#!/usr/bin/env bash
# Static validation for the fail-fast `make vso-deck` startup sequence.
# This test never starts Podman, kind, Kubernetes, or Presenterm.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MAKEFILE="${REPO_ROOT}/Makefile"
PREPARE_SCRIPT="${REPO_ROOT}/scripts/prepare-vso-deck-env.sh"
VAULT_SETUP_SCRIPT="${REPO_ROOT}/scripts/setup-vault-cluster.sh"

# Literal source-code patterns; these shell-looking variables and Make
# expressions intentionally must not expand in this validation script.
# shellcheck disable=SC2016
PODMAN_START_PATTERN='podman start "$container"'
# shellcheck disable=SC2016
KUBECTL_CONTEXT_PATTERN='kubectl --context "$context"'
# shellcheck disable=SC2016
KIND_EXPORT_PATTERN='kind export kubeconfig --name "$cluster_name"'
# shellcheck disable=SC2016
MAKE_SETUP_PATTERN='$(MAKE) --no-print-directory setup'
# shellcheck disable=SC2016
MAKE_VERIFY_PATTERN='$(MAKE) --no-print-directory verify-two-cluster'
# shellcheck disable=SC2016
VAULT_INIT_CAPTURE_PATTERN='VAULT_INIT_JSON=$(kubectl_vault exec'

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
  local text="$1"
  local expected="$2"
  printf '%s' "$text" | grep -qF -- "$expected"
}

line_number() {
  local text="$1"
  local expected="$2"
  local occurrence="${3:-1}"
  printf '%s\n' "$text" | grep -nF -- "$expected" | sed -n "${occurrence}p" | cut -d: -f1
}

check "deck preparation script exists" test -f "$PREPARE_SCRIPT"
check "deck preparation script passes bash syntax validation" bash -n "$PREPARE_SCRIPT"
check "deck preparation has a non-mutating check-only mode" grep -q -- '--check-only' "$PREPARE_SCRIPT"
check "deck preparation can start the Podman machine" grep -qF 'podman machine start' "$PREPARE_SCRIPT"
check "deck preparation detects expected kind control-plane containers" grep -qF 'control-plane' "$PREPARE_SCRIPT"
check "deck preparation starts stopped control-plane containers" grep -qF "$PODMAN_START_PATTERN" "$PREPARE_SCRIPT"
check "deck preparation checks explicit Kubernetes contexts" grep -qF "$KUBECTL_CONTEXT_PATTERN" "$PREPARE_SCRIPT"
check "deck preparation waits for Kubernetes Nodes to become Ready" grep -qF -- '--for=condition=Ready node --all' "$PREPARE_SCRIPT"
check "deck preparation restores a missing kubeconfig context" grep -qF "$KIND_EXPORT_PATTERN" "$PREPARE_SCRIPT"
check "Vault setup bounds the fresh-install pod readiness wait" grep -qF 'VAULT_POD_READY_ATTEMPTS' "$VAULT_SETUP_SCRIPT"
check "Vault setup treats an initially missing pod as retryable" grep -qF -- "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true" "$VAULT_SETUP_SCRIPT"
check "Vault setup parses JSON status so sealed exit code 2 is safe" grep -qF 'vault status -format=json' "$VAULT_SETUP_SCRIPT"
check "Vault setup can restore CLI login after unseal" grep -qF 'unseal_from_file && login_from_file' "$VAULT_SETUP_SCRIPT"
check "Vault setup verifies CLI authentication even when already unsealed" grep -qF 'vault token lookup' "$VAULT_SETUP_SCRIPT"
check "Vault setup captures init output before writing the key file" grep -qF "$VAULT_INIT_CAPTURE_PATTERN" "$VAULT_SETUP_SCRIPT"
if grep -qE 'vault operator init.*>.*KEYS_FILE' "$VAULT_SETUP_SCRIPT"; then
  echo "FAIL: Vault setup must not redirect initialization directly over the recovery key file"
  fail=$((fail + 1))
else
  echo "PASS: Vault setup cannot truncate the recovery key file on failed initialization"
  pass=$((pass + 1))
fi

vso_deck_recipe="$(awk '
  /^vso-deck:/ { in_target=1; next }
  in_target && /^[^[:space:]#][^:]*:/ { exit }
  in_target { print }
' "$MAKEFILE")"

check "vso-deck checks Presenterm availability" contains "$vso_deck_recipe" 'command -v presenterm'
check "vso-deck invokes the startup preparation script" contains "$vso_deck_recipe" 'scripts/prepare-vso-deck-env.sh'
check "vso-deck forces the Podman kind provider for startup" contains "$vso_deck_recipe" 'KIND_EXPERIMENTAL_PROVIDER=podman bash scripts/prepare-vso-deck-env.sh'
check "vso-deck verifies existing resources before considering setup" contains "$vso_deck_recipe" "if $MAKE_VERIFY_PATTERN; then"
check "vso-deck explicitly skips setup for a healthy environment" contains "$vso_deck_recipe" 'skipping setup and reusing them unchanged'
check "vso-deck retains setup as a failure-only recovery path" contains "$vso_deck_recipe" 'Existing resources are incomplete or unhealthy; running setup once'
check "vso-deck forces the Podman kind provider for fallback setup" contains "$vso_deck_recipe" "KIND_EXPERIMENTAL_PROVIDER=podman $MAKE_SETUP_PATTERN"
check "vso-deck launches Presenterm with live blocks" contains "$vso_deck_recipe" 'exec presenterm -x presenterm/vso.md'

verify_count="$(printf '%s\n' "$vso_deck_recipe" | grep -cF -- "$MAKE_VERIFY_PATTERN")"
if [ "$verify_count" -eq 2 ]; then
  echo "PASS: vso-deck verifies once before setup and once after fallback setup"
  pass=$((pass + 1))
else
  echo "FAIL: expected two verification gates in vso-deck recipe, found ${verify_count}"
  fail=$((fail + 1))
fi

presenterm_check_line="$(line_number "$vso_deck_recipe" 'command -v presenterm')"
prepare_line="$(line_number "$vso_deck_recipe" 'scripts/prepare-vso-deck-env.sh')"
first_verify_line="$(line_number "$vso_deck_recipe" "$MAKE_VERIFY_PATTERN" 1)"
setup_line="$(line_number "$vso_deck_recipe" "$MAKE_SETUP_PATTERN")"
second_verify_line="$(line_number "$vso_deck_recipe" "$MAKE_VERIFY_PATTERN" 2)"
launch_line="$(line_number "$vso_deck_recipe" 'exec presenterm -x presenterm/vso.md')"

if [ -n "$presenterm_check_line" ] && [ -n "$prepare_line" ] && [ -n "$first_verify_line" ] \
    && [ -n "$setup_line" ] && [ -n "$second_verify_line" ] && [ -n "$launch_line" ] \
    && [ "$presenterm_check_line" -lt "$prepare_line" ] \
    && [ "$prepare_line" -lt "$first_verify_line" ] \
    && [ "$first_verify_line" -lt "$setup_line" ] \
    && [ "$setup_line" -lt "$second_verify_line" ] \
    && [ "$second_verify_line" -lt "$launch_line" ]; then
  echo "PASS: vso-deck is ordered prepare -> verify -> fallback setup/re-verify -> launch"
  pass=$((pass + 1))
else
  echo "FAIL: vso-deck health-first/fallback gates are not correctly ordered"
  printf '%s\n' "$vso_deck_recipe" | sed 's/^/  /'
  fail=$((fail + 1))
fi

# Override recursive MAKE so GNU make's -n recursion exception cannot run the
# live verify/setup targets during this static rendering check.
if make -C "$REPO_ROOT" -n vso-deck MAKE=true 2>&1 | grep -qF 'presenterm -x presenterm/vso.md'; then
  echo "PASS: make can render the vso-deck recipe"
  pass=$((pass + 1))
else
  echo "FAIL: make could not render the vso-deck recipe"
  fail=$((fail + 1))
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
