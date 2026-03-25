#!/usr/bin/env bash
# =============================================================================
# Scenario 1b: Colocated Microgateway — Dedicated Proxies
# =============================================================================
# Hop path: Client → Agent → agw-mcp /mcp → mcp-everything sampleLLM → agw-llm /mock-openai → LLM
#
# Difference from 1a: two dedicated Gateway proxies instead of one shared gateway
#   agentgateway-proxy-mcp  — handles /mcp routes
#   agentgateway-proxy-llm  — handles /mock-openai routes
#
# Steps
#   1. Deploy mcp-server-everything + mock-llm to ai-platform namespace
#   2. Apply AgentGateway HTTPRoutes and backends
#   3. Get Gateway IPs
#   4. Set up Python virtual environment
#   5. Launch Streamlit UI or locust load test
#   6. Cleanup
#
# No real OpenAI API key required — traffic routes through mock-llm (llm-d-inference-sim).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLIENT_DIR="${REPO_ROOT}/client"
NAMESPACE="ai-platform"
AGW_NAMESPACE="agentgateway-system"
AGENT_NAMESPACE="agent-1"
MCP_GW_SVC="agentgateway-proxy-mcp"
LLM_GW_SVC="agentgateway-proxy-llm"
STREAMLIT_PORT="${STREAMLIT_PORT:-8501}"
LOCUST_PORT="${LOCUST_PORT:-8089}"

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
echo " Scenario 1b: Colocated Microgateway — Dedicated Proxies"
echo "======================================================"
echo

# =============================================================================
# STEP 0 — AgentGateway proxy service type
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 0: AgentGateway proxy service type"
echo "─────────────────────────────────────────────────────"
echo
echo "How should the agentgateway proxy services be exposed?"
echo "  1) LoadBalancer  — assigns external IPs (GKE/EKS/AKS)"
echo "  2) ClusterIP     — ideal when running the load-gen client in-cluster (no external IP needed)"
echo
read -r -p "Choice [1]: " SVC_TYPE_CHOICE
SVC_TYPE_CHOICE="${SVC_TYPE_CHOICE:-1}"

if [[ "${SVC_TYPE_CHOICE}" == "2" ]]; then
    AGW_SVC_TYPE="ClusterIP"
else
    AGW_SVC_TYPE="LoadBalancer"
fi

info "Patching EnterpriseAgentgatewayParameters → service.spec.type=${AGW_SVC_TYPE} …"
kubectl patch enterpriseagentgatewayparameters agentgateway-config -n "${AGW_NAMESPACE}" \
    --type=merge \
    -p "{\"spec\":{\"service\":{\"spec\":{\"type\":\"${AGW_SVC_TYPE}\"}}}}" 2>/dev/null \
    || warn "Could not patch EnterpriseAgentgatewayParameters (resource may not exist yet — continuing)."
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
# STEP 2 — Apply AgentGateway routes
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
# STEP 4 — Get Gateway IPs
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 4: Retrieve AgentGateway gateway IPs"
echo "─────────────────────────────────────────────────────"

MCP_GATEWAY_IP=""
LLM_GATEWAY_IP=""

if [[ "${AGW_SVC_TYPE}" == "LoadBalancer" ]]; then
    for i in $(seq 1 20); do
        MCP_GATEWAY_IP=$(kubectl get svc "${MCP_GW_SVC}" -n "${AGW_NAMESPACE}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        LLM_GATEWAY_IP=$(kubectl get svc "${LLM_GW_SVC}" -n "${AGW_NAMESPACE}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        [ -n "${MCP_GATEWAY_IP}" ] && [ -n "${LLM_GATEWAY_IP}" ] && break
        warn "Waiting for load-balancer IPs … (${i}/20)"
        sleep 5
    done
    [ -n "${MCP_GATEWAY_IP}" ] && info "MCP Gateway IP: ${MCP_GATEWAY_IP}" || warn "Could not obtain MCP load-balancer IP after 100s."
    [ -n "${LLM_GATEWAY_IP}" ] && info "LLM Gateway IP: ${LLM_GATEWAY_IP}" || warn "Could not obtain LLM load-balancer IP after 100s."
fi

if [ -z "${MCP_GATEWAY_IP}" ]; then
    warn "Using port-forward for MCP gateway on localhost:8080."
    kubectl port-forward -n "${AGW_NAMESPACE}" \
        svc/${MCP_GW_SVC} 8080:8080 </dev/null &>/dev/null &
    MCP_PF_PID=$!
    MCP_GATEWAY_IP="localhost"
    info "MCP port-forward PID: ${MCP_PF_PID}"
fi

if [ -z "${LLM_GATEWAY_IP}" ]; then
    warn "Using port-forward for LLM gateway on localhost:8081."
    kubectl port-forward -n "${AGW_NAMESPACE}" \
        svc/${LLM_GW_SVC} 8081:8080 </dev/null &>/dev/null &
    LLM_PF_PID=$!
    LLM_GATEWAY_IP="localhost"
    info "LLM port-forward PID: ${LLM_PF_PID} (port 8081)"
fi

export MCP_GATEWAY_IP LLM_GATEWAY_IP
echo

# =============================================================================
# STEP 5 — Choose client mode: local or Kubernetes
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 5: Choose client deployment mode"
echo "─────────────────────────────────────────────────────"
echo
echo "How would you like to run the load-gen client?"
echo "  1) Local  — Python venv on this machine (includes client↔LB network hop)"
echo "  2) k8s    — Deploy containerized client into the cluster (intra-cluster latency only)"
echo
read -r -p "Choice [1]: " CLIENT_MODE
CLIENT_MODE="${CLIENT_MODE:-1}"

if [[ "${CLIENT_MODE}" == "2" ]]; then
    info "Deploying loadgen client to namespace '${AGENT_NAMESPACE}' …"
    kubectl create namespace "${AGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${SCRIPT_DIR}/k8s/agent-deployment.yaml"
    kubectl rollout status deployment/loadgen-client -n "${AGENT_NAMESPACE}" --timeout=120s
    info "Client deployed. GATEWAY_IP is set to ${MCP_GW_SVC}.${AGW_NAMESPACE}.svc.cluster.local"
    CLIENT_MODE="k8s"
else
    info "Setting up local Python virtual environment …"
    VENV_DIR="${CLIENT_DIR}/.venv"

    if [ ! -d "${VENV_DIR}" ]; then
        PYTHON=""
        for PY in python3.12 python3.11 python3; do
            if command -v "${PY}" &>/dev/null; then
                PYTHON="${PY}"
                break
            fi
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
# STEP 6 — Launch (local mode only)
# =============================================================================
if [[ "${CLIENT_MODE}" == "local" ]]; then
    echo "─────────────────────────────────────────────────────"
    info "Step 6: Launch UI or load test"
    echo "─────────────────────────────────────────────────────"
    echo
    echo "What would you like to run?"
    echo "  1) Streamlit UI (port ${STREAMLIT_PORT}) — single-agent + load-test launcher"
    echo "  2) Locust headless load test  — specify users/duration"
    echo "  3) Both (Streamlit + locust web UI on port ${LOCUST_PORT})"
    echo "  4) Skip — manual launch"
    echo
    read -r -p "Choice [1]: " LAUNCH_CHOICE
    LAUNCH_CHOICE="${LAUNCH_CHOICE:-1}"

    case "${LAUNCH_CHOICE}" in
        1)
            info "Launching Streamlit at http://localhost:${STREAMLIT_PORT}"
            GATEWAY_IP="${MCP_GATEWAY_IP}" OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
                streamlit run "${CLIENT_DIR}/app.py" \
                --server.port "${STREAMLIT_PORT}" \
                --server.headless true
            ;;
        2)
            read -r -p "Concurrent users [10]: " LT_USERS
            LT_USERS="${LT_USERS:-10}"
            read -r -p "Spawn rate (users/s) [2]: " LT_RATE
            LT_RATE="${LT_RATE:-2}"
            read -r -p "Duration (s) [60]: " LT_DUR
            LT_DUR="${LT_DUR:-60}"

            info "Starting locust: ${LT_USERS} users, rate ${LT_RATE}/s, ${LT_DUR}s"
            OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
                locust -f "${CLIENT_DIR}/loadtest.py" \
                --headless \
                -u "${LT_USERS}" -r "${LT_RATE}" -t "${LT_DUR}s" \
                --host "http://${MCP_GATEWAY_IP}:8080"
            ;;
        3)
            info "Starting Streamlit at http://localhost:${STREAMLIT_PORT}"
            GATEWAY_IP="${MCP_GATEWAY_IP}" OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
                streamlit run "${CLIENT_DIR}/app.py" \
                --server.port "${STREAMLIT_PORT}" \
                --server.headless true &
            STREAMLIT_PID=$!

            info "Starting Locust web UI at http://localhost:${LOCUST_PORT}"
            OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
                locust -f "${CLIENT_DIR}/loadtest.py" \
                --web-port "${LOCUST_PORT}" \
                --host "http://${MCP_GATEWAY_IP}:8080" &
            LOCUST_PID=$!

            info "Streamlit PID: ${STREAMLIT_PID}, Locust PID: ${LOCUST_PID}"
            info "Press Ctrl+C to stop both."
            wait
            ;;
        4)
            info "Skipping launch. Run manually:"
            echo "  # Streamlit (MCP gateway as primary host)"
            echo "  GATEWAY_IP=${MCP_GATEWAY_IP} streamlit run ${CLIENT_DIR}/app.py"
            echo
            echo "  # Locust headless (MCP gateway)"
            echo "  locust -f ${CLIENT_DIR}/loadtest.py \\"
            echo "    --headless -u 10 -r 2 -t 60s \\"
            echo "    --host http://${MCP_GATEWAY_IP}:8080"
            echo
            echo "  # For direct LLM baseline tests, configure the Streamlit UI with:"
            echo "    host=${LLM_GATEWAY_IP}  port=8080  LLM path=/mock-openai"
            ;;
    esac
else
    echo "─────────────────────────────────────────────────────"
    info "Step 6: Skipped — client is running in-cluster"
    info "Port-forward to access the UI:"
    echo "  kubectl port-forward -n ${AGENT_NAMESPACE} svc/loadgen-client ${STREAMLIT_PORT}:${STREAMLIT_PORT}"
    echo "─────────────────────────────────────────────────────"
fi

echo

# =============================================================================
# STEP 7 — Observability hints
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 7: Observability"
echo "─────────────────────────────────────────────────────"
echo
echo "  # AgentGateway MCP proxy request logs"
echo "  kubectl logs -n ${AGW_NAMESPACE} deploy/${MCP_GW_SVC} -f"
echo
echo "  # AgentGateway LLM proxy request logs"
echo "  kubectl logs -n ${AGW_NAMESPACE} deploy/${LLM_GW_SVC} -f"
echo
echo "  # MCP server logs"
echo "  kubectl logs -n ${NAMESPACE} deploy/mcp-server-everything -f"
echo
echo "  # Prometheus port-forward"
echo "  kubectl port-forward -n monitoring svc/grafana-prometheus-kube-pr-prometheus 9090:9090"
echo "  open http://localhost:9090"
echo
echo "  # Key PromQL queries (run individually in Prometheus UI)"
echo
echo "  # p99 gateway-side request latency per route (excludes client↔LB network hop)"
echo "  histogram_quantile(0.99, sum by (le, route) (rate(agentgateway_request_duration_seconds_bucket[5m])))"
echo
echo "  # Request throughput per route (requests/sec)"
echo "  sum by (route) (rate(agentgateway_requests_total[1m]))"
echo
if [[ "${CLIENT_MODE}" == "k8s" ]]; then
    info "Streamlit UI (in-cluster):"
    echo "  kubectl port-forward -n ${AGENT_NAMESPACE} svc/loadgen-client ${STREAMLIT_PORT}:${STREAMLIT_PORT}"
    echo "  open http://localhost:${STREAMLIT_PORT}"
else
    info "Streamlit UI: http://localhost:${STREAMLIT_PORT}"
fi
echo
if [[ "${CLIENT_MODE}" == "k8s" ]]; then
    info "Streamlit UI host configurations:"
    echo
    echo "  MCP baseline / Full chain (via agentgateway-proxy-mcp):"
    echo "    host=${MCP_GW_SVC}.${AGW_NAMESPACE}.svc.cluster.local  port=8080  MCP path=/mcp  LLM path=/mock-openai"
    echo
    echo "  Direct LLM baseline (via agentgateway-proxy-llm):"
    echo "    host=${LLM_GW_SVC}.${AGW_NAMESPACE}.svc.cluster.local  port=8080  LLM path=/mock-openai"
    echo
    echo "  Direct backend (bypass agentgateway — zero-gateway baseline):"
    echo "    MCP:  host=mcp-server-everything.${NAMESPACE}.svc.cluster.local  port=8080  MCP path=/mcp"
    echo "    LLM:  host=mock-llm.${NAMESPACE}.svc.cluster.local               port=8080  LLM path=(leave blank)"
    echo
    echo "  Delta between in-cluster gateway and direct runs = pure agentgateway overhead."
fi
echo

read -r -p "Press Enter to continue to cleanup …"

# =============================================================================
# STEP 8 — Cleanup
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 8: Cleanup"
echo "─────────────────────────────────────────────────────"
echo
echo
read -r -p "Run cleanup? (removes routes and workloads) [y/N]: " DO_CLEANUP
if [[ "${DO_CLEANUP,,}" == "y" ]]; then
    kubectl delete -f "${SCRIPT_DIR}/route/" --ignore-not-found
    kubectl delete -f "${SCRIPT_DIR}/k8s/mcp-everything-deployment.yaml" --ignore-not-found
    kubectl delete -f "${SCRIPT_DIR}/k8s/mock-llm-deployment.yaml" --ignore-not-found

    if [[ "${CLIENT_MODE}" == "k8s" ]]; then
        kubectl delete -f "${SCRIPT_DIR}/k8s/agent-deployment.yaml" --ignore-not-found
        info "k8s client removed."
    else
        read -r -p "Also delete Python venv? [y/N]: " DEL_VENV
        DEL_VENV="${DEL_VENV:-n}"
        if [[ "${DEL_VENV,,}" == "y" ]]; then
            rm -rf "${CLIENT_DIR}/.venv"
            info "venv removed."
        fi
    fi
    info "Cleanup complete."
fi

echo
info "Done."
