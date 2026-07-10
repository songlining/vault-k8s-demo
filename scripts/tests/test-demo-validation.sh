#!/usr/bin/env bash
# scripts/tests/test-demo-validation.sh
#
# Unit tests for demo.sh's preflight/validation logic and static review of
# its kubectl usage:
#   - shell syntax check
#   - missing required commands (kubectl)
#   - missing/unknown VAULT_CONTEXT
#   - every kubectl invocation uses an explicit --context (this is the
#     single-cluster Agent Injector/OTel demo, entirely within the Vault
#     cluster -- it never touches VSO or the VSO cluster)
#
# These tests never run the full guided demo against a real cluster; they
# only exercise the fast-failing preflight path (invalid context) and static
# review of the script contents.
#
# Usage: scripts/tests/test-demo-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEMO="${REPO_ROOT}/demo.sh"

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

# 1. Shell syntax is valid.
if bash -n "$DEMO" 2>/tmp/demo-syntax.err; then
  echo "PASS: demo.sh has valid bash syntax"
  pass=$((pass + 1))
else
  echo "FAIL: demo.sh has a syntax error:"
  sed 's/^/  /' /tmp/demo-syntax.err
  fail=$((fail + 1))
fi

# 2. Missing required command (kubectl) is reported and fails fast.
NO_KUBECTL_DIR="$(mktemp -d)"
trap 'rm -rf "$NO_KUBECTL_DIR"' EXIT
for tool in bash mktemp cat grep sed printf; do
  real_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real_path" ] && ln -sf "$real_path" "${NO_KUBECTL_DIR}/${tool}"
done
assert_fail_contains \
  "missing kubectl is reported" \
  "kubectl" \
  env -i PATH="$NO_KUBECTL_DIR" HOME="$HOME" NO_WAIT=true "$DEMO"

# 3. Missing/unknown VAULT_CONTEXT is reported.
assert_fail_contains \
  "unknown VAULT_CONTEXT is reported" \
  "kubectl context 'definitely-not-a-real-context' not found" \
  env VAULT_CONTEXT=definitely-not-a-real-context NO_WAIT=true "$DEMO"

# --- Static review of demo.sh's contents ------------------------------------

# 4. Every kubectl invocation in the script includes an explicit --context.
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' "$DEMO" \
  | grep -v -- '--context' \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'require_commands|command -v' || true)
if [ -n "$bare_calls" ]; then
  echo "FAIL: found bare kubectl invocation(s) without an explicit --context:"
  echo "$bare_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every kubectl invocation in demo.sh includes an explicit --context"
  pass=$((pass + 1))
fi

# 5. Every --context usage targets ${VAULT_CONTEXT} -- this demo never
#    touches the VSO cluster.
bad_context_calls=$(grep -nE -- '--context ' "$DEMO" \
  | grep -vE -- '--context \$\{VAULT_CONTEXT\}' || true)
if [ -n "$bad_context_calls" ]; then
  echo "FAIL: found --context usage not referencing \${VAULT_CONTEXT}:"
  echo "$bad_context_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every --context usage in demo.sh references \${VAULT_CONTEXT}"
  pass=$((pass + 1))
fi

echo ""
echo "demo.sh validation: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
