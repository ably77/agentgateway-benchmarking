# Scenario 1a - Colocated Microgateway: GKE Cluster Setup

## Architecture
- Single cluster, single region, single availability zone
- 3 isolated node groups (one per logical tier)
- Shared proxy (Agentgateway handles both MCP + LLM routing)
- Single client

```
Node Group 1 (Zone A): ns=agent-1         → Client-1
Node Group 2 (Zone A): ns=agentgateway-system → Agentgateway (MCP + LLM)
Node Group 3 (Zone A): ns=capability-1    → MCP Server (mcp-everything) + mock-llm-d
```

---

## Set core cluster variables

```bash
GKE_CLUSTER_NAME="ly-gke-benchmark-scenario1a"
GKE_CLUSTER_ZONE="us-east1-b"
GKE_PROJECT="field-engineering-us"
CLUSTER_VERSION="1.33.5-gke.2469000"
MAIN_MACHINE_TYPE="n2-standard-4"
COMMON_LABELS="purpose=pre-sales,expiration=na,team=fe-presale,created-by=alex_ly,customer=internal"
```

---

## Create Cluster (minimal default pool)

```bash
gcloud container clusters create ${GKE_CLUSTER_NAME} \
  --cluster-version ${CLUSTER_VERSION} \
  --no-enable-autoupgrade \
  --machine-type=${MAIN_MACHINE_TYPE} \
  --num-nodes=1 \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT} \
  --node-labels ${COMMON_LABELS} \
  --labels application=agentgateway-benchmark,${COMMON_LABELS} \
  --logging NONE \
  --spot
```

---

## Node Group 1 — Agent (Client-1)
> Namespace: `agent-1`

```bash
GKE_NODE_POOL_NAME="agent-scenario1a"
POOL_ZONE="${GKE_CLUSTER_ZONE}"
POOL_MACHINE_TYPE="n2-standard-4"
POOL_NUM_NODES="1"
POOL_MIN_NODES="1"
POOL_MAX_NODES="2"
POOL_NODE_TAINTS="workload=agent:NoSchedule"
POOL_NODE_LABELS="workload=agent"

gcloud container node-pools create ${GKE_NODE_POOL_NAME} \
  --cluster ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} \
  --project ${GKE_PROJECT} \
  --node-labels ${COMMON_LABELS},${POOL_NODE_LABELS} \
  --num-nodes=${POOL_NUM_NODES} \
  --enable-autoscaling \
  --min-nodes=${POOL_MIN_NODES} \
  --max-nodes=${POOL_MAX_NODES} \
  --machine-type=${POOL_MACHINE_TYPE} \
  --node-taints=${POOL_NODE_TAINTS} \
  --spot
```

### Scale
```bash
# Scale up/down
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool agent-scenario1a --num-nodes 1 --quiet

# Scale to zero
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool agent-scenario1a --num-nodes 0 --quiet
```

---

## Node Group 2 — Agentgateway (Shared Proxy: MCP + LLM)
> Namespace: `agentgateway-system`

```bash
GKE_NODE_POOL_NAME="agentgateway-scenario1a"
POOL_ZONE="${GKE_CLUSTER_ZONE}"
POOL_MACHINE_TYPE="n2-standard-4"
POOL_NUM_NODES="1"
POOL_MIN_NODES="1"
POOL_MAX_NODES="1"
POOL_NODE_TAINTS="workload=agentgateway:NoSchedule"
POOL_NODE_LABELS="workload=agentgateway"

gcloud container node-pools create ${GKE_NODE_POOL_NAME} \
  --cluster ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} \
  --project ${GKE_PROJECT} \
  --node-labels ${COMMON_LABELS},${POOL_NODE_LABELS} \
  --num-nodes=${POOL_NUM_NODES} \
  --enable-autoscaling \
  --min-nodes=${POOL_MIN_NODES} \
  --max-nodes=${POOL_MAX_NODES} \
  --machine-type=${POOL_MACHINE_TYPE} \
  --node-taints=${POOL_NODE_TAINTS} \
  --spot
```

### Scale
```bash
# Scale up/down
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool agent-scenario1agateway --num-nodes 1 --quiet

# Scale to zero
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool agent-scenario1agateway --num-nodes 0 --quiet
```

---

## Node Group 3 — Capability (MCP Server + mock-llm-d)
> Namespace: `capability-1`

```bash
GKE_NODE_POOL_NAME="capability-scenario1a"
POOL_ZONE="${GKE_CLUSTER_ZONE}"
POOL_MACHINE_TYPE="n2-standard-4"
POOL_NUM_NODES="4"
POOL_MIN_NODES="4"
POOL_MAX_NODES="5"
POOL_NODE_TAINTS="workload=capability:NoSchedule"
POOL_NODE_LABELS="workload=capability"

gcloud container node-pools create ${GKE_NODE_POOL_NAME} \
  --cluster ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} \
  --project ${GKE_PROJECT} \
  --node-labels ${COMMON_LABELS},${POOL_NODE_LABELS} \
  --num-nodes=${POOL_NUM_NODES} \
  --enable-autoscaling \
  --min-nodes=${POOL_MIN_NODES} \
  --max-nodes=${POOL_MAX_NODES} \
  --machine-type=${POOL_MACHINE_TYPE} \
  --node-taints=${POOL_NODE_TAINTS} \
  --spot
```

### Scale
```bash
# Scale up/down
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool capability-scenario1a --num-nodes 4 --quiet

# Scale to zero
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool capability-scenario1a --num-nodes 0 --quiet
```

---

## Verify node pools

```bash
gcloud container node-pools list \
  --cluster ${GKE_CLUSTER_NAME} \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT}
```

---

## Workload scheduling reference

Apply these to each workload's `Deployment` spec to pin pods to the correct node pool:

### Node Group 1 — agent-1 (Client-1)
```yaml
nodeSelector:
  workload: agent
tolerations:
- key: workload
  operator: Equal
  value: agent
  effect: NoSchedule
```

### Node Group 2 — agentgateway-system (Agentgateway)
```yaml
nodeSelector:
  workload: agentgateway
tolerations:
- key: workload
  operator: Equal
  value: agentgateway
  effect: NoSchedule
```

### Node Group 3 — capability-1 (MCP Server + mock-llm-d)
```yaml
nodeSelector:
  workload: capability
tolerations:
- key: workload
  operator: Equal
  value: capability
  effect: NoSchedule
```

---

## Teardown

```bash
gcloud container clusters delete ${GKE_CLUSTER_NAME} \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT}
```
