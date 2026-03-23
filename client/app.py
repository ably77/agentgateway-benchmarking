"""
Agentgateway Loadgen
Streamlit UI for single-request smoke tests and concurrent Locust load-test launching.

Measures pure AgentGateway overhead — no real AI inference involved.
All backend services are deterministic echo servers:
  agw /mcp          → mcp-everything (MCP proxy hop, echo tool)
  agw /mock-openai  → mock-llm in echo mode (LLM proxy hop, mirrors user message)

Usage:
    streamlit run app.py

Environment variables:
    GATEWAY_IP   AgentGateway load-balancer IP (pre-fills the sidebar field)
"""

import os
import time
import json
import subprocess
import threading
import queue
import sys

import csv
import tempfile

import requests
import streamlit as st



# ------------------------------------------------------------------ #
#  Helpers                                                            #
# ------------------------------------------------------------------ #
def _show_locust_summary(csv_prefix: str, test_meta: dict | None = None):
    """Parse locust stats and render a summary table + key metrics."""
    stats_file = f"{csv_prefix}_stats.csv"
    failures_file = f"{csv_prefix}_failures.csv"
    sidecar_file = f"{csv_prefix}_stats.json"

    rows = []
    sidecar_meta = {}

    # Prefer sidecar JSON (written by on_quitting) — it captures the final in-memory
    # stats after the CSV may have been flushed early.
    if os.path.exists(sidecar_file):
        try:
            with open(sidecar_file) as f:
                sidecar = json.load(f)
            sidecar_meta = {k: v for k, v in sidecar.items() if k != "rows"}
            for entry in sidecar.get("rows", []):
                rows.append({
                    "Route": entry.get("route", ""),
                    "Requests": entry.get("requests", 0),
                    "Failures": entry.get("failures", 0),
                    "RPS": entry.get("rps", 0.0),
                    "p50 (ms)": round(entry.get("p50", 0), 2),
                    "p95 (ms)": round(entry.get("p95", 0), 2),
                    "p99 (ms)": round(entry.get("p99", 0), 2),
                })
        except Exception:
            rows = []

    # Fall back to CSV if sidecar isn't available yet.
    if not rows and os.path.exists(stats_file):
        with open(stats_file) as f:
            for row in csv.DictReader(f):
                if row.get("Name") in ("", "Aggregated"):
                    continue
                rows.append({
                    "Route": row.get("Name", ""),
                    "Requests": int(row.get("Request Count", 0)),
                    "Failures": int(row.get("Failure Count", 0)),
                    "RPS": round(float(row.get("Requests/s", 0)), 2),
                    "p50 (ms)": round(float(row.get("50%", 0)), 2),
                    "p95 (ms)": round(float(row.get("95%", 0)), 2),
                    "p99 (ms)": round(float(row.get("99%", 0)), 2),
                })

    if not rows:
        return

    # ── Test metadata ──────────────────────────────────────────────────
    st.markdown("#### Test Info")
    meta_cols = st.columns(3)
    start_iso = sidecar_meta.get("start_time") or (test_meta or {}).get("start_time", "—")
    end_iso   = sidecar_meta.get("end_time")   or (test_meta or {}).get("end_time",   "—")
    elapsed_s = sidecar_meta.get("elapsed_s")  or (test_meta or {}).get("elapsed_s",  None)

    def _fmt_dt(iso):
        if not iso or iso == "—":
            return "—"
        try:
            from datetime import datetime, timezone
            dt = datetime.fromisoformat(iso)
            return dt.strftime("%Y-%m-%d %H:%M:%S UTC")
        except Exception:
            return iso

    meta_cols[0].markdown(f"**Start Time**  \n{_fmt_dt(start_iso)}")
    meta_cols[1].markdown(f"**End Time**  \n{_fmt_dt(end_iso)}")
    meta_cols[2].markdown(f"**Elapsed**  \n{elapsed_s:.1f}s" if elapsed_s is not None else "**Elapsed**  \n—")

    if test_meta:
        meta_cols2 = st.columns(3)
        meta_cols2[0].markdown(f"**Test Type**  \n{test_meta.get('profile_label', '—')}")
        meta_cols2[1].markdown(f"**Concurrent Users**  \n{test_meta.get('users', '—')}")
        meta_cols2[2].markdown(f"**Spawn Rate**  \n{test_meta.get('spawn_rate', '—')} users/s")

        meta_cols3 = st.columns(3)
        meta_cols3[0].markdown(f"**Duration**  \n{test_meta.get('duration', '—')}s")
        mcp_calls = test_meta.get("mcp_calls")
        llm_per_step = test_meta.get("llm_calls_per_step")
        total_llm = test_meta.get("total_llm_calls")
        meta_cols3[1].markdown(f"**MCP Tool Calls / Task**  \n{mcp_calls}" if mcp_calls is not None else "**MCP Tool Calls / Task**  \n—")
        if llm_per_step is not None and total_llm is not None:
            meta_cols3[2].markdown(f"**Total LLM Calls / Task**  \n{total_llm} ({llm_per_step} per step)")
        else:
            meta_cols3[2].markdown("**Total LLM Calls / Task**  \n—")

    st.markdown("#### Results")
    st.dataframe(rows, width='stretch')


    # Failures detail
    if os.path.exists(failures_file):
        fail_rows = []
        with open(failures_file) as f:
            fail_rows = list(csv.DictReader(f))
        if fail_rows:
            with st.expander(f"Failures ({len(fail_rows)})"):
                st.dataframe(fail_rows, width='stretch')


# ------------------------------------------------------------------ #
#  Page config                                                        #
# ------------------------------------------------------------------ #
st.set_page_config(
    page_title="Agentgateway Loadgen",
    page_icon="⚡",
    layout="wide",
)

# ------------------------------------------------------------------ #
#  Sidebar — configuration                                           #
# ------------------------------------------------------------------ #
st.sidebar.markdown("### Configure gateway endpoints and routes")

shared_gateway = st.sidebar.checkbox("Shared gateway", value=True, key="shared_gateway")

if shared_gateway:
    gateway_ip = st.sidebar.text_input(
        "Gateway IP / Host",
        value=os.environ.get("GATEWAY_IP", ""),
        placeholder="e.g. 34.120.0.1",
        key="gw_ip_shared",
    )
    gateway_port = st.sidebar.number_input("Gateway Port", value=8080, step=1, key="gw_port_shared")
    mcp_gateway_ip = gateway_ip
    llm_gateway_ip = gateway_ip
    mcp_gateway_port = gateway_port
    llm_gateway_port = gateway_port
else:
    mcp_gateway_ip = st.sidebar.text_input(
        "MCP Gateway IP / Host",
        value=os.environ.get("GATEWAY_IP", ""),
        placeholder="e.g. 34.120.0.1",
        key="gw_ip_mcp",
    )
    mcp_gateway_port = st.sidebar.number_input("MCP Gateway Port", value=8080, step=1, key="gw_port_mcp")
    llm_gateway_ip = st.sidebar.text_input(
        "LLM Gateway IP / Host",
        value=os.environ.get("GATEWAY_IP", ""),
        placeholder="e.g. 34.120.0.1",
        key="gw_ip_llm",
    )
    llm_gateway_port = st.sidebar.number_input("LLM Gateway Port", value=8080, step=1, key="gw_port_llm")
    gateway_ip = mcp_gateway_ip
    gateway_port = mcp_gateway_port
api_key = "placeholder-key"

st.sidebar.markdown("**Gateway Routes**")
mcp_path = st.sidebar.text_input("MCP path", value="/mcp", key="mcp_path")
llm_path = st.sidebar.text_input("LLM path", value="/mock-openai", key="llm_path")

if "mcp_session_id" not in st.session_state:
    st.session_state.mcp_session_id = ""
if "mcp_init_ms" not in st.session_state:
    st.session_state.mcp_init_ms = 0.0



# ------------------------------------------------------------------ #
#  Main area                                                          #
# ------------------------------------------------------------------ #
st.title("Agentgateway Loadgen")
st.caption(
    "Measures pure gateway overhead when all components are colocated in the same cluster and AZ. "
    "MCP traffic routes through `agw /mcp → mcp-everything` and LLM traffic through "
    "`agw /mock-openai → mock-llm (echo mode)` — both on the same shared AgentGateway instance."
)

tab_single, tab_load = st.tabs(
    ["Single Request", "Load Test (Locust)"]
)

# ================================================================== #
#  TAB 1 — Single Request                                            #
# ================================================================== #
with tab_single:
    st.subheader("Single Request — Direct HTTP Client")
    st.caption(
        "Makes raw HTTP calls through AgentGateway — no agent or framework involved. "
        "Use this to establish baseline hop latencies before adding agent overhead."
    )

    # ── Profile selector ───────────────────────────────────────────────────
    sr_pcol1, sr_pcol2 = st.columns(2)
    with sr_pcol1:
        sr_profile = st.radio(
            "Profile",
            options=["Full Chain", "Direct MCP Baseline", "Direct LLM Baseline"],
            key="sr_profile",
        )
        if sr_profile == "Full Chain":
            _sr_flow = st.radio(
                "Flow",
                options=["Standard Tool-Use Flow", "Context-Augmented Flow (RAG Style)"],
                index=0,
                key="sr_flow",
                horizontal=True,
                help=(
                    "**Standard Tool-Use Flow:** "
                    "LLM receives the prompt first and decides which tool to call. "
                    "Order: LLM call → MCP tool execution → LLM call with tool result.\n\n"
                    "**Context-Augmented Flow (RAG Style):** "
                    "Agent proactively fetches context from MCP before engaging the LLM. "
                    "Order: MCP tool call → LLM call with retrieved context."
                ),
            )
            sr_scenario_a = (_sr_flow == "Standard Tool-Use Flow")
        else:
            sr_scenario_a = False
    with sr_pcol2:
        if sr_profile == "Full Chain":
            if sr_scenario_a:
                st.info(
                    "**Standard Tool-Use Flow** — the LLM acts as orchestrator. "
                    "1️⃣ `/mock-openai` receives the prompt and decides to call a tool → "
                    "2️⃣ `/mcp tools/call echo` executes the tool → "
                    "3️⃣ `/mock-openai` receives the tool result and produces a final response. "
                    "Captures 'Time to First Tool Call' as the key latency bottleneck."
                )
            else:
                st.info(
                    "**Context-Augmented Flow (RAG style)** — the agent fetches context first. "
                    "1️⃣ `/mcp tools/call echo` retrieves data proactively → "
                    "2️⃣ `/mock-openai` receives the retrieved context alongside the prompt. "
                    "End-to-end latency through both gateway routes."
                )
        elif sr_profile == "Direct MCP Baseline":
            st.info(
                "**Direct MCP Baseline** — `/mcp initialize` once, then "
                "`/mcp tools/call echo` only. No LLM hop. "
                "Isolates MCP proxy latency."
            )
        else:
            st.info(
                "**Direct LLM Baseline** — no MCP session. "
                "`/mock-openai chat/completions` only. "
                "Isolates LLM proxy latency at a configurable payload size."
            )

    # ── Step 1: MCP Session (not needed for Direct LLM) ───────────────────
    if sr_profile != "Direct LLM Baseline":
        st.markdown("**Step 1 — MCP Session**")
        init_col1, init_col2 = st.columns([1, 3])
        with init_col1:
            init_btn = st.button(
                "Initialize" if not st.session_state.mcp_session_id else "Re-initialize",
                key="init_mcp",
                disabled=not gateway_ip,
            )
        with init_col2:
            if st.session_state.mcp_session_id:
                st.success(
                    f"Session active — ID `{st.session_state.mcp_session_id[:16]}…` "
                    f"| init: {st.session_state.mcp_init_ms:.2f} ms"
                )
            else:
                st.warning("No session — click Initialize before running.")

        if init_btn:
            if not gateway_ip:
                st.error("Set Gateway IP in the sidebar first.")
            else:
                _mcp_url = f"http://{mcp_gateway_ip}:{mcp_gateway_port}{mcp_path}"
                _headers = {
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {api_key}",
                    "Accept": "application/json, text/event-stream",
                }
                try:
                    _t = time.perf_counter()
                    _resp = requests.post(
                        _mcp_url,
                        json={"jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                                         "clientInfo": {"name": "scenario-1", "version": "1.0"}}},
                        headers=_headers,
                        timeout=30,
                    )
                    _resp.raise_for_status()
                    _sid = _resp.headers.get("mcp-session-id", "")
                    if _sid:
                        st.session_state.mcp_session_id = _sid
                        st.session_state.mcp_init_ms = (time.perf_counter() - _t) * 1000
                        st.rerun()
                    else:
                        st.error("No mcp-session-id in response")
                except Exception as _exc:
                    st.error(f"Init failed: {_exc}")

    # ── Step 2: Config + Run ───────────────────────────────────────────────
    st.markdown("**Step 2 — Run**")

    if sr_profile == "Full Chain":
        cfg_col1, cfg_col2 = st.columns(2)
        msg_kb = cfg_col1.slider("MCP message size (KB)", min_value=32, max_value=256, value=32, step=8, key="msg_kb")
        num_calls = cfg_col2.number_input("MCP tool calls", min_value=1, max_value=20, value=1, step=1, key="num_calls")
        llm_payload_b = 2048
        run_btn = st.button("Run Full Chain", type="primary", key="run_chain", disabled=not st.session_state.mcp_session_id)
    elif sr_profile == "Direct MCP Baseline":
        cfg_col1, cfg_col2 = st.columns(2)
        msg_kb = cfg_col1.slider("MCP message size (KB)", min_value=32, max_value=256, value=32, step=8, key="msg_kb")
        num_calls = cfg_col2.number_input("MCP tool calls", min_value=1, max_value=20, value=1, step=1, key="num_calls")
        llm_payload_b = 2048
        run_btn = st.button("Run Direct MCP", type="primary", key="run_mcp", disabled=not st.session_state.mcp_session_id)
    else:
        llm_payload_b = st.slider("LLM payload size (B)", min_value=1, max_value=2048, value=256, step=1, key="sr_llm_payload_b")
        msg_kb = 32
        num_calls = 1
        run_btn = st.button("Run Direct LLM", type="primary", key="run_llm", disabled=not gateway_ip)

    if run_btn:
        if not gateway_ip:
            st.error("Set Gateway IP in the sidebar first.")
            st.stop()

        import random as _rand
        _words = ["apple","bridge","cloud","delta","echo","forest","gateway","harbor",
                  "island","jungle","kernel","lambda","matrix","nebula","orbit","proxy",
                  "quorum","router","signal","token","uplink","vector","widget","xenon",
                  "yellow","zenith","agent","buffer","cluster","daemon","endpoint","flux"]

        # Build echo_message (used by MCP calls in both flows) and a short user prompt
        # (used as the initial LLM message in the Standard Tool-Use Flow).
        _target = msg_kb * 1024
        _parts, _size = [], 0
        while _size < _target:
            w = _rand.choice(_words)
            _parts.append(w)
            _size += len(w) + 1
        echo_message = " ".join(_parts)[:_target]

        _prompt_parts, _prompt_size = [], 0
        while _prompt_size < llm_payload_b:
            w = _rand.choice(_words)
            _prompt_parts.append(w)
            _prompt_size += len(w) + 1
        user_prompt = " ".join(_prompt_parts)[:llm_payload_b]

        mcp_base_url = f"http://{mcp_gateway_ip}:{mcp_gateway_port}"
        llm_base_url = f"http://{llm_gateway_ip}:{llm_gateway_port}"
        mcp_url = f"{mcp_base_url}{mcp_path}"
        base_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json, text/event-stream",
        }

        # ── Standard Tool-Use Flow (Scenario A): LLM → MCP → LLM ────────
        if sr_profile == "Full Chain" and sr_scenario_a:
            # Step 1: Initial LLM call — LLM receives prompt, "decides" to call a tool
            with st.spinner("Step 1/3 — Initial LLM call (LLM receives prompt) …"):
                try:
                    t_llm1 = time.perf_counter()
                    llm1_resp = requests.post(
                        f"{llm_base_url}{llm_path}/v1/chat/completions",
                        json={"model": "mock-gpt-4o-mini",
                              "messages": [{"role": "user", "content": user_prompt}]},
                        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
                        timeout=120,
                    )
                    llm1_ms = (time.perf_counter() - t_llm1) * 1000
                    if not llm1_resp.ok:
                        st.error(f"Initial LLM call failed: HTTP {llm1_resp.status_code}")
                        st.code(llm1_resp.text[:1000])
                        st.stop()
                except requests.exceptions.RequestException as exc:
                    st.error(f"Initial LLM call failed: {exc}")
                    st.stop()

            # Step 2: MCP tool call — agent executes the tool the LLM requested
            session_headers = {**base_headers, "mcp-session-id": st.session_state.mcp_session_id}
            mcp_parts = []
            mcp_ms_total = 0.0
            mcp_responses = []
            for call_i in range(int(num_calls)):
                with st.spinner(f"Step 2/3 — MCP tool call {call_i + 1}/{int(num_calls)} — echo ({msg_kb} KB) …"):
                    try:
                        t_mcp = time.perf_counter()
                        mcp_resp = requests.post(
                            mcp_url,
                            json={"jsonrpc": "2.0", "id": call_i + 2, "method": "tools/call",
                                  "params": {"name": "echo", "arguments": {"message": echo_message}}},
                            headers=session_headers,
                            timeout=120,
                        )
                        call_ms = (time.perf_counter() - t_mcp) * 1000
                        mcp_ms_total += call_ms
                        mcp_resp.raise_for_status()
                        mcp_responses.append((call_i + 1, call_ms, mcp_resp.text))
                        for line in mcp_resp.text.splitlines():
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
                    except requests.exceptions.RequestException as exc:
                        st.error(f"MCP echo call {call_i + 1} failed: {exc}")
                        st.stop()

            mcp_ms = mcp_ms_total
            mcp_content = " ".join(mcp_parts)

            for call_num, call_ms, raw in mcp_responses:
                with st.expander(f"MCP response — call {call_num} ({call_ms:.2f} ms)"):
                    for line in raw.splitlines():
                        if line.startswith("data: "):
                            try:
                                st.json(json.loads(line[6:]))
                            except Exception:
                                st.code(line)
                            break

            # Step 3: Final LLM call — LLM receives tool result and produces final response
            with st.spinner("Step 3/3 — Final LLM call (tool result → summary) …"):
                try:
                    t_llm2 = time.perf_counter()
                    llm2_resp = requests.post(
                        f"{llm_base_url}{llm_path}/v1/chat/completions",
                        json={"model": "mock-gpt-4o-mini",
                              "messages": [
                                  {"role": "user", "content": user_prompt},
                                  {"role": "assistant", "content": "[tool_use: echo]"},
                                  {"role": "tool", "content": mcp_content[:llm_payload_b]},
                              ]},
                        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
                        timeout=120,
                    )
                    llm2_ms = (time.perf_counter() - t_llm2) * 1000
                    if not llm2_resp.ok:
                        st.error(f"Final LLM call failed: HTTP {llm2_resp.status_code}")
                        st.code(llm2_resp.text[:1000])
                        st.stop()
                except requests.exceptions.RequestException as exc:
                    st.error(f"Final LLM call failed: {exc}")
                    st.stop()

            total_ms = llm1_ms + mcp_ms + llm2_ms
            st.success(f"Standard Tool-Use Flow completed in **{total_ms:.2f} ms**")
            col_a, col_b, col_c, col_d = st.columns(4)
            col_a.metric("LLM initial (ms)", f"{llm1_ms:.2f}", help="Step 1 — LLM receives prompt. In production this is the 'Time to First Tool Call' bottleneck.")
            col_b.metric(f"MCP echo ×{int(num_calls)} (ms)", f"{mcp_ms:.2f}", help="Step 2 — MCP tool execution as instructed by the LLM.")
            col_c.metric("LLM summary (ms)", f"{llm2_ms:.2f}", help="Step 3 — LLM receives tool result and produces final response.")
            col_d.metric("Total (ms)", f"{total_ms:.2f}", help="Sum of all three hops client-side.")
            st.caption("⚠️ These are **client-side** measurements and include client↔gateway network latency on each hop. To isolate pure gateway processing time, use `agentgateway_request_duration_seconds_bucket` in Grafana.")
            with st.expander("Initial LLM response"):
                try:
                    body = llm1_resp.json()
                    reply = body.get("choices", [{}])[0].get("message", {}).get("content", "")
                    st.info(f"Echo reply preview: **{reply[:120]}{'…' if len(reply) > 120 else ''}**")
                    st.json(body)
                except Exception:
                    st.code(llm1_resp.text[:500])
            with st.expander("Final LLM response"):
                try:
                    body = llm2_resp.json()
                    reply = body.get("choices", [{}])[0].get("message", {}).get("content", "")
                    st.info(f"Echo reply preview: **{reply[:120]}{'…' if len(reply) > 120 else ''}**")
                    st.json(body)
                except Exception:
                    st.code(llm2_resp.text[:500])

        # ── Direct LLM Baseline ───────────────────────────────────────────
        elif sr_profile == "Direct LLM Baseline":
            _parts, _size = [], 0
            while _size < llm_payload_b:
                w = _rand.choice(_words)
                _parts.append(w)
                _size += len(w) + 1
            llm_message = " ".join(_parts)[:llm_payload_b]

            with st.spinner(f"Sending {llm_payload_b}B to mock LLM …"):
                try:
                    t_llm = time.perf_counter()
                    llm_resp = requests.post(
                        f"{llm_base_url}{llm_path}/v1/chat/completions",
                        json={"model": "mock-gpt-4o-mini",
                              "messages": [{"role": "user", "content": llm_message}]},
                        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
                        timeout=120,
                    )
                    llm_ms = (time.perf_counter() - t_llm) * 1000
                    if not llm_resp.ok:
                        st.error(f"Mock LLM call failed: HTTP {llm_resp.status_code}")
                        st.code(llm_resp.text[:1000])
                        st.stop()
                except requests.exceptions.RequestException as exc:
                    st.error(f"Mock LLM call failed: {exc}")
                    st.stop()

            st.success(f"Direct LLM completed in **{llm_ms:.2f} ms**")
            st.metric("Mock LLM (ms)", f"{llm_ms:.2f}", help="Client-side round-trip: client → network → AgentGateway → network → mock-llm → back. Includes client↔gateway network latency. Gateway-only duration is visible in agentgateway_request_duration_seconds_bucket (Grafana).")
            st.caption("⚠️ This is a **client-side** measurement and includes client↔gateway network latency. To isolate pure gateway processing time, use `agentgateway_request_duration_seconds_bucket` in Grafana.")
            with st.expander("LLM response"):
                try:
                    body = llm_resp.json()
                    reply = body.get("choices", [{}])[0].get("message", {}).get("content", "")
                    st.info(f"Echo reply preview: **{reply[:120]}{'…' if len(reply) > 120 else ''}**")
                    st.json(body)
                except Exception:
                    st.code(llm_resp.text[:500])

        # ── Full Chain (Scenario B) + Direct MCP ─────────────────────────
        else:
            session_headers = {**base_headers, "mcp-session-id": st.session_state.mcp_session_id}

            mcp_parts = []
            mcp_ms_total = 0.0
            mcp_responses = []
            for call_i in range(int(num_calls)):
                with st.spinner(f"MCP call {call_i + 1}/{int(num_calls)} — echo ({msg_kb} KB) …"):
                    try:
                        t_mcp = time.perf_counter()
                        mcp_resp = requests.post(
                            mcp_url,
                            json={"jsonrpc": "2.0", "id": call_i + 2, "method": "tools/call",
                                  "params": {"name": "echo", "arguments": {"message": echo_message}}},
                            headers=session_headers,
                            timeout=120,
                        )
                        call_ms = (time.perf_counter() - t_mcp) * 1000
                        mcp_ms_total += call_ms
                        mcp_resp.raise_for_status()
                        mcp_responses.append((call_i + 1, call_ms, mcp_resp.text))
                        for line in mcp_resp.text.splitlines():
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
                    except requests.exceptions.RequestException as exc:
                        st.error(f"MCP echo call {call_i + 1} failed: {exc}")
                        st.stop()

            mcp_ms = mcp_ms_total
            mcp_content = " ".join(mcp_parts)

            for call_num, call_ms, raw in mcp_responses:
                with st.expander(f"MCP response — call {call_num} ({call_ms:.2f} ms)"):
                    for line in raw.splitlines():
                        if line.startswith("data: "):
                            try:
                                st.json(json.loads(line[6:]))
                            except Exception:
                                st.code(line)
                            break

            if sr_profile == "Full Chain":
                with st.spinner(f"Forwarding {len(mcp_content):,} chars to mock LLM …"):
                    try:
                        t_llm = time.perf_counter()
                        llm_resp = requests.post(
                            f"{llm_base_url}{llm_path}/v1/chat/completions",
                            json={"model": "mock-gpt-4o-mini",
                                  "messages": [{"role": "user", "content": mcp_content[:llm_payload_b]}]},
                            headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
                            timeout=120,
                        )
                        llm_ms = (time.perf_counter() - t_llm) * 1000
                        if not llm_resp.ok:
                            st.error(f"Mock LLM call failed: HTTP {llm_resp.status_code}")
                            st.code(llm_resp.text[:1000])
                            st.stop()
                    except requests.exceptions.RequestException as exc:
                        st.error(f"Mock LLM call failed: {exc}")
                        st.stop()

                total_ms = mcp_ms + llm_ms
                st.success(f"Full chain completed in **{total_ms:.2f} ms**")
                col_a, col_b, col_c = st.columns(3)
                col_a.metric(f"MCP echo ×{int(num_calls)} (ms)", f"{mcp_ms:.2f}", help="Client-side round-trip: client → network → AgentGateway → network → mcp-everything → back. Includes client↔gateway network latency. Gateway-only duration is visible in agentgateway_request_duration_seconds_bucket (Grafana).")
                col_b.metric("Mock LLM (ms)", f"{llm_ms:.2f}", help="Client-side round-trip: client → network → AgentGateway → network → mock-llm → back. Includes client↔gateway network latency. Gateway-only duration is visible in agentgateway_request_duration_seconds_bucket (Grafana).")
                col_c.metric("Total (ms)", f"{total_ms:.2f}", help="Sum of all MCP echo calls + LLM call as measured client-side. Does not deduplicate network latency across hops.")
                st.caption("⚠️ These are **client-side** measurements and include client↔gateway network latency on each hop. To isolate pure gateway processing time, use `agentgateway_request_duration_seconds_bucket` in Grafana.")
                with st.expander("LLM response"):
                    try:
                        body = llm_resp.json()
                        reply = body.get("choices", [{}])[0].get("message", {}).get("content", "")
                        st.info(f"Echo reply preview: **{reply[:120]}{'…' if len(reply) > 120 else ''}**")
                        st.json(body)
                    except Exception:
                        st.code(llm_resp.text[:500])
            else:
                st.success(f"Direct MCP completed in **{mcp_ms:.2f} ms**")
                st.metric(f"MCP echo ×{int(num_calls)} (ms)", f"{mcp_ms:.2f}", help="Client-side round-trip: client → network → AgentGateway → network → mcp-everything → back. Includes client↔gateway network latency. Gateway-only duration is visible in agentgateway_request_duration_seconds_bucket (Grafana).")
                st.caption("⚠️ This is a **client-side** measurement and includes client↔gateway network latency. To isolate pure gateway processing time, use `agentgateway_request_duration_seconds_bucket` in Grafana.")

    st.markdown("---")
    st.markdown("**Hop Diagram**")
    if sr_profile == "Full Chain":
        if sr_scenario_a:
            st.code(
                "Standard Tool-Use Flow\n"
                "Client → AgentGateway /mock-openai → mock-llm [initial prompt]\n"
                "       → AgentGateway /mcp → mcp-everything [echo ×N]\n"
                "       → AgentGateway /mock-openai → mock-llm [tool result summary] → Client",
                language=None,
            )
        else:
            st.code(
                "Context-Augmented Flow (RAG style)\n"
                "Client → AgentGateway /mcp → mcp-everything [echo ×N]\n"
                "       → AgentGateway /mock-openai → mock-llm [echo] → Client",
                language=None,
            )
    elif sr_profile == "Direct MCP Baseline":
        st.code(
            "Client → AgentGateway /mcp → mcp-everything [echo ×N] → Client",
            language=None,
        )
    else:
        st.code(
            "Client → AgentGateway /mock-openai → mock-llm [echo] → Client",
            language=None,
        )

# ================================================================== #
#  TAB 2 — Locust Load Test launcher                                 #
# ================================================================== #
with tab_load:
    st.subheader("Load Test — Concurrent Users via Locust")
    st.caption(
        "Spawns a Locust subprocess that simulates N concurrent users hitting AgentGateway. "
        "Each user establishes its own MCP session on start (except Direct LLM Baseline). "
        "Choose a profile to isolate what you're measuring: full round-trip, MCP proxy only, or LLM hop only."
    )

    col1, col2, col3 = st.columns(3)
    num_users = col1.number_input("Concurrent users", 1, 1000, 10, key="lt_users")
    spawn_rate = col2.number_input("Spawn rate (users/s)", 1, 50, 2, key="lt_rate")
    duration = col3.number_input("Duration (s)", 10, 86400, 60, key="lt_dur")
    st.markdown("**Test profile**")
    pcol1, pcol2 = st.columns(2)
    with pcol1:
        profile = st.radio(
            "Profile",
            options=["Full Chain", "Direct MCP Baseline", "Direct LLM Baseline"],
            key="lt_profile",
            label_visibility="collapsed",
        )
    with pcol2:
        if profile == "Full Chain":
            if st.session_state.get("lt_flow", "Standard Tool-Use Flow") == "Standard Tool-Use Flow":
                st.info(
                    "**Standard Tool-Use Flow** — the LLM acts as orchestrator. "
                    "Each user: `/mcp initialize` once, then on every task: "
                    "1️⃣ `/mock-openai` (initial prompt) → "
                    "2️⃣ `/mcp tools/call echo` (tool execution) → "
                    "3️⃣ `/mock-openai` (tool result summary). "
                    "Captures 'Time to First Tool Call' as the key latency bottleneck."
                )
            else:
                st.info(
                    "**Context-Augmented Flow (RAG style)** — the agent fetches context first. "
                    "Each user: `/mcp initialize` once, then on every task: "
                    "1️⃣ `/mcp tools/call echo` (fetch context) → "
                    "2️⃣ `/mock-openai` (LLM with retrieved context). "
                    "End-to-end latency through both gateway routes on the shared gateway."
                )
        elif profile == "Direct MCP Baseline":
            st.info(
                "**Direct MCP Baseline** — `/mcp initialize` once per user, then "
                "`/mcp tools/call echo` only. No LLM hop. "
                "Isolates AgentGateway MCP proxy latency from LLM overhead."
            )
        else:
            st.info(
                "**Direct LLM Baseline** — no MCP session, no MCP hops. "
                "`/mock-openai chat/completions` only. "
                "Isolates AgentGateway LLM proxy latency with zero MCP overhead."
            )

    if profile == "Full Chain":
        _lt_flow = st.radio(
            "Flow",
            options=["Standard Tool-Use Flow", "Context-Augmented Flow (RAG Style)"],
            index=0,
            key="lt_flow",
            horizontal=True,
            help=(
                "**Standard Tool-Use Flow:** "
                "LLM receives the prompt first and decides which tool to call. "
                "Order: LLM call → MCP tool execution → LLM call with tool result.\n\n"
                "**Context-Augmented Flow (RAG Style):** "
                "Agent proactively fetches context from MCP before engaging the LLM. "
                "Order: MCP tool call → LLM call with retrieved context."
            ),
        )
        lt_scenario_a = (_lt_flow == "Standard Tool-Use Flow")
        lt_echo_kb = st.slider("MCP message size (KB)", min_value=32, max_value=256, value=32, step=8, key="lt_echo_kb")
        call_col1, call_col2 = st.columns(2)
        lt_num_calls = call_col1.number_input("MCP tool calls per task", min_value=1, max_value=20, value=1, step=1, key="lt_num_calls")
        lt_llm_calls = call_col2.number_input("LLM calls per step", min_value=1, max_value=20, value=1, step=1, key="lt_llm_calls")
        lt_llm_payload_b = 2048
    elif profile == "Direct MCP Baseline":
        lt_scenario_a = False
        lt_echo_kb = st.slider("MCP message size (KB)", min_value=32, max_value=256, value=32, step=8, key="lt_echo_kb")
        lt_num_calls = st.number_input("MCP tool calls per task", min_value=1, max_value=20, value=1, step=1, key="lt_num_calls")
        lt_llm_calls = 1
        lt_llm_payload_b = 2048
    else:
        lt_scenario_a = False
        lt_llm_payload_b = st.slider("LLM payload size (B)", min_value=1, max_value=2048, value=256, step=1, key="lt_llm_payload_b")
        lt_llm_calls = st.number_input("LLM calls per task", min_value=1, max_value=20, value=1, step=1, key="lt_llm_calls")
        lt_num_calls = 1
        lt_echo_kb = 32

    run_lt = st.button("Start Load Test", type="primary", key="start_lt")

    if "locust_proc" not in st.session_state:
        st.session_state.locust_proc = None
    if "locust_log" not in st.session_state:
        st.session_state.locust_log = []
    if "locust_csv_prefix" not in st.session_state:
        st.session_state.locust_csv_prefix = ""
    if "locust_test_meta" not in st.session_state:
        st.session_state.locust_test_meta = None
    if "locust_stop_pending" not in st.session_state:
        st.session_state.locust_stop_pending = False

    stop_placeholder = st.empty()
    if not st.session_state.locust_stop_pending:
        stop_lt = stop_placeholder.button("Stop", key="stop_lt")
    else:
        stop_lt = False

    output_box = st.empty()

    if run_lt:
        if not gateway_ip:
            st.error("Set Gateway IP in the sidebar first.")
        else:
            csv_prefix = os.path.join(tempfile.mkdtemp(), "locust")
            st.session_state.locust_csv_prefix = csv_prefix

            cmd = [
                sys.executable, "-m", "locust",
                "-f", os.path.join(os.path.dirname(__file__), "loadtest.py"),
                "--host", f"http://{mcp_gateway_ip}:{mcp_gateway_port}",
                "-u", str(int(num_users)),
                "-r", str(int(spawn_rate)),
                "-t", f"{int(duration)}s",
                "--csv", csv_prefix,
            ]
            cmd.append("--headless")

            env = os.environ.copy()
            env["MCP_ECHO_KB"] = str(int(lt_echo_kb))
            env["LLM_PAYLOAD_B"] = str(int(lt_llm_payload_b))
            env["MCP_PATH"] = mcp_path
            env["LLM_PATH"] = llm_path
            env["LLM_HOST"] = f"http://{llm_gateway_ip}:{llm_gateway_port}"
            env["MCP_NUM_CALLS"] = str(int(lt_num_calls))
            env["LLM_NUM_CALLS"] = str(int(lt_llm_calls))
            env["OPENAI_API_KEY"] = api_key
            env["LOCUST_STATS_FILE"] = csv_prefix + "_stats.json"
            env["LOCUST_PROFILE"] = (
                "chain" if profile == "Full Chain"
                else "mcp" if profile == "Direct MCP Baseline"
                else "llm"
            )
            env["LOCUST_SCENARIO"] = "a" if lt_scenario_a else "b"

            if profile == "Full Chain":
                flow_label = "Standard Tool-Use Flow" if lt_scenario_a else "Context-Augmented Flow (RAG Style)"
                profile_label = f"Full Chain — {flow_label}"
            else:
                profile_label = profile
            # Standard Tool-Use has 2 LLM steps (initial prompt + tool result summary)
            llm_steps = 2 if lt_scenario_a else 1
            st.session_state.locust_test_meta = {
                "profile_label": profile_label,
                "users": int(num_users),
                "spawn_rate": int(spawn_rate),
                "duration": int(duration),
                "mcp_calls": int(lt_num_calls) if profile in ("Full Chain", "Direct MCP Baseline") else None,
                "llm_calls_per_step": int(lt_llm_calls) if profile in ("Full Chain", "Direct LLM Baseline") else None,
                "total_llm_calls": int(lt_llm_calls) * llm_steps if profile in ("Full Chain", "Direct LLM Baseline") else None,
            }

            st.session_state.locust_log = []
            st.session_state.locust_stop_pending = False
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                env=env,
            )
            st.session_state.locust_proc = proc

            log_queue: queue.Queue = queue.Queue()

            def _reader(p, q):
                for line in iter(p.stdout.readline, ""):
                    # Locust uses \r for terminal overwrites; normalize so captured
                    # output doesn't concatenate the stats table onto the last log line.
                    line = line.replace('\r\n', '\n').replace('\r', '\n')
                    q.put(line)

            threading.Thread(target=_reader, args=(proc, log_queue), daemon=True).start()

            start_time = time.time()
            while proc.poll() is None and (time.time() - start_time) < duration + 10:
                while not log_queue.empty():
                    line = log_queue.get_nowait()
                    st.session_state.locust_log.append(line)
                visible = [l for l in st.session_state.locust_log if not l.startswith("[hop-timing]")]
                output_box.code("".join(visible[-60:]))
                time.sleep(0.5)

            # drain remaining output
            while not log_queue.empty():
                st.session_state.locust_log.append(log_queue.get_nowait())
            visible = [l for l in st.session_state.locust_log if not l.startswith("[hop-timing]")]
            output_box.code("".join(visible[-80:]))
            st.success("Load test complete.")
            st.caption(
                "⚠️ All latency metrics (Avg, p50, p95, p99) are **client-side** measurements and include "
                "client↔gateway network latency on each hop. "
                "To isolate pure gateway processing time, use `agentgateway_request_duration_seconds_bucket` in Grafana."
            )
            _show_locust_summary(st.session_state.locust_csv_prefix, st.session_state.locust_test_meta)

    if stop_lt and st.session_state.locust_proc:
        st.session_state.locust_proc.terminate()
        st.session_state.locust_stop_pending = True
        stop_placeholder.empty()
        warn_box = st.empty()
        warn_box.warning("Locust process terminated.")
        st.caption(
            "⚠️ All latency metrics (Avg, p50, p95, p99) are **client-side** measurements and include "
            "client↔gateway network latency on each hop. "
            "To isolate pure gateway processing time, use `agentgateway_request_duration_seconds_bucket` in Grafana."
        )
        _show_locust_summary(st.session_state.locust_csv_prefix, st.session_state.locust_test_meta)
        time.sleep(5)
        warn_box.empty()
        st.session_state.locust_stop_pending = False
        st.rerun()

    if st.session_state.locust_log:
        with st.expander("Full locust output"):
            st.code("".join(st.session_state.locust_log))

    st.markdown("---")
    st.markdown("**Hop Diagram — Load Test**")
    if profile == "Full Chain" and lt_scenario_a:
        st.code(
            "── Standard Tool-Use Flow ────────────────\n"
            "Client → AgentGateway /mock-openai\n"
            "       → mock-llm [initial prompt]\n"
            "       → AgentGateway /mcp\n"
            "       → mcp-everything [echo]\n"
            "       → AgentGateway /mock-openai\n"
            "       → mock-llm [tool result summary] → Client\n"
            "\n"
            "── Direct MCP Baseline ───────────────────\n"
            "Client → AgentGateway /mcp\n"
            "       → mcp-everything [echo] → Client\n"
            "\n"
            "── Direct LLM Baseline ───────────────────\n"
            "Client → AgentGateway /mock-openai\n"
            "       → mock-llm [echo mode] → Client",
            language=None,
        )
    else:
        st.code(
            "── Context-Augmented Flow (RAG style) ────\n"
            "Client → AgentGateway /mcp\n"
            "       → mcp-everything [echo]\n"
            "       → AgentGateway /mock-openai\n"
            "       → mock-llm [echo mode] → Client\n"
            "\n"
            "── Direct MCP Baseline ───────────────────\n"
            "Client → AgentGateway /mcp\n"
            "       → mcp-everything [echo] → Client\n"
            "\n"
            "── Direct LLM Baseline ───────────────────\n"
            "Client → AgentGateway /mock-openai\n"
            "       → mock-llm [echo mode] → Client",
            language=None,
        )


