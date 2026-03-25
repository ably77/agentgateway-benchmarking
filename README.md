# AgentGateway Benchmarking

Performance benchmarks for [AgentGateway](https://agentgateway.dev) across different deployment topologies.

## Scenarios

| Scenario | Description |
|----------|-------------|
| [Scenario 0 — Baseline](./scenario-0-baseline/) | Direct LLM and MCP calls with no proxy. Establishes reference latency for all hops. |
| [Scenario 1a — Shared Proxy](./scenario-1a/) | Colocated microgateway with a single shared proxy for LLM and MCP traffic. |
| [Scenario 1b — Isolated Proxies](./scenario-1b/) | Colocated microgateway with dedicated proxies for LLM and MCP. |
| [Scenario 2 — Multi-Client](./scenario-2/) | Multiple clients sharing a single colocated proxy. |
| [Scenario 3 — Cross-Region](./scenario-3/) | External client routed through a cloud load balancer to measure NLB hop cost. |

## Getting Started

1. Provision infrastructure — see [`gke/`](./gke/) for cluster setup
2. Review [common requirements](./common-requirements.md)
3. Start with **Scenario 0 — Baseline** — each subsequent scenario builds on the previous one

## Repository Structure

```
├── README.md
├── common-requirements.md
├── gke/                        # Cluster provisioning guides
├── client/                     # Load test client (Locust-based)
├── images/                     # Shared architecture diagrams
├── scenario-0-baseline/        # No-proxy baseline
├── scenario-1a/                # Shared proxy
├── scenario-1b/                # Isolated proxies
├── scenario-2/                 # Multi-client shared proxy
└── scenario-3/                 # Cross-region / external client
```
