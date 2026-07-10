#!/usr/bin/env bash
# scripts/tests/test-vso-lab-kind-config-validation.sh
#
# Unit test for tasks/vso-jwt-oidc-auth/02-configure-kind-oidc-issuer.md.
#
# Phase 1 (docs/vso-jwt-oidc-auth-spike-01.md) proved that Vault's
# auth/jwt-vso mount can use jwks_url + bound_issuer against the VSO
# cluster's default kind service account issuer, without any kind API
# server issuer/JWKS override. This test locks in that decision (see
# docs/vso-jwt-oidc-auth-task-02.md) by asserting:
#
#   1. scripts/kind/vso-lab-config.yaml.tmpl does NOT set
#      apiServer.extraArgs.service-account-issuer or
#      service-account-jwks-uri (no unexpected reconfiguration).
#   2. The template still has the certSANs entry for ${TWO_CLUSTER_HOST}
#      and the apiServerPort mapping to ${VSO_API_HOST_PORT} - the two
#      things the jwks_url reachability plan actually depends on.
#   3. Both scripts/create-clusters.sh and the template reference the
#      decision doc(s) in their comments, so the "why" stays discoverable.
#
# This is a static/text validation test only - it never creates or
# mutates a kind cluster.
#
# Usage: scripts/tests/test-vso-lab-kind-config-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VSO_TEMPLATE="${REPO_ROOT}/scripts/kind/vso-lab-config.yaml.tmpl"
CREATE_CLUSTERS="${REPO_ROOT}/scripts/create-clusters.sh"

pass=0
fail=0

assert_not_contains() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo "FAIL: $desc (found unexpected match for: $pattern in $file)"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

assert_contains() {
  local desc="$1" pattern="$2" file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo "FAIL: $desc (expected to find: $pattern in $file)"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

if [ ! -f "$VSO_TEMPLATE" ]; then
  echo "FAIL: expected file not found: $VSO_TEMPLATE"
  fail=$((fail + 1))
else
  # 1. No service account issuer/JWKS API server overrides - the "not
  #    required" decision from tasks 01/02.
  assert_not_contains \
    "vso-lab-config.yaml.tmpl does not set service-account-issuer" \
    '^\s*service-account-issuer:' \
    "$VSO_TEMPLATE"

  assert_not_contains \
    "vso-lab-config.yaml.tmpl does not set service-account-jwks-uri" \
    '^\s*service-account-jwks-uri:' \
    "$VSO_TEMPLATE"

  # 2. Reachability-critical config still present: certSANs for
  #    TWO_CLUSTER_HOST and the apiServerPort mapping to VSO_API_HOST_PORT.
  assert_contains \
    "vso-lab-config.yaml.tmpl still adds \${TWO_CLUSTER_HOST} to certSANs" \
    '"\$\{TWO_CLUSTER_HOST\}"' \
    "$VSO_TEMPLATE"

  assert_contains \
    "vso-lab-config.yaml.tmpl still maps apiServerPort to \${VSO_API_HOST_PORT}" \
    'apiServerPort: \$\{VSO_API_HOST_PORT\}' \
    "$VSO_TEMPLATE"

  # 3. Decision is documented in-place, not just in a separate doc.
  assert_contains \
    "vso-lab-config.yaml.tmpl references the issuer/JWKS decision doc" \
    "vso-jwt-oidc-auth-task-02.md" \
    "$VSO_TEMPLATE"
fi

if [ ! -f "$CREATE_CLUSTERS" ]; then
  echo "FAIL: expected file not found: $CREATE_CLUSTERS"
  fail=$((fail + 1))
else
  assert_contains \
    "create-clusters.sh references the issuer/JWKS decision doc" \
    "vso-jwt-oidc-auth-task-02.md" \
    "$CREATE_CLUSTERS"

  assert_not_contains \
    "create-clusters.sh does not render service-account-issuer args" \
    'service-account-issuer=' \
    "$CREATE_CLUSTERS"
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
