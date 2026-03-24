Scenario 1b: Colocated microgateway with dedicated proxies (single cluster / same AZ)
Goal: measure latency difference between dedicated vs. shared proxy (Scenario 1a).

Hypothesis: negligible performance difference; operational isolation is the value add.

Kubernetes Cluster (Region R1 / AZ1)
Namespace: ai-platform
agent-pods (2–10 replicas)
agentgateway-proxy-mcp (2 replicas — MCP traffic only)
agentgateway-proxy-llm (2 replicas — LLM traffic only)
mcp-server-everything
prometheus, Grafana

Hop path (5 hops): Client → Agent → agw-mcp /mcp → MCP Server → agw-llm /mock-openai → LLM

Key difference from 1a: two separate Gateway resources and proxy deployments instead of one shared gateway.
Dashboard is reused unchanged — PodMonitor selects both proxy pods via matchExpressions.
