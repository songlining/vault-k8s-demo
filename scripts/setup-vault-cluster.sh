#!/usr/bin/env bash
# scripts/setup-vault-cluster.sh
#
# Installs and configures Vault in the Vault cluster only (VAULT_CONTEXT,
# default: kind-vault-lab). This is the Vault-specific half of the former
# create_vault.sh, extracted so it can run independently of any VSO/VSO
# cluster setup (see scripts/setup-vso-cluster.sh, a later task).
#
# This script:
#   - installs Vault via Helm into VAULT_CONTEXT
#   - waits for the vault-0 pod, initializes/unseals it (idempotent, with
#     recovery from a saved local unseal-key file)
#   - enables the file audit device
#   - enables the (same-cluster) `kubernetes` auth method and kv-v2 secrets
#     engine
#   - seeds kv-v2/vault-demo/mysecret and baseline policies
#     (mysecret, vault-metrics-read)
#   - configures the `vault-demo` and `otel-vault-metrics` roles against the
#     same-cluster `auth/kubernetes` mount
#   - (re)deploys the Agent Injector demo pod (vault-demo) and the OTel
#     collector + metrics-check demo resources in the observability
#     namespace, all in the Vault cluster
#
# It deliberately does NOT install the Vault Secrets Operator, VSO CRDs, or
# the vso-demo-app pod, and does NOT touch the dedicated cross-cluster
# `auth/kubernetes-vso` mount -- those belong to the VSO cluster and later
# tasks (06, 07, 08).
#
# Usage:
#   VAULT_CONTEXT=kind-vault-lab scripts/setup-vault-cluster.sh
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VAULT_CONTEXT,
# NAMESPACE, OBSERVABILITY_NAMESPACE, KEYS_FILE, etc).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/two-cluster-env.sh
source "${SCRIPT_DIR}/lib/two-cluster-env.sh"

require_commands kubectl helm jq
require_context "$VAULT_CONTEXT"

echo "==> Installing/upgrading Vault in context '${VAULT_CONTEXT}'..."

helm_vault upgrade --install vault hashicorp/vault \
  --create-namespace \
  -f - <<'EOF'
injector:
  enabled: true
server:
  auditStorage:
    enabled: true
    size: 1Gi
    type: file
  standalone:
    config: |
      ui = true

      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
      }

      storage "file" {
        path = "/vault/data"
      }

      telemetry {
        prometheus_retention_time = "24h"
        disable_hostname = true
      }
EOF

VAULT_SERVICE_ACCOUNT="${VAULT_SERVICE_ACCOUNT:-vault}"

# --- Cross-cluster exposure ------------------------------------------------
#
# Pods in the VSO cluster cannot resolve `vault.default.svc.cluster.local`
# (that DNS name only exists inside the Vault cluster's own cluster
# network). Instead, expose Vault's existing ClusterIP-backed pod selector
# via a NodePort Service. The Vault cluster's kind config
# (scripts/kind/vault-lab-config.yaml.tmpl) maps that NodePort 1:1 to a host
# port via extraPortMappings, so consumers outside this cluster (including
# pods in kind-vso-lab, via Podman's host gateway) can reach Vault at
# VAULT_ADDR (http://${TWO_CLUSTER_HOST}:${VAULT_HOST_PORT} by default -- see
# scripts/lib/two-cluster-env.sh). This Service is additive: it does not
# replace or modify the Helm chart's own `vault`/`vault-internal` Services,
# so `vault.default.svc.cluster.local` continues to work unchanged for
# same-cluster consumers (Agent Injector, OTel collector).
echo "==> Exposing Vault via NodePort '${VAULT_NODE_PORT}' (host port ${VAULT_HOST_PORT}) for cross-cluster access..."
kubectl_vault apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: vault-external
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/instance: vault
    app.kubernetes.io/name: vault
    app.kubernetes.io/component: cross-cluster-access
spec:
  type: NodePort
  selector:
    app.kubernetes.io/instance: vault
    app.kubernetes.io/name: vault
    component: server
  ports:
    - name: http
      port: 8200
      targetPort: 8200
      nodePort: ${VAULT_NODE_PORT}
      protocol: TCP
EOF

echo "Waiting for Vault pod to be ready in ${VAULT_CONTEXT}..."
while : ; do
  POD=$(kubectl_vault get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$POD" ]; then
    READY_STATUS=$(kubectl_vault get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Initialized")].status}')
    if [ "$READY_STATUS" = "True" ]; then
      break
    fi
  fi
  sleep 5
  echo "Still waiting for Vault pod to be ready..."
done
echo "Vault pod $POD is Initialized."

POD=$(kubectl_vault get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" \
      -o jsonpath='{.items[0].metadata.name}')

echo "Wait for another 20 secs for things to be settled ..."
sleep 20

# Skip init/unseal if Vault is already initialized and unsealed
KEYS_FILE="${KEYS_FILE:-vault-init-keys.json}"

unseal_from_file() {
  # Unseal the Vault pod using keys saved in $KEYS_FILE on the host.
  if [ ! -f "$KEYS_FILE" ]; then
    return 1
  fi
  local i
  for i in 0 1 2; do
    key=$(jq -r ".unseal_keys_b64[$i]" "$KEYS_FILE")
    if [ -z "$key" ] || [ "$key" = "null" ]; then
      return 1
    fi
    kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault operator unseal "$key" >/dev/null
  done
  return 0
}

if kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Initialized.*true' \
    && kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Sealed.*false'; then
  echo "Vault is already initialized and unsealed. Skipping init/unseal."
elif kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Initialized.*true'; then
  # Initialized but sealed (e.g. the pod restarted). Recover from saved keys.
  echo "Vault is initialized but sealed. Attempting to unseal from ${KEYS_FILE}..."
  if unseal_from_file; then
    echo "Vault unsealed from saved keys in ${KEYS_FILE}."
  else
    echo "ERROR: Vault is sealed and no usable unseal keys were found in ${KEYS_FILE}." >&2
    echo "Cannot recover this Vault. Recreate the cluster for a clean demo:" >&2
    echo "  kind delete cluster --name ${VAULT_KIND_CLUSTER_NAME} && scripts/create-clusters.sh" >&2
    echo "  helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update" >&2
    echo "  make setup" >&2
    echo "" >&2
    echo "Note: Ensure KIND_EXPERIMENTAL_PROVIDER=podman is set when using Podman Desktop." >&2
    exit 1
  fi
else
  # Fresh Vault: initialize, persist keys to a gitignored host file, then unseal.
  echo "Initializing Vault and saving unseal keys to ${KEYS_FILE}..."
  kubectl_vault exec "$POD" -n "$NAMESPACE" -- \
    vault operator init -key-shares=5 -key-threshold=3 -format=json > "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"

  if ! unseal_from_file; then
    echo "ERROR: failed to unseal Vault from freshly written ${KEYS_FILE}." >&2
    exit 1
  fi

  # Login with the root token without printing it to the terminal.
  ROOT_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")
  kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault login -no-print "$ROOT_TOKEN"

  echo "Vault initialized, unsealed, logged in and ready for use."
  echo "Unseal keys and root token saved to ${KEYS_FILE} (gitignored). Keep this file safe; it is demo-only."
fi

# Enable audit device only if not already enabled
if kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault audit list 2>/dev/null | grep -q '^file/'; then
  echo "Audit device 'file' already enabled. Skipping."
else
  kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault audit enable file file_path=stdout
fi

kubectl_vault apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: my-auth-delegator-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: ${VAULT_SERVICE_ACCOUNT}
  namespace: ${NAMESPACE}
EOF

sleep 5

# Enable kubernetes auth (same-cluster, Agent Injector/OTel demo path) only
# if not already enabled. This mount is distinct from the cross-cluster
# auth/kubernetes-vso mount configured by a later task for VSO.
if kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault auth list 2>/dev/null | grep -q '^kubernetes/'; then
  echo "Kubernetes auth method already enabled. Skipping."
else
  kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault auth enable kubernetes
fi

# Enable kv-v2 secrets engine only if not already enabled
if kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault secrets list 2>/dev/null | grep -q '^kv-v2/'; then
  echo "Secrets engine kv-v2 already enabled. Skipping."
else
  kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault secrets enable -path=kv-v2 kv-v2
fi

kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault kv put kv-v2/vault-demo/mysecret username=larry
kubectl_vault exec -i "$POD" -n "$NAMESPACE" -- vault policy write mysecret - <<EOF
path "kv-v2/data/vault-demo/mysecret" {
  capabilities = ["read"]
}
EOF

kubectl_vault exec -i "$POD" -n "$NAMESPACE" -- vault policy write vault-metrics-read - <<EOF
path "sys/metrics" {
  capabilities = ["read"]
}
EOF

# 1. Authentication Request
#    ↓
# 2. JWT Validation (K8s TokenReview API)
#    ↓
# 3. Role Matching (vault-demo)
#    ↓
# 4. Entity/EntityAlias Management:
#    • Check if EntityAlias exists for "default/default"
#    • If not: Create Entity + EntityAlias
#    • If yes: Use existing Entity
#    ↓
# 5. Token Creation:
#    • Apply policies from role (default,mysecret)
#    • Link token to Entity
#    • Set TTL (1h)
#    ↓
# 6. Return token + entity info
kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault write auth/kubernetes/role/vault-demo \
    alias_name_source=serviceaccount_name \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default,mysecret \
    ttl=1h

kubectl_vault exec "$POD" -n "$NAMESPACE" -- sh -c "vault write auth/kubernetes/config \
  kubernetes_host=https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT"

kubectl_vault apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${OBSERVABILITY_NAMESPACE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: ${OBSERVABILITY_NAMESPACE}
EOF

kubectl_vault exec "$POD" -n "$NAMESPACE" -- vault write auth/kubernetes/role/otel-vault-metrics \
    alias_name_source=serviceaccount_name \
    bound_service_account_names=otel-collector \
    bound_service_account_namespaces="$OBSERVABILITY_NAMESPACE" \
    policies=vault-metrics-read \
    ttl=1h

# Recreate vault-demo pod so the Vault Agent sidecar is freshly injected
# (the agent-injector mutating webhook only runs on pod CREATE, not UPDATE)
kubectl_vault delete pod vault-demo -n "$NAMESPACE" --ignore-not-found=true --wait=true

kubectl_vault apply -f - <<'EOF'
# vault-demo.yaml

apiVersion: v1
kind: Pod
metadata:
  name: vault-demo
  namespace: default
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "vault-demo"
    vault.hashicorp.com/agent-inject-secret-mysecret: "kv-v2/data/vault-demo/mysecret"
    vault.hashicorp.com/agent-inject-template-mysecret: |
      {{- with secret "kv-v2/data/vault-demo/mysecret" -}}
      {{- range $k, $v := .Data.data }}
      {{ $k }}: {{ $v }}
      {{- end }}
      {{ end }}
spec:
  restartPolicy: "OnFailure"
  containers:
    - name: vault-demo
      image: badouralix/curl-jq
      command: ["sh", "-c"]
      resources: {}
      args:
      - |
        VAULT_ADDR="http://vault-internal:8200"
        SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
        VAULT_RESPONSE=$(curl -X POST -H "X-Vault-Request: true" -d '{"jwt": "'"$SA_TOKEN"'", "role": "vault-demo"}' \
          $VAULT_ADDR/v1/auth/kubernetes/login | jq .)

        echo $VAULT_RESPONSE
        echo ""

        VAULT_TOKEN=$(echo $VAULT_RESPONSE | jq -r '.auth.client_token')
        echo $VAULT_TOKEN

        echo "Fetching vault-demo/mysecret from vault...."
        VAULT_SECRET=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" $VAULT_ADDR/v1/kv-v2/data/vault-demo/mysecret)
        echo $VAULT_SECRET

        sleep infinity
EOF

kubectl_vault apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: ${OBSERVABILITY_NAMESPACE}
data:
  config.yaml: |
    receivers:
      prometheus:
        config:
          scrape_configs:
            - job_name: vault
              scrape_interval: 15s
              metrics_path: /v1/sys/metrics
              params:
                format:
                  - prometheus
              bearer_token_file: /vault/secrets/token
              static_configs:
                - targets:
                    - vault.${NAMESPACE}.svc.cluster.local:8200

    processors:
      batch: {}

    exporters:
      debug:
        verbosity: normal

    service:
      pipelines:
        metrics:
          receivers:
            - prometheus
          processors:
            - batch
          exporters:
            - debug
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: ${OBSERVABILITY_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "otel-vault-metrics"
        vault.hashicorp.com/agent-inject-token: "true"
        vault.hashicorp.com/agent-inject-containers: "otel-collector"
    spec:
      serviceAccountName: otel-collector
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.114.0
          args:
            - --config=/etc/otelcol-contrib/config.yaml
          resources: {}
          volumeMounts:
            - name: otel-collector-config
              mountPath: /etc/otelcol-contrib
              readOnly: true
      volumes:
        - name: otel-collector-config
          configMap:
            name: otel-collector-config
---
apiVersion: v1
kind: Pod
metadata:
  name: vault-metrics-check
  namespace: ${OBSERVABILITY_NAMESPACE}
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "otel-vault-metrics"
    vault.hashicorp.com/agent-inject-token: "true"
    vault.hashicorp.com/agent-inject-containers: "vault-metrics-check"
spec:
  serviceAccountName: otel-collector
  restartPolicy: OnFailure
  containers:
    - name: vault-metrics-check
      image: badouralix/curl-jq
      command:
        - sh
        - -c
      args:
        - sleep infinity
      resources: {}
EOF

echo "Waiting for the OpenTelemetry collector and metrics check pod to be ready..."
kubectl_vault wait -n "$OBSERVABILITY_NAMESPACE" --for=condition=Ready pod -l app=otel-collector --timeout=180s
kubectl_vault wait -n "$OBSERVABILITY_NAMESPACE" --for=condition=Ready pod/vault-metrics-check --timeout=180s

VAULT_METRICS_URL="http://vault.${NAMESPACE}.svc.cluster.local:8200/v1/sys/metrics?format=prometheus"

echo "Checking that unauthenticated Vault metrics access is blocked..."
UNAUTH_STATUS=$(kubectl_vault exec -n "$OBSERVABILITY_NAMESPACE" vault-metrics-check -c vault-metrics-check -- sh -c \
  "curl -s -o /tmp/vault-metrics-unauth.out -w '%{http_code}' '$VAULT_METRICS_URL'")
echo "Unauthenticated sys/metrics HTTP status: $UNAUTH_STATUS"
if [ "$UNAUTH_STATUS" = "200" ]; then
  echo "ERROR: unauthenticated sys/metrics access is enabled; this demo expects it to be blocked."
  exit 1
fi

echo "Checking that the injected Vault token can read sys/metrics..."
if ! kubectl_vault exec -n "$OBSERVABILITY_NAMESPACE" vault-metrics-check -c vault-metrics-check -- sh -c \
  "curl -sf -H \"X-Vault-Token: \$(cat /vault/secrets/token)\" -o /tmp/vault-metrics-auth.out '$VAULT_METRICS_URL' && grep -m 1 '^# HELP vault_' /tmp/vault-metrics-auth.out"; then
  echo "ERROR: authenticated sys/metrics check failed."
  exit 1
fi

echo "OpenTelemetry collector is configured to scrape Vault sys/metrics with bearer_token_file=/vault/secrets/token."

echo ""
echo "Vault cluster '${VAULT_CONTEXT}' is set up: kv-v2/vault-demo/mysecret is seeded,"
echo "the Agent Injector demo pod and OTel collector are running, and the"
echo "same-cluster auth/kubernetes mount is configured."
echo ""
echo "Vault is reachable cross-cluster at VAULT_ADDR=${VAULT_ADDR} via the"
echo "'vault-external' NodePort Service (nodePort ${VAULT_NODE_PORT}) mapped to"
echo "host port ${VAULT_HOST_PORT} by the kind cluster's extraPortMappings."
echo "Verify with: scripts/check-vault-connectivity.sh"
echo ""
echo "This script does not install VSO, VSO CRDs, or the cross-cluster"
echo "auth/kubernetes-vso mount -- see scripts/setup-vso-cluster.sh and the"
echo "VSO auth setup task for that."
