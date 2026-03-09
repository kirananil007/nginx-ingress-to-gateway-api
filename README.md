# nginx Ingress → Kubernetes Gateway API

`ingress-nginx` reached end-of-life in early 2026. If you're still running it,
this is your sign to migrate. I spent a weekend building this demo on a local
kind cluster to understand what the migration actually looks like end-to-end.

---

## The problem with Ingress

The Ingress API was added in 2015 and it shows. The core issue isn't that it
doesn't work — it's that all configuration lives in annotations:

```yaml
nginx.ingress.kubernetes.io/rewrite-target: /$2
nginx.ingress.kubernetes.io/use-regex: "true"
nginx.ingress.kubernetes.io/proxy-body-size: 10m
nginx.ingress.kubernetes.io/ssl-redirect: "true"
```

These are strings. The API server doesn't validate them. They're nginx-specific,
so if you switch controllers you rewrite everything. And there's no way to let
app teams control their routing without also giving them access to infra-level config.

Gateway API fixes all of this by splitting the concern into three resources with
clear ownership:

```
GatewayClass  →  owned by the platform/infra team   (which controller to use)
Gateway       →  owned by the platform team          (what ports/protocols to expose)
HTTPRoute     →  owned by the app team               (how to route app traffic)
```

Before, one `Ingress` resource mixed all three. Now each layer has a clear owner.

---

## How the pieces map

```
BEFORE                                AFTER
──────────────────────────────────────────────────────────────
IngressClass                    →     GatewayClass
Ingress Controller Service      →     Gateway
Ingress                         →     HTTPRoute

spec.rules[].host               →     HTTPRoute.spec.hostnames[]
spec.rules[].http.paths         →     HTTPRoute.spec.rules[].matches[]
spec.rules[].backend            →     HTTPRoute.spec.rules[].backendRefs[]
nginx.ingress.io/rewrite-target →     HTTPRoute filters.URLRewrite  (typed!)
spec.tls                        →     Gateway.spec.listeners[].tls
```

---

## What's in this repo

```
nginx-to-gateway-api/
├── kind-cluster.yaml
├── 01-apps/
│   ├── app1.yaml              # simple echo service ("Frontend")
│   └── app2.yaml              # simple echo service ("Backend API")
├── 02-nginx-ingress/
│   └── ingress.yaml           # classic Ingress with nginx annotations
├── 03-gateway-api/
│   ├── envoyproxy.yaml        # tells Envoy Gateway to use NodePort (required for kind)
│   ├── gatewayclass.yaml      # cluster-wide: use Envoy Gateway
│   ├── gateway.yaml           # listen on port 80, allow routes from 'demo' ns
│   └── httproute.yaml         # /app1 → app1-svc, /app2 → app2-svc
└── Makefile
```

---

## Prerequisites

- `kind` v0.25+
- `kubectl` v1.26+
- `helm` v3.14+
- Docker running

---

## Phase 1 — Get nginx ingress working

### Create the cluster

```bash
kind create cluster --config kind-cluster.yaml --name nginx-to-gateway
```

The cluster maps host port `18080` to container port `80` (not `8080` — that's
almost always taken on a Mac).

### Install ingress-nginx

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

The kind-specific manifest uses `hostNetwork: true`, so nginx binds to port 80
on the kind node directly, which flows to host port 18080.

### Deploy the apps and Ingress

```bash
kubectl create namespace demo
kubectl apply -f 01-apps/ -n demo
kubectl apply -f 02-nginx-ingress/ingress.yaml -n demo
```

The Ingress:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  rules:
    - host: demo.local
      http:
        paths:
          - path: /app1(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: app1-svc
                port:
                  number: 80
          - path: /app2(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: app2-svc
                port:
                  number: 80
```

### Test it

```bash
curl -H "Host: demo.local" http://localhost:18080/app1
# Hello from App1 (Frontend Service) 🚀

curl -H "Host: demo.local" http://localhost:18080/app2
# Hello from App2 (Backend API Service) ⚙️
```

Works. But look at that Ingress — regex path matching, controller-specific annotations,
no separation between infra config and app routing. This is what we're replacing.

---

## Phase 2 — Set up Gateway API alongside nginx

We'll run both in parallel first, verify everything works, then cut over.

### Install Envoy Gateway

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.3.0 \
  --namespace envoy-gateway-system \
  --create-namespace \
  --wait
```

Helm will print warnings about `unrecognized format "int64"/"int32"` — ignore them,
it's a version skew between kubectl and the newer CRD format validators. The install works fine.

This deploys the Envoy Gateway controller and installs the Gateway API CRDs (v1.2).

### Apply Gateway API resources

Order matters here — apply `envoyproxy.yaml` before `gatewayclass.yaml`:

```bash
kubectl apply -f 03-gateway-api/envoyproxy.yaml    # must be first
kubectl apply -f 03-gateway-api/gatewayclass.yaml
kubectl apply -f 03-gateway-api/gateway.yaml
kubectl apply -f 03-gateway-api/httproute.yaml
```

**Why `envoyproxy.yaml` first?** By default, Envoy Gateway creates a `LoadBalancer`
service for the proxy. kind has no cloud provider, so that IP never gets assigned
and the Gateway stays `PROGRAMMED=False`. The `EnvoyProxy` resource switches it to
`NodePort` so the Gateway can actually come up.

```yaml
# envoyproxy.yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: kind-proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
```

The `GatewayClass` references this config via `parametersRef` — something
`IngressClass` could never do:

```yaml
# gatewayclass.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: kind-proxy-config
    namespace: envoy-gateway-system
```

The `Gateway` defines what ports to listen on and which namespaces can attach routes:

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo-gateway
  namespace: demo
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

`allowedRoutes.namespaces.from: Same` is worth calling out — it means only
HTTPRoutes in the `demo` namespace can attach to this Gateway. Built-in
multi-tenancy, no extra policy needed.

And the `HTTPRoute` — notice how clean this is compared to the Ingress above:

```yaml
# httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo-httproute
  namespace: demo
spec:
  parentRefs:
    - name: demo-gateway
  hostnames:
    - "demo.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /app1
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: app1-svc
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /app2
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: app2-svc
          port: 80
```

No annotations. No regex. The path rewrite is a typed `URLRewrite` filter — the
API server validates it. And this same YAML works on Cilium, Istio, Traefik, or
any other Gateway API conformant controller.

### Verify and test

```bash
kubectl get gatewayclass,gateway,httproute -A
# gatewayclass/eg          Accepted: True
# gateway/demo-gateway     Programmed: True   ADDRESS: 172.18.0.5
# httproute/demo-httproute hostnames: ["demo.local"]
```

Envoy Gateway provisions a dedicated proxy pod in `envoy-gateway-system`. On Mac,
the kind node IP isn't reachable from the host directly (Docker runs in a VM),
so use port-forward:

```bash
ENVOY_SVC=$(kubectl get svc -n envoy-gateway-system --no-headers \
  -o custom-columns=":metadata.name" | grep envoy-demo)

kubectl port-forward -n envoy-gateway-system svc/$ENVOY_SVC 9090:80 &

curl -H "Host: demo.local" http://localhost:9090/app1
# Hello from App1 (Frontend Service) 🚀

curl -H "Host: demo.local" http://localhost:9090/app2
# Hello from App2 (Backend API Service) ⚙️
```

Same result. Different (better) control plane.

---

## Phase 3 — Cut over

```bash
# Drop the Ingress resource — nginx stops routing
kubectl delete ingress demo-ingress -n demo

# Remove ingress-nginx entirely
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml

# Confirm it's gone
kubectl get ns ingress-nginx   # NotFound
```

Gateway API still serving:
```bash
curl -H "Host: demo.local" http://localhost:9090/app1
# Hello from App1 (Frontend Service) 🚀
```

Done. nginx is gone, apps are still up.

---

## One thing Gateway API gets you for free — traffic splitting

With Ingress, canary deployments require multiple Ingress objects, the
`nginx.ingress.kubernetes.io/canary` annotation family, and a lot of careful
coordination. With HTTPRoute it's one field:

```yaml
backendRefs:
  - name: app1-svc-stable
    port: 80
    weight: 90
  - name: app1-svc-canary
    port: 80
    weight: 10
```

10% of traffic to canary, 90% stable. No annotations, no second Ingress object,
works on any conformant controller.

---

## Gotchas I hit during this

**Port 8080 already in use** — almost guaranteed on a Mac (AirPlay, React dev servers,
etc.). Switched to 18080 in the kind cluster config.

**Gateway stuck at PROGRAMMED=False** — Envoy Gateway defaults to `LoadBalancer`
service type. kind has no cloud provider so the IP never gets assigned.
Fix is `envoyproxy.yaml` with `type: NodePort`, applied before the GatewayClass.

**`helm install` failing with "cannot re-use a name"** — left over from a previous
failed attempt. `helm upgrade --install` handles both fresh installs and retries.

**Envoy proxy service ends up in `envoy-gateway-system`, not `demo`** — the proxy
pod/service lives where the controller lives, not where the Gateway resource is.
Something to keep in mind when writing port-forward commands.

---

## Cleanup

```bash
kill $(lsof -t -i:9090) $(lsof -t -i:18080) 2>/dev/null
kind delete cluster --name nginx-to-gateway
```

---

## Tools

- [kind](https://kind.sigs.k8s.io/) — local Kubernetes via Docker
- [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) — the controller we're migrating away from
- [Envoy Gateway](https://gateway.envoyproxy.io/) — CNCF project, Gateway API implementation on Envoy Proxy
- [Gateway API](https://gateway-api.sigs.k8s.io/) — the spec itself (v1.2 GA)

---

*Tested on macOS (Apple Silicon) · kind v0.30 · kubectl v1.29 · Envoy Gateway v1.3.0*
