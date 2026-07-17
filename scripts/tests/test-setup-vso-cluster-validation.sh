#!/usr/bin/env bash
# scripts/tests/test-setup-vso-cluster-validation.sh
#
# Unit tests for scripts/setup-vso-cluster.sh's validation logic only:
#   - missing required commands (kubectl/helm)
#   - missing/unknown VSO_CONTEXT
#   - unknown flag
#   - happy path (--check-only, no cluster mutation)
#   - static safety review:
#       * the legacy TokenReview reviewer identity (vault-token-reviewer SA +
#         system:auth-delegator ClusterRoleBinding) is not created unless
#         ENABLE_TOKEN_REVIEWER_AUTH=1 is explicitly set
#       * the oidc-discovery-reader ClusterRole/ClusterRoleBinding (needed
#         by the default JWT/OIDC auth path) is created unconditionally
#       * the vso-demo namespace and service account are still created
#         unconditionally
#       * every live-cluster kubectl/helm invocation uses an explicit
#         context wrapper
#
# These tests never install the operator or mutate any real cluster -- they
# only exercise the fast-failing validation path via `--check-only` and
# static review of the script contents.
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

# --- Static safety review ---------------------------------------------------

# 7. The legacy TokenReview reviewer identity default must be off
#    (ENABLE_TOKEN_REVIEWER_AUTH defaults to 0), and both the reviewer
#    ServiceAccount and the system:auth-delegator ClusterRoleBinding must
#    only be emitted inside a guard on that variable being "1" -- never
#    unconditionally.
if grep -qE 'ENABLE_TOKEN_REVIEWER_AUTH="\$\{ENABLE_TOKEN_REVIEWER_AUTH:-0\}"' "$SETUP_VSO"; then
  echo "PASS: ENABLE_TOKEN_REVIEWER_AUTH defaults to 0 (off)"
  pass=$((pass + 1))
else
  echo "FAIL: ENABLE_TOKEN_REVIEWER_AUTH is not declared with a default of 0"
  fail=$((fail + 1))
fi

if grep -qE 'if \[ "\$ENABLE_TOKEN_REVIEWER_AUTH" = "1" \]; then' "$SETUP_VSO"; then
  echo "PASS: script gates the legacy TokenReview reviewer identity behind an explicit ENABLE_TOKEN_REVIEWER_AUTH=1 check"
  pass=$((pass + 1))
else
  echo "FAIL: script does not appear to gate the legacy TokenReview reviewer identity behind ENABLE_TOKEN_REVIEWER_AUTH"
  fail=$((fail + 1))
fi

# 8. The reviewer ServiceAccount manifest (kind: ServiceAccount, name:
#    ${VAULT_TOKEN_REVIEWER_SA}) and the system:auth-delegator
#    ClusterRoleBinding must appear strictly between the
#    ENABLE_TOKEN_REVIEWER_AUTH guard's `if` and its closing `fi`/`else`,
#    not before it (i.e. not unconditionally created earlier in the
#    script).
guard_line=$(grep -n 'if \[ "\$ENABLE_TOKEN_REVIEWER_AUTH" = "1" \]; then' "$SETUP_VSO" | head -1 | cut -d: -f1)
reviewer_sa_line=$(grep -n 'name: \${VAULT_TOKEN_REVIEWER_SA}' "$SETUP_VSO" | head -1 | cut -d: -f1)
auth_delegator_line=$(grep -n 'name: system:auth-delegator' "$SETUP_VSO" | head -1 | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$reviewer_sa_line" ] && [ -n "$auth_delegator_line" ] \
    && [ "$reviewer_sa_line" -gt "$guard_line" ] && [ "$auth_delegator_line" -gt "$guard_line" ]; then
  echo "PASS: reviewer ServiceAccount and system:auth-delegator ClusterRoleBinding are declared after (inside) the ENABLE_TOKEN_REVIEWER_AUTH guard"
  pass=$((pass + 1))
else
  echo "FAIL: could not confirm the reviewer ServiceAccount/ClusterRoleBinding are declared inside the ENABLE_TOKEN_REVIEWER_AUTH guard"
  echo "  guard_line=${guard_line:-<none>} reviewer_sa_line=${reviewer_sa_line:-<none>} auth_delegator_line=${auth_delegator_line:-<none>}"
  fail=$((fail + 1))
fi

# 9. The vso-demo namespace and service account must still be created
#    unconditionally (before/outside the ENABLE_TOKEN_REVIEWER_AUTH guard).
vso_demo_sa_line=$(grep -n 'name: vso-demo$' "$SETUP_VSO" | head -1 | cut -d: -f1)
namespace_line=$(grep -n 'kind: Namespace' "$SETUP_VSO" | head -1 | cut -d: -f1)
if [ -n "$vso_demo_sa_line" ] && [ -n "$namespace_line" ] \
    && { [ -z "$guard_line" ] || { [ "$vso_demo_sa_line" -lt "$guard_line" ] && [ "$namespace_line" -lt "$guard_line" ]; }; }; then
  echo "PASS: vso-demo namespace and service account are created unconditionally"
  pass=$((pass + 1))
else
  echo "FAIL: vso-demo namespace/service account are missing or unexpectedly gated"
  fail=$((fail + 1))
fi

# 10. The oidc-discovery-reader ClusterRole/ClusterRoleBinding (required by
#     the default JWT/OIDC auth path to let Vault fetch JWKS/discovery
#     unauthenticated) must be created unconditionally, not gated behind
#     ENABLE_TOKEN_REVIEWER_AUTH.
oidc_role_line=$(grep -n 'name: oidc-discovery-reader$' "$SETUP_VSO" | head -1 | cut -d: -f1)
oidc_binding_line=$(grep -n 'name: oidc-discovery-reader-binding' "$SETUP_VSO" | head -1 | cut -d: -f1)
if [ -n "$oidc_role_line" ] && [ -n "$oidc_binding_line" ] \
    && { [ -z "$guard_line" ] || { [ "$oidc_role_line" -lt "$guard_line" ] && [ "$oidc_binding_line" -lt "$guard_line" ]; }; }; then
  echo "PASS: oidc-discovery-reader ClusterRole/ClusterRoleBinding are created unconditionally (default JWT/OIDC path)"
  pass=$((pass + 1))
else
  echo "FAIL: oidc-discovery-reader ClusterRole/ClusterRoleBinding are missing or unexpectedly gated"
  fail=$((fail + 1))
fi

OIDC_RBAC_BLOCK=$(awk '
  /name: oidc-discovery-reader$/ { in_role=1 }
  in_role { print }
  in_role && /^---$/ { exit }
' "$SETUP_VSO")
if printf '%s\n' "$OIDC_RBAC_BLOCK" | grep -qF -- '- /.well-known/openid-configuration' \
    && printf '%s\n' "$OIDC_RBAC_BLOCK" | grep -qF -- '- /openid/v1/jwks'; then
  echo "PASS: discovery RBAC grants both discovery metadata and JWKS paths"
  pass=$((pass + 1))
else
  echo "FAIL: discovery RBAC must grant both exact OIDC endpoint paths"
  fail=$((fail + 1))
fi

OIDC_PATH_COUNT=$(printf '%s\n' "$OIDC_RBAC_BLOCK" | grep -cE '^[[:space:]]+- /' || true)
if [ "$OIDC_PATH_COUNT" -eq 2 ] && ! printf '%s\n' "$OIDC_RBAC_BLOCK" | grep -q '\*'; then
  echo "PASS: discovery RBAC is limited to exactly two non-resource URLs with no wildcard"
  pass=$((pass + 1))
else
  echo "FAIL: discovery RBAC is broader than the two required non-resource URLs"
  fail=$((fail + 1))
fi

# 11. Live-cluster proof (best-effort, non-mutating): if the VSO cluster's
#     vso-demo namespace already exists from a previous default (non-legacy)
#     run, the vault-token-reviewer service account should not be present.
if command -v kubectl >/dev/null 2>&1 && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1 \
    && kubectl --context kind-vso-lab get namespace vso-demo >/dev/null 2>&1; then
  if kubectl --context kind-vso-lab get serviceaccount vault-token-reviewer -n vso-demo >/dev/null 2>&1; then
    echo "NOTE: live cluster has a 'vault-token-reviewer' SA in vso-demo (likely from a prior ENABLE_TOKEN_REVIEWER_AUTH=1 run or older setup) -- not treated as a failure, just informational."
  else
    echo "PASS: live vso-demo namespace has no 'vault-token-reviewer' service account"
    pass=$((pass + 1))
  fi
  if kubectl --context kind-vso-lab get serviceaccount vso-demo -n vso-demo >/dev/null 2>&1; then
    echo "PASS: live vso-demo namespace has the 'vso-demo' service account"
    pass=$((pass + 1))
  else
    echo "FAIL: live vso-demo namespace is missing the 'vso-demo' service account"
    fail=$((fail + 1))
  fi
else
  echo "SKIP: live-cluster proof (kind-vso-lab context/vso-demo namespace not available in this environment)"
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
