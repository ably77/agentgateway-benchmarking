#!/usr/bin/env bash
# =============================================================================
# Scenario 1c: Colocated Microgateway — External Client via LoadBalancer
# =============================================================================
# Hop path: Client → NLB → agw /mcp → mcp-everything sampleLLM → agw /mock-openai → LLM
#
# Difference from 1a: client connects via the LoadBalancer external IP so the
# NLB hop is included in all latency measurements.
#
# Two client deployment options:
#   1) Local  — Python venv on this machine (internet + NLB hop)
#   2) k8s    — single client deployed to a separate cluster (NLB hop, no internet variance)
#
# Steps
#   1. Deploy mcp-server-everything + mock-llm to ai-platform namespace
#   2. Apply AgentGateway HTTPRoutes and backends (unchanged from 1a)
#   3. Wait for LoadBalancer external IP
#   4. Deploy client (local or separate k8s cluster)
#   5. Launch
#   6. Cleanup
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLIENT_DIR="${REPO_ROOT}/client"
NAMESPACE="ai-platform"
AGW_NAMESPACE="agentgateway-system"
AGENT_NAMESPACE="agent-1"
STREAMLIT_PORT="${STREAMLIT_PORT:-8501}"
LOCUST_PORT="${LOCUST_PORT:-8089}"

# Color helpers
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require() { command -v "$1" &>/dev/null || { error "Required tool not found: $1"; exit 1; }; }
require kubectl
require curl
require jq

echo
echo "======================================================"
echo " Scenario 1c: External Client via LoadBalancer"
echo "======================================================"
echo

# =============================================================================
# STEP 0 — Ensure agentgateway-proxy is exposed as LoadBalancer
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 0: Ensure agentgateway-proxy service type = LoadBalancer"
echo "─────────────────────────────────────────────────────"
echo
info "Scenario 1c requires a LoadBalancer so the external NLB hop is included in latency."
info "Patching EnterpriseAgentgatewayParameters → service.spec.type=LoadBalancer …"
kubectl patch enterpriseagentgatewayparameters agentgateway-config -n "${AGW_NAMESPACE}" \
    --type=merge \
    -p '{"spec":{"service":{"spec":{"type":"LoadBalancer"}}}}' 2>/dev/null \
    || warn "Could not patch EnterpriseAgentgatewayParameters (resource may not exist yet — continuing)."
echo

# =============================================================================
# STEP 1 — Deploy mcp-server-everything + mock-llm
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 1: Deploy mcp-server-everything + mock-llm"
echo "─────────────────────────────────────────────────────"

kubectl get namespace "${NAMESPACE}" &>/dev/null || kubectl create namespace "${NAMESPACE}"
info "Namespace '${NAMESPACE}' ready."

kubectl apply -f "${SCRIPT_DIR}/k8s/mcp-everything-deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/mock-llm-deployment.yaml"
info "Workloads applied. Waiting for rollouts …"

kubectl rollout status deployment/mcp-server-everything -n "${NAMESPACE}" --timeout=120s
kubectl rollout status deployment/mock-llm              -n "${NAMESPACE}" --timeout=120s
info "mcp-server-everything and mock-llm are ready."
echo

# =============================================================================
# STEP 2 — Apply AgentGateway routes (same as 1a)
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 2: Apply AgentGateway HTTPRoutes and backends"
echo "─────────────────────────────────────────────────────"

kubectl apply -f "${SCRIPT_DIR}/route/mock-openai-backend.yaml"
kubectl apply -f "${SCRIPT_DIR}/route/mock-openai-httproute.yaml"
kubectl apply -f "${SCRIPT_DIR}/route/mcp-everything-backend.yaml"
kubectl apply -f "${SCRIPT_DIR}/route/mcp-everything-httproute.yaml"

info "Routes applied:"
kubectl get httproutes -n "${AGW_NAMESPACE}"
echo

# =============================================================================
# STEP 3 — Wait for LoadBalancer external IP
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 3: Waiting for LoadBalancer external IP"
echo "─────────────────────────────────────────────────────"

GATEWAY_IP=""
for i in $(seq 1 24); do
    GATEWAY_IP=$(kubectl get svc agentgateway-proxy -n "${AGW_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "${GATEWAY_IP}" ] && break
    warn "Waiting for LoadBalancer IP … (${i}/24, timeout 2m)"
    sleep 5
done

if [ -z "${GATEWAY_IP}" ]; then
    error "LoadBalancer IP not assigned after 2 minutes. Ensure the cluster supports LoadBalancer services."
    exit 1
fi

info "Gateway LoadBalancer IP: ${GATEWAY_IP}"
export GATEWAY_IP
echo

# =============================================================================
# STEP 4 — Choose client mode
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 4: Choose client deployment mode"
echo "─────────────────────────────────────────────────────"
echo
echo "Both options connect via the LoadBalancer IP (${GATEWAY_IP}) — NLB hop included."
echo
echo "  1) Local  — Python venv on this machine (internet + NLB hop)"
echo "  2) k8s    — deploy client to a separate cluster (NLB hop, no internet variance)"
echo
read -r -p "Choice [1]: " CLIENT_MODE
CLIENT_MODE="${CLIENT_MODE:-1}"

CLIENT_CONTEXT=""

if [[ "${CLIENT_MODE}" == "2" ]]; then
    # -------------------------------------------------------------------------
    # Select a separate cluster context for the client deployment
    # -------------------------------------------------------------------------
    CURRENT_CONTEXT=$(kubectl config current-context)
    info "Current context (gateway cluster): ${CURRENT_CONTEXT}"
    echo
    echo "Available contexts:"
    mapfile -t ALL_CONTEXTS < <(kubectl config get-contexts -o name)
    for idx in "${!ALL_CONTEXTS[@]}"; do
        CTX="${ALL_CONTEXTS[$idx]}"
        if [[ "${CTX}" == "${CURRENT_CONTEXT}" ]]; then
            echo "  $((idx+1))) ${CTX}  ← current (gateway cluster)"
        else
            echo "  $((idx+1))) ${CTX}"
        fi
    done
    echo
    read -r -p "Select context for client cluster [enter number]: " CTX_CHOICE
    CTX_CHOICE="${CTX_CHOICE:-1}"
    CLIENT_CONTEXT="${ALL_CONTEXTS[$((CTX_CHOICE-1))]}"

    if [[ "${CLIENT_CONTEXT}" == "${CURRENT_CONTEXT}" ]]; then
        warn "You selected the same context as the gateway cluster."
        warn "Traffic will be short-circuited by kube-proxy — the NLB hop will NOT be measured."
        read -r -p "Continue anyway? [y/N]: " FORCE_SAME
        [[ "${FORCE_SAME,,}" == "y" ]] || { error "Aborted. Select a different cluster context."; exit 1; }
    fi

    info "Client context: ${CLIENT_CONTEXT}"
    echo

    kubectl --context "${CLIENT_CONTEXT}" create namespace "${AGENT_NAMESPACE}" \
        --dry-run=client -o yaml | kubectl --context "${CLIENT_CONTEXT}" apply -f -

    info "Deploying loadgen client to ${CLIENT_CONTEXT} …"
    kubectl --context "${CLIENT_CONTEXT}" apply -f "${SCRIPT_DIR}/k8s/agent-deployment.yaml"

    info "Patching GATEWAY_IP=${GATEWAY_IP} into client deployment …"
    kubectl --context "${CLIENT_CONTEXT}" set env deployment/loadgen-client \
        -n "${AGENT_NAMESPACE}" "GATEWAY_IP=${GATEWAY_IP}"

    kubectl --context "${CLIENT_CONTEXT}" rollout status \
        deployment/loadgen-client -n "${AGENT_NAMESPACE}" --timeout=120s
    info "Client deployed on ${CLIENT_CONTEXT} → pointing at LB IP: ${GATEWAY_IP}"
    CLIENT_MODE="k8s"
else
    info "Setting up local Python virtual environment …"
    VENV_DIR="${CLIENT_DIR}/.venv"

    if [ ! -d "${VENV_DIR}" ]; then
        PYTHON=""
        for PY in python3.12 python3.11 python3; do
            if command -v "${PY}" &>/dev/null; then PYTHON="${PY}"; break; fi
        done
        [ -z "${PYTHON}" ] && { error "Python 3.11+ required."; exit 1; }
        info "Creating venv with ${PYTHON} …"
        "${PYTHON}" -m venv "${VENV_DIR}"
    fi

    # shellcheck disable=SC1090
    source "${VENV_DIR}/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet -r "${CLIENT_DIR}/requirements.txt"
    info "Dependencies installed."
    CLIENT_MODE="local"
fi
echo

# =============================================================================
# STEP 5 — Launch
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 5: Launch"
echo "─────────────────────────────────────────────────────"
echo

if [[ "${CLIENT_MODE}" == "local" ]]; then
    echo "What would you like to run?"
    echo "  1) Streamlit UI (port ${STREAMLIT_PORT})"
    echo "  2) Locust headless load test"
    echo "  3) Both (Streamlit + locust web UI on port ${LOCUST_PORT})"
    echo "  4) Skip — manual launch"
    echo
    read -r -p "Choice [1]: " LAUNCH_CHOICE
    LAUNCH_CHOICE="${LAUNCH_CHOICE:-1}"

    case "${LAUNCH_CHOICE}" in
        1)
            info "Launching Streamlit at http://localhost:${STREAMLIT_PORT}"
            GATEWAY_IP="${GATEWAY_IP}" OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
                streamlit run "${CLIENT_DIR}/app.py" \
                --server.port "${STREAMLIT_PORT}" \
                --server.headless true
            ;;
        2)
            read -r -p "Concurrent users [10]: " LT_USERS; LT_USERS="${LT_USERS:-10}"
            read -r -p "Spawn rate (users/s) [2]: " LT_RATE; LT_RATE="${LT_RATE:-2}"
            read -r -p "Duration (s) [60]: " LT_DUR; LT_DUR="${LT_DUR:-60}"
            info "Starting locust: ${LT_USERS} users, rate ${LT_RATE}/s, ${LT_DUR}s"
            OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
                locust -f "${CLIENT_DIR}/loadtest.py" \
                --headless -u "${LT_USERS}" -r "${LT_RATE}" -t "${LT_DUR}s" \
                --host "http://${GATEWAY_IP}:8080"
            ;;
        3)
            info "Starting Streamlit at http://localhost:${STREAMLIT_PORT}"
            GATEWAY_IP="${GATEWAY_IP}" OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
                streamlit run "${CLIENT_DIR}/app.py" \
                --server.port "${STREAMLIT_PORT}" \
                --server.headless true &
            STREAMLIT_PID=$!
            info "Starting Locust web UI at http://localhost:${LOCUST_PORT}"
            OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
                locust -f "${CLIENT_DIR}/loadtest.py" \
                --web-port "${LOCUST_PORT}" \
                --host "http://${GATEWAY_IP}:8080" &
            LOCUST_PID=$!
            info "Streamlit PID: ${STREAMLIT_PID}, Locust PID: ${LOCUST_PID}"
            info "Press Ctrl+C to stop both."
            wait
            ;;
        4)
            info "Skipping launch. Run manually:"
            echo "  GATEWAY_IP=${GATEWAY_IP} streamlit run ${CLIENT_DIR}/app.py"
            echo "  locust -f ${CLIENT_DIR}/loadtest.py --headless -u 10 -r 2 -t 60s --host http://${GATEWAY_IP}:8080"
            ;;
    esac
else
    info "Client running on cluster: ${CLIENT_CONTEXT}"
    info "Port-forward to access the UI:"
    echo "  kubectl --context ${CLIENT_CONTEXT} port-forward -n ${AGENT_NAMESPACE} svc/loadgen-client ${STREAMLIT_PORT}:8501"
    echo "  open http://localhost:${STREAMLIT_PORT}"
fi

echo

# =============================================================================
# STEP 6 — Observability hints
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 6: Observability"
echo "─────────────────────────────────────────────────────"
echo
echo "  # AgentGateway request logs"
echo "  kubectl logs -n ${AGW_NAMESPACE} deploy/agentgateway-proxy -f"
echo
echo "  # MCP server logs"
echo "  kubectl logs -n ${NAMESPACE} deploy/mcp-server-everything -f"
echo
echo "  # Prometheus port-forward"
echo "  kubectl port-forward -n monitoring svc/grafana-prometheus-kube-pr-prometheus 9090:9090"
echo
echo "  # Host configuration:"
echo "    host=${GATEWAY_IP}  port=8080  MCP path=/mcp  LLM path=/mock-openai"
echo

read -r -p "Press Enter to continue to cleanup …"

# =============================================================================
# STEP 7 — Cleanup
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 7: Cleanup"
echo "─────────────────────────────────────────────────────"
echo
read -r -p "Run cleanup? (removes routes and workloads) [y/N]: " DO_CLEANUP
if [[ "${DO_CLEANUP,,}" == "y" ]]; then
    kubectl delete -f "${SCRIPT_DIR}/route/" --ignore-not-found
    kubectl delete -f "${SCRIPT_DIR}/k8s/mcp-everything-deployment.yaml" --ignore-not-found
    kubectl delete -f "${SCRIPT_DIR}/k8s/mock-llm-deployment.yaml" --ignore-not-found

    if [[ "${CLIENT_MODE}" == "k8s" ]] && [ -n "${CLIENT_CONTEXT}" ]; then
        kubectl --context "${CLIENT_CONTEXT}" delete -f "${SCRIPT_DIR}/k8s/agent-deployment.yaml" --ignore-not-found
        kubectl --context "${CLIENT_CONTEXT}" delete namespace "${AGENT_NAMESPACE}" --ignore-not-found
        info "k8s client removed from ${CLIENT_CONTEXT}."
    elif [[ "${CLIENT_MODE}" == "local" ]]; then
        read -r -p "Also delete Python venv? [y/N]: " DEL_VENV
        if [[ "${DEL_VENV,,}" == "y" ]]; then
            rm -rf "${CLIENT_DIR}/.venv"
            info "Venv removed."
        fi
    fi
    info "Cleanup complete."
fi

echo
info "Done."
