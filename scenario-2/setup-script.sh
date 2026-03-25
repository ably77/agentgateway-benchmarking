#!/usr/bin/env bash
# =============================================================================
# Scenario 2: Multi-Client Shared Centralized Gateway Load Test
# =============================================================================
# Hop path: Client-1 ─┐
#           Client-2 ─┼─→ agw /mcp → mcp-everything sampleLLM → agw /openai → LLM
#           Client-N ─┘
#
# Steps
#   0. Configure AgentGateway proxy service type
#   1. Deploy mcp-server-everything + mock-llm to ai-platform namespace
#   2. Apply AgentGateway HTTPRoutes and backends
#   3. Get Gateway IP
#   4. Choose client count (1–5, default 3)
#   5. Choose client mode: local or k8s
#   6. Deploy/launch N clients
#   7. Print per-client port-forward commands or PID list
#
# No real OpenAI API key required — traffic routes through mock-llm (llm-d-inference-sim).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLIENT_DIR="${REPO_ROOT}/client"
NAMESPACE="ai-platform"
AGW_NAMESPACE="agentgateway-system"
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
echo " Scenario 2: Multi-Client Shared Centralized Gateway"
echo "======================================================"
echo

# =============================================================================
# STEP 0 — AgentGateway proxy service type
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 0: AgentGateway proxy service type"
echo "─────────────────────────────────────────────────────"
echo
echo "How should the agentgateway-proxy service be exposed?"
echo "  1) LoadBalancer  — assigns an external IP (GKE/EKS/AKS)"
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
# STEP 4 — Get Gateway IP
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 4: Retrieve AgentGateway gateway IP"
echo "─────────────────────────────────────────────────────"

GATEWAY_IP=""
if [[ "${AGW_SVC_TYPE}" == "LoadBalancer" ]]; then
    for i in $(seq 1 20); do
        GATEWAY_IP=$(kubectl get svc agentgateway-proxy -n "${AGW_NAMESPACE}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        [ -n "${GATEWAY_IP}" ] && break
        warn "Waiting for load-balancer IP … (${i}/20)"
        sleep 5
    done
    if [ -n "${GATEWAY_IP}" ]; then
        info "Gateway IP: ${GATEWAY_IP}"
    else
        warn "Could not obtain load-balancer IP after 100s."
    fi
fi

if [ -z "${GATEWAY_IP}" ]; then
    warn "Using port-forward on localhost:8080."
    kubectl port-forward -n "${AGW_NAMESPACE}" \
        svc/agentgateway-proxy 8080:8080 </dev/null &>/dev/null &
    PF_PID=$!
    GATEWAY_IP="localhost"
    info "Port-forward PID: ${PF_PID} (kill to stop)"
fi

export GATEWAY_IP
echo

# =============================================================================
# STEP 5 — Choose client count
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 5: Choose number of concurrent clients"
echo "─────────────────────────────────────────────────────"
echo
echo "How many independent load-gen clients should be deployed?"
echo "  Each client runs in its own namespace (agent-1 … agent-N)"
echo "  and hits the same shared AgentGateway."
echo
read -r -p "Number of clients [1-5, default 2]: " CLIENT_COUNT
CLIENT_COUNT="${CLIENT_COUNT:-2}"

# Validate range
if ! [[ "${CLIENT_COUNT}" =~ ^[1-5]$ ]]; then
    warn "Invalid client count '${CLIENT_COUNT}'. Defaulting to 3."
    CLIENT_COUNT=3
fi

info "Deploying ${CLIENT_COUNT} client(s)."
echo

# Build array of namespaces to use
AGENT_NAMESPACES=()
for i in $(seq 1 "${CLIENT_COUNT}"); do
    AGENT_NAMESPACES+=("agent-${i}")
done

# =============================================================================
# STEP 6 — Choose client mode: local or Kubernetes
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 6: Choose client deployment mode"
echo "─────────────────────────────────────────────────────"
echo
echo "How would you like to run the load-gen clients?"
echo "  1) Local  — Python venv on this machine (N Streamlit processes, ports 8501…850N)"
echo "  2) k8s    — Deploy containerized clients into the cluster (intra-cluster latency only)"
echo
read -r -p "Choice [1]: " CLIENT_MODE_CHOICE
CLIENT_MODE_CHOICE="${CLIENT_MODE_CHOICE:-1}"

if [[ "${CLIENT_MODE_CHOICE}" == "2" ]]; then
    # ── k8s mode ──────────────────────────────────────────────────────────────
    info "Deploying ${CLIENT_COUNT} loadgen client(s) to Kubernetes …"

    for i in $(seq 1 "${CLIENT_COUNT}"); do
        NS="agent-${i}"
        info "  Creating namespace '${NS}' and deploying loadgen-client-${i} …"
        kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
        kubectl apply -f "${SCRIPT_DIR}/k8s/agent-${i}-deployment.yaml"
    done

    info "Waiting for all client rollouts …"
    for i in $(seq 1 "${CLIENT_COUNT}"); do
        NS="agent-${i}"
        kubectl rollout status "deployment/loadgen-client-${i}" -n "${NS}" --timeout=120s
        info "  loadgen-client-${i} in '${NS}' is ready."
    done

    CLIENT_MODE="k8s"
else
    # ── local mode ────────────────────────────────────────────────────────────
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

    info "Launching ${CLIENT_COUNT} Streamlit process(es) in background …"
    STREAMLIT_PIDS=()
    for i in $(seq 1 "${CLIENT_COUNT}"); do
        PORT=$((8500 + i))
        info "  Starting Client ${i} on port ${PORT} …"
        GATEWAY_IP="${GATEWAY_IP}" OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
            streamlit run "${CLIENT_DIR}/app.py" \
            --server.port "${PORT}" \
            --server.headless true \
            </dev/null &>/dev/null &
        STREAMLIT_PIDS+=($!)
        info "  Client ${i} PID: ${STREAMLIT_PIDS[-1]}"
    done

    echo
    info "All ${CLIENT_COUNT} Streamlit processes started:"
    for i in $(seq 1 "${CLIENT_COUNT}"); do
        PORT=$((8500 + i))
        echo "  Client ${i}: http://localhost:${PORT}  (PID: ${STREAMLIT_PIDS[$((i-1))]})"
    done
    echo
    info "Press Ctrl+C to stop all processes, or kill PIDs individually."

    CLIENT_MODE="local"
fi
echo

# =============================================================================
# STEP 7 — Port-forward instructions (k8s mode)
# =============================================================================
if [[ "${CLIENT_MODE}" == "k8s" ]]; then
    echo "─────────────────────────────────────────────────────"
    info "Step 7: Port-forward commands to access client UIs"
    echo "─────────────────────────────────────────────────────"
    echo
    info "Run the following commands to access each client UI:"
    echo

    for i in $(seq 1 "${CLIENT_COUNT}"); do
        LOCAL_PORT=$((8500 + i))
        echo "  kubectl port-forward -n agent-${i} svc/loadgen-client-${i} ${LOCAL_PORT}:8501 &"
    done

    echo
    info "Then open each client in your browser:"
    for i in $(seq 1 "${CLIENT_COUNT}"); do
        LOCAL_PORT=$((8500 + i))
        echo "  open http://localhost:${LOCAL_PORT}  # Client ${i}"
    done
    echo
    info "Launch a locust run from each tab simultaneously to generate concurrent load."
fi
echo

# =============================================================================
# STEP 8 — Observability hints
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 8: Observability"
echo "─────────────────────────────────────────────────────"
echo
echo "  # AgentGateway request logs"
echo "  kubectl logs -n ${AGW_NAMESPACE} deploy/agentgateway -f"
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
echo "  # P99 gateway-side request latency per route (all clients combined)"
echo "  histogram_quantile(0.99, sum by (le, route) (rate(agentgateway_request_duration_seconds_bucket[5m])))"
echo
echo "  # Request throughput per route (requests/sec)"
echo "  sum by (route) (rate(agentgateway_requests_total[1m]))"
echo
echo "  # Total concurrent request rate (all clients)"
echo "  sum(rate(agentgateway_requests_total[1m]))"
echo
echo "  # Error rate per route"
echo "  sum by (route) (rate(agentgateway_requests_total{status=~\"5..\"}[1m]))"
echo
if [[ "${CLIENT_MODE}" == "k8s" ]]; then
    info "Streamlit UI host configurations (use in each client UI):"
    echo
    echo "  Via AgentGateway (in-cluster — no LB hop):"
    echo "    host=agentgateway-proxy.${AGW_NAMESPACE}.svc.cluster.local  port=8080  MCP path=/mcp  LLM path=/mock-openai"
    echo
    echo "  Via AgentGateway (LoadBalancer — includes client↔LB hop):"
    echo "    host=${GATEWAY_IP}  port=8080  MCP path=/mcp  LLM path=/mock-openai"
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
# STEP 9 — Cleanup
# =============================================================================
echo "─────────────────────────────────────────────────────"
info "Step 9: Cleanup"
echo "─────────────────────────────────────────────────────"
echo
read -r -p "Run cleanup? (removes routes, workloads, and client namespaces) [y/N]: " DO_CLEANUP
if [[ "${DO_CLEANUP,,}" == "y" ]]; then
    kubectl delete -f "${SCRIPT_DIR}/route/" --ignore-not-found
    kubectl delete -f "${SCRIPT_DIR}/k8s/mcp-everything-deployment.yaml" --ignore-not-found
    kubectl delete -f "${SCRIPT_DIR}/k8s/mock-llm-deployment.yaml" --ignore-not-found

    if [[ "${CLIENT_MODE}" == "k8s" ]]; then
        for i in $(seq 1 "${CLIENT_COUNT}"); do
            kubectl delete -f "${SCRIPT_DIR}/k8s/agent-${i}-deployment.yaml" --ignore-not-found
            kubectl delete namespace "agent-${i}" --ignore-not-found
            info "  agent-${i} removed."
        done
    else
        # Kill background streamlit processes
        for PID in "${STREAMLIT_PIDS[@]:-}"; do
            kill "${PID}" 2>/dev/null && info "  Killed Streamlit PID ${PID}." || true
        done
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
