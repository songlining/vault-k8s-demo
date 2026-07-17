#!/usr/bin/env bash
# scripts/create-clusters.sh
#
# Deterministic two-cluster bootstrap for the VSO Podman demo.
#
# Creates (or validates/reuses) two Podman-backed kind clusters:
#   - kind-vault-lab  (VAULT_CONTEXT) - runs Vault only.
#   - kind-vso-lab    (VSO_CONTEXT)   - runs VSO, VSO CRDs, and vso-demo-app.
#
# This script only creates/validates the clusters and their networking
# contract (host ports, API server cert SANs). It does not install Vault,
# VSO, or any demo workloads - see scripts/setup-vault-cluster.sh and
# scripts/setup-vso-cluster.sh for that.
#
# ServiceAccount OIDC issuer (Vault JWT/OIDC auth for VSO):
#   The VSO kind template configures its API server as a self-consistent,
#   externally reachable issuer at
#   https://${TWO_CLUSTER_HOST}:${VSO_API_HOST_PORT}. The JWT `iss`, discovery
#   document `issuer`, Vault `oidc_discovery_url`, and advertised external JWKS
#   endpoint therefore agree. Only the VSO cluster changes; the Vault cluster's
#   same-cluster Kubernetes auth remains on kubeadm defaults. See
#   docs/vso-oidc-discovery-handoff.md.
#
# Usage:
#   KIND_EXPERIMENTAL_PROVIDER=podman scripts/create-clusters.sh
#   scripts/create-clusters.sh --check-only   # validate tools/env, no cluster changes
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VAULT_CONTEXT,
# VSO_CONTEXT, VAULT_KIND_CLUSTER_NAME, VSO_KIND_CLUSTER_NAME,
# TWO_CLUSTER_HOST, VAULT_HOST_PORT, VAULT_NODE_PORT, VSO_API_HOST_PORT).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/two-cluster-env.sh
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-only)
      CHECK_ONLY=1
      ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg' (supported: --check-only)" >&2
      exit 1
      ;;
  esac
done

# --- Validation ---------------------------------------------------------

require_podman_provider() {
  if [ "${KIND_EXPERIMENTAL_PROVIDER:-}" != "podman" ]; then
    cat >&2 <<'EOF'
ERROR: KIND_EXPERIMENTAL_PROVIDER=podman is not set.

This demo requires Podman-backed kind clusters (per IBM container runtime
policy). Set the variable and re-run, e.g.:

  export KIND_EXPERIMENTAL_PROVIDER=podman
  scripts/create-clusters.sh

See PODMAN_MIGRATION.md for full Podman setup instructions.
EOF
    return 1
  fi
}

require_podman_machine_running() {
  # Best-effort check; only meaningful on macOS where Podman runs in a VM.
  if command -v podman >/dev/null 2>&1; then
    if podman machine list --format '{{.Name}}' >/dev/null 2>&1; then
      if ! podman machine list --format '{{.Running}}' 2>/dev/null | grep -qi true; then
        echo "WARNING: no running 'podman machine' detected. If cluster creation hangs, run: podman machine start" >&2
      fi
    fi
  fi
}

fail=0
require_commands kind kubectl podman || fail=1
require_podman_provider || fail=1
validate_vso_oidc_env || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi
require_podman_machine_running

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK: required commands present and KIND_EXPERIMENTAL_PROVIDER=podman is set."
  exit 0
fi

# --- Render kind config from centralized ports/names --------------------

render_config() {
  local template="$1"
  local out="$2"
  sed \
    -e "s|\${VAULT_KIND_CLUSTER_NAME}|${VAULT_KIND_CLUSTER_NAME}|g" \
    -e "s|\${VSO_KIND_CLUSTER_NAME}|${VSO_KIND_CLUSTER_NAME}|g" \
    -e "s|\${VAULT_HOST_PORT}|${VAULT_HOST_PORT}|g" \
    -e "s|\${VAULT_NODE_PORT}|${VAULT_NODE_PORT}|g" \
    -e "s|\${VSO_API_HOST_PORT}|${VSO_API_HOST_PORT}|g" \
    -e "s|\${TWO_CLUSTER_HOST}|${TWO_CLUSTER_HOST}|g" \
    "$template" > "$out"
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

VAULT_KIND_CONFIG="${WORK_DIR}/vault-lab-config.yaml"
VSO_KIND_CONFIG="${WORK_DIR}/vso-lab-config.yaml"
render_config "${SCRIPT_DIR}/kind/vault-lab-config.yaml.tmpl" "$VAULT_KIND_CONFIG"
render_config "${SCRIPT_DIR}/kind/vso-lab-config.yaml.tmpl" "$VSO_KIND_CONFIG"

# --- Idempotent create-or-reuse -----------------------------------------
#
# `kind get clusters` shells out to `podman ps ... --format {{index .Labels
# "..."}}` internally, which is known to break on some podman client/server
# version combinations (podman's ps --format renders Labels as a flat string
# rather than a map). Rather than depend on that listing working, attempt the
# create directly and treat kind's own "already exist" error as the reuse
# signal - this keeps the script idempotent even when `kind get clusters` is
# broken in the local environment.

create_or_reuse_cluster() {
  local name="$1"
  local config="$2"
  local out
  echo "==> Ensuring kind cluster '${name}' exists (KIND_EXPERIMENTAL_PROVIDER=podman)..."
  if out=$(KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --name "$name" --config "$config" 2>&1); then
    echo "$out"
    return 0
  fi
  echo "$out" >&2
  if echo "$out" | grep -qi 'already exist'; then
    echo "==> kind cluster '${name}' already exists, reusing it."
    return 0
  fi
  echo "ERROR: failed to create kind cluster '${name}'." >&2
  return 1
}

echo "Vault cluster:  ${VAULT_KIND_CLUSTER_NAME} (context ${VAULT_CONTEXT}), Vault host port ${VAULT_HOST_PORT} -> NodePort ${VAULT_NODE_PORT}"
echo "VSO cluster:    ${VSO_KIND_CLUSTER_NAME} (context ${VSO_CONTEXT}), OIDC issuer ${VSO_OIDC_DISCOVERY_URL}, certSAN ${TWO_CLUSTER_HOST}"
echo ""

create_or_reuse_cluster "$VAULT_KIND_CLUSTER_NAME" "$VAULT_KIND_CONFIG"
create_or_reuse_cluster "$VSO_KIND_CLUSTER_NAME" "$VSO_KIND_CONFIG"

# --- Confirm resulting contexts ------------------------------------------

echo ""
echo "==> Verifying kubeconfig contexts..."
missing_context=0
for ctx in "$VAULT_CONTEXT" "$VSO_CONTEXT"; do
  if kubectl config get-contexts "$ctx" >/dev/null 2>&1; then
    echo "OK: context '$ctx' present."
  else
    echo "ERROR: expected context '$ctx' not found in kubeconfig." >&2
    missing_context=1
  fi
done

if [ "$missing_context" -ne 0 ]; then
  exit 1
fi

# A kind cluster's ServiceAccount issuer is fixed when kube-apiserver starts.
# Never silently reuse a pre-discovery VSO cluster: setup cannot repair that
# control-plane drift, and automatic deletion would destroy user resources.
if ! VSO_DISCOVERY_DOCUMENT=$(kubectl --context "$VSO_CONTEXT" get \
    --raw='/.well-known/openid-configuration' 2>/dev/null); then
  echo "ERROR: could not retrieve OIDC discovery metadata from context '${VSO_CONTEXT}'." >&2
  echo "       Check the API server, kubeconfig context, and authorization before retrying." >&2
  echo "       This does not prove creation-time issuer drift; do not recreate the cluster" >&2
  echo "       based on this retrieval failure alone." >&2
  exit 1
fi
COMPACT_VSO_DISCOVERY=$(printf '%s' "$VSO_DISCOVERY_DOCUMENT" | tr -d '[:space:]')
if ! printf '%s' "$COMPACT_VSO_DISCOVERY" | grep -qF '"issuer":' \
    || ! printf '%s' "$COMPACT_VSO_DISCOVERY" | grep -qF '"jwks_uri":'; then
  echo "ERROR: VSO OIDC discovery response is missing issuer or jwks_uri metadata." >&2
  echo "       Inspect the API server response; this is not proof that recreation is required." >&2
  unset VSO_DISCOVERY_DOCUMENT COMPACT_VSO_DISCOVERY
  exit 1
fi
if ! printf '%s' "$COMPACT_VSO_DISCOVERY" | grep -qF \
    "\"issuer\":\"${VSO_OIDC_DISCOVERY_URL}\"" \
    || ! printf '%s' "$COMPACT_VSO_DISCOVERY" | grep -qF \
    "\"jwks_uri\":\"${VSO_OIDC_JWKS_URL}\""; then
  echo "ERROR: existing VSO cluster '${VSO_KIND_CLUSTER_NAME}' does not have the required" >&2
  echo "       externally reachable ServiceAccount OIDC issuer/JWKS metadata." >&2
  echo "       Expected issuer:   ${VSO_OIDC_DISCOVERY_URL}" >&2
  echo "       Expected jwks_uri: ${VSO_OIDC_JWKS_URL}" >&2
  echo "       This creation-time setting cannot be reconciled in place." >&2
  echo "       Recreate only '${VSO_KIND_CLUSTER_NAME}' after explicit confirmation;" >&2
  echo "       this script will never delete it automatically." >&2
  unset VSO_DISCOVERY_DOCUMENT COMPACT_VSO_DISCOVERY
  exit 1
fi
unset VSO_DISCOVERY_DOCUMENT COMPACT_VSO_DISCOVERY
echo "OK: VSO cluster discovery issuer and advertised JWKS URI match the expected external endpoint."

echo ""
echo "Both clusters are ready. This script does not change your current"
echo "kubectl context; use explicit --context flags (or the VAULT_CONTEXT /"
echo "VSO_CONTEXT variables from scripts/lib/two-cluster-env.sh) for every"
echo "later step:"
echo ""
echo "  kubectl --context ${VAULT_CONTEXT} get pods -A"
echo "  kubectl --context ${VSO_CONTEXT} get pods -A"
