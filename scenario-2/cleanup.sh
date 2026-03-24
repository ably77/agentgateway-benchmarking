#!/usr/bin/env bash
# Tear down all Scenario 2 resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="ai-platform"
AGW_NAMESPACE="agentgateway-system"

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }

read -r -p "This will delete all Scenario 2 resources. Continue? [y/N]: " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

info "Removing AgentGateway routes and backends …"
kubectl delete -f "${SCRIPT_DIR}/route/" --ignore-not-found

info "Removing workloads …"
kubectl delete -f "${SCRIPT_DIR}/k8s/mcp-everything-deployment.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/k8s/mock-llm-deployment.yaml" --ignore-not-found

info "Removing loadgen clients …"
for i in 1 2 3 4 5; do
    YAML="${SCRIPT_DIR}/k8s/agent-${i}-deployment.yaml"
    NS="agent-${i}"
    if kubectl get namespace "${NS}" &>/dev/null; then
        kubectl delete -f "${YAML}" --ignore-not-found
        kubectl delete namespace "${NS}" --ignore-not-found
        info "  agent-${i} namespace removed."
    fi
done

info "Deleting ai-platform namespace …"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

VENV_DIR="${SCRIPT_DIR}/../client/.venv"
if [ -d "${VENV_DIR}" ]; then
    read -r -p "Remove local Python venv (${VENV_DIR})? [y/N]: " CLEAN_VENV
    if [[ "${CLEAN_VENV}" =~ ^[Yy]$ ]]; then
        rm -rf "${VENV_DIR}"
        info "Venv removed."
    else
        info "Venv kept."
    fi
fi

info "Done. AgentGateway namespace '${AGW_NAMESPACE}' was left intact."
