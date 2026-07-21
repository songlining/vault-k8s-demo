.PHONY: help setup clusters setup-vault setup-vso configure-vso-auth configure-vso-jwt-auth vso-apply \
        demo verify status logs-otel logs-agent \
        vso-demo vso-deck vso-verify vso-status logs-vso \
        check-vault-connectivity verify-two-cluster \
        configure-auth-delegator auth-delegator-apply auth-delegator-setup \
        auth-delegator-verify auth-delegator-status auth-delegator-deck
.DEFAULT_GOAL := help

# --------------------------------------------------------------------------
# Two-cluster (Podman-backed kind) context defaults.
#
# Vault runs only in $(VAULT_CONTEXT); VSO, its CRDs, and vso-demo-app run
# only in $(VSO_CONTEXT). Override any of these on the command line or in
# the environment, e.g.:
#   make setup VAULT_CONTEXT=kind-vault-lab VSO_CONTEXT=kind-vso-lab
# The scripts in scripts/ (via scripts/lib/two-cluster-env.sh) apply the
# same defaults if these are left unset, so exporting them here keeps `make
# help` accurate without forcing a value on every script invocation.
# --------------------------------------------------------------------------
VAULT_CONTEXT ?= kind-vault-lab
VSO_CONTEXT ?= kind-vso-lab
TWO_CLUSTER_HOST ?= host.containers.internal
VAULT_HOST_PORT ?= 8200
VSO_API_HOST_PORT ?= 6444
VAULT_ADDR ?= http://$(TWO_CLUSTER_HOST):$(VAULT_HOST_PORT)
VSO_API_ADDR ?= https://$(TWO_CLUSTER_HOST):$(VSO_API_HOST_PORT)

export VAULT_CONTEXT
export VSO_CONTEXT
export TWO_CLUSTER_HOST
export VAULT_HOST_PORT
export VSO_API_HOST_PORT
export VAULT_ADDR
export VSO_API_ADDR

help: ## Show available demo commands
	@echo "Two-cluster Podman-backed kind demo (VAULT_CONTEXT=$(VAULT_CONTEXT), VSO_CONTEXT=$(VSO_CONTEXT))"
	@echo "Requires: export KIND_EXPERIMENTAL_PROVIDER=podman"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

## --- Two-cluster setup (Podman-backed kind) ------------------------------

setup: ## Run the full two-cluster setup: clusters, Vault, VSO, JWT/OIDC cross-cluster auth, VSO demo apply
	@bash scripts/create-clusters.sh
	@bash scripts/setup-vault-cluster.sh
	@bash scripts/setup-vso-cluster.sh
	@bash scripts/configure-vso-jwt-auth.sh
	@bash scripts/apply-vso-demo.sh

clusters: ## Create/validate the kind-vault-lab and kind-vso-lab Podman-backed kind clusters
	@bash scripts/create-clusters.sh

setup-vault: ## Install and configure Vault in the Vault cluster (VAULT_CONTEXT) only
	@bash scripts/setup-vault-cluster.sh

setup-vso: ## Install VSO and create vso-demo namespace/service accounts in the VSO cluster (VSO_CONTEXT) only
	@bash scripts/setup-vso-cluster.sh

configure-vso-auth: configure-vso-jwt-auth ## Alias for configure-vso-jwt-auth (default JWT/OIDC auth setup, compatibility entry point)

configure-vso-jwt-auth: ## Configure auth/jwt-vso through the VSO cluster's OIDC discovery URL and advertised JWKS
	@bash scripts/configure-vso-jwt-auth.sh

vso-apply: ## Apply VSO CRDs (VaultConnection/VaultAuth/VaultStaticSecret) and vso-demo-app in the VSO cluster
	@bash scripts/apply-vso-demo.sh

check-vault-connectivity: ## Prove a pod in the VSO cluster can reach Vault at VAULT_ADDR
	@bash scripts/check-vault-connectivity.sh

verify-two-cluster: ## Full end-to-end two-cluster proof: placement, network, auth, VSO sync, and rotation
	@bash scripts/verify-two-cluster.sh

## --- Guided demo flows -----------------------------------------------------

demo: ## Run the guided live demo flow (single-cluster Agent Injector/OTel demo)
	@bash demo.sh

vso-demo: ## Run the guided Vault Secrets Operator (VSO) demo flow across both clusters
	@bash vso-demo.sh

vso-deck: ## Start and reuse a healthy lab; reconcile only when needed, then run the Presenterm VSO deck
	@command -v presenterm >/dev/null 2>&1 || { echo "presenterm not installed: brew install presenterm"; exit 1; }
	@echo "==> [vso-deck 1/3] Starting Podman and existing kind control planes"
	@KIND_EXPERIMENTAL_PROVIDER=podman bash scripts/prepare-vso-deck-env.sh
	@set -e; \
		echo "==> [vso-deck 2/3] Verifying the existing two-cluster environment"; \
		if $(MAKE) --no-print-directory verify-two-cluster; then \
			echo "==> Existing resources are healthy; skipping setup and reusing them unchanged."; \
		else \
			echo "==> Existing resources are incomplete or unhealthy; running setup once, then re-verifying."; \
			KIND_EXPERIMENTAL_PROVIDER=podman $(MAKE) --no-print-directory setup; \
			$(MAKE) --no-print-directory verify-two-cluster; \
		fi
	@echo "==> [vso-deck 3/3] All checkpoints passed; launching Presenterm"
	@exec presenterm -x presenterm/vso.md

## --- Verify/status/logs: single-cluster Agent Injector/OTel demo (Vault cluster) --

verify: ## Verify the single-cluster Agent Injector/OTel demo environment is ready (current kubectl context)
	@echo "Current context:"
	@kubectl config current-context
	@echo ""
	@echo "Default namespace:"
	@kubectl get pods -n default
	@echo ""
	@echo "Observability namespace:"
	@kubectl get pods -n observability
	@echo ""
	@echo "Unauthenticated sys/metrics status:"
	@kubectl exec -n observability vault-metrics-check -c vault-metrics-check -- sh -c 'curl -s -o /tmp/vault-metrics-unauth.out -w "%{http_code}" "http://vault.default.svc.cluster.local:8200/v1/sys/metrics?format=prometheus"'
	@echo ""
	@echo "Authenticated sys/metrics sample:"
	@kubectl exec -n observability vault-metrics-check -c vault-metrics-check -- sh -c 'curl -sf -H "X-Vault-Token: $$(cat /vault/secrets/token)" "http://vault.default.svc.cluster.local:8200/v1/sys/metrics?format=prometheus" | grep -m 1 "^# HELP vault_"'

status: ## Show Kubernetes resources used by the single-cluster Agent Injector/OTel demo (current kubectl context)
	@kubectl get pods,svc,configmap,serviceaccount -n default
	@echo ""
	@kubectl get pods,deploy,configmap,serviceaccount -n observability

logs-otel: ## Show recent OpenTelemetry collector logs (current kubectl context)
	@kubectl logs -n observability deployment/otel-collector -c otel-collector --tail=80

logs-agent: ## Show recent Vault Agent sidecar logs from the OTel collector pod (current kubectl context)
	@kubectl logs -n observability deployment/otel-collector -c vault-agent --tail=80

## --- Verify/status/logs: two-cluster VSO demo -----------------------------

vso-verify: ## Verify the VSO demo is synced end-to-end in the VSO cluster (VSO_CONTEXT)
	@echo "Vault Secrets Operator deployment (context: $(VSO_CONTEXT)):"
	@kubectl --context $(VSO_CONTEXT) get deploy -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator
	@echo ""
	@echo "VSO demo namespace pods (context: $(VSO_CONTEXT)):"
	@kubectl --context $(VSO_CONTEXT) get pods -n vso-demo
	@echo ""
	@echo "VaultStaticSecret status (context: $(VSO_CONTEXT)):"
	@kubectl --context $(VSO_CONTEXT) get vaultstaticsecret vso-demo-mysecret -n vso-demo
	@echo ""
	@echo "Synced native Secret value (username, context: $(VSO_CONTEXT)):"
	@kubectl --context $(VSO_CONTEXT) get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d; echo
	@echo ""
	@echo "App pod envFrom value captured at pod start (existing env vars do not live-update, context: $(VSO_CONTEXT)):"
	@kubectl --context $(VSO_CONTEXT) exec vso-demo-app -n vso-demo -- printenv username

vso-status: ## Show Kubernetes resources used by the VSO demo across both clusters
	@echo "Vault cluster (context: $(VAULT_CONTEXT)):"
	@kubectl --context $(VAULT_CONTEXT) get pods,svc -n default
	@echo ""
	@echo "VSO cluster (context: $(VSO_CONTEXT)):"
	@kubectl --context $(VSO_CONTEXT) get pods,secret,serviceaccount -n vso-demo
	@echo ""
	@kubectl --context $(VSO_CONTEXT) get vaultconnection,vaultauth,vaultstaticsecret -n vso-demo
	@echo ""
	@kubectl --context $(VSO_CONTEXT) get pods,deploy -n vault-secrets-operator-system

logs-vso: ## Show recent Vault Secrets Operator controller logs (context: VSO_CONTEXT)
	@kubectl --context $(VSO_CONTEXT) logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator --tail=80

## --- Client-JWT-self-review VSO scenario (docs/vso-kubernetes-auth-delegator-plan.md) --
#
# A second, parallel VSO scenario that coexists with (and never modifies)
# the default JWT/OIDC scenario above. VSO's own short-lived, dual-audience
# ServiceAccount JWT is both the login credential presented to Vault AND
# the HTTP bearer Vault uses for its own Kubernetes TokenReview call,
# authorized by a scenario-owned system:auth-delegator ClusterRoleBinding.
# None of these targets create, delete, or recreate a kind cluster, or run
# Helm install/upgrade.

configure-auth-delegator: ## Configure the dedicated auth/kubernetes-vso-self-review Vault Kubernetes auth mount, role, and policy
	@bash scripts/configure-vso-auth-delegator.sh

auth-delegator-apply: ## Apply the cross-namespace VSO resources (namespaces, ServiceAccounts, CRB, VaultConnection/VaultAuth/VaultStaticSecret, app pod)
	@bash scripts/apply-vso-auth-delegator-demo.sh

auth-delegator-setup: configure-auth-delegator auth-delegator-apply ## Configure only the dedicated auth mount and apply only the new scenario resources

auth-delegator-verify: ## Full end-to-end proof: placement, RBAC, direct TokenReview, Vault login negatives, cross-namespace sync, and CAS rotation
	@bash scripts/verify-vso-auth-delegator.sh

auth-delegator-status: ## Show Kubernetes resources used by the client-JWT-self-review scenario across both clusters
	@echo "Vault cluster (context: $(VAULT_CONTEXT)):"
	@kubectl --context $(VAULT_CONTEXT) get pods -n default -l app.kubernetes.io/name=vault
	@echo ""
	@echo "VSO cluster (context: $(VSO_CONTEXT)):"
	@kubectl --context $(VSO_CONTEXT) get namespace vso-auth-config vso-auth-delegator-app 2>/dev/null || true
	@echo ""
	@kubectl --context $(VSO_CONTEXT) get serviceaccount,clusterrolebinding -n vso-auth-delegator-app 2>/dev/null | grep -E 'vso-auth-delegator|NAME' || true
	@echo ""
	@kubectl --context $(VSO_CONTEXT) get vaultconnection,vaultauth -n vso-auth-config 2>/dev/null || true
	@echo ""
	@kubectl --context $(VSO_CONTEXT) get vaultstaticsecret,secret,pod -n vso-auth-delegator-app 2>/dev/null || true

auth-delegator-deck: ## Health-first: verify both scenarios (reconciling this one only if unhealthy), then run the Presenterm auth-delegator deck. SKIP_PREFLIGHT=1 bypasses the health gates
	@command -v presenterm >/dev/null 2>&1 || { echo "presenterm not installed: brew install presenterm"; exit 1; }
ifeq ($(SKIP_PREFLIGHT),)
	@echo "==> [auth-delegator-deck 1/5] Starting Podman and requiring existing kind control planes (no cluster creation)"
	@KIND_EXPERIMENTAL_PROVIDER=podman bash scripts/prepare-vso-deck-env.sh --require-existing
	@echo "==> [auth-delegator-deck 2/5] Verifying the existing default JWT/OIDC scenario is healthy (--skip-rotation)"
	@bash scripts/verify-two-cluster.sh --skip-rotation
	@set -e; \
		echo "==> [auth-delegator-deck 3/5] Health-checking the client-JWT-self-review scenario (--skip-rotation)"; \
		if bash scripts/verify-vso-auth-delegator.sh --skip-rotation; then \
			echo "==> Existing auth-delegator resources are healthy; skipping setup and reusing them unchanged."; \
		else \
			echo "==> Existing auth-delegator resources are incomplete or unhealthy; running setup once."; \
			$(MAKE) --no-print-directory auth-delegator-setup; \
		fi
	@echo "==> [auth-delegator-deck 4/5] Running the full auth-delegator verifier (including reversible CAS rotation)"
	@bash scripts/verify-vso-auth-delegator.sh
	@echo "==> [auth-delegator-deck 5/5] Re-verifying the default JWT/OIDC scenario shows no regression (--skip-rotation)"
	@bash scripts/verify-two-cluster.sh --skip-rotation
	@echo "==> All checkpoints passed; launching Presenterm"
else
	@echo "==> SKIP_PREFLIGHT=1: bypassing all health gates; launching Presenterm directly (environment is assumed healthy)"
endif
	@exec presenterm -x presenterm/auth-delegator.md
