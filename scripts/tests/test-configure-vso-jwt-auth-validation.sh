#!/usr/bin/env bash
# scripts/tests/test-configure-vso-jwt-auth-validation.sh
#
# Unit tests for scripts/configure-vso-jwt-auth.sh's validation logic and
# static safety properties only:
#   - shell syntax check
#   - missing required commands (kubectl/base64)
#   - missing/unknown VAULT_CONTEXT or VSO_CONTEXT
#   - VAULT_CONTEXT == VSO_CONTEXT rejected
#   - unknown flag
#   - happy path (--check-only, no cluster mutation)
#   - static safety review:
#       * script never writes token_reviewer_jwt (this mount has no
#         reviewer identity at all -- the whole point of JWT/OIDC auth)
#       * role write includes bound_audiences and bound_subject (strict
#         claim binding, not just issuer/audience alone)
#       * bound_subject is the exact vso-demo/vso-demo subject
#       * script enables a Vault `jwt` auth method, not `kubernetes`
#       * script never disables an auth mount
#       * script never touches the same-cluster auth/kubernetes/ mount or
#         the migration-compatibility auth/kubernetes-vso/ mount directly
#       * every live-cluster kubectl invocation uses an explicit-context
#         wrapper (kubectl_vault/kubectl_vso), except the one intentional
#         context-agnostic `kubectl config view` CA read
#
# These tests never configure a real Vault -- they only exercise the
# fast-failing validation path via `--check-only` and static review of the
# script contents.
#
# Usage: scripts/tests/test-configure-vso-jwt-auth-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIGURE_JWT_AUTH="${REPO_ROOT}/scripts/configure-vso-jwt-auth.sh"

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
  bash -n "$CONFIGURE_JWT_AUTH"

# 2. Unknown flag.
assert_fail_contains \
  "fails clearly on an unrecognized flag" \
  "unknown argument" \
  "$CONFIGURE_JWT_AUTH" --not-a-real-flag

# 3. Missing required commands (simulate an empty PATH minus bash builtins).
assert_fail_contains \
  "fails clearly when required commands are missing from PATH" \
  "required command" \
  env PATH=/usr/bin:/bin "$CONFIGURE_JWT_AUTH" --check-only

# 4. Unknown/missing VAULT_CONTEXT.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vault'" \
  env VAULT_CONTEXT=kind-does-not-exist-vault "$CONFIGURE_JWT_AUTH" --check-only

# 5. Unknown/missing VSO_CONTEXT.
assert_fail_contains \
  "fails clearly when VSO_CONTEXT does not exist" \
  "context 'kind-does-not-exist-vso'" \
  env VSO_CONTEXT=kind-does-not-exist-vso "$CONFIGURE_JWT_AUTH" --check-only

# 6. VAULT_CONTEXT == VSO_CONTEXT rejected.
assert_fail_contains \
  "fails clearly when VAULT_CONTEXT and VSO_CONTEXT are the same" \
  "must not be the same context" \
  env VAULT_CONTEXT=kind-same VSO_CONTEXT=kind-same "$CONFIGURE_JWT_AUTH" --check-only

# 7. Happy path: real PATH, real contexts (if present), --check-only never
#    touches any cluster.
if command -v kubectl >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vault-lab >/dev/null 2>&1 \
    && kubectl config get-contexts kind-vso-lab >/dev/null 2>&1; then
  assert_success \
    "--check-only succeeds when tools and both contexts are present" \
    "$CONFIGURE_JWT_AUTH" --check-only
else
  echo "SKIP: happy-path check (kubectl/kind-vault-lab/kind-vso-lab not all available in this environment)"
fi

# --- Static safety review ----------------------------------------------------

# 8. The script must never write token_reviewer_jwt: JWT/OIDC auth has no
#    reviewer identity, unlike the TokenReview-based auth/kubernetes-vso
#    mount. This is the core acceptance criterion of this feature. Only
#    an actual `key=value` write argument counts -- comments and the
#    completion message are expected to mention the term to explain its
#    absence.
if grep -E 'token_reviewer_jwt=' "$CONFIGURE_JWT_AUTH" | grep -vE '^[[:space:]]*#' >/dev/null; then
  echo "FAIL: script writes token_reviewer_jwt=... (JWT/OIDC auth must not store a reviewer JWT)"
  fail=$((fail + 1))
else
  echo "PASS: script never writes token_reviewer_jwt"
  pass=$((pass + 1))
fi

# 9. The role write must bind bound_audiences (not just issuer/subject).
if grep -qE 'bound_audiences=' "$CONFIGURE_JWT_AUTH"; then
  echo "PASS: role write includes bound_audiences"
  pass=$((pass + 1))
else
  echo "FAIL: role write is missing bound_audiences"
  fail=$((fail + 1))
fi

# 10. The role write must bind bound_subject (not just issuer/audience).
if grep -qE 'bound_subject=' "$CONFIGURE_JWT_AUTH"; then
  echo "PASS: role write includes bound_subject"
  pass=$((pass + 1))
else
  echo "FAIL: role write is missing bound_subject"
  fail=$((fail + 1))
fi

# 11. bound_subject must resolve to the exact vso-demo/vso-demo subject
#     string (system:serviceaccount:<namespace>:vso-demo), not a loose
#     pattern.
if grep -qE 'VSO_JWT_BOUND_SUBJECT="system:serviceaccount:\$\{VSO_NAMESPACE\}:vso-demo"' "$CONFIGURE_JWT_AUTH"; then
  echo "PASS: bound_subject is the exact system:serviceaccount:<namespace>:vso-demo subject"
  pass=$((pass + 1))
else
  echo "FAIL: bound_subject does not construct the exact vso-demo/vso-demo subject string"
  fail=$((fail + 1))
fi

# 12. The role write must set role_type=jwt and user_claim=sub, per the
#     task spec's exact required role attributes.
if grep -qE 'role_type=jwt' "$CONFIGURE_JWT_AUTH" && grep -qE 'user_claim=sub' "$CONFIGURE_JWT_AUTH"; then
  echo "PASS: role write sets role_type=jwt and user_claim=sub"
  pass=$((pass + 1))
else
  echo "FAIL: role write is missing role_type=jwt and/or user_claim=sub"
  fail=$((fail + 1))
fi

# 13. The script must enable a Vault `jwt` auth method (not `kubernetes`).
if grep -qE 'vault auth enable -path="\$\{VSO_JWT_AUTH_MOUNT\}".*$' "$CONFIGURE_JWT_AUTH" \
    && grep -A1 'vault auth enable -path="\${VSO_JWT_AUTH_MOUNT}"' "$CONFIGURE_JWT_AUTH" | grep -qE '(^|[^_a-zA-Z-])jwt([^_a-zA-Z-]|$)'; then
  echo "PASS: script enables the Vault jwt auth method on auth/\${VSO_JWT_AUTH_MOUNT}"
  pass=$((pass + 1))
else
  echo "FAIL: could not confirm script enables the Vault jwt auth method on auth/\${VSO_JWT_AUTH_MOUNT}"
  fail=$((fail + 1))
fi

# 14. The script must never disable or delete an auth mount.
if grep -qE 'vault auth disable' "$CONFIGURE_JWT_AUTH"; then
  echo "FAIL: script contains a destructive 'vault auth disable' call"
  fail=$((fail + 1))
else
  echo "PASS: script never disables an auth mount"
  pass=$((pass + 1))
fi

# 15. The script must never reference the same-cluster auth/kubernetes/
#     mount, nor the migration-compatibility auth/kubernetes-vso/ mount,
#     directly.
if grep -qE '"auth/kubernetes/' "$CONFIGURE_JWT_AUTH" || grep -qE "'auth/kubernetes/" "$CONFIGURE_JWT_AUTH"; then
  echo "FAIL: script references the same-cluster auth/kubernetes/ mount directly"
  fail=$((fail + 1))
else
  echo "PASS: script never references the same-cluster auth/kubernetes/ mount directly"
  pass=$((pass + 1))
fi

if grep -qE '"auth/kubernetes-vso/' "$CONFIGURE_JWT_AUTH" || grep -qE "'auth/kubernetes-vso/" "$CONFIGURE_JWT_AUTH"; then
  echo "FAIL: script references the migration-compatibility auth/kubernetes-vso/ mount directly (should only touch auth/\${VSO_JWT_AUTH_MOUNT})"
  fail=$((fail + 1))
else
  echo "PASS: script never references the migration-compatibility auth/kubernetes-vso/ mount directly"
  pass=$((pass + 1))
fi

# 16. The script must never use oidc_discovery_url (Phase 1 spike decision:
#     jwks_url only), and must use jwks_url + bound_issuer. Only
#     non-comment lines count -- explanatory comments contrasting this
#     script with the not-chosen oidc_discovery_url mode are expected to
#     mention the term.
if grep -vE '^[[:space:]]*#' "$CONFIGURE_JWT_AUTH" | grep -q 'oidc_discovery_url'; then
  echo "FAIL: script writes oidc_discovery_url outside of comments (spike 01 decision requires jwks_url only)"
  fail=$((fail + 1))
else
  echo "PASS: script never writes oidc_discovery_url"
  pass=$((pass + 1))
fi

if grep -qE 'jwks_url="\$\{VSO_OIDC_JWKS_URL\}"' "$CONFIGURE_JWT_AUTH" \
    && grep -qE 'bound_issuer="\$\{VSO_OIDC_ISSUER\}"' "$CONFIGURE_JWT_AUTH"; then
  echo "PASS: config write uses jwks_url + bound_issuer from shared env defaults"
  pass=$((pass + 1))
else
  echo "FAIL: config write does not use both jwks_url and bound_issuer from shared env defaults"
  fail=$((fail + 1))
fi

# 17. The verification summary must not print CA/JWKS pubkey material. Use
#     a JSON-aware filter (jq del()) rather than a line-based grep, since
#     multi-line PEM values are not prefixed per-line in plain-text `vault
#     read` output and a naive grep would leak continuation lines.
if grep -qE "jq 'del\(.data.jwks_ca_pem" "$CONFIGURE_JWT_AUTH"; then
  echo "PASS: verification read uses jq del() to filter jwks_ca_pem/jwt_validation_pubkeys/oidc_discovery_ca_pem before printing"
  pass=$((pass + 1))
else
  echo "FAIL: verification read does not appear to filter sensitive config fields before printing"
  fail=$((fail + 1))
fi

# 18. Every kubectl invocation in the script uses an explicit-context
#     wrapper (kubectl_vault/kubectl_vso), except the one intentional use
#     of raw `kubectl config view` to read the VSO cluster's CA from the
#     local kubeconfig (context-agnostic by design).
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' "$CONFIGURE_JWT_AUTH" \
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
