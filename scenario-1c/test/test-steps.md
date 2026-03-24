# scale MCP deployment
kubectl scale -n ai-platform deploy/mcp-server-everything --replicas 3

# Client connects via the LoadBalancer external IP — NLB hop is included in all measurements.

## Option A — Local mode (laptop → internet → NLB → gateway)
# Streamlit UI launched by setup-script.sh at http://localhost:8501
# GATEWAY_IP is pre-set to the LB IP by the script.

## Option B — k8s mode (separate cluster → NLB → gateway)
# Port-forward to the client UI from the client cluster context
kubectl --context <client-context> port-forward -n agent-1 svc/loadgen-client 8501:8501

# Configure Streamlit UI
- Gateway IP / Host: <LoadBalancer external IP>   ← pre-filled by setup-script.sh
- Gateway Port: 8080
- MCP Path: /mcp
- LLM Path: /mock-openai

# Test
50 concurrent users
Spawn rate 5 users/s
Duration 300 seconds (5 mins)

- Direct LLM Baseline (1x LLM call)
    - LLM Payload size: 256 B
- Direct MCP Baseline (1x MCP tool call)
    - MCP Payload Size: 32 KB
- Full Chain
    - Standard Tool Use Flow
        - 1x LLM call + 2x MCP Tool Calls x 1x LLM call
        - MCP Payload Size: 32 KB
    - Context-Augmented Flow (RAG style)
        - 2x MCP tool calls x 1x LLM call
        - MCP Payload Size: 32 KB

# After each test
Rollout restart the backend servers
```
kubectl rollout restart -n ai-platform deployment mcp-server-everything
kubectl rollout restart -n ai-platform deployment mock-llm
```

# Observability
- Output from Streamlit / Locust summary tables
- Grafana Dashboards (same dashboard as Scenario 1a — no changes required)
- Prometheus metrics
