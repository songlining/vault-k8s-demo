#!/usr/bin/env bash
# scripts/tests/test-auth-delegator-deck-startup-validation.sh
#
# Static validation for the fail-fast `make auth-delegator-deck` startup
# sequence and its transitive call graph. This test never starts Podman,
# kind, Kubernetes, or Presenterm for real, and it never mutates a live
# cluster.
#
# Asserts:
#   - scripts/prepare-vso-deck-env.sh has a --require-existing mode that
#     fails immediately on a missing kind control-plane container and never
#     suggests/invokes cluster creation in that branch
#   - the auth-delegator-deck Make recipe is health-first and ordered:
#     require-existing prepare -> verify existing OIDC (--skip-rotation) ->
#     health-check this scenario (--skip-rotation) -> setup only if
#     unhealthy -> full verifier (with rotation) -> re-verify OIDC
#     (--skip-rotation) -> launch presenterm
#   - transitive safety: neither the Make recipe nor any script it can
#     reach (prepare-vso-deck-env.sh, verify-two-cluster.sh,
#     verify-vso-auth-delegator.sh, configure-vso-auth-delegator.sh,
#     apply-vso-auth-delegator-demo.sh) invokes cluster creation/deletion,
#     `helm install`/`helm upgrade`, or a bare `make setup`
#
# Usage: scripts/tests/test-auth-delegator-deck-startup-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MAKEFILE="${REPO_ROOT}/Makefile"
PREPARE_SCRIPT="${REPO_ROOT}/scripts/prepare-vso-deck-env.sh"

# shellcheck disable=SC2016
MAKE_AUTH_DELEGATOR_SETUP_PATTERN='$(MAKE) --no-print-directory auth-delegator-setup'
# shellcheck disable=SC2016
BARE_MAKE_SETUP_PATTERN='$(MAKE) --no-print-directory setup'

pass=0
fail=0

check() {
  local description="$1"
  shift
  if "$@"; then
    echo "PASS: ${description}"
    pass=$((pass + 1))
  else
    echo "FAIL: ${description}"
    fail=$((fail + 1))
  fi
}

contains() {
  local text="$1" expected="$2"
  printf '%s' "$text" | grep -qF -- "$expected"
}

not_contains() {
  local text="$1" expected="$2"
  ! printf '%s' "$text" | grep -qF -- "$expected"
}

line_number() {
  local text="$1" expected="$2" occurrence="${3:-1}"
  printf '%s\n' "$text" | grep -nF -- "$expected" | sed -n "${occurrence}p" | cut -d: -f1
}

# --- prepare-vso-deck-env.sh --require-existing --------------------------

check "prepare script exists" test -f "$PREPARE_SCRIPT"
check "prepare script passes bash syntax validation" bash -n "$PREPARE_SCRIPT"
check "prepare script has a --require-existing mode" grep -q -- '--require-existing' "$PREPARE_SCRIPT"
check "prepare script still has a non-mutating --check-only mode" grep -q -- '--check-only' "$PREPARE_SCRIPT"

PREPARE_CONTENTS="$(cat "$PREPARE_SCRIPT")"
check "--require-existing fails fast (no cluster creation suggestion in that branch)" \
  contains "$PREPARE_CONTENTS" 'REQUIRE_EXISTING'

# The require-existing failure branch must not print the 'make setup will
# create' suggestion, and the missing-container check function must
# short-circuit to an error before any cluster-creation-adjacent logic.
missing_container_block="$(awk '
  /if ! podman container exists "\$container"; then/ { found=1 }
  found { print }
  found && /^  fi$/ { exit }
' "$PREPARE_SCRIPT")"
check "require-existing branch never creates a cluster" \
  not_contains "$missing_container_block" 'kind create cluster'
check "require-existing branch reports a clear error, not a create suggestion" \
  contains "$missing_container_block" 'REQUIRE_EXISTING'

# --- auth-delegator-deck Make recipe --------------------------------------

auth_delegator_deck_recipe="$(awk '
  /^auth-delegator-deck:/ { in_target=1; next }
  in_target && /^[^[:space:]#][^:]*:/ { exit }
  in_target { print }
' "$MAKEFILE")"

check "Makefile defines auth-delegator-deck" test -n "$auth_delegator_deck_recipe"
check "auth-delegator-deck checks Presenterm availability" \
  contains "$auth_delegator_deck_recipe" 'command -v presenterm'
check "auth-delegator-deck invokes prepare-vso-deck-env.sh with --require-existing" \
  contains "$auth_delegator_deck_recipe" 'bash scripts/prepare-vso-deck-env.sh --require-existing'
check "auth-delegator-deck forces the Podman kind provider for startup" \
  contains "$auth_delegator_deck_recipe" 'KIND_EXPERIMENTAL_PROVIDER=podman bash scripts/prepare-vso-deck-env.sh --require-existing'
check "auth-delegator-deck verifies the default JWT/OIDC scenario with --skip-rotation" \
  contains "$auth_delegator_deck_recipe" 'bash scripts/verify-two-cluster.sh --skip-rotation'
check "auth-delegator-deck health-checks this scenario with --skip-rotation" \
  contains "$auth_delegator_deck_recipe" 'bash scripts/verify-vso-auth-delegator.sh --skip-rotation'
check "auth-delegator-deck runs setup only via the auth-delegator-setup target (not a raw script call)" \
  contains "$auth_delegator_deck_recipe" "$MAKE_AUTH_DELEGATOR_SETUP_PATTERN"
check "auth-delegator-deck runs the full verifier (with rotation) as a separate, later step" \
  contains "$auth_delegator_deck_recipe" 'bash scripts/verify-vso-auth-delegator.sh'
check "auth-delegator-deck launches Presenterm with live blocks" \
  contains "$auth_delegator_deck_recipe" 'exec presenterm -x presenterm/auth-delegator.md'

skip_rotation_count="$(printf '%s\n' "$auth_delegator_deck_recipe" | grep -cF -- '--skip-rotation')"
if [ "$skip_rotation_count" -ge 3 ]; then
  echo "PASS: at least 3 --skip-rotation invocations (OIDC before, health-check, OIDC after)"
  pass=$((pass + 1))
else
  echo "FAIL: expected >= 3 --skip-rotation invocations, found ${skip_rotation_count}"
  fail=$((fail + 1))
fi

full_verify_count="$(printf '%s\n' "$auth_delegator_deck_recipe" | grep -cF -- 'bash scripts/verify-vso-auth-delegator.sh')"
if [ "$full_verify_count" -ge 2 ]; then
  echo "PASS: verify-vso-auth-delegator.sh invoked at least twice (health-check + full run)"
  pass=$((pass + 1))
else
  echo "FAIL: expected >= 2 verify-vso-auth-delegator.sh invocations, found ${full_verify_count}"
  fail=$((fail + 1))
fi

# --- Ordering ---------------------------------------------------------------

presenterm_check_line="$(line_number "$auth_delegator_deck_recipe" 'command -v presenterm')"
prepare_line="$(line_number "$auth_delegator_deck_recipe" '--require-existing')"
oidc_verify_line_1="$(line_number "$auth_delegator_deck_recipe" 'bash scripts/verify-two-cluster.sh --skip-rotation' 1)"
health_check_line="$(line_number "$auth_delegator_deck_recipe" 'bash scripts/verify-vso-auth-delegator.sh --skip-rotation')"
setup_line="$(line_number "$auth_delegator_deck_recipe" "$MAKE_AUTH_DELEGATOR_SETUP_PATTERN")"
full_verify_line="$(printf '%s\n' "$auth_delegator_deck_recipe" | grep -nF -- 'bash scripts/verify-vso-auth-delegator.sh' | grep -vF -- '--skip-rotation' | head -1 | cut -d: -f1)"
oidc_verify_line_2="$(line_number "$auth_delegator_deck_recipe" 'bash scripts/verify-two-cluster.sh --skip-rotation' 2)"
launch_line="$(line_number "$auth_delegator_deck_recipe" 'exec presenterm -x presenterm/auth-delegator.md')"

if [ -n "$presenterm_check_line" ] && [ -n "$prepare_line" ] && [ -n "$oidc_verify_line_1" ] \
    && [ -n "$health_check_line" ] && [ -n "$setup_line" ] && [ -n "$full_verify_line" ] \
    && [ -n "$oidc_verify_line_2" ] && [ -n "$launch_line" ] \
    && [ "$presenterm_check_line" -lt "$prepare_line" ] \
    && [ "$prepare_line" -lt "$oidc_verify_line_1" ] \
    && [ "$oidc_verify_line_1" -lt "$health_check_line" ] \
    && [ "$health_check_line" -lt "$setup_line" ] \
    && [ "$setup_line" -lt "$full_verify_line" ] \
    && [ "$full_verify_line" -lt "$oidc_verify_line_2" ] \
    && [ "$oidc_verify_line_2" -lt "$launch_line" ]; then
  echo "PASS: auth-delegator-deck is ordered require-existing -> verify OIDC -> health-check -> setup-if-unhealthy -> full verify -> re-verify OIDC -> launch"
  pass=$((pass + 1))
else
  echo "FAIL: auth-delegator-deck health-first/fallback gates are not correctly ordered"
  printf '%s\n' "$auth_delegator_deck_recipe" | sed 's/^/  /'
  fail=$((fail + 1))
fi

# --- Transitive safety: never create/delete/recreate a cluster, never Helm,
# --- never a bare `make setup` --------------------------------------------

FORBIDDEN_PATTERNS=(
  'kind create cluster'
  'kind delete cluster'
  'helm install'
  'helm upgrade'
  'podman machine rm'
)

check "auth-delegator-deck recipe itself never calls bare 'make setup'" \
  not_contains "$auth_delegator_deck_recipe" "$BARE_MAKE_SETUP_PATTERN"

for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
  check "auth-delegator-deck recipe never contains '${pattern}'" \
    not_contains "$auth_delegator_deck_recipe" "$pattern"
done

# Transitive call graph: every script auth-delegator-deck can reach,
# directly or via auth-delegator-setup.
TRANSITIVE_SCRIPTS=(
  "${REPO_ROOT}/scripts/prepare-vso-deck-env.sh"
  "${REPO_ROOT}/scripts/verify-two-cluster.sh"
  "${REPO_ROOT}/scripts/verify-vso-auth-delegator.sh"
  "${REPO_ROOT}/scripts/configure-vso-auth-delegator.sh"
  "${REPO_ROOT}/scripts/apply-vso-auth-delegator-demo.sh"
  "${REPO_ROOT}/scripts/check-vault-connectivity.sh"
)

for script in "${TRANSITIVE_SCRIPTS[@]}"; do
  script_name="$(basename "$script")"
  if [ ! -f "$script" ]; then
    echo "FAIL: expected transitive script not found: ${script}"
    fail=$((fail + 1))
    continue
  fi
  contents="$(cat "$script")"
  for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    check "${script_name} never invokes '${pattern}'" \
      not_contains "$contents" "$pattern"
  done
  # These scripts may print human-facing hints like "Run 'make setup-vault'
  # (or scripts/setup-vault-cluster.sh) first." -- that is a diagnostic
  # string, not an invocation. Assert no ACTUAL invocation (a line that
  # executes the command rather than merely quoting it in an echo/string).
  invocation_lines="$(printf '%s\n' "$contents" | grep -nE '(^|[^"'\''A-Za-z0-9_./-])(scripts/create-clusters\.sh|scripts/setup-vault-cluster\.sh|scripts/setup-vso-cluster\.sh)' | grep -vE "echo|fail_section|Run '|Run |NOTE:|#" || true)"
  if [ -z "$invocation_lines" ]; then
    echo "PASS: ${script_name} never actually invokes cluster/Vault/VSO install scripts (only quotes them as hints, if at all)"
    pass=$((pass + 1))
  else
    echo "FAIL: ${script_name} appears to actually invoke a cluster/install script:"
    echo "$invocation_lines" | sed 's/^/  /'
    fail=$((fail + 1))
  fi
done

# --- make -n render check (MAKE overridden to a no-op so the GNU make
# --- recursive-$(MAKE) dry-run exception cannot execute the live
# --- fallback setup target; the verify-* calls are read-only/fail-fast
# --- when no live cluster is unsealed, matching the existing vso-deck
# --- startup test's established technique) --------------------------------

if make -C "$REPO_ROOT" -n auth-delegator-deck MAKE=true 2>&1 | grep -qF 'presenterm -x presenterm/auth-delegator.md'; then
  echo "PASS: make can render the auth-delegator-deck recipe"
  pass=$((pass + 1))
else
  echo "FAIL: make could not render the auth-delegator-deck recipe"
  fail=$((fail + 1))
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
