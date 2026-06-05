.PHONY: help setup demo verify status logs-otel logs-agent vso-demo vso-verify vso-status logs-vso
.DEFAULT_GOAL := help

help: ## Show available demo commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup: ## Run the full Vault Kubernetes setup script on the current cluster
	@echo "Running create_vault.sh on current kubectl context..."
	@bash create_vault.sh

demo: ## Run the guided live demo flow
	@bash demo.sh

vso-demo: ## Run the guided Vault Secrets Operator (VSO) demo flow
	@bash vso-demo.sh

verify: ## Verify the demo environment is ready
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

status: ## Show Kubernetes resources used by the demo
	@kubectl get pods,svc,configmap,serviceaccount -n default
	@echo ""
	@kubectl get pods,deploy,configmap,serviceaccount -n observability

logs-otel: ## Show recent OpenTelemetry collector logs
	@kubectl logs -n observability deployment/otel-collector -c otel-collector --tail=80

logs-agent: ## Show recent Vault Agent sidecar logs from the OTel collector pod
	@kubectl logs -n observability deployment/otel-collector -c vault-agent --tail=80

vso-verify: ## Verify the Vault Secrets Operator demo environment is ready
	@echo "Vault Secrets Operator deployment:"
	@kubectl get deploy -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator
	@echo ""
	@echo "VSO demo namespace pods:"
	@kubectl get pods -n vso-demo
	@echo ""
	@echo "VaultStaticSecret status:"
	@kubectl get vaultstaticsecret vso-demo-mysecret -n vso-demo
	@echo ""
	@echo "Synced native Secret value (username):"
	@kubectl get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d; echo
	@echo ""
	@echo "App pod envFrom value captured at pod start (existing env vars do not live-update):"
	@kubectl exec vso-demo-app -n vso-demo -- printenv username

vso-status: ## Show Kubernetes resources used by the VSO demo
	@kubectl get pods,secret,serviceaccount -n vso-demo
	@echo ""
	@kubectl get vaultconnection,vaultauth,vaultstaticsecret -n vso-demo
	@echo ""
	@kubectl get pods,deploy -n vault-secrets-operator-system

logs-vso: ## Show recent Vault Secrets Operator controller logs
	@kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator --tail=80
