# Reconfigure for Scenario 3

This step migrates from scenario-2 (multiple in-cluster clients, shared proxy) to scenario-3 (single external client via LoadBalancer).

## What changes

| | Scenario 2 | Scenario 3 |
|---|---|---|
| Clients | 1-5 in-cluster (`agent-1`…`agent-N`) | 1 client on separate cluster or local |
| Service type | LoadBalancer or ClusterIP | LoadBalancer (required for NLB measurement) |
| Clusters | Single cluster | Two clusters (gateway + client) |
| Gateway / routes / backends | — | Unchanged |

## Steps

### 1. Set up cluster contexts

Scenario 3 uses two clusters. Set context variables so you can switch explicitly:

```bash
export CTX_CLUSTER1="gke_<project>_us-east1-b_ly-gke-benchmark-main"
export CTX_CLUSTER2="gke_<project>_us-east1-b_ly-gke-benchmark-external-client"
```

If you haven't provisioned the second cluster yet, follow [`gke/external-client-cluster-gke.md`](../../gke/external-client-cluster-gke.md).

> All remaining steps in this file apply to **Cluster 1** (gateway). Set your active context before proceeding:

```bash
kubectl config use-context $CTX_CLUSTER1
```

### 2. Remove scenario-2 client deployments

Delete the in-cluster client namespaces (`agent-1` through `agent-5`) from the main cluster. The backends and gateway configuration remain unchanged.

```bash
for ns in agent-1 agent-2 agent-3 agent-4 agent-5; do
    kubectl --context $CTX_CLUSTER1 delete namespace "$ns" --ignore-not-found
done
```

### 3. Ensure LoadBalancer service type

Scenario 3 requires a LoadBalancer service so the external client can reach the gateway via the NLB. Patch `EnterpriseAgentgatewayParameters` if it isn't already set to `LoadBalancer`:

```bash
kubectl --context $CTX_CLUSTER1 get enterpriseagentgatewayparameters agentgateway-config \
    -n agentgateway-system -o jsonpath='{.spec.service.spec.type}'
```

If the output is not `LoadBalancer`, apply the patch:

```bash
kubectl --context $CTX_CLUSTER1 patch enterpriseagentgatewayparameters agentgateway-config \
    -n agentgateway-system --type merge \
    -p '{"spec":{"service":{"spec":{"type":"LoadBalancer"}}}}'
```

### 4. Wait for LoadBalancer external IP

Poll until the external IP is assigned (up to 2 minutes):

```bash
echo "Waiting for LoadBalancer external IP..."
for i in $(seq 1 24); do
    LB_IP=$(kubectl --context $CTX_CLUSTER1 get svc agentgateway-proxy \
        -n agentgateway-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -n "$LB_IP" ]; then
        echo "LoadBalancer IP: $LB_IP"
        break
    fi
    echo "  Not yet (${i}/24), retrying in 5s..."
    sleep 5
done

if [ -z "$LB_IP" ]; then
    echo "ERROR: LoadBalancer IP not assigned after 2 minutes."
    exit 1
fi
```

### 5. Verify

Confirm gateway pods are running:

```bash
kubectl --context $CTX_CLUSTER1 get pods -n agentgateway-system
```

Expected output:

```
NAME                                                        READY   STATUS    RESTARTS   AGE
agentgateway-proxy-6ccb7848b4-nt7qk                         1/1     Running   0          21s
agentgateway-proxy-6ccb7848b4-p8mxj                         1/1     Running   0          21s
enterprise-agentgateway-c5c748bbd-m8l4k                     1/1     Running   0          91s
ext-auth-service-enterprise-agentgateway-6dd5dbff7b-85xkh   1/1     Running   0          20s
ext-cache-enterprise-agentgateway-67d75d8b48-fx676          1/1     Running   0          21s
rate-limiter-enterprise-agentgateway-7d46cb8df9-wr6c7       1/1     Running   0          21s
```

Confirm LoadBalancer IP is available:

```bash
kubectl --context $CTX_CLUSTER1 get svc agentgateway-proxy -n agentgateway-system
```

You are now ready to run the scenario-3 `setup-script.sh`.
