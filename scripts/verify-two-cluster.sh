#!/usr/bin/env bash
# scripts/verify-two-cluster.sh
#
# End-to-end verification that the two-cluster (Podman-backed kind) Vault +
# Vault Secrets Operator (VSO) demo works, top to bottom, across both
# clusters. This is the primary completion gate for the
# `vso-two-cluster-podman` feature (see tasks/vso-two-cluster-podman/).
#
# It proves, in order (each section fails fast with an actionable message):
#
#   1. VAULT_CONTEXT and VSO_CONTEXT exist and are different clusters.
#   2. Vault is installed and Ready in the Vault cluster ONLY (not in VSO).
#   3. VSO operator, CRDs, the vso-demo namespace, and the app pod exist in
#      the VSO cluster ONLY (not in the Vault cluster).
#   4. A pod in the VSO cluster can reach Vault at the documented external
#      address (VAULT_ADDR).
#   5. Vault authenticates a real VSO cluster service account JWT directly
#      against the VSO cluster's JWKS (no TokenReview) through the
#      dedicated auth/${VSO_JWT_AUTH_MOUNT} (jwt-vso) mount -- and proves
#      that mount's strict claim binding by also confirming a
#      wrong-audience JWT and a wrong-service-account JWT are BOTH
#      rejected.
#   6. The VaultStaticSecret is Ready/Synced and its native Secret value
#      matches what's actually in Vault.
#   7. A rotation performed in the Vault cluster is observed in the VSO
#      cluster's native Secret within the refresh window, and the baseline
#      value is restored afterward.
#
# Usage:
#   scripts/verify-two-cluster.sh
#   scripts/verify-two-cluster.sh --check-only     # validate tools/contexts only
#   scripts/verify-two-cluster.sh --skip-rotation   # skip the (slower) rotation section
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VAULT_CONTEXT,
# VSO_CONTEXT, VAULT_ADDR, NAMESPACE, VSO_NAMESPACE, VSO_OPERATOR_NAMESPACE,
# VSO_JWT_AUTH_MOUNT, VSO_JWT_AUTH_ROLE, VSO_JWT_AUDIENCE, SECRET_NAME,
# APP_POD), plus BASELINE_USERNAME (default: larry), ROTATED_USERNAME
# (default: larry-rotated), ROTATION_ATTEMPTS (default: 20),
# ROTATION_SLEEP (default: 3, seconds between polls), and
# VSO_JWT_WRONG_AUDIENCE (default: not-${VSO_JWT_AUDIENCE}, used only for
# the negative wrong-audience test in section 5).
#
# NOTE: no full JWT value is ever printed to stdout/stderr by this script --
# only pass/fail outcomes and Vault's own (JWT-free) login/error responses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/two-cluster-env.sh
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

BASELINE_USERNAME="${BASELINE_USERNAME:-larry}"
ROTATED_USERNAME="${ROTATED_USERNAME:-larry-rotated}"
ROTATION_ATTEMPTS="${ROTATION_ATTEMPTS:-20}"
ROTATION_SLEEP="${ROTATION_SLEEP:-3}"

CHECK_ONLY=0
SKIP_ROTATION=0
for arg in "$@"; do
  case "$arg" in
    --check-only)
      CHECK_ONLY=1
      ;;
    --skip-rotation)
      SKIP_ROTATION=1
      ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg' (supported: --check-only, --skip-rotation)" >&2
      exit 1
      ;;
  esac
done

SECTION=""
fail_section() {
  echo "" >&2
  echo "FAILED at section: ${SECTION}" >&2
  echo "$*" >&2
  exit 1
}

section() {
  SECTION="$1"
  echo ""
  echo "==> [${SECTION}]"
}

# ---------------------------------------------------------------------------
# 1. Contexts
# ---------------------------------------------------------------------------

section "1/7 contexts"

fail=0
require_commands kubectl base64 jq || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

require_contexts || fail_section \
  "VAULT_CONTEXT ('${VAULT_CONTEXT}') and VSO_CONTEXT ('${VSO_CONTEXT}') must both exist and be different clusters." \
  "Run 'make clusters' (or scripts/create-clusters.sh) first."

echo "OK: VAULT_CONTEXT='${VAULT_CONTEXT}' and VSO_CONTEXT='${VSO_CONTEXT}' both exist and differ."

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo ""
  echo "OK (--check-only): required commands present, contexts valid. Skipping the rest."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Vault installed and Ready in the Vault cluster ONLY
# ---------------------------------------------------------------------------

section "2/7 vault placement + readiness"

VAULT_POD=$(kubectl_vault get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$VAULT_POD" ]; then
  fail_section \
    "No Vault pod found in context '${VAULT_CONTEXT}' namespace '${NAMESPACE}'." \
    "Run 'make setup-vault' (or scripts/setup-vault-cluster.sh) first."
fi

if ! kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Sealed.*false'; then
  fail_section \
    "Vault pod '${VAULT_POD}' in context '${VAULT_CONTEXT}' is not initialized/unsealed." \
    "Run 'make setup-vault' (or scripts/setup-vault-cluster.sh) first."
fi
echo "OK: Vault pod '${VAULT_POD}' is running and unsealed in context '${VAULT_CONTEXT}'."

# Negative placement: Vault must NOT be running in the VSO cluster.
VAULT_IN_VSO=$(kubectl_vso get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
if [ -n "$VAULT_IN_VSO" ]; then
  fail_section \
    "Found Vault pod(s) '${VAULT_IN_VSO}' running in the VSO cluster (context '${VSO_CONTEXT}')." \
    "Vault must run only in the Vault cluster (context '${VAULT_CONTEXT}')."
fi
echo "OK: no Vault pod found in the VSO cluster (context '${VSO_CONTEXT}')."

# ---------------------------------------------------------------------------
# 3. VSO operator, CRDs, app namespace, app pod in the VSO cluster ONLY
# ---------------------------------------------------------------------------

section "3/7 vso placement + readiness"

if ! kubectl_vso get deploy -n "$VSO_OPERATOR_NAMESPACE" \
    -l app.kubernetes.io/name=vault-secrets-operator \
    -o jsonpath='{.items[0].metadata.name}' >/dev/null 2>&1; then
  fail_section \
    "No Vault Secrets Operator deployment found in context '${VSO_CONTEXT}' namespace '${VSO_OPERATOR_NAMESPACE}'." \
    "Run 'make setup-vso' (or scripts/setup-vso-cluster.sh) first."
fi

VSO_AVAILABLE=$(kubectl_vso get deploy -n "$VSO_OPERATOR_NAMESPACE" \
  -l app.kubernetes.io/name=vault-secrets-operator \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
if [ "$VSO_AVAILABLE" != "True" ]; then
  fail_section \
    "Vault Secrets Operator deployment in context '${VSO_CONTEXT}' is not Available (status='${VSO_AVAILABLE:-<none>}')." \
    "Check: kubectl --context ${VSO_CONTEXT} get pods -n ${VSO_OPERATOR_NAMESPACE}"
fi
echo "OK: Vault Secrets Operator deployment is Available in context '${VSO_CONTEXT}'."

if ! kubectl_vso get crd vaultstaticsecrets.secrets.hashicorp.com >/dev/null 2>&1; then
  fail_section \
    "CRD 'vaultstaticsecrets.secrets.hashicorp.com' not found in context '${VSO_CONTEXT}'." \
    "Run 'make setup-vso' (or scripts/setup-vso-cluster.sh) first."
fi
echo "OK: VSO CRDs are installed in context '${VSO_CONTEXT}'."

if ! kubectl_vso get namespace "$VSO_NAMESPACE" >/dev/null 2>&1; then
  fail_section \
    "Namespace '${VSO_NAMESPACE}' not found in context '${VSO_CONTEXT}'." \
    "Run 'make setup-vso' (or scripts/setup-vso-cluster.sh) first."
fi

APP_POD_PHASE=$(kubectl_vso get pod "$APP_POD" -n "$VSO_NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$APP_POD_PHASE" != "Running" ]; then
  fail_section \
    "App pod '${APP_POD}' in context '${VSO_CONTEXT}' namespace '${VSO_NAMESPACE}' is not Running (phase='${APP_POD_PHASE:-<not found>}')." \
    "Run 'make vso-apply' (or scripts/apply-vso-demo.sh) first."
fi
echo "OK: app pod '${APP_POD}' is Running in context '${VSO_CONTEXT}' namespace '${VSO_NAMESPACE}'."

# Negative placement: VSO operator, CRDs, and the app namespace must NOT
# exist in the Vault cluster.
if kubectl_vault get namespace "$VSO_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
  fail_section \
    "Namespace '${VSO_OPERATOR_NAMESPACE}' unexpectedly exists in the Vault cluster (context '${VAULT_CONTEXT}')." \
    "VSO must run only in the VSO cluster (context '${VSO_CONTEXT}')."
fi

if kubectl_vault get crd vaultstaticsecrets.secrets.hashicorp.com >/dev/null 2>&1; then
  fail_section \
    "VSO CRDs unexpectedly installed in the Vault cluster (context '${VAULT_CONTEXT}')." \
    "VSO CRDs must be installed only in the VSO cluster (context '${VSO_CONTEXT}')."
fi

if kubectl_vault get namespace "$VSO_NAMESPACE" >/dev/null 2>&1; then
  fail_section \
    "Namespace '${VSO_NAMESPACE}' unexpectedly exists in the Vault cluster (context '${VAULT_CONTEXT}')." \
    "The vso-demo namespace/app must exist only in the VSO cluster (context '${VSO_CONTEXT}')."
fi
echo "OK: VSO operator, CRDs, and namespace '${VSO_NAMESPACE}' are absent from the Vault cluster (context '${VAULT_CONTEXT}')."

# ---------------------------------------------------------------------------
# 4. Network reachability: a pod in the VSO cluster can reach Vault at the
#    documented external address.
# ---------------------------------------------------------------------------

section "4/7 network reachability (VSO cluster -> Vault external address)"

if ! bash "${SCRIPT_DIR}/check-vault-connectivity.sh"; then
  fail_section \
    "A pod in the VSO cluster (context '${VSO_CONTEXT}') could not reach Vault at '${VAULT_ADDR}'." \
    "See PODMAN_MIGRATION.md and scripts/check-vault-connectivity.sh output above for diagnostics."
fi
echo "OK: a pod in the VSO cluster reached Vault at '${VAULT_ADDR}'."

# ---------------------------------------------------------------------------
# 5. JWT/OIDC auth: Vault authenticates a real VSO cluster service account
#    JWT, validated directly against the VSO cluster's JWKS (no
#    TokenReview, no reviewer JWT), through auth/${VSO_JWT_AUTH_MOUNT}. This
#    also proves the mount's strict claim binding by confirming a
#    wrong-audience JWT and a wrong-service-account JWT are BOTH rejected
#    -- JWT/OIDC security depends on this, so these negative checks are
#    mandatory, not optional.
# ---------------------------------------------------------------------------

section "5/7 jwt/oidc auth (auth/${VSO_JWT_AUTH_MOUNT})"

if ! kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault auth list 2>/dev/null | grep -q "^${VSO_JWT_AUTH_MOUNT}/"; then
  fail_section \
    "auth/${VSO_JWT_AUTH_MOUNT} is not enabled in context '${VAULT_CONTEXT}'." \
    "Run 'make configure-vso-auth' (or scripts/configure-vso-jwt-auth.sh) first."
fi

# 5.0 Role/config output includes strict claim binding (bound_audiences AND
#     bound_subject, not just the issuer) -- the concrete mitigation this
#     mount relies on so the wrong audience or wrong service account can't
#     accidentally authenticate.
ROLE_OUTPUT=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read -format=json \
  "auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE}" 2>&1) || {
  fail_section \
    "Could not read auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE} in context '${VAULT_CONTEXT}'." \
    "Run 'make configure-vso-auth' (or scripts/configure-vso-jwt-auth.sh) first."
}

ROLE_BOUND_AUDIENCES=$(printf '%s' "$ROLE_OUTPUT" | jq -r '(.data.bound_audiences // []) | join(",")' 2>/dev/null || true)
ROLE_BOUND_SUBJECT=$(printf '%s' "$ROLE_OUTPUT" | jq -r '.data.bound_subject // empty' 2>/dev/null || true)
EXPECTED_BOUND_SUBJECT="system:serviceaccount:${VSO_NAMESPACE}:vso-demo"

if [ "$ROLE_BOUND_AUDIENCES" != "$VSO_JWT_AUDIENCE" ] || [ "$ROLE_BOUND_SUBJECT" != "$EXPECTED_BOUND_SUBJECT" ]; then
  fail_section \
    "auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE} is not strictly bound (bound_audiences='${ROLE_BOUND_AUDIENCES:-<none>}', bound_subject='${ROLE_BOUND_SUBJECT:-<none>}'; expected audience '${VSO_JWT_AUDIENCE}' and subject '${EXPECTED_BOUND_SUBJECT}')." \
    "Run 'make configure-vso-auth' (or scripts/configure-vso-jwt-auth.sh) first."
fi
echo "OK: auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE} strictly binds bound_audiences='${VSO_JWT_AUDIENCE}' and bound_subject='${EXPECTED_BOUND_SUBJECT}'."

# 5.1 Positive: the real 'vso-demo' service account, with the intended
#     audience, must authenticate successfully.
VSO_SA_JWT=$(kubectl_vso create token vso-demo -n "$VSO_NAMESPACE" --duration 10m --audience "${VSO_JWT_AUDIENCE}" 2>/dev/null || true)
if [ -z "$VSO_SA_JWT" ]; then
  fail_section \
    "Failed to mint a token for service account 'vso-demo' in namespace '${VSO_NAMESPACE}' of context '${VSO_CONTEXT}' (audience: ${VSO_JWT_AUDIENCE})." \
    "Run 'make setup-vso' (or scripts/setup-vso-cluster.sh) first."
fi

LOGIN_OUTPUT=$(kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write -format=json \
  "auth/${VSO_JWT_AUTH_MOUNT}/login" role="${VSO_JWT_AUTH_ROLE}" jwt="${VSO_SA_JWT}" 2>&1) || {
  unset VSO_SA_JWT
  fail_section \
    "Vault rejected the correct 'vso-demo' service account JWT (audience: ${VSO_JWT_AUDIENCE}) against auth/${VSO_JWT_AUTH_MOUNT}/login (role: ${VSO_JWT_AUTH_ROLE})." \
    "$LOGIN_OUTPUT"
}
unset VSO_SA_JWT

LOGIN_TOKEN=$(printf '%s' "$LOGIN_OUTPUT" | jq -r '.auth.client_token // empty' 2>/dev/null || true)
if [ -z "$LOGIN_TOKEN" ]; then
  fail_section \
    "Vault login through auth/${VSO_JWT_AUTH_MOUNT} did not return a client_token for the correct 'vso-demo' JWT." \
    "$LOGIN_OUTPUT"
fi
unset LOGIN_TOKEN LOGIN_OUTPUT
echo "OK: correct 'vso-demo' service account JWT (audience: ${VSO_JWT_AUDIENCE}) authenticates through auth/${VSO_JWT_AUTH_MOUNT} (role: ${VSO_JWT_AUTH_ROLE})."

# 5.2 Negative: the real 'vso-demo' service account but the WRONG
#     audience must be rejected (proves bound_audiences is enforced).
VSO_JWT_WRONG_AUDIENCE="${VSO_JWT_WRONG_AUDIENCE:-not-${VSO_JWT_AUDIENCE}}"
WRONG_AUD_JWT=$(kubectl_vso create token vso-demo -n "$VSO_NAMESPACE" --duration 10m --audience "${VSO_JWT_WRONG_AUDIENCE}" 2>/dev/null || true)
if [ -z "$WRONG_AUD_JWT" ]; then
  fail_section \
    "Failed to mint a wrong-audience token for service account 'vso-demo' in namespace '${VSO_NAMESPACE}' of context '${VSO_CONTEXT}' (audience: ${VSO_JWT_WRONG_AUDIENCE})." \
    "Run 'make setup-vso' (or scripts/setup-vso-cluster.sh) first."
fi

if kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write -format=json \
    "auth/${VSO_JWT_AUTH_MOUNT}/login" role="${VSO_JWT_AUTH_ROLE}" jwt="${WRONG_AUD_JWT}" >/dev/null 2>&1; then
  unset WRONG_AUD_JWT
  fail_section \
    "Vault incorrectly ACCEPTED a 'vso-demo' service account JWT with the wrong audience ('${VSO_JWT_WRONG_AUDIENCE}') against auth/${VSO_JWT_AUTH_MOUNT}/login." \
    "Strict bound_audiences claim binding is not being enforced; check auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE}."
fi
unset WRONG_AUD_JWT
echo "OK: Vault rejected a 'vso-demo' service account JWT with the wrong audience ('${VSO_JWT_WRONG_AUDIENCE}')."

# 5.3 Negative: the correct audience but the WRONG service account (the
#     namespace's 'default' SA, not 'vso-demo') must be rejected (proves
#     bound_subject is enforced).
WRONG_SA_JWT=$(kubectl_vso create token default -n "$VSO_NAMESPACE" --duration 10m --audience "${VSO_JWT_AUDIENCE}" 2>/dev/null || true)
if [ -z "$WRONG_SA_JWT" ]; then
  fail_section \
    "Failed to mint a wrong-service-account token for the 'default' service account in namespace '${VSO_NAMESPACE}' of context '${VSO_CONTEXT}'." \
    "Run 'make setup-vso' (or scripts/setup-vso-cluster.sh) first."
fi

if kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write -format=json \
    "auth/${VSO_JWT_AUTH_MOUNT}/login" role="${VSO_JWT_AUTH_ROLE}" jwt="${WRONG_SA_JWT}" >/dev/null 2>&1; then
  unset WRONG_SA_JWT
  fail_section \
    "Vault incorrectly ACCEPTED a JWT from the wrong service account ('default' in namespace '${VSO_NAMESPACE}') against auth/${VSO_JWT_AUTH_MOUNT}/login." \
    "Strict bound_subject claim binding is not being enforced; check auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE}."
fi
unset WRONG_SA_JWT
echo "OK: Vault rejected a JWT from the wrong service account ('default' in namespace '${VSO_NAMESPACE}')."

# ---------------------------------------------------------------------------
# 6. VaultStaticSecret reconciliation + native Secret value
# ---------------------------------------------------------------------------

section "6/7 vso reconciliation + secret sync"

VSS_READY=$(kubectl_vso get vaultstaticsecret "$SECRET_NAME" -n "$VSO_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$VSS_READY" != "True" ]; then
  fail_section \
    "VaultStaticSecret '${SECRET_NAME}' in context '${VSO_CONTEXT}' namespace '${VSO_NAMESPACE}' is not Ready (status='${VSS_READY:-<none>}')." \
    "Inspect with: kubectl --context ${VSO_CONTEXT} describe vaultstaticsecret ${SECRET_NAME} -n ${VSO_NAMESPACE}"
fi
echo "OK: VaultStaticSecret '${SECRET_NAME}' is Ready in context '${VSO_CONTEXT}'."

VAULT_VALUE=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault kv get -field=username kv-v2/vault-demo/mysecret 2>/dev/null || true)
VSO_VALUE=$(kubectl_vso get secret "$SECRET_NAME" -n "$VSO_NAMESPACE" \
  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [ -z "$VAULT_VALUE" ]; then
  fail_section \
    "Could not read kv-v2/vault-demo/mysecret from Vault (context '${VAULT_CONTEXT}')." \
    "Run 'make setup-vault' (or scripts/setup-vault-cluster.sh) first."
fi

if [ "$VAULT_VALUE" != "$VSO_VALUE" ]; then
  fail_section \
    "Native Secret '${SECRET_NAME}' value ('${VSO_VALUE:-<empty>}') does not match Vault's value ('${VAULT_VALUE}')." \
    "Inspect with: kubectl --context ${VSO_CONTEXT} describe vaultstaticsecret ${SECRET_NAME} -n ${VSO_NAMESPACE}"
fi
echo "OK: native Secret '${SECRET_NAME}' value matches Vault's value ('${VAULT_VALUE}')."

# ---------------------------------------------------------------------------
# 7. Rotation: write in the Vault cluster, poll the VSO cluster Secret,
#    reset the baseline value.
# ---------------------------------------------------------------------------

if [ "$SKIP_ROTATION" -eq 1 ]; then
  echo ""
  echo "==> [7/7 rotation] skipped (--skip-rotation)."
else
  section "7/7 rotation (Vault cluster write -> VSO cluster Secret update)"

  echo "==> Writing rotated value (username=${ROTATED_USERNAME}) to kv-v2/vault-demo/mysecret in ${VAULT_CONTEXT}..."
  kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- \
    vault kv put kv-v2/vault-demo/mysecret username="${ROTATED_USERNAME}" >/dev/null

  ROTATED_SYNCED="false"
  for i in $(seq 1 "$ROTATION_ATTEMPTS"); do
    CURRENT_VALUE=$(kubectl_vso get secret "$SECRET_NAME" -n "$VSO_NAMESPACE" \
      -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
    echo "    attempt ${i}: ${CURRENT_VALUE:-<not yet synced>}"
    if [ "$CURRENT_VALUE" = "$ROTATED_USERNAME" ]; then
      ROTATED_SYNCED="true"
      break
    fi
    sleep "$ROTATION_SLEEP"
  done

  if [ "$ROTATED_SYNCED" != "true" ]; then
    # Reset the baseline before failing, so a re-run starts clean.
    kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- \
      vault kv put kv-v2/vault-demo/mysecret username="${BASELINE_USERNAME}" >/dev/null 2>&1 || true
    fail_section \
      "The VSO cluster's native Secret '${SECRET_NAME}' did not reflect the rotated value ('${ROTATED_USERNAME}') within ${ROTATION_ATTEMPTS} attempts (${ROTATION_SLEEP}s apart)." \
      "Inspect with: kubectl --context ${VSO_CONTEXT} describe vaultstaticsecret ${SECRET_NAME} -n ${VSO_NAMESPACE}; and: kubectl --context ${VSO_CONTEXT} logs -n ${VSO_OPERATOR_NAMESPACE} -l app.kubernetes.io/name=vault-secrets-operator"
  fi
  echo "OK: rotation observed in the VSO cluster's native Secret within ${i} attempt(s)."

  echo "==> Resetting kv-v2/vault-demo/mysecret to baseline (username=${BASELINE_USERNAME}) in ${VAULT_CONTEXT}..."
  kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- \
    vault kv put kv-v2/vault-demo/mysecret username="${BASELINE_USERNAME}" >/dev/null

  RESET_SYNCED="false"
  for i in $(seq 1 "$ROTATION_ATTEMPTS"); do
    CURRENT_VALUE=$(kubectl_vso get secret "$SECRET_NAME" -n "$VSO_NAMESPACE" \
      -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ "$CURRENT_VALUE" = "$BASELINE_USERNAME" ]; then
      RESET_SYNCED="true"
      break
    fi
    sleep "$ROTATION_SLEEP"
  done

  if [ "$RESET_SYNCED" != "true" ]; then
    fail_section \
      "Reset the Vault value back to baseline ('${BASELINE_USERNAME}'), but the VSO cluster's native Secret has not caught up yet." \
      "This is a soft failure: baseline was written; re-run verification, or check: kubectl --context ${VSO_CONTEXT} get vaultstaticsecret ${SECRET_NAME} -n ${VSO_NAMESPACE}"
  fi
  echo "OK: baseline value (username=${BASELINE_USERNAME}) restored and confirmed in the VSO cluster."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=================================================================="
echo "VERIFIED: two-cluster VSO demo is healthy end-to-end."
echo "  Vault cluster (context '${VAULT_CONTEXT}'):  Vault Running/unsealed"
echo "  VSO cluster   (context '${VSO_CONTEXT}'):    VSO Available, CRDs installed, app Running"
echo "  Network:      VSO cluster -> Vault @ ${VAULT_ADDR} reachable"
echo "  Auth:         auth/${VSO_JWT_AUTH_MOUNT} (JWT/OIDC) authenticates vso-demo service account (role: ${VSO_JWT_AUTH_ROLE});"
echo "                wrong-audience and wrong-service-account JWTs correctly rejected"
echo "  Sync:         VaultStaticSecret '${SECRET_NAME}' Ready, native Secret matches Vault"
if [ "$SKIP_ROTATION" -eq 1 ]; then
  echo "  Rotation:     skipped (--skip-rotation)"
else
  echo "  Rotation:     observed within refresh window, baseline restored"
fi
echo "=================================================================="
