.PHONY: all create-cluster install-nginx-ingress deploy-apps setup-ingress \
        test-nginx install-envoy-gateway setup-gateway-api test-gateway \
        migrate-to-gateway cleanup status help

CLUSTER_NAME   := nginx-to-gateway
NAMESPACE      := demo
NGINX_VERSION  := controller-v1.12.0
EG_VERSION     := v1.3.0

# ─────────────────────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────────────────────
help: ## Show this help
	@echo ""
	@echo "  nginx-to-gateway-api demo"
	@echo "  ─────────────────────────"
	@echo "  PHASE 1 — Run nginx ingress (the old way)"
	@echo "    make create-cluster        → Spin up a kind cluster"
	@echo "    make install-nginx-ingress → Install ingress-nginx controller"
	@echo "    make deploy-apps           → Deploy sample apps"
	@echo "    make setup-ingress         → Apply Ingress resource"
	@echo "    make test-nginx            → Verify routing via nginx"
	@echo ""
	@echo "  PHASE 2 — Migrate to Gateway API"
	@echo "    make install-envoy-gateway → Install Envoy Gateway controller"
	@echo "    make setup-gateway-api     → Apply GatewayClass + Gateway + HTTPRoute"
	@echo "    make test-gateway          → Verify routing via Envoy Gateway"
	@echo "    make migrate-to-gateway    → Remove nginx ingress (full cutover)"
	@echo ""
	@echo "  UTILITIES"
	@echo "    make status   → Show cluster state"
	@echo "    make cleanup  → Delete the kind cluster"
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: NGINX INGRESS
# ─────────────────────────────────────────────────────────────────────────────

create-cluster: ## Create kind cluster
	@echo "\n==> Creating kind cluster: $(CLUSTER_NAME)"
	kind create cluster --config kind-cluster.yaml --name $(CLUSTER_NAME)
	@echo "==> Cluster ready!"
	kubectl cluster-info --context kind-$(CLUSTER_NAME)

install-nginx-ingress: ## Install ingress-nginx (kind-specific manifest)
	@echo "\n==> Installing ingress-nginx $(NGINX_VERSION)"
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(NGINX_VERSION)/deploy/static/provider/kind/deploy.yaml
	@echo "\n==> Waiting for ingress-nginx controller to be ready..."
	kubectl wait --namespace ingress-nginx \
	  --for=condition=ready pod \
	  --selector=app.kubernetes.io/component=controller \
	  --timeout=120s
	@echo "==> ingress-nginx is ready!"

deploy-apps: ## Deploy sample applications (app1 + app2)
	@echo "\n==> Creating namespace: $(NAMESPACE)"
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@echo "\n==> Deploying app1 and app2"
	kubectl apply -f 01-apps/ -n $(NAMESPACE)
	@echo "\n==> Waiting for pods to be ready..."
	kubectl wait --namespace $(NAMESPACE) \
	  --for=condition=ready pod \
	  --selector=app=app1 \
	  --timeout=60s
	kubectl wait --namespace $(NAMESPACE) \
	  --for=condition=ready pod \
	  --selector=app=app2 \
	  --timeout=60s
	@echo "==> Apps are running!"
	kubectl get pods -n $(NAMESPACE)

setup-ingress: ## Apply Ingress resource pointing to app1 and app2
	@echo "\n==> Applying Ingress resource"
	kubectl apply -f 02-nginx-ingress/ingress.yaml -n $(NAMESPACE)
	kubectl get ingress -n $(NAMESPACE)
	@echo "\n==> Ingress is configured!"

test-nginx: ## Test nginx ingress routing (uses port 18080 mapped from kind)
	@echo "\n==> Testing nginx ingress routing"
	@echo "    Host: demo.local  Port: 18080 (mapped from kind container port 80)"
	@echo ""
	@echo "--- Hitting /app1 ---"
	curl -s -H "Host: demo.local" http://localhost:18080/app1 || \
	  (echo "\nTip: Make sure kind port 80 is mapped. Try port-forward:" && \
	   echo "  kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80")
	@echo ""
	@echo "--- Hitting /app2 ---"
	curl -s -H "Host: demo.local" http://localhost:18080/app2 || true
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: GATEWAY API MIGRATION
# ─────────────────────────────────────────────────────────────────────────────

install-envoy-gateway: ## Install Envoy Gateway via Helm (includes Gateway API CRDs)
	@echo "\n==> Installing Envoy Gateway $(EG_VERSION)"
	@echo "    (This also installs Gateway API CRDs v1.2)"
	helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
	  --version $(EG_VERSION) \
	  --namespace envoy-gateway-system \
	  --create-namespace \
	  --wait
	@echo "\n==> Waiting for Envoy Gateway to be ready..."
	kubectl wait --namespace envoy-gateway-system \
	  --for=condition=available deployment/envoy-gateway \
	  --timeout=120s
	@echo "\n==> Gateway API CRDs installed:"
	kubectl get crd | grep gateway.networking.k8s.io
	@echo "==> Envoy Gateway is ready!"

setup-gateway-api: ## Apply GatewayClass, Gateway, and HTTPRoute
	@echo "\n==> Applying Gateway API resources"
	@echo "    Step 1: GatewayClass (cluster-scoped)"
	kubectl apply -f 03-gateway-api/gatewayclass.yaml
	@echo "    Step 2: Gateway (namespace: $(NAMESPACE))"
	kubectl apply -f 03-gateway-api/gateway.yaml
	@echo "    Step 3: HTTPRoute (namespace: $(NAMESPACE))"
	kubectl apply -f 03-gateway-api/httproute.yaml
	@echo "\n==> Waiting for Gateway to be programmed..."
	kubectl wait --namespace $(NAMESPACE) \
	  --for=condition=Programmed gateway/demo-gateway \
	  --timeout=90s
	@echo "\n==> Gateway API resources:"
	kubectl get gatewayclass,gateway,httproute -A

test-gateway: ## Test Envoy Gateway routing (NodePort 30080)
	@echo "\n==> Testing Envoy Gateway routing"
	@echo "    NodePort: 30080 (mapped from kind container port 30080)"
	@echo ""
	@echo "--- Hitting /app1 ---"
	curl -s -H "Host: demo.local" http://localhost:30080/app1 || \
	  (echo "\nNodePort not available. Trying port-forward..." && \
	   echo "Run: kubectl port-forward -n envoy-gateway-system svc/\$$(kubectl get svc -n envoy-gateway-system -o name | grep envoyroxy | head -1 | cut -d/ -f2) 30080:80")
	@echo ""
	@echo "--- Hitting /app2 ---"
	curl -s -H "Host: demo.local" http://localhost:30080/app2 || true
	@echo ""

migrate-to-gateway: ## Remove nginx ingress — full cutover to Gateway API
	@echo "\n==> Removing nginx Ingress resource"
	kubectl delete ingress demo-ingress -n $(NAMESPACE) --ignore-not-found
	@echo "\n==> Removing ingress-nginx controller"
	kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(NGINX_VERSION)/deploy/static/provider/kind/deploy.yaml --ignore-not-found
	@echo "\n==> Migration complete! Traffic now flows through Envoy Gateway."
	@echo "    Test: curl -H 'Host: demo.local' http://localhost:30080/app1"

# ─────────────────────────────────────────────────────────────────────────────
# UTILITIES
# ─────────────────────────────────────────────────────────────────────────────

status: ## Show cluster state
	@echo "\n==> Nodes"
	kubectl get nodes
	@echo "\n==> Pods (all namespaces)"
	kubectl get pods -A
	@echo "\n==> Ingress resources"
	kubectl get ingress -A 2>/dev/null || echo "  (none)"
	@echo "\n==> Gateway API resources"
	kubectl get gatewayclass,gateway,httproute -A 2>/dev/null || echo "  (Gateway API CRDs not installed)"

cleanup: ## Delete the kind cluster
	@echo "\n==> Deleting kind cluster: $(CLUSTER_NAME)"
	kind delete cluster --name $(CLUSTER_NAME)
	@echo "==> Done!"
