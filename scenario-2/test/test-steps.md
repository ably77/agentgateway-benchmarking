# Scenario 2 Test Steps

## Setup

Scale MCP and LLM deployments for load testing:
```bash
kubectl scale -n ai-platform deploy/mcp-server-everything --replicas 3
kubectl scale -n ai-platform deploy/mock-llm --replicas 3
```

## Client Configuration

Configure the following in **each** Streamlit UI (Client 1, 2, 3):
- Use default shared gateway
- Gateway IP / Host: `agentgateway-proxy.agentgateway-system.svc.cluster.local`
- Gateway Port: `8000`
- MCP Path: `/mcp`
- LLM Path: `/mock-openai`

Access each client UI via port-forward:
```bash
kubectl port-forward -n agent-1 svc/loadgen-client-1 8501:8501 &
kubectl port-forward -n agent-2 svc/loadgen-client-2 8502:8501 &
kubectl port-forward -n agent-3 svc/loadgen-client-3 8503:8501 &

open http://localhost:8501  # Client 1
open http://localhost:8502  # Client 2
open http://localhost:8503  # Client 3
```

## Load Test Parameters

Run simultaneously across all 3 clients:
```
50 concurrent users (per client → 150 total)
Spawn rate: 5 users/s
Duration: 300 seconds (5 mins)
```

## Test Cases

Run each test case across **all clients simultaneously**:

- **Direct LLM Baseline** (1x LLM call)
  - LLM Payload size: 256 B
- **Direct MCP Baseline** (1x MCP tool call)
  - MCP Payload Size: 32 KB
- **Full Chain — Standard Tool Use Flow**
  - 1x LLM call + 2x MCP Tool Calls + 1x LLM call
  - MCP Payload Size: 32 KB
- **Full Chain — Context-Augmented Flow** (RAG style)
  - 2x MCP tool calls + 1x LLM call
  - MCP Payload Size: 32 KB

## After Each Test

Rollout restart the backend servers before the next test run:
```bash
kubectl rollout restart -n ai-platform deployment mcp-server-everything
kubectl rollout restart -n ai-platform deployment mock-llm
```

## Observability

- Output from each Streamlit / Locust summary table (Client 1, 2, 3)
- Grafana Dashboards (aggregate + per-client breakdown if available)
- Prometheus metrics — compare total throughput vs. scenario-1a single-client baseline

Key queries:
```promql
# Total request rate across all clients
sum(rate(agentgateway_requests_total[1m]))

# P99 latency per route (all clients combined)
histogram_quantile(0.99, sum by (le, route) (rate(agentgateway_request_duration_seconds_bucket[5m])))

# Error rate
sum by (route) (rate(agentgateway_requests_total{status=~"5.."}[1m]))
```
