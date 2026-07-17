#!/usr/bin/env bash
# scripts/setup-vso-cluster.sh
#
# Context-aware VSO cluster setup: installs the Vault Secrets Operator (VSO)
# and creates the vso-demo namespace/service accounts *only* in the VSO
# cluster (VSO_CONTEXT / kind-vso-lab by default).
#
# This script does NOT touch the Vault cluster, does NOT configure Vault
# JWT/OIDC or Kubernetes auth, and does NOT apply VSO CRDs (VaultConnection/
# VaultAuth/VaultStaticSecret) - those are handled by later scripts once
# cross-cluster auth is wired up. This is cluster-scaffolding only:
#   - installs the vault-secrets-operator Helm chart in $VSO_OPERATOR_NAMESPACE
#   - creates the $VSO_NAMESPACE namespace
#   - creates the 'vso-demo' service account (what VSO's VaultAuth will use)
#   - grants unauthenticated read access to this cluster's OIDC discovery/
#     JWKS endpoints (see "OIDC discovery reader RBAC" below), which Vault's
#     JWT/OIDC auth method (auth/${VSO_JWT_AUTH_MOUNT}, configured by
#     scripts/configure-vso-jwt-auth.sh) needs to validate 'vso-demo'
#     service account JWTs directly, with no call back into this cluster.
#
# Default auth model: JWT/OIDC (no TokenReview reviewer identity)
# ----------------------------------------------------------------
# The demo's default cross-cluster auth path is Vault JWT/OIDC auth
# (auth/${VSO_JWT_AUTH_MOUNT}, see scripts/configure-vso-jwt-auth.sh and
# docs/vso-jwt-oidc-auth-plan.md). Vault validates 'vso-demo' service
# account JWTs by retrieving this cluster's OIDC discovery metadata and then
# its advertised JWKS signing keys. It never calls this cluster's TokenReview
# API, and no reviewer JWT is ever stored in Vault. Because of that, this script does NOT
# create a 'vault-token-reviewer' service account or bind
# 'system:auth-delegator' by default.
#
# Legacy TokenReview compatibility path (off by default)
# -------------------------------------------------------
# The older Vault Kubernetes auth path (auth/${VSO_AUTH_MOUNT}, configured
# by scripts/configure-vso-kubernetes-auth.sh) is kept only as an explicit,
# opt-in comparison/migration path -- it is legacy/demo-comparison only,
# not the recommended setup. It requires a reviewer service account with
# TokenReview RBAC. Set ENABLE_TOKEN_REVIEWER_AUTH=1 to also create that
# reviewer identity here:
#   - creates the '$VAULT_TOKEN_REVIEWER_SA' service account + TokenReview
#     RBAC (system:auth-delegator) so Vault's legacy Kubernetes auth config
#     can use it as the reviewer identity when validating tokens against
#     this cluster's API server.
#
# Every kubectl/helm operation here targets $VSO_CONTEXT explicitly; it never
# relies on (or changes) the caller's current kubectl context.
#
# Usage:
#   VSO_CONTEXT=kind-vso-lab scripts/setup-vso-cluster.sh
#   scripts/setup-vso-cluster.sh --check-only   # validate tools/context only
#   ENABLE_TOKEN_REVIEWER_AUTH=1 scripts/setup-vso-cluster.sh   # legacy TokenReview compat path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/two-cluster-env.sh
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

# Explicit, off-by-default compatibility flag for the legacy TokenReview
# reviewer identity (vault-token-reviewer SA + system:auth-delegator
# binding). Only needed if you intend to run the legacy
# scripts/configure-vso-kubernetes-auth.sh path for comparison against the
# default JWT/OIDC path; see docs/vso-jwt-oidc-auth-plan.md Phase 5.
ENABLE_TOKEN_REVIEWER_AUTH="${ENABLE_TOKEN_REVIEWER_AUTH:-0}"

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-only)
      CHECK_ONLY=1
      ;;
    -h|--help)
      sed -n '2,51p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg' (supported: --check-only)" >&2
      exit 1
      ;;
  esac
done

# --- Validation ----------------------------------------------------------

fail=0
require_commands kubectl helm || fail=1
require_context "$VSO_CONTEXT" || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK: required commands present and context '$VSO_CONTEXT' exists."
  exit 0
fi

echo "==> Setting up the Vault Secrets Operator cluster (context: ${VSO_CONTEXT})"

# --- Install the Vault Secrets Operator (idempotent; pinned chart version) --

helm_vso repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm_vso repo update hashicorp >/dev/null 2>&1 || true

echo "==> Installing/upgrading Vault Secrets Operator (chart version ${VSO_CHART_VERSION})..."
helm_vso upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace "$VSO_OPERATOR_NAMESPACE" \
  --create-namespace \
  --version "$VSO_CHART_VERSION"

echo "==> Waiting for the Vault Secrets Operator deployment to become Available..."
kubectl_vso wait -n "$VSO_OPERATOR_NAMESPACE" \
  --for=condition=Available deployment \
  -l app.kubernetes.io/name=vault-secrets-operator --timeout=180s

# --- vso-demo namespace + service account ---------------------------------

echo "==> Creating namespace '${VSO_NAMESPACE}' and service account..."
kubectl_vso apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${VSO_NAMESPACE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vso-demo
  namespace: ${VSO_NAMESPACE}
EOF

# --- OIDC discovery reader RBAC (default JWT/OIDC auth path) --------------
#
# Vault's JWT/OIDC auth method (auth/${VSO_JWT_AUTH_MOUNT}, configured in
# scripts/configure-vso-jwt-auth.sh) first fetches this cluster's discovery
# document and then follows its advertised `jwks_uri` to validate 'vso-demo'
# ServiceAccount JWTs. Both are unauthenticated GETs -- Vault's JWT auth does
# not send a bearer token when retrieving discovery or JWKS documents.
#
# Default kind/kubeadm RBAC does not grant unauthenticated callers access
# to '/.well-known/openid-configuration' or '/openid/v1/jwks' (only a
# small set of health/version paths are covered by
# system:public-info-viewer). This ClusterRole/ClusterRoleBinding closes
# that gap by granting 'system:unauthenticated' read access to exactly
# those two non-resource URLs -- nothing else.
echo "==> Granting OIDC discovery/JWKS read access to unauthenticated callers..."
kubectl_vso apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: oidc-discovery-reader
rules:
- nonResourceURLs:
  - /.well-known/openid-configuration
  - /openid/v1/jwks
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-discovery-reader-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: oidc-discovery-reader
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:unauthenticated
EOF

# --- Legacy TokenReview reviewer identity (opt-in, off by default) --------
#
# Only created when ENABLE_TOKEN_REVIEWER_AUTH=1. This is legacy/demo
# comparison support for the older Vault Kubernetes auth path
# (auth/${VSO_AUTH_MOUNT}, scripts/configure-vso-kubernetes-auth.sh) which
# authenticates incoming JWTs by calling the TokenReview API. The default
# JWT/OIDC auth path (auth/${VSO_JWT_AUTH_MOUNT}) does not use or require
# this service account.
if [ "$ENABLE_TOKEN_REVIEWER_AUTH" = "1" ]; then
  echo "==> ENABLE_TOKEN_REVIEWER_AUTH=1: creating legacy TokenReview reviewer identity '${VAULT_TOKEN_REVIEWER_SA}'..."
  kubectl_vso apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${VAULT_TOKEN_REVIEWER_SA}
  namespace: ${VSO_NAMESPACE}
EOF

  echo "==> Binding TokenReview RBAC to '${VAULT_TOKEN_REVIEWER_SA}'..."
  kubectl_vso apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${VAULT_TOKEN_REVIEWER_SA}-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: ${VAULT_TOKEN_REVIEWER_SA}
  namespace: ${VSO_NAMESPACE}
EOF
else
  echo "==> Skipping legacy TokenReview reviewer identity (default JWT/OIDC auth path does not need it)."
  echo "    Set ENABLE_TOKEN_REVIEWER_AUTH=1 to create '${VAULT_TOKEN_REVIEWER_SA}' + system:auth-delegator for comparison."
fi

echo ""
echo "VSO cluster setup complete (context: ${VSO_CONTEXT})."
echo "  - Operator namespace: ${VSO_OPERATOR_NAMESPACE}"
echo "  - Demo namespace:     ${VSO_NAMESPACE} (service account: vso-demo)"
echo "  - Default auth path:  JWT/OIDC (auth/${VSO_JWT_AUTH_MOUNT}) - no TokenReview reviewer identity required"
if [ "$ENABLE_TOKEN_REVIEWER_AUTH" = "1" ]; then
  echo "  - Legacy compat:      TokenReview reviewer identity '${VAULT_TOKEN_REVIEWER_SA}' created (ENABLE_TOKEN_REVIEWER_AUTH=1)"
fi
echo ""
echo "Not done here (see other scripts): Vault JWT/OIDC auth configuration"
echo "(auth/${VSO_JWT_AUTH_MOUNT}, scripts/configure-vso-jwt-auth.sh) and VSO CRDs"
echo "(VaultConnection/VaultAuth/VaultStaticSecret, scripts/apply-vso-demo.sh)."
