.PHONY: help setup clusters setup-vault setup-vso configure-vso-auth vso-apply \
        demo verify status logs-otel logs-agent \
        vso-demo vso-deck vso-verify vso-status logs-vso \
        check-vault-connectivity verify-two-cluster
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
VAULT_ADDR ?= http://host.containers.internal:8200
VSO_API_ADDR ?= https://host.containers.internal:6444

export VAULT_CONTEXT
export VSO_CONTEXT
export VAULT_ADDR
export VSO_API_ADDR

help: ## Show available demo commands
	@echo "Two-cluster Podman-backed kind demo (VAULT_CONTEXT=$(VAULT_CONTEXT), VSO_CONTEXT=$(VSO_CONTEXT))"
	@echo "Requires: export KIND_EXPERIMENTAL_PROVIDER=podman"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

## --- Two-cluster setup (Podman-backed kind) ------------------------------

setup: ## Run the full two-cluster setup: clusters, Vault, VSO, cross-cluster auth, VSO demo apply
	@bash scripts/create-clusters.sh
	@bash scripts/setup-vault-cluster.sh
	@bash scripts/setup-vso-cluster.sh
	@bash scripts/configure-vso-kubernetes-auth.sh
	@bash scripts/apply-vso-demo.sh

clusters: ## Create/validate the kind-vault-lab and kind-vso-lab Podman-backed kind clusters
	@bash scripts/create-clusters.sh

setup-vault: ## Install and configure Vault in the Vault cluster (VAULT_CONTEXT) only
	@bash scripts/setup-vault-cluster.sh

setup-vso: ## Install VSO and create vso-demo namespace/service accounts in the VSO cluster (VSO_CONTEXT) only
	@bash scripts/setup-vso-cluster.sh

configure-vso-auth: ## Configure Vault's dedicated auth/kubernetes-vso mount against the VSO cluster API server
	@bash scripts/configure-vso-kubernetes-auth.sh

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

vso-deck: ## Run the VSO demo as a presenterm slide deck (requires presenterm; -x enables live code blocks)
	@command -v presenterm >/dev/null 2>&1 || { echo "presenterm not installed: brew install presenterm"; exit 1; }
	@presenterm -x presenterm/vso.md

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
