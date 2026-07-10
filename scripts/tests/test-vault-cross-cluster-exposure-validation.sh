#!/usr/bin/env bash
# scripts/tests/test-vault-cross-cluster-exposure-validation.sh
#
# Unit tests validating that scripts/setup-vault-cluster.sh's generated
# 'vault-external' NodePort Service manifest matches the cross-cluster
# networking contract centralized in scripts/lib/two-cluster-env.sh
# (VAULT_HOST_PORT / VAULT_NODE_PORT) and the Vault cluster's kind config
# (scripts/kind/vault-lab-config.yaml.tmpl).
#
# This does not install anything or touch a live cluster -- it renders the
# heredoc-embedded manifest the same way the real script would (variable
# substitution via bash) and asserts on the resulting YAML text, plus
# cross-checks the kind config template for the matching extraPortMappings
# entry.
#
# Usage: scripts/tests/test-vault-cross-cluster-exposure-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETUP_VAULT="${REPO_ROOT}/scripts/setup-vault-cluster.sh"
KIND_TMPL="${REPO_ROOT}/scripts/kind/vault-lab-config.yaml.tmpl"
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

# 1. bash syntax check.
if bash -n "$SETUP_VAULT" >/dev/null 2>&1; then
  check "setup-vault-cluster.sh passes bash -n syntax check" 0
else
  check "setup-vault-cluster.sh passes bash -n syntax check" 1
fi

# 2. Extract the vault-external Service manifest block from the script and
#    render it with the real env defaults, the same way the script would
#    when sourced and run.
# shellcheck source=/dev/null
source "$ENV_LIB"

MANIFEST="$(awk '/^kind: Service$/{found=1} found{print} found && /^EOF$/{exit}' "$SETUP_VAULT" \
  | sed '/^EOF$/d')"

if [ -z "$MANIFEST" ]; then
  check "found a 'vault-external' Service manifest block in setup-vault-cluster.sh" 1
else
  check "found a 'vault-external' Service manifest block in setup-vault-cluster.sh" 0
fi

RENDERED="$(NAMESPACE="$NAMESPACE" VAULT_NODE_PORT="$VAULT_NODE_PORT" bash -c "cat <<EOF
$MANIFEST
EOF")"

echo "$RENDERED" | grep -q '^  name: vault-external$'
check "manifest names the Service 'vault-external'" $?

echo "$RENDERED" | grep -q '^  type: NodePort$'
check "manifest sets Service type to NodePort" $?

echo "$RENDERED" | grep -q "^      nodePort: ${VAULT_NODE_PORT}$"
check "manifest nodePort matches VAULT_NODE_PORT (${VAULT_NODE_PORT})" $?

echo "$RENDERED" | grep -q '^      port: 8200$'
check "manifest exposes port 8200" $?

echo "$RENDERED" | grep -q '^      targetPort: 8200$'
check "manifest targets container port 8200" $?

echo "$RENDERED" | grep -qE '^\s*app\.kubernetes\.io/name: vault$'
check "manifest selector includes app.kubernetes.io/name=vault" $?

echo "$RENDERED" | grep -qE '^\s*component: server$'
check "manifest selector includes component=server (matches vault-0 pod labels)" $?

# 3. The Vault cluster's kind config must map that same NodePort to
#    VAULT_HOST_PORT via extraPortMappings, or the Service is unreachable
#    from outside the cluster.
if grep -q 'containerPort: \${VAULT_NODE_PORT}' "$KIND_TMPL" \
    && grep -q 'hostPort: \${VAULT_HOST_PORT}' "$KIND_TMPL"; then
  check "kind config template maps VAULT_NODE_PORT -> VAULT_HOST_PORT via extraPortMappings" 0
else
  check "kind config template maps VAULT_NODE_PORT -> VAULT_HOST_PORT via extraPortMappings" 1
fi

# 4. The script must not remove or replace the existing same-cluster
#    'vault'/'vault-internal' Services -- vault-external must be additive.
grep -q "^helm_vault upgrade --install vault hashicorp/vault" "$SETUP_VAULT"
check "script still installs Vault via the standard Helm chart (unchanged same-cluster Services)" $?

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
