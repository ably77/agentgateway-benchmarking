# Scenario 1: Colocated Microgateway Load Test

> **Goal**: Measure "best-case" overhead when everything is local — all hops in the same cluster / AZ.

## Architecture

```
                   ┌──────────────────────────────────────────────────┐
                   │  Kubernetes Cluster (Region R1 / AZ1)             │
                   │  Namespace: ai-platform                           │
                   │                                                    │
  HTTP Request     │  ┌──────────┐    ┌───────────────────────────┐   │
  ─────────────────┼─▶│  Agent   │───▶│  AgentGateway (shared)    │   │
                   │  │  (CrewAI)│    │  ┌──────────────────────┐ │   │
                   │  └──────────┘    │  │ /mcp  HTTPRoute       │ │   │
                   │       ▲          │  └──────────┬───────────┘ │   │
                   │       │          │             │              │   │
                   │       │          │  ┌──────────▼───────────┐ │   │
                   │       │          │  │ MCP Everything Server │ │   │
                   │       │          │  │  (sampleLLM tool ──┐) │ │   │
                   │       │          │  └──────────────────── │ ┘ │   │
                   │       │          │                        │    │   │
                   │       │          │  ┌─────────────────────▼──┐ │   │
                   │       └──────────│──│ /mock-openai HTTPRoute  │ │   │
                   │     LLM response │  └────────────────────────┘ │   │
                   │                  └───────────────────────────────┘   │
                   └──────────────────────────────────────────────────┘
```

### Hop Path (5 hops)

```
Client → Agent → agw /mcp → mcp-everything sampleLLM → agw /mock-openai → mock-llm
```

| Hop | From | To | Via |
|-----|------|----|-----|
| 1 | Client | Agent Pod | HTTP |
| 2 | Agent | AgentGateway `/mcp` | MCP over streamable-HTTP |
| 3 | AgentGateway | MCP Everything Server | Proxied MCP |
| 4 | MCP Server | AgentGateway `/mock-openai` | sampleLLM back-call |
| 5 | AgentGateway | mock-llm (llm-d-inference-sim) | Proxied OpenAI-compatible |

Both hop 2→3 and hop 4→5 transit the **same AgentGateway** instance — different HTTPRoutes, same Gateway, demonstrating the "shared gateway" (colocated microgateway) pattern.

---

## Components

| Component | Replicas | Notes |
|-----------|----------|-------|
| `agent` (CrewAI) | 2–10 (load test) | Streamlit UI + locust load driver |
| `agentgateway` | 2 | Handles both `/mcp` and `/mock-openai` routes |
| `mcp-server-everything` | 2 | Reference MCP server; `sampleLLM` triggers LLM back-call |
| `prometheus` | 1 | Scrapes agentgateway metrics |
| `grafana` | 1 | Per-hop dashboards |

---

## Prerequisites

- Completed [Enterprise AgentGateway workshop](../fe-enterprise-agentgateway-workshop) OR a running cluster with:
  - `agentgateway-system` namespace and Gateway named `agentgateway-proxy`
  - `AgentgatewayBackend` CRD installed
- `kubectl` configured against the target cluster
- `helm`, `jq`, `curl`, Python 3.11+

---

## Quick Start

```bash
chmod +x setup-script.sh
./setup-script.sh
```

The script walks through six steps interactively:
1. Deploy MCP everything server to `ai-platform` namespace
2. Apply AgentGateway HTTPRoutes and backends
3. Deploy mock-llm (llm-d-inference-sim)
4. Set up Python virtual environment
5. Launch Streamlit single-agent UI (port 8501)
6. *(Optional)* Run locust load test (port 8089)

---

## Running the Load Test Directly

```bash
# Single-agent smoke test
python agent/app.py

# Locust load test (from agent/ dir with venv active)
locust -f agent/loadtest.py \
  --headless -u 10 -r 2 -t 60s \
  --host http://<GATEWAY_IP>:8080
```

---

## Observability

```bash
# AgentGateway request logs (hop timing)
kubectl logs -n agentgateway-system deploy/agentgateway -f

# MCP server logs
kubectl logs -n ai-platform deploy/mcp-server-everything -f

# Prometheus metrics
kubectl port-forward -n monitoring svc/prometheus 9090:9090
open http://localhost:9090

# Grafana (if deployed)
kubectl port-forward -n monitoring svc/grafana 3000:3000
open http://localhost:3000
```

Key Prometheus queries:
```promql
# P99 latency per route
histogram_quantile(0.99, sum(rate(agentgateway_request_duration_seconds_bucket[5m])) by (le, route))

# Requests per second
sum(rate(agentgateway_requests_total[1m])) by (route)

# Error rate
sum(rate(agentgateway_requests_total{status=~"5.."}[1m])) by (route)
```

---

## File Structure

```
scenario-1/
├── description.md          # Scenario specification
├── README.md               # This file
├── setup-script.sh          # One-shot setup & teardown
├── agent/
│   ├── app.py              # Streamlit UI (single-agent + load test launcher)
│   ├── loadtest.py         # Locust load test definition
│   └── requirements.txt    # Python dependencies
├── k8s/
│   └── mcp-everything-deployment.yaml  # MCP everything server + service
└── route/
    ├── mock-openai-httproute.yaml       # /mock-openai route (mock LLM proxy)
    ├── mock-openai-backend.yaml        # mock-llm AgentgatewayBackend
    ├── mcp-everything-httproute.yaml   # /mcp route (MCP proxy)
    └── mcp-everything-backend.yaml     # MCP everything AgentgatewayBackend
```
