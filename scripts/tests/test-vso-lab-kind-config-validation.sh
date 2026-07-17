#!/usr/bin/env bash
# scripts/tests/test-vso-lab-kind-config-validation.sh
#
# Static contract for the externally reachable ServiceAccount OIDC issuer
# described in docs/vso-oidc-discovery-handoff.md. It asserts that:
#
#   1. The kubeadm v1beta4 API-server config sets the external issuer and
#      advertised JWKS URI using the list-of-name/value extraArgs schema.
#   2. The template retains the external hostname certificate SAN and stable
#      API-server host-port mapping needed for TLS-verified discovery.
#   3. The implementation comments link back to the discovery handoff.
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
  # 1. kubeadm v1beta4 represents API-server extraArgs as a list.
  assert_contains \
    "vso-lab-config.yaml.tmpl uses kubeadm v1beta4" \
    'apiVersion: kubeadm.k8s.io/v1beta4' \
    "$VSO_TEMPLATE"

  assert_contains \
    "vso-lab-config.yaml.tmpl sets the externally reachable service-account issuer" \
    'name: service-account-issuer' \
    "$VSO_TEMPLATE"

  assert_contains \
    "vso-lab-config.yaml.tmpl renders the issuer from host and stable API port" \
    'value: "https://\$\{TWO_CLUSTER_HOST\}:\$\{VSO_API_HOST_PORT\}"' \
    "$VSO_TEMPLATE"

  assert_contains \
    "vso-lab-config.yaml.tmpl sets the advertised service-account JWKS URI" \
    'name: service-account-jwks-uri' \
    "$VSO_TEMPLATE"

  assert_contains \
    "vso-lab-config.yaml.tmpl advertises the external JWKS endpoint" \
    'value: "https://\$\{TWO_CLUSTER_HOST\}:\$\{VSO_API_HOST_PORT\}/openid/v1/jwks"' \
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
    "vso-lab-config.yaml.tmpl references the OIDC discovery handoff" \
    "vso-oidc-discovery-handoff.md" \
    "$VSO_TEMPLATE"
fi

if [ ! -f "$CREATE_CLUSTERS" ]; then
  echo "FAIL: expected file not found: $CREATE_CLUSTERS"
  fail=$((fail + 1))
else
  assert_contains \
    "create-clusters.sh references the OIDC discovery handoff" \
    "vso-oidc-discovery-handoff.md" \
    "$CREATE_CLUSTERS"

  assert_contains \
    "create-clusters.sh renders the external host placeholder" \
    'TWO_CLUSTER_HOST' \
    "$CREATE_CLUSTERS"

  assert_contains \
    "create-clusters.sh renders the stable VSO API port placeholder" \
    'VSO_API_HOST_PORT' \
    "$CREATE_CLUSTERS"
fi

echo ""
echo "Results: $pass passed, $fail failed."
if [ "$fail" -ne 0 ]; then
  exit 1
fi
