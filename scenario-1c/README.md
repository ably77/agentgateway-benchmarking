# Scenario 1c: Colocated Microgateway — External Client via LoadBalancer

> **Goal**: Measure the NLB hop cost by routing the client through the external LoadBalancer IP rather than the internal cluster DNS. Latency delta vs Scenario 1a = NLB overhead.

## Architecture

```
                   ┌──────────────────────────────────────────────────┐
                   │  Kubernetes Cluster (Region R1 / AZ1)             │
  HTTP Request     │                                                    │
  ─────────────────┼──▶ NLB ──▶ ┌───────────────────────────┐        │
  Client           │             │  AgentGateway (shared)    │        │
  (external)       │             │  ┌──────────────────────┐ │        │
                   │             │  │ /mcp  HTTPRoute       │ │        │
                   │             │  └──────────┬───────────┘ │        │
                   │             │             │              │        │
                   │             │  ┌──────────▼───────────┐ │        │
                   │             │  │ MCP Everything Server │ │        │
                   │             │  │  (sampleLLM tool ──┐) │ │        │
                   │             │  └──────────────────── │ ┘ │        │
                   │             │                        │    │        │
                   │      ▲      │  ┌─────────────────────▼──┐ │        │
                   │      │      │  │ /mock-openai HTTPRoute  │ │        │
                   │      └──────│──└────────────────────────┘ │        │
                   │  LLM resp.  └───────────────────────────────┘        │
                   └──────────────────────────────────────────────────┘
```

### Hop Path (6 hops — same as 1a + NLB)

```
Client → NLB → agw /mcp → mcp-everything sampleLLM → agw /mock-openai → mock-llm
```

| Hop | From | To | Via |
|-----|------|----|-----|
| 1 | Client | NLB | External network |
| 2 | NLB | AgentGateway `/mcp` | MCP over streamable-HTTP |
| 3 | AgentGateway | MCP Everything Server | Proxied MCP |
| 4 | MCP Server | AgentGateway `/mock-openai` | sampleLLM back-call |
| 5 | AgentGateway | mock-llm (llm-d-inference-sim) | Proxied OpenAI-compatible |

---

## Difference from Scenario 1a

| | Scenario 1a | Scenario 1c |
|-|-------------|-------------|
| Client connects via | `agentgateway-proxy` cluster DNS (internal) | LoadBalancer external IP |
| NLB hop measured | No — short-circuited by kube-proxy | Yes |
| Gateway | 1 shared `agentgateway-proxy` (unchanged) | 1 shared `agentgateway-proxy` (unchanged) |
| HTTPRoutes | `/mcp`, `/mock-openai` (unchanged) | `/mcp`, `/mock-openai` (unchanged) |

---

## Client Deployment Options

### Option 1 — Local (laptop → internet → NLB)
Measures: gateway overhead + internet latency + NLB

### Option 2 — Separate k8s cluster (cluster-B → NLB)
Measures: gateway overhead + NLB (no internet variance). The setup script lists all available `kubectl` contexts and lets you pick the client cluster. If you pick the same context as the gateway cluster, kube-proxy will short-circuit the NLB and you'll get the same result as 1a.

---

## Components

| Component | Replicas | Notes |
|-----------|----------|-------|
| `agent` (agent-1) | 1 | Streamlit UI + locust |
| `agentgateway` | 2 | Handles `/mcp` and `/mock-openai` — unchanged from 1a |
| `mcp-server-everything` | 2 | Reference MCP server |
| `prometheus` | 1 | Scrapes agentgateway metrics |
| `grafana` | 1 | Dashboard (unchanged from 1a) |

---

## Quick Start

```bash
chmod +x setup-script.sh
./setup-script.sh
```

---

## File Structure

```
scenario-1c/
├── description.md
├── README.md
├── setup-script.sh
├── cleanup.sh
├── gke/
│   └── scenario-1c-gke.md
├── k8s/
│   ├── agent-deployment.yaml           # Single client (agent-1), GATEWAY_IP patched at deploy time
│   ├── mcp-everything-deployment.yaml  # Unchanged from 1a
│   └── mock-llm-deployment.yaml        # Unchanged from 1a
├── installation-steps/
│   ├── 001-set-up-enterprise-agentgateway.md  # Unchanged from 1a
│   ├── 002-set-up-monitoring-tools.md          # Unchanged from 1a
│   └── lib/observability/
│       └── agentgateway-grafana-dashboard-v1.json  # Unchanged from 1a
└── route/
    ├── mock-openai-httproute.yaml    # Unchanged from 1a
    ├── mock-openai-backend.yaml      # Unchanged from 1a
    ├── mcp-everything-httproute.yaml # Unchanged from 1a
    └── mcp-everything-backend.yaml   # Unchanged from 1a
```
