Scenario 2: Multi-Client Shared Centralized Gateway
Goal: measure gateway performance under concurrent load from multiple independent clients sharing a single AgentGateway.

Kubernetes Cluster (Region R1 / AZ1)
Namespace: ai-platform
AgentGateway (shared, single instance)
mcp-server-everything (2 replicas)
mock-llm / llm-d-inference-sim (2 replicas)
3–5 independent loadgen clients in separate namespaces (agent-1 … agent-N)
prometheus, Grafana

Hop path (5 hops, N concurrent client streams):
Client-1 ─┐
Client-2 ─┼─→ agw /mcp → mcp-everything sampleLLM → agw /mock-openai → mock-llm
Client-3 ─┘

Emphasis: gateway throughput and latency under concurrent multi-client load; cross-client interference detection.
