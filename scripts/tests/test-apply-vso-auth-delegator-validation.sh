#!/usr/bin/env bash
# scripts/tests/test-apply-vso-auth-delegator-validation.sh
#
# Unit tests for scripts/apply-vso-auth-delegator-demo.sh's validation logic,
# manifest content, and static safety properties only (see
# docs/vso-kubernetes-auth-delegator-plan.md):
#   - shell syntax check
#   - missing required commands
#   - missing/unknown VAULT_CONTEXT or VSO_CONTEXT
#   - VAULT_CONTEXT == VSO_CONTEXT rejected
#   - colliding auth-delegator names rejected
#   - unknown flag
#   - happy path (--check-only, no cluster mutation)
#   - manifest review:
#       * VaultConnection address is the external VAULT_ADDR
#       * VaultAuth: method kubernetes, dedicated mount/role, self-review
#         serviceAccount, BOTH audiences, tokenExpirationSeconds,
#         allowedNamespaces containing ONLY the app namespace
#       * VaultStaticSecret uses the cross-namespace vaultAuthRef
#         "<auth-ns>/<vault-auth-name>"
#       * the self-review ServiceAccount and the app pod both set
#         automountServiceAccountToken: false
#       * the ClusterRoleBinding grants system:auth-delegator to exactly
#         the self-review ServiceAccount (single subject)
#       * the app pod uses the separate unprivileged app ServiceAccount and
#         carries no vault.hashicorp.com annotations
#       * every scenario-owned object carries the ownership label
#   - static safety review:
#       * KV seeding is guarded by an ownership-marker check before any
#         read/write, and uses cas=0 (create-only-if-absent) via stdin JSON
#       * this script never writes/overwrites the Vault policy (the
#         configure script is its sole owner) -- it only verifies the
#         policy exists
#       * namespace/ClusterRoleBinding creation is guarded by an ownership
#         label check before adoption
#       * every kubectl invocation uses an explicit-context wrapper
#
# These tests never apply real CRDs or mutate any real cluster -- they only
# exercise the fast-failing validation path via `--check-only` and static
# review of the script contents (including the rendered manifest, produced
# fully offline).
#
# Usage: scripts/tests/test-apply-vso-auth-delegator-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APPLY_AUTH_DELEGATOR="${REPO_ROOT}/scripts/apply-vso-auth-delegator-demo.sh"

pass=0
fail=0

assert_fail_contains() {
  local desc="$1" expected="$2"
  shift 2
  local out
  local status=0
  out="$("$@" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    echo "FAIL: $desc (expected non-zero exit, got 0)"
    fail=$((fail + 1))
    return
  fi
  if ! echo "$out" | grep -q "$expected"; then
    echo "FAIL: $desc (expected output to contain: $expected)"
    echo "  --- actual output ---"
    echo "$out" | sed 's/^/  /'
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

assert_success() {
  local desc="$1"
  shift
  local out
  local status=0
  out="$("$@" 2>&1)" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $desc (expected exit 0, got $status)"
    echo "$out" | sed 's/^/  /'
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected to find: $needle)"
    fail=$((fail + 1))
  fi
}

# 1. bash syntax check.
assert_success \
  "passes bash -n syntax check" \
  bash -n "$APPLY_AUTH_DELEGATOR"

# 2. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  "$APPLY_AUTH_DELEGATOR" --not-a-real-flag

# 3. Missing required commands.
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env PATH=/usr/bin:/bin "$APPLY_AUTH_DELEGATOR" --check-only

# 4. Unknown/missing VAULT_CONTEXT.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vault'" \
  env VAULT_CONTEXT=kind-does-not-exist-vault "$APPLY_AUTH_DELEGATOR" --check-only

# 5. Unknown/missing VSO_CONTEXT.
assert_fail_contains \
  "fails clearly when VSO_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vso'" \
  env VSO_CONTEXT=kind-does-not-exist-vso "$APPLY_AUTH_DELEGATOR" --check-only

# 6. VAULT_CONTEXT == VSO_CONTEXT rejected.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT and VSO_CONTEXT are the same" \
  "must not be the same context" \
  env VAULT_CONTEXT=kind-same VSO_CONTEXT=kind-same "$APPLY_AUTH_DELEGATOR" --check-only

# 7. Colliding auth-delegator names rejected.
assert_fail_contains \
  "fails clearly when AUTH_DELEGATOR_SECRET_NAME collides with SECRET_NAME" \
  "collide with the existing JWT/OIDC scenario" \
  env AUTH_DELEGATOR_SECRET_NAME=vso-demo-mysecret "$APPLY_AUTH_DELEGATOR" --check-only

# 8. Happy path: real PATH, real contexts (if present), --check-only never
#    touches any cluster (manifests are rendered and validated fully
#    offline via 'kubectl create --dry-run=client').
if command -v kubectl >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vault-lab >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and both contexts are present" \
    "$APPLY_AUTH_DELEGATOR" --check-only
else
  echo "SKIP: happy-path check (kubectl/kind-vault-lab/kind-vso-lab not all available in this environment)"
fi

# --- Manifest review (rendered fully offline, using the same lib defaults) -

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/two-cluster-env.sh"

RENDER_WRAPPER="$(mktemp)"
trap 'rm -f "$RENDER_WRAPPER"' EXIT

{
  echo 'set -euo pipefail'
  echo "SCRIPT_DIR=\"${REPO_ROOT}/scripts\""
  # shellcheck disable=SC2016
  echo 'source "$SCRIPT_DIR/lib/two-cluster-env.sh"'
  sed -n '/^render_auth_delegator_manifests()/,/^}/p' "$APPLY_AUTH_DELEGATOR"
  echo 'render_auth_delegator_manifests'
} > "$RENDER_WRAPPER"

RENDERED_MANIFESTS="$(bash "$RENDER_WRAPPER" 2>&1)"

if [ -z "$RENDERED_MANIFESTS" ]; then
  echo "FAIL: could not render manifests for offline review (render_auth_delegator_manifests produced no output)"
  fail=$((fail + 1))
else
  echo "PASS: manifests render successfully offline"
  pass=$((pass + 1))

  assert_contains \
    "VaultConnection uses the external VAULT_ADDR" \
    "$RENDERED_MANIFESTS" "address: ${VAULT_ADDR}"

  assert_contains \
    "VaultAuth method is kubernetes" \
    "$RENDERED_MANIFESTS" "method: kubernetes"

  assert_contains \
    "VaultAuth uses the dedicated mount" \
    "$RENDERED_MANIFESTS" "mount: ${AUTH_DELEGATOR_AUTH_MOUNT}"

  assert_contains \
    "VaultAuth references the self-review serviceAccount" \
    "$RENDERED_MANIFESTS" "serviceAccount: ${AUTH_DELEGATOR_SELF_REVIEW_SA}"

  assert_contains \
    "VaultAuth requests BOTH audiences" \
    "$RENDERED_MANIFESTS" "- ${AUTH_DELEGATOR_VAULT_AUDIENCE}"
  assert_contains \
    "VaultAuth requests BOTH audiences (API audience)" \
    "$RENDERED_MANIFESTS" "- ${AUTH_DELEGATOR_API_AUDIENCE}"

  assert_contains \
    "VaultAuth sets tokenExpirationSeconds from the shared default" \
    "$RENDERED_MANIFESTS" "tokenExpirationSeconds: ${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS}"

  assert_contains \
    "VaultAuth allowedNamespaces scopes to the app namespace only" \
    "$RENDERED_MANIFESTS" "- ${AUTH_DELEGATOR_APP_NAMESPACE}"

  assert_contains \
    "VaultStaticSecret uses the cross-namespace vaultAuthRef form" \
    "$RENDERED_MANIFESTS" "vaultAuthRef: ${AUTH_DELEGATOR_AUTH_NAMESPACE}/${AUTH_DELEGATOR_VAULT_AUTH}"

  assert_contains \
    "self-review ServiceAccount disables token automount" \
    "$RENDERED_MANIFESTS" "automountServiceAccountToken: false"

  assert_contains \
    "ClusterRoleBinding grants system:auth-delegator" \
    "$RENDERED_MANIFESTS" "name: system:auth-delegator"

  assert_contains \
    "app pod uses the separate unprivileged app ServiceAccount" \
    "$RENDERED_MANIFESTS" "serviceAccountName: ${AUTH_DELEGATOR_APP_SA}"

  if echo "$RENDERED_MANIFESTS" | grep -qE 'vault\.hashicorp\.com/'; then
    echo "FAIL: rendered manifests contain vault.hashicorp.com annotations (the app pod must have zero Vault awareness)"
    fail=$((fail + 1))
  else
    echo "PASS: rendered manifests contain no vault.hashicorp.com annotations"
    pass=$((pass + 1))
  fi

  # The ClusterRoleBinding's ONLY subject must be the self-review SA -- no
  # extra subjects (app SA, default, controller) anywhere in that document.
  CRB_BLOCK=$(printf '%s\n' "$RENDERED_MANIFESTS" | awk '
    /^---$/ { if (cap) exit; next }
    /^kind: ClusterRoleBinding$/ { cap=1 }
    cap { print }
  ')
  SUBJECT_COUNT=$(printf '%s\n' "$CRB_BLOCK" | grep -c 'kind: ServiceAccount' || true)
  if [ "$SUBJECT_COUNT" -eq 1 ] && printf '%s\n' "$CRB_BLOCK" | grep -qF "name: ${AUTH_DELEGATOR_SELF_REVIEW_SA}"; then
    echo "PASS: ClusterRoleBinding has exactly one subject (the self-review ServiceAccount)"
    pass=$((pass + 1))
  else
    echo "FAIL: ClusterRoleBinding does not have exactly one self-review-SA subject (found ${SUBJECT_COUNT})"
    fail=$((fail + 1))
  fi

  # Every scenario-owned object must carry the ownership label.
  OWNED_KINDS=$(printf '%s\n' "$RENDERED_MANIFESTS" | grep -cE '^kind: ' || true)
  LABEL_COUNT=$(printf '%s\n' "$RENDERED_MANIFESTS" | grep -cF "${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}" || true)
  if [ "$LABEL_COUNT" -ge "$OWNED_KINDS" ]; then
    echo "PASS: every rendered object carries the scenario ownership label"
    pass=$((pass + 1))
  else
    echo "FAIL: not every rendered object carries the scenario ownership label (${LABEL_COUNT} labels for ${OWNED_KINDS} objects)"
    fail=$((fail + 1))
  fi
fi

# --- Static safety review ----------------------------------------------------

# 9. KV seeding must be guarded by an ownership-marker check before any
#    read/write, and use cas=0 (create-only-if-absent) via stdin JSON.
if grep -qE 'EXISTING_KV_MARKER.*!=.*AUTH_DELEGATOR_KV_METADATA_VALUE' "$APPLY_AUTH_DELEGATOR" \
    && grep -qE '"options": \{cas: 0\}|options: \{cas: \$cas\}|cas: 0' "$APPLY_AUTH_DELEGATOR"; then
  echo "PASS: KV seeding is guarded by an ownership-marker check and uses cas=0 (create-only-if-absent)"
  pass=$((pass + 1))
else
  echo "FAIL: KV seeding is not guarded/CAS-safe as expected"
  fail=$((fail + 1))
fi

# 10. This script must never write/overwrite the Vault policy -- the
#     configure script is its sole owner. It may only read/verify it
#     exists.
if grep -qE 'vault policy write' "$APPLY_AUTH_DELEGATOR"; then
  echo "FAIL: apply script writes a Vault policy (the configure script must be the sole owner)"
  fail=$((fail + 1))
else
  echo "PASS: apply script never writes a Vault policy"
  pass=$((pass + 1))
fi
if grep -qE 'vault policy read "\$\{AUTH_DELEGATOR_POLICY\}"' "$APPLY_AUTH_DELEGATOR"; then
  echo "PASS: apply script verifies (read-only) that the dedicated policy already exists"
  pass=$((pass + 1))
else
  echo "FAIL: apply script does not verify the dedicated policy exists before proceeding"
  fail=$((fail + 1))
fi

# 11. Namespace/ClusterRoleBinding adoption must be guarded by an ownership
#     label check.
if grep -qE 'existing_label.*!=.*AUTH_DELEGATOR_OWNER_LABEL_VALUE' "$APPLY_AUTH_DELEGATOR" \
    && grep -qE 'CRB_LABEL.*!=.*AUTH_DELEGATOR_OWNER_LABEL_VALUE' "$APPLY_AUTH_DELEGATOR"; then
  echo "PASS: namespace and ClusterRoleBinding adoption are guarded by an ownership label check"
  pass=$((pass + 1))
else
  echo "FAIL: namespace/ClusterRoleBinding adoption is not guarded by an ownership label check"
  fail=$((fail + 1))
fi

# 12. Every kubectl invocation uses an explicit-context wrapper.
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' "$APPLY_AUTH_DELEGATOR" \
  | grep -vE '(kubectl_vso|kubectl_vault)' \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE '^[0-9]+:\s*echo ' \
  | grep -vE 'require_commands|command -v' \
  | grep -vE 'kubectl create --dry-run=client|kubectl apply --dry-run=server' || true)
if [ -n "$bare_calls" ]; then
  echo "FAIL: found bare kubectl invocation(s) not using the *_vault/*_vso wrappers:"
  echo "$bare_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every live-cluster kubectl invocation uses an explicit-context wrapper"
  pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
