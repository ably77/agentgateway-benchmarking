#!/usr/bin/env bash
# switch-from-1a.sh
# Migrates gateway configuration from scenario-1a (single proxy) to
# scenario-1b (two dedicated proxies: MCP and LLM).
#
# What this script does:
#   1. Removes the single agentgateway-proxy Gateway from scenario-1a
#   2. Applies the updated EnterpriseAgentgatewayParameters (1 replica, 750m CPU / 512Mi)
#   3. Creates two dedicated Gateway resources: agentgateway-proxy-mcp and agentgateway-proxy-llm
#   4. Waits for both proxies to become ready

set -euo pipefail

echo "==> Removing scenario-1a single gateway proxy..."
kubectl delete gateway agentgateway-proxy -n agentgateway-system --ignore-not-found

echo "==> Updating PodMonitor to target both dedicated proxies (MCP and LLM)..."
kubectl apply -f- <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: data-plane-monitoring-agentgateway-metrics
  namespace: agentgateway-system
spec:
  namespaceSelector:
    matchNames:
      - agentgateway-system
  podMetricsEndpoints:
    - port: metrics
  selector:
    matchExpressions:
      - key: app.kubernetes.io/name
        operator: In
        values:
          - agentgateway-proxy-mcp
          - agentgateway-proxy-llm
EOF

echo "==> Applying scenario-1b configuration (two dedicated proxies: MCP and LLM)..."
kubectl apply -f- <<'EOF'
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: agentgateway-config
  namespace: agentgateway-system
spec:
  sharedExtensions:
    extauth:
      enabled: true
      deployment:
        spec:
          replicas: 1
          template:
            spec:
              nodeSelector:
                workload: agentgateway
              tolerations:
                - key: workload
                  operator: Equal
                  value: agentgateway
                  effect: NoSchedule
              containers:
                - name: ext-auth-service
                  resources:
                    requests:
                      cpu: 500m
                      memory: 256Mi
                    limits:
                      cpu: 500m
                      memory: 256Mi
    ratelimiter:
      enabled: true
      deployment:
        spec:
          replicas: 1
          template:
            spec:
              nodeSelector:
                workload: agentgateway
              tolerations:
                - key: workload
                  operator: Equal
                  value: agentgateway
                  effect: NoSchedule
              containers:
                - name: rate-limiter
                  resources:
                    requests:
                      cpu: 500m
                      memory: 256Mi
                    limits:
                      cpu: 500m
                      memory: 256Mi
    extCache:
      enabled: true
      deployment:
        spec:
          replicas: 1
          template:
            spec:
              nodeSelector:
                workload: agentgateway
              tolerations:
                - key: workload
                  operator: Equal
                  value: agentgateway
                  effect: NoSchedule
              containers:
                - name: redis
                  resources:
                    requests:
                      cpu: 500m
                      memory: 256Mi
                    limits:
                      cpu: 500m
                      memory: 256Mi
  logging:
    level: warn
  service:
    metadata:
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    spec:
      type: LoadBalancer
  rawConfig:
    config:
      logging:
        fields:
          add:
            jwt: 'jwt'
            x-foo: 'request.headers["x-foo"]'
            request.body: json(request.body)
            response.body: json(response.body)
            request.body.modelId: json(request.body).modelId
        format: json
      tracing:
        otlpProtocol: grpc
        otlpEndpoint: http://tempo-distributor.monitoring.svc.cluster.local:4317
        randomSampling: 'true'
        fields:
          add:
            jwt: 'jwt'
            response.body: 'json(response.body)'
            x-foo: 'request.headers["x-foo"]'
  deployment:
    spec:
      replicas: 1
      template:
        spec:
          nodeSelector:
            workload: agentgateway
          tolerations:
            - key: workload
              operator: Equal
              value: agentgateway
              effect: NoSchedule
          containers:
          - name: agentgateway
            resources:
              requests:
                cpu: 750m
                memory: 512Mi
---
# Dedicated MCP proxy — handles /mcp routes only
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy-mcp
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      port: 8080
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
---
# Dedicated LLM proxy — handles /mock-openai routes only
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy-llm
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      port: 8080
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
EOF

echo "==> Waiting for agentgateway-proxy-mcp deployment to be created by the controller..."
for i in $(seq 1 30); do
    if kubectl get deployment agentgateway-proxy-mcp -n agentgateway-system &>/dev/null; then
        echo "    Deployment found."
        break
    fi
    echo "    Not yet (${i}/30), retrying in 5s..."
    sleep 5
done

echo "==> Waiting for agentgateway-proxy-mcp to be ready..."
kubectl rollout status deployment/agentgateway-proxy-mcp -n agentgateway-system --timeout=120s

echo "==> Waiting for agentgateway-proxy-llm deployment to be created by the controller..."
for i in $(seq 1 30); do
    if kubectl get deployment agentgateway-proxy-llm -n agentgateway-system &>/dev/null; then
        echo "    Deployment found."
        break
    fi
    echo "    Not yet (${i}/30), retrying in 5s..."
    sleep 5
done

echo "==> Waiting for agentgateway-proxy-llm to be ready..."
kubectl rollout status deployment/agentgateway-proxy-llm -n agentgateway-system --timeout=120s

echo ""
echo "==> Pods in agentgateway-system:"
kubectl get pods -n agentgateway-system

echo ""
echo "==> Services in agentgateway-system:"
kubectl get svc -n agentgateway-system

echo ""
echo "Done. You are now running scenario-1b with two dedicated proxies (MCP + LLM)."
