#!/usr/bin/env bash
# scripts/tests/test-auth-delegator-docs-validation.sh
#
# Unit tests for the client-JWT-self-review VSO scenario's customer-facing
# documentation (docs/vso-kubernetes-auth-delegator-demo.md) and the
# repository-level docs that reference it (README.md, PODMAN_MIGRATION.md):
#   - the new doc exists and covers architecture/sequence, client JWT
#     self-review rationale, dual audiences, RBAC/risk trade-offs,
#     cross-namespace semantics, setup/verify/troubleshooting, a comparison
#     with the JWT/OIDC and dedicated-reviewer modes, and manual cleanup
#     instructions requiring explicit confirmation
#   - README.md lists this as a fourth scenario and states JWT/OIDC remains
#     the default, and its command index includes every auth-delegator-*
#     Make target
#   - PODMAN_MIGRATION.md documents the Vault-to-VSO TokenReview path on
#     port 6444
#   - docs/vso-jwt-oidc-demo.md is untouched by this task (pre-existing
#     unrelated dirty change elsewhere in the working tree; this test only
#     asserts it still states JWT/OIDC is the default, it does not assert
#     byte-identity with any prior revision)
#
# Usage: scripts/tests/test-auth-delegator-docs-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NEW_DOC="${REPO_ROOT}/docs/vso-kubernetes-auth-delegator-demo.md"
README="${REPO_ROOT}/README.md"
PODMAN_DOC="${REPO_ROOT}/PODMAN_MIGRATION.md"
JWT_OIDC_DOC="${REPO_ROOT}/docs/vso-jwt-oidc-demo.md"

pass=0
fail=0

assert_pass() { echo "PASS: $1"; pass=$((pass + 1)); }
assert_fail() { echo "FAIL: $1"; fail=$((fail + 1)); }

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    assert_pass "$desc"
  else
    echo "  expected to find: $needle"
    assert_fail "$desc"
  fi
}

assert_matches() {
  local desc="$1" haystack="$2" pattern="$3"
  if printf '%s' "$haystack" | grep -qE -- "$pattern"; then
    assert_pass "$desc"
  else
    echo "  expected to match: $pattern"
    assert_fail "$desc"
  fi
}

if [ ! -f "$NEW_DOC" ]; then
  echo "FAIL: ${NEW_DOC} not found"
  echo ""
  echo "auth-delegator-docs validation: 0 passed, 1 failed"
  exit 1
fi
NEW_DOC_CONTENTS="$(cat "$NEW_DOC")"

# --- 1. New doc covers every Phase 7 topic ----------------------------------

assert_contains "new doc has an architecture diagram (mermaid)" "$NEW_DOC_CONTENTS" '```mermaid'
assert_contains "new doc explains client JWT self-review selection" "$NEW_DOC_CONTENTS" 'client JWT self-review'
assert_contains "new doc explains dual/two audiences" "$NEW_DOC_CONTENTS" 'two audiences'
assert_contains "new doc discusses RBAC trade-offs (system:auth-delegator)" "$NEW_DOC_CONTENTS" 'system:auth-delegator'
assert_contains "new doc discusses SubjectAccessReview breadth trade-off" "$NEW_DOC_CONTENTS" 'SubjectAccessReview'
assert_contains "new doc explains cross-namespace semantics" "$NEW_DOC_CONTENTS" 'allowedNamespaces'
assert_contains "new doc explains namespace/name VaultAuth reference" "$NEW_DOC_CONTENTS" 'namespace/name'
assert_contains "new doc has a Setup section" "$NEW_DOC_CONTENTS" '## Setup'
assert_contains "new doc has a Verification section" "$NEW_DOC_CONTENTS" '## Verification'
assert_contains "new doc has a Troubleshooting section" "$NEW_DOC_CONTENTS" '## Troubleshooting'
assert_contains "new doc compares to the JWT/OIDC scenario" "$NEW_DOC_CONTENTS" 'Comparison with the default JWT/OIDC scenario'
assert_contains "new doc compares to the dedicated-reviewer mode" "$NEW_DOC_CONTENTS" 'Dedicated reviewer'
assert_contains "new doc mentions the Vault-local review design" "$NEW_DOC_CONTENTS" 'Vault-local review'
assert_contains "new doc has a manual cleanup section" "$NEW_DOC_CONTENTS" 'Manual cleanup'
assert_contains "new doc requires explicit confirmation for cleanup" "$NEW_DOC_CONTENTS" 'confirming with the user'
assert_contains "new doc states JWT/OIDC remains the default" "$NEW_DOC_CONTENTS" 'remains the default VSO authentication method'
assert_contains "new doc references the implementation plan" "$NEW_DOC_CONTENTS" 'vso-kubernetes-auth-delegator-plan.md'
assert_contains "new doc references the deck" "$NEW_DOC_CONTENTS" 'presenterm/auth-delegator.md'
assert_contains "new doc documents make auth-delegator-deck's health-first sequence" "$NEW_DOC_CONTENTS" '--require-existing'
assert_contains "new doc mentions the visual validator" "$NEW_DOC_CONTENTS" 'validate-deck-visual.sh'

# The new doc must never suggest cluster creation/deletion or Helm as part
# of routine setup/verify/deck flows (only as separately-confirmed manual
# cleanup instructions for Vault/Kubernetes resource removal -- never a
# cluster or Helm release).
if printf '%s' "$NEW_DOC_CONTENTS" | grep -qE 'helm (install|upgrade)|kind create cluster'; then
  assert_fail "new doc suggests cluster creation or Helm install/upgrade for this scenario"
else
  assert_pass "new doc never suggests cluster creation or Helm install/upgrade"
fi

# --- 2. New doc never modifies/claims the historical vso-jwt-oidc-demo.md ---
# --- content or presents auth-delegator as the new default ------------------

assert_contains "new doc states this is a parallel/alternative scenario, not the new default" "$NEW_DOC_CONTENTS" 'This scenario is a **second, parallel**'

# --- 3. README.md lists the fourth scenario and preserves the default ------

README_CONTENTS="$(cat "$README")"
assert_matches "README states 'four independent' scenarios" "$README_CONTENTS" 'four independent Vault-on-Kubernetes'
assert_contains "README links the new doc" "$README_CONTENTS" 'docs/vso-kubernetes-auth-delegator-demo.md'
assert_contains "README states JWT/OIDC remains the default" "$README_CONTENTS" 'This remains the **default** VSO scenario.'
assert_contains "README labels the new scenario as an alternative" "$README_CONTENTS" 'alternative'

for target in \
  'make configure-auth-delegator' \
  'make auth-delegator-apply' \
  'make auth-delegator-setup' \
  'make auth-delegator-verify' \
  'make auth-delegator-status' \
  'make auth-delegator-deck'; do
  assert_contains "README command index includes '${target}'" "$README_CONTENTS" "$target"
done

# --- 4. PODMAN_MIGRATION.md documents the port-6444 TokenReview path -------

PODMAN_CONTENTS="$(cat "$PODMAN_DOC")"
assert_contains "PODMAN_MIGRATION documents the auth-delegator TokenReview path" "$PODMAN_CONTENTS" 'Vault-to-VSO TokenReview path'
assert_contains "PODMAN_MIGRATION references port 6444 for this path" "$PODMAN_CONTENTS" '6444'
assert_contains "PODMAN_MIGRATION references the dedicated auth mount" "$PODMAN_CONTENTS" 'auth/kubernetes-vso-self-review'
assert_contains "PODMAN_MIGRATION states no new port mapping/cluster recreation is required" "$PODMAN_CONTENTS" 'No new port mapping'
assert_contains "PODMAN_MIGRATION links the new doc" "$PODMAN_CONTENTS" 'docs/vso-kubernetes-auth-delegator-demo.md'

# --- 5. docs/vso-jwt-oidc-demo.md is not required to change by this task, --
# --- but must still state JWT/OIDC is the default if present ---------------

if [ -f "$JWT_OIDC_DOC" ]; then
  JWT_OIDC_CONTENTS="$(cat "$JWT_OIDC_DOC")"
  assert_contains "docs/vso-jwt-oidc-demo.md still references auth/jwt-vso" "$JWT_OIDC_CONTENTS" 'auth/jwt-vso'
else
  assert_fail "docs/vso-jwt-oidc-demo.md not found"
fi

echo ""
echo "auth-delegator-docs validation: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
