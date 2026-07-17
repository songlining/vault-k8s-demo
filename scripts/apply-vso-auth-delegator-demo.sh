#!/usr/bin/env bash
# scripts/apply-vso-auth-delegator-demo.sh
#
# Applies the cross-namespace VSO resources and dedicated Kubernetes
# identities for the CLIENT JWT SELF-REVIEW scenario in the VSO cluster
# (VSO_CONTEXT, default kind-vso-lab) ONLY. See
# docs/vso-kubernetes-auth-delegator-plan.md.
#
# Depends on (and never repeats):
#   - scripts/setup-vault-cluster.sh:               Vault running + kv-v2
#     secrets engine enabled + cross-cluster NodePort exposure (VAULT_ADDR)
#   - scripts/setup-vso-cluster.sh:                  VSO operator installed
#   - scripts/configure-vso-auth-delegator.sh:       the dedicated
#     auth/${AUTH_DELEGATOR_AUTH_MOUNT} mount, role, and
#     ${AUTH_DELEGATOR_POLICY} policy (this script never creates or
#     modifies that policy -- the configure script is its sole owner)
#
# This script never creates, deletes, or recreates a kind cluster, and never
# runs Helm install/upgrade.
#
# What this script does, all in VSO_CONTEXT (and the Vault cluster only for
# seeding the dedicated KV fixture), all idempotently:
#   - Feature-detects required VSO CRD fields and operator TokenRequest RBAC
#     (preflight_auth_delegator_runtime) before applying anything.
#   - Creates ${AUTH_DELEGATOR_AUTH_NAMESPACE} and
#     ${AUTH_DELEGATOR_APP_NAMESPACE} idempotently, labeled/annotated as
#     scenario-owned. Refuses to adopt a same-name namespace that lacks the
#     expected ownership marker.
#   - Seeds the dedicated KV fixture (kv-v2/${AUTH_DELEGATOR_KV_PATH}) only
#     when absent, via a JSON stdin payload with cas=0 (create-only-if-
#     absent), then attaches scenario ownership through KV-v2 custom
#     metadata (also via stdin). If the path already exists, requires the
#     exact ownership marker before touching it at all.
#   - Creates the self-review ServiceAccount
#     (${AUTH_DELEGATOR_SELF_REVIEW_SA}) ONLY in the app/consumer namespace,
#     with automountServiceAccountToken: false and the scenario ownership
#     label.
#   - Creates exactly ONE scenario-owned ClusterRoleBinding
#     (${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}) granting system:auth-delegator
#     to that single ServiceAccount subject and no other. Refuses to adopt
#     a same-name binding lacking the expected ownership marker, and never
#     adds a second subject to one it does own.
#   - Creates a separate, unprivileged app ServiceAccount
#     (${AUTH_DELEGATOR_APP_SA}), never bound to system:auth-delegator.
#   - Applies VaultConnection + VaultAuth in the auth namespace: method
#     kubernetes, the dedicated mount/role, serviceAccount:
#     ${AUTH_DELEGATOR_SELF_REVIEW_SA}, BOTH audiences
#     (${AUTH_DELEGATOR_VAULT_AUDIENCE}, ${AUTH_DELEGATOR_API_AUDIENCE}),
#     tokenExpirationSeconds: ${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS}, and
#     allowedNamespaces containing ONLY the app namespace.
#   - Applies VaultStaticSecret in the app namespace with vaultAuthRef
#     "${AUTH_DELEGATOR_AUTH_NAMESPACE}/${AUTH_DELEGATOR_VAULT_AUTH}"
#     (cross-namespace reference), destination Secret in the app namespace.
#   - Recreates a plain, single-container app pod in the app namespace under
#     the unprivileged app ServiceAccount (no vault.hashicorp.com
#     annotations, no sidecar), consuming the native Secret via envFrom.
#   - Waits for VaultAuth validation, VaultStaticSecret Ready, destination
#     Secret, and app pod readiness, without ever printing the secret value.
#
# Usage:
#   scripts/apply-vso-auth-delegator-demo.sh
#   scripts/apply-vso-auth-delegator-demo.sh --check-only
#
#   --check-only performs NO writes to either cluster. It runs the shared
#   preflight, renders every manifest, validates them with a server-side
#   dry-run when the live API is reachable (client-side otherwise), and
#   exits before any apply/vault write.
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VAULT_CONTEXT,
# VSO_CONTEXT, VAULT_ADDR, AUTH_DELEGATOR_*), plus BASELINE_USERNAME
# (default: larry) and SYNC_ATTEMPTS (default: 30).

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
      sed -n '2,58p' "${BASH_SOURCE[0]}"
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
require_commands kubectl jq base64 || fail=1
require_contexts || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

validate_auth_delegator_env || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

# render_auth_delegator_manifests
#
# Prints every Kubernetes manifest this script applies (namespaces,
# ServiceAccounts, ClusterRoleBinding, VaultConnection/VaultAuth,
# VaultStaticSecret, app pod). Used by both --check-only (validation only)
# and the mutating path (actual apply).
render_auth_delegator_manifests() {
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${AUTH_DELEGATOR_AUTH_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
  annotations:
    ${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY}: ${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${AUTH_DELEGATOR_APP_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
  annotations:
    ${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY}: ${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${AUTH_DELEGATOR_SELF_REVIEW_SA}
  namespace: ${AUTH_DELEGATOR_APP_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
  annotations:
    ${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY}: ${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE}
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${AUTH_DELEGATOR_APP_SA}
  namespace: ${AUTH_DELEGATOR_APP_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
  annotations:
    ${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY}: ${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
  annotations:
    ${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY}: ${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: ${AUTH_DELEGATOR_SELF_REVIEW_SA}
  namespace: ${AUTH_DELEGATOR_APP_NAMESPACE}
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: ${AUTH_DELEGATOR_VAULT_CONNECTION}
  namespace: ${AUTH_DELEGATOR_AUTH_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
spec:
  address: ${VAULT_ADDR}
  skipTLSVerify: true
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: ${AUTH_DELEGATOR_VAULT_AUTH}
  namespace: ${AUTH_DELEGATOR_AUTH_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
spec:
  vaultConnectionRef: ${AUTH_DELEGATOR_VAULT_CONNECTION}
  method: kubernetes
  mount: ${AUTH_DELEGATOR_AUTH_MOUNT}
  allowedNamespaces:
    - ${AUTH_DELEGATOR_APP_NAMESPACE}
  kubernetes:
    role: ${AUTH_DELEGATOR_ROLE}
    serviceAccount: ${AUTH_DELEGATOR_SELF_REVIEW_SA}
    audiences:
      - ${AUTH_DELEGATOR_VAULT_AUDIENCE}
      - ${AUTH_DELEGATOR_API_AUDIENCE}
    tokenExpirationSeconds: ${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS}
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: ${AUTH_DELEGATOR_VSS_NAME}
  namespace: ${AUTH_DELEGATOR_APP_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
spec:
  vaultAuthRef: ${AUTH_DELEGATOR_AUTH_NAMESPACE}/${AUTH_DELEGATOR_VAULT_AUTH}
  mount: ${AUTH_DELEGATOR_KV_MOUNT}
  type: kv-v2
  path: ${AUTH_DELEGATOR_KV_PATH}
  refreshAfter: 30s
  destination:
    name: ${AUTH_DELEGATOR_SECRET_NAME}
    create: true
---
apiVersion: v1
kind: Pod
metadata:
  name: ${AUTH_DELEGATOR_APP_POD}
  namespace: ${AUTH_DELEGATOR_APP_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
  annotations:
    ${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY}: ${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE}
spec:
  serviceAccountName: ${AUTH_DELEGATOR_APP_SA}
  automountServiceAccountToken: false
  restartPolicy: OnFailure
  containers:
    - name: app
      image: badouralix/curl-jq
      command: ["sh", "-c", "sleep infinity"]
      resources: {}
      envFrom:
        - secretRef:
            name: ${AUTH_DELEGATOR_SECRET_NAME}
EOF
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "==> [--check-only] validating environment, runtime feature support, and manifests (no writes)"

  preflight_auth_delegator_runtime || fail=1

  if context_exists "$VSO_CONTEXT" \
      && kubectl_vso get namespace "$AUTH_DELEGATOR_APP_NAMESPACE" >/dev/null 2>&1 \
      && kubectl_vso get namespace "$AUTH_DELEGATOR_AUTH_NAMESPACE" >/dev/null 2>&1 \
      && kubectl_vso auth can-i create pods -n "$AUTH_DELEGATOR_APP_NAMESPACE" >/dev/null 2>&1; then
    echo "==> Rendering manifests and validating with a server-side dry-run..."
    if render_auth_delegator_manifests | kubectl_vso apply --dry-run=server --validate=true -f - >/dev/null; then
      echo "OK: manifests are valid (server-side dry-run)."
    else
      echo "ERROR: server-side dry-run rejected the rendered manifests." >&2
      fail=1
    fi
  else
    echo "==> Rendering manifests and validating client-side only (live API not reachable/authorized)…"
    # Validate the rendered YAML purely offline so --check-only never
    # depends on a live API server. kubectl's --dry-run=client still
    # fetches the API group list, so it fails with 'connection refused'
    # when clusters are stopped. Use python3+PyYAML or yq instead.
    rendered="$(render_auth_delegator_manifests)" || { echo "ERROR: failed to render manifests." >&2; fail=1; }
    if [ "$fail" -eq 0 ]; then
      validated=0
      if python3 -c 'import yaml,sys; list(yaml.safe_load_all(sys.stdin))' <<<"$rendered" >/dev/null 2>&1; then
        echo "OK: manifests parse as valid YAML (python3+PyYAML; CRD-specific validation skipped)."
        validated=1
      elif command -v yq >/dev/null 2>&1 && printf '%s' "$rendered" | yq eval-all '.' - >/dev/null 2>&1; then
        echo "OK: manifests parse as valid YAML (yq; CRD-specific validation skipped)."
        validated=1
      fi
      if [ "$validated" -eq 0 ]; then
        if ! command -v python3 >/dev/null 2>&1 && ! command -v yq >/dev/null 2>&1; then
          echo "NOTE: no offline YAML parser available (python3+PyYAML or yq); falling back to kubectl --dry-run=client (may fail without a live API)."
          if printf '%s' "$rendered" | kubectl create --dry-run=client --validate=false -f - >/dev/null 2>&1; then
            echo "OK: manifests parse as valid Kubernetes YAML (kubectl client-side)."
            validated=1
          fi
        fi
      fi
      if [ "$validated" -eq 0 ]; then
        echo "ERROR: rendered manifests are not valid YAML." >&2
        fail=1
      fi
    fi
  fi

  if [ "$fail" -ne 0 ]; then
    exit 1
  fi
  echo ""
  echo "OK (--check-only): environment, runtime feature support, and manifests look correct. No writes performed."
  exit 0
fi

echo "==> Applying the client-JWT-self-review VSO scenario in context '${VSO_CONTEXT}'"
echo "    Vault cluster (secret source): ${VAULT_CONTEXT}"
echo "    Auth namespace:                ${AUTH_DELEGATOR_AUTH_NAMESPACE}"
echo "    App/consumer namespace:        ${AUTH_DELEGATOR_APP_NAMESPACE}"
echo ""

preflight_auth_delegator_runtime || {
  echo "ERROR: runtime feature preflight failed; see diagnostics above." >&2
  exit 1
}

# --- Preflight: dedicated Vault auth mount/role must already exist --------

VAULT_POD=$(kubectl_vault get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$VAULT_POD" ]; then
  echo "ERROR: no Vault pod found in context '${VAULT_CONTEXT}' namespace '${NAMESPACE}'." >&2
  echo "       Run scripts/setup-vault-cluster.sh first." >&2
  exit 1
fi

if ! kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault auth list 2>/dev/null | grep -q "^${AUTH_DELEGATOR_AUTH_MOUNT}/"; then
  echo "ERROR: auth/${AUTH_DELEGATOR_AUTH_MOUNT} is not enabled in context '${VAULT_CONTEXT}'." >&2
  echo "       Run scripts/configure-vso-auth-delegator.sh first." >&2
  exit 1
fi

if ! kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault policy read "${AUTH_DELEGATOR_POLICY}" >/dev/null 2>&1; then
  echo "ERROR: Vault policy '${AUTH_DELEGATOR_POLICY}' does not exist in context '${VAULT_CONTEXT}'." >&2
  echo "       Run scripts/configure-vso-auth-delegator.sh first (it is the sole owner of this policy)." >&2
  exit 1
fi

# --- Ownership-aware namespace creation ------------------------------------

ensure_owned_namespace() {
  local ns="$1"
  local existing_label
  existing_label=$(kubectl_vso get namespace "$ns" -o jsonpath="{.metadata.labels.${AUTH_DELEGATOR_OWNER_LABEL_KEY//./\\.}}" 2>/dev/null || true)
  if kubectl_vso get namespace "$ns" >/dev/null 2>&1; then
    if [ "$existing_label" != "$AUTH_DELEGATOR_OWNER_LABEL_VALUE" ]; then
      echo "ERROR: namespace '${ns}' already exists but lacks the expected ownership label (${AUTH_DELEGATOR_OWNER_LABEL_KEY}=${AUTH_DELEGATOR_OWNER_LABEL_VALUE})." >&2
      echo "       Refusing to adopt a foreign namespace." >&2
      exit 1
    fi
    echo "    namespace '${ns}' already exists and is scenario-owned."
  else
    echo "==> Creating namespace '${ns}'..."
    kubectl_vso apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
  annotations:
    ${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY}: ${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE}
EOF
  fi
}

ensure_owned_namespace "$AUTH_DELEGATOR_AUTH_NAMESPACE"
ensure_owned_namespace "$AUTH_DELEGATOR_APP_NAMESPACE"

# --- Seed the dedicated KV fixture, only when absent -----------------------
#
# Ownership is proven with KV-v2 custom metadata, not merely the path's
# existence. An unmarked or foreign path at this location is a fail-safe
# stop, not an overwrite.

echo "==> Checking kv-v2/${AUTH_DELEGATOR_KV_PATH} ownership..."
EXISTING_KV_METADATA=$(kubectl_vault exec "$VAULT_POD" -n "$NAMESPACE" -- vault kv metadata get \
  -format=json -mount="${AUTH_DELEGATOR_KV_MOUNT}" "${AUTH_DELEGATOR_KV_PATH}" 2>/dev/null || true)

if [ -n "$EXISTING_KV_METADATA" ]; then
  EXISTING_KV_MARKER=$(printf '%s' "$EXISTING_KV_METADATA" | jq -r --arg k "$AUTH_DELEGATOR_KV_METADATA_KEY" '.data.custom_metadata[$k] // empty' 2>/dev/null || true)
  if [ "$EXISTING_KV_MARKER" != "$AUTH_DELEGATOR_KV_METADATA_VALUE" ]; then
    echo "ERROR: kv-v2/${AUTH_DELEGATOR_KV_PATH} already exists but lacks the expected ownership custom_metadata (${AUTH_DELEGATOR_KV_METADATA_KEY}=${AUTH_DELEGATOR_KV_METADATA_VALUE})." >&2
    echo "       Refusing to read or mutate a path this scenario does not own." >&2
    exit 1
  fi
  echo "    kv-v2/${AUTH_DELEGATOR_KV_PATH} already exists and is scenario-owned. Leaving its current value as-is."
else
  echo "==> Seeding kv-v2/${AUTH_DELEGATOR_KV_PATH} (username=${BASELINE_USERNAME}, create-only-if-absent)..."
  jq -n --arg username "$BASELINE_USERNAME" \
    '{data: {username: $username}, options: {cas: 0}}' \
    | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write "${AUTH_DELEGATOR_KV_MOUNT}/data/${AUTH_DELEGATOR_KV_PATH}" -
  echo "==> Marking kv-v2/${AUTH_DELEGATOR_KV_PATH} as scenario-owned (custom metadata)..."
  jq -n --arg k "$AUTH_DELEGATOR_KV_METADATA_KEY" --arg v "$AUTH_DELEGATOR_KV_METADATA_VALUE" \
    '{custom_metadata: {($k): $v}}' \
    | kubectl_vault exec -i "$VAULT_POD" -n "$NAMESPACE" -- vault write "${AUTH_DELEGATOR_KV_MOUNT}/metadata/${AUTH_DELEGATOR_KV_PATH}" -
fi
unset EXISTING_KV_METADATA

# --- Apply Kubernetes resources --------------------------------------------
#
# ensure_owned_namespace already created the namespaces; render again for
# ServiceAccounts/ClusterRoleBinding/VSO CRDs/app pod (idempotent apply of
# the namespaces above is harmless).

echo "==> Checking ClusterRoleBinding '${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}' ownership..."
if kubectl_vso get clusterrolebinding "${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}" >/dev/null 2>&1; then
  CRB_LABEL=$(kubectl_vso get clusterrolebinding "${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}" \
    -o jsonpath="{.metadata.labels.${AUTH_DELEGATOR_OWNER_LABEL_KEY//./\\.}}" 2>/dev/null || true)
  if [ "$CRB_LABEL" != "$AUTH_DELEGATOR_OWNER_LABEL_VALUE" ]; then
    echo "ERROR: ClusterRoleBinding '${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}' already exists but lacks the expected ownership label." >&2
    echo "       Refusing to adopt a foreign ClusterRoleBinding." >&2
    exit 1
  fi
  echo "    ClusterRoleBinding '${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING}' already exists and is scenario-owned; it will be re-applied with exactly one subject."
fi

# --- Grant the VSO operator permission to create TokenRequests ------------
#
# VSO's Kubernetes credential provider mints the short-lived, dual-audience
# self-review JWT by creating a serviceaccounts/token (TokenRequest) for the
# self-review ServiceAccount in the app namespace. Without this RoleBinding,
# VSO cannot mint the token and every VaultAuth sync fails with a 403. The
# VSO operator SA name is detected at runtime (not known at render time),
# so this Role/RoleBinding is applied separately from the static manifest.

VSO_OPERATOR_SA=$(kubectl_vso get deploy -n "$VSO_OPERATOR_NAMESPACE" \
  -l app.kubernetes.io/name=vault-secrets-operator \
  -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}' 2>/dev/null || true)
if [ -z "$VSO_OPERATOR_SA" ]; then
  echo "ERROR: could not resolve the VSO operator ServiceAccount name in '${VSO_OPERATOR_NAMESPACE}'." >&2
  echo "       Is Vault Secrets Operator installed in context '${VSO_CONTEXT}'?" >&2
  exit 1
fi

echo "==> Creating Role/RoleBinding for VSO operator ('${VSO_OPERATOR_SA}') to create tokens for '${AUTH_DELEGATOR_SELF_REVIEW_SA}'..."
kubectl_vso apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${AUTH_DELEGATOR_TOKEN_CREATOR_ROLE}
  namespace: ${AUTH_DELEGATOR_APP_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
  annotations:
    ${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY}: ${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE}
rules:
- apiGroups: [""]
  resources: ["serviceaccounts/token"]
  verbs: ["create"]
  resourceNames: ["${AUTH_DELEGATOR_SELF_REVIEW_SA}"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${AUTH_DELEGATOR_TOKEN_CREATOR_ROLE_BINDING}
  namespace: ${AUTH_DELEGATOR_APP_NAMESPACE}
  labels:
    ${AUTH_DELEGATOR_OWNER_LABEL_KEY}: ${AUTH_DELEGATOR_OWNER_LABEL_VALUE}
  annotations:
    ${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY}: ${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${AUTH_DELEGATOR_TOKEN_CREATOR_ROLE}
subjects:
- kind: ServiceAccount
  name: ${VSO_OPERATOR_SA}
  namespace: ${VSO_OPERATOR_NAMESPACE}
EOF
unset VSO_OPERATOR_SA

echo "==> Applying ServiceAccounts, ClusterRoleBinding, VaultConnection/VaultAuth/VaultStaticSecret, and app pod..."
render_auth_delegator_manifests | kubectl_vso apply -f -

# --- Recreate the plain app pod so its env reflects the current Secret ----

echo "==> Recreating the consuming app pod '${AUTH_DELEGATOR_APP_POD}'..."
kubectl_vso delete pod "${AUTH_DELEGATOR_APP_POD}" -n "$AUTH_DELEGATOR_APP_NAMESPACE" --ignore-not-found=true --wait=true
render_auth_delegator_manifests | kubectl_vso apply -f -

# --- Wait for VaultAuth validation, VaultStaticSecret Ready, Secret --------

echo "==> Waiting for VaultAuth '${AUTH_DELEGATOR_VAULT_AUTH}' to become Valid in '${AUTH_DELEGATOR_AUTH_NAMESPACE}'..."
kubectl_vso wait -n "$AUTH_DELEGATOR_AUTH_NAMESPACE" \
  --for=condition=Valid "vaultauth/${AUTH_DELEGATOR_VAULT_AUTH}" --timeout=60s || true

echo "==> Waiting for VSO to materialize the native Secret '${AUTH_DELEGATOR_SECRET_NAME}' in '${AUTH_DELEGATOR_APP_NAMESPACE}'..."
VSO_SYNCED="false"
for i in $(seq 1 "$SYNC_ATTEMPTS"); do
  VSO_VALUE=$(kubectl_vso get secret "${AUTH_DELEGATOR_SECRET_NAME}" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -n "$VSO_VALUE" ]; then
    echo "    attempt ${i}: secret materialized"
    VSO_SYNCED="true"
    break
  fi
  echo "    attempt ${i}: <not yet synced>"
  sleep 3
done
unset VSO_VALUE

if [ "$VSO_SYNCED" != "true" ]; then
  echo "ERROR: VSO did not materialize secret '${AUTH_DELEGATOR_SECRET_NAME}' in '${AUTH_DELEGATOR_APP_NAMESPACE}'." >&2
  echo "       Inspect with: kubectl --context ${VSO_CONTEXT} describe vaultstaticsecret ${AUTH_DELEGATOR_VSS_NAME} -n ${AUTH_DELEGATOR_APP_NAMESPACE}" >&2
  echo "       and:          kubectl --context ${VSO_CONTEXT} describe vaultauth ${AUTH_DELEGATOR_VAULT_AUTH} -n ${AUTH_DELEGATOR_AUTH_NAMESPACE}" >&2
  echo "       and:          kubectl --context ${VSO_CONTEXT} logs -n ${VSO_OPERATOR_NAMESPACE} -l app.kubernetes.io/name=vault-secrets-operator" >&2
  exit 1
fi

echo "==> Waiting for '${AUTH_DELEGATOR_APP_POD}' to become Ready..."
kubectl_vso wait -n "$AUTH_DELEGATOR_APP_NAMESPACE" --for=condition=Ready "pod/${AUTH_DELEGATOR_APP_POD}" --timeout=180s

echo ""
echo "Client-JWT-self-review VSO scenario applied in context '${VSO_CONTEXT}':"
echo "  - Namespaces:        ${AUTH_DELEGATOR_AUTH_NAMESPACE} (auth), ${AUTH_DELEGATOR_APP_NAMESPACE} (app)"
echo "  - Self-review SA:    ${AUTH_DELEGATOR_SELF_REVIEW_SA} (app ns only, automountServiceAccountToken: false)"
echo "  - ClusterRoleBinding: ${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING} -> system:auth-delegator (sole subject: self-review SA)"
echo "  - App SA:            ${AUTH_DELEGATOR_APP_SA} (unprivileged, no system:auth-delegator)"
echo "  - VaultAuth:          ${AUTH_DELEGATOR_AUTH_NAMESPACE}/${AUTH_DELEGATOR_VAULT_AUTH} (allowedNamespaces: ${AUTH_DELEGATOR_APP_NAMESPACE})"
echo "  - VaultStaticSecret:  ${AUTH_DELEGATOR_APP_NAMESPACE}/${AUTH_DELEGATOR_VSS_NAME} <- kv-v2/${AUTH_DELEGATOR_KV_PATH}"
echo "  - Secret + app pod:   ${AUTH_DELEGATOR_APP_NAMESPACE}/${AUTH_DELEGATOR_SECRET_NAME}, ${AUTH_DELEGATOR_APP_POD} (1/1)"
