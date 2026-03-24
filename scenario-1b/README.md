# Scenario 1b: Colocated Microgateway — Dedicated Proxies

> **Goal**: Measure latency differences when using **dedicated proxies** vs. the shared proxy in Scenario 1a. Hypothesis: negligible performance difference; operational isolation is the value add.

## Architecture

```
                   ┌──────────────────────────────────────────────────┐
                   │  Kubernetes Cluster (Region R1 / AZ1)             │
                   │  Namespace: ai-platform                           │
                   │                                                    │
  HTTP Request     │  ┌──────────┐    ┌──────────────────────────────┐ │
  ─────────────────┼─▶│  Agent   │───▶│ AgentGateway (MCP)           │ │
                   │  │  (CrewAI)│    │  agentgateway-proxy-mcp      │ │
                   │  └──────────┘    │  ┌──────────────────────────┐│ │
                   │       ▲          │  │ /mcp  HTTPRoute           ││ │
                   │       │          │  └──────────┬───────────────┘│ │
                   │       │          └─────────────│────────────────┘ │
                   │       │                        │                   │
                   │       │          ┌─────────────▼────────────────┐ │
                   │       │          │  MCP Everything Server        │ │
                   │       │          │  (sampleLLM tool ──┐)         │ │
                   │       │          └────────────────────│──────────┘ │
                   │       │                               │             │
                   │       │          ┌────────────────────▼──────────┐ │
                   │       └──────────│ AgentGateway (LLM)            │ │
                   │     LLM response │  agentgateway-proxy-llm       │ │
                   │                  │  ┌──────────────────────────┐ │ │
                   │                  │  │ /mock-openai  HTTPRoute   │ │ │
                   │                  │  └──────────────────────────┘ │ │
                   │                  └───────────────────────────────┘ │
                   └──────────────────────────────────────────────────┘
```

### Hop Path (5 hops)

```
Client → Agent → agw-mcp /mcp → mcp-everything sampleLLM → agw-llm /mock-openai → mock-llm
```

| Hop | From | To | Via |
|-----|------|----|-----|
| 1 | Client | Agent Pod | HTTP |
| 2 | Agent | `agentgateway-proxy-mcp` `/mcp` | MCP over streamable-HTTP |
| 3 | AgentGateway (MCP) | MCP Everything Server | Proxied MCP |
| 4 | MCP Server | `agentgateway-proxy-llm` `/mock-openai` | sampleLLM back-call |
| 5 | AgentGateway (LLM) | mock-llm (llm-d-inference-sim) | Proxied OpenAI-compatible |

Hop 2→3 transits **`agentgateway-proxy-mcp`** and hop 4→5 transits **`agentgateway-proxy-llm`** — two separate Gateway deployments, demonstrating the "dedicated proxy" (isolated microgateway) pattern.

---

## Difference from Scenario 1a

| | Scenario 1a | Scenario 1b |
|-|-------------|-------------|
| Gateway resources | 1 (`agentgateway-proxy`) | 2 (`agentgateway-proxy-mcp`, `agentgateway-proxy-llm`) |
| Proxy deployments | 1 shared | 2 dedicated |
| Gateway services | 1 LoadBalancer | 2 LoadBalancers |
| HTTPRoutes | 2 routes on same gateway | 1 route per gateway |
| Dashboard | Shared | Shared (unchanged) |

---

## Components

| Component | Replicas | Notes |
|-----------|----------|-------|
| `agent` (CrewAI) | 2–10 (load test) | Streamlit UI + locust load driver |
| `agentgateway-proxy-mcp` | 2 | Handles `/mcp` routes only |
| `agentgateway-proxy-llm` | 2 | Handles `/mock-openai` routes only |
| `mcp-server-everything` | 2 | Reference MCP server; `sampleLLM` triggers LLM back-call |
| `prometheus` | 1 | Scrapes both agentgateway proxies |
| `grafana` | 1 | Per-hop dashboards (same dashboard as 1a) |

---

## Prerequisites

- Completed [Enterprise AgentGateway workshop](../fe-enterprise-agentgateway-workshop) OR a running cluster with:
  - `agentgateway-system` namespace
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
  --host http://<MCP_GATEWAY_IP>:8080
```

---

## Observability

```bash
# AgentGateway MCP proxy request logs
kubectl logs -n agentgateway-system deploy/agentgateway-proxy-mcp -f

# AgentGateway LLM proxy request logs
kubectl logs -n agentgateway-system deploy/agentgateway-proxy-llm -f

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
# P99 latency per route (both proxies)
histogram_quantile(0.99, sum(rate(agentgateway_request_duration_seconds_bucket[5m])) by (le, route))

# Requests per second per proxy
sum(rate(agentgateway_requests_total[1m])) by (route, pod)

# Error rate
sum(rate(agentgateway_requests_total{status=~"5.."}[1m])) by (route)
```

---

## File Structure

```
scenario-1b/
├── description.md          # Scenario specification
├── README.md               # This file
├── setup-script.sh         # One-shot setup & teardown
├── cleanup.sh              # Standalone cleanup
├── gke/
│   └── scenario-1b-gke.md  # GKE cluster setup for this scenario
├── k8s/
│   ├── agent-deployment.yaml            # Loadgen client (GATEWAY_IP → proxy-mcp)
│   ├── mcp-everything-deployment.yaml   # MCP everything server + service
│   └── mock-llm-deployment.yaml         # Mock LLM server + service
├── installation-steps/
│   ├── 001-set-up-enterprise-agentgateway.md  # Deploys two dedicated Gateway resources
│   ├── 002-set-up-monitoring-tools.md          # PodMonitor for both proxies
│   └── lib/observability/
│       └── agentgateway-grafana-dashboard-v1.json  # Unchanged from 1a
└── route/
    ├── mock-openai-httproute.yaml       # /mock-openai → agentgateway-proxy-llm
    ├── mock-openai-backend.yaml         # mock-llm AgentgatewayBackend
    ├── mcp-everything-httproute.yaml    # /mcp → agentgateway-proxy-mcp
    └── mcp-everything-backend.yaml      # MCP everything AgentgatewayBackend
```
