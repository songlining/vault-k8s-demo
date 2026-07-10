#!/usr/bin/env bash
# scripts/tests/test-apply-vso-demo-validation.sh
#
# Unit tests for scripts/apply-vso-demo.sh's validation logic and manifest
# content only:
#   - shell syntax check
#   - missing required commands (kubectl/base64)
#   - missing/unknown VAULT_CONTEXT or VSO_CONTEXT
#   - VAULT_CONTEXT == VSO_CONTEXT rejected
#   - unknown flag
#   - happy path (--check-only, no cluster mutation)
#   - manifest review: VaultConnection address is the external VAULT_ADDR
#     (never vault.default.svc.cluster.local), VaultAuth mount/role/service
#     account are correct, VaultStaticSecret path/destination are correct,
#     and the consuming app pod carries no vault.hashicorp.com annotations
#   - every kubectl invocation uses an explicit-context wrapper
#
# These tests never apply real CRDs or mutate any real cluster -- they only
# exercise the fast-failing validation path via `--check-only` and static
# review of the script contents.
#
# Usage: scripts/tests/test-apply-vso-demo-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APPLY_VSO="${REPO_ROOT}/scripts/apply-vso-demo.sh"

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
  if echo "$haystack" | grep -qF "$needle"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected to find: $needle)"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "FAIL: $desc (did not expect to find: $needle)"
    fail=$((fail + 1))
  else
    echo "PASS: $desc"
    pass=$((pass + 1))
  fi
}

# 1. bash syntax check.
assert_success \
  "passes bash -n syntax check" \
  bash -n "$APPLY_VSO"

# 2. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  "$APPLY_VSO" --not-a-real-flag

# 3. Missing required commands (simulate an empty PATH minus bash builtins).
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env PATH=/usr/bin:/bin "$APPLY_VSO" --check-only

# 4. Unknown/missing VAULT_CONTEXT.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vault'" \
  env VAULT_CONTEXT=kind-does-not-exist-vault "$APPLY_VSO" --check-only

# 5. Unknown/missing VSO_CONTEXT.
assert_fail_contains \
  "fails clearly when VSO_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vso'" \
  env VSO_CONTEXT=kind-does-not-exist-vso "$APPLY_VSO" --check-only

# 6. VAULT_CONTEXT == VSO_CONTEXT rejected.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT and VSO_CONTEXT are the same" \
  "must not be the same context" \
  env VAULT_CONTEXT=kind-vault-lab VSO_CONTEXT=kind-vault-lab "$APPLY_VSO" --check-only

# 7. Happy path: real PATH, real contexts (if present), --check-only never
#    touches any cluster.
if command -v kubectl >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vault-lab >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and both contexts are present" \
    "$APPLY_VSO" --check-only
else
  echo "SKIP: happy-path check (kubectl/kind-vault-lab/kind-vso-lab not all available in this environment)"
fi

# 8. Manifest review: read the script contents once for all static checks.
CONTENTS="$(cat "$APPLY_VSO")"

assert_contains \
  "VaultConnection uses the external VAULT_ADDR variable, not a literal in-cluster DNS name" \
  "$CONTENTS" 'address: ${VAULT_ADDR}'

MANIFEST_CONTENTS="$(grep -vE '^\s*#' "$APPLY_VSO")"
assert_not_contains \
  "VaultConnection never hardcodes the same-cluster Vault DNS name outside of comments" \
  "$MANIFEST_CONTENTS" 'address: http://vault.default.svc.cluster.local'

assert_contains \
  "VaultAuth uses method: jwt" \
  "$CONTENTS" 'method: jwt'

assert_contains \
  "VaultAuth uses the dedicated cross-cluster JWT auth mount variable" \
  "$CONTENTS" 'mount: ${VSO_JWT_AUTH_MOUNT}'

assert_contains \
  "VaultAuth jwt.role uses the VSO_JWT_AUTH_ROLE variable" \
  "$CONTENTS" 'role: ${VSO_JWT_AUTH_ROLE}'

assert_contains \
  "VaultAuth jwt.serviceAccount binds the vso-demo service account" \
  "$CONTENTS" 'serviceAccount: vso-demo'

assert_contains \
  "VaultAuth jwt.audiences block is present" \
  "$CONTENTS" 'audiences:'

assert_contains \
  "VaultAuth jwt.audiences uses the VSO_JWT_AUDIENCE variable" \
  "$CONTENTS" '${VSO_JWT_AUDIENCE}'

assert_contains \
  "VaultAuth jwt.tokenExpirationSeconds is set to a short bounded value" \
  "$CONTENTS" 'tokenExpirationSeconds: 600'

VAULTAUTH_MANIFEST="$(awk '/^kind: VaultAuth$/,/^---$/' "$APPLY_VSO")"
assert_not_contains \
  "VaultAuth manifest no longer contains the old kubernetes: auth stanza" \
  "$VAULTAUTH_MANIFEST" 'kubernetes:'

assert_not_contains \
  "VaultAuth manifest does not use method: kubernetes" \
  "$VAULTAUTH_MANIFEST" 'method: kubernetes'

assert_contains \
  "VaultStaticSecret reads from kv-v2/vault-demo/mysecret" \
  "$CONTENTS" 'path: vault-demo/mysecret'

assert_contains \
  "VaultStaticSecret destination uses the SECRET_NAME variable" \
  "$CONTENTS" 'name: ${SECRET_NAME}'

# 9. The consuming app pod manifest block must carry no Vault annotations
#    and only one container. Extract the pod manifest between its `kind:
#    Pod` marker for the app and the following heredoc terminator.
APP_POD_MANIFEST="$(awk '/name: \$\{APP_POD\}/,/^EOF$/' "$APPLY_VSO")"

assert_not_contains \
  "consuming app pod manifest has no vault.hashicorp.com annotations" \
  "$APP_POD_MANIFEST" 'vault.hashicorp.com'

assert_contains \
  "consuming app pod manifest uses envFrom to consume the native Secret" \
  "$APP_POD_MANIFEST" 'envFrom'

CONTAINER_COUNT=$(echo "$APP_POD_MANIFEST" | grep -c '^\s*- name:' || true)
if [ "$CONTAINER_COUNT" -eq 1 ]; then
  echo "PASS: consuming app pod manifest defines exactly one container"
  pass=$((pass + 1))
else
  echo "FAIL: consuming app pod manifest defines ${CONTAINER_COUNT} containers, expected 1"
  fail=$((fail + 1))
fi

# 10. Every kubectl invocation in the script uses an explicit context (via
#     the kubectl_vso/kubectl_vault wrappers) -- guard against regressions
#     that call bare `kubectl` without going through the wrappers.
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' "$APPLY_VSO" \
  | grep -vE '(kubectl_vso|kubectl_vault)' \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE '^[0-9]+:\s*echo ' \
  | grep -vE 'require_commands|command -v' || true)
if [ -n "$bare_calls" ]; then
  echo "FAIL: found bare kubectl invocation(s) not using an explicit-context wrapper:"
  echo "$bare_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every kubectl invocation uses an explicit-context wrapper"
  pass=$((pass + 1))
fi

# 11. No VSO CRD kinds are ever applied against the Vault cluster (i.e. no
#     kubectl_vault call anywhere near a VaultConnection/VaultAuth/
#     VaultStaticSecret block).
if grep -qE 'kubectl_vault.*(VaultConnection|VaultAuth|VaultStaticSecret)' "$APPLY_VSO"; then
  echo "FAIL: found a VSO CRD apparently applied via kubectl_vault (Vault cluster)"
  fail=$((fail + 1))
else
  echo "PASS: no VSO CRDs are applied via kubectl_vault (Vault cluster)"
  pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
