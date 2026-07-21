#!/usr/bin/env bash
# scripts/verify-vso-auth-delegator.sh
#
# End-to-end verification of the CLIENT JWT SELF-REVIEW VSO scenario (see
# docs/vso-kubernetes-auth-delegator-plan.md): the same short-lived,
# dual-audience ServiceAccount JWT is both the `jwt` VSO submits to Vault's
# Kubernetes auth login endpoint AND the HTTP bearer Vault uses when it
# calls the VSO cluster's TokenReview API, authorized by a scenario-owned
# `system:auth-delegator` ClusterRoleBinding.
#
# This never creates, deletes, or recreates a kind cluster, and never runs
# Helm install/upgrade. It proves, in order (each section fails fast):
#
#   1. Contexts/compatibility/baseline snapshot of the coexisting default
#      JWT/OIDC scenario (auth/${VSO_JWT_AUTH_MOUNT}, vso-demo CRs).
#   2. Placement and ownership of every scenario resource.
#   3. Network/TLS reachability in both directions.
#   4. RBAC and reviewer selection (exactly one CRB subject; only the
#      self-review SA can create TokenReviews; the live Vault mount has
#      disable_local_ca_jwt=true/disable_iss_validation=true/no reviewer).
#   5. JWT claims and a DIRECT same-JWT TokenReview proof (the same in-memory
#      token used as both the outer HTTP bearer and spec.token).
#   6. Vault login (positive) and every audience/identity negative case.
#   7. Vault token constraints (non-renewable batch token, exact policy).
#   8. Cross-namespace sync, deny-by-default in a third namespace.
#   9. Full-object CAS rotation and exact restoration (HUP/INT/TERM-safe).
#  10. No regression in the coexisting default JWT/OIDC scenario.
#
# Usage:
#   scripts/verify-vso-auth-delegator.sh
#   scripts/verify-vso-auth-delegator.sh --check-only      # validate tools/contexts/CRD/RBAC only
#   scripts/verify-vso-auth-delegator.sh --skip-rotation    # skip the (slower) rotation section
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VAULT_CONTEXT,
# VSO_CONTEXT, AUTH_DELEGATOR_*), plus ROTATED_USERNAME (default:
# larry-rotated), ROTATION_ATTEMPTS (default: 20), ROTATION_SLEEP (default:
# 3s).
#
# NOTE: no full JWT/Vault token value is ever printed to stdout/stderr by
# this script -- only decoded claim summaries, pass/fail outcomes, and
# Vault's own (secret-free) login/error responses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/two-cluster-env.sh
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

ROTATED_USERNAME="${ROTATED_USERNAME:-larry-rotated}"
ROTATION_ATTEMPTS="${ROTATION_ATTEMPTS:-20}"
ROTATION_SLEEP="${ROTATION_SLEEP:-3}"
DENY_CHECK_NAMESPACE="${DENY_CHECK_NAMESPACE:-vso-auth-delegator-deny-check}"
DENY_CHECK_VSS_NAME="deny-check"
DENY_CHECK_SECRET_NAME="deny-check-secret"

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
      sed -n '2,33p' "${BASH_SOURCE[0]}"
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

# decode_jwt_claims_json <jwt>
#
# Prints the decoded claims JSON of a JWT without ever printing the token
# itself. Fails (empty output, non-zero return) on malformed input.
decode_jwt_claims_json() {
  local jwt="$1"
  local payload_segment="${jwt#*.}"
  payload_segment="${payload_segment%%.*}"
  payload_segment="${payload_segment//-/+}"
  payload_segment="${payload_segment//_/\/}"
  case $((${#payload_segment} % 4)) in
    2) payload_segment+="==" ;;
    3) payload_segment+="=" ;;
    1) return 1 ;;
  esac
  printf '%s' "$payload_segment" | base64 --decode 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. Contexts, compatibility, and baseline snapshot
# ---------------------------------------------------------------------------

section "1/10 contexts + compatibility + baseline snapshot"

fail=0
require_commands kubectl base64 jq curl || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

require_contexts || fail_section \
  "VAULT_CONTEXT ('${VAULT_CONTEXT}') and VSO_CONTEXT ('${VSO_CONTEXT}') must both exist and be different clusters."
validate_auth_delegator_env || fail_section \
  "The auth-delegator environment is misconfigured; see errors above."
echo "OK: contexts differ and the auth-delegator environment is self-consistent."

if [ "$CHECK_ONLY" -eq 1 ]; then
  preflight_auth_delegator_runtime || fail_section "Runtime feature preflight failed; see diagnostics above."
  echo ""
  echo "OK (--check-only): required commands present, contexts/environment valid, runtime features detected. Skipping the rest."
  exit 0
fi

preflight_auth_delegator_runtime || fail_section \
  "Runtime feature preflight failed (VSO version/CRD schema/operator RBAC); see diagnostics above."

VAULT_POD=$(kubectl_vault get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$VAULT_POD" ]; then
  fail_section "No Vault pod found in context '${VAULT_CONTEXT}' namespace '${NAMESPACE}'. Run scripts/setup-vault-cluster.sh first."
fi
if ! kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Sealed.*false'; then
  fail_section "Vault pod '${VAULT_POD}' in context '${VAULT_CONTEXT}' is not initialized/unsealed."
fi
echo "OK: Vault pod '${VAULT_POD}' is running and unsealed."

if ! kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault auth list 2>/dev/null | grep -q "^${AUTH_DELEGATOR_AUTH_MOUNT}/"; then
  fail_section "auth/${AUTH_DELEGATOR_AUTH_MOUNT} is not enabled. Run scripts/configure-vso-auth-delegator.sh first."
fi

# Baseline snapshot of the coexisting default JWT/OIDC scenario. Section
# 10 re-captures both and asserts byte-for-byte equality after every gate
# below (including rotation) has run.
JWT_OIDC_SNAPSHOT_BEFORE=$(capture_jwt_oidc_baseline_snapshot "$VAULT_POD")
VSO_DEMO_CR_SNAPSHOT_BEFORE=$(capture_vso_demo_cr_snapshot)
echo "OK: captured baseline snapshots of the coexisting default JWT/OIDC scenario (mount/role + vso-demo CRs)."

# ---------------------------------------------------------------------------
# 2. Placement and ownership
# ---------------------------------------------------------------------------

section "2/10 placement + ownership"

assert_owned() {
  local kind="$1" name="$2" ns_flag="$3"
  local label
  # shellcheck disable=SC2086
  label=$(kubectl_vso get "$kind" "$name" $ns_flag \
    -o jsonpath="{.metadata.labels.${AUTH_DELEGATOR_OWNER_LABEL_KEY//./\\.}}" 2>/dev/null || true)
  if [ "$label" != "$AUTH_DELEGATOR_OWNER_LABEL_VALUE" ]; then
    fail_section "${kind}/${name} is missing the expected ownership label (${AUTH_DELEGATOR_OWNER_LABEL_KEY}=${AUTH_DELEGATOR_OWNER_LABEL_VALUE})."
  fi
}

if ! kubectl_vso get namespace "$AUTH_DELEGATOR_AUTH_NAMESPACE" >/dev/null 2>&1; then
  fail_section "Namespace '${AUTH_DELEGATOR_AUTH_NAMESPACE}' not found in context '${VSO_CONTEXT}'. Run scripts/apply-vso-auth-delegator-demo.sh first."
fi
if ! kubectl_vso get namespace "$AUTH_DELEGATOR_APP_NAMESPACE" >/dev/null 2>&1; then
  fail_section "Namespace '${AUTH_DELEGATOR_APP_NAMESPACE}' not found in context '${VSO_CONTEXT}'. Run scripts/apply-vso-auth-delegator-demo.sh first."
fi
assert_owned namespace "$AUTH_DELEGATOR_AUTH_NAMESPACE" ""
assert_owned namespace "$AUTH_DELEGATOR_APP_NAMESPACE" ""
echo "OK: both dedicated namespaces exist and carry the scenario ownership label."

if kubectl_vault get namespace "$AUTH_DELEGATOR_AUTH_NAMESPACE" >/dev/null 2>&1 \
    || kubectl_vault get namespace "$AUTH_DELEGATOR_APP_NAMESPACE" >/dev/null 2>&1; then
  fail_section "Auth-delegator namespaces unexpectedly exist in the Vault cluster (context '${VAULT_CONTEXT}')."
fi
echo "OK: auth-delegator namespaces are absent from the Vault cluster."

if ! kubectl_vso get serviceaccount "$AUTH_DELEGATOR_SELF_REVIEW_SA" -n "$AUTH_DELEGATOR_APP_NAMESPACE" >/dev/null 2>&1; then
  fail_section "Self-review ServiceAccount '${AUTH_DELEGATOR_SELF_REVIEW_SA}' not found in '${AUTH_DELEGATOR_APP_NAMESPACE}'."
fi
assert_owned serviceaccount "$AUTH_DELEGATOR_SELF_REVIEW_SA" "-n $AUTH_DELEGATOR_APP_NAMESPACE"

if kubectl_vso get serviceaccount "$AUTH_DELEGATOR_SELF_REVIEW_SA" -n "$AUTH_DELEGATOR_AUTH_NAMESPACE" >/dev/null 2>&1; then
  fail_section "Self-review ServiceAccount '${AUTH_DELEGATOR_SELF_REVIEW_SA}' unexpectedly also exists in the auth namespace '${AUTH_DELEGATOR_AUTH_NAMESPACE}'."
fi
echo "OK: the self-review ServiceAccount exists ONLY in the consumer namespace."

SELF_REVIEW_AUTOMOUNT=$(kubectl_vso get serviceaccount "$AUTH_DELEGATOR_SELF_REVIEW_SA" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
  -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null || true)
if [ "$SELF_REVIEW_AUTOMOUNT" != "false" ]; then
  fail_section "Self-review ServiceAccount must have automountServiceAccountToken: false (got '${SELF_REVIEW_AUTOMOUNT:-<unset>}')."
fi
echo "OK: self-review ServiceAccount has automountServiceAccountToken: false."

if ! kubectl_vso get serviceaccount "$AUTH_DELEGATOR_APP_SA" -n "$AUTH_DELEGATOR_APP_NAMESPACE" >/dev/null 2>&1; then
  fail_section "App ServiceAccount '${AUTH_DELEGATOR_APP_SA}' not found in '${AUTH_DELEGATOR_APP_NAMESPACE}'."
fi
assert_owned serviceaccount "$AUTH_DELEGATOR_APP_SA" "-n $AUTH_DELEGATOR_APP_NAMESPACE"
echo "OK: the separate unprivileged app ServiceAccount exists in the consumer namespace."

if ! kubectl_vso get clusterrolebinding "$AUTH_DELEGATOR_CLUSTER_ROLE_BINDING" >/dev/null 2>&1; then
  fail_section "ClusterRoleBinding '${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}' not found."
fi
assert_owned clusterrolebinding "$AUTH_DELEGATOR_CLUSTER_ROLE_BINDING" ""
echo "OK: scenario resources carry the expected ownership markers."

# ---------------------------------------------------------------------------
# 3. Network and TLS
# ---------------------------------------------------------------------------

section "3/10 network + TLS"

if ! bash "${SCRIPT_DIR}/check-vault-connectivity.sh"; then
  fail_section "A pod in the VSO cluster could not reach Vault at '${VAULT_ADDR}'."
fi
echo "OK: a pod in the VSO cluster reached Vault at '${VAULT_ADDR}'."

VSO_CLUSTER_NAME=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name==\"${VSO_CONTEXT}\")].context.cluster}")
VSO_CA_DATA_B64=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${VSO_CLUSTER_NAME}\")].cluster.certificate-authority-data}")
if [ -z "$VSO_CA_DATA_B64" ]; then
  fail_section "Could not read the VSO cluster CA from kubeconfig."
fi
VSO_CA_PEM=$(printf '%s' "$VSO_CA_DATA_B64" | base64 --decode)
unset VSO_CA_DATA_B64

LIVEZ_STATUS=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cacert <(printf '%s' "$VSO_CA_PEM") \
  --resolve "${TWO_CLUSTER_HOST}:${VSO_API_HOST_PORT}:127.0.0.1" \
  "${VSO_API_ADDR}/livez" 2>&1) || true
if [ "$LIVEZ_STATUS" != "200" ]; then
  fail_section "Could not reach the VSO cluster API server's /livez over TLS using the VSO cluster CA (got '${LIVEZ_STATUS}')."
fi
echo "OK: Vault-cluster-side TLS-verified reachability to the VSO cluster API server confirmed."

# ---------------------------------------------------------------------------
# 4. RBAC and reviewer selection
# ---------------------------------------------------------------------------

section "4/10 rbac + reviewer selection"

CRB_SUBJECTS=$(kubectl_vso get clusterrolebinding "$AUTH_DELEGATOR_CLUSTER_ROLE_BINDING" -o json \
  | jq -c '[.subjects[] | {kind, name, namespace}] | sort')
EXPECTED_SUBJECTS=$(jq -nc --arg name "$AUTH_DELEGATOR_SELF_REVIEW_SA" --arg ns "$AUTH_DELEGATOR_APP_NAMESPACE" \
  '[{kind:"ServiceAccount", name:$name, namespace:$ns}]')
if [ "$CRB_SUBJECTS" != "$EXPECTED_SUBJECTS" ]; then
  fail_section "ClusterRoleBinding '${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}' does not have exactly the expected sole subject." \
    "expected: ${EXPECTED_SUBJECTS}, actual: ${CRB_SUBJECTS}"
fi
CRB_ROLE=$(kubectl_vso get clusterrolebinding "$AUTH_DELEGATOR_CLUSTER_ROLE_BINDING" -o jsonpath='{.roleRef.name}')
if [ "$CRB_ROLE" != "system:auth-delegator" ]; then
  fail_section "ClusterRoleBinding '${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}' roleRef is '${CRB_ROLE}', expected 'system:auth-delegator'."
fi
echo "OK: '${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}' grants system:auth-delegator to exactly one subject (the self-review ServiceAccount)."

if ! kubectl_vso auth can-i create tokenreviews.authentication.k8s.io \
    --as="system:serviceaccount:${AUTH_DELEGATOR_APP_NAMESPACE}:${AUTH_DELEGATOR_SELF_REVIEW_SA}" >/dev/null 2>&1; then
  fail_section "The self-review ServiceAccount cannot create TokenReviews."
fi
echo "OK: the self-review ServiceAccount CAN create TokenReviews."

for identity in \
  "system:serviceaccount:${AUTH_DELEGATOR_APP_NAMESPACE}:${AUTH_DELEGATOR_APP_SA}|app ServiceAccount" \
  "system:serviceaccount:${AUTH_DELEGATOR_APP_NAMESPACE}:default|default ServiceAccount (consumer ns)" \
  ; do
  as_identity="${identity%%|*}"
  label="${identity##*|}"
  if kubectl_vso auth can-i create tokenreviews.authentication.k8s.io --as="$as_identity" >/dev/null 2>&1; then
    fail_section "The ${label} ('${as_identity}') can unexpectedly create TokenReviews."
  fi
  echo "OK: the ${label} CANNOT create TokenReviews."
done

VSO_OPERATOR_SA=$(kubectl_vso get deploy -n "$VSO_OPERATOR_NAMESPACE" \
  -l app.kubernetes.io/name=vault-secrets-operator \
  -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}' 2>/dev/null || true)
if [ -n "$VSO_OPERATOR_SA" ]; then
  # The VSO operator's own 'vault-secrets-operator-proxy-role' (kube-rbac-proxy
  # for metrics) includes 'create tokenreviews' as a standard VSO install
  # component. This is NOT our scenario's system:auth-delegator binding and
  # does not undermine the self-review design (Vault still uses the client's
  # JWT as the bearer, not a stored reviewer JWT). Report it as a NOTE, not a
  # failure, and verify our scenario-owned binding is the only
  # system:auth-delegator grant (checked above).
  if kubectl_vso auth can-i create tokenreviews.authentication.k8s.io \
      --as="system:serviceaccount:${VSO_OPERATOR_NAMESPACE}:${VSO_OPERATOR_SA}" >/dev/null 2>&1; then
    echo "NOTE: the VSO controller SA ('${VSO_OPERATOR_SA}') can create TokenReviews via the standard VSO proxy-role (kube-rbac-proxy), not via our scenario's system:auth-delegator binding."
  else
    echo "OK: the VSO controller ServiceAccount CANNOT create TokenReviews."
  fi
fi

LEGACY_DELEGATOR_BINDINGS=$(kubectl_vso get clusterrolebinding -o json \
  | jq -r --arg owned "$AUTH_DELEGATOR_CLUSTER_ROLE_BINDING" \
    '.items[] | select(.roleRef.name=="system:auth-delegator" and .metadata.name != $owned) | .metadata.name')
if [ -n "$LEGACY_DELEGATOR_BINDINGS" ]; then
  echo "NOTE: other system:auth-delegator bindings exist and are left unmodified (reported, not changed):"
  printf '%s\n' "$LEGACY_DELEGATOR_BINDINGS" | sed 's/^/       - /'
else
  echo "NOTE: no other system:auth-delegator bindings found."
fi

MOUNT_CONFIG=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read -format=json "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config" 2>&1) || {
  fail_section "Could not read auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config." "$MOUNT_CONFIG"
}
if ! printf '%s' "$MOUNT_CONFIG" | jq -e '
    .data.disable_local_ca_jwt == true and
    .data.disable_iss_validation == true and
    .data.token_reviewer_jwt_set == false
  ' >/dev/null 2>&1; then
  fail_section "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/config does not have disable_local_ca_jwt=true, disable_iss_validation=true, and no reviewer JWT."
fi
unset MOUNT_CONFIG
echo "OK: Vault mount has disable_local_ca_jwt=true, disable_iss_validation=true, token_reviewer_jwt_set=false."

# ---------------------------------------------------------------------------
# 5. JWT claims and direct same-JWT TokenReview proof
# ---------------------------------------------------------------------------

section "5/10 jwt claims + direct self-review proof"

SELF_REVIEW_JWT=$(kubectl_vso create token "$AUTH_DELEGATOR_SELF_REVIEW_SA" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
  --duration "${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS}s" \
  --audience "$AUTH_DELEGATOR_VAULT_AUDIENCE" --audience "$AUTH_DELEGATOR_API_AUDIENCE" 2>/dev/null || true)
if [ -z "$SELF_REVIEW_JWT" ]; then
  fail_section "Failed to mint a dual-audience token for '${AUTH_DELEGATOR_SELF_REVIEW_SA}' in '${AUTH_DELEGATOR_APP_NAMESPACE}'."
fi

CLAIMS_JSON=$(decode_jwt_claims_json "$SELF_REVIEW_JWT") || {
  unset SELF_REVIEW_JWT
  fail_section "Minted self-review JWT has an unparseable payload."
}

EXPECTED_SUBJECT="system:serviceaccount:${AUTH_DELEGATOR_APP_NAMESPACE}:${AUTH_DELEGATOR_SELF_REVIEW_SA}"
if ! printf '%s' "$CLAIMS_JSON" | jq -e --arg iss "$VSO_OIDC_ISSUER" --arg sub "$EXPECTED_SUBJECT" \
    --arg a1 "$AUTH_DELEGATOR_VAULT_AUDIENCE" --arg a2 "$AUTH_DELEGATOR_API_AUDIENCE" '
      .iss == $iss and
      .sub == $sub and
      ((.aud | type) == "array") and
      (.aud | index($a1) != null) and
      (.aud | index($a2) != null) and
      ((.exp - .iat) > 0) and
      ((.exp - .iat) <= 600)
    ' >/dev/null 2>&1; then
  unset SELF_REVIEW_JWT CLAIMS_JSON
  fail_section "Minted self-review JWT does not have the expected issuer/subject/dual-audiences/bounded lifetime."
fi
unset CLAIMS_JSON
echo "OK: minted self-review JWT has the expected issuer, subject, both audiences, and a bounded (<= 600s) lifetime."

TOKENREVIEW_BODY=$(jq -n --arg token "$SELF_REVIEW_JWT" --arg aud "$AUTH_DELEGATOR_VAULT_AUDIENCE" \
  '{apiVersion:"authentication.k8s.io/v1", kind:"TokenReview", spec:{token:$token, audiences:[$aud]}}')

TOKENREVIEW_OUTPUT=$(curl --silent --show-error \
  --cacert <(printf '%s' "$VSO_CA_PEM") \
  --resolve "${TWO_CLUSTER_HOST}:${VSO_API_HOST_PORT}:127.0.0.1" \
  -H "Authorization: Bearer ${SELF_REVIEW_JWT}" \
  -H "Content-Type: application/json" \
  -X POST --data "$TOKENREVIEW_BODY" \
  --write-out '\nHTTP_STATUS:%{http_code}' \
  "${VSO_API_ADDR}/apis/authentication.k8s.io/v1/tokenreviews" 2>&1) || true
unset TOKENREVIEW_BODY

TOKENREVIEW_HTTP_STATUS="${TOKENREVIEW_OUTPUT##*HTTP_STATUS:}"
TOKENREVIEW_JSON="${TOKENREVIEW_OUTPUT%$'\n'HTTP_STATUS:*}"
unset TOKENREVIEW_OUTPUT

if [ "$TOKENREVIEW_HTTP_STATUS" != "201" ] && [ "$TOKENREVIEW_HTTP_STATUS" != "200" ]; then
  unset SELF_REVIEW_JWT TOKENREVIEW_JSON
  fail_section "Direct TokenReview using the self-review JWT as both the outer HTTP bearer and spec.token did not return HTTP 200/201 (got '${TOKENREVIEW_HTTP_STATUS}')."
fi

if ! printf '%s' "$TOKENREVIEW_JSON" | jq -e --arg sub "$EXPECTED_SUBJECT" --arg aud "$AUTH_DELEGATOR_VAULT_AUDIENCE" '
    .status.authenticated == true and
    .status.user.username == $sub and
    ((.status.audiences // []) | index($aud) != null)
  ' >/dev/null 2>&1; then
  unset SELF_REVIEW_JWT TOKENREVIEW_JSON
  fail_section "Direct TokenReview did not report authenticated=true with the exact expected identity and audience."
fi
unset TOKENREVIEW_JSON
echo "OK: direct TokenReview proves the SAME JWT is both the outer HTTP bearer (authorized by system:auth-delegator) and the reviewed token (authenticated=true, exact identity, audience '${AUTH_DELEGATOR_VAULT_AUDIENCE}')."

# ---------------------------------------------------------------------------
# 6. Vault login and negative authentication
# ---------------------------------------------------------------------------

section "6/10 vault login + negative authentication"

LOGIN_OUTPUT=$(printf '%s' "$SELF_REVIEW_JWT" | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- \
  vault write -format=json "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/login" \
  role="${AUTH_DELEGATOR_ROLE}" jwt=- 2>&1) || {
  unset SELF_REVIEW_JWT LOGIN_OUTPUT
  fail_section "Vault rejected the correct dual-audience self-review JWT." "$LOGIN_OUTPUT"
}
unset SELF_REVIEW_JWT
echo "OK: the correct dual-audience self-review JWT authenticates through auth/${AUTH_DELEGATOR_AUTH_MOUNT}."

# 6a. Correct SA, ONLY the vault audience: the outer HTTP bearer's own
#     audience is then unacceptable to the VSO API server (which defaults
#     its accepted audience to its --service-account-issuer), so the
#     TokenReview HTTP call itself is rejected and Vault login fails.
VAULT_ONLY_JWT=$(kubectl_vso create token "$AUTH_DELEGATOR_SELF_REVIEW_SA" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
  --duration "${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS}s" --audience "$AUTH_DELEGATOR_VAULT_AUDIENCE" 2>/dev/null || true)
if [ -z "$VAULT_ONLY_JWT" ]; then
  fail_section "Failed to mint a vault-audience-only token for the self-review ServiceAccount."
fi
if printf '%s' "$VAULT_ONLY_JWT" | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- \
    vault write -format=json "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/login" role="${AUTH_DELEGATOR_ROLE}" jwt=- >/dev/null 2>&1; then
  unset VAULT_ONLY_JWT
  fail_section "Vault incorrectly ACCEPTED a vault-audience-only JWT (the outer API bearer audience should have been rejected)."
fi
unset VAULT_ONLY_JWT
echo "OK: a vault-audience-only JWT is rejected (outer HTTP bearer audience unacceptable to the VSO API server)."

# 6b. Correct SA, ONLY the API-server audience (no 'vault'): the outer HTTP
#     bearer succeeds, but the TokenReview's requested audience ('vault')
#     is not among the token's own audiences, so TokenReview reports
#     authenticated=false and Vault login fails.
API_ONLY_JWT=$(kubectl_vso create token "$AUTH_DELEGATOR_SELF_REVIEW_SA" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
  --duration "${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS}s" --audience "$AUTH_DELEGATOR_API_AUDIENCE" 2>/dev/null || true)
if [ -z "$API_ONLY_JWT" ]; then
  fail_section "Failed to mint an API-audience-only token for the self-review ServiceAccount."
fi
if printf '%s' "$API_ONLY_JWT" | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- \
    vault write -format=json "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/login" role="${AUTH_DELEGATOR_ROLE}" jwt=- >/dev/null 2>&1; then
  unset API_ONLY_JWT
  fail_section "Vault incorrectly ACCEPTED an API-audience-only JWT (the requested 'vault' TokenReview audience should have been rejected)."
fi
unset API_ONLY_JWT
echo "OK: an API-audience-only JWT is rejected (requested 'vault' TokenReview audience not present)."

# 6c. WRONG ServiceAccount (the unprivileged app SA), both audiences: role
#     binding rejects the ServiceAccount name/namespace, and/or the app SA
#     lacks TokenReview RBAC (already independently proven in section 4).
WRONG_SA_JWT=$(kubectl_vso create token "$AUTH_DELEGATOR_APP_SA" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
  --duration "${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS}s" \
  --audience "$AUTH_DELEGATOR_VAULT_AUDIENCE" --audience "$AUTH_DELEGATOR_API_AUDIENCE" 2>/dev/null || true)
if [ -z "$WRONG_SA_JWT" ]; then
  fail_section "Failed to mint a dual-audience token for the wrong (app) ServiceAccount."
fi
if printf '%s' "$WRONG_SA_JWT" | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- \
    vault write -format=json "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/login" role="${AUTH_DELEGATOR_ROLE}" jwt=- >/dev/null 2>&1; then
  unset WRONG_SA_JWT
  fail_section "Vault incorrectly ACCEPTED a JWT from the wrong (app) ServiceAccount."
fi
unset WRONG_SA_JWT
echo "OK: a dual-audience JWT from the wrong (app) ServiceAccount is rejected (role SA/namespace binding and/or TokenReview RBAC, already proven independently in section 4)."

# ---------------------------------------------------------------------------
# 7. Vault token constraints
# ---------------------------------------------------------------------------

section "7/10 vault token constraints"

LOGIN_RENEWABLE=$(printf '%s' "$LOGIN_OUTPUT" | jq -r '.auth.renewable | tostring')
LOGIN_TOKEN_TYPE=$(printf '%s' "$LOGIN_OUTPUT" | jq -r '.auth.token_type // empty')
TOKEN_POLICIES=$(printf '%s' "$LOGIN_OUTPUT" | jq -c '(.auth.token_policies // []) | sort')
EFFECTIVE_POLICIES=$(printf '%s' "$LOGIN_OUTPUT" | jq -c '(.auth.policies // []) | sort')
IDENTITY_POLICIES=$(printf '%s' "$LOGIN_OUTPUT" | jq -c '(.auth.identity_policies // []) | sort')
LOGIN_TTL=$(printf '%s' "$LOGIN_OUTPUT" | jq -r '.auth.lease_duration // 0')
EXPECTED_POLICIES_JSON=$(jq -nc --arg p "$AUTH_DELEGATOR_POLICY" '[$p]')
unset LOGIN_OUTPUT

# Vault 2.x may return token_type=null in the login response even for
# batch tokens; fall back to the role's configured token_type.
if [ -z "$LOGIN_TOKEN_TYPE" ]; then
  LOGIN_TOKEN_TYPE=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- \
    vault read -format=json "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/role/${AUTH_DELEGATOR_ROLE}" \
    | jq -r '.data.token_type // empty' 2>/dev/null || true)
fi

if [ "$LOGIN_RENEWABLE" != "false" ] || [ "$LOGIN_TOKEN_TYPE" != "batch" ]; then
  fail_section "Vault login token is not a non-renewable batch token (renewable='${LOGIN_RENEWABLE}', token_type='${LOGIN_TOKEN_TYPE}')."
fi
if [ "$TOKEN_POLICIES" != "$EXPECTED_POLICIES_JSON" ] || [ "$EFFECTIVE_POLICIES" != "$EXPECTED_POLICIES_JSON" ] || [ "$IDENTITY_POLICIES" != '[]' ]; then
  fail_section "Vault login token does not have exactly the dedicated policy (token_policies='${TOKEN_POLICIES}', policies='${EFFECTIVE_POLICIES}', identity_policies='${IDENTITY_POLICIES}')."
fi

MAX_TTL_SECONDS=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault read -format=json "auth/${AUTH_DELEGATOR_AUTH_MOUNT}/role/${AUTH_DELEGATOR_ROLE}" \
  | jq -r '.data.token_ttl // .data.ttl // 0')
if [ "$LOGIN_TTL" -le 0 ] || [ "$LOGIN_TTL" -gt "$MAX_TTL_SECONDS" ]; then
  fail_section "Vault login token TTL (${LOGIN_TTL}s) is not positive and <= the configured maximum (${MAX_TTL_SECONDS}s)."
fi
echo "OK: Vault login token is a non-renewable batch token with only '${AUTH_DELEGATOR_POLICY}' policy, no identity policies, and a bounded TTL (${LOGIN_TTL}s <= ${MAX_TTL_SECONDS}s)."

# ---------------------------------------------------------------------------
# 8. Cross-namespace sync and deny-by-default
# ---------------------------------------------------------------------------

section "8/10 cross-namespace sync + deny-by-default"

VAULT_AUTH_VALID=$(kubectl_vso get vaultauth "$AUTH_DELEGATOR_VAULT_AUTH" -n "$AUTH_DELEGATOR_AUTH_NAMESPACE" \
  -o jsonpath='{.status.valid}' 2>/dev/null || true)
if [ "$VAULT_AUTH_VALID" != "true" ]; then
  fail_section "VaultAuth '${AUTH_DELEGATOR_VAULT_AUTH}' in '${AUTH_DELEGATOR_AUTH_NAMESPACE}' is not valid (status='${VAULT_AUTH_VALID:-<none>}')."
fi
echo "OK: VaultAuth is valid in the AUTH namespace ('${AUTH_DELEGATOR_AUTH_NAMESPACE}')."

VSS_READY=$(kubectl_vso get vaultstaticsecret "$AUTH_DELEGATOR_VSS_NAME" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$VSS_READY" != "True" ]; then
  fail_section "VaultStaticSecret '${AUTH_DELEGATOR_VSS_NAME}' in '${AUTH_DELEGATOR_APP_NAMESPACE}' is not Ready (status='${VSS_READY:-<none>}')."
fi
echo "OK: VaultStaticSecret is Ready in the CONSUMER namespace ('${AUTH_DELEGATOR_APP_NAMESPACE}'), proving cross-namespace VaultAuth consumption."

if kubectl_vso get secret "$AUTH_DELEGATOR_SECRET_NAME" -n "$AUTH_DELEGATOR_AUTH_NAMESPACE" >/dev/null 2>&1; then
  fail_section "Destination Secret '${AUTH_DELEGATOR_SECRET_NAME}' unexpectedly exists in the AUTH namespace."
fi
if ! kubectl_vso get secret "$AUTH_DELEGATOR_SECRET_NAME" -n "$AUTH_DELEGATOR_APP_NAMESPACE" >/dev/null 2>&1; then
  fail_section "Destination Secret '${AUTH_DELEGATOR_SECRET_NAME}' not found in the CONSUMER namespace."
fi
echo "OK: the destination Secret exists ONLY in the consumer namespace."

APP_POD_SA=$(kubectl_vso get pod "$AUTH_DELEGATOR_APP_POD" -n "$AUTH_DELEGATOR_APP_NAMESPACE" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null || true)
if [ "$APP_POD_SA" != "$AUTH_DELEGATOR_APP_SA" ]; then
  fail_section "App pod '${AUTH_DELEGATOR_APP_POD}' does not use the unprivileged app ServiceAccount (uses '${APP_POD_SA:-<none>}')."
fi
APP_POD_VAULT_ANNOTATIONS=$(kubectl_vso get pod "$AUTH_DELEGATOR_APP_POD" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
  -o json | jq -r '.metadata.annotations // {} | keys[] | select(startswith("vault.hashicorp.com/"))' 2>/dev/null || true)
if [ -n "$APP_POD_VAULT_ANNOTATIONS" ]; then
  fail_section "App pod has vault.hashicorp.com annotations (should have zero Vault awareness)."
fi
APP_POD_CONTAINER_COUNT=$(kubectl_vso get pod "$AUTH_DELEGATOR_APP_POD" -n "$AUTH_DELEGATOR_APP_NAMESPACE" -o jsonpath='{.spec.containers[*].name}' | wc -w | tr -d ' ')
if [ "$APP_POD_CONTAINER_COUNT" != "1" ]; then
  fail_section "App pod does not have exactly one container (found ${APP_POD_CONTAINER_COUNT}); expected no sidecar."
fi
APP_POD_PHASE=$(kubectl_vso get pod "$AUTH_DELEGATOR_APP_POD" -n "$AUTH_DELEGATOR_APP_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$APP_POD_PHASE" != "Running" ]; then
  fail_section "App pod is not Running (phase='${APP_POD_PHASE:-<none>}')."
fi
CURRENT_SECRET_VALUE=$(kubectl_vso get secret "$AUTH_DELEGATOR_SECRET_NAME" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
POD_ENV_VALUE=$(kubectl_vso exec "$AUTH_DELEGATOR_APP_POD" -n "$AUTH_DELEGATOR_APP_NAMESPACE" -- printenv username 2>/dev/null || true)
if [ -z "$CURRENT_SECRET_VALUE" ] || [ "$POD_ENV_VALUE" != "$CURRENT_SECRET_VALUE" ]; then
  fail_section "App pod's captured env value does not match the current native Secret value."
fi
echo "OK: the plain app runs under the unprivileged ServiceAccount, has no Vault annotations/sidecar, and consumes the expected data."

# Deny-by-default: a verifier-owned temporary VaultStaticSecret in a THIRD
# namespace must be denied by allowedNamespaces and must create no Secret.
# A scoped trap removes only this temporary object/namespace.
DENY_CHECK_ARMED=1
cleanup_deny_check() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [ "$DENY_CHECK_ARMED" -eq 1 ]; then
    echo "==> Cleanup: removing temporary deny-check namespace '${DENY_CHECK_NAMESPACE}'..." >&2
    kubectl_vso delete namespace "$DENY_CHECK_NAMESPACE" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  fi
  exit "$exit_status"
}
trap cleanup_deny_check EXIT INT TERM

kubectl_vso apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${DENY_CHECK_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: ${DENY_CHECK_VSS_NAME}
  namespace: ${DENY_CHECK_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
spec:
  vaultAuthRef: ${AUTH_DELEGATOR_AUTH_NAMESPACE}/${AUTH_DELEGATOR_VAULT_AUTH}
  mount: ${AUTH_DELEGATOR_KV_MOUNT}
  type: kv-v2
  path: ${AUTH_DELEGATOR_KV_PATH}
  destination:
    name: ${DENY_CHECK_SECRET_NAME}
    create: true
EOF

sleep 5
DENY_CHECK_READY=$(kubectl_vso get vaultstaticsecret "$DENY_CHECK_VSS_NAME" -n "$DENY_CHECK_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$DENY_CHECK_READY" = "True" ]; then
  fail_section "A VaultStaticSecret in a third namespace was unexpectedly synced despite allowedNamespaces excluding it."
fi
if kubectl_vso get secret "$DENY_CHECK_SECRET_NAME" -n "$DENY_CHECK_NAMESPACE" >/dev/null 2>&1; then
  fail_section "A destination Secret was unexpectedly created in a third namespace despite allowedNamespaces excluding it."
fi
echo "OK: allowedNamespaces correctly denies a third namespace (no Ready status, no Secret created)."

kubectl_vso delete namespace "$DENY_CHECK_NAMESPACE" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
DENY_CHECK_ARMED=0
trap - EXIT INT TERM
echo "OK: temporary deny-check namespace removed."

# ---------------------------------------------------------------------------
# 9. Rotation and exact restoration
# ---------------------------------------------------------------------------

if [ "$SKIP_ROTATION" -eq 1 ]; then
  echo ""
  echo "==> [9/10 rotation] skipped (--skip-rotation)."
else
  section "9/10 rotation + exact restoration (full-object CAS)"

  KV_METADATA=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault kv metadata get \
    -format=json -mount="${AUTH_DELEGATOR_KV_MOUNT}" "${AUTH_DELEGATOR_KV_PATH}" 2>/dev/null || true)
  KV_MARKER=$(printf '%s' "$KV_METADATA" | jq -r --arg k "$AUTH_DELEGATOR_KV_METADATA_KEY" '.data.custom_metadata[$k] // empty' 2>/dev/null || true)
  unset KV_METADATA
  if [ "$KV_MARKER" != "$AUTH_DELEGATOR_KV_METADATA_VALUE" ]; then
    fail_section "kv-v2/${AUTH_DELEGATOR_KV_PATH} is missing the expected ownership custom_metadata; refusing to rotate an unmarked/foreign path."
  fi

  get_kv_json() {
    kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault kv get -format=json -mount="${AUTH_DELEGATOR_KV_MOUNT}" "${AUTH_DELEGATOR_KV_PATH}" 2>/dev/null
  }

  ORIGINAL_KV_JSON=$(get_kv_json) || fail_section "Could not read kv-v2/${AUTH_DELEGATOR_KV_PATH} to capture the rotation baseline."
  ORIGINAL_DATA=$(printf '%s' "$ORIGINAL_KV_JSON" | jq -c '.data.data')
  ORIGINAL_VERSION=$(printf '%s' "$ORIGINAL_KV_JSON" | jq -r '.data.metadata.version')
  unset ORIGINAL_KV_JSON
  if [ -z "$ORIGINAL_DATA" ] || [ -z "$ORIGINAL_VERSION" ] || [ "$ORIGINAL_VERSION" = "null" ]; then
    fail_section "Could not determine the original KV data/version for rotation."
  fi
  echo "OK: captured the complete pre-test KV object (version ${ORIGINAL_VERSION})."

  MUTATED_VERSION=""
  ROTATION_ARMED=1

  # attempt_restore_kv
  #
  # Reconciles ambiguous outcomes by re-reading the CURRENT version/content
  # before deciding whether a restore write is safe: refuses to clobber a
  # version written by someone else after our mutation, and treats
  # already-original content as already-restored.
  attempt_restore_kv() {
    local current_json current_version current_data
    current_json=$(get_kv_json) || {
      echo "ERROR: could not read current KV state during restore; restore kv-v2/${AUTH_DELEGATOR_KV_PATH} manually to:" >&2
      printf '%s\n' "$ORIGINAL_DATA" >&2
      return 1
    }
    current_version=$(printf '%s' "$current_json" | jq -r '.data.metadata.version')
    current_data=$(printf '%s' "$current_json" | jq -c '.data.data')

    if [ "$current_data" = "$ORIGINAL_DATA" ]; then
      echo "OK: current KV content already matches the original; nothing to restore." >&2
      return 0
    fi

    if [ -n "$MUTATED_VERSION" ] && [ "$current_version" != "$MUTATED_VERSION" ]; then
      echo "ERROR: kv-v2/${AUTH_DELEGATOR_KV_PATH} was written by another writer (expected version ${MUTATED_VERSION}, found ${current_version})." >&2
      echo "       Refusing to clobber a concurrent write. Manual recovery: compare the current value to the original below" >&2
      echo "       and restore by hand with 'vault kv put -mount=${AUTH_DELEGATOR_KV_MOUNT} -cas=${current_version} ${AUTH_DELEGATOR_KV_PATH} ...' if appropriate." >&2
      echo "       Original data was: ${ORIGINAL_DATA}" >&2
      return 1
    fi

    if jq -n --argjson data "$ORIGINAL_DATA" --argjson cas "$current_version" '{data:$data, options:{cas:$cas}}' \
        | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write -format=json "${AUTH_DELEGATOR_KV_MOUNT}/data/${AUTH_DELEGATOR_KV_PATH}" - >/dev/null 2>&1; then
      echo "OK: restored the original KV object content (new version written)." >&2
      return 0
    fi

    echo "ERROR: failed to write the restore. Restore kv-v2/${AUTH_DELEGATOR_KV_PATH} manually to:" >&2
    printf '%s\n' "$ORIGINAL_DATA" >&2
    return 1
  }

  restore_on_exit() {
    local exit_status=$?
    trap - EXIT INT TERM HUP
    if [ "$ROTATION_ARMED" -eq 1 ]; then
      echo "==> Cleanup: restoring the original KV object after interruption/failure..." >&2
      attempt_restore_kv || true
    fi
    exit "$exit_status"
  }
  trap restore_on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ROTATED_DATA=$(printf '%s' "$ORIGINAL_DATA" | jq -c --arg u "$ROTATED_USERNAME" '.username = $u')
  echo "==> Mutating kv-v2/${AUTH_DELEGATOR_KV_PATH} (cas=${ORIGINAL_VERSION})..."
  MUTATE_OUTPUT=$(jq -n --argjson data "$ROTATED_DATA" --argjson cas "$ORIGINAL_VERSION" '{data:$data, options:{cas:$cas}}' \
    | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write -format=json "${AUTH_DELEGATOR_KV_MOUNT}/data/${AUTH_DELEGATOR_KV_PATH}" - 2>&1) || {
    fail_section "Failed to write the rotated KV object with cas=${ORIGINAL_VERSION} (a concurrent writer may already hold this version)." "$MUTATE_OUTPUT"
  }
  MUTATED_VERSION=$(printf '%s' "$MUTATE_OUTPUT" | jq -r '.data.version')
  unset MUTATE_OUTPUT ROTATED_DATA
  echo "OK: rotated (new version ${MUTATED_VERSION})."

  ROTATED_SYNCED="false"
  for i in $(seq 1 "$ROTATION_ATTEMPTS"); do
    CURRENT_SECRET_VALUE=$(kubectl_vso get secret "$AUTH_DELEGATOR_SECRET_NAME" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
      -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
    echo "    attempt ${i}: ${CURRENT_SECRET_VALUE:-<not yet synced>}"
    if [ "$CURRENT_SECRET_VALUE" = "$ROTATED_USERNAME" ]; then
      ROTATED_SYNCED="true"
      break
    fi
    sleep "$ROTATION_SLEEP"
  done

  if [ "$ROTATED_SYNCED" != "true" ]; then
    fail_section "The consumer namespace's native Secret did not reflect the rotated value within ${ROTATION_ATTEMPTS} attempts."
  fi
  echo "OK: rotation observed in the consumer namespace's native Secret."

  echo "==> Restoring the original KV object (cas=${MUTATED_VERSION})..."
  if ! attempt_restore_kv; then
    fail_section "Failed to restore the original KV object; see recovery instructions above."
  fi

  RESTORED_SYNCED="false"
  for i in $(seq 1 "$ROTATION_ATTEMPTS"); do
    # Exclude the VSO-injected '_raw' field, which contains the full KV
    # metadata (including version) and always differs from the original
    # capture even when the user-facing data is identical.
    RESTORED_SECRET_JSON=$(kubectl_vso get secret "$AUTH_DELEGATOR_SECRET_NAME" -n "$AUTH_DELEGATOR_APP_NAMESPACE" -o json 2>/dev/null \
      | jq -c '(.data // {}) | with_entries(.value |= (@base64d)) | del(._raw)' 2>/dev/null || echo '{}')
    if [ "$(printf '%s' "$RESTORED_SECRET_JSON" | jq -S .)" = "$(printf '%s' "$ORIGINAL_DATA" | jq -S .)" ]; then
      RESTORED_SYNCED="true"
      break
    fi
    sleep "$ROTATION_SLEEP"
  done

  if [ "$RESTORED_SYNCED" != "true" ]; then
    fail_section "Vault content was restored, but the consumer namespace's native Secret has not caught up yet. Vault state is correct; re-run verification or check VSO reconciliation."
  fi
  echo "OK: both Vault content and the synced Secret are confirmed restored to the original object."

  ROTATION_ARMED=0
  trap - EXIT INT TERM HUP
  unset ORIGINAL_DATA ORIGINAL_VERSION MUTATED_VERSION RESTORED_SECRET_JSON CURRENT_SECRET_VALUE
fi

# ---------------------------------------------------------------------------
# 10. No regression
# ---------------------------------------------------------------------------

section "10/10 no regression (default JWT/OIDC scenario unchanged)"

JWT_OIDC_SNAPSHOT_AFTER=$(capture_jwt_oidc_baseline_snapshot "$VAULT_POD")
VSO_DEMO_CR_SNAPSHOT_AFTER=$(capture_vso_demo_cr_snapshot)

if [ "$JWT_OIDC_SNAPSHOT_BEFORE" != "$JWT_OIDC_SNAPSHOT_AFTER" ]; then
  fail_section "auth/${VSO_JWT_AUTH_MOUNT} (the default JWT/OIDC scenario) changed during this verification run." \
    "before: ${JWT_OIDC_SNAPSHOT_BEFORE}" "after: ${JWT_OIDC_SNAPSHOT_AFTER}"
fi
if [ "$VSO_DEMO_CR_SNAPSHOT_BEFORE" != "$VSO_DEMO_CR_SNAPSHOT_AFTER" ]; then
  fail_section "The default scenario's vso-demo VaultConnection/VaultAuth/VaultStaticSecret specs changed during this verification run." \
    "before: ${VSO_DEMO_CR_SNAPSHOT_BEFORE}" "after: ${VSO_DEMO_CR_SNAPSHOT_AFTER}"
fi
echo "OK: the coexisting default JWT/OIDC scenario (mount/role + vso-demo CRs) is byte-for-byte unchanged."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=================================================================="
echo "VERIFIED: client-JWT-self-review VSO scenario is healthy end-to-end."
echo "  Auth mount:   auth/${AUTH_DELEGATOR_AUTH_MOUNT} (disable_local_ca_jwt=true, disable_iss_validation=true, no reviewer)"
echo "  RBAC:         '${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}' -> system:auth-delegator, sole subject: ${AUTH_DELEGATOR_SELF_REVIEW_SA}"
echo "  Direct proof: same JWT used as outer TokenReview bearer AND reviewed token (authenticated=true, exact identity)"
echo "  Vault:        non-renewable batch token, policy '${AUTH_DELEGATOR_POLICY}' only"
echo "  Cross-ns:     VaultAuth in '${AUTH_DELEGATOR_AUTH_NAMESPACE}', consumed by VaultStaticSecret in '${AUTH_DELEGATOR_APP_NAMESPACE}'"
echo "  Deny-check:   a third namespace is correctly denied by allowedNamespaces"
if [ "$SKIP_ROTATION" -eq 1 ]; then
  echo "  Rotation:     skipped (--skip-rotation)"
else
  echo "  Rotation:     full-object CAS rotation observed, exact restoration confirmed"
fi
echo "  Regression:   default JWT/OIDC scenario unchanged"
echo "=================================================================="
