#!/usr/bin/env bash
# scripts/tests/test-configure-vso-kubernetes-auth-validation.sh
#
# Unit tests for scripts/configure-vso-kubernetes-auth.sh's validation logic
# only:
#   - shell syntax check
#   - missing required commands (kubectl/jq/base64)
#   - missing/unknown VAULT_CONTEXT or VSO_CONTEXT
#   - VAULT_CONTEXT == VSO_CONTEXT rejected
#   - unknown flag
#   - happy path (--check-only, no cluster mutation)
#   - idempotence review: enable/config/role writes use fixed idempotent
#     patterns (no destructive `vault auth disable` etc.) and never touch
#     the same-cluster `auth/kubernetes` mount
#
# These tests never configure a real Vault or mint real reviewer tokens --
# they only exercise the fast-failing validation path via `--check-only` and
# static review of the script contents.
#
# Usage: scripts/tests/test-configure-vso-kubernetes-auth-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIGURE_AUTH="${REPO_ROOT}/scripts/configure-vso-kubernetes-auth.sh"

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
  bash -n "$CONFIGURE_AUTH"

# 2. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  "$CONFIGURE_AUTH" --not-a-real-flag

# 3. Missing required commands (simulate an empty PATH minus bash builtins).
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env PATH=/usr/bin:/bin "$CONFIGURE_AUTH" --check-only

# 4. Unknown/missing VAULT_CONTEXT.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vault'" \
  env VAULT_CONTEXT=kind-does-not-exist-vault "$CONFIGURE_AUTH" --check-only

# 5. Unknown/missing VSO_CONTEXT.
assert_fail_contains \
  "fails clearly when VSO_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vso'" \
  env VSO_CONTEXT=kind-does-not-exist-vso "$CONFIGURE_AUTH" --check-only

# 6. VAULT_CONTEXT == VSO_CONTEXT rejected.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT and VSO_CONTEXT are the same" \
  "must not be the same context" \
  env VAULT_CONTEXT=kind-same VSO_CONTEXT=kind-same "$CONFIGURE_AUTH" --check-only

# 7. Happy path: real PATH, real contexts (if present), --check-only never
#    touches any cluster.
if command -v kubectl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vault-lab >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and both contexts are present" \
    "$CONFIGURE_AUTH" --check-only
else
  echo "SKIP: happy-path check (kubectl/jq/kind-vault-lab/kind-vso-lab not all available in this environment)"
fi

# 8. Idempotence / safety review: the script must never disable or delete
#    the auth/kubernetes-vso mount, and must never touch the pre-existing
#    same-cluster auth/kubernetes mount at all.
if grep -qE 'vault auth disable' "$CONFIGURE_AUTH"; then
  echo "FAIL: script contains a destructive 'vault auth disable' call"
  fail=$((fail + 1))
else
  echo "PASS: script never disables an auth mount"
  pass=$((pass + 1))
fi

if grep -qE '"auth/kubernetes/' "$CONFIGURE_AUTH" || grep -qE "'auth/kubernetes/" "$CONFIGURE_AUTH"; then
  echo "FAIL: script references the same-cluster auth/kubernetes/ mount directly (should only touch auth/\${VSO_AUTH_MOUNT})"
  fail=$((fail + 1))
else
  echo "PASS: script never references the same-cluster auth/kubernetes/ mount directly"
  pass=$((pass + 1))
fi

# 9. Every kubectl invocation in the script uses an explicit-context wrapper
#    (kubectl_vault/kubectl_vso), except the one intentional use of raw
#    `kubectl config view` to read the VSO cluster's CA from the local
#    kubeconfig (which is context-agnostic by design: it reads the cluster
#    entry, not a live API call against any context).
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' "$CONFIGURE_AUTH" \
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

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
