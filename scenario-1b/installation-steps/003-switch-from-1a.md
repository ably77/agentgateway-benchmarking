# Switch from Scenario 1a to Scenario 1b

This step migrates the gateway configuration from scenario-1a (single shared proxy) to scenario-1b (two dedicated proxies — one for MCP traffic, one for LLM traffic).

## What changes

| | Scenario 1a | Scenario 1b |
|---|---|---|
| Gateways | `agentgateway-proxy` (single) | `agentgateway-proxy-mcp` + `agentgateway-proxy-llm` |
| Replicas | 2 | 1 per proxy |
| CPU request | 1000m | 750m |
| Memory request | 1024Mi | 512Mi |
| PodMonitor selector | `agentgateway-proxy` | `agentgateway-proxy-mcp` + `agentgateway-proxy-llm` |

## Steps

### 1. Remove the scenario-1a single gateway proxy

```bash
kubectl delete gateway agentgateway-proxy -n agentgateway-system --ignore-not-found
```

### 2. Update the PodMonitor to target both dedicated proxies

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
    matchExpressions:
      - key: app.kubernetes.io/name
        operator: In
        values:
          - agentgateway-proxy-mcp
          - agentgateway-proxy-llm
EOF
```

### 3. Apply the scenario-1b gateway configuration

This updates `EnterpriseAgentgatewayParameters` to the lower-resource profile and creates the two dedicated Gateway resources.

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
```

### 4. Verify both proxies are running

The controller needs a moment to create the Deployments after the Gateway resources are applied.

```bash
kubectl get pods -n agentgateway-system
```

Expected output:

```
NAME                                                        READY   STATUS    RESTARTS   AGE
agentgateway-proxy-llm-6ccb7848b4-nt7qk                    1/1     Running   0          21s
agentgateway-proxy-mcp-7dd8c959b5-kw2nl                    1/1     Running   0          21s
enterprise-agentgateway-c5c748bbd-m8l4k                    1/1     Running   0          91s
ext-auth-service-enterprise-agentgateway-6dd5dbff7b-85xkh  1/1     Running   0          20s
ext-cache-enterprise-agentgateway-67d75d8b48-fx676         1/1     Running   0          21s
rate-limiter-enterprise-agentgateway-7d46cb8df9-wr6c7      1/1     Running   0          21s
```

### 5. Verify both Gateway services have external IPs

```bash
kubectl get svc -n agentgateway-system
```

Expected output:

```
NAME                                         TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)          AGE
agentgateway-proxy-llm                       LoadBalancer   10.96.10.1      <pending>        8080:31234/TCP   25s
agentgateway-proxy-mcp                       LoadBalancer   10.96.10.2      <pending>        8080:31235/TCP   25s
enterprise-agentgateway                      ClusterIP      10.96.10.3      <none>           9977/TCP         95s
ext-auth-service-enterprise-agentgateway     ClusterIP      10.96.10.4      <none>           8083/TCP         24s
ext-cache-enterprise-agentgateway            ClusterIP      10.96.10.5      <none>           6379/TCP         24s
rate-limiter-enterprise-agentgateway         ClusterIP      10.96.10.6      <none>           8084/TCP         24s
```

You can also run the automated script: `switch-from-1a.sh`
