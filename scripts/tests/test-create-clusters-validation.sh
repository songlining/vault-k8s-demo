#!/usr/bin/env bash
# scripts/tests/test-create-clusters-validation.sh
#
# Unit tests for scripts/create-clusters.sh's validation logic only:
#   - missing required commands (kind/kubectl/podman)
#   - missing KIND_EXPERIMENTAL_PROVIDER=podman
#   - happy path (--check-only, no cluster mutation)
#
# These tests never create or touch real kind/podman clusters — they only
# exercise the fast-failing validation path via `--check-only`.
#
# Usage: scripts/tests/test-create-clusters-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CREATE_CLUSTERS="${REPO_ROOT}/scripts/create-clusters.sh"

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

# 1. Missing KIND_EXPERIMENTAL_PROVIDER entirely.
assert_fail_contains \
  "fails clearly when KIND_EXPERIMENTAL_PROVIDER is unset" \
  "KIND_EXPERIMENTAL_PROVIDER=podman is not set" \
  env -u KIND_EXPERIMENTAL_PROVIDER "$CREATE_CLUSTERS" --check-only

# 2. KIND_EXPERIMENTAL_PROVIDER set to the wrong value.
assert_fail_contains \
  "fails clearly when KIND_EXPERIMENTAL_PROVIDER is not 'podman'" \
  "KIND_EXPERIMENTAL_PROVIDER=podman is not set" \
  env KIND_EXPERIMENTAL_PROVIDER=docker "$CREATE_CLUSTERS" --check-only

# 3. Missing required commands (simulate an empty PATH minus bash builtins).
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env KIND_EXPERIMENTAL_PROVIDER=podman PATH=/usr/bin:/bin "$CREATE_CLUSTERS" --check-only

# 4. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  env KIND_EXPERIMENTAL_PROVIDER=podman "$CREATE_CLUSTERS" --not-a-real-flag

# 5. Happy path: real PATH, provider set, --check-only never touches clusters.
if command -v kind >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and provider are present" \
    env KIND_EXPERIMENTAL_PROVIDER=podman "$CREATE_CLUSTERS" --check-only
else
  echo "SKIP: happy-path check (kind/kubectl/podman not all installed in this environment)"
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
