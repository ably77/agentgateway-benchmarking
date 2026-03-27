# Shared Cluster - GKE Setup

This cluster setup is shared across the **Baseline**, **Scenario 1a**, **Scenario 1b**, and **Scenario 2**. Each scenario deploys different workloads onto this cluster, but the underlying GKE infrastructure is the same.

## Architecture
- Single cluster, single region, single availability zone
- 3 isolated node groups (one per logical tier)
- Single client

```
Node Group 1 (Zone A): ns=agent-1         → Client-1
Node Group 2 (Zone A): ns=agentgateway-system → Agentgateway (MCP + LLM)
Node Group 3 (Zone A): ns=capability-1    → MCP Server (mcp-everything) + mock-llm-d
```

---

## Set core cluster variables

```bash
GKE_CLUSTER_NAME="ly-gke-benchmark-main"
GKE_CLUSTER_ZONE="us-east1-b"
GKE_PROJECT="<project>"
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
  --logging NONE
```

---

## Node Group 1 — Agent (Client-1)
> Namespace: `agent-1`

```bash
GKE_NODE_POOL_NAME="agent-main"
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
  --node-taints=${POOL_NODE_TAINTS}
```

### Scale
```bash
# Scale up/down
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool agent-main --num-nodes 1 --quiet

# Scale to zero
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool agent-main --num-nodes 0 --quiet
```

---

## Node Group 2 — Agentgateway (Shared Proxy: MCP + LLM)
> Namespace: `agentgateway-system`

```bash
GKE_NODE_POOL_NAME="agentgateway-main"
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
  --node-taints=${POOL_NODE_TAINTS}
```

### Scale
```bash
# Scale up/down
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool agentgateway-main --num-nodes 1 --quiet

# Scale to zero
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool agentgateway-main --num-nodes 0 --quiet
```

---

## Node Group 3 — Capability (MCP Server + mock-llm-d)
> Namespace: `capability-1`

```bash
GKE_NODE_POOL_NAME="capability-main"
POOL_ZONE="${GKE_CLUSTER_ZONE}"
POOL_MACHINE_TYPE="n2-standard-4"
POOL_NUM_NODES="4"
POOL_MIN_NODES="4"
POOL_MAX_NODES="7"
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
  --node-taints=${POOL_NODE_TAINTS}
```

### Scale
```bash
# Scale up/down
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool capability-main --num-nodes 4 --quiet

# Scale to zero
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --zone ${POOL_ZONE} --project ${GKE_PROJECT} \
  --node-pool capability-main --num-nodes 0 --quiet
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

## Delete node pools

To delete individual node pools without tearing down the cluster:

```bash
# Delete agent node pool
gcloud container node-pools delete agent-main \
  --cluster ${GKE_CLUSTER_NAME} \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT} \
  --quiet

# Delete agentgateway node pool
gcloud container node-pools delete agentgateway-main \
  --cluster ${GKE_CLUSTER_NAME} \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT} \
  --quiet

# Delete capability node pool
gcloud container node-pools delete capability-main \
  --cluster ${GKE_CLUSTER_NAME} \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT} \
  --quiet
```

---

## Teardown

```bash
gcloud container clusters delete ${GKE_CLUSTER_NAME} \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT}
```
