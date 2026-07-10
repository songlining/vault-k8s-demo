#!/usr/bin/env bash
# scripts/tests/test-check-vault-connectivity-validation.sh
#
# Unit tests for scripts/check-vault-connectivity.sh's validation logic:
#   - missing required commands (kubectl)
#   - missing/unknown VSO_CONTEXT
#   - unknown flag
#   - happy path (--check-only, no pod run against any real cluster)
#
# These tests never run the throwaway curl pod against a real cluster --
# they only exercise the fast-failing validation path via `--check-only`.
#
# Usage: scripts/tests/test-check-vault-connectivity-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHECK_SCRIPT="${REPO_ROOT}/scripts/check-vault-connectivity.sh"

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
  bash -n "$CHECK_SCRIPT"

# 2. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  "$CHECK_SCRIPT" --not-a-real-flag

# 3. Missing required commands (simulate an empty PATH minus bash builtins).
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env PATH=/usr/bin:/bin "$CHECK_SCRIPT" --check-only

# 4. Unknown/missing VSO_CONTEXT.
assert_fail_contains \
  "fails clearly when VSO_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vso'" \
  env VSO_CONTEXT=kind-does-not-exist-vso "$CHECK_SCRIPT" --check-only

# 5. Happy path: real PATH, real VSO_CONTEXT (if present), --check-only never
#    runs the connectivity-check pod.
if command -v kubectl >/dev/null 2>&1 && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and VSO_CONTEXT are present" \
    "$CHECK_SCRIPT" --check-only
else
  echo "SKIP: happy-path check (kubectl/kind-vso-lab context not available in this environment)"
fi

# 6. Every kubectl invocation in the script uses the explicit-context
#    kubectl_vso wrapper -- guard against regressions that call bare
#    `kubectl` without going through it.
bare_calls=$(grep -nE '(^|[^_a-zA-Z])kubectl[[:space:]]' "$CHECK_SCRIPT" \
  | grep -vE 'kubectl_vso|kubectl_vault' \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'require_commands|command -v' \
  | grep -vE 'echo ' || true)
if [ -n "$bare_calls" ]; then
  echo "FAIL: found bare kubectl invocation(s) not using the kubectl_vso wrapper:"
  echo "$bare_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every kubectl invocation uses the explicit-context kubectl_vso wrapper"
  pass=$((pass + 1))
fi

# 7. VAULT_ADDR must not reference vault.default.svc.cluster.local or any
#    other in-cluster-only DNS name -- this is a cross-cluster check.
if grep -v '^#' "$CHECK_SCRIPT" | grep -q 'svc.cluster.local'; then
  echo "FAIL: script references an in-cluster-only DNS name (svc.cluster.local)"
  fail=$((fail + 1))
else
  echo "PASS: script does not reference any svc.cluster.local DNS name"
  pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
