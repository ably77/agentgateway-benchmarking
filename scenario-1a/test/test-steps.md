# scale MCP deployment down to 1 replica
kubectl scale -n ai-platform deploy/mcp-server-everything --replicas 3

# Configure the following in Streamlit UI
- Use default shared gateway
- Gateway IP / Host: agentgateway-proxy.agentgateway-system.svc.cluster.local
- Gateway Port: 8000
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
- Grafana Dashboards
- Prometheus metrics