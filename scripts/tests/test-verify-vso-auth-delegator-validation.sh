#!/usr/bin/env bash
# scripts/tests/test-verify-vso-auth-delegator-validation.sh
#
# Unit tests for scripts/verify-vso-auth-delegator.sh's validation logic and
# structure only (client JWT self-review VSO scenario, see
# docs/vso-kubernetes-auth-delegator-plan.md):
#   - shell syntax check
#   - missing required commands (kubectl/base64/jq/curl)
#   - missing/unknown VAULT_CONTEXT or VSO_CONTEXT
#   - VAULT_CONTEXT == VSO_CONTEXT rejected
#   - colliding auth-delegator names rejected
#   - unknown flag
#   - happy path (--check-only, no cluster mutation)
#   - section review: all 10 sections are present, in order
#   - direct same-JWT TokenReview proof: the same in-memory JWT is used as
#     both the outer HTTP bearer AND spec.token, with spec.audiences=["vault"]
#   - all 3 Vault-login negative cases are present (vault-only audience,
#     API-only audience, wrong ServiceAccount) and asserted to fail
#   - RBAC positive/negative can-i checks for self-review/app/default/
#     controller identities
#   - token constraints: renewable=false, token_type=batch, exact policy,
#     empty identity_policies, bounded TTL
#   - rotation section: full-object capture, cas-based mutate+restore, HUP/
#     INT/TERM traps, conflict detection, restoration verified before the
#     trap is disarmed
#   - --skip-rotation is parsed and honored
#   - no full JWT/Vault token value is ever echoed/printed by the script
#   - every kubectl invocation uses an explicit-context wrapper
#
# These tests never mutate any real cluster beyond `--check-only` (which
# only validates tools/contexts/environment/runtime feature detection) --
# the full end-to-end run (including rotation and the direct TokenReview
# proof) is exercised manually against a real two-cluster environment, not
# by this file.
#
# Usage: scripts/tests/test-verify-vso-auth-delegator-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERIFY_AUTH_DELEGATOR="${REPO_ROOT}/scripts/verify-vso-auth-delegator.sh"

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
  bash -n "$VERIFY_AUTH_DELEGATOR"

# 2. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  "$VERIFY_AUTH_DELEGATOR" --not-a-real-flag

# 3. Missing required commands.
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env PATH=/usr/bin:/bin "$VERIFY_AUTH_DELEGATOR" --check-only

# 4. Unknown/missing VAULT_CONTEXT.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vault'" \
  env VAULT_CONTEXT=kind-does-not-exist-vault "$VERIFY_AUTH_DELEGATOR" --check-only

# 5. Unknown/missing VSO_CONTEXT.
assert_fail_contains \
  "fails clearly when VSO_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vso'" \
  env VSO_CONTEXT=kind-does-not-exist-vso "$VERIFY_AUTH_DELEGATOR" --check-only

# 6. VAULT_CONTEXT == VSO_CONTEXT rejected.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT and VSO_CONTEXT are the same" \
  "must not be the same context" \
  env VAULT_CONTEXT=kind-same VSO_CONTEXT=kind-same "$VERIFY_AUTH_DELEGATOR" --check-only

# 7. Colliding auth-delegator names rejected.
assert_fail_contains \
  "fails clearly when the auth-delegator environment is misconfigured" \
  "auth-delegator environment is misconfigured" \
  env AUTH_DELEGATOR_APP_NAMESPACE=vso-demo "$VERIFY_AUTH_DELEGATOR" --check-only

# 8. Happy path: real PATH, real contexts (if present), --check-only never
#    touches any cluster beyond context/environment/runtime-feature checks.
if command -v kubectl >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vault-lab >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and both contexts are present" \
    "$VERIFY_AUTH_DELEGATOR" --check-only
else
  echo "SKIP: happy-path check (kubectl/kind-vault-lab/kind-vso-lab not all available in this environment)"
fi

# --- Static review -----------------------------------------------------------

CONTENTS="$(cat "$VERIFY_AUTH_DELEGATOR")"

# 9. All 10 sections are present.
EXPECTED_SECTIONS=(
  "1/10 contexts + compatibility + baseline snapshot"
  "2/10 placement + ownership"
  "3/10 network + TLS"
  "4/10 rbac + reviewer selection"
  "5/10 jwt claims + direct self-review proof"
  "6/10 vault login + negative authentication"
  "7/10 vault token constraints"
  "8/10 cross-namespace sync + deny-by-default"
  "9/10 rotation + exact restoration"
  "10/10 no regression"
)
for s in "${EXPECTED_SECTIONS[@]}"; do
  assert_contains "section '${s}' is present" "$CONTENTS" "$s"
done

# 10. Sections appear in ascending order.
declare -a LINES=()
for s in "1/10 contexts" "2/10 placement" "3/10 network" "4/10 rbac" "5/10 jwt claims" \
    "6/10 vault login" "7/10 vault token constraints" "8/10 cross-namespace" \
    "9/10 rotation" "10/10 no regression"; do
  LINES+=("$(grep -n -- "$s" "$VERIFY_AUTH_DELEGATOR" | head -1 | cut -d: -f1)")
done
ordered=1
for i in $(seq 0 8); do
  if [ "${LINES[$i]}" -ge "${LINES[$((i+1))]}" ]; then
    ordered=0
  fi
done
if [ "$ordered" -eq 1 ]; then
  echo "PASS: all 10 sections appear in ascending order"
  pass=$((pass + 1))
else
  echo "FAIL: sections are not in ascending order (${LINES[*]})"
  fail=$((fail + 1))
fi

# 11. Baseline snapshot of the coexisting default JWT/OIDC scenario is
#     captured (section 1) and compared byte-for-byte at the end
#     (section 10).
assert_contains \
  "captures a JWT/OIDC mount/role snapshot before any gate runs" \
  "$CONTENTS" 'JWT_OIDC_SNAPSHOT_BEFORE=$(capture_jwt_oidc_baseline_snapshot'
assert_contains \
  "captures a vso-demo CR snapshot before any gate runs" \
  "$CONTENTS" 'VSO_DEMO_CR_SNAPSHOT_BEFORE=$(capture_vso_demo_cr_snapshot'
assert_contains \
  "compares the JWT/OIDC snapshot byte-for-byte at the end" \
  "$CONTENTS" 'JWT_OIDC_SNAPSHOT_BEFORE" != "$JWT_OIDC_SNAPSHOT_AFTER'
assert_contains \
  "compares the vso-demo CR snapshot byte-for-byte at the end" \
  "$CONTENTS" 'VSO_DEMO_CR_SNAPSHOT_BEFORE" != "$VSO_DEMO_CR_SNAPSHOT_AFTER'

# 12. RBAC positive/negative checks: self-review SA can, app/default/
#     controller SAs cannot.
assert_contains \
  "asserts the self-review ServiceAccount CAN create TokenReviews" \
  "$CONTENTS" 'cannot create TokenReviews.'
assert_contains \
  "checks the app ServiceAccount cannot create TokenReviews" \
  "$CONTENTS" 'AUTH_DELEGATOR_APP_SA}|app ServiceAccount'
assert_contains \
  "checks the default ServiceAccount cannot create TokenReviews" \
  "$CONTENTS" 'default ServiceAccount (consumer ns)'
assert_contains \
  "checks the VSO controller ServiceAccount cannot create TokenReviews" \
  "$CONTENTS" 'VSO controller ServiceAccount'
assert_contains \
  "legacy system:auth-delegator bindings are reported but not modified" \
  "$CONTENTS" 'reported, not changed'

# 13. Live Vault mount review requires disable_local_ca_jwt, disable_iss_validation, no reviewer.
assert_contains \
  "checks disable_local_ca_jwt == true" \
  "$CONTENTS" '.data.disable_local_ca_jwt == true'
assert_contains \
  "checks disable_iss_validation == true" \
  "$CONTENTS" '.data.disable_iss_validation == true'
assert_contains \
  "checks token_reviewer_jwt_set == false" \
  "$CONTENTS" '.data.token_reviewer_jwt_set == false'

# 14. Direct same-JWT TokenReview proof: one variable used as BOTH the
#     outer Authorization bearer AND spec.token.
assert_contains \
  "direct TokenReview sets the Authorization header from the self-review JWT" \
  "$CONTENTS" 'Authorization: Bearer ${SELF_REVIEW_JWT}'
assert_contains \
  "direct TokenReview body's spec.token uses the SAME JWT variable" \
  "$CONTENTS" '--arg token "$SELF_REVIEW_JWT"'
assert_contains \
  "direct TokenReview requests spec.audiences=[\"vault\"]" \
  "$CONTENTS" 'spec:{token:$token, audiences:[$aud]}'
assert_contains \
  "direct TokenReview asserts authenticated == true" \
  "$CONTENTS" '.status.authenticated == true'
assert_contains \
  "direct TokenReview asserts the exact identity" \
  "$CONTENTS" '.status.user.username == $sub'

# 15. Dual-audience minted JWT claims are checked (issuer, subject, BOTH
#     audiences, bounded lifetime) without ever printing the token.
assert_contains \
  "asserts both audiences are present in the minted JWT" \
  "$CONTENTS" '(.aud | index($a1) != null) and'
assert_contains \
  "asserts the JWT lifetime is bounded to <= 600s" \
  "$CONTENTS" '(.exp - .iat) <= 600'

if grep -nE 'echo.*\$(\{)?(SELF_REVIEW_JWT|VAULT_ONLY_JWT|API_ONLY_JWT|WRONG_SA_JWT)(\})?' "$VERIFY_AUTH_DELEGATOR" >/dev/null; then
  echo "FAIL: found an echo that appears to print a raw JWT variable"
  fail=$((fail + 1))
else
  echo "PASS: no echo prints a raw JWT variable"
  pass=$((pass + 1))
fi

# 16. All three Vault-login negative cases exist and are asserted to fail.
assert_contains \
  "negative case: vault-audience-only JWT is minted" \
  "$CONTENTS" 'VAULT_ONLY_JWT=$(kubectl_vso create token'
assert_contains \
  "negative case: vault-audience-only login is asserted to fail" \
  "$CONTENTS" 'incorrectly ACCEPTED a vault-audience-only JWT'

assert_contains \
  "negative case: API-audience-only JWT is minted" \
  "$CONTENTS" 'API_ONLY_JWT=$(kubectl_vso create token'
assert_contains \
  "negative case: API-audience-only login is asserted to fail" \
  "$CONTENTS" 'incorrectly ACCEPTED an API-audience-only JWT'

assert_contains \
  "negative case: wrong-ServiceAccount JWT is minted" \
  "$CONTENTS" 'WRONG_SA_JWT=$(kubectl_vso create token "$AUTH_DELEGATOR_APP_SA"'
assert_contains \
  "negative case: wrong-ServiceAccount login is asserted to fail" \
  "$CONTENTS" 'incorrectly ACCEPTED a JWT from the wrong (app) ServiceAccount'

# 17. Login JWTs are sent via stdin (jwt=-), never as an exec argument.
assert_contains \
  "login sends the JWT over stdin (jwt=-)" \
  "$CONTENTS" 'jwt=-'
if grep -nE 'jwt="\$\{?(SELF_REVIEW_JWT|VAULT_ONLY_JWT|API_ONLY_JWT|WRONG_SA_JWT)' "$VERIFY_AUTH_DELEGATOR" >/dev/null; then
  echo "FAIL: a JWT is passed as a bare exec argument instead of via stdin"
  fail=$((fail + 1))
else
  echo "PASS: JWTs are never passed as bare exec arguments"
  pass=$((pass + 1))
fi

# 18. Token constraint checks: renewable=false, token_type=batch, exact
#     policy set, empty identity_policies, bounded TTL.
assert_contains \
  "checks the token is non-renewable" \
  "$CONTENTS" 'LOGIN_RENEWABLE" != "false"'
assert_contains \
  "checks the token type is batch" \
  "$CONTENTS" 'LOGIN_TOKEN_TYPE" != "batch"'
assert_contains \
  "checks token_policies and effective policies against the expected single-policy set" \
  "$CONTENTS" 'EXPECTED_POLICIES_JSON'
assert_contains \
  "checks identity_policies is empty" \
  "$CONTENTS" "IDENTITY_POLICIES" != '[]'"'"
assert_contains \
  "checks the TTL is positive and bounded by the configured maximum" \
  "$CONTENTS" 'LOGIN_TTL" -le 0'

# 19. Cross-namespace deny-by-default check in a THIRD namespace, with a
#     scoped cleanup trap.
assert_contains \
  "creates a temporary third namespace for the deny-by-default check" \
  "$CONTENTS" 'DENY_CHECK_NAMESPACE'
assert_contains \
  "asserts the temporary VaultStaticSecret is NOT Ready (denied by allowedNamespaces)" \
  "$CONTENTS" 'unexpectedly synced despite allowedNamespaces'
assert_contains \
  "asserts no Secret is created in the denied third namespace" \
  "$CONTENTS" 'unexpectedly created in a third namespace'
assert_contains \
  "deny-check cleanup is scoped to only the temporary namespace" \
  "$CONTENTS" 'cleanup_deny_check'

# 20. Rotation section: full-object capture, CAS mutate+restore, HUP/INT/
#     TERM traps, conflict detection, restore verified before disarming.
assert_contains \
  "rotation requires the KV ownership marker before touching the fixture" \
  "$CONTENTS" 'refusing to rotate an unmarked/foreign path'
assert_contains \
  "rotation captures the complete original KV data object and version" \
  "$CONTENTS" 'ORIGINAL_DATA=$(printf'
assert_contains \
  "rotation mutates with cas=<original-version>" \
  "$CONTENTS" '--argjson cas "$ORIGINAL_VERSION"'
assert_contains \
  "rotation cleanup installs EXIT/INT/TERM/HUP traps" \
  "$CONTENTS" "trap 'exit 129' HUP"
assert_contains \
  "restore refuses to clobber a version written by another writer" \
  "$CONTENTS" 'Refusing to clobber a concurrent write'
assert_contains \
  "restore reconciles ambiguous outcomes by reading current version/content first" \
  "$CONTENTS" 'current_data" = "$ORIGINAL_DATA'
assert_contains \
  "restore verifies the synced Secret before disarming the trap" \
  "$CONTENTS" 'ROTATION_ARMED=0'

ROTATION_ARMED_LINE=$(grep -n '^  ROTATION_ARMED=0' "$VERIFY_AUTH_DELEGATOR" | tail -1 | cut -d: -f1)
RESTORED_CHECK_LINE=$(grep -n 'RESTORED_SYNCED" != "true"' "$VERIFY_AUTH_DELEGATOR" | tail -1 | cut -d: -f1)
if [ -n "$ROTATION_ARMED_LINE" ] && [ -n "$RESTORED_CHECK_LINE" ] && [ "$RESTORED_CHECK_LINE" -lt "$ROTATION_ARMED_LINE" ]; then
  echo "PASS: restoration is verified before the rotation trap is disarmed"
  pass=$((pass + 1))
else
  echo "FAIL: could not confirm restoration is verified before the rotation trap is disarmed"
  fail=$((fail + 1))
fi

# 21. --skip-rotation is parsed and actually skips the rotation section.
assert_contains \
  "--skip-rotation flag is parsed" \
  "$CONTENTS" '--skip-rotation)'
assert_contains \
  "--skip-rotation actually skips the rotation section" \
  "$CONTENTS" 'skipped (--skip-rotation)'

# 22. Every kubectl invocation uses an explicit-context wrapper.
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' "$VERIFY_AUTH_DELEGATOR" \
  | grep -vE '(kubectl_vso|kubectl_vault)' \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE '^[0-9]+:\s*echo ' \
  | grep -vE 'require_commands|command -v|kubectl config view' || true)
if [ -n "$bare_calls" ]; then
  echo "FAIL: found bare kubectl invocation(s) not using an explicit-context wrapper:"
  echo "$bare_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every kubectl invocation uses an explicit-context wrapper"
  pass=$((pass + 1))
fi

# 23. The live mount config readback (which may contain kubernetes_ca_cert)
#     is never echoed/printed on any path -- only pass/fail assertions are
#     derived from it, and it is unset immediately after use.
if grep -nE 'echo.*\$(\{)?MOUNT_CONFIG(\})?' "$VERIFY_AUTH_DELEGATOR" >/dev/null; then
  echo "FAIL: found an echo that appears to print the raw mount config (may contain kubernetes_ca_cert)"
  fail=$((fail + 1))
else
  echo "PASS: the mount config readback (which may contain kubernetes_ca_cert) is never echoed"
  pass=$((pass + 1))
fi
assert_contains \
  "the mount config variable is unset immediately after use" \
  "$CONTENTS" 'unset MOUNT_CONFIG'

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
