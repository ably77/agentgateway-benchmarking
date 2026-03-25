#!/usr/bin/env bash
# reconfigure-for-scenario-3.sh
# Migrates from scenario-2 (multiple in-cluster clients, shared proxy) to
# scenario-3 (single external client via LoadBalancer).
#
# What this script does:
#   1. Validates cluster context variables (CTX_CLUSTER1, CTX_CLUSTER2)
#   2. Removes scenario-2 client namespaces (agent-1 through agent-5)
#   3. Ensures service type is LoadBalancer
#   4. Waits for LoadBalancer external IP assignment

set -euo pipefail

# --- 1. Validate cluster contexts ---
if [ -z "${CTX_CLUSTER1:-}" ]; then
    echo "ERROR: CTX_CLUSTER1 is not set. Export it before running this script."
    echo "  export CTX_CLUSTER1=\"gke_<project>_us-east1-b_ly-gke-benchmark-main\""
    exit 1
fi

if [ -z "${CTX_CLUSTER2:-}" ]; then
    echo "WARNING: CTX_CLUSTER2 is not set. You will need it when running setup-script.sh."
    echo "  export CTX_CLUSTER2=\"gke_<project>_us-east1-b_ly-gke-benchmark-external-client\""
fi

echo "==> Using gateway cluster context: $CTX_CLUSTER1"

# --- 2. Remove scenario-2 client namespaces ---
echo "==> Removing scenario-2 client namespaces (agent-1 through agent-5)..."
for ns in agent-1 agent-2 agent-3 agent-4 agent-5; do
    kubectl --context "$CTX_CLUSTER1" delete namespace "$ns" --ignore-not-found
done

# --- 3. Ensure LoadBalancer service type ---
echo "==> Checking service type on EnterpriseAgentgatewayParameters..."
CURRENT_TYPE=$(kubectl --context "$CTX_CLUSTER1" get enterpriseagentgatewayparameters agentgateway-config \
    -n agentgateway-system -o jsonpath='{.spec.service.spec.type}' 2>/dev/null || echo "")

if [ "$CURRENT_TYPE" != "LoadBalancer" ]; then
    echo "    Current type: '${CURRENT_TYPE:-<not set>}' — patching to LoadBalancer..."
    kubectl --context "$CTX_CLUSTER1" patch enterpriseagentgatewayparameters agentgateway-config \
        -n agentgateway-system --type merge \
        -p '{"spec":{"service":{"spec":{"type":"LoadBalancer"}}}}'
else
    echo "    Already LoadBalancer — no change needed."
fi

# --- 4. Wait for LoadBalancer external IP ---
echo "==> Waiting for LoadBalancer external IP (up to 2 minutes)..."
LB_IP=""
for i in $(seq 1 24); do
    LB_IP=$(kubectl --context "$CTX_CLUSTER1" get svc agentgateway-proxy \
        -n agentgateway-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$LB_IP" ]; then
        echo "    LoadBalancer IP: $LB_IP"
        break
    fi
    echo "    Not yet (${i}/24), retrying in 5s..."
    sleep 5
done

if [ -z "$LB_IP" ]; then
    echo "ERROR: LoadBalancer IP not assigned after 2 minutes."
    exit 1
fi

# --- 5. Verify ---
echo ""
echo "==> Pods in agentgateway-system:"
kubectl --context "$CTX_CLUSTER1" get pods -n agentgateway-system

echo ""
echo "==> Services in agentgateway-system:"
kubectl --context "$CTX_CLUSTER1" get svc -n agentgateway-system

echo ""
echo "Done. Gateway cluster is ready for scenario-3."
echo "LoadBalancer IP: $LB_IP"
echo "You can now run: scenario-3/setup-script.sh"
