#!/usr/bin/env bash
# Tear down all Scenario 1a resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="ai-platform"
AGW_NAMESPACE="agentgateway-system"
AGENT_NAMESPACE="agent-1"

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }

read -r -p "This will delete all Scenario 1a resources. Continue? [y/N]: " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

info "Removing AgentGateway routes and backends …"
kubectl delete -f "${SCRIPT_DIR}/route/" --ignore-not-found

info "Removing loadgen client …"
kubectl delete -f "${SCRIPT_DIR}/k8s/agent-deployment.yaml" --ignore-not-found

info "Removing workloads …"
kubectl delete -f "${SCRIPT_DIR}/k8s/mcp-everything-deployment.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/k8s/mock-llm-deployment.yaml" --ignore-not-found

info "Deleting namespaces …"
kubectl delete namespace "${AGENT_NAMESPACE}" --ignore-not-found
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
