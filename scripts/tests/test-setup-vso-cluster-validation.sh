#!/usr/bin/env bash
# scripts/tests/test-setup-vso-cluster-validation.sh
#
# Unit tests for scripts/setup-vso-cluster.sh's validation logic only:
#   - missing required commands (kubectl/helm)
#   - missing/unknown VSO_CONTEXT
#   - unknown flag
#   - happy path (--check-only, no cluster mutation)
#
# These tests never install the operator or mutate any real cluster -- they
# only exercise the fast-failing validation path via `--check-only`.
#
# Usage: scripts/tests/test-setup-vso-cluster-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETUP_VSO="${REPO_ROOT}/scripts/setup-vso-cluster.sh"

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
  bash -n "$SETUP_VSO"

# 2. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  "$SETUP_VSO" --not-a-real-flag

# 3. Missing required commands (simulate an empty PATH minus bash builtins).
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env PATH=/usr/bin:/bin "$SETUP_VSO" --check-only

# 4. Unknown/missing VSO_CONTEXT.
assert_fail_contains \
  "fails clearly when VSO_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vso'" \
  env VSO_CONTEXT=kind-does-not-exist-vso "$SETUP_VSO" --check-only

# 5. Happy path: real PATH, real VSO_CONTEXT (if present), --check-only never
#    touches the cluster.
if command -v kubectl >/dev/null 2>&1 && command -v helm >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and VSO_CONTEXT are present" \
    "$SETUP_VSO" --check-only
else
  echo "SKIP: happy-path check (kubectl/helm/kind-vso-lab context not all available in this environment)"
fi

# 6. Every kubectl/helm invocation in the script uses an explicit context
#    (via the kubectl_vso/helm_vso wrappers) -- guard against regressions
#    that call bare `kubectl`/`helm` without going through the wrappers.
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl|helm)[[:space:]]' "$SETUP_VSO" \
  | grep -vE '(kubectl_vso|helm_vso|kubectl_vault|helm_vault)' \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'require_commands|command -v' || true)
if [ -n "$bare_calls" ]; then
  echo "FAIL: found bare kubectl/helm invocation(s) not using the *_vso wrappers:"
  echo "$bare_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every kubectl/helm invocation uses an explicit-context wrapper"
  pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
