#!/usr/bin/env bash
# scripts/lib/two-cluster-env.sh
#
# Shared environment defaults and preflight helpers for the two-cluster
# (Podman-backed kind) Vault + Vault Secrets Operator (VSO) demo.
#
# Every setup, demo, and verification script should `source` this file
# instead of re-declaring context names, namespaces, or addresses. This
# keeps `kind-vault-lab` / `kind-vso-lab` naming, ports, and mount paths
# centralized and overrideable via environment variables.
#
# Usage:
#   #!/usr/bin/env bash
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/two-cluster-env.sh"
#
#   require_commands kubectl kind helm jq
#   require_contexts
#   kubectl_vault get pods -n "$NAMESPACE"
#   kubectl_vso get pods -n "$VSO_NAMESPACE"
#
# This file is meant to be sourced, not executed directly. It intentionally
# avoids `set -euo pipefail` at the top level so sourcing it does not change
# the calling script's shell options; the calling script is expected to set
# its own strict-mode flags (this file's functions are written to behave
# correctly under `set -euo pipefail`).

# --------------------------------------------------------------------------
# Cluster contexts
# --------------------------------------------------------------------------
# These are the two Podman-backed kind clusters used by the demo. Vault runs
# only in VAULT_CONTEXT; VSO, its CRDs, and the demo app run only in
# VSO_CONTEXT. Never rely on `kubectl config current-context` for
# correctness -- always pass one of these explicitly.
VAULT_CONTEXT="${VAULT_CONTEXT:-kind-vault-lab}"
VSO_CONTEXT="${VSO_CONTEXT:-kind-vso-lab}"

# kind cluster names (without the `kind-` context prefix kind adds).
VAULT_KIND_CLUSTER_NAME="${VAULT_KIND_CLUSTER_NAME:-vault-lab}"
VSO_KIND_CLUSTER_NAME="${VSO_KIND_CLUSTER_NAME:-vso-lab}"

# --------------------------------------------------------------------------
# Cross-cluster networking
# --------------------------------------------------------------------------
# Host reachable from both Podman-backed kind clusters via the container
# runtime's host gateway. Vault is exposed on the Vault cluster via a
# NodePort/host port mapping to this host+port; VSO's VaultConnection uses
# this address to reach Vault from the VSO cluster.
TWO_CLUSTER_HOST="${TWO_CLUSTER_HOST:-host.containers.internal}"

VAULT_HOST_PORT="${VAULT_HOST_PORT:-8200}"
VAULT_ADDR="${VAULT_ADDR:-http://${TWO_CLUSTER_HOST}:${VAULT_HOST_PORT}}"

# NodePort Vault's Kubernetes Service listens on inside the Vault cluster.
# The Vault cluster's kind config maps this 1:1 to VAULT_HOST_PORT via
# extraPortMappings (see scripts/kind/vault-lab-config.yaml.tmpl and
# scripts/create-clusters.sh). Task 05 (expose-vault-cross-cluster) creates
# the actual NodePort Service using this port.
VAULT_NODE_PORT="${VAULT_NODE_PORT:-30820}"

# Host port the VSO cluster's API server is mapped to, and the address Vault
# uses to reach it for Kubernetes auth TokenReview requests.
VSO_API_HOST_PORT="${VSO_API_HOST_PORT:-6444}"
VSO_API_ADDR="${VSO_API_ADDR:-https://${TWO_CLUSTER_HOST}:${VSO_API_HOST_PORT}}"

# --------------------------------------------------------------------------
# Namespaces
# --------------------------------------------------------------------------
# Vault cluster namespaces.
NAMESPACE="${NAMESPACE:-default}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"

# VSO cluster namespaces.
VSO_NAMESPACE="${VSO_NAMESPACE:-vso-demo}"
VSO_OPERATOR_NAMESPACE="${VSO_OPERATOR_NAMESPACE:-vault-secrets-operator-system}"

# --------------------------------------------------------------------------
# Chart versions
# --------------------------------------------------------------------------
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-}"
VSO_CHART_VERSION="${VSO_CHART_VERSION:-1.4.0}"

# --------------------------------------------------------------------------
# Resource names
# --------------------------------------------------------------------------
VAULT_POD_LABEL_SELECTOR="${VAULT_POD_LABEL_SELECTOR:-app.kubernetes.io/name=vault}"

# Kubernetes auth mount used by VSO (cross-cluster), distinct from the
# pre-existing same-cluster `auth/kubernetes` mount used by the Agent
# Injector / OTel demo paths, which must not be touched.
#
# DEPRECATION NOTE: these Kubernetes-auth variables are kept temporarily
# for migration compatibility while the demo moves to JWT/OIDC auth (see
# VSO_JWT_* / VSO_OIDC_* below, docs/vso-jwt-oidc-auth-plan.md, and
# tasks/vso-jwt-oidc-auth/*.md). Do not remove until every script/task in
# that plan has migrated off `auth/${VSO_AUTH_MOUNT}`.
VSO_AUTH_MOUNT="${VSO_AUTH_MOUNT:-kubernetes-vso}"
VSO_AUTH_ROLE="${VSO_AUTH_ROLE:-vso-demo}"

# --------------------------------------------------------------------------
# JWT/OIDC auth (VSO -> Vault), replacing the Kubernetes auth mount above
# --------------------------------------------------------------------------
# Vault JWT auth mount dedicated to the VSO cluster's service account JWTs,
# validated via the VSO cluster's OIDC issuer/JWKS rather than a
# TokenReview call back to the VSO cluster's API server. Named distinctly
# from `${VSO_AUTH_MOUNT}` (`kubernetes-vso`) so both can exist side by
# side during migration; see docs/vso-jwt-oidc-auth-spike-01.md for the
# jwks_url vs oidc_discovery_url decision this mount's config relies on.
VSO_JWT_AUTH_MOUNT="${VSO_JWT_AUTH_MOUNT:-jwt-vso}"
VSO_JWT_AUTH_ROLE="${VSO_JWT_AUTH_ROLE:-vso-demo}"

# Audience Vault expects (`bound_audiences`) and VSO's ServiceAccount
# projected token requests (`aud`) must both use `vault` by default so a
# JWT minted for another audience is rejected outright.
VSO_JWT_AUDIENCE="${VSO_JWT_AUDIENCE:-vault}"

# `bound_issuer` string Vault compares against the JWT's `iss` claim. This
# is a plain string compare -- it does not need to be reachable from the
# Vault cluster. Default kind clusters self-report the Kubernetes-internal
# issuer below (see spike 01); override if the VSO cluster's kind config
# sets `service-account-issuer` to something else.
VSO_OIDC_ISSUER="${VSO_OIDC_ISSUER:-https://kubernetes.default.svc.cluster.local}"

# JWKS endpoint Vault fetches signing keys from to validate VSO cluster
# service account JWTs, reached over the same cross-cluster host+port as
# ${VSO_API_ADDR} (see spike 01: the VSO cluster's self-reported
# `jwks_uri` is a Podman-bridge IP that is not reliably reachable, so this
# uses the same externally-reachable address as VSO_API_ADDR instead).
VSO_OIDC_JWKS_URL="${VSO_OIDC_JWKS_URL:-${VSO_API_ADDR}/openid/v1/jwks}"

SECRET_NAME="${SECRET_NAME:-vso-demo-mysecret}"
APP_POD="${APP_POD:-vso-demo-app}"
VAULT_TOKEN_REVIEWER_SA="${VAULT_TOKEN_REVIEWER_SA:-vault-token-reviewer}"

# --------------------------------------------------------------------------
# Command preflight
# --------------------------------------------------------------------------

# require_commands <cmd> [<cmd> ...]
#
# Verifies each given command is available on PATH. Prints an actionable
# error naming the missing command(s) and returns non-zero if any are
# missing (does not exit the shell, so callers under `set -e` will stop, and
# callers that want to handle the failure themselves still can by capturing
# the return code).
require_commands() {
  local missing=()
  local cmd

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: required command(s) not found on PATH: ${missing[*]}" >&2
    echo "       install the missing command(s) and re-run." >&2
    return 1
  fi

  return 0
}

# --------------------------------------------------------------------------
# Context preflight
# --------------------------------------------------------------------------

# context_exists <context-name>
#
# Returns 0 if the given kubectl context exists in the current kubeconfig,
# non-zero otherwise. Does not depend on which context is "current".
context_exists() {
  local ctx="$1"
  kubectl config get-contexts -o name 2>/dev/null | grep -Fxq "$ctx"
}

# require_context <context-name>
#
# Asserts a single named context exists, printing an actionable error that
# names the missing context and the command that would create it.
require_context() {
  local ctx="$1"

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found on PATH; cannot check context '$ctx'." >&2
    return 1
  fi

  if ! context_exists "$ctx"; then
    echo "ERROR: kubectl context '$ctx' not found." >&2
    echo "       Expected clusters: VAULT_CONTEXT=$VAULT_CONTEXT, VSO_CONTEXT=$VSO_CONTEXT" >&2
    echo "       Run 'make clusters' (or the two-cluster bootstrap script) to create it," >&2
    echo "       or check 'kubectl config get-contexts' for the correct name." >&2
    return 1
  fi

  return 0
}

# require_contexts
#
# Asserts both VAULT_CONTEXT and VSO_CONTEXT exist and are different from
# each other. This is the primary preflight gate every setup/demo/verify
# script should call before doing any real work.
require_contexts() {
  local ok=0

  require_context "$VAULT_CONTEXT" || ok=1
  require_context "$VSO_CONTEXT" || ok=1

  if [ "$VAULT_CONTEXT" = "$VSO_CONTEXT" ]; then
    echo "ERROR: VAULT_CONTEXT and VSO_CONTEXT must not be the same context (both are '$VAULT_CONTEXT')." >&2
    echo "       Vault must run in a different cluster from VSO/VSO CRDs/the demo app." >&2
    ok=1
  fi

  return "$ok"
}

# --------------------------------------------------------------------------
# Context-specific kubectl/helm wrappers
# --------------------------------------------------------------------------

# kubectl_vault <args...>
#
# Runs kubectl against VAULT_CONTEXT explicitly. Never relies on the
# ambient current-context.
kubectl_vault() {
  kubectl --context "$VAULT_CONTEXT" "$@"
}

# kubectl_vso <args...>
#
# Runs kubectl against VSO_CONTEXT explicitly.
kubectl_vso() {
  kubectl --context "$VSO_CONTEXT" "$@"
}

# helm_vault <args...>
#
# Runs helm against VAULT_CONTEXT explicitly (via --kube-context).
helm_vault() {
  helm --kube-context "$VAULT_CONTEXT" "$@"
}

# helm_vso <args...>
#
# Runs helm against VSO_CONTEXT explicitly (via --kube-context).
helm_vso() {
  helm --kube-context "$VSO_CONTEXT" "$@"
}

# --------------------------------------------------------------------------
# Podman / kind network preflight
# --------------------------------------------------------------------------

# preflight_two_cluster_network
#
# Best-effort checks for the assumptions later setup/demo scripts rely on:
#   - kind is configured to use the Podman provider.
#   - both expected kind clusters exist.
#   - TWO_CLUSTER_HOST resolves/is reachable, where checkable from this host.
#
# This function prints actionable diagnostics but is deliberately
# non-fatal for checks it cannot fully verify from outside the cluster
# (e.g. reachability from *inside* a kind pod requires a running pod and is
# left to the dedicated `make verify-two-cluster` target). It returns
# non-zero only for checks it can verify with confidence.
preflight_two_cluster_network() {
  local ok=0

  if [ "${KIND_EXPERIMENTAL_PROVIDER:-}" != "podman" ]; then
    echo "WARNING: KIND_EXPERIMENTAL_PROVIDER is not set to 'podman' (current: '${KIND_EXPERIMENTAL_PROVIDER:-<unset>}')." >&2
    echo "         Podman-backed kind clusters require: export KIND_EXPERIMENTAL_PROVIDER=podman" >&2
  fi

  if command -v kind >/dev/null 2>&1; then
    local existing_clusters
    existing_clusters="$(kind get clusters 2>/dev/null || true)"

    if ! printf '%s\n' "$existing_clusters" | grep -Fxq "$VAULT_KIND_CLUSTER_NAME"; then
      echo "NOTE: kind cluster '$VAULT_KIND_CLUSTER_NAME' (context '$VAULT_CONTEXT') not found yet." >&2
      ok=1
    fi

    if ! printf '%s\n' "$existing_clusters" | grep -Fxq "$VSO_KIND_CLUSTER_NAME"; then
      echo "NOTE: kind cluster '$VSO_KIND_CLUSTER_NAME' (context '$VSO_CONTEXT') not found yet." >&2
      ok=1
    fi
  else
    echo "WARNING: kind not found on PATH; cannot check for existing clusters." >&2
  fi

  if command -v getent >/dev/null 2>&1; then
    if ! getent hosts "$TWO_CLUSTER_HOST" >/dev/null 2>&1; then
      echo "NOTE: '$TWO_CLUSTER_HOST' does not resolve from this host. This is often fine" >&2
      echo "      (it only needs to resolve from inside the kind/Podman network namespaces)," >&2
      echo "      but if VSO cannot reach Vault, verify Podman's host gateway is enabled." >&2
    fi
  fi

  return "$ok"
}

# print_two_cluster_env
#
# Prints the core shared variables. Useful for smoke-testing that this file
# was sourced correctly (see validation steps in the task spec).
print_two_cluster_env() {
  cat <<EOF
VAULT_CONTEXT=$VAULT_CONTEXT
VSO_CONTEXT=$VSO_CONTEXT
VAULT_KIND_CLUSTER_NAME=$VAULT_KIND_CLUSTER_NAME
VSO_KIND_CLUSTER_NAME=$VSO_KIND_CLUSTER_NAME
VAULT_ADDR=$VAULT_ADDR
VAULT_NODE_PORT=$VAULT_NODE_PORT
VSO_API_ADDR=$VSO_API_ADDR
NAMESPACE=$NAMESPACE
OBSERVABILITY_NAMESPACE=$OBSERVABILITY_NAMESPACE
VSO_NAMESPACE=$VSO_NAMESPACE
VSO_OPERATOR_NAMESPACE=$VSO_OPERATOR_NAMESPACE
VSO_CHART_VERSION=$VSO_CHART_VERSION
VSO_AUTH_MOUNT=$VSO_AUTH_MOUNT
VSO_AUTH_ROLE=$VSO_AUTH_ROLE
VSO_JWT_AUTH_MOUNT=$VSO_JWT_AUTH_MOUNT
VSO_JWT_AUTH_ROLE=$VSO_JWT_AUTH_ROLE
VSO_JWT_AUDIENCE=$VSO_JWT_AUDIENCE
VSO_OIDC_ISSUER=$VSO_OIDC_ISSUER
VSO_OIDC_JWKS_URL=$VSO_OIDC_JWKS_URL
SECRET_NAME=$SECRET_NAME
APP_POD=$APP_POD
EOF
}
