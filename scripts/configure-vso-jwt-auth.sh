#!/usr/bin/env bash
# scripts/configure-vso-jwt-auth.sh
#
# Configures Vault's dedicated JWT/OIDC auth mount (auth/${VSO_JWT_AUTH_MOUNT},
# default auth/jwt-vso) in the Vault cluster (VAULT_CONTEXT, default
# kind-vault-lab) so it can validate VSO service account JWTs *directly*,
# using the VSO cluster's (VSO_CONTEXT, default kind-vso-lab) JWKS signing
# keys -- with no TokenReview call back to the VSO cluster's API server, and
# no reviewer JWT stored in Vault.
#
# This replaces the TokenReview-based auth/${VSO_AUTH_MOUNT} (default
# auth/kubernetes-vso) pattern configured by
# scripts/configure-vso-kubernetes-auth.sh for the default demo path. See
# docs/vso-jwt-oidc-auth-plan.md and docs/vso-jwt-oidc-auth-spike-01.md for
# the full design/decision record.
#
# What this script does, all idempotently:
#   - Reads the VSO cluster's CA certificate (pulled live from the VSO
#     cluster's kubeconfig entry, same source as
#     scripts/configure-vso-kubernetes-auth.sh) so Vault can validate TLS
#     when fetching JWKS.
#   - Enables `auth/${VSO_JWT_AUTH_MOUNT}` in the Vault cluster as a Vault
#     `jwt` auth method, if not already enabled -- leaves the pre-existing
#     same-cluster `auth/kubernetes` mount (Agent Injector/OTel demo paths)
#     and the (migration-compatibility) `auth/${VSO_AUTH_MOUNT}` mount
#     completely untouched.
#   - Writes/updates `auth/${VSO_JWT_AUTH_MOUNT}/config` with:
#       jwks_url    = ${VSO_OIDC_JWKS_URL} (externally-reachable JWKS
#                     endpoint on the VSO cluster's API server)
#       jwks_ca_pem = the VSO cluster CA
#       bound_issuer = ${VSO_OIDC_ISSUER} (a plain string compare against
#                      the JWT's `iss` claim -- not fetched/resolved)
#     Per the Phase 1 spike decision (docs/vso-jwt-oidc-auth-spike-01.md),
#     `jwks_url` is used rather than `oidc_discovery_url`: the VSO cluster's
#     default kind issuer is cluster-internal and its self-advertised
#     `jwks_uri` is a Podman-bridge IP, neither reachable from the Vault
#     cluster, whereas the externally-mapped JWKS endpoint is proven
#     reachable.
#   - Writes/updates `auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE}`,
#     strictly bound to:
#       role_type       = jwt
#       user_claim      = sub
#       bound_audiences = ${VSO_JWT_AUDIENCE}
#       bound_subject   = system:serviceaccount:${VSO_NAMESPACE}:vso-demo
#     granting only the `mysecret` policy -- no reviewer identity, no
#     `token_reviewer_jwt`, and no loose claim binding (this script never
#     accepts "any token from the issuer" or "any token with the right
#     audience" -- both issuer and audience and subject must match).
#
# Prerequisite (documented, not yet automated by this script): the VSO
# cluster's API server must grant unauthenticated GET access to
# `/openid/v1/jwks` (and `/.well-known/openid-configuration`) for Vault's
# JWKS fetch to succeed -- default kind/kubeadm RBAC does not grant this by
# default. See docs/vso-jwt-oidc-auth-spike-01.md for the
# `oidc-discovery-reader` ClusterRole/ClusterRoleBinding; formalizing this
# into scripts/setup-vso-cluster.sh is tracked separately
# (tasks/vso-jwt-oidc-auth/05-refactor-vso-cluster-setup.md).
#
# Usage:
#   scripts/configure-vso-jwt-auth.sh
#   scripts/configure-vso-jwt-auth.sh --check-only   # validate tools/context only
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VAULT_CONTEXT,
# VSO_CONTEXT, VSO_NAMESPACE, VSO_JWT_AUTH_MOUNT, VSO_JWT_AUTH_ROLE,
# VSO_JWT_AUDIENCE, VSO_OIDC_ISSUER, VSO_OIDC_JWKS_URL).

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
      sed -n '2,58p' "${BASH_SOURCE[0]}"
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
require_commands kubectl base64 jq || fail=1
require_contexts || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK: required commands present and VAULT_CONTEXT/VSO_CONTEXT both exist and differ."
  exit 0
fi

echo "==> Configuring Vault JWT/OIDC auth for VSO service account tokens"
echo "    Vault cluster (auth host): ${VAULT_CONTEXT}"
echo "    VSO cluster (JWKS source): ${VSO_CONTEXT}"
echo "    Auth mount:                auth/${VSO_JWT_AUTH_MOUNT}"
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
# Same source/pattern as scripts/configure-vso-kubernetes-auth.sh: read this
# from the local kubeconfig entry for VSO_CONTEXT (which is guaranteed to
# already have it -- it's how `kubectl --context "$VSO_CONTEXT"` itself
# works), rather than extracting it from inside a pod. This is the CA that
# signs the VSO cluster's API server certificate, whose SANs include
# TWO_CLUSTER_HOST (see scripts/kind/vso-lab-config.yaml.tmpl), which is
# what makes ${VSO_OIDC_JWKS_URL} reachable and TLS-verifiable from Vault.

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

echo "    VSO CA resolved from cluster entry '${VSO_CLUSTER_NAME}' (not printed)."

# --- Enable auth/${VSO_JWT_AUTH_MOUNT} idempotently --------------------------
#
# This must never touch the pre-existing same-cluster `auth/kubernetes`
# mount (Agent Injector / OTel demo paths, configured by
# scripts/setup-vault-cluster.sh) nor the migration-compatibility
# `auth/${VSO_AUTH_MOUNT}` TokenReview mount (configured by
# scripts/configure-vso-kubernetes-auth.sh).

echo "==> Enabling auth/${VSO_JWT_AUTH_MOUNT} in context '${VAULT_CONTEXT}' (if not already enabled)..."
if kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault auth list 2>/dev/null | grep -q "^${VSO_JWT_AUTH_MOUNT}/"; then
  echo "    auth/${VSO_JWT_AUTH_MOUNT} already enabled. Skipping enable (config below is still refreshed)."
else
  # Guard against a TOCTOU race: if another process (e.g. a concurrent
  # setup/demo run) enables auth/${VSO_JWT_AUTH_MOUNT} between the check
  # above and this call, `vault auth enable` fails with "path is already in
  # use" even though the desired end state (mount enabled) is already true.
  # Treat that specific error as success instead of a hard failure so this
  # step stays truly idempotent under concurrency.
  set +e
  ENABLE_OUTPUT=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- \
    vault auth enable -path="${VSO_JWT_AUTH_MOUNT}" -description="JWT/OIDC auth validated directly against the VSO cluster (${VSO_CONTEXT}) JWKS -- no TokenReview, no reviewer JWT" \
    jwt 2>&1)
  ENABLE_EXIT=$?
  set -e
  if [ "$ENABLE_EXIT" -ne 0 ]; then
    if printf '%s' "$ENABLE_OUTPUT" | grep -qi 'path is already in use'; then
      echo "    auth/${VSO_JWT_AUTH_MOUNT} was enabled concurrently between the check and this call. Continuing (idempotent)."
    else
      printf '%s\n' "$ENABLE_OUTPUT" >&2
      echo "ERROR: failed to enable auth/${VSO_JWT_AUTH_MOUNT}." >&2
      exit 1
    fi
  else
    printf '%s\n' "$ENABLE_OUTPUT"
  fi
fi

# --- Configure auth/${VSO_JWT_AUTH_MOUNT}/config -----------------------------
#
# jwks_url mode (not oidc_discovery_url): per the Phase 1 spike decision,
# Vault fetches signing keys directly from VSO_OIDC_JWKS_URL and never
# fetches or trusts the VSO cluster's self-reported OIDC discovery document
# (whose issuer/jwks_uri fields are cluster-internal-only). bound_issuer is
# a pure string comparison against the token's `iss` claim, so it is safe to
# set to that cluster-internal value even though it is not itself
# reachable/resolvable from the Vault cluster.
#
# Deliberately never writes token_reviewer_jwt: this mount has no reviewer
# identity at all.

echo "==> Writing auth/${VSO_JWT_AUTH_MOUNT}/config..."
kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write "auth/${VSO_JWT_AUTH_MOUNT}/config" \
  jwks_url="${VSO_OIDC_JWKS_URL}" \
  jwks_ca_pem="${VSO_CA_PEM}" \
  bound_issuer="${VSO_OIDC_ISSUER}"

# --- Write the vso-demo JWT role ---------------------------------------------
#
# Strictly bound to the exact `vso-demo` service account in the
# `${VSO_NAMESPACE}` namespace of the VSO cluster (created by
# scripts/setup-vso-cluster.sh), the exact audience `${VSO_JWT_AUDIENCE}`,
# and only the `mysecret` policy (seeded by scripts/setup-vault-cluster.sh)
# -- no `default` policy, keeping this identity least-privilege. Binding
# both bound_audiences AND bound_subject (not just the issuer) is the
# concrete mitigation for "a role that accepts any token from the issuer,
# or any token with the right audience, could accidentally allow the wrong
# service account to authenticate" (docs/vso-jwt-oidc-auth-plan.md).

VSO_JWT_BOUND_SUBJECT="system:serviceaccount:${VSO_NAMESPACE}:vso-demo"

echo "==> Writing auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE}..."
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault write "auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE}" \
  role_type=jwt \
  user_claim=sub \
  bound_audiences="${VSO_JWT_AUDIENCE}" \
  bound_subject="${VSO_JWT_BOUND_SUBJECT}" \
  policies=mysecret \
  ttl=1h

echo ""
echo "==> Verifying configuration (no secrets/JWTs/CA material printed)..."
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault auth list
echo ""
# Read as JSON and drop CA/pubkey material with jq before printing -- the
# plain-text `vault read` table wraps multi-line PEM values across several
# output lines with no per-line key prefix, so a naive line-based grep
# filter (matched only against the first line of each field) would leak
# the remaining lines of jwks_ca_pem. jq operates on the whole JSON value,
# so the entire field is removed regardless of how many lines it spans.
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read -format=json "auth/${VSO_JWT_AUTH_MOUNT}/config" \
  | jq 'del(.data.jwks_ca_pem, .data.jwt_validation_pubkeys, .data.oidc_discovery_ca_pem)'
echo ""
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read "auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE}"

echo ""
echo "auth/${VSO_JWT_AUTH_MOUNT} is configured in context '${VAULT_CONTEXT}':"
echo "  issuer (bound_issuer, string compare only): ${VSO_OIDC_ISSUER}"
echo "  jwks_url (fetched directly, VSO cluster):   ${VSO_OIDC_JWKS_URL}"
echo "  bound_audiences:                            ${VSO_JWT_AUDIENCE}"
echo "  bound_subject:                               ${VSO_JWT_BOUND_SUBJECT}"
echo "  policies:                                    mysecret"
echo ""
echo "No token_reviewer_jwt was written -- this mount validates VSO service"
echo "account JWTs directly against the VSO cluster's JWKS, with no"
echo "TokenReview call and no reviewer identity stored in Vault."
