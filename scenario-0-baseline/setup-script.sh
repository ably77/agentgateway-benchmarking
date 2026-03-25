#!/usr/bin/env bash
# =============================================================================
# Scenario 0: Baseline — Direct Backend, No Proxy
# =============================================================================
# Hop path: Client → mcp-everything (direct)   Client → mock-llm (direct)
#
# Steps
#   1. Deploy mcp-server-everything + mock-llm to ai-platform namespace
#   2. Deploy in-cluster loadgen client (k8s)
#   3. Observability hints
#   4. Cleanup
#
# No AgentGateway in the data path — pure backend latency baseline.
# No real OpenAI API key required — traffic routes through mock-llm (llm-d-inference-sim).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="ai-platform"
AGENT_NAMESPACE="agent-1"
STREAMLIT_PORT="${STREAMLIT_PORT:-8501}"

# Color helpers
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check required tools
require() { command -v "$1" &>/dev/null || { error "Required tool not found: $1"; exit 1; }; }
require kubectl
require curl
require jq

echo
echo "======================================================"
echo " Scenario 0: Baseline — Direct Backend, No Proxy"
echo "======================================================"
echo

# =============================================================================
# STEP 1 — Deploy mcp-server-everything + mock-llm
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 1: Deploy mcp-server-everything + mock-llm"
echo "─────────────────────────────────────────────────────"

# Create namespace if it doesn't exist
kubectl get namespace "${NAMESPACE}" &>/dev/null || kubectl create namespace "${NAMESPACE}"
info "Namespace '${NAMESPACE}' ready."

kubectl apply -f "${SCRIPT_DIR}/k8s/mcp-everything-deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/mock-llm-deployment.yaml"
info "Workloads applied. Waiting for rollouts …"

kubectl rollout status deployment/mcp-server-everything -n "${NAMESPACE}" --timeout=120s
kubectl rollout status deployment/mock-llm              -n "${NAMESPACE}" --timeout=120s
info "mcp-server-everything and mock-llm are ready."

MCP_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=mcp-server-everything \
    -o jsonpath='{.items[*].status.phase}')
LLM_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=mock-llm \
    -o jsonpath='{.items[*].status.phase}')
info "MCP pod phases: ${MCP_PODS} | LLM pod phases: ${LLM_PODS}"

echo

# =============================================================================
# STEP 2 — Deploy in-cluster loadgen client
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 2: Deploy loadgen client to namespace '${AGENT_NAMESPACE}'"
echo "─────────────────────────────────────────────────────"

kubectl create namespace "${AGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/k8s/agent-deployment.yaml"
kubectl rollout status deployment/loadgen-client -n "${AGENT_NAMESPACE}" --timeout=120s
info "Client deployed."

echo

# =============================================================================
# STEP 3 — Observability hints
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 3: Observability"
echo "─────────────────────────────────────────────────────"
echo

echo "  # MCP server logs"
echo "  kubectl logs -n ${NAMESPACE} deploy/mcp-server-everything -f"
echo
echo "  # LLM server logs"
echo "  kubectl logs -n ${NAMESPACE} deploy/mock-llm -f"
echo

info "Streamlit UI (in-cluster):"
echo "  kubectl port-forward -n ${AGENT_NAMESPACE} svc/loadgen-client ${STREAMLIT_PORT}:${STREAMLIT_PORT}"
echo "  open http://localhost:${STREAMLIT_PORT}"
echo

info "Streamlit UI host configurations (direct backend — no gateway):"
echo
echo "  Un-select the Shared Gateway checkbox, then configure:"
echo
echo "    MCP:  host=mcp-server-everything.${NAMESPACE}.svc.cluster.local  port=8080  MCP path=/mcp"
echo "    LLM:  host=mock-llm.${NAMESPACE}.svc.cluster.local               port=8080  LLM path=(leave blank)"
echo
echo "  Delta between this baseline and scenario-1a (via agentgateway) = pure agentgateway overhead."
echo

read -r -p "Press Enter to continue to cleanup …"

# =============================================================================
# STEP 4 — Cleanup
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 4: Cleanup"
echo "─────────────────────────────────────────────────────"
echo

read -r -p "Run cleanup? (removes workloads and client) [y/N]: " DO_CLEANUP
if [[ "${DO_CLEANUP,,}" == "y" ]]; then
    kubectl delete -f "${SCRIPT_DIR}/k8s/mcp-everything-deployment.yaml" --ignore-not-found
    kubectl delete -f "${SCRIPT_DIR}/k8s/mock-llm-deployment.yaml" --ignore-not-found
    kubectl delete -f "${SCRIPT_DIR}/k8s/agent-deployment.yaml" --ignore-not-found
    info "Workloads and client removed."
    info "Cleanup complete."
fi

echo
info "Done."
