#!/usr/bin/env bash
# scripts/lib/two-cluster-env.sh
#
# Shared environment defaults and preflight helpers for the two-cluster
# (Podman-backed kind) Vault + Vault Secrets Operator (VSO) demo.
#
# Every setup, demo, and verification script should `source` this file
# instead of re-declaring context names, namespaces, or addresses. This
# keeps `kind-vault-lab` / `kind-vso-lab` naming, ports, and mount paths
# centralized and overrideable via environment variables.
#
# Usage:
#   #!/usr/bin/env bash
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/two-cluster-env.sh"
#
#   require_commands kubectl kind helm jq
#   require_contexts
#   kubectl_vault get pods -n "$NAMESPACE"
#   kubectl_vso get pods -n "$VSO_NAMESPACE"
#
# This file is meant to be sourced, not executed directly. It intentionally
# avoids `set -euo pipefail` at the top level so sourcing it does not change
# the calling script's shell options; the calling script is expected to set
# its own strict-mode flags (this file's functions are written to behave
# correctly under `set -euo pipefail`).

# --------------------------------------------------------------------------
# Cluster contexts
# --------------------------------------------------------------------------
# These are the two Podman-backed kind clusters used by the demo. Vault runs
# only in VAULT_CONTEXT; VSO, its CRDs, and the demo app run only in
# VSO_CONTEXT. Never rely on `kubectl config current-context` for
# correctness -- always pass one of these explicitly.
VAULT_CONTEXT="${VAULT_CONTEXT:-kind-vault-lab}"
VSO_CONTEXT="${VSO_CONTEXT:-kind-vso-lab}"

# kind cluster names (without the `kind-` context prefix kind adds).
VAULT_KIND_CLUSTER_NAME="${VAULT_KIND_CLUSTER_NAME:-vault-lab}"
VSO_KIND_CLUSTER_NAME="${VSO_KIND_CLUSTER_NAME:-vso-lab}"

# --------------------------------------------------------------------------
# Cross-cluster networking
# --------------------------------------------------------------------------
# Host reachable from both Podman-backed kind clusters via the container
# runtime's host gateway. Vault is exposed on the Vault cluster via a
# NodePort/host port mapping to this host+port; VSO's VaultConnection uses
# this address to reach Vault from the VSO cluster.
TWO_CLUSTER_HOST="${TWO_CLUSTER_HOST:-host.containers.internal}"

VAULT_HOST_PORT="${VAULT_HOST_PORT:-8200}"
VAULT_ADDR="${VAULT_ADDR:-http://${TWO_CLUSTER_HOST}:${VAULT_HOST_PORT}}"

# NodePort Vault's Kubernetes Service listens on inside the Vault cluster.
# The Vault cluster's kind config maps this 1:1 to VAULT_HOST_PORT via
# extraPortMappings (see scripts/kind/vault-lab-config.yaml.tmpl and
# scripts/create-clusters.sh). Task 05 (expose-vault-cross-cluster) creates
# the actual NodePort Service using this port.
VAULT_NODE_PORT="${VAULT_NODE_PORT:-30820}"

# Host port the VSO cluster's API server is mapped to, and the address Vault
# uses to reach it for Kubernetes auth TokenReview requests.
VSO_API_HOST_PORT="${VSO_API_HOST_PORT:-6444}"
VSO_API_ADDR="${VSO_API_ADDR:-https://${TWO_CLUSTER_HOST}:${VSO_API_HOST_PORT}}"

# --------------------------------------------------------------------------
# Namespaces
# --------------------------------------------------------------------------
# Vault cluster namespaces.
NAMESPACE="${NAMESPACE:-default}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"

# VSO cluster namespaces.
VSO_NAMESPACE="${VSO_NAMESPACE:-vso-demo}"
VSO_OPERATOR_NAMESPACE="${VSO_OPERATOR_NAMESPACE:-vault-secrets-operator-system}"

# --------------------------------------------------------------------------
# Chart versions
# --------------------------------------------------------------------------
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-}"
VSO_CHART_VERSION="${VSO_CHART_VERSION:-1.4.0}"

# --------------------------------------------------------------------------
# Resource names
# --------------------------------------------------------------------------
VAULT_POD_LABEL_SELECTOR="${VAULT_POD_LABEL_SELECTOR:-app.kubernetes.io/name=vault}"

# Kubernetes auth mount used by VSO (cross-cluster), distinct from the
# pre-existing same-cluster `auth/kubernetes` mount used by the Agent
# Injector / OTel demo paths, which must not be touched.
#
# DEPRECATION NOTE: these Kubernetes-auth variables are kept temporarily
# for migration compatibility while the demo moves to JWT/OIDC auth (see
# VSO_JWT_* / VSO_OIDC_* below, docs/vso-jwt-oidc-auth-plan.md, and
# tasks/vso-jwt-oidc-auth/*.md). Do not remove until every script/task in
# that plan has migrated off `auth/${VSO_AUTH_MOUNT}`.
VSO_AUTH_MOUNT="${VSO_AUTH_MOUNT:-kubernetes-vso}"
VSO_AUTH_ROLE="${VSO_AUTH_ROLE:-vso-demo}"

# --------------------------------------------------------------------------
# JWT/OIDC auth (VSO -> Vault), replacing the Kubernetes auth mount above
# --------------------------------------------------------------------------
# Vault JWT auth mount dedicated to the VSO cluster's service account JWTs,
# validated through the VSO cluster's OIDC discovery metadata and advertised
# JWKS rather than a TokenReview callback. Named distinctly from
# `${VSO_AUTH_MOUNT}` (`kubernetes-vso`) so both can exist side by side during
# migration; see docs/vso-oidc-discovery-handoff.md.
VSO_JWT_AUTH_MOUNT="${VSO_JWT_AUTH_MOUNT:-jwt-vso}"
VSO_JWT_AUTH_ROLE="${VSO_JWT_AUTH_ROLE:-vso-demo}"

# Audience Vault expects (`bound_audiences`) and VSO's ServiceAccount
# projected token requests (`aud`) must both use `vault` by default so a
# JWT minted for another audience is rejected outright.
VSO_JWT_AUDIENCE="${VSO_JWT_AUDIENCE:-vault}"

# Vault's discovery base, the discovery document's issuer, and the JWT `iss`
# claim must be identical. The VSO kind API server is configured with this
# externally reachable ServiceAccount issuer at cluster creation time.
VSO_OIDC_DISCOVERY_URL="${VSO_OIDC_DISCOVERY_URL:-${VSO_API_ADDR}}"
VSO_OIDC_ISSUER="${VSO_OIDC_ISSUER:-${VSO_OIDC_DISCOVERY_URL}}"

# Expected JWKS URI advertised by discovery. Vault does not configure this
# directly; verification uses it to assert that discovery is self-consistent.
VSO_OIDC_JWKS_URL="${VSO_OIDC_JWKS_URL:-${VSO_OIDC_DISCOVERY_URL}/openid/v1/jwks}"

# validate_vso_oidc_env
#
# Ensures all externally rendered/configured OIDC values derive from the same
# host and port. Override TWO_CLUSTER_HOST and VSO_API_HOST_PORT together;
# overriding only a derived URL would make kubeadm and Vault disagree.
validate_vso_oidc_env() {
  local expected_api_addr="https://${TWO_CLUSTER_HOST}:${VSO_API_HOST_PORT}"
  local expected_jwks_url="${VSO_OIDC_DISCOVERY_URL}/openid/v1/jwks"
  local ok=0

  if [ "$VSO_API_ADDR" != "$expected_api_addr" ]; then
    echo "ERROR: VSO_API_ADDR must derive from TWO_CLUSTER_HOST and VSO_API_HOST_PORT." >&2
    echo "       expected='${expected_api_addr}' actual='${VSO_API_ADDR}'" >&2
    ok=1
  fi
  if [ "$VSO_OIDC_DISCOVERY_URL" != "$VSO_API_ADDR" ]; then
    echo "ERROR: VSO_OIDC_DISCOVERY_URL must equal VSO_API_ADDR." >&2
    ok=1
  fi
  if [ "$VSO_OIDC_ISSUER" != "$VSO_OIDC_DISCOVERY_URL" ]; then
    echo "ERROR: VSO_OIDC_ISSUER must equal VSO_OIDC_DISCOVERY_URL." >&2
    ok=1
  fi
  if [ "$VSO_OIDC_JWKS_URL" != "$expected_jwks_url" ]; then
    echo "ERROR: VSO_OIDC_JWKS_URL must be the discovery URL plus /openid/v1/jwks." >&2
    echo "       expected='${expected_jwks_url}' actual='${VSO_OIDC_JWKS_URL}'" >&2
    ok=1
  fi

  return "$ok"
}

SECRET_NAME="${SECRET_NAME:-vso-demo-mysecret}"
APP_POD="${APP_POD:-vso-demo-app}"
VAULT_TOKEN_REVIEWER_SA="${VAULT_TOKEN_REVIEWER_SA:-vault-token-reviewer}"

# --------------------------------------------------------------------------
# Auth-delegator (client JWT self-review) scenario defaults
# --------------------------------------------------------------------------
# Second, parallel VSO scenario: see docs/vso-kubernetes-auth-delegator-plan.md.
# Vault authenticates the *same* short-lived, dual-audience ServiceAccount JWT
# VSO uses to log in as the HTTP bearer for its own Kubernetes TokenReview
# call (disable_local_ca_jwt=true, no token_reviewer_jwt). Every name below
# is dedicated to this scenario so it can run alongside the default JWT/OIDC
# scenario (auth/${VSO_JWT_AUTH_MOUNT}, namespace ${VSO_NAMESPACE}) without
# sharing any mount, namespace, ServiceAccount, or Secret name.
# validate_auth_delegator_env (below) enforces that these never collide.

# VSO-cluster namespaces. Auth/config resources (VaultConnection/VaultAuth)
# live in the auth namespace; the app/consumer namespace holds the
# self-review ServiceAccount, the app ServiceAccount, the VaultStaticSecret,
# the destination Secret, and the plain app pod -- proving VSO resolves the
# Kubernetes ServiceAccount from the *consuming* resource's namespace even
# though the VaultAuth itself is centrally defined elsewhere.
AUTH_DELEGATOR_AUTH_NAMESPACE="${AUTH_DELEGATOR_AUTH_NAMESPACE:-vso-auth-delegator}"
AUTH_DELEGATOR_APP_NAMESPACE="${AUTH_DELEGATOR_APP_NAMESPACE:-vso-auth-delegator-app}"

# ServiceAccounts, both created only in AUTH_DELEGATOR_APP_NAMESPACE. The
# self-review SA is the ONLY subject ever added to
# AUTH_DELEGATOR_CLUSTER_ROLE_BINDING; the app SA is unprivileged and never
# receives system:auth-delegator or any Vault-facing role.
AUTH_DELEGATOR_SELF_REVIEW_SA="${AUTH_DELEGATOR_SELF_REVIEW_SA:-vso-auth-delegator}"
AUTH_DELEGATOR_APP_SA="${AUTH_DELEGATOR_APP_SA:-vso-auth-delegator-app}"

# The single scenario-owned ClusterRoleBinding. Its only subject must be
# AUTH_DELEGATOR_SELF_REVIEW_SA in AUTH_DELEGATOR_APP_NAMESPACE.
AUTH_DELEGATOR_CLUSTER_ROLE_BINDING="${AUTH_DELEGATOR_CLUSTER_ROLE_BINDING:-vso-auth-delegator-self-review}"

# The VSO operator needs to create serviceaccounts/token (TokenRequest) for
# the self-review SA in the app namespace to mint the short-lived, dual-
# audience JWT. This Role/RoleBinding grants ONLY that permission and is
# scoped to the self-review SA's resource name. The VSO operator SA name is
# detected at runtime; the apply script creates this RoleBinding dynamically.
AUTH_DELEGATOR_TOKEN_CREATOR_ROLE="${AUTH_DELEGATOR_TOKEN_CREATOR_ROLE:-vso-auth-delegator-token-creator}"
AUTH_DELEGATOR_TOKEN_CREATOR_ROLE_BINDING="${AUTH_DELEGATOR_TOKEN_CREATOR_ROLE_BINDING:-vso-auth-delegator-token-creator}"

# Dedicated Vault Kubernetes auth mount for client JWT self-review. Distinct
# from both auth/${VSO_JWT_AUTH_MOUNT} (default JWT/OIDC) and
# auth/${VSO_AUTH_MOUNT} (historical dedicated-reviewer Kubernetes auth) --
# this script family must never write to either of those.
AUTH_DELEGATOR_AUTH_MOUNT="${AUTH_DELEGATOR_AUTH_MOUNT:-kubernetes-vso-self-review}"
AUTH_DELEGATOR_ROLE="${AUTH_DELEGATOR_ROLE:-vso-auth-delegator}"
AUTH_DELEGATOR_POLICY="${AUTH_DELEGATOR_POLICY:-vso-auth-delegator}"

# Dedicated KV v2 fixture, on the same kv-v2 mount already used by the
# other scenarios but at its own path.
AUTH_DELEGATOR_KV_MOUNT="${AUTH_DELEGATOR_KV_MOUNT:-kv-v2}"
AUTH_DELEGATOR_KV_PATH="${AUTH_DELEGATOR_KV_PATH:-vso-auth-delegator/mysecret}"

# VSO custom resource names. VaultConnection/VaultAuth live in the auth
# namespace; VaultStaticSecret/destination Secret/app pod live in the app
# namespace and reference the VaultAuth cross-namespace as
# "${AUTH_DELEGATOR_AUTH_NAMESPACE}/${AUTH_DELEGATOR_VAULT_AUTH}".
AUTH_DELEGATOR_VAULT_CONNECTION="${AUTH_DELEGATOR_VAULT_CONNECTION:-vso-auth-delegator}"
AUTH_DELEGATOR_VAULT_AUTH="${AUTH_DELEGATOR_VAULT_AUTH:-vso-auth-delegator}"
AUTH_DELEGATOR_VSS_NAME="${AUTH_DELEGATOR_VSS_NAME:-vso-auth-delegator-mysecret}"
AUTH_DELEGATOR_SECRET_NAME="${AUTH_DELEGATOR_SECRET_NAME:-vso-auth-delegator-mysecret}"
AUTH_DELEGATOR_APP_POD="${AUTH_DELEGATOR_APP_POD:-vso-auth-delegator-app}"

# Dual audiences. AUTH_DELEGATOR_VAULT_AUDIENCE is the audience the Vault
# role requests (spec.audiences=["vault"] in the client's TokenReview);
# AUTH_DELEGATOR_API_AUDIENCE lets the SAME token authenticate as the outer
# HTTP bearer to the VSO kube-apiserver, which defaults its accepted API
# audience to its --service-account-issuer (VSO_OIDC_ISSUER) since
# --api-audiences is not set. See "Audience decision" in the plan --
# changing this must never require deleting/recreating kind-vso-lab.
AUTH_DELEGATOR_VAULT_AUDIENCE="${AUTH_DELEGATOR_VAULT_AUDIENCE:-vault}"
AUTH_DELEGATOR_API_AUDIENCE="${AUTH_DELEGATOR_API_AUDIENCE:-${VSO_OIDC_ISSUER}}"

# Minimum enforced by validate_auth_delegator_env: VSO's Kubernetes
# credential provider requires tokenExpirationSeconds >= 600.
AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS="${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS:-600}"
AUTH_DELEGATOR_TOKEN_TTL="${AUTH_DELEGATOR_TOKEN_TTL:-1h}"

# Ownership markers stamped on every scenario-owned Kubernetes object
# (namespaces, ServiceAccounts, ClusterRoleBinding). A same-name object
# lacking this exact label must never be adopted/mutated.
AUTH_DELEGATOR_OWNER_LABEL_KEY="${AUTH_DELEGATOR_OWNER_LABEL_KEY:-vault-k8s-demo.hashicorp.com/scenario}"
AUTH_DELEGATOR_OWNER_LABEL_VALUE="${AUTH_DELEGATOR_OWNER_LABEL_VALUE:-auth-delegator}"
AUTH_DELEGATOR_OWNER_ANNOTATION_KEY="${AUTH_DELEGATOR_OWNER_ANNOTATION_KEY:-vault-k8s-demo.hashicorp.com/managed-by}"
AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE="${AUTH_DELEGATOR_OWNER_ANNOTATION_VALUE:-scripts/apply-vso-auth-delegator-demo.sh}"

# Expected description on the dedicated Vault Kubernetes auth mount. A
# same-name mount is only reusable when its type is "kubernetes" AND its
# description exactly equals this string; otherwise setup must refuse to
# overwrite it.
AUTH_DELEGATOR_MOUNT_DESCRIPTION="${AUTH_DELEGATOR_MOUNT_DESCRIPTION:-Kubernetes auth (client JWT self-review) for the vso-auth-delegator scenario, validated against the VSO cluster API server}"

# Custom KV-v2 metadata key/value marking the dedicated KV fixture as
# scenario-owned. An existing path is only reusable/mutable when its
# current custom_metadata carries this exact key/value.
AUTH_DELEGATOR_KV_METADATA_KEY="${AUTH_DELEGATOR_KV_METADATA_KEY:-vault-k8s-demo-scenario}"
AUTH_DELEGATOR_KV_METADATA_VALUE="${AUTH_DELEGATOR_KV_METADATA_VALUE:-auth-delegator}"

# auth_delegator_policy_hcl
#
# Prints the single canonical Vault policy this scenario ever writes: read
# on the dedicated KV v2 data path only.
# scripts/configure-vso-auth-delegator.sh is the sole owner of policy
# creation; it accepts a pre-existing same-name policy only when its rules
# are byte-identical to this canonical content.
auth_delegator_policy_hcl() {
  cat <<EOF
path "${AUTH_DELEGATOR_KV_MOUNT}/data/${AUTH_DELEGATOR_KV_PATH}" {
  capabilities = ["read"]
}
EOF
}

# validate_auth_delegator_env
#
# Fails fast on configuration mistakes that would otherwise surface as
# confusing runtime errors deep inside configure/apply/verify:
#   - the auth and consumer namespaces must differ
#   - the ServiceAccount token expiration must be >= 600s (VSO's minimum)
#   - the Vault and API audiences must both be non-empty and distinct
#   - the API audience must equal the externally configured VSO issuer
#     (VSO_OIDC_ISSUER), since the VSO API server's accepted audience
#     defaults to its --service-account-issuer
#   - none of this scenario's dedicated names collide with the existing
#     JWT/OIDC scenario's namespace/mount/Secret/pod names
#   - the external VSO API address is itself self-consistent
#     (delegates to validate_vso_oidc_env)
validate_auth_delegator_env() {
  local ok=0

  if [ "$AUTH_DELEGATOR_AUTH_NAMESPACE" = "$AUTH_DELEGATOR_APP_NAMESPACE" ]; then
    echo "ERROR: AUTH_DELEGATOR_AUTH_NAMESPACE and AUTH_DELEGATOR_APP_NAMESPACE must differ (both are '${AUTH_DELEGATOR_AUTH_NAMESPACE}')." >&2
    ok=1
  fi

  case "$AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS" in
    ''|*[!0-9]*)
      echo "ERROR: AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS must be a positive integer (got '${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS}')." >&2
      ok=1
      ;;
    *)
      if [ "$AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS" -lt 600 ]; then
        echo "ERROR: AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS must be >= 600 (VSO's Kubernetes credential provider minimum); got '${AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS}'." >&2
        ok=1
      fi
      ;;
  esac

  if [ -z "$AUTH_DELEGATOR_VAULT_AUDIENCE" ] || [ -z "$AUTH_DELEGATOR_API_AUDIENCE" ]; then
    echo "ERROR: AUTH_DELEGATOR_VAULT_AUDIENCE and AUTH_DELEGATOR_API_AUDIENCE must both be non-empty." >&2
    ok=1
  elif [ "$AUTH_DELEGATOR_VAULT_AUDIENCE" = "$AUTH_DELEGATOR_API_AUDIENCE" ]; then
    echo "ERROR: AUTH_DELEGATOR_VAULT_AUDIENCE and AUTH_DELEGATOR_API_AUDIENCE must be distinct (both are '${AUTH_DELEGATOR_VAULT_AUDIENCE}')." >&2
    ok=1
  fi

  if [ "$AUTH_DELEGATOR_API_AUDIENCE" != "$VSO_OIDC_ISSUER" ]; then
    echo "ERROR: AUTH_DELEGATOR_API_AUDIENCE must equal VSO_OIDC_ISSUER so the dual-audience token can authenticate as the outer HTTP bearer to the VSO API server." >&2
    echo "       expected='${VSO_OIDC_ISSUER}' actual='${AUTH_DELEGATOR_API_AUDIENCE}'" >&2
    ok=1
  fi

  local collisions=()
  [ "$AUTH_DELEGATOR_AUTH_NAMESPACE" = "$VSO_NAMESPACE" ] && collisions+=("AUTH_DELEGATOR_AUTH_NAMESPACE must not equal VSO_NAMESPACE ('${VSO_NAMESPACE}')")
  [ "$AUTH_DELEGATOR_APP_NAMESPACE" = "$VSO_NAMESPACE" ] && collisions+=("AUTH_DELEGATOR_APP_NAMESPACE must not equal VSO_NAMESPACE ('${VSO_NAMESPACE}')")
  [ "$AUTH_DELEGATOR_APP_NAMESPACE" = "$VSO_OPERATOR_NAMESPACE" ] && collisions+=("AUTH_DELEGATOR_APP_NAMESPACE must not equal VSO_OPERATOR_NAMESPACE ('${VSO_OPERATOR_NAMESPACE}')")
  [ "$AUTH_DELEGATOR_AUTH_NAMESPACE" = "$VSO_OPERATOR_NAMESPACE" ] && collisions+=("AUTH_DELEGATOR_AUTH_NAMESPACE must not equal VSO_OPERATOR_NAMESPACE ('${VSO_OPERATOR_NAMESPACE}')")
  [ "$AUTH_DELEGATOR_AUTH_MOUNT" = "$VSO_JWT_AUTH_MOUNT" ] && collisions+=("AUTH_DELEGATOR_AUTH_MOUNT must not equal VSO_JWT_AUTH_MOUNT ('${VSO_JWT_AUTH_MOUNT}')")
  [ "$AUTH_DELEGATOR_AUTH_MOUNT" = "$VSO_AUTH_MOUNT" ] && collisions+=("AUTH_DELEGATOR_AUTH_MOUNT must not equal VSO_AUTH_MOUNT ('${VSO_AUTH_MOUNT}')")
  [ "$AUTH_DELEGATOR_SECRET_NAME" = "$SECRET_NAME" ] && collisions+=("AUTH_DELEGATOR_SECRET_NAME must not equal SECRET_NAME ('${SECRET_NAME}')")
  [ "$AUTH_DELEGATOR_APP_POD" = "$APP_POD" ] && collisions+=("AUTH_DELEGATOR_APP_POD must not equal APP_POD ('${APP_POD}')")
  [ "$AUTH_DELEGATOR_POLICY" = "mysecret" ] && collisions+=("AUTH_DELEGATOR_POLICY must not reuse the shared 'mysecret' policy name")
  [ "$AUTH_DELEGATOR_KV_PATH" = "vault-demo/mysecret" ] && collisions+=("AUTH_DELEGATOR_KV_PATH must not reuse the shared 'vault-demo/mysecret' path")

  if [ "${#collisions[@]}" -gt 0 ]; then
    echo "ERROR: auth-delegator names collide with the existing JWT/OIDC scenario:" >&2
    local c
    for c in "${collisions[@]}"; do
      echo "       - ${c}" >&2
    done
    ok=1
  fi

  validate_vso_oidc_env || ok=1

  return "$ok"
}

# preflight_auth_delegator_runtime
#
# Feature-detects (rather than assumes) the runtime capabilities this
# scenario depends on, printing actionable diagnostics for each gate. Safe
# to call before any cluster exists (each check degrades to a clear
# NOTE/ERROR rather than crashing). Returns non-zero only when a gate this
# function can verify with confidence has actually failed. Never creates,
# deletes, or recreates a cluster or container.
#
#   - both kind control-plane containers already exist
#   - the deployed VSO version/image (informational; VSO_CHART_VERSION
#     defaults to 1.4.0, the first release with cross-namespace
#     vaultAuthRef + Kubernetes audiences/tokenExpirationSeconds support)
#   - the VaultAuth CRD schema actually exposes allowedNamespaces and the
#     Kubernetes audiences/tokenExpirationSeconds fields
#   - the VSO operator's ServiceAccount can create serviceaccounts/token in
#     the consumer namespace (TokenRequest RBAC)
preflight_auth_delegator_runtime() {
  local ok=0

  if command -v podman >/dev/null 2>&1; then
    local c
    for c in "${VAULT_KIND_CLUSTER_NAME}-control-plane" "${VSO_KIND_CLUSTER_NAME}-control-plane"; do
      if ! podman container exists "$c" 2>/dev/null; then
        echo "ERROR: kind control-plane container '${c}' does not exist." >&2
        echo "       This scenario never creates clusters; create it out-of-band first." >&2
        ok=1
      fi
    done
  else
    echo "WARNING: podman not found on PATH; cannot confirm both kind control-plane containers already exist." >&2
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found on PATH; cannot feature-detect VSO version/CRD/RBAC support." >&2
    return 1
  fi

  if ! context_exists "$VSO_CONTEXT"; then
    echo "NOTE: context '${VSO_CONTEXT}' does not exist yet; skipping live VSO version/CRD/RBAC feature detection." >&2
    return "$ok"
  fi

  local vso_image
  vso_image=$(kubectl_vso get deploy -n "$VSO_OPERATOR_NAMESPACE" \
    -l app.kubernetes.io/name=vault-secrets-operator \
    -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
  if [ -z "$vso_image" ]; then
    echo "NOTE: no Vault Secrets Operator deployment found in context '${VSO_CONTEXT}' namespace '${VSO_OPERATOR_NAMESPACE}' yet." >&2
  else
    echo "NOTE: deployed Vault Secrets Operator image: ${vso_image}" >&2
  fi

  if command -v jq >/dev/null 2>&1 && kubectl_vso get crd vaultauths.secrets.hashicorp.com >/dev/null 2>&1; then
    local crd_schema has_allowed_ns has_audiences has_token_exp
    crd_schema=$(kubectl_vso get crd vaultauths.secrets.hashicorp.com -o json 2>/dev/null || true)
    has_allowed_ns=$(printf '%s' "$crd_schema" | jq -e '
      [.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.allowedNamespaces]
      | any(. != null)' >/dev/null 2>&1 && echo true || echo false)
    has_audiences=$(printf '%s' "$crd_schema" | jq -e '
      [.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.kubernetes.properties.audiences]
      | any(. != null)' >/dev/null 2>&1 && echo true || echo false)
    has_token_exp=$(printf '%s' "$crd_schema" | jq -e '
      [.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.kubernetes.properties.tokenExpirationSeconds]
      | any(. != null)' >/dev/null 2>&1 && echo true || echo false)
    if [ "$has_allowed_ns" != "true" ] || [ "$has_audiences" != "true" ] || [ "$has_token_exp" != "true" ]; then
      echo "ERROR: the installed VaultAuth CRD does not expose allowedNamespaces/kubernetes.audiences/kubernetes.tokenExpirationSeconds." >&2
      echo "       Upgrade the vault-secrets-operator Helm release to >= 1.4.0 (see VSO_CHART_VERSION)." >&2
      ok=1
    else
      echo "OK: VaultAuth CRD exposes allowedNamespaces, kubernetes.audiences, and kubernetes.tokenExpirationSeconds." >&2
    fi
  else
    echo "NOTE: VaultAuth CRD not found (or jq unavailable) in context '${VSO_CONTEXT}'; skipping CRD schema feature detection." >&2
  fi

  local operator_sa
  operator_sa=$(kubectl_vso get deploy -n "$VSO_OPERATOR_NAMESPACE" \
    -l app.kubernetes.io/name=vault-secrets-operator \
    -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}' 2>/dev/null || true)
  if [ -n "$operator_sa" ]; then
    # 'kubectl auth can-i create serviceaccounts/token' with --as is
    # unreliable for the TokenRequest subresource (known Kubernetes RBAC
    # quirk: the authorization check for serviceaccounts/token is handled
    # by the TokenRequest API itself, not the normal SAR path). Instead,
    # verify the Role/RoleBinding exists with the VSO operator SA as its
    # subject. If the namespace doesn't exist yet (first apply hasn't
    # run), skip with a NOTE.
    if ! kubectl_vso get namespace "$AUTH_DELEGATOR_APP_NAMESPACE" >/dev/null 2>&1; then
      echo "NOTE: namespace '${AUTH_DELEGATOR_APP_NAMESPACE}' does not exist yet; skipping TokenRequest RBAC check (apply will create the Role/RoleBinding)." >&2
    elif kubectl_vso get rolebinding "$AUTH_DELEGATOR_TOKEN_CREATOR_ROLE_BINDING" -n "$AUTH_DELEGATOR_APP_NAMESPACE" >/dev/null 2>&1 \
        && [ "$(kubectl_vso get rolebinding "$AUTH_DELEGATOR_TOKEN_CREATOR_ROLE_BINDING" -n "$AUTH_DELEGATOR_APP_NAMESPACE" \
          -o jsonpath='{.subjects[?(@.kind=="ServiceAccount")].name}' 2>/dev/null)" = "$operator_sa" ]; then
      echo "OK: RoleBinding '${AUTH_DELEGATOR_TOKEN_CREATOR_ROLE_BINDING}' grants VSO operator SA '${operator_sa}' permission to create tokens for '${AUTH_DELEGATOR_SELF_REVIEW_SA}' in '${AUTH_DELEGATOR_APP_NAMESPACE}'." >&2
    else
      echo "ERROR: RoleBinding '${AUTH_DELEGATOR_TOKEN_CREATOR_ROLE_BINDING}' not found (or does not reference VSO operator SA '${operator_sa}') in '${AUTH_DELEGATOR_APP_NAMESPACE}'." >&2
      echo "       VSO cannot mint the short-lived self-review JWT without this RBAC." >&2
      echo "       Run scripts/apply-vso-auth-delegator-demo.sh first (it creates the Role/RoleBinding)." >&2
      ok=1
    fi
  else
    echo "NOTE: could not resolve the VSO operator ServiceAccount name; skipping TokenRequest RBAC feature detection." >&2
  fi

  return "$ok"
}

# capture_jwt_oidc_baseline_snapshot <vault_pod>
#
# Prints a normalized (sorted-key, secret-stripped) JSON snapshot of the
# EXISTING default JWT/OIDC scenario's auth/${VSO_JWT_AUTH_MOUNT} mount
# config + role, so configure/apply/verify scripts for the new
# client-JWT-self-review scenario can prove they never disturbed it.
# Requires kubectl_vault, NAMESPACE, VSO_JWT_AUTH_MOUNT, and
# VSO_JWT_AUTH_ROLE to already be set (i.e. this file already sourced).
capture_jwt_oidc_baseline_snapshot() {
  local vault_pod="$1"
  local mount_cfg role_cfg
  mount_cfg=$(kubectl_vault exec "$vault_pod" -n "$NAMESPACE" -- vault read -format=json \
    "auth/${VSO_JWT_AUTH_MOUNT}/config" 2>/dev/null || echo '{}')
  role_cfg=$(kubectl_vault exec "$vault_pod" -n "$NAMESPACE" -- vault read -format=json \
    "auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE}" 2>/dev/null || echo '{}')
  jq -n --argjson mount "$mount_cfg" --argjson role "$role_cfg" '
    {
      mount: (($mount.data // {}) | del(.oidc_discovery_ca_pem, .jwks_ca_pem, .jwt_validation_pubkeys)),
      role: ($role.data // {})
    }' | jq -S .
}

# capture_vso_demo_cr_snapshot
#
# Prints a normalized JSON snapshot of the EXISTING default scenario's
# VaultConnection/VaultAuth/VaultStaticSecret specs in $VSO_NAMESPACE, so
# the new scenario's verifier can prove it never disturbed them. Requires
# kubectl_vso, VSO_NAMESPACE, and SECRET_NAME to already be set.
capture_vso_demo_cr_snapshot() {
  local conn auth vss
  conn=$(kubectl_vso get vaultconnection vso-demo-connection -n "$VSO_NAMESPACE" -o json 2>/dev/null | jq -c '.spec // {}' 2>/dev/null || echo '{}')
  auth=$(kubectl_vso get vaultauth vso-demo-auth -n "$VSO_NAMESPACE" -o json 2>/dev/null | jq -c '.spec // {}' 2>/dev/null || echo '{}')
  vss=$(kubectl_vso get vaultstaticsecret "$SECRET_NAME" -n "$VSO_NAMESPACE" -o json 2>/dev/null | jq -c '.spec // {}' 2>/dev/null || echo '{}')
  jq -n --argjson conn "$conn" --argjson auth "$auth" --argjson vss "$vss" \
    '{vaultConnection: $conn, vaultAuth: $auth, vaultStaticSecret: $vss}' | jq -S .
}

# --------------------------------------------------------------------------
# Command preflight
# --------------------------------------------------------------------------

# require_commands <cmd> [<cmd> ...]
#
# Verifies each given command is available on PATH. Prints an actionable
# error naming the missing command(s) and returns non-zero if any are
# missing (does not exit the shell, so callers under `set -e` will stop, and
# callers that want to handle the failure themselves still can by capturing
# the return code).
require_commands() {
  local missing=()
  local cmd

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: required command(s) not found on PATH: ${missing[*]}" >&2
    echo "       install the missing command(s) and re-run." >&2
    return 1
  fi

  return 0
}

# --------------------------------------------------------------------------
# Context preflight
# --------------------------------------------------------------------------

# context_exists <context-name>
#
# Returns 0 if the given kubectl context exists in the current kubeconfig,
# non-zero otherwise. Does not depend on which context is "current".
context_exists() {
  local ctx="$1"
  kubectl config get-contexts -o name 2>/dev/null | grep -Fxq "$ctx"
}

# require_context <context-name>
#
# Asserts a single named context exists, printing an actionable error that
# names the missing context and the command that would create it.
require_context() {
  local ctx="$1"

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found on PATH; cannot check context '$ctx'." >&2
    return 1
  fi

  if ! context_exists "$ctx"; then
    echo "ERROR: kubectl context '$ctx' not found." >&2
    echo "       Expected clusters: VAULT_CONTEXT=$VAULT_CONTEXT, VSO_CONTEXT=$VSO_CONTEXT" >&2
    echo "       Run 'make clusters' (or the two-cluster bootstrap script) to create it," >&2
    echo "       or check 'kubectl config get-contexts' for the correct name." >&2
    return 1
  fi

  return 0
}

# require_contexts
#
# Asserts both VAULT_CONTEXT and VSO_CONTEXT exist and are different from
# each other. This is the primary preflight gate every setup/demo/verify
# script should call before doing any real work.
require_contexts() {
  local ok=0

  require_context "$VAULT_CONTEXT" || ok=1
  require_context "$VSO_CONTEXT" || ok=1

  if [ "$VAULT_CONTEXT" = "$VSO_CONTEXT" ]; then
    echo "ERROR: VAULT_CONTEXT and VSO_CONTEXT must not be the same context (both are '$VAULT_CONTEXT')." >&2
    echo "       Vault must run in a different cluster from VSO/VSO CRDs/the demo app." >&2
    ok=1
  fi

  return "$ok"
}

# --------------------------------------------------------------------------
# Context-specific kubectl/helm wrappers
# --------------------------------------------------------------------------

# kubectl_vault <args...>
#
# Runs kubectl against VAULT_CONTEXT explicitly. Never relies on the
# ambient current-context.
kubectl_vault() {
  kubectl --context "$VAULT_CONTEXT" "$@"
}

# kubectl_vso <args...>
#
# Runs kubectl against VSO_CONTEXT explicitly.
kubectl_vso() {
  kubectl --context "$VSO_CONTEXT" "$@"
}

# helm_vault <args...>
#
# Runs helm against VAULT_CONTEXT explicitly (via --kube-context).
helm_vault() {
  helm --kube-context "$VAULT_CONTEXT" "$@"
}

# helm_vso <args...>
#
# Runs helm against VSO_CONTEXT explicitly (via --kube-context).
helm_vso() {
  helm --kube-context "$VSO_CONTEXT" "$@"
}

# --------------------------------------------------------------------------
# Podman / kind network preflight
# --------------------------------------------------------------------------

# preflight_two_cluster_network
#
# Best-effort checks for the assumptions later setup/demo scripts rely on:
#   - kind is configured to use the Podman provider.
#   - both expected kind clusters exist.
#   - TWO_CLUSTER_HOST resolves/is reachable, where checkable from this host.
#
# This function prints actionable diagnostics but is deliberately
# non-fatal for checks it cannot fully verify from outside the cluster
# (e.g. reachability from *inside* a kind pod requires a running pod and is
# left to the dedicated `make verify-two-cluster` target). It returns
# non-zero only for checks it can verify with confidence.
preflight_two_cluster_network() {
  local ok=0

  if [ "${KIND_EXPERIMENTAL_PROVIDER:-}" != "podman" ]; then
    echo "WARNING: KIND_EXPERIMENTAL_PROVIDER is not set to 'podman' (current: '${KIND_EXPERIMENTAL_PROVIDER:-<unset>}')." >&2
    echo "         Podman-backed kind clusters require: export KIND_EXPERIMENTAL_PROVIDER=podman" >&2
  fi

  if command -v kind >/dev/null 2>&1; then
    local existing_clusters
    existing_clusters="$(kind get clusters 2>/dev/null || true)"

    if ! printf '%s\n' "$existing_clusters" | grep -Fxq "$VAULT_KIND_CLUSTER_NAME"; then
      echo "NOTE: kind cluster '$VAULT_KIND_CLUSTER_NAME' (context '$VAULT_CONTEXT') not found yet." >&2
      ok=1
    fi

    if ! printf '%s\n' "$existing_clusters" | grep -Fxq "$VSO_KIND_CLUSTER_NAME"; then
      echo "NOTE: kind cluster '$VSO_KIND_CLUSTER_NAME' (context '$VSO_CONTEXT') not found yet." >&2
      ok=1
    fi
  else
    echo "WARNING: kind not found on PATH; cannot check for existing clusters." >&2
  fi

  if command -v getent >/dev/null 2>&1; then
    if ! getent hosts "$TWO_CLUSTER_HOST" >/dev/null 2>&1; then
      echo "NOTE: '$TWO_CLUSTER_HOST' does not resolve from this host. This is often fine" >&2
      echo "      (it only needs to resolve from inside the kind/Podman network namespaces)," >&2
      echo "      but if VSO cannot reach Vault, verify Podman's host gateway is enabled." >&2
    fi
  fi

  return "$ok"
}

# print_two_cluster_env
#
# Prints the core shared variables. Useful for smoke-testing that this file
# was sourced correctly (see validation steps in the task spec).
print_two_cluster_env() {
  cat <<EOF
VAULT_CONTEXT=$VAULT_CONTEXT
VSO_CONTEXT=$VSO_CONTEXT
VAULT_KIND_CLUSTER_NAME=$VAULT_KIND_CLUSTER_NAME
VSO_KIND_CLUSTER_NAME=$VSO_KIND_CLUSTER_NAME
VAULT_ADDR=$VAULT_ADDR
VAULT_NODE_PORT=$VAULT_NODE_PORT
VSO_API_ADDR=$VSO_API_ADDR
NAMESPACE=$NAMESPACE
OBSERVABILITY_NAMESPACE=$OBSERVABILITY_NAMESPACE
VSO_NAMESPACE=$VSO_NAMESPACE
VSO_OPERATOR_NAMESPACE=$VSO_OPERATOR_NAMESPACE
VSO_CHART_VERSION=$VSO_CHART_VERSION
VSO_AUTH_MOUNT=$VSO_AUTH_MOUNT
VSO_AUTH_ROLE=$VSO_AUTH_ROLE
VSO_JWT_AUTH_MOUNT=$VSO_JWT_AUTH_MOUNT
VSO_JWT_AUTH_ROLE=$VSO_JWT_AUTH_ROLE
VSO_JWT_AUDIENCE=$VSO_JWT_AUDIENCE
VSO_OIDC_DISCOVERY_URL=$VSO_OIDC_DISCOVERY_URL
VSO_OIDC_ISSUER=$VSO_OIDC_ISSUER
VSO_OIDC_JWKS_URL=$VSO_OIDC_JWKS_URL
SECRET_NAME=$SECRET_NAME
APP_POD=$APP_POD
AUTH_DELEGATOR_AUTH_NAMESPACE=$AUTH_DELEGATOR_AUTH_NAMESPACE
AUTH_DELEGATOR_APP_NAMESPACE=$AUTH_DELEGATOR_APP_NAMESPACE
AUTH_DELEGATOR_SELF_REVIEW_SA=$AUTH_DELEGATOR_SELF_REVIEW_SA
AUTH_DELEGATOR_APP_SA=$AUTH_DELEGATOR_APP_SA
AUTH_DELEGATOR_CLUSTER_ROLE_BINDING=$AUTH_DELEGATOR_CLUSTER_ROLE_BINDING
AUTH_DELEGATOR_TOKEN_CREATOR_ROLE=$AUTH_DELEGATOR_TOKEN_CREATOR_ROLE
AUTH_DELEGATOR_TOKEN_CREATOR_ROLE_BINDING=$AUTH_DELEGATOR_TOKEN_CREATOR_ROLE_BINDING
AUTH_DELEGATOR_AUTH_MOUNT=$AUTH_DELEGATOR_AUTH_MOUNT
AUTH_DELEGATOR_ROLE=$AUTH_DELEGATOR_ROLE
AUTH_DELEGATOR_POLICY=$AUTH_DELEGATOR_POLICY
AUTH_DELEGATOR_KV_MOUNT=$AUTH_DELEGATOR_KV_MOUNT
AUTH_DELEGATOR_KV_PATH=$AUTH_DELEGATOR_KV_PATH
AUTH_DELEGATOR_VAULT_CONNECTION=$AUTH_DELEGATOR_VAULT_CONNECTION
AUTH_DELEGATOR_VAULT_AUTH=$AUTH_DELEGATOR_VAULT_AUTH
AUTH_DELEGATOR_VSS_NAME=$AUTH_DELEGATOR_VSS_NAME
AUTH_DELEGATOR_SECRET_NAME=$AUTH_DELEGATOR_SECRET_NAME
AUTH_DELEGATOR_APP_POD=$AUTH_DELEGATOR_APP_POD
AUTH_DELEGATOR_VAULT_AUDIENCE=$AUTH_DELEGATOR_VAULT_AUDIENCE
AUTH_DELEGATOR_API_AUDIENCE=$AUTH_DELEGATOR_API_AUDIENCE
AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS=$AUTH_DELEGATOR_TOKEN_EXPIRATION_SECONDS
AUTH_DELEGATOR_TOKEN_TTL=$AUTH_DELEGATOR_TOKEN_TTL
EOF
}
