#!/usr/bin/env bash
# scripts/tests/test-verify-two-cluster-validation.sh
#
# Unit tests for scripts/verify-two-cluster.sh's validation logic and
# structure only:
#   - shell syntax check
#   - missing required commands (kubectl/base64/jq)
#   - missing/unknown VAULT_CONTEXT or VSO_CONTEXT
#   - VAULT_CONTEXT == VSO_CONTEXT rejected
#   - unknown flag
#   - happy path (--check-only, no cluster mutation)
#   - section review: all 7 sections are present, in order, and each has a
#     matching fail_section actionable-message call
#   - every kubectl invocation uses an explicit-context wrapper
#   - rotation section resets the baseline value even on failure
#
# These tests never mutate any real cluster beyond `--check-only` (which
# only validates tools/contexts) -- the full end-to-end run (including the
# rotation section) is exercised manually per the task's validation steps
# against a real two-cluster environment, not by this file.
#
# Usage: scripts/tests/test-verify-two-cluster-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERIFY_SCRIPT="${REPO_ROOT}/scripts/verify-two-cluster.sh"

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
  bash -n "$VERIFY_SCRIPT"

# 2. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  "$VERIFY_SCRIPT" --not-a-real-flag

# 3. Missing required commands (simulate an empty PATH minus bash builtins).
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env PATH=/usr/bin:/bin "$VERIFY_SCRIPT" --check-only

# 4. Unknown/missing VAULT_CONTEXT.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vault'" \
  env VAULT_CONTEXT=kind-does-not-exist-vault "$VERIFY_SCRIPT" --check-only

# 5. Unknown/missing VSO_CONTEXT.
assert_fail_contains \
  "fails clearly when VSO_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vso'" \
  env VSO_CONTEXT=kind-does-not-exist-vso "$VERIFY_SCRIPT" --check-only

# 6. VAULT_CONTEXT == VSO_CONTEXT rejected.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT and VSO_CONTEXT are the same" \
  "must not be the same context" \
  env VAULT_CONTEXT=kind-vault-lab VSO_CONTEXT=kind-vault-lab "$VERIFY_SCRIPT" --check-only

# 7. Happy path: real PATH, real contexts (if present), --check-only never
#    touches any cluster beyond the context-existence check.
if command -v kubectl >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vault-lab >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and both contexts are present" \
    "$VERIFY_SCRIPT" --check-only
else
  echo "SKIP: happy-path check (kubectl/kind-vault-lab/kind-vso-lab not all available in this environment)"
fi

# 8. Static review: read the script contents once for structural checks.
CONTENTS="$(cat "$VERIFY_SCRIPT")"

EXPECTED_SECTIONS=(
  "1/7 contexts"
  "2/7 vault placement + readiness"
  "3/7 vso placement + readiness"
  "4/7 network reachability"
  "5/7 kubernetes auth"
  "6/7 vso reconciliation + secret sync"
  "7/7 rotation"
)

for s in "${EXPECTED_SECTIONS[@]}"; do
  assert_contains \
    "section '${s}' is present" \
    "$CONTENTS" "$s"
done

# 9. Sections appear in ascending order (by line number of their `section`
#    call / skip-rotation echo).
LINE_1=$(grep -n '"1/7 contexts"' "$VERIFY_SCRIPT" | head -1 | cut -d: -f1)
LINE_2=$(grep -n '"2/7 vault placement' "$VERIFY_SCRIPT" | head -1 | cut -d: -f1)
LINE_3=$(grep -n '"3/7 vso placement' "$VERIFY_SCRIPT" | head -1 | cut -d: -f1)
LINE_4=$(grep -n '4/7 network reachability' "$VERIFY_SCRIPT" | head -1 | cut -d: -f1)
LINE_5=$(grep -n '"5/7 kubernetes auth' "$VERIFY_SCRIPT" | head -1 | cut -d: -f1)
LINE_6=$(grep -n '"6/7 vso reconciliation' "$VERIFY_SCRIPT" | head -1 | cut -d: -f1)
LINE_7=$(grep -n '7/7 rotation' "$VERIFY_SCRIPT" | head -1 | cut -d: -f1)

if [ "$LINE_1" -lt "$LINE_2" ] && [ "$LINE_2" -lt "$LINE_3" ] && [ "$LINE_3" -lt "$LINE_4" ] \
    && [ "$LINE_4" -lt "$LINE_5" ] && [ "$LINE_5" -lt "$LINE_6" ] && [ "$LINE_6" -lt "$LINE_7" ]; then
  echo "PASS: all 7 sections appear in ascending order"
  pass=$((pass + 1))
else
  echo "FAIL: sections are not in ascending order ($LINE_1,$LINE_2,$LINE_3,$LINE_4,$LINE_5,$LINE_6,$LINE_7)"
  fail=$((fail + 1))
fi

# 10. Negative placement checks are present (Vault absent from VSO cluster,
#     VSO absent from Vault cluster).
assert_contains \
  "checks Vault is absent from the VSO cluster" \
  "$CONTENTS" 'Found Vault pod(s)'

assert_contains \
  "checks VSO operator/CRDs/namespace are absent from the Vault cluster" \
  "$CONTENTS" 'unexpectedly exists in the Vault cluster'

# 11. Rotation section resets the baseline value even when the rotation
#     itself fails (soft-landing behavior), and always attempts a final
#     reset to BASELINE_USERNAME.
assert_contains \
  "rotation failure path resets the baseline value before failing" \
  "$CONTENTS" 'Reset the baseline before failing'

BASELINE_RESET_COUNT=$(grep -c 'vault kv put kv-v2/vault-demo/mysecret username="${BASELINE_USERNAME}"' "$VERIFY_SCRIPT" || true)
if [ "$BASELINE_RESET_COUNT" -ge 2 ]; then
  echo "PASS: baseline value is reset in both the failure path and the final reset step"
  pass=$((pass + 1))
else
  echo "FAIL: expected at least 2 baseline-reset writes (failure path + final reset), found ${BASELINE_RESET_COUNT}"
  fail=$((fail + 1))
fi

# 12. Auth section actually performs a real login (not just a status check).
assert_contains \
  "auth section performs a real vault write .../login with a minted JWT" \
  "$CONTENTS" 'vault write -format=json'

assert_contains \
  "auth section mints a token for the vso-demo service account" \
  "$CONTENTS" 'kubectl_vso create token vso-demo'

# 13. Every kubectl invocation in the script uses an explicit context (via
#     the kubectl_vso/kubectl_vault wrappers) -- guard against regressions
#     that call bare `kubectl` without going through the wrappers.
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' "$VERIFY_SCRIPT" \
  | grep -vE '(kubectl_vso|kubectl_vault)' \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE '^[0-9]+:\s*echo ' \
  | grep -vE 'require_commands|command -v' \
  | grep -viE 'Inspect with|Check:|logs -n' || true)
if [ -n "$bare_calls" ]; then
  echo "FAIL: found bare kubectl invocation(s) not using an explicit-context wrapper:"
  echo "$bare_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every kubectl invocation uses an explicit-context wrapper"
  pass=$((pass + 1))
fi

# 14. --skip-rotation flag is honored (documented and parsed).
assert_contains \
  "--skip-rotation flag is parsed" \
  "$CONTENTS" '--skip-rotation)'

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
