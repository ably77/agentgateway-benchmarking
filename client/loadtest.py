"""
Agentgateway Loadgen — Locust load test.

Simulates N concurrent users each running one of three profiles:
  chain  — full chain through both gateway routes; flow controlled by LOCUST_SCENARIO:
             scenario b (default): Context-Augmented Flow (RAG style)
               agw /mcp echo ×N → agw /mock-openai ×N
             scenario a: Standard Tool-Use Flow (LLM-first orchestration)
               agw /mock-openai (initial) ×N → agw /mcp echo ×N → agw /mock-openai (summary) ×N
  mcp    — agw /mcp → mcp-everything echo ×N  (MCP proxy baseline, no LLM hop)
  llm    — agw /mock-openai → mock-llm echo ×N  (LLM proxy baseline, no MCP session)

Set via LOCUST_PROFILE env var (default: chain). Launched by the Streamlit UI or directly:
    locust -f loadtest.py --headless -u 10 -r 2 -t 60s \
        --host http://<GATEWAY_IP>:8080

Environment variables:
    LOCUST_PROFILE   chain | mcp | llm  (default: chain)
    LOCUST_SCENARIO  a | b  (default: b)
                       a = Standard Tool-Use Flow: LLM → MCP → LLM
                       b = Context-Augmented Flow (RAG style): MCP → LLM
    MCP_PATH         MCP route prefix   (default: /mcp)
    LLM_PATH         LLM route prefix   (default: /mock-openai)
    LLM_HOST         LLM gateway base URL if separate from MCP gateway (default: uses --host)
    MCP_NUM_CALLS    MCP echo calls per task iteration  (default: 1)
    LLM_NUM_CALLS    LLM chat calls per task iteration  (default: 1)
    MCP_ECHO_KB      MCP echo message size in KB, 32–256  (default: 32)
    LLM_PAYLOAD_B    Bytes of MCP content forwarded to LLM, 1–2048  (default: 256)
"""

import os
import json
import time
import threading
from datetime import datetime, timezone

from locust import HttpUser, task, between, events


# Path where on_quitting will write final stats for all routes (more accurate than CSV)
LOCUST_STATS_FILE = os.environ.get("LOCUST_STATS_FILE", "")

_test_start_time: datetime | None = None

@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    global _test_start_time
    _test_start_time = datetime.now(timezone.utc)

OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "placeholder-key")

# Profile controls which task runs: "chain" | "mcp" | "llm"
LOCUST_PROFILE = os.environ.get("LOCUST_PROFILE", "chain")

# Scenario controls chain flow: "a" = Standard Tool-Use Flow, "b" = Context-Augmented Flow (RAG)
LOCUST_SCENARIO = os.environ.get("LOCUST_SCENARIO", "b")

MCP_PATH = os.environ.get("MCP_PATH", "/mcp")
LLM_PATH = os.environ.get("LLM_PATH", "/mock-openai")
LLM_HOST = os.environ.get("LLM_HOST", "")  # if empty, falls back to self.host

# Number of MCP echo calls per task iteration
MCP_NUM_CALLS = max(1, int(os.environ.get("MCP_NUM_CALLS", "1")))
LLM_NUM_CALLS = max(1, int(os.environ.get("LLM_NUM_CALLS", "1")))

# LLM payload truncation size in bytes (1–2048). Set via LLM_PAYLOAD_B env var.
LLM_PAYLOAD_B = max(1, min(2048, int(os.environ.get("LLM_PAYLOAD_B", "256"))))

# Echo message size in KB (32–256). Set via MCP_ECHO_KB env var.
_echo_kb = int(os.environ.get("MCP_ECHO_KB", "32"))
_echo_kb = max(32, min(256, _echo_kb))
import random as _random
_WORDS = ["apple","bridge","cloud","delta","echo","forest","gateway","harbor",
          "island","jungle","kernel","lambda","matrix","nebula","orbit","proxy",
          "quorum","router","signal","token","uplink","vector","widget","xenon",
          "yellow","zenith","agent","buffer","cluster","daemon","endpoint","flux"]
_target = _echo_kb * 1024
_parts: list[str] = []
_size = 0
while _size < _target:
    w = _random.choice(_WORDS)
    _parts.append(w)
    _size += len(w) + 1
ECHO_MESSAGE = " ".join(_parts)[:_target]


class AgentGatewayUser(HttpUser):
    """
    Each Locust user represents one concurrent client instance.

    on_start: MCP initialize → capture session ID (once per user, skipped for llm profile)
    Active task is determined by LOCUST_PROFILE at module load:
      chain — mcp_to_llm_chain  (MCP echo × N → LLM chat × N)
      mcp   — mcp_direct_call   (MCP echo × N only)
      llm   — llm_direct_call   (LLM chat × N only, no MCP session)
    """

    wait_time = between(0.5, 2.0)
    mcp_session_id: str = ""

    def on_start(self):
        """Establish MCP session once per simulated user (skipped for direct LLM profile)."""
        if LOCUST_PROFILE == "llm":
            return

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Accept": "application/json, text/event-stream",
        }
        payload = {
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "locust-user", "version": "1.0"},
            },
        }
        with self.client.post(
            MCP_PATH,
            json=payload,
            headers=headers,
            catch_response=True,
            name="/mcp initialize",
        ) as resp:
            if resp.status_code == 200:
                self.mcp_session_id = resp.headers.get("mcp-session-id", "")
                if self.mcp_session_id:
                    resp.success()
                else:
                    resp.failure("No mcp-session-id in initialize response")
            else:
                resp.failure(f"Initialize failed: HTTP {resp.status_code}")

    # ------------------------------------------------------------------ #
    #  Full chain: agw /mcp → mcp-everything echo → agw /mock-openai    #
    # ------------------------------------------------------------------ #
    @task
    def mcp_to_llm_chain(self):
        """
        Step 1: MCP tools/call → echo (agw /mcp → mcp-everything)
        Step 2: Forward echoed content to mock LLM (agw /mock-openai → mock-llm echo)
        Exercises both gateway routes in sequence through the shared gateway.
        """
        chain_start = time.perf_counter()
        mcp_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Accept": "application/json, text/event-stream",
            "mcp-session-id": self.mcp_session_id,
        }

        # Step 1: MCP echo ×N
        mcp_parts = []
        for call_i in range(MCP_NUM_CALLS):
            mcp_payload = {
                "jsonrpc": "2.0",
                "id": int(time.time() * 1000) + call_i,
                "method": "tools/call",
                "params": {"name": "echo", "arguments": {"message": ECHO_MESSAGE}},
            }
            start = time.perf_counter()
            with self.client.post(
                MCP_PATH,
                json=mcp_payload,
                headers=mcp_headers,
                catch_response=True,
                name="/mcp → echo tool",
            ) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000
                _record_hop_headers(resp, elapsed_ms)
                if resp.status_code == 200:
                    resp.success()
                    for line in resp.text.splitlines():
                        if line.startswith("data: "):
                            try:
                                data = json.loads(line[6:])
                                items = data.get("result", {}).get("content", [])
                                text = items[0].get("text", "") if items else ""
                                if text.startswith("Echo: "):
                                    text = text[6:]
                                if text:
                                    mcp_parts.append(text)
                            except Exception:
                                pass
                            break
                else:
                    resp.failure(f"HTTP {resp.status_code}: {resp.text[:200]}")
                    return  # skip LLM hop if any MCP call failed

        mcp_content = " ".join(mcp_parts) if mcp_parts else ECHO_MESSAGE

        # Step 2: forward to mock LLM ×N
        llm_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPENAI_API_KEY}",
        }
        for _ in range(LLM_NUM_CALLS):
            llm_payload = {
                "model": "mock-gpt-4o-mini",
                "messages": [{"role": "user", "content": mcp_content[:LLM_PAYLOAD_B]}],
            }
            start = time.perf_counter()
            with self.client.post(
                f"{LLM_HOST}{LLM_PATH}/v1/chat/completions" if LLM_HOST else f"{LLM_PATH}/v1/chat/completions",
                json=llm_payload,
                headers=llm_headers,
                catch_response=True,
                name="/mock-openai",
            ) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000
                _record_hop_headers(resp, elapsed_ms)
                if resp.status_code == 200:
                    resp.success()
                else:
                    resp.failure(f"HTTP {resp.status_code}: {resp.text[:200]}")
                    return

        chain_ms = (time.perf_counter() - chain_start) * 1000
        self.environment.events.request.fire(
            request_type="CHAIN",
            name="[full chain] context-augmented flow",
            response_time=chain_ms,
            response_length=0,
            exception=None,
            context={},
        )

    # ------------------------------------------------------------------ #
    #  Standard Tool-Use Flow (Scenario A): LLM → MCP → LLM            #
    # ------------------------------------------------------------------ #
    @task
    def scenario_a_chain(self):
        """
        Standard Tool-Use Flow — the LLM acts as orchestrator.
        Step 1: LLM call ×N (initial prompt — LLM decides to call a tool)
        Step 2: MCP tools/call echo ×N (tool execution as instructed by LLM)
        Step 3: LLM call ×N (tool result forwarded back for final summary)
        """
        chain_start = time.perf_counter()
        llm_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPENAI_API_KEY}",
        }
        mcp_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Accept": "application/json, text/event-stream",
            "mcp-session-id": self.mcp_session_id,
        }
        initial_prompt = ECHO_MESSAGE[:LLM_PAYLOAD_B]

        # Step 1: Initial LLM call ×N — LLM receives prompt, "decides" to call a tool
        for _ in range(LLM_NUM_CALLS):
            llm_payload = {
                "model": "mock-gpt-4o-mini",
                "messages": [{"role": "user", "content": initial_prompt}],
            }
            start = time.perf_counter()
            with self.client.post(
                f"{LLM_HOST}{LLM_PATH}/v1/chat/completions" if LLM_HOST else f"{LLM_PATH}/v1/chat/completions",
                json=llm_payload,
                headers=llm_headers,
                catch_response=True,
                name="/mock-openai → initial prompt",
            ) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000
                _record_hop_headers(resp, elapsed_ms)
                if resp.status_code == 200:
                    resp.success()
                else:
                    resp.failure(f"HTTP {resp.status_code}: {resp.text[:200]}")
                    return

        # Step 2: MCP echo ×N — tool execution as instructed by LLM
        mcp_parts = []
        for call_i in range(MCP_NUM_CALLS):
            mcp_payload = {
                "jsonrpc": "2.0",
                "id": int(time.time() * 1000) + call_i,
                "method": "tools/call",
                "params": {"name": "echo", "arguments": {"message": ECHO_MESSAGE}},
            }
            start = time.perf_counter()
            with self.client.post(
                MCP_PATH,
                json=mcp_payload,
                headers=mcp_headers,
                catch_response=True,
                name="/mcp → echo tool",
            ) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000
                _record_hop_headers(resp, elapsed_ms)
                if resp.status_code == 200:
                    resp.success()
                    for line in resp.text.splitlines():
                        if line.startswith("data: "):
                            try:
                                data = json.loads(line[6:])
                                items = data.get("result", {}).get("content", [])
                                text = items[0].get("text", "") if items else ""
                                if text.startswith("Echo: "):
                                    text = text[6:]
                                if text:
                                    mcp_parts.append(text)
                            except Exception:
                                pass
                            break
                else:
                    resp.failure(f"HTTP {resp.status_code}: {resp.text[:200]}")
                    return

        mcp_content = " ".join(mcp_parts) if mcp_parts else ECHO_MESSAGE

        # Step 3: Final LLM call ×N — LLM receives tool result, produces summary
        for _ in range(LLM_NUM_CALLS):
            llm_payload = {
                "model": "mock-gpt-4o-mini",
                "messages": [
                    {"role": "user", "content": initial_prompt},
                    {"role": "assistant", "content": "[tool_use: echo]"},
                    {"role": "tool", "content": mcp_content[:LLM_PAYLOAD_B]},
                ],
            }
            start = time.perf_counter()
            with self.client.post(
                f"{LLM_HOST}{LLM_PATH}/v1/chat/completions" if LLM_HOST else f"{LLM_PATH}/v1/chat/completions",
                json=llm_payload,
                headers=llm_headers,
                catch_response=True,
                name="/mock-openai → tool result summary",
            ) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000
                _record_hop_headers(resp, elapsed_ms)
                if resp.status_code == 200:
                    resp.success()
                else:
                    resp.failure(f"HTTP {resp.status_code}: {resp.text[:200]}")
                    return

        chain_ms = (time.perf_counter() - chain_start) * 1000
        self.environment.events.request.fire(
            request_type="CHAIN",
            name="[full chain] standard tool-use",
            response_time=chain_ms,
            response_length=0,
            exception=None,
            context={},
        )

    # ------------------------------------------------------------------ #
    #  Direct MCP baseline: MCP echo only, no LLM hop                   #
    # ------------------------------------------------------------------ #
    @task
    def mcp_direct_call(self):
        """
        MCP tools/call → echo only (agw /mcp → mcp-everything).
        Baseline to isolate raw MCP proxy latency from LLM overhead.
        """
        mcp_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Accept": "application/json, text/event-stream",
            "mcp-session-id": self.mcp_session_id,
        }
        for call_i in range(MCP_NUM_CALLS):
            payload = {
                "jsonrpc": "2.0",
                "id": int(time.time() * 1000) + call_i,
                "method": "tools/call",
                "params": {"name": "echo", "arguments": {"message": ECHO_MESSAGE}},
            }
            start = time.perf_counter()
            with self.client.post(
                MCP_PATH,
                json=payload,
                headers=mcp_headers,
                catch_response=True,
                name="/mcp → echo tool",
            ) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000
                _record_hop_headers(resp, elapsed_ms)
                if resp.status_code == 200:
                    resp.success()
                else:
                    resp.failure(f"HTTP {resp.status_code}: {resp.text[:200]}")
                    return

    # ------------------------------------------------------------------ #
    #  Direct LLM baseline: /mock-openai only, no MCP hops              #
    # ------------------------------------------------------------------ #
    @task
    def llm_direct_call(self):
        """
        Direct chat completion through agw /mock-openai → mock-llm.
        Baseline to isolate MCP-proxy overhead from raw gateway+LLM latency.
        Sends a message of LLM_PAYLOAD_B bytes — mock-llm echoes it back,
        so response size matches the payload size.
        """
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPENAI_API_KEY}",
        }

        _parts, _size = [], 0
        while _size < LLM_PAYLOAD_B:
            w = _random.choice(_WORDS)
            _parts.append(w)
            _size += len(w) + 1
        llm_message = " ".join(_parts)[:LLM_PAYLOAD_B]

        for _ in range(LLM_NUM_CALLS):
            payload = {
                "model": "mock-gpt-4o-mini",
                "messages": [{"role": "user", "content": llm_message}],
            }
            start = time.perf_counter()
            with self.client.post(
                f"{LLM_HOST}{LLM_PATH}/v1/chat/completions" if LLM_HOST else f"{LLM_PATH}/v1/chat/completions",
                json=payload,
                headers=headers,
                catch_response=True,
                name="/mock-openai",
            ) as resp:
                elapsed_ms = (time.perf_counter() - start) * 1000
                _record_hop_headers(resp, elapsed_ms)
                if resp.status_code == 200:
                    resp.success()
                else:
                    resp.failure(f"HTTP {resp.status_code}: {resp.text[:200]}")
                    return


# ------------------------------------------------------------------ #
#  Apply profile — restrict tasks to the selected profile            #
# ------------------------------------------------------------------ #
if LOCUST_PROFILE == "chain":
    if LOCUST_SCENARIO == "a":
        # Standard Tool-Use Flow: LLM → MCP → LLM
        AgentGatewayUser.tasks = [AgentGatewayUser.scenario_a_chain]
    else:
        # Context-Augmented Flow (RAG style): MCP → LLM
        AgentGatewayUser.tasks = [AgentGatewayUser.mcp_to_llm_chain]
elif LOCUST_PROFILE == "mcp":
    AgentGatewayUser.tasks = [AgentGatewayUser.mcp_direct_call]
elif LOCUST_PROFILE == "llm":
    AgentGatewayUser.tasks = [AgentGatewayUser.llm_direct_call]


# ------------------------------------------------------------------ #
#  Helper: extract per-hop timing from response headers              #
# ------------------------------------------------------------------ #
def _record_hop_headers(resp, elapsed_ms: float):
    """Print client-side hop timing. AgentGateway does not add upstream timing headers."""
    print(f"[hop-timing] client_ms={elapsed_ms:.1f}")


# ------------------------------------------------------------------ #
#  Event hooks — print summary at end of test                        #
# ------------------------------------------------------------------ #
@events.quitting.add_listener
def on_quitting(environment, **kwargs):
    end_time = datetime.now(timezone.utc)
    elapsed_s = (end_time - _test_start_time).total_seconds() if _test_start_time else 0.0

    stats = environment.stats
    all_rows = []
    print("\n=== Agentgateway Loadgen — Summary ===")
    if _test_start_time:
        print(f"Start:   {_test_start_time.strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print(f"End:     {end_time.strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print(f"Elapsed: {elapsed_s:.1f}s")
    print("------")
    for name, entry in stats.entries.items():
        if entry.num_requests == 0:
            continue
        route = entry.name if hasattr(entry, 'name') else name[1]
        print(
            f"{route:50s}  "
            f"reqs={entry.num_requests:5d}  "
            f"fails={entry.num_failures:4d}  "
            f"p50={entry.get_response_time_percentile(0.5):.2f}ms  "
            f"p95={entry.get_response_time_percentile(0.95):.2f}ms  "
            f"p99={entry.get_response_time_percentile(0.99):.2f}ms"
        )
        all_rows.append({
            "route": route,
            "requests": entry.num_requests,
            "failures": entry.num_failures,
            "rps": round(entry.current_rps, 2),
            "p50": entry.get_response_time_percentile(0.5),
            "p95": entry.get_response_time_percentile(0.95),
            "p99": entry.get_response_time_percentile(0.99),
        })
    print("=====================================\n")
    if LOCUST_STATS_FILE:
        try:
            with open(LOCUST_STATS_FILE, "w") as _f:
                json.dump({
                    "start_time": _test_start_time.isoformat() if _test_start_time else None,
                    "end_time": end_time.isoformat(),
                    "elapsed_s": round(elapsed_s, 1),
                    "rows": all_rows,
                }, _f)
        except Exception:
            pass
