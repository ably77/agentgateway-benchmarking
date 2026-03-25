#!/usr/bin/env bash
# reconfigure-for-scenario-2.sh
# Migrates gateway configuration from scenario-1b (two dedicated proxies) to
# the single shared agentgateway-proxy required by scenario-2.
#
# What this script does:
#   1. Removes agentgateway-proxy-mcp and agentgateway-proxy-llm Gateways
#   2. Applies updated EnterpriseAgentgatewayParameters (2 replicas, 1000m CPU / 1024Mi)
#   3. Creates the single agentgateway-proxy Gateway
#   4. Waits for the proxy to become ready

set -euo pipefail

echo "==> Removing scenario-1b dedicated proxies (MCP and LLM)..."
kubectl delete gateway agentgateway-proxy-mcp agentgateway-proxy-llm \
    -n agentgateway-system --ignore-not-found

echo "==> Updating PodMonitor to target single agentgateway-proxy..."
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
    matchLabels:
      app.kubernetes.io/name: agentgateway-proxy
EOF

echo "==> Applying scenario-2 gateway configuration (single shared proxy)..."
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
      replicas: 2
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
                cpu: 1000m
                memory: 1024Mi
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
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

echo "==> Waiting for agentgateway-proxy deployment to be created by the controller..."
for i in $(seq 1 30); do
    if kubectl get deployment agentgateway-proxy -n agentgateway-system &>/dev/null; then
        echo "    Deployment found."
        break
    fi
    echo "    Not yet (${i}/30), retrying in 5s..."
    sleep 5
done

echo "==> Waiting for agentgateway-proxy to be ready..."
kubectl rollout status deployment/agentgateway-proxy -n agentgateway-system --timeout=120s

echo ""
echo "==> Pods in agentgateway-system:"
kubectl get pods -n agentgateway-system

echo ""
echo "==> Services in agentgateway-system:"
kubectl get svc -n agentgateway-system

echo ""
echo "Done. You are now running the scenario-2 single shared proxy configuration."
echo "You can now run: scenario-2/setup-script.sh"
