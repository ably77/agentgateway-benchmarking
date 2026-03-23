# scale MCP deployment down to 1 replica
kubectl scale -n ai-platform deploy/mcp-server-everything --replicas 1

**Note**: Required for direct (bypass) tests. The MCP server does not share session state across
replicas — with multiple pods, the Kubernetes Service load-balances requests round-robin, so an
`initialize` call may land on pod A while subsequent `tools/call` requests hit pod B, which has
no record of that session and returns 400. Agentgateway handles session pinning automatically
(via `AgentgatewayBackend` label-selector), but when bypassing it you must ensure all requests
go to the same pod by running a single replica.

# Configure the following in Streamlit UI
Un-select Shared Gateway checkbox

Direct backend (bypass agentgateway — zero-gateway baseline):
    MCP:  host=mcp-server-everything.ai-platform.svc.cluster.local  port=8080  MCP path=/mcp
    LLM:  host=mock-llm.ai-platform.svc.cluster.local               port=8080  LLM path=(leave blank)

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