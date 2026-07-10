#!/usr/bin/env bash
# scripts/tests/test-two-cluster-env-validation.sh
#
# Unit tests for scripts/lib/two-cluster-env.sh's JWT/OIDC environment
# defaults (VSO_JWT_AUTH_MOUNT, VSO_JWT_AUTH_ROLE, VSO_JWT_AUDIENCE,
# VSO_OIDC_ISSUER, VSO_OIDC_JWKS_URL), added for the vso-jwt-oidc-auth
# migration (see docs/vso-jwt-oidc-auth-plan.md Phase 3,
# tasks/vso-jwt-oidc-auth/03-add-jwt-oidc-env-defaults.md).
#
# Covers:
#   - bash -n syntax check (this file is sourced, not executed, elsewhere).
#   - default values for the new JWT/OIDC variables in a clean shell.
#   - override behavior via environment variables.
#   - the pre-existing Kubernetes-auth variables (VSO_AUTH_MOUNT,
#     VSO_AUTH_ROLE, VAULT_TOKEN_REVIEWER_SA) remain available unchanged,
#     for migration compatibility.
#   - print_two_cluster_env() includes all five new variables.
#   - sourcing under `set -euo pipefail` never trips on an unbound variable.
#
# This never touches a live cluster -- it only sources the library in
# subshells with controlled environments.
#
# Usage: scripts/tests/test-two-cluster-env-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_LIB="${REPO_ROOT}/scripts/lib/two-cluster-env.sh"

pass=0
fail=0

check() {
  local desc="$1" cond="$2"
  if [ "$cond" -eq 0 ]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc"
    fail=$((fail + 1))
  fi
}

assert_var_eq() {
  # assert_var_eq <description> <actual> <expected>
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    check "$desc" 0
  else
    echo "  expected: $expected"
    echo "  actual:   $actual"
    check "$desc" 1
  fi
}

# 1. bash syntax check.
if bash -n "$ENV_LIB" >/dev/null 2>&1; then
  check "two-cluster-env.sh passes bash -n syntax check" 0
else
  check "two-cluster-env.sh passes bash -n syntax check" 1
fi

# --------------------------------------------------------------------------
# 2. Defaults: source in a clean environment (unset every JWT/OIDC and
#    legacy Kubernetes-auth variable first, so a leaked value from the
#    calling shell can't mask a missing default).
# --------------------------------------------------------------------------
DEFAULTS_OUTPUT="$(
  env -u VSO_JWT_AUTH_MOUNT -u VSO_JWT_AUTH_ROLE -u VSO_JWT_AUDIENCE \
      -u VSO_OIDC_ISSUER -u VSO_OIDC_JWKS_URL \
      -u VSO_AUTH_MOUNT -u VSO_AUTH_ROLE -u VAULT_TOKEN_REVIEWER_SA \
      -u VSO_API_ADDR -u TWO_CLUSTER_HOST -u VSO_API_HOST_PORT \
    bash -c "set -euo pipefail; source '$ENV_LIB'; print_two_cluster_env"
)"

get_default() {
  # get_default <VAR_NAME>
  printf '%s\n' "$DEFAULTS_OUTPUT" | sed -n "s/^$1=//p"
}

assert_var_eq "default VSO_JWT_AUTH_MOUNT is 'jwt-vso'" \
  "$(get_default VSO_JWT_AUTH_MOUNT)" "jwt-vso"

assert_var_eq "default VSO_JWT_AUTH_ROLE is 'vso-demo'" \
  "$(get_default VSO_JWT_AUTH_ROLE)" "vso-demo"

assert_var_eq "default VSO_JWT_AUDIENCE is 'vault'" \
  "$(get_default VSO_JWT_AUDIENCE)" "vault"

assert_var_eq "default VSO_OIDC_ISSUER matches the default kind service account issuer" \
  "$(get_default VSO_OIDC_ISSUER)" "https://kubernetes.default.svc.cluster.local"

assert_var_eq "default VSO_OIDC_JWKS_URL is derived from VSO_API_ADDR" \
  "$(get_default VSO_OIDC_JWKS_URL)" "https://host.containers.internal:6444/openid/v1/jwks"

# Legacy Kubernetes-auth variables must still default correctly (migration
# compatibility -- task 03 must not remove or change these).
assert_var_eq "legacy VSO_AUTH_MOUNT default is unchanged ('kubernetes-vso')" \
  "$(get_default VSO_AUTH_MOUNT)" "kubernetes-vso"

assert_var_eq "legacy VSO_AUTH_ROLE default is unchanged ('vso-demo')" \
  "$(get_default VSO_AUTH_ROLE)" "vso-demo"

# --------------------------------------------------------------------------
# 3. Overrides: every new JWT/OIDC variable can be overridden from the
#    environment (the same mechanism Make command-line overrides use).
# --------------------------------------------------------------------------
OVERRIDES_OUTPUT="$(
  env \
    VSO_JWT_AUTH_MOUNT="jwt-override" \
    VSO_JWT_AUTH_ROLE="role-override" \
    VSO_JWT_AUDIENCE="aud-override" \
    VSO_OIDC_ISSUER="https://issuer.override.example" \
    VSO_OIDC_JWKS_URL="https://jwks.override.example/keys" \
    bash -c "set -euo pipefail; source '$ENV_LIB'; print_two_cluster_env"
)"

get_override() {
  printf '%s\n' "$OVERRIDES_OUTPUT" | sed -n "s/^$1=//p"
}

assert_var_eq "VSO_JWT_AUTH_MOUNT override is preserved" \
  "$(get_override VSO_JWT_AUTH_MOUNT)" "jwt-override"

assert_var_eq "VSO_JWT_AUTH_ROLE override is preserved" \
  "$(get_override VSO_JWT_AUTH_ROLE)" "role-override"

assert_var_eq "VSO_JWT_AUDIENCE override is preserved" \
  "$(get_override VSO_JWT_AUDIENCE)" "aud-override"

assert_var_eq "VSO_OIDC_ISSUER override is preserved" \
  "$(get_override VSO_OIDC_ISSUER)" "https://issuer.override.example"

assert_var_eq "VSO_OIDC_JWKS_URL override is preserved" \
  "$(get_override VSO_OIDC_JWKS_URL)" "https://jwks.override.example/keys"

# --------------------------------------------------------------------------
# 4. print_two_cluster_env() output includes all five new JWT/OIDC keys.
# --------------------------------------------------------------------------
for key in VSO_JWT_AUTH_MOUNT VSO_JWT_AUTH_ROLE VSO_JWT_AUDIENCE VSO_OIDC_ISSUER VSO_OIDC_JWKS_URL; do
  if printf '%s\n' "$DEFAULTS_OUTPUT" | grep -q "^${key}="; then
    check "print_two_cluster_env() includes $key" 0
  else
    check "print_two_cluster_env() includes $key" 1
  fi
done

# --------------------------------------------------------------------------
# 5. Sourcing under `set -euo pipefail` with no environment at all (aside
#    from what source_env inherits) never trips "unbound variable" for the
#    new variables -- proves downstream scripts can source this file and
#    immediately reference the new variables without errors.
# --------------------------------------------------------------------------
UNBOUND_CHECK_OUTPUT=""
UNBOUND_CHECK_STATUS=0
UNBOUND_CHECK_OUTPUT="$(
  env -u VSO_JWT_AUTH_MOUNT -u VSO_JWT_AUTH_ROLE -u VSO_JWT_AUDIENCE \
      -u VSO_OIDC_ISSUER -u VSO_OIDC_JWKS_URL \
    bash -c "
      set -euo pipefail
      source '$ENV_LIB'
      echo \"mount=\${VSO_JWT_AUTH_MOUNT}\"
      echo \"role=\${VSO_JWT_AUTH_ROLE}\"
      echo \"audience=\${VSO_JWT_AUDIENCE}\"
      echo \"issuer=\${VSO_OIDC_ISSUER}\"
      echo \"jwks=\${VSO_OIDC_JWKS_URL}\"
    " 2>&1
)" || UNBOUND_CHECK_STATUS=$?

if [ "$UNBOUND_CHECK_STATUS" -eq 0 ] && ! printf '%s\n' "$UNBOUND_CHECK_OUTPUT" | grep -qi "unbound variable"; then
  check "downstream scripts can reference new JWT/OIDC vars under set -euo pipefail without unbound-variable errors" 0
else
  echo "$UNBOUND_CHECK_OUTPUT" | sed 's/^/  /'
  check "downstream scripts can reference new JWT/OIDC vars under set -euo pipefail without unbound-variable errors" 1
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
