#!/usr/bin/env bash
# scripts/configure-vso-kubernetes-auth.sh
#
# Configures a dedicated Vault Kubernetes auth mount (auth/kubernetes-vso)
# in the Vault cluster (VAULT_CONTEXT, default kind-vault-lab) that
# validates service account JWTs against the *VSO* cluster's API server
# (VSO_CONTEXT, default kind-vso-lab).
#
# This is the cross-cluster trust glue between the two clusters created by
# scripts/create-clusters.sh and set up by scripts/setup-vault-cluster.sh /
# scripts/setup-vso-cluster.sh:
#   - Vault cluster: `vault-0` runs the Vault server (setup-vault-cluster.sh)
#   - VSO cluster:   VSO + a `vault-token-reviewer` service account with
#                     TokenReview RBAC (setup-vso-cluster.sh)
#
# What this script does, all idempotently:
#   - Reads the VSO cluster's API server address (VSO_API_ADDR, e.g.
#     https://host.containers.internal:6444 -- reachable from *inside* the
#     Vault cluster via the Podman host gateway) and CA certificate (pulled
#     live from the VSO cluster's kubeconfig entry).
#   - Mints (or refreshes) a reviewer JWT for the VSO cluster's
#     `vault-token-reviewer` service account via `kubectl create token`.
#   - Enables `auth/kubernetes-vso` in the Vault cluster (path/mount name
#     from VSO_AUTH_MOUNT) if not already enabled -- leaves the pre-existing
#     same-cluster `auth/kubernetes` mount (Agent Injector/OTel demo paths)
#     completely untouched.
#   - Writes/updates `auth/kubernetes-vso/config` with the VSO API address,
#     CA, and reviewer JWT.
#   - Writes/updates `auth/kubernetes-vso/role/vso-demo`, bound only to the
#     `vso-demo` service account in the `vso-demo` namespace of the VSO
#     cluster, granting the `mysecret` policy.
#
# Demo-only reviewer token limitation:
#   `kubectl create token` issues a *time-bounded* JWT (see
#   VSO_REVIEWER_TOKEN_TTL below, default 1 year). It is not auto-refreshed
#   by Kubernetes. Vault's Kubernetes auth method also does not re-fetch it
#   on its own. For this demo that is an accepted limitation: re-running
#   this script mints a fresh reviewer JWT and rewrites
#   `auth/kubernetes-vso/config`, so periodically re-running it (well before
#   the TTL expires) keeps TokenReview working. This script is safe to
#   re-run at any time -- it does not disturb any other Vault configuration.
#
# Usage:
#   scripts/configure-vso-kubernetes-auth.sh
#   scripts/configure-vso-kubernetes-auth.sh --check-only   # validate tools/context only
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VAULT_CONTEXT,
# VSO_CONTEXT, VSO_API_ADDR, VSO_AUTH_MOUNT, VSO_AUTH_ROLE, VSO_NAMESPACE,
# VAULT_TOKEN_REVIEWER_SA), plus VSO_REVIEWER_TOKEN_TTL (default: 8760h).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/two-cluster-env.sh
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

# Reviewer JWT lifetime. Demo-only: not auto-refreshed; re-run this script
# to mint a new one before it expires.
VSO_REVIEWER_TOKEN_TTL="${VSO_REVIEWER_TOKEN_TTL:-8760h}"

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-only)
      CHECK_ONLY=1
      ;;
    -h|--help)
      sed -n '2,45p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg' (supported: --check-only)" >&2
      exit 1
      ;;
  esac
done

# --- Validation ------------------------------------------------------------

fail=0
require_commands kubectl jq base64 || fail=1
require_contexts || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK: required commands present and VAULT_CONTEXT/VSO_CONTEXT both exist and differ."
  exit 0
fi

echo "==> Configuring Vault Kubernetes auth against the VSO cluster"
echo "    Vault cluster (auth host): ${VAULT_CONTEXT}"
echo "    VSO cluster (validated):   ${VSO_CONTEXT}"
echo "    Auth mount:                auth/${VSO_AUTH_MOUNT}"
echo ""

# --- Locate the Vault pod ---------------------------------------------------

VAULT_POD=$(kubectl_vault get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$VAULT_POD" ]; then
  echo "ERROR: no Vault pod found in context '${VAULT_CONTEXT}' namespace '${NAMESPACE}'." >&2
  echo "       Run scripts/setup-vault-cluster.sh first." >&2
  exit 1
fi

if ! kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Sealed.*false'; then
  echo "ERROR: Vault in context '${VAULT_CONTEXT}' is not initialized/unsealed." >&2
  echo "       Run scripts/setup-vault-cluster.sh first." >&2
  exit 1
fi

# --- Read the VSO cluster's API server CA -----------------------------------
#
# We read this from the local kubeconfig entry for VSO_CONTEXT rather than
# from inside a VSO-cluster pod, since this is the same CA that signs the
# VSO cluster's API server certificate (whose SANs include TWO_CLUSTER_HOST,
# see scripts/kind/vso-lab-config.yaml.tmpl), and the caller's kubeconfig is
# guaranteed to already have it (it's how `kubectl --context "$VSO_CONTEXT"`
# itself works).

echo "==> Reading API server CA for context '${VSO_CONTEXT}'..."

VSO_CLUSTER_NAME=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name==\"${VSO_CONTEXT}\")].context.cluster}")
if [ -z "$VSO_CLUSTER_NAME" ]; then
  echo "ERROR: could not resolve the cluster entry for context '${VSO_CONTEXT}' from kubeconfig." >&2
  exit 1
fi

VSO_CA_DATA_B64=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${VSO_CLUSTER_NAME}\")].cluster.certificate-authority-data}")
if [ -z "$VSO_CA_DATA_B64" ]; then
  echo "ERROR: no certificate-authority-data found for cluster '${VSO_CLUSTER_NAME}' (context '${VSO_CONTEXT}')." >&2
  echo "       Is this a kind cluster with an embedded CA? Custom kubeconfigs using" >&2
  echo "       certificate-authority (a file path) instead of inline data are not" >&2
  echo "       supported by this script." >&2
  exit 1
fi

VSO_CA_PEM=$(printf '%s' "$VSO_CA_DATA_B64" | base64 --decode)
if [ -z "$VSO_CA_PEM" ]; then
  echo "ERROR: failed to base64-decode the VSO cluster CA data." >&2
  exit 1
fi

echo "    VSO API address: ${VSO_API_ADDR}"
echo "    VSO CA resolved from cluster entry '${VSO_CLUSTER_NAME}'."

# --- Mint (or refresh) the reviewer JWT --------------------------------------
#
# `vault-token-reviewer` and its system:auth-delegator ClusterRoleBinding are
# created by scripts/setup-vso-cluster.sh. This mints a fresh, time-bounded
# token for it every run (see VSO_REVIEWER_TOKEN_TTL / the demo-only
# limitation documented at the top of this file).

echo "==> Minting reviewer JWT for service account '${VAULT_TOKEN_REVIEWER_SA}' (ttl ${VSO_REVIEWER_TOKEN_TTL})..."

REVIEWER_JWT=$(kubectl_vso create token "$VAULT_TOKEN_REVIEWER_SA" -n "$VSO_NAMESPACE" \
  --duration "$VSO_REVIEWER_TOKEN_TTL" 2>/dev/null || true)
if [ -z "$REVIEWER_JWT" ]; then
  echo "ERROR: failed to mint a token for service account '${VAULT_TOKEN_REVIEWER_SA}' in" >&2
  echo "       namespace '${VSO_NAMESPACE}' of context '${VSO_CONTEXT}'." >&2
  echo "       Run scripts/setup-vso-cluster.sh first to create this service account." >&2
  exit 1
fi

# --- Enable auth/kubernetes-vso idempotently ---------------------------------
#
# This must never touch the pre-existing same-cluster `auth/kubernetes`
# mount (Agent Injector / OTel demo paths, configured by
# scripts/setup-vault-cluster.sh).

echo "==> Enabling auth/${VSO_AUTH_MOUNT} in context '${VAULT_CONTEXT}' (if not already enabled)..."
if kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault auth list 2>/dev/null | grep -q "^${VSO_AUTH_MOUNT}/"; then
  echo "    auth/${VSO_AUTH_MOUNT} already enabled. Skipping enable (config below is still refreshed)."
else
  kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- \
    vault auth enable -path="${VSO_AUTH_MOUNT}" -description="Kubernetes auth validated against the VSO cluster (${VSO_CONTEXT}) API server" \
    kubernetes
fi

# --- Configure auth/kubernetes-vso/config ------------------------------------

echo "==> Writing auth/${VSO_AUTH_MOUNT}/config..."
kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write "auth/${VSO_AUTH_MOUNT}/config" \
  kubernetes_host="${VSO_API_ADDR}" \
  kubernetes_ca_cert="${VSO_CA_PEM}" \
  token_reviewer_jwt="${REVIEWER_JWT}"

# --- Write the vso-demo role -------------------------------------------------
#
# Bound only to the `vso-demo` service account in the `vso-demo` namespace of
# the VSO cluster (created by scripts/setup-vso-cluster.sh), granting only
# the `mysecret` policy (seeded by scripts/setup-vault-cluster.sh) -- no
# `default` policy, keeping this identity least-privilege.

echo "==> Writing auth/${VSO_AUTH_MOUNT}/role/${VSO_AUTH_ROLE}..."
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault write "auth/${VSO_AUTH_MOUNT}/role/${VSO_AUTH_ROLE}" \
  alias_name_source=serviceaccount_name \
  bound_service_account_names=vso-demo \
  bound_service_account_namespaces="${VSO_NAMESPACE}" \
  policies=mysecret \
  ttl=1h

echo ""
echo "==> Verifying configuration..."
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault auth list
echo ""
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read "auth/${VSO_AUTH_MOUNT}/role/${VSO_AUTH_ROLE}"

echo ""
echo "auth/${VSO_AUTH_MOUNT} is configured in context '${VAULT_CONTEXT}' against the VSO"
echo "cluster's API server (${VSO_API_ADDR}), and role '${VSO_AUTH_ROLE}' is bound to"
echo "service account '${VSO_NAMESPACE}/vso-demo' with policy 'mysecret'."
echo ""
echo "Reviewer JWT expires in ${VSO_REVIEWER_TOKEN_TTL} (demo-only; not auto-refreshed)."
echo "Re-run this script to mint a fresh reviewer JWT before it expires."
