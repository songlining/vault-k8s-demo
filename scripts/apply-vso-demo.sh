#!/usr/bin/env bash
# scripts/apply-vso-demo.sh
#
# Applies the VSO custom resources (VaultConnection/VaultAuth/
# VaultStaticSecret) and the plain consuming app pod (vso-demo-app) in the
# VSO cluster (VSO_CONTEXT, default kind-vso-lab) ONLY.
#
# This is the cross-cluster "wire it up" step that depends on:
#   - scripts/setup-vault-cluster.sh:            Vault running + seeded
#     secret (kv-v2/vault-demo/mysecret) + cross-cluster NodePort exposure
#     (VAULT_ADDR, see scripts/lib/two-cluster-env.sh)
#   - scripts/setup-vso-cluster.sh:               VSO operator installed +
#     vso-demo namespace/service account in the VSO cluster
#   - scripts/configure-vso-jwt-auth.sh:           auth/jwt-vso (dedicated,
#     cross-cluster JWT/OIDC auth mount, validated via the VSO cluster's
#     JWKS signing keys -- no TokenReview, no reviewer JWT) configured in
#     the Vault cluster
#
# What this script does, all in VSO_CONTEXT only:
#   - Re-seeds kv-v2/vault-demo/mysecret to the baseline value in the Vault
#     cluster (VAULT_CONTEXT) so the demo/rotation flow starts clean.
#   - Applies VaultConnection (spec.address = VAULT_ADDR, the *external*
#     host.containers.internal address -- never the same-cluster
#     vault.default.svc.cluster.local DNS name, which VSO cluster pods
#     cannot resolve).
#   - Applies VaultAuth (method: jwt, mount: jwt-vso, role: vso-demo,
#     service account: vso-demo, audiences: vault, short-lived projected
#     token). This is a projected ServiceAccount token JWT login -- no
#     TokenReview call back to the VSO cluster's API server, and no
#     token_reviewer_jwt stored anywhere.
#   - Applies VaultStaticSecret (kv-v2/vault-demo/mysecret -> native Secret
#     vso-demo-mysecret, refreshAfter 30s).
#   - Recreates the plain vso-demo-app pod (envFrom the native Secret; no
#     Vault annotations, no sidecar).
#   - Waits for the native Secret to materialize with the expected baseline
#     value, then waits for the app pod to become Ready.
#
# This script deliberately does NOT touch the Vault cluster's CRDs (there
# are none -- VSO and its CRDs only exist in the VSO cluster) and does NOT
# install VSO itself or configure Vault JWT/OIDC auth; see
# scripts/setup-vso-cluster.sh and scripts/configure-vso-jwt-auth.sh for
# those.
#
# Usage:
#   scripts/apply-vso-demo.sh
#   scripts/apply-vso-demo.sh --check-only   # validate tools/context only
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VAULT_CONTEXT,
# VSO_CONTEXT, VAULT_ADDR, VSO_NAMESPACE, VSO_JWT_AUTH_MOUNT,
# VSO_JWT_AUTH_ROLE, VSO_JWT_AUDIENCE, SECRET_NAME, APP_POD, NAMESPACE),
# plus BASELINE_USERNAME (default: larry) and SYNC_ATTEMPTS (default: 30).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/two-cluster-env.sh
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

BASELINE_USERNAME="${BASELINE_USERNAME:-larry}"
SYNC_ATTEMPTS="${SYNC_ATTEMPTS:-30}"

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-only)
      CHECK_ONLY=1
      ;;
    -h|--help)
      sed -n '2,45p' "${BASH_SOURCE[0]}"
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
require_commands kubectl base64 || fail=1
require_contexts || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK: required commands present and VAULT_CONTEXT/VSO_CONTEXT both exist and differ."
  exit 0
fi

echo "==> Applying the VSO demo (CRDs + consuming app) in context '${VSO_CONTEXT}'"
echo "    Vault cluster (secret source): ${VAULT_CONTEXT}"
echo "    VSO cluster (CRDs + app):      ${VSO_CONTEXT}"
echo "    Vault external address:        ${VAULT_ADDR}"
echo "    Auth mount:                    ${VSO_JWT_AUTH_MOUNT}"
echo ""

# --- Seed the Vault secret to its baseline value ----------------------------
#
# Runs against the Vault cluster only, so the demo/rotation flow always
# starts from a known value regardless of what a previous run left behind.

VAULT_POD=$(kubectl_vault get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$VAULT_POD" ]; then
  echo "ERROR: no Vault pod found in context '${VAULT_CONTEXT}' namespace '${NAMESPACE}'." >&2
  echo "       Run scripts/setup-vault-cluster.sh first." >&2
  exit 1
fi

echo "==> Seeding kv-v2/vault-demo/mysecret to baseline (username=${BASELINE_USERNAME}) in ${VAULT_CONTEXT}..."
kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- \
  vault kv put kv-v2/vault-demo/mysecret username="${BASELINE_USERNAME}" >/dev/null

# --- Preflight: vso-demo namespace + service account must already exist ----

if ! kubectl_vso get serviceaccount vso-demo -n "$VSO_NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: service account 'vso-demo' not found in namespace '${VSO_NAMESPACE}' of context '${VSO_CONTEXT}'." >&2
  echo "       Run scripts/setup-vso-cluster.sh first." >&2
  exit 1
fi

# --- Apply VaultConnection / VaultAuth / VaultStaticSecret ------------------
#
# VaultConnection.spec.address MUST be the external, cross-cluster address
# (VAULT_ADDR, e.g. http://host.containers.internal:8200) -- pods in the VSO
# cluster cannot resolve vault.default.svc.cluster.local, which only exists
# inside the Vault cluster's own cluster network.
#
# VaultAuth.spec.mount is the dedicated cross-cluster auth/jwt-vso mount
# configured by scripts/configure-vso-jwt-auth.sh, never the same-cluster
# auth/kubernetes mount used by the Agent Injector/OTel paths. method: jwt
# uses VSO's built-in projected ServiceAccount token support
# (jwt.serviceAccount) -- VSO requests a short-lived, audience-scoped
# token directly from the VSO cluster's API server and presents it to
# Vault's JWT auth mount, which validates it against the VSO cluster's
# JWKS keys. No token_reviewer_jwt is stored anywhere in this path.

echo "==> Applying VaultConnection/VaultAuth/VaultStaticSecret in '${VSO_CONTEXT}'..."
kubectl_vso apply -f - <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vso-demo-connection
  namespace: ${VSO_NAMESPACE}
spec:
  address: ${VAULT_ADDR}
  skipTLSVerify: true
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vso-demo-auth
  namespace: ${VSO_NAMESPACE}
spec:
  vaultConnectionRef: vso-demo-connection
  method: jwt
  mount: ${VSO_JWT_AUTH_MOUNT}
  jwt:
    role: ${VSO_JWT_AUTH_ROLE}
    serviceAccount: vso-demo
    audiences:
      - ${VSO_JWT_AUDIENCE}
    tokenExpirationSeconds: 600
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: ${SECRET_NAME}
  namespace: ${VSO_NAMESPACE}
spec:
  vaultAuthRef: vso-demo-auth
  mount: kv-v2
  type: kv-v2
  path: vault-demo/mysecret
  refreshAfter: 30s
  destination:
    name: ${SECRET_NAME}
    create: true
EOF

# --- Recreate the plain consuming app pod -----------------------------------
#
# Recreated (not just re-applied) so a re-run always picks up a fresh pod
# whose env is populated from whatever Secret exists at pod start -- matches
# the same pattern used for vault-demo in scripts/setup-vault-cluster.sh.
# This pod carries NO vault.hashicorp.com annotations and runs a single
# container: it consumes the native Secret purely via standard Kubernetes
# envFrom, with zero Vault awareness.

echo "==> Recreating the consuming app pod '${APP_POD}' in '${VSO_CONTEXT}'..."
kubectl_vso delete pod "${APP_POD}" -n "$VSO_NAMESPACE" --ignore-not-found=true --wait=true

kubectl_vso apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${APP_POD}
  namespace: ${VSO_NAMESPACE}
spec:
  serviceAccountName: vso-demo
  restartPolicy: OnFailure
  containers:
    - name: app
      image: badouralix/curl-jq
      command: ["sh", "-c", "sleep infinity"]
      resources: {}
      envFrom:
        - secretRef:
            name: ${SECRET_NAME}
EOF

# --- Wait for the native Secret to materialize with the expected value -----

echo "==> Waiting for VSO to materialize the native Secret '${SECRET_NAME}' in '${VSO_NAMESPACE}'..."
VSO_SYNCED="false"
for i in $(seq 1 "$SYNC_ATTEMPTS"); do
  VSO_VALUE=$(kubectl_vso get secret "${SECRET_NAME}" -n "$VSO_NAMESPACE" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
  echo "    attempt ${i}: ${VSO_VALUE:-<not yet synced>}"
  if [ "$VSO_VALUE" = "$BASELINE_USERNAME" ]; then
    VSO_SYNCED="true"
    break
  fi
  sleep 3
done

if [ "$VSO_SYNCED" != "true" ]; then
  echo "ERROR: VSO did not materialize secret '${SECRET_NAME}' with username=${BASELINE_USERNAME}." >&2
  echo "       Inspect with: kubectl --context ${VSO_CONTEXT} describe vaultstaticsecret ${SECRET_NAME} -n ${VSO_NAMESPACE}" >&2
  echo "       and:          kubectl --context ${VSO_CONTEXT} logs -n ${VSO_OPERATOR_NAMESPACE} -l app.kubernetes.io/name=vault-secrets-operator" >&2
  exit 1
fi

echo "==> Waiting for '${APP_POD}' to become Ready..."
kubectl_vso wait -n "$VSO_NAMESPACE" --for=condition=Ready "pod/${APP_POD}" --timeout=180s

echo ""
echo "VSO demo applied in context '${VSO_CONTEXT}':"
echo "  - VaultConnection 'vso-demo-connection' -> ${VAULT_ADDR}"
echo "  - VaultAuth 'vso-demo-auth' (method: jwt, mount: ${VSO_JWT_AUTH_MOUNT}, role: ${VSO_JWT_AUTH_ROLE})"
echo "  - VaultStaticSecret '${SECRET_NAME}' <- kv-v2/vault-demo/mysecret (refreshAfter 30s)"
echo "  - Native Secret '${SECRET_NAME}' synced with username=${BASELINE_USERNAME}"
echo "  - Consuming pod '${APP_POD}' (1/1, no vault.hashicorp.com annotations)"
