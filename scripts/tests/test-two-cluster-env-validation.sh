#!/usr/bin/env bash
# scripts/tests/test-two-cluster-env-validation.sh
#
# Unit tests for scripts/lib/two-cluster-env.sh's JWT/OIDC environment
# defaults (VSO_JWT_AUTH_MOUNT, VSO_JWT_AUTH_ROLE, VSO_JWT_AUDIENCE,
# VSO_OIDC_DISCOVERY_URL, VSO_OIDC_ISSUER, VSO_OIDC_JWKS_URL), added for the vso-jwt-oidc-auth
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
      -u VSO_OIDC_DISCOVERY_URL -u VSO_OIDC_ISSUER -u VSO_OIDC_JWKS_URL \
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

assert_var_eq "default VSO_OIDC_DISCOVERY_URL is the externally reachable VSO API address" \
  "$(get_default VSO_OIDC_DISCOVERY_URL)" "https://host.containers.internal:6444"

assert_var_eq "default VSO_OIDC_ISSUER is derived from the discovery URL" \
  "$(get_default VSO_OIDC_ISSUER)" "https://host.containers.internal:6444"

assert_var_eq "default VSO_OIDC_JWKS_URL is derived from the discovery URL" \
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
    VSO_OIDC_DISCOVERY_URL="https://discovery.override.example" \
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

assert_var_eq "VSO_OIDC_DISCOVERY_URL override is preserved" \
  "$(get_override VSO_OIDC_DISCOVERY_URL)" "https://discovery.override.example"

assert_var_eq "VSO_OIDC_ISSUER override is preserved" \
  "$(get_override VSO_OIDC_ISSUER)" "https://issuer.override.example"

assert_var_eq "VSO_OIDC_JWKS_URL override is preserved" \
  "$(get_override VSO_OIDC_JWKS_URL)" "https://jwks.override.example/keys"

# --------------------------------------------------------------------------
# 4. print_two_cluster_env() output includes all six JWT/OIDC keys.
# --------------------------------------------------------------------------
for key in VSO_JWT_AUTH_MOUNT VSO_JWT_AUTH_ROLE VSO_JWT_AUDIENCE VSO_OIDC_DISCOVERY_URL VSO_OIDC_ISSUER VSO_OIDC_JWKS_URL; do
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
      -u VSO_OIDC_DISCOVERY_URL -u VSO_OIDC_ISSUER -u VSO_OIDC_JWKS_URL \
    bash -c "
      set -euo pipefail
      source '$ENV_LIB'
      echo \"mount=\${VSO_JWT_AUTH_MOUNT}\"
      echo \"role=\${VSO_JWT_AUTH_ROLE}\"
      echo \"audience=\${VSO_JWT_AUDIENCE}\"
      echo \"discovery=\${VSO_OIDC_DISCOVERY_URL}\"
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

if env TWO_CLUSTER_HOST=identity.example VSO_API_HOST_PORT=7443 \
    VSO_API_ADDR=https://identity.example:7443 \
    VSO_OIDC_DISCOVERY_URL=https://identity.example:7443 \
    VSO_OIDC_ISSUER=https://identity.example:7443 \
    VSO_OIDC_JWKS_URL=https://identity.example:7443/openid/v1/jwks \
    bash -c "source '$ENV_LIB'; validate_vso_oidc_env"; then
  check "coherent host/port and derived OIDC overrides pass consistency validation" 0
else
  check "coherent host/port and derived OIDC overrides pass consistency validation" 1
fi

if env TWO_CLUSTER_HOST=identity.example VSO_API_HOST_PORT=7443 \
    VSO_API_ADDR=https://stale.example:6444 \
    bash -c "source '$ENV_LIB'; validate_vso_oidc_env" >/dev/null 2>&1; then
  check "inconsistent derived VSO API/OIDC values are rejected" 1
else
  check "inconsistent derived VSO API/OIDC values are rejected" 0
fi

# --------------------------------------------------------------------------
# 6. Auth-delegator (client JWT self-review) scenario defaults, added for
#    docs/vso-kubernetes-auth-delegator-plan.md.
# --------------------------------------------------------------------------

AUTH_DELEGATOR_DEFAULTS_OUTPUT="$(
  env -u AUTH_DELEGATOR_AUTH_NAMESPACE -u AUTH_DELEGATOR_APP_NAMESPACE \
      -u AUTH_DELEGATOR_SELF_REVIEW_SA -u AUTH_DELEGATOR_APP_SA \
      -u AUTH_DELEGATOR_CLUSTER_ROLE_BINDING -u AUTH_DELEGATOR_AUTH_MOUNT \
      -u AUTH_DELEGATOR_ROLE -u AUTH_DELEGATOR_POLICY -u AUTH_DELEGATOR_KV_MOUNT \
      -u AUTH_DELEGATOR_KV_PATH -u AUTH_DELEGATOR_VAULT_CONNECTION \
      -u AUTH_DELEGATOR_VAULT_AUTH -u AUTH_DELEGATOR_VSS_NAME \
      -u AUTH_DELEGATOR_SECRET_NAME -u AUTH_DELEGATOR_APP_POD \
      -u AUTH_DELEGATOR_VAULT_AUDIENCE -u AUTH_DELEGATOR_API_AUDIENCE \
      -u AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS -u AUTH_DELEGATOR_TOKEN_TTL \
    bash -c "set -euo pipefail; source '$ENV_LIB'; print_two_cluster_env"
)"

get_ad_default() {
  printf '%s\n' "$AUTH_DELEGATOR_DEFAULTS_OUTPUT" | sed -n "s/^$1=//p"
}

assert_var_eq "default AUTH_DELEGATOR_AUTH_NAMESPACE is 'vso-auth-delegator'" \
  "$(get_ad_default AUTH_DELEGATOR_AUTH_NAMESPACE)" "vso-auth-delegator"
assert_var_eq "default AUTH_DELEGATOR_APP_NAMESPACE is 'vso-auth-delegator-app'" \
  "$(get_ad_default AUTH_DELEGATOR_APP_NAMESPACE)" "vso-auth-delegator-app"
assert_var_eq "default AUTH_DELEGATOR_SELF_REVIEW_SA is 'vso-auth-delegator'" \
  "$(get_ad_default AUTH_DELEGATOR_SELF_REVIEW_SA)" "vso-auth-delegator"
assert_var_eq "default AUTH_DELEGATOR_APP_SA is 'vso-auth-delegator-app'" \
  "$(get_ad_default AUTH_DELEGATOR_APP_SA)" "vso-auth-delegator-app"
assert_var_eq "default AUTH_DELEGATOR_CLUSTER_ROLE_BINDING is 'vso-auth-delegator-self-review'" \
  "$(get_ad_default AUTH_DELEGATOR_CLUSTER_ROLE_BINDING)" "vso-auth-delegator-self-review"
assert_var_eq "default AUTH_DELEGATOR_AUTH_MOUNT is 'kubernetes-vso-self-review'" \
  "$(get_ad_default AUTH_DELEGATOR_AUTH_MOUNT)" "kubernetes-vso-self-review"
assert_var_eq "default AUTH_DELEGATOR_ROLE is 'vso-auth-delegator'" \
  "$(get_ad_default AUTH_DELEGATOR_ROLE)" "vso-auth-delegator"
assert_var_eq "default AUTH_DELEGATOR_POLICY is 'vso-auth-delegator'" \
  "$(get_ad_default AUTH_DELEGATOR_POLICY)" "vso-auth-delegator"
assert_var_eq "default AUTH_DELEGATOR_KV_MOUNT is 'kv-v2'" \
  "$(get_ad_default AUTH_DELEGATOR_KV_MOUNT)" "kv-v2"
assert_var_eq "default AUTH_DELEGATOR_KV_PATH is 'vso-auth-delegator/mysecret'" \
  "$(get_ad_default AUTH_DELEGATOR_KV_PATH)" "vso-auth-delegator/mysecret"
assert_var_eq "default AUTH_DELEGATOR_VSS_NAME is 'vso-auth-delegator-mysecret'" \
  "$(get_ad_default AUTH_DELEGATOR_VSS_NAME)" "vso-auth-delegator-mysecret"
assert_var_eq "default AUTH_DELEGATOR_SECRET_NAME is 'vso-auth-delegator-mysecret'" \
  "$(get_ad_default AUTH_DELEGATOR_SECRET_NAME)" "vso-auth-delegator-mysecret"
assert_var_eq "default AUTH_DELEGATOR_APP_POD is 'vso-auth-delegator-app'" \
  "$(get_ad_default AUTH_DELEGATOR_APP_POD)" "vso-auth-delegator-app"
assert_var_eq "default AUTH_DELEGATOR_VAULT_AUDIENCE is 'vault'" \
  "$(get_ad_default AUTH_DELEGATOR_VAULT_AUDIENCE)" "vault"
assert_var_eq "default AUTH_DELEGATOR_API_AUDIENCE derives from VSO_OIDC_ISSUER" \
  "$(get_ad_default AUTH_DELEGATOR_API_AUDIENCE)" "https://host.containers.internal:6444"
assert_var_eq "default AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS is '600'" \
  "$(get_ad_default AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS)" "600"
assert_var_eq "default AUTH_DELEGATOR_TOKEN_TTL is '1h'" \
  "$(get_ad_default AUTH_DELEGATOR_TOKEN_TTL)" "1h"

for key in AUTH_DELEGATOR_AUTH_NAMESPACE AUTH_DELEGATOR_APP_NAMESPACE AUTH_DELEGATOR_SELF_REVIEW_SA \
    AUTH_DELEGATOR_APP_SA AUTH_DELEGATOR_CLUSTER_ROLE_BINDING AUTH_DELEGATOR_AUTH_MOUNT \
    AUTH_DELEGATOR_ROLE AUTH_DELEGATOR_POLICY AUTH_DELEGATOR_KV_MOUNT AUTH_DELEGATOR_KV_PATH \
    AUTH_DELEGATOR_VAULT_CONNECTION AUTH_DELEGATOR_VAULT_AUTH AUTH_DELEGATOR_VSS_NAME \
    AUTH_DELEGATOR_SECRET_NAME AUTH_DELEGATOR_APP_POD AUTH_DELEGATOR_VAULT_AUDIENCE \
    AUTH_DELEGATOR_API_AUDIENCE AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS AUTH_DELEGATOR_TOKEN_TTL; do
  if printf '%s\n' "$AUTH_DELEGATOR_DEFAULTS_OUTPUT" | grep -q "^${key}="; then
    check "print_two_cluster_env() includes $key" 0
  else
    check "print_two_cluster_env() includes $key" 1
  fi
done

# Overrides are preserved.
AUTH_DELEGATOR_OVERRIDE_OUTPUT="$(
  env AUTH_DELEGATOR_AUTH_NAMESPACE=auth-ns-override AUTH_DELEGATOR_APP_NAMESPACE=app-ns-override \
    bash -c "source '$ENV_LIB'; print_two_cluster_env"
)"
if printf '%s\n' "$AUTH_DELEGATOR_OVERRIDE_OUTPUT" | grep -q '^AUTH_DELEGATOR_AUTH_NAMESPACE=auth-ns-override$' \
    && printf '%s\n' "$AUTH_DELEGATOR_OVERRIDE_OUTPUT" | grep -q '^AUTH_DELEGATOR_APP_NAMESPACE=app-ns-override$'; then
  check "AUTH_DELEGATOR_AUTH_NAMESPACE/APP_NAMESPACE overrides are preserved" 0
else
  check "AUTH_DELEGATOR_AUTH_NAMESPACE/APP_NAMESPACE overrides are preserved" 1
fi

# validate_auth_delegator_env: happy path (defaults) passes.
if bash -c "source '$ENV_LIB'; validate_auth_delegator_env" >/dev/null 2>&1; then
  check "validate_auth_delegator_env passes with unmodified defaults" 0
else
  check "validate_auth_delegator_env passes with unmodified defaults" 1
fi

# validate_auth_delegator_env: auth namespace == app namespace rejected.
if env AUTH_DELEGATOR_APP_NAMESPACE=vso-auth-delegator \
    bash -c "source '$ENV_LIB'; validate_auth_delegator_env" >/dev/null 2>&1; then
  check "identical auth/app namespaces are rejected" 1
else
  check "identical auth/app namespaces are rejected" 0
fi

# validate_auth_delegator_env: token expiration below 600s rejected.
if env AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS=599 \
    bash -c "source '$ENV_LIB'; validate_auth_delegator_env" >/dev/null 2>&1; then
  check "token expiration below 600s is rejected" 1
else
  check "token expiration below 600s is rejected" 0
fi

# validate_auth_delegator_env: identical vault/API audiences rejected.
if env AUTH_DELEGATOR_API_AUDIENCE=vault \
    bash -c "source '$ENV_LIB'; validate_auth_delegator_env" >/dev/null 2>&1; then
  check "identical vault/API audiences are rejected" 1
else
  check "identical vault/API audiences are rejected" 0
fi

# validate_auth_delegator_env: API audience must equal VSO_OIDC_ISSUER.
if env AUTH_DELEGATOR_API_AUDIENCE=https://not-the-issuer.example \
    bash -c "source '$ENV_LIB'; validate_auth_delegator_env" >/dev/null 2>&1; then
  check "API audience not matching VSO_OIDC_ISSUER is rejected" 1
else
  check "API audience not matching VSO_OIDC_ISSUER is rejected" 0
fi

# validate_auth_delegator_env: colliding names with the JWT/OIDC scenario
# are rejected (namespace, mount, Secret, pod, policy, KV path).
for collision_env in \
    'AUTH_DELEGATOR_APP_NAMESPACE=vso-demo' \
    'AUTH_DELEGATOR_AUTH_MOUNT=jwt-vso' \
    'AUTH_DELEGATOR_AUTH_MOUNT=kubernetes-vso' \
    'AUTH_DELEGATOR_SECRET_NAME=vso-demo-mysecret' \
    'AUTH_DELEGATOR_APP_POD=vso-demo-app' \
    'AUTH_DELEGATOR_POLICY=mysecret' \
    'AUTH_DELEGATOR_KV_PATH=vault-demo/mysecret' \
    ; do
  if env "$collision_env" bash -c "source '$ENV_LIB'; validate_auth_delegator_env" >/dev/null 2>&1; then
    check "collision rejected: ${collision_env}" 1
  else
    check "collision rejected: ${collision_env}" 0
  fi
done

# auth_delegator_policy_hcl: prints a read-only policy scoped to the
# dedicated KV v2 data path.
POLICY_HCL="$(bash -c "source '$ENV_LIB'; auth_delegator_policy_hcl")"
if printf '%s\n' "$POLICY_HCL" | grep -qF 'path "kv-v2/data/vso-auth-delegator/mysecret"' \
    && printf '%s\n' "$POLICY_HCL" | grep -qF '"read"' \
    && ! printf '%s\n' "$POLICY_HCL" | grep -qiF 'create\|update\|delete\|sudo'; then
  check "auth_delegator_policy_hcl prints a read-only policy scoped to the dedicated KV path" 0
else
  check "auth_delegator_policy_hcl prints a read-only policy scoped to the dedicated KV path" 1
fi

# preflight_auth_delegator_runtime and the snapshot helpers must exist and
# be callable without crashing, even with no live cluster.
if bash -c "source '$ENV_LIB'; declare -f preflight_auth_delegator_runtime >/dev/null && declare -f capture_jwt_oidc_baseline_snapshot >/dev/null && declare -f capture_vso_demo_cr_snapshot >/dev/null"; then
  check "preflight_auth_delegator_runtime and snapshot helper functions are defined" 0
else
  check "preflight_auth_delegator_runtime and snapshot helper functions are defined" 1
fi

if env VSO_CONTEXT=kind-definitely-does-not-exist-anywhere \
    bash -c "source '$ENV_LIB'; preflight_auth_delegator_runtime" >/dev/null 2>&1; then
  check "preflight_auth_delegator_runtime degrades gracefully when the VSO context does not exist" 0
else
  check "preflight_auth_delegator_runtime degrades gracefully when the VSO context does not exist" 1
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
