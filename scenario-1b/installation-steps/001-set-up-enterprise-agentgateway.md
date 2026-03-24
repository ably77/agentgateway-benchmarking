# Install Enterprise Agentgateway

In this workshop, you'll deploy Enterprise Agentgateway and complete hands-on labs that showcase routing, security, observability, and Gen AI features.

## Pre-requisites
- Kubernetes > 1.30
- Kubernetes Gateway API

## Lab Objectives
- Configure Kubernetes Gateway API CRDs
- Configure Enterprise Agentgateway CRDs
- Install Enterprise Agentgateway Controller
- Configure two dedicated agentgateway proxies (MCP and LLM)
- Validate that components are installed

### Kubernetes Gateway API CRDs

Installing the Kubernetes Gateway API custom resources is a pre-requisite to using Enterprise Agentgateway. We're using the experimental CRDs to enable advanced features like mTLS frontend validation (lab 026). If frontend mTLS is not a requirement, you can continue with the standard install.

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```

To check if the the Kubernetes Gateway API CRDS are installed

```bash
kubectl api-resources --api-group=gateway.networking.k8s.io
```

Expected Output:

```bash
NAME                 SHORTNAMES   APIVERSION                           NAMESPACED   KIND
backendtlspolicies   btlspolicy   gateway.networking.k8s.io/v1         true         BackendTLSPolicy
gatewayclasses       gc           gateway.networking.k8s.io/v1         false        GatewayClass
gateways             gtw          gateway.networking.k8s.io/v1         true         Gateway
grpcroutes                        gateway.networking.k8s.io/v1         true         GRPCRoute
httproutes                        gateway.networking.k8s.io/v1         true         HTTPRoute
listenersets         lset         gateway.networking.k8s.io/v1         true         ListenerSet
referencegrants      refgrant     gateway.networking.k8s.io/v1         true         ReferenceGrant
tcproutes                         gateway.networking.k8s.io/v1alpha2   true         TCPRoute
tlsroutes                         gateway.networking.k8s.io/v1         true         TLSRoute
udproutes                         gateway.networking.k8s.io/v1alpha2   true         UDPRoute
```

## Install Enterprise Agentgateway

### Configure Required Variables
Export your Solo Trial license key variable and Enterprise Agentgateway version
```bash
export SOLO_TRIAL_LICENSE_KEY=$SOLO_TRIAL_LICENSE_KEY
export ENTERPRISE_AGW_VERSION=v2.2.0
```

### Enterprise Agentgateway CRDs
```bash
kubectl create namespace agentgateway-system
```

```bash
helm upgrade -i --create-namespace --namespace agentgateway-system \
    --version $ENTERPRISE_AGW_VERSION enterprise-agentgateway-crds \
    oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds
```

To check if the the Enterprise Agentgateway CRDs are installed-

```bash
kubectl api-resources | awk 'NR==1 || /enterpriseagentgateway\.solo\.io|agentgateway\.dev|ratelimit\.solo\.io|extauth\.solo\.io/'
```

Expected output

```bash
NAME                                SHORTNAMES        APIVERSION                                NAMESPACED   KIND
agentgatewaybackends                agbe              agentgateway.dev/v1alpha1                 true         AgentgatewayBackend
agentgatewayparameters              agpar             agentgateway.dev/v1alpha1                 true         AgentgatewayParameters
agentgatewaypolicies                agpol             agentgateway.dev/v1alpha1                 true         AgentgatewayPolicy
enterpriseagentgatewayparameters    eagpar            enterpriseagentgateway.solo.io/v1alpha1   true         EnterpriseAgentgatewayParameters
enterpriseagentgatewaypolicies      eagpol            enterpriseagentgateway.solo.io/v1alpha1   true         EnterpriseAgentgatewayPolicy
authconfigs                         ac                extauth.solo.io/v1                        true         AuthConfig
ratelimitconfigs                    rlc               ratelimit.solo.io/v1alpha1                true         RateLimitConfig
```

## Install Enterprise Agentgateway Controller
Using Helm:
```bash
helm upgrade -i -n agentgateway-system enterprise-agentgateway oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
--create-namespace \
--version $ENTERPRISE_AGW_VERSION \
--set-string licensing.licenseKey=$SOLO_TRIAL_LICENSE_KEY \
-f -<<EOF
#--- Optional: override for image registry/tag for the controller
#controller:
#  image:
#    registry: us-docker.pkg.dev/solo-public/enterprise-agentgateway
#    tag: "$ENTERPRISE_AGW_VERSION"
#    pullPolicy: IfNotPresent
# --- Pin controller to agentgateway node group
nodeSelector:
  workload: agentgateway
tolerations:
  - key: workload
    operator: Equal
    value: agentgateway
    effect: NoSchedule
# --- Override the default Agentgateway parameters used by this GatewayClass
# If the referenced parameters are not found, the controller will use the defaults
gatewayClassParametersRefs:
  enterprise-agentgateway:
    group: enterpriseagentgateway.solo.io
    kind: EnterpriseAgentgatewayParameters
    name: agentgateway-config
    namespace: agentgateway-system
EOF
```

Check that the Enterprise Agentgateway Controller is now running:

```bash
kubectl get pods -n agentgateway-system -l app.kubernetes.io/name=enterprise-agentgateway
```

Expected Output:

```bash
NAME                                       READY   STATUS    RESTARTS   AGE
enterprise-agentgateway-5fc9d95758-n8vvb   1/1     Running   0          87s
```

## Deploy Agentgateway with two dedicated proxies
The configuration below deploys a shared `EnterpriseAgentgatewayParameters` and two separate Gateway resources — one dedicated to MCP traffic (`agentgateway-proxy-mcp`) and one dedicated to LLM traffic (`agentgateway-proxy-llm`). Each Gateway gets its own independent proxy deployment and LoadBalancer service, providing operational isolation between traffic types while sharing the same controller and extension services (ext-auth, rate-limiter, ext-cache).

```bash
kubectl apply -f- <<'EOF'
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: agentgateway-config
  namespace: agentgateway-system
spec:
  ### -- uncomment to override shared extensions -- ###
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
      #--- Image overrides for deployment ---
      #image:
      #  registry: gcr.io
      #  repository: gloo-mesh/ext-auth-service
      #  tag: ""
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
      #--- Image overrides for deployment ---
      #image:
      #  registry: gcr.io
      #  repository: gloo-mesh/rate-limiter
      #  tag: ""
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
      #--- Image overrides for deployment ---
      #image:
      #  registry: docker.io
      #  repository: redis
      #  tag: ""
  logging:
    level: warn
  #--- Image overrides for deployment ---
  #image:
  #  registry: us-docker.pkg.dev
  #  repository: solo-public/enterprise-agentgateway/agentgateway-enterprise
  #  tag: ""
  service:
    metadata:
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    spec:
      type: LoadBalancer
  #--- Use rawConfig to inline custom configuration from ConfigMap ---
  rawConfig:
    config:
      # --- Label all metrics using a value extracted from the request body
      #metrics:
      #  fields:
      #    add:
      #      modelId: json(request.body).modelId
      logging:
        fields:
          add:
            # --- Capture the claims from a verified JWT token if JWT policy is enabled
            jwt: 'jwt'
            # --- Capture a single request header by name (example: x-foo)
            x-foo: 'request.headers["x-foo"]'
            # --- Capture entire request body and parse it as JSON
            request.body: json(request.body)
            # --- Capture entire response body and parse it as JSON
            response.body: json(response.body)
            # --- Capture a field in the request body
            request.body.modelId: json(request.body).modelId
        format: json
      tracing:
        otlpProtocol: grpc
        otlpEndpoint: http://tempo-distributor.monitoring.svc.cluster.local:4317
        randomSampling: 'true'
        fields:
          add:
            # --- Capture the claims from a verified JWT token if JWT policy is enabled
            jwt: 'jwt'
            # --- Capture entire response body and parse it as JSON
            response.body: 'json(response.body)'
            # --- Capture a single request header by name (example: x-foo)
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

Check that both Agentgateway proxies are now running:

```bash
kubectl get pods -n agentgateway-system
```

Expected Output:

```bash
NAME                                                        READY   STATUS    RESTARTS   AGE
agentgateway-proxy-llm-6ccb7848b4-nt7qk                    1/1     Running   0          21s
agentgateway-proxy-llm-6ccb7848b4-p8mxj                    1/1     Running   0          21s
agentgateway-proxy-mcp-7dd8c959b5-kw2nl                    1/1     Running   0          21s
agentgateway-proxy-mcp-7dd8c959b5-r5vhp                    1/1     Running   0          21s
enterprise-agentgateway-c5c748bbd-m8l4k                    1/1     Running   0          91s
ext-auth-service-enterprise-agentgateway-6dd5dbff7b-85xkh  1/1     Running   0          20s
ext-cache-enterprise-agentgateway-67d75d8b48-fx676         1/1     Running   0          21s
rate-limiter-enterprise-agentgateway-7d46cb8df9-wr6c7      1/1     Running   0          21s
```

Verify both Gateway services have been assigned external IPs:

```bash
kubectl get svc -n agentgateway-system
```

Expected Output:

```bash
NAME                                         TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)          AGE
agentgateway-proxy-llm                       LoadBalancer   10.96.10.1      <pending>        8080:31234/TCP   25s
agentgateway-proxy-mcp                       LoadBalancer   10.96.10.2      <pending>        8080:31235/TCP   25s
enterprise-agentgateway                      ClusterIP      10.96.10.3      <none>           9977/TCP         95s
ext-auth-service-enterprise-agentgateway     ClusterIP      10.96.10.4      <none>           8083/TCP         24s
ext-cache-enterprise-agentgateway            ClusterIP      10.96.10.5      <none>           6379/TCP         24s
rate-limiter-enterprise-agentgateway         ClusterIP      10.96.10.6      <none>           8084/TCP         24s
```
