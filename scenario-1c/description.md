Scenario 1c: Colocated microgateway — external client via LoadBalancer (single cluster / same AZ)
Goal: measure the NLB hop cost by connecting through the external LoadBalancer IP.

Hypothesis: consistent NLB overhead added on top of scenario 1a results.

Kubernetes Cluster (Region R1 / AZ1)
Namespace: ai-platform
Single client (agent-1 namespace) — connects via LoadBalancer external IP
agentgateway-proxy (2 replicas — shared, same as 1a)
mcp-server-everything
prometheus, Grafana

Hop path (6 hops): Client → NLB → agw /mcp → MCP Server → agw /mock-openai → LLM

Key difference from 1a: client routes through the external LoadBalancer so the NLB hop is
included in all measurements. All gateway, route, backend, and monitoring resources are
identical to Scenario 1a.

Client deployment options:
  - Local (laptop): internet + NLB + gateway overhead
  - Separate k8s cluster: NLB + gateway overhead (no internet variance)
