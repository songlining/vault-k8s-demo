#!/usr/bin/env bash
# scripts/check-vault-connectivity.sh
#
# Reusable cross-cluster connectivity check: proves that a pod running in
# the VSO cluster (VSO_CONTEXT, default kind-vso-lab) can reach Vault at
# VAULT_ADDR (default http://host.containers.internal:8200) -- the same
# address VSO's VaultConnection resource uses (see scripts/lib/two-cluster-env.sh
# and task 05/expose-vault-cross-cluster).
#
# It deliberately does NOT use vault.default.svc.cluster.local or any other
# Vault-cluster-internal DNS name, since those only resolve inside the Vault
# cluster's own cluster network.
#
# This script is one-shot and stateless: it runs a throwaway curl pod via
# `kubectl run --rm -i --restart=Never` in the VSO cluster, reads Vault's
# /v1/sys/health response, and evaluates the HTTP status code against the
# set Vault itself documents as "healthy enough to prove connectivity"
# (initialized-but-sealed, standby, etc. all count -- this is a network/
# reachability check, not a Vault-readiness check).
#
# Usage:
#   scripts/check-vault-connectivity.sh
#   scripts/check-vault-connectivity.sh --check-only   # validate tools/context only, no pod run
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VSO_CONTEXT,
# VAULT_ADDR, TWO_CLUSTER_HOST, VAULT_HOST_PORT).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/two-cluster-env.sh
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

CHECK_ONLY=0
CHECK_POD_NAME="${CHECK_POD_NAME:-vault-connectivity-check}"
CHECK_IMAGE="${CHECK_IMAGE:-curlimages/curl}"
CHECK_HEALTH_PATH="${CHECK_HEALTH_PATH:-/v1/sys/health}"

for arg in "$@"; do
  case "$arg" in
    --check-only)
      CHECK_ONLY=1
      ;;
    -h|--help)
      sed -n '2,25p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg' (supported: --check-only)" >&2
      exit 1
      ;;
  esac
done

# --- Validation ------------------------------------------------------------

fail=0
require_commands kubectl || fail=1
require_context "$VSO_CONTEXT" || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK: required commands present and context '$VSO_CONTEXT' exists."
  exit 0
fi

# --- Explain the assumption up front, before we run anything ---------------

echo "==> Checking Vault reachability from a pod in '${VSO_CONTEXT}'..."
echo "    VAULT_ADDR=${VAULT_ADDR}"
echo "    (This relies on Podman's host gateway resolving '${TWO_CLUSTER_HOST}'"
echo "     from inside kind's pod network, and on the Vault cluster's kind"
echo "     config mapping NodePort ${VAULT_NODE_PORT} -> host port ${VAULT_HOST_PORT}"
echo "     via extraPortMappings. See scripts/kind/vault-lab-config.yaml.tmpl.)"
echo ""

# Clean up any stale pod from a previous interrupted run before starting.
kubectl_vso delete pod "$CHECK_POD_NAME" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true

HEALTH_URL="${VAULT_ADDR}${CHECK_HEALTH_PATH}"

set +e
POD_OUTPUT=$(kubectl_vso run "$CHECK_POD_NAME" \
  --rm -i --restart=Never \
  --image="$CHECK_IMAGE" \
  --command -- sh -c \
  "http_code=\$(curl -s -o /tmp/health.json -w '%{http_code}' --max-time 10 '${HEALTH_URL}' 2>/tmp/health.err); echo \"HTTP_CODE=\${http_code}\"; echo '--- body ---'; cat /tmp/health.json 2>/dev/null; echo ''; echo '--- curl stderr ---'; cat /tmp/health.err 2>/dev/null" \
  2>&1)
POD_STATUS=$?
set -e

echo "$POD_OUTPUT"
echo ""

HTTP_CODE=$(printf '%s\n' "$POD_OUTPUT" | grep -m1 '^HTTP_CODE=' | cut -d= -f2)

# Vault's /v1/sys/health intentionally returns non-200 codes to signal state
# (sealed, standby, uninitialized, etc.) without that being a connectivity
# problem. Any of these codes means the HTTP request round-tripped through
# to Vault, which is exactly what this check is proving.
case "$HTTP_CODE" in
  200|429|472|473|501|503)
    echo "OK: reached Vault at ${HEALTH_URL} (HTTP ${HTTP_CODE}) from a pod in '${VSO_CONTEXT}'."
    exit 0
    ;;
  "" | 000)
    echo "ERROR: could not reach Vault at ${HEALTH_URL} from a pod in '${VSO_CONTEXT}' (no HTTP response)." >&2
    echo "" >&2
    echo "This usually means one of the Podman Desktop / kind networking assumptions" >&2
    echo "documented in PODMAN_MIGRATION.md is not holding, e.g.:" >&2
    echo "  - '${TWO_CLUSTER_HOST}' does not resolve to Podman's host gateway from" >&2
    echo "    inside a kind pod on this OS/Podman version." >&2
    echo "  - The Vault cluster's kind extraPortMappings (NodePort ${VAULT_NODE_PORT} ->" >&2
    echo "    host port ${VAULT_HOST_PORT}) were not applied -- confirm with:" >&2
    echo "      podman inspect ${VAULT_KIND_CLUSTER_NAME}-control-plane --format '{{.NetworkSettings.Ports}}'" >&2
    echo "  - Vault's 'vault-external' NodePort Service is missing in the Vault" >&2
    echo "    cluster -- confirm with:" >&2
    echo "      kubectl --context ${VAULT_CONTEXT} get svc vault-external -n ${NAMESPACE}" >&2
    echo "  - Podman machine/VM is not running, or was restarted after the clusters" >&2
    echo "    were created (host gateway routes can reset) -- try: podman machine start" >&2
    if [ "$POD_STATUS" -ne 0 ]; then
      exit "$POD_STATUS"
    fi
    exit 1
    ;;
  *)
    echo "WARNING: reached Vault at ${HEALTH_URL} but got an unexpected HTTP status: ${HTTP_CODE}." >&2
    echo "         Treating this as a connectivity success (the request round-tripped)," >&2
    echo "         but check the response body above for anything unexpected." >&2
    exit 0
    ;;
esac
