#!/usr/bin/env bash
# scripts/setup-vso-cluster.sh
#
# Context-aware VSO cluster setup: installs the Vault Secrets Operator (VSO)
# and creates the vso-demo namespace/service accounts *only* in the VSO
# cluster (VSO_CONTEXT / kind-vso-lab by default).
#
# This script does NOT touch the Vault cluster, does NOT configure Vault
# Kubernetes auth, and does NOT apply VSO CRDs (VaultConnection/VaultAuth/
# VaultStaticSecret) - those are handled by later tasks once cross-cluster
# auth is wired up. This is cluster-scaffolding only:
#   - installs the vault-secrets-operator Helm chart in $VSO_OPERATOR_NAMESPACE
#   - creates the $VSO_NAMESPACE namespace
#   - creates the 'vso-demo' service account (what VSO's VaultAuth will use)
#   - creates the '$VAULT_TOKEN_REVIEWER_SA' service account + TokenReview
#     RBAC (system:auth-delegator) so Vault's Kubernetes auth config can use
#     it as the reviewer identity when validating tokens against this
#     cluster's API server.
#
# Every kubectl/helm operation here targets $VSO_CONTEXT explicitly; it never
# relies on (or changes) the caller's current kubectl context.
#
# Usage:
#   VSO_CONTEXT=kind-vso-lab scripts/setup-vso-cluster.sh
#   scripts/setup-vso-cluster.sh --check-only   # validate tools/context only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/two-cluster-env.sh
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-only)
      CHECK_ONLY=1
      ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}"
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

# --- vso-demo namespace + service accounts --------------------------------

echo "==> Creating namespace '${VSO_NAMESPACE}' and service accounts..."
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
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${VAULT_TOKEN_REVIEWER_SA}
  namespace: ${VSO_NAMESPACE}
EOF

# --- TokenReview RBAC for the reviewer identity ---------------------------
#
# Vault's Kubernetes auth method (mounted against this cluster's API server
# as auth/kubernetes-vso - configured in a later task) authenticates
# incoming JWTs by calling the TokenReview API as this service account.
# system:auth-delegator grants both TokenReview and SubjectAccessReview,
# which is the standard binding used for Kubernetes auth "reviewer" SAs.
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

echo ""
echo "VSO cluster setup complete (context: ${VSO_CONTEXT})."
echo "  - Operator namespace: ${VSO_OPERATOR_NAMESPACE}"
echo "  - Demo namespace:     ${VSO_NAMESPACE} (service accounts: vso-demo, ${VAULT_TOKEN_REVIEWER_SA})"
echo ""
echo "Not done here (see later tasks): Vault Kubernetes auth configuration"
echo "(auth/kubernetes-vso) and VSO CRDs (VaultConnection/VaultAuth/VaultStaticSecret)."
