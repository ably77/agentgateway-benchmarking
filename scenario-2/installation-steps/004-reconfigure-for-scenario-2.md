# Reconfigure Gateways for Scenario 2

This step tears down the scenario-1b dual-proxy configuration and replaces it with the single shared `agentgateway-proxy` required by scenario-2.

## What changes

| | Scenario 1b | Scenario 2 |
|---|---|---|
| Gateways | `agentgateway-proxy-mcp` + `agentgateway-proxy-llm` | `agentgateway-proxy` (single) |
| Replicas | 1 per proxy | 2 |
| CPU request | 750m | 1000m |
| Memory request | 512Mi | 1024Mi |

## Steps

### 1. Remove the scenario-1b dedicated proxies

```bash
kubectl delete gateway agentgateway-proxy-mcp agentgateway-proxy-llm -n agentgateway-system --ignore-not-found
```

### 2. Update the PodMonitor to target the single proxy

Scenario-1b's PodMonitor selects both `agentgateway-proxy-mcp` and `agentgateway-proxy-llm` via `matchExpressions`. Scenario-2 uses a single `agentgateway-proxy`, so update it to use `matchLabels` instead:

```bash
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
```

### 3. Apply the scenario-2 gateway configuration

This updates `EnterpriseAgentgatewayParameters` to the higher-resource profile and creates the single `agentgateway-proxy` Gateway.

```bash
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
```

### 4. Verify the proxy is running

```bash
kubectl get pods -n agentgateway-system
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

### 5. Verify the service has an external IP

```bash
kubectl get svc agentgateway-proxy -n agentgateway-system
```

You are now ready to run the scenario-2 `setup-script.sh`.
