#!/usr/bin/env bash
# scripts/prepare-vso-deck-env.sh
#
# Brings an existing Podman-backed two-cluster VSO lab back online before
# `make vso-deck` verifies it. Missing kind control-plane containers are left
# for the setup fallback to create; existing stopped containers are restarted
# and checked for Kubernetes readiness.
#
# This script does not install Vault or VSO and does not change demo data.
# The Makefile next verifies the existing environment and reuses healthy
# resources unchanged. It runs setup only when that verification fails.
#
# Usage:
#   KIND_EXPERIMENTAL_PROVIDER=podman scripts/prepare-vso-deck-env.sh
#   scripts/prepare-vso-deck-env.sh --check-only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

PODMAN_MACHINE_NAME="${PODMAN_MACHINE_NAME:-}"
PODMAN_READY_ATTEMPTS="${PODMAN_READY_ATTEMPTS:-30}"
PODMAN_READY_SLEEP="${PODMAN_READY_SLEEP:-2}"
KUBERNETES_READY_ATTEMPTS="${KUBERNETES_READY_ATTEMPTS:-60}"
KUBERNETES_READY_SLEEP="${KUBERNETES_READY_SLEEP:-2}"
KUBERNETES_NODE_TIMEOUT="${KUBERNETES_NODE_TIMEOUT:-120s}"

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-only)
      CHECK_ONLY=1
      ;;
    -h|--help)
      sed -n '2,15p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg' (supported: --check-only)" >&2
      exit 1
      ;;
  esac
done

fail=0
require_commands podman kubectl kind || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK: podman, kubectl, and kind are available; no machine, container, or cluster state was changed."
  exit 0
fi

ensure_podman_ready() {
  if podman info >/dev/null 2>&1; then
    echo "OK: Podman runtime is available."
    return 0
  fi

  if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: Podman is unavailable and automatic 'podman machine start' is only supported here on macOS." >&2
    echo "       Start the Podman service, then re-run 'make vso-deck'." >&2
    return 1
  fi

  echo "==> Podman runtime is unavailable; starting the Podman machine..."
  if [ -n "$PODMAN_MACHINE_NAME" ]; then
    podman machine start "$PODMAN_MACHINE_NAME"
  else
    podman machine start
  fi

  local attempt
  for attempt in $(seq 1 "$PODMAN_READY_ATTEMPTS"); do
    if podman info >/dev/null 2>&1; then
      echo "OK: Podman runtime became available (attempt ${attempt}/${PODMAN_READY_ATTEMPTS})."
      return 0
    fi
    sleep "$PODMAN_READY_SLEEP"
  done

  echo "ERROR: Podman did not become ready after ${PODMAN_READY_ATTEMPTS} attempts." >&2
  echo "       Check 'podman machine list' and 'podman info', then re-run 'make vso-deck'." >&2
  return 1
}

wait_for_kubernetes() {
  local context="$1"
  local label="$2"
  local attempt

  echo "==> Checkpoint: waiting for ${label} API (${context})..."
  for attempt in $(seq 1 "$KUBERNETES_READY_ATTEMPTS"); do
    if kubectl --context "$context" get --raw=/readyz >/dev/null 2>&1 \
        && [ -n "$(kubectl --context "$context" get nodes -o name 2>/dev/null || true)" ]; then
      echo "OK: ${label} API is responding (attempt ${attempt}/${KUBERNETES_READY_ATTEMPTS})."
      break
    fi
    if [ "$attempt" -eq "$KUBERNETES_READY_ATTEMPTS" ]; then
      echo "ERROR: ${label} API (${context}) did not become ready." >&2
      echo "       Inspect the node container with: podman logs ${label}-control-plane" >&2
      return 1
    fi
    sleep "$KUBERNETES_READY_SLEEP"
  done

  echo "==> Checkpoint: waiting for ${label} node Ready (${context})..."
  if ! kubectl --context "$context" wait \
      --for=condition=Ready node --all --timeout="$KUBERNETES_NODE_TIMEOUT"; then
    echo "ERROR: ${label} node did not become Ready in context '${context}'." >&2
    kubectl --context "$context" get nodes -o wide >&2 || true
    return 1
  fi
  echo "OK: ${label} node is Ready."
}

prepare_existing_cluster() {
  local cluster_name="$1"
  local context="$2"
  local label="$3"
  local container="${cluster_name}-control-plane"
  local state

  if ! podman container exists "$container"; then
    echo "NOTE: '${container}' does not exist; 'make setup' will create ${label}."
    return 0
  fi

  state="$(podman inspect --format '{{.State.Status}}' "$container")"
  case "$state" in
    running)
      echo "OK: ${label} control plane '${container}' is already running."
      ;;
    exited|stopped|created|configured)
      echo "==> Starting ${label} control plane '${container}' (state: ${state})..."
      podman start "$container" >/dev/null
      echo "OK: ${label} control plane started."
      ;;
    paused)
      echo "ERROR: ${label} control plane '${container}' is paused." >&2
      echo "       Run 'podman unpause ${container}', then re-run 'make vso-deck'." >&2
      return 1
      ;;
    *)
      echo "ERROR: ${label} control plane '${container}' has unsupported state '${state}'." >&2
      echo "       Inspect it with: podman inspect ${container}" >&2
      return 1
      ;;
  esac

  if ! context_exists "$context"; then
    echo "==> Kubeconfig context '${context}' is missing; exporting it from kind cluster '${cluster_name}'..."
    if ! KIND_EXPERIMENTAL_PROVIDER=podman kind export kubeconfig --name "$cluster_name"; then
      echo "ERROR: failed to export kubeconfig for existing kind cluster '${cluster_name}'." >&2
      return 1
    fi
    if ! context_exists "$context"; then
      echo "ERROR: kind export completed but expected context '${context}' is still missing." >&2
      return 1
    fi
    echo "OK: restored kubeconfig context '${context}'."
  fi

  wait_for_kubernetes "$context" "$cluster_name"
}

echo "==> Preparing the Podman-backed VSO deck environment"
ensure_podman_ready
prepare_existing_cluster "$VAULT_KIND_CLUSTER_NAME" "$VAULT_CONTEXT" "Vault cluster"
prepare_existing_cluster "$VSO_KIND_CLUSTER_NAME" "$VSO_CONTEXT" "VSO cluster"

echo ""
echo "OK: runtime/startup checkpoints passed."
echo "    Next gate: verify and reuse healthy resources; run setup only if verification fails."
