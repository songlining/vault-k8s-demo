#!/usr/bin/env bash
# scripts/tests/test-configure-vso-auth-delegator-validation.sh
#
# Unit tests for scripts/configure-vso-auth-delegator.sh's validation logic
# and static safety properties only (client JWT self-review Kubernetes auth
# mount, see docs/vso-kubernetes-auth-delegator-plan.md):
#   - shell syntax check
#   - missing required commands (kubectl/jq/base64)
#   - missing/unknown VAULT_CONTEXT or VSO_CONTEXT
#   - VAULT_CONTEXT == VSO_CONTEXT rejected
#   - colliding auth-delegator names rejected (delegates to
#     validate_auth_delegator_env)
#   - unknown flag
#   - happy path (--check-only, no cluster mutation)
#   - static safety review:
#       * the Kubernetes-auth config write sends kubernetes_host,
#         kubernetes_ca_cert, disable_local_ca_jwt=true,
#         disable_iss_validation=true, and an EMPTY token_reviewer_jwt as a
#         single JSON object piped into `vault write ... -` (stdin), never
#         as `key="value"` argv containing the CA PEM
#       * the role write binds bound_service_account_names,
#         bound_service_account_namespaces, and audience (Kubernetes auth
#         uses singular "audience", not "bound_audiences")
#       * the role suppresses the default policy and issues batch tokens
#       * the mount-enable step is guarded by a prior existence/type/
#         description check (idempotent, refuses to adopt a foreign mount)
#       * the policy write is guarded by a byte-identical-content check
#         before reuse, and is piped via stdin
#       * this script never references auth/kubernetes/, auth/jwt-vso/, or
#         auth/kubernetes-vso/ directly (the three mounts it must never
#         touch)
#       * every live-cluster kubectl invocation uses an explicit-context
#         wrapper, except the one intentional context-agnostic
#         `kubectl config view` CA read
#       * the coexisting JWT/OIDC scenario is snapshotted (via
#         capture_jwt_oidc_baseline_snapshot) both before and after this
#         script's own writes
#
# These tests never configure a real Vault -- they only exercise the
# fast-failing validation path via `--check-only` and static review of the
# script contents.
#
# Usage: scripts/tests/test-configure-vso-auth-delegator-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIGURE_AUTH_DELEGATOR="${REPO_ROOT}/scripts/configure-vso-auth-delegator.sh"

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

# 1. bash syntax check.
assert_success \
  "passes bash -n syntax check" \
  bash -n "$CONFIGURE_AUTH_DELEGATOR"

# 2. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  "$CONFIGURE_AUTH_DELEGATOR" --not-a-real-flag

# 3. Missing required commands.
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env PATH=/usr/bin:/bin "$CONFIGURE_AUTH_DELEGATOR" --check-only

# 4. Unknown/missing VAULT_CONTEXT.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vault'" \
  env VAULT_CONTEXT=kind-does-not-exist-vault "$CONFIGURE_AUTH_DELEGATOR" --check-only

# 5. Unknown/missing VSO_CONTEXT.
assert_fail_contains \
  "fails clearly when VSO_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vso'" \
  env VSO_CONTEXT=kind-does-not-exist-vso "$CONFIGURE_AUTH_DELEGATOR" --check-only

# 6. VAULT_CONTEXT == VSO_CONTEXT rejected.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT and VSO_CONTEXT are the same" \
  "must not be the same context" \
  env VAULT_CONTEXT=kind-same VSO_CONTEXT=kind-same "$CONFIGURE_AUTH_DELEGATOR" --check-only

# 7. Colliding auth-delegator namespace rejected (delegated environment
#    validation runs before any cluster/network work).
assert_fail_contains \
  "fails clearly when AUTH_DELEGATOR_APP_NAMESPACE collides with VSO_NAMESPACE" \
  "collide with the existing JWT/OIDC scenario" \
  env AUTH_DELEGATOR_APP_NAMESPACE=vso-demo "$CONFIGURE_AUTH_DELEGATOR" --check-only

# 8. Happy path: real PATH, real contexts (if present), --check-only never
#    touches any cluster.
if command -v kubectl >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vault-lab >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and both contexts are present" \
    "$CONFIGURE_AUTH_DELEGATOR" --check-only
else
  echo "SKIP: happy-path check (kubectl/kind-vault-lab/kind-vso-lab not all available in this environment)"
fi

# --- Static safety review ----------------------------------------------------

# 9. The config write must be a single JSON object piped into
#    `vault write ... -` (stdin), never `kubernetes_ca_cert="..."` as a bare
#    argv key=value pair (which would put the CA PEM in argv/process list).
if grep -qE 'kubernetes_ca_cert="' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "FAIL: script passes kubernetes_ca_cert as a bare argv key=value pair (CA would appear in argv/process list)"
  fail=$((fail + 1))
else
  echo "PASS: script never passes kubernetes_ca_cert as a bare argv key=value pair"
  pass=$((pass + 1))
fi

if grep -qE 'vault write "auth/\$\{AUTH_DELEGATOR_AUTH_MOUNT\}/config" -$' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "PASS: config write pipes a single JSON payload into 'vault write ... -' (stdin)"
  pass=$((pass + 1))
else
  echo "FAIL: could not confirm the config write uses the stdin-JSON '-' form"
  fail=$((fail + 1))
fi

# 10. The JSON payload must set disable_local_ca_jwt=true,
#     disable_iss_validation=true, and an EMPTY token_reviewer_jwt.
if grep -qE 'disable_local_ca_jwt: true' "$CONFIGURE_AUTH_DELEGATOR" \
    && grep -qE 'disable_iss_validation: true' "$CONFIGURE_AUTH_DELEGATOR" \
    && grep -qE 'token_reviewer_jwt: ""' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "PASS: config JSON sets disable_local_ca_jwt=true, disable_iss_validation=true, and an empty token_reviewer_jwt"
  pass=$((pass + 1))
else
  echo "FAIL: config JSON is missing disable_local_ca_jwt/disable_iss_validation/empty token_reviewer_jwt"
  fail=$((fail + 1))
fi

# 11. The readback check must assert all four required fields, including
#     token_reviewer_jwt_set == false (not just disable_local_ca_jwt).
if grep -qE 'token_reviewer_jwt_set == false' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "PASS: readback asserts token_reviewer_jwt_set == false"
  pass=$((pass + 1))
else
  echo "FAIL: readback does not assert token_reviewer_jwt_set == false"
  fail=$((fail + 1))
fi

# 12. The role write must bind bound_service_account_names,
#     bound_service_account_namespaces, and audience (singular -- the
#     Kubernetes auth method's role field, distinct from the JWT auth
#     method's bound_audiences).
if grep -qE 'bound_service_account_names="\$\{AUTH_DELEGATOR_SELF_REVIEW_SA\}"' "$CONFIGURE_AUTH_DELEGATOR" \
    && grep -qE 'bound_service_account_namespaces="\$\{AUTH_DELEGATOR_APP_NAMESPACE\}"' "$CONFIGURE_AUTH_DELEGATOR" \
    && grep -qE 'audience="\$\{AUTH_DELEGATOR_VAULT_AUDIENCE\}"' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "PASS: role write binds the exact self-review SA, consumer namespace, and vault audience"
  pass=$((pass + 1))
else
  echo "FAIL: role write is missing an exact SA/namespace/audience binding"
  fail=$((fail + 1))
fi

if grep -qE 'token_no_default_policy=true' "$CONFIGURE_AUTH_DELEGATOR" && grep -qE 'token_type=batch' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "PASS: role suppresses the default policy and issues non-renewable batch tokens"
  pass=$((pass + 1))
else
  echo "FAIL: role must set token_no_default_policy=true and token_type=batch"
  fail=$((fail + 1))
fi

# 13. Mount-enable must be guarded by an existence/type/description check
#     before enabling or overwriting (refuses to adopt a foreign mount).
if grep -qF '"$EXISTING_MOUNT_TYPE" != "kubernetes"' "$CONFIGURE_AUTH_DELEGATOR" \
    && grep -qF '"$EXISTING_MOUNT_DESC" != "$AUTH_DELEGATOR_MOUNT_DESCRIPTION"' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "PASS: mount enable is guarded by a type/description ownership check"
  pass=$((pass + 1))
else
  echo "FAIL: mount enable is not guarded by a type/description ownership check"
  fail=$((fail + 1))
fi

if grep -qE 'vault auth disable' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "FAIL: script contains a destructive 'vault auth disable' call"
  fail=$((fail + 1))
else
  echo "PASS: script never disables an auth mount"
  pass=$((pass + 1))
fi

# 14. Policy write must be guarded by a byte-identical-content comparison
#     before reuse, and piped via stdin.
if grep -qE 'EXISTING_POLICY_HCL' "$CONFIGURE_AUTH_DELEGATOR" \
    && grep -qE 'vault policy write "\$\{AUTH_DELEGATOR_POLICY\}" -$' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "PASS: policy write is guarded by a content comparison and piped via stdin"
  pass=$((pass + 1))
else
  echo "FAIL: policy write is not guarded/piped as expected"
  fail=$((fail + 1))
fi

# 15. This script must never reference the same-cluster auth/kubernetes/
#     mount, the default JWT/OIDC auth/jwt-vso/ mount, or the historical
#     dedicated-reviewer auth/kubernetes-vso/ mount directly.
for forbidden in '"auth/kubernetes/' "'auth/kubernetes/" '"auth/jwt-vso/' "'auth/jwt-vso/" '"auth/kubernetes-vso/' "'auth/kubernetes-vso/"; do
  if grep -qF -- "$forbidden" "$CONFIGURE_AUTH_DELEGATOR"; then
    echo "FAIL: script references a mount it must never touch directly ('${forbidden}')"
    fail=$((fail + 1))
  fi
done
echo "PASS: script never references auth/kubernetes/, auth/jwt-vso/, or auth/kubernetes-vso/ directly"
pass=$((pass + 1))

# 16. Every kubectl invocation uses an explicit-context wrapper, except the
#     one intentional 'kubectl config view' CA read.
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' "$CONFIGURE_AUTH_DELEGATOR" \
  | grep -vE '(kubectl_vso|kubectl_vault)' \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'require_commands|command -v' \
  | grep -vE 'kubectl config view' || true)
if [ -n "$bare_calls" ]; then
  echo "FAIL: found bare kubectl invocation(s) not using the *_vault/*_vso wrappers or 'kubectl config view':"
  echo "$bare_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every live-cluster kubectl invocation uses an explicit-context wrapper"
  pass=$((pass + 1))
fi

# 17. The coexisting JWT/OIDC scenario must be snapshotted both before and
#     after this script's own writes, and compared for regression.
snapshot_calls=$(grep -c 'capture_jwt_oidc_baseline_snapshot' "$CONFIGURE_AUTH_DELEGATOR" || true)
if [ "$snapshot_calls" -ge 2 ] && grep -qE 'JWT_OIDC_SNAPSHOT_BEFORE.*!=.*JWT_OIDC_SNAPSHOT_AFTER' "$CONFIGURE_AUTH_DELEGATOR"; then
  echo "PASS: the coexisting JWT/OIDC scenario is snapshotted before/after and compared for regression"
  pass=$((pass + 1))
else
  echo "FAIL: could not confirm a before/after regression snapshot of the coexisting JWT/OIDC scenario"
  fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
