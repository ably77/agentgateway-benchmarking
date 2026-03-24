# Scenario 2: Multi-Client Shared Centralized Gateway

> **Goal**: Measure gateway throughput and latency under concurrent load from multiple independent clients sharing a single AgentGateway. Observe any cross-client interference.

## Architecture

```
                   ┌──────────────────────────────────────────────────────┐
                   │  Kubernetes Cluster (Region R1 / AZ1)                 │
                   │  Namespace: ai-platform                               │
                   │                                                        │
  Client 1 ────────┼─┐                                                     │
                   │ ├──▶ ┌───────────────────────────┐                   │
  Client 2 ────────┼─┤    │  AgentGateway (shared)    │                   │
                   │ ├──▶ │  ┌──────────────────────┐ │                   │
  Client 3 ────────┼─┘    │  │ /mcp  HTTPRoute       │ │                   │
                   │       │  └──────────┬───────────┘ │                   │
                   │       │             │              │                   │
                   │       │  ┌──────────▼───────────┐ │                   │
                   │       │  │ MCP Everything Server │ │                   │
                   │       │  │  (sampleLLM tool ──┐) │ │                   │
                   │       │  └────────────────────│─┘ │                   │
                   │       │                        │    │                   │
                   │       │  ┌─────────────────────▼──┐ │                   │
                   │       │  │ /mock-openai HTTPRoute  │ │                   │
                   │       │  └──────────┬─────────────┘ │                   │
                   │       └─────────────┼───────────────┘                   │
                   │                     ▼                                    │
                   │              mock-llm (llm-d-inference-sim)              │
                   └──────────────────────────────────────────────────────────┘
```

### Hop Path (5 hops — N concurrent client streams)

```
Client-1 ─┐
Client-2 ─┼─→ agw /mcp → mcp-everything sampleLLM → agw /mock-openai → mock-llm
Client-N ─┘
```

| Hop | From | To | Via |
|-----|------|----|-----|
| 1 | Client (agent-N ns) | AgentGateway `/mcp` | MCP over streamable-HTTP |
| 2 | AgentGateway | MCP Everything Server | Proxied MCP |
| 3 | MCP Server | AgentGateway `/mock-openai` | sampleLLM back-call |
| 4 | AgentGateway | mock-llm (llm-d-inference-sim) | Proxied OpenAI-compatible |
| 5 | mock-llm | MCP Server → Client | Response path |

All N clients transit the **same AgentGateway** instance simultaneously — measuring gateway performance under concurrent multi-client load.

---

## Components

| Component | Namespace | Replicas | Notes |
|-----------|-----------|----------|-------|
| `loadgen-client-1` | `agent-1` | 1 | Streamlit UI + Locust load driver |
| `loadgen-client-2` | `agent-2` | 1 | Streamlit UI + Locust load driver |
| `loadgen-client-3` | `agent-3` | 1 | Streamlit UI + Locust load driver |
| `loadgen-client-4` | `agent-4` | 1 | Optional 4th client |
| `loadgen-client-5` | `agent-5` | 1 | Optional 5th client |
| `agentgateway` | `agentgateway-system` | 2 | Shared gateway for all clients |
| `mcp-server-everything` | `ai-platform` | 2 | Reference MCP server |
| `mock-llm` | `ai-platform` | 2 | llm-d-inference-sim (mock OpenAI API) |
| `prometheus` | `monitoring` | 1 | Scrapes agentgateway metrics |
| `grafana` | `monitoring` | 1 | Per-hop dashboards |

---

## Prerequisites

- Completed [Enterprise AgentGateway installation](./installation-steps/001-set-up-enterprise-agentgateway.md) OR a running cluster with:
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

The script walks through steps interactively:
1. Configure AgentGateway proxy service type (LoadBalancer or ClusterIP)
2. Deploy MCP everything server + mock-llm to `ai-platform` namespace
3. Apply AgentGateway HTTPRoutes and backends
4. Retrieve Gateway IP (or set up port-forward)
5. Choose client count (1–5, default 3)
6. Choose client mode (local Python or k8s in-cluster)
7. Print per-client port-forward commands / open browser tabs

---

## Accessing Client UIs (k8s mode)

After running the setup script in k8s mode, use the printed port-forward commands:

```bash
kubectl port-forward -n agent-1 svc/loadgen-client-1 8501:8501 &
kubectl port-forward -n agent-2 svc/loadgen-client-2 8502:8501 &
kubectl port-forward -n agent-3 svc/loadgen-client-3 8503:8501 &

open http://localhost:8501  # Client 1
open http://localhost:8502  # Client 2
open http://localhost:8503  # Client 3
```

Launch a locust run from each tab simultaneously to generate concurrent multi-client load.

---

## Observability

```bash
# AgentGateway request logs
kubectl logs -n agentgateway-system deploy/agentgateway -f

# MCP server logs
kubectl logs -n ai-platform deploy/mcp-server-everything -f

# Prometheus port-forward
kubectl port-forward -n monitoring svc/grafana-prometheus-kube-pr-prometheus 9090:9090
open http://localhost:9090
```

Key Prometheus queries:
```promql
# P99 latency per route (gateway-side, excludes client↔LB hop)
histogram_quantile(0.99, sum by (le, route) (rate(agentgateway_request_duration_seconds_bucket[5m])))

# Request throughput per route (requests/sec) — all clients combined
sum by (route) (rate(agentgateway_requests_total[1m]))

# Error rate per route
sum by (route) (rate(agentgateway_requests_total{status=~"5.."}[1m]))

# Total concurrent request rate (all clients)
sum(rate(agentgateway_requests_total[1m]))
```

---

## File Structure

```
scenario-2/
├── description.md
├── README.md
├── setup-script.sh
├── cleanup.sh
├── k8s/
│   ├── agent-1-deployment.yaml
│   ├── agent-2-deployment.yaml
│   ├── agent-3-deployment.yaml
│   ├── agent-4-deployment.yaml
│   ├── agent-5-deployment.yaml
│   ├── mcp-everything-deployment.yaml
│   └── mock-llm-deployment.yaml
├── route/
│   ├── mcp-everything-httproute.yaml
│   ├── mcp-everything-backend.yaml
│   ├── mock-openai-httproute.yaml
│   └── mock-openai-backend.yaml
└── installation-steps/
    ├── 001-set-up-enterprise-agentgateway.md
    ├── 002-set-up-monitoring-tools.md
    └── lib/
        └── observability/
            └── agentgateway-grafana-dashboard-v1.json
```
