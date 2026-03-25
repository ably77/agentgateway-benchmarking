# External Client Cluster - GKE Setup

## Overview

This is an optional second cluster used when running the external client from GKE rather than a local machine venv. It hosts a single agent node pool with Client-1, which connects to Agentgateway running on Cluster 1 (see `main-cluster-gke.md`).

## Architecture

```
[Cluster 2 — ly-gke-benchmark-external-client]
Node Group 1 (Zone A): agent-external-client  → Client-1 (ns=agent-1)

[Cluster 1 — remote (ly-gke-benchmark-main)]
Node Group 2 (Zone A): agentgateway-main  → Agentgateway (MCP + LLM)
Node Group 3 (Zone A): capability-main    → MCP Server (mcp-everything) + mock-llm-d
```

---

## Set core cluster variables

```bash
GKE_CLUSTER_NAME="ly-gke-benchmark-external-client"
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
GKE_NODE_POOL_NAME="agent-external-client"
POOL_ZONE="${GKE_CLUSTER_ZONE}"
POOL_MACHINE_TYPE="n2-standard-4"
POOL_NUM_NODES="1"
POOL_MIN_NODES="1"
POOL_MAX_NODES="1"
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

---

## Verify node pools

```bash
gcloud container node-pools list \
  --cluster ${GKE_CLUSTER_NAME} \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT}
```

---

## Get credentials for both clusters

```bash
# Cluster 1 (server — shared with 1a/1b)
gcloud container clusters get-credentials ly-gke-benchmark-main \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT}

# Cluster 2 (client)
gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT}
```

Switch between clusters using kubectl context:

```bash
# List available contexts
kubectl config get-contexts

# Switch to cluster 1 (server)
kubectl config use-context gke_${GKE_PROJECT}_${GKE_CLUSTER_ZONE}_ly-gke-benchmark-main

# Switch to cluster 2 (client)
kubectl config use-context gke_${GKE_PROJECT}_${GKE_CLUSTER_ZONE}_${GKE_CLUSTER_NAME}
```

---

## Workload scheduling reference

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

---

## Teardown

```bash
gcloud container clusters delete ${GKE_CLUSTER_NAME} \
  --zone ${GKE_CLUSTER_ZONE} \
  --project ${GKE_PROJECT}
```
