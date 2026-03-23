Scenario 1: Colocated microgateway (single cluster / same AZ)
Goal: measure “best case” overhead when everything is local.

Derive labs from /Users/alexly-solo/Desktop/solo/solo-github/fe-enterprise-agentgateway-workshop

Kubernetes Cluster (Region R1 / AZ1)
Namespace: ai-platform 
kagent-controller, kagent-ui
agent-pods (2–10 replicas)
agentgateway-mcp (2 replicas +  local MCP governance - same gateway different httproute)
agentgateway-llm (2 replicas + outbound LLM governance - same gateway different httproute)
mcp-server-github, mcp-server-prometheus, mcp-server-internalapi
prometheus, Grafana
Hop path (4–6 hops)API → Agent → MCP Gateway → MCP Server → agentgateway → LLM → back
Emphasis: end‑to‑end tracing + per‑hop timing and overhead when “co‑living together.” 
