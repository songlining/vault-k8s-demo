#!/usr/bin/env bash
# scripts/configure-vso-auth-delegator.sh
#
# Configures a dedicated Vault Kubernetes auth mount
# (auth/${AUTH_DELEGATOR_AUTH_MOUNT}, default auth/kubernetes-vso-self-review)
# in the Vault cluster (VAULT_CONTEXT, default kind-vault-lab) for the
# CLIENT JWT SELF-REVIEW scenario: VSO's own short-lived, dual-audience
# ServiceAccount JWT is both the `jwt` submitted to Vault's login endpoint
# AND the HTTP bearer Vault uses when it calls the VSO cluster's
# TokenReview API. See docs/vso-kubernetes-auth-delegator-plan.md.
#
# This is a THIRD, independent Vault Kubernetes auth mount. It must never
# touch:
#   - auth/kubernetes           (same-cluster Agent Injector/OTel demo path)
#   - auth/${VSO_JWT_AUTH_MOUNT} (default cross-cluster JWT/OIDC scenario)
#   - auth/${VSO_AUTH_MOUNT}     (historical dedicated-reviewer Kubernetes auth)
#
# What this script does, all idempotently:
#   - Reads the VSO cluster's API server CA from kubeconfig (never printed).
#   - Enables auth/${AUTH_DELEGATOR_AUTH_MOUNT} if not already enabled. If a
#     mount of that name already exists, it must be type `kubernetes` with
#     the exact scenario description before this script will touch it --
#     otherwise it stops rather than overwrite an unrelated mount.
#   - Writes auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config as a single JSON
#     payload over stdin (kubernetes_host, kubernetes_ca_cert,
#     disable_local_ca_jwt=true, disable_iss_validation=true, and an EMPTY
#     token_reviewer_jwt to clear any drift) -- this keeps the CA PEM (and
#     any future reviewer JWT) out of argv/process-list entirely, unlike
#     the legacy scripts/configure-vso-kubernetes-auth.sh, which passes CA
#     PEM as a `vault write key=value` argument.
#   - Reads the config back and fails unless kubernetes_host matches,
#     disable_local_ca_jwt=true, disable_iss_validation=true, and
#     token_reviewer_jwt_set=false.
#   - Creates the sole scenario-owned Vault policy
#     (auth_delegator_policy_hcl in scripts/lib/two-cluster-env.sh): read
#     only on the dedicated KV v2 data path. A pre-existing same-name
#     policy is reused only when its canonical rules are byte-identical;
#     otherwise this script refuses to overwrite it.
#   - Creates auth/${AUTH_DELEGATOR_AUTH_MOUNT}/role/${AUTH_DELEGATOR_ROLE},
#     bound exactly to the self-review ServiceAccount, the consumer
#     namespace, and the `vault` audience, with no default policy and
#     non-renewable batch tokens (token_type=batch).
#   - Snapshots the existing default JWT/OIDC mount/role
#     (auth/${VSO_JWT_AUTH_MOUNT}) before and after every write this script
#     performs, and fails loudly if that snapshot changed -- proving this
#     script never disturbs the coexisting scenario. The same snapshot
#     helper is reused by scripts/verify-vso-auth-delegator.sh.
#   - Prints only sanitized configuration and pass/fail statements -- no
#     JWTs, Vault tokens, or CA PEM data are ever printed.
#
# Usage:
#   scripts/configure-vso-auth-delegator.sh
#   scripts/configure-vso-auth-delegator.sh --check-only
#
#   --check-only performs NO writes. It validates contexts, the existing
#   kind control-plane containers, live Vault/VSO versions and CRD/RBAC
#   fields (via preflight_auth_delegator_runtime), endpoints, CA data
#   availability, audience coherence, and mount-name availability/ownership.
#
# Env overrides live in scripts/lib/two-cluster-env.sh
# (VAULT_CONTEXT, VSO_CONTEXT, VSO_API_ADDR, AUTH_DELEGATOR_*).
#
# This script never creates, deletes, or recreates a kind cluster, and never
# runs Helm install/upgrade.

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
      sed -n '2,55p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg' (supported: --check-only)" >&2
      exit 1
      ;;
  esac
done

# --- Validation --------------------------------------------------------

fail=0
require_commands kubectl jq base64 || fail=1
require_contexts || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

validate_auth_delegator_env || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "==> [--check-only] validating environment, runtime feature support, and prerequisites (no writes)"

  preflight_auth_delegator_runtime || fail=1

  if context_exists "$VAULT_CONTEXT"; then
    VAULT_POD_CHECK=$(kubectl_vault get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$VAULT_POD_CHECK" ]; then
      echo "NOTE: no Vault pod found yet in context '${VAULT_CONTEXT}' namespace '${NAMESPACE}'." >&2
    else
      if kubectl_vault exec "$VAULT_POD_CHECK" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Sealed.*false'; then
        echo "OK: Vault pod '${VAULT_POD_CHECK}' is running and unsealed."
      else
        echo "ERROR: Vault pod '${VAULT_POD_CHECK}' is not initialized/unsealed." >&2
        fail=1
      fi

      EXISTING_MOUNT_TYPE=$(kubectl_vault exec "$VAULT_POD_CHECK" -n "$NAMESPACE" -- vault read -format=json sys/auth 2>/dev/null \
        | jq -r --arg p "${AUTH_DELEGATOR_AUTH_MOUNT}/" '.data[$p].type // empty' 2>/dev/null || true)
      if [ -n "$EXISTING_MOUNT_TYPE" ] && [ "$EXISTING_MOUNT_TYPE" != "kubernetes" ]; then
        echo "ERROR: a mount already exists at auth/${AUTH_DELEGATOR_AUTH_MOUNT} with type '${EXISTING_MOUNT_TYPE}' (expected 'kubernetes' or unmounted)." >&2
        fail=1
      else
        echo "OK: auth/${AUTH_DELEGATOR_AUTH_MOUNT} is either unmounted or already the expected 'kubernetes' type."
      fi
    fi
  else
    echo "NOTE: context '${VAULT_CONTEXT}' does not exist yet; skipping live Vault checks." >&2
  fi

  if context_exists "$VSO_CONTEXT"; then
    VSO_CLUSTER_NAME_CHECK=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name==\"${VSO_CONTEXT}\")].context.cluster}" 2>/dev/null || true)
    VSO_CA_DATA_B64_CHECK=""
    if [ -n "$VSO_CLUSTER_NAME_CHECK" ]; then
      VSO_CA_DATA_B64_CHECK=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${VSO_CLUSTER_NAME_CHECK}\")].cluster.certificate-authority-data}" 2>/dev/null || true)
    fi
    if [ -z "$VSO_CA_DATA_B64_CHECK" ]; then
      echo "ERROR: no certificate-authority-data available for context '${VSO_CONTEXT}'." >&2
      fail=1
    else
      echo "OK: VSO cluster CA is resolvable from kubeconfig (not printed)."
    fi
    unset VSO_CLUSTER_NAME_CHECK VSO_CA_DATA_B64_CHECK
  fi

  if [ "$fail" -ne 0 ]; then
    exit 1
  fi
  echo ""
  echo "OK (--check-only): environment, runtime feature support, and endpoints look correct. No writes performed."
  exit 0
fi

echo "==> Configuring Vault Kubernetes auth (client JWT self-review) against the VSO cluster"
echo "    Vault cluster (auth host): ${VAULT_CONTEXT}"
echo "    VSO cluster (validated):   ${VSO_CONTEXT}"
echo "    Auth mount:                auth/${AUTH_DELEGATOR_AUTH_MOUNT}"
echo "    Role:                      ${AUTH_DELEGATOR_ROLE}"
echo "    Policy:                    ${AUTH_DELEGATOR_POLICY}"
echo ""

preflight_auth_delegator_runtime || {
  echo "ERROR: runtime feature preflight failed; see diagnostics above." >&2
  exit 1
}

# --- Locate the Vault pod ------------------------------------------------

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

# --- Snapshot the coexisting JWT/OIDC scenario BEFORE any writes ----------

JWT_OIDC_SNAPSHOT_BEFORE=$(capture_jwt_oidc_baseline_snapshot "$VAULT_POD")

# --- Read the VSO cluster's API server CA (never printed) -----------------

echo "==> Reading API server CA for context '${VSO_CONTEXT}'..."

VSO_CLUSTER_NAME=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name==\"${VSO_CONTEXT}\")].context.cluster}")
if [ -z "$VSO_CLUSTER_NAME" ]; then
  echo "ERROR: could not resolve the cluster entry for context '${VSO_CONTEXT}' from kubeconfig." >&2
  exit 1
fi

VSO_CA_DATA_B64=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${VSO_CLUSTER_NAME}\")].cluster.certificate-authority-data}")
if [ -z "$VSO_CA_DATA_B64" ]; then
  echo "ERROR: no certificate-authority-data found for cluster '${VSO_CLUSTER_NAME}' (context '${VSO_CONTEXT}')." >&2
  exit 1
fi

VSO_CA_PEM=$(printf '%s' "$VSO_CA_DATA_B64" | base64 --decode)
if [ -z "$VSO_CA_PEM" ]; then
  echo "ERROR: failed to base64-decode the VSO cluster CA data." >&2
  exit 1
fi
unset VSO_CA_DATA_B64
echo "    VSO CA resolved from cluster entry '${VSO_CLUSTER_NAME}' (not printed)."

# --- Enable auth/${AUTH_DELEGATOR_AUTH_MOUNT} idempotently, refusing to ---
# --- adopt a foreign same-name mount --------------------------------------

echo "==> Checking auth/${AUTH_DELEGATOR_AUTH_MOUNT} in context '${VAULT_CONTEXT}'..."
EXISTING_AUTH_JSON=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read -format=json sys/auth 2>/dev/null || echo '{}')
EXISTING_MOUNT_TYPE=$(printf '%s' "$EXISTING_AUTH_JSON" | jq -r --arg p "${AUTH_DELEGATOR_AUTH_MOUNT}/" '.data[$p].type // empty')
EXISTING_MOUNT_DESC=$(printf '%s' "$EXISTING_AUTH_JSON" | jq -r --arg p "${AUTH_DELEGATOR_AUTH_MOUNT}/" '.data[$p].description // empty')
unset EXISTING_AUTH_JSON

if [ -z "$EXISTING_MOUNT_TYPE" ]; then
  echo "==> Enabling auth/${AUTH_DELEGATOR_AUTH_MOUNT}..."
  kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- \
    vault auth enable -path="${AUTH_DELEGATOR_AUTH_MOUNT}" -description="${AUTH_DELEGATOR_MOUNT_DESCRIPTION}" \
    kubernetes
elif [ "$EXISTING_MOUNT_TYPE" != "kubernetes" ]; then
  echo "ERROR: auth/${AUTH_DELEGATOR_AUTH_MOUNT} already exists with type '${EXISTING_MOUNT_TYPE}' (expected 'kubernetes')." >&2
  echo "       Refusing to overwrite a mount this scenario does not own." >&2
  exit 1
elif [ "$EXISTING_MOUNT_DESC" != "$AUTH_DELEGATOR_MOUNT_DESCRIPTION" ]; then
  echo "ERROR: auth/${AUTH_DELEGATOR_AUTH_MOUNT} already exists but its description does not match this scenario's expected ownership marker." >&2
  echo "       expected: ${AUTH_DELEGATOR_MOUNT_DESCRIPTION}" >&2
  echo "       actual:   ${EXISTING_MOUNT_DESC}" >&2
  echo "       Refusing to overwrite a mount this scenario does not own." >&2
  exit 1
else
  echo "    auth/${AUTH_DELEGATOR_AUTH_MOUNT} already enabled and owned by this scenario. Skipping enable (config below is still refreshed)."
fi
unset EXISTING_MOUNT_TYPE EXISTING_MOUNT_DESC

# --- Write auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config as JSON over stdin ----
#
# Client JWT self-review: no token_reviewer_jwt is ever configured (sent
# empty here to clear drift from a previous run), and
# disable_local_ca_jwt=true so Vault never falls back to its own pod's
# local ServiceAccount token/CA. disable_iss_validation=true is the
# plugin's documented default for this mode -- Kubernetes TokenReview
# performs issuer validation instead of a second Vault-side check.
# Sending the whole payload as one JSON object over stdin keeps the CA PEM
# out of argv/process-list entirely.

echo "==> Writing auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config (JSON via stdin, CA not printed)..."
jq -n \
  --arg host "${VSO_API_ADDR}" \
  --arg ca "${VSO_CA_PEM}" \
  '{
     kubernetes_host: $host,
     kubernetes_ca_cert: $ca,
     disable_local_ca_jwt: true,
     disable_iss_validation: true,
     token_reviewer_jwt: ""
   }' \
  | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config" -
unset VSO_CA_PEM

echo "==> Reading back auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config and verifying required fields..."
MOUNT_CONFIG=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read -format=json "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config" 2>&1) || {
  echo "ERROR: failed to read back auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config." >&2
  echo "$MOUNT_CONFIG" >&2
  exit 1
}

if ! printf '%s' "$MOUNT_CONFIG" | jq -e --arg host "${VSO_API_ADDR}" '
    .data.kubernetes_host == $host and
    .data.disable_local_ca_jwt == true and
    .data.disable_iss_validation == true and
    .data.token_reviewer_jwt_set == false
  ' >/dev/null 2>&1; then
  echo "ERROR: auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config does not have the expected client-JWT-self-review fields." >&2
  printf '%s\n' "$MOUNT_CONFIG" | jq 'del(.data.kubernetes_ca_cert, .data.pem_keys)' >&2
  exit 1
fi
echo "OK: kubernetes_host matches, disable_local_ca_jwt=true, disable_iss_validation=true, token_reviewer_jwt_set=false."
unset MOUNT_CONFIG

# --- Create the sole scenario-owned Vault policy --------------------------

echo "==> Checking Vault policy '${AUTH_DELEGATOR_POLICY}'..."
EXPECTED_POLICY_HCL="$(auth_delegator_policy_hcl)"
EXISTING_POLICY_HCL=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault policy read "${AUTH_DELEGATOR_POLICY}" 2>/dev/null || true)
if [ -n "$EXISTING_POLICY_HCL" ]; then
  if [ "$(printf '%s' "$EXISTING_POLICY_HCL" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')" \
      != "$(printf '%s' "$EXPECTED_POLICY_HCL" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')" ]; then
    echo "ERROR: policy '${AUTH_DELEGATOR_POLICY}' already exists but its rules do not exactly match this scenario's expected policy." >&2
    echo "       Refusing to overwrite a policy this scenario does not own." >&2
    exit 1
  fi
  echo "    policy '${AUTH_DELEGATOR_POLICY}' already exists and matches exactly. Re-applying (idempotent)."
fi
unset EXISTING_POLICY_HCL

printf '%s' "$EXPECTED_POLICY_HCL" | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault policy write "${AUTH_DELEGATOR_POLICY}" -
unset EXPECTED_POLICY_HCL

# --- Write the exact-bound role --------------------------------------------
#
# Bound exactly to the self-review ServiceAccount, the consumer (app)
# namespace, and the `vault` audience. No default policy; non-renewable
# batch tokens; ${AUTH_DELEGATOR_TOKEN_TTL} TTL.

echo "==> Writing auth/${AUTH_DELEGATOR_AUTH_MOUNT}/role/${AUTH_DELEGATOR_ROLE}..."
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault write "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/role/${AUTH_DELEGATOR_ROLE}" \
  bound_service_account_names="${AUTH_DELEGATOR_SELF_REVIEW_SA}" \
  bound_service_account_namespaces="${AUTH_DELEGATOR_APP_NAMESPACE}" \
  audience="${AUTH_DELEGATOR_VAULT_AUDIENCE}" \
  policies="${AUTH_DELEGATOR_POLICY}" \
  token_no_default_policy=true \
  token_type=batch \
  ttl="${AUTH_DELEGATOR_TOKEN_TTL}"

# --- Regression check: this script must never disturb the coexisting -----
# --- default JWT/OIDC scenario --------------------------------------------

JWT_OIDC_SNAPSHOT_AFTER=$(capture_jwt_oidc_baseline_snapshot "$VAULT_POD")
if [ "$JWT_OIDC_SNAPSHOT_BEFORE" != "$JWT_OIDC_SNAPSHOT_AFTER" ]; then
  echo "ERROR: auth/${VSO_JWT_AUTH_MOUNT} (the default JWT/OIDC scenario) changed while configuring auth/${AUTH_DELEGATOR_AUTH_MOUNT}." >&2
  echo "       This script must never disturb the coexisting default scenario; investigate before re-running." >&2
  exit 1
fi
echo "OK: the coexisting default JWT/OIDC scenario (auth/${VSO_JWT_AUTH_MOUNT}) is unchanged."
unset JWT_OIDC_SNAPSHOT_BEFORE JWT_OIDC_SNAPSHOT_AFTER

# --- Print only sanitized configuration and pass/fail statements ---------

echo ""
echo "==> Verifying configuration (no secrets/JWTs/CA material printed)..."
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault auth list
echo ""
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read -format=json "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config" \
  | jq 'del(.data.kubernetes_ca_cert, .data.pem_keys)'
echo ""
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/role/${AUTH_DELEGATOR_ROLE}"

echo ""
echo "auth/${AUTH_DELEGATOR_AUTH_MOUNT} is configured in context '${VAULT_CONTEXT}' for client JWT self-review:"
echo "  kubernetes_host:          ${VSO_API_ADDR}"
echo "  disable_local_ca_jwt:     true"
echo "  disable_iss_validation:   true"
echo "  token_reviewer_jwt_set:   false (no reviewer identity -- the client's own JWT is the TokenReview bearer)"
echo "  role:                     ${AUTH_DELEGATOR_ROLE} (SA: ${AUTH_DELEGATOR_SELF_REVIEW_SA}, namespace: ${AUTH_DELEGATOR_APP_NAMESPACE}, audience: ${AUTH_DELEGATOR_VAULT_AUDIENCE})"
echo "  policy:                   ${AUTH_DELEGATOR_POLICY} (default policy suppressed, batch tokens, ttl=${AUTH_DELEGATOR_TOKEN_TTL})"
echo ""
echo "auth/kubernetes, auth/${VSO_JWT_AUTH_MOUNT}, and auth/${VSO_AUTH_MOUNT} were not touched."
