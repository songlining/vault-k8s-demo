#!/usr/bin/env bash
# scripts/tests/test-vso-demo-validation.sh
#
# Unit tests for vso-demo.sh's preflight/validation logic and static review
# of its kubectl usage and narrative content:
#   - shell syntax check
#   - missing required commands (kubectl/base64)
#   - missing/unknown VAULT_CONTEXT or VSO_CONTEXT
#   - VAULT_CONTEXT == VSO_CONTEXT rejected
#   - every kubectl invocation in the script uses an explicit `--context`
#   - the script's narrative/diagrams reference both clusters (two-cluster
#     architecture), not a single-cluster one
#   - rotation commands write through the Vault cluster and read through the
#     VSO cluster
#
# These tests never run the full guided demo against a real cluster (that
# requires live kind-vault-lab/kind-vso-lab clusters with Vault + VSO + the
# demo app already applied -- see the validation step in
# tasks/vso-two-cluster-podman/10-update-demo-scripts.md for the live,
# end-to-end `NO_WAIT=true ./vso-demo.sh` run). They only exercise the
# fast-failing preflight path (invalid context) and static review of the
# script contents.
#
# Usage: scripts/tests/test-vso-demo-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VSO_DEMO="${REPO_ROOT}/vso-demo.sh"

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

# 1. Shell syntax is valid.
if bash -n "$VSO_DEMO" 2>/tmp/vso-demo-syntax.err; then
  echo "PASS: vso-demo.sh has valid bash syntax"
  pass=$((pass + 1))
else
  echo "FAIL: vso-demo.sh has a syntax error:"
  sed 's/^/  /' /tmp/vso-demo-syntax.err
  fail=$((fail + 1))
fi

# 2. Missing required command (kubectl) is reported and fails fast.
NO_KUBECTL_DIR="$(mktemp -d)"
trap 'rm -rf "$NO_KUBECTL_DIR"' EXIT
for tool in bash base64 mktemp cat grep sed printf; do
  real_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real_path" ] && ln -sf "$real_path" "${NO_KUBECTL_DIR}/${tool}"
done
assert_fail_contains \
  "missing kubectl is reported" \
  "kubectl" \
  env -i PATH="$NO_KUBECTL_DIR" HOME="$HOME" NO_WAIT=true "$VSO_DEMO"

# 3. Missing/unknown VAULT_CONTEXT is reported.
assert_fail_contains \
  "unknown VAULT_CONTEXT is reported" \
  "kubectl context 'definitely-not-a-real-context' not found" \
  env VAULT_CONTEXT=definitely-not-a-real-context NO_WAIT=true "$VSO_DEMO"

# 4. Missing/unknown VSO_CONTEXT is reported.
assert_fail_contains \
  "unknown VSO_CONTEXT is reported" \
  "kubectl context 'definitely-not-a-real-context' not found" \
  env VSO_CONTEXT=definitely-not-a-real-context NO_WAIT=true "$VSO_DEMO"

# 5. VAULT_CONTEXT == VSO_CONTEXT is rejected outright.
assert_fail_contains \
  "VAULT_CONTEXT == VSO_CONTEXT is rejected" \
  "must not be the same context" \
  env VAULT_CONTEXT=kind-vault-lab VSO_CONTEXT=kind-vault-lab NO_WAIT=true "$VSO_DEMO"

# --- Static review of vso-demo.sh's contents --------------------------------

VSO_DEMO_CONTENTS="$(cat "$VSO_DEMO")"

# 6. Every kubectl invocation in the script includes an explicit --context
#    (directly, since vso-demo.sh builds command strings for presentation
#    rather than calling the kubectl_vault/kubectl_vso wrapper functions
#    inline). Guards against a regression that reintroduces a bare kubectl
#    call relying on the ambient current-context.
bare_calls=$(grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' "$VSO_DEMO" \
  | grep -v -- '--context' \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'require_commands|command -v' || true)
if [ -n "$bare_calls" ]; then
  echo "FAIL: found bare kubectl invocation(s) without an explicit --context:"
  echo "$bare_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every kubectl invocation in vso-demo.sh includes an explicit --context"
  pass=$((pass + 1))
fi

# 7. Every `kubectl --context` invocation targets one of the two known
#    context variables, never a hardcoded cluster name.
bad_context_calls=$(grep -nE -- '--context ' "$VSO_DEMO" \
  | grep -vE -- '--context \$\{VAULT_CONTEXT\}|--context \$\{VSO_CONTEXT\}|--context "\$VAULT_CONTEXT"|--context "\$VSO_CONTEXT"' || true)
if [ -n "$bad_context_calls" ]; then
  echo "FAIL: found --context usage not referencing \${VAULT_CONTEXT}/\${VSO_CONTEXT}:"
  echo "$bad_context_calls" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every --context usage references \${VAULT_CONTEXT} or \${VSO_CONTEXT}"
  pass=$((pass + 1))
fi

# 8. The narrative/diagrams describe a two-cluster architecture, not a
#    single-cluster one.
assert_contains \
  "intro mentions the Vault cluster" \
  "$VSO_DEMO_CONTENTS" 'Vault cluster: ${VAULT_CONTEXT}'
assert_contains \
  "intro mentions the VSO cluster" \
  "$VSO_DEMO_CONTENTS" 'VSO cluster:   ${VSO_CONTEXT}'
assert_contains \
  "architecture section title mentions two clusters" \
  "$VSO_DEMO_CONTENTS" '1. Architecture: two clusters, one sync pipeline'
assert_contains \
  "diagram labels the Vault cluster" \
  "$VSO_DEMO_CONTENTS" 'VAULT CLUSTER'
assert_contains \
  "diagram labels the VSO cluster" \
  "$VSO_DEMO_CONTENTS" 'VSO CLUSTER'

# 9. Rotation section: writes happen against VAULT_CONTEXT (vault kv put),
#    reads happen against VSO_CONTEXT (get secret).
rotation_block=$(sed -n '/Live rotation: change Vault/,/Demo complete/p' "$VSO_DEMO")

write_calls_wrong_context=$(echo "$rotation_block" | grep -n 'vault kv put' | grep -v -- '--context ${VAULT_CONTEXT}' || true)
if [ -n "$write_calls_wrong_context" ]; then
  echo "FAIL: found a rotation 'vault kv put' write not targeting \${VAULT_CONTEXT}:"
  echo "$write_calls_wrong_context" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every rotation write ('vault kv put') targets \${VAULT_CONTEXT}"
  pass=$((pass + 1))
fi

read_calls_wrong_context=$(echo "$rotation_block" | grep -n 'get secret' | grep -v -- '--context ${VSO_CONTEXT}' || true)
if [ -n "$read_calls_wrong_context" ]; then
  echo "FAIL: found a rotation 'get secret' read not targeting \${VSO_CONTEXT}:"
  echo "$read_calls_wrong_context" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "PASS: every rotation read ('get secret') targets \${VSO_CONTEXT}"
  pass=$((pass + 1))
fi

# 10. The dedicated cross-cluster auth mount (auth/kubernetes-vso, via
#     VSO_AUTH_MOUNT) is referenced, not the same-cluster auth/kubernetes
#     mount used by the Agent Injector/OTel demo paths.
assert_contains \
  "least-privilege section reads the dedicated VSO_AUTH_MOUNT role" \
  "$VSO_DEMO_CONTENTS" 'auth/${VSO_AUTH_MOUNT}/role/${VSO_AUTH_ROLE}'

echo ""
echo "vso-demo.sh validation: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
