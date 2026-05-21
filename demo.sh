#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"
VAULT_SERVICE_HOST="${VAULT_SERVICE_HOST:-vault.${NAMESPACE}.svc.cluster.local}"
VAULT_METRICS_URL="http://${VAULT_SERVICE_HOST}:8200/v1/sys/metrics?format=prometheus"
NO_WAIT="${NO_WAIT:-false}"

if [ -t 1 ]; then
  BLUE="$(printf '\033[34m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  CYAN="$(printf '\033[36m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
else
  BLUE=""
  GREEN=""
  YELLOW=""
  CYAN=""
  BOLD=""
  RESET=""
fi

pause() {
  if [ "$NO_WAIT" = "true" ]; then
    return
  fi

  printf "\n%sPress ENTER to continue...%s" "$YELLOW" "$RESET"
  read -r _
}

section() {
  local title="$1"

  if [ "$NO_WAIT" != "true" ]; then
    clear
  fi

  printf "%s\n" "$BLUE"
  printf "======================================================================\n"
  printf "%s\n" "$title"
  printf "======================================================================\n"
  printf "%s\n\n" "$RESET"
}

p() {
  printf "%s# %s%s\n" "$CYAN" "$1" "$RESET"
}

pe() {
  local cmd="$1"

  printf "%s$ %s%s\n" "$BOLD" "$cmd" "$RESET"
  bash -o pipefail -c "$cmd"
  printf "\n"
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf "Missing required command: %s\n" "$command_name" >&2
    exit 1
  fi
}

verify_ready() {
  require_command kubectl

  kubectl get pod vault-0 -n "$NAMESPACE" >/dev/null
  kubectl get pod vault-metrics-check -n "$OBSERVABILITY_NAMESPACE" >/dev/null
  kubectl wait -n "$NAMESPACE" --for=condition=Ready pod/vault-0 --timeout=10s >/dev/null
  kubectl wait -n "$OBSERVABILITY_NAMESPACE" --for=condition=Ready pod/vault-metrics-check --timeout=10s >/dev/null
  kubectl wait -n "$OBSERVABILITY_NAMESPACE" --for=condition=Ready pod -l app=otel-collector --timeout=10s >/dev/null
}

verify_ready

section "Vault Kubernetes Auth and OTel Metrics Demo"
cat <<'INTRO'
This guided flow demonstrates a secure way for OpenTelemetry to scrape Vault
metrics from Kubernetes.

The customer problem:
  - Vault UI and API access share port 8200.
  - Enabling unauthenticated metrics would expose metrics to anyone with access
    to that port.
  - We want OTel to scrape metrics, but only after Kubernetes auth and Vault
    policy checks.

What we will prove:
  1. The observability workload is running with a Vault Agent sidecar.
  2. Unauthenticated sys/metrics access is blocked.
  3. Vault Agent injects a token file into the pod.
  4. Authenticated sys/metrics access succeeds with that token.
  5. The token is scoped to a metrics-only policy.
INTRO
pause

section "1. Architecture: how the pieces fit"
cat <<'ARCH'
observability/otel-collector ServiceAccount
        |
        | (1) SA JWT
        v
Vault Agent sidecar ──(2) login with JWT──► Vault Kubernetes auth
        |                                          |
        |                                          | (3) verify JWT
        | (4) writes Vault token to                v
        |     /vault/secrets/token          Kubernetes TokenReview API
        v
OpenTelemetry collector ──(5) bearer token──► Vault /v1/sys/metrics

The OTel collector never needs a hard-coded Vault token. Vault Agent obtains
one at runtime by authenticating the pod's Kubernetes identity.
ARCH
pause

section "2. Confirm the demo workloads"
p "Vault is running in the default namespace"
pe "kubectl get pods -n ${NAMESPACE}"

p "The OTel collector and metrics check pod are in the observability namespace"
pe "kubectl get pods -n ${OBSERVABILITY_NAMESPACE}"

cat <<'POINTS'
Key points:
  - 2/2 means the main container and Vault Agent sidecar are both running.
  - vault-metrics-check is a simple pod that uses the same auth pattern as OTel.
POINTS
pause

section "3. Show the OTel scrape configuration"
p "The Prometheus receiver uses bearer_token_file instead of a static token"
pe "kubectl get configmap otel-collector-config -n ${OBSERVABILITY_NAMESPACE} -o jsonpath='{.data.config\\.yaml}' | sed -n '/receivers:/,/processors:/p'"

cat <<'POINTS'
Key points:
  - metrics_path points to /v1/sys/metrics.
  - bearer_token_file points to /vault/secrets/token.
  - The target is the in-cluster Vault service.
POINTS
pause

section "4. Prove unauthenticated metrics are blocked"
p "Call sys/metrics with no Vault token"
pe "kubectl exec -n ${OBSERVABILITY_NAMESPACE} vault-metrics-check -c vault-metrics-check -- sh -c 'curl -s -o /tmp/vault-metrics-unauth.out -w \"%{http_code}\" \"${VAULT_METRICS_URL}\"'"

cat <<'POINTS'
Expected result:
  - HTTP 403.

This is the security control ASX cares about: metrics are not exposed just
because a user can reach Vault port 8200.
POINTS
pause

section "5. Show Vault Agent's injected token file"
p "Show that Vault Agent wrote a token file for the workload"
pe "kubectl exec -n ${OBSERVABILITY_NAMESPACE} vault-metrics-check -c vault-metrics-check -- ls -l /vault/secrets/token"

p "Show the pod annotations that request token injection"
pe "kubectl get pod -n ${OBSERVABILITY_NAMESPACE} vault-metrics-check -o yaml | grep '^    vault.hashicorp.com'"

cat <<'POINTS'
Key points:
  - We show the token file exists, but we do not print the token.
  - Vault Agent created it after Kubernetes auth succeeded.
POINTS
pause

section "6. Prove authenticated metrics work"
p "Use the injected token file as the Vault token header"
pe "kubectl exec -n ${OBSERVABILITY_NAMESPACE} vault-metrics-check -c vault-metrics-check -- sh -c 'curl -sf -H \"X-Vault-Token: \$(cat /vault/secrets/token)\" \"${VAULT_METRICS_URL}\" | grep -E \"^vault_(core_unsealed|core_active|runtime_alloc_bytes|runtime_num_goroutines|token_create_count) \" | head -10'"

cat <<'POINTS'
Expected result, real Vault metric samples with values, for example:
  - vault_core_unsealed 1          (Vault is unsealed and serving)
  - vault_core_active 1            (this node is the active leader)
  - vault_runtime_alloc_bytes ...  (Go heap memory in use)
  - vault_runtime_num_goroutines ...
  - vault_token_create_count ...   (tokens issued so far)

This is the same endpoint as the previous section. The difference is that this
request is authenticated with a Vault token issued to the OTel Kubernetes
identity.
POINTS
pause

section "7. Show least-privilege Vault access"
p "The metrics policy can only read sys/metrics"
pe "kubectl exec vault-0 -n ${NAMESPACE} -- vault policy read vault-metrics-read"

p "The Kubernetes auth role is bound only to observability/otel-collector"
pe "kubectl exec vault-0 -n ${NAMESPACE} -- vault read auth/kubernetes/role/otel-vault-metrics | grep -E 'bound_service_account_names|bound_service_account_namespaces|token_policies|policies'"

cat <<'POINTS'
Key points:
  - The policy grants read on sys/metrics only.
  - The role only maps the observability/otel-collector service account to that
    policy.
  - Other workloads do not get this metrics token by default.
POINTS
pause

section "8. Baseline secret sidecar demo"
p "The original sidecar demo still works and is separate from the OTel path"
pe "kubectl exec vault-demo -n ${NAMESPACE} -c vault-demo -- cat /vault/secrets/mysecret"

cat <<'POINTS'
Key points:
  - This is the original KV sidecar pattern.
  - The OTel metrics path is additive: a separate role, policy, namespace, and
    service account.
POINTS
pause

section "Demo complete"
printf "%s" "$GREEN"
cat <<'SUMMARY'
What we proved:
  - Unauthenticated metrics access stays blocked.
  - Kubernetes auth validates the OTel collector's service account identity.
  - Vault Agent writes a short-lived token file into the pod.
  - OTel can use bearer_token_file to scrape sys/metrics.
  - Vault policy keeps access narrow: read-only sys/metrics.

Useful follow-up commands:
  make verify
  kubectl logs -n observability deployment/otel-collector -c otel-collector --tail=50
  kubectl exec vault-0 -- vault read auth/kubernetes/role/otel-vault-metrics
SUMMARY
printf "%s" "$RESET"
