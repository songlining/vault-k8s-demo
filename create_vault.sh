#!/usr/bin/env bash
# inspired by https://www.youtube.com/watch?v=HHZO4_-GRYs

# Host-side tools required by this script.
for _cmd in kubectl helm jq; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$_cmd' not found on PATH." >&2
    exit 1
  fi
done

helm upgrade --install vault hashicorp/vault \
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

# Wait for Vault pod to be ready
NAMESPACE="default"
OBSERVABILITY_NAMESPACE="observability"
VSO_NAMESPACE="vso-demo"
VSO_OPERATOR_NAMESPACE="vault-secrets-operator-system"
VSO_CHART_VERSION="1.4.0"
VAULT_SERVICE_ACCOUNT="vault"
echo "Waiting for Vault pod to be ready..."
while : ; do
  POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$POD" ]; then
    READY_STATUS=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Initialized")].status}')
    if [ "$READY_STATUS" = "True" ]; then
      break
    fi
  fi
  sleep 5
  echo "Still waiting for Vault pod to be ready..."
done
echo "Vault pod $POD is Initialized."

POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault \
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
    kubectl exec "$POD" -n "$NAMESPACE" -- vault operator unseal "$key" >/dev/null
  done
  return 0
}

if kubectl exec "$POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Initialized.*true' \
    && kubectl exec "$POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Sealed.*false'; then
  echo "Vault is already initialized and unsealed. Skipping init/unseal."
elif kubectl exec "$POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Initialized.*true'; then
  # Initialized but sealed (e.g. the pod restarted). Recover from saved keys.
  echo "Vault is initialized but sealed. Attempting to unseal from ${KEYS_FILE}..."
  if unseal_from_file; then
    echo "Vault unsealed from saved keys in ${KEYS_FILE}."
  else
    echo "ERROR: Vault is sealed and no usable unseal keys were found in ${KEYS_FILE}." >&2
    echo "Cannot recover this Vault. Recreate the cluster for a clean demo:" >&2
    echo "  kind delete cluster --name vault-lab && kind create cluster --name vault-lab" >&2
    echo "  helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update" >&2
    echo "  make setup" >&2
    exit 1
  fi
else
  # Fresh Vault: initialize, persist keys to a gitignored host file, then unseal.
  echo "Initializing Vault and saving unseal keys to ${KEYS_FILE}..."
  kubectl exec "$POD" -n "$NAMESPACE" -- \
    vault operator init -key-shares=5 -key-threshold=3 -format=json > "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"

  if ! unseal_from_file; then
    echo "ERROR: failed to unseal Vault from freshly written ${KEYS_FILE}." >&2
    exit 1
  fi

  # Login with the root token without printing it to the terminal.
  ROOT_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")
  kubectl exec "$POD" -n "$NAMESPACE" -- vault login -no-print "$ROOT_TOKEN"

  echo "Vault initialized, unsealed, logged in and ready for use."
  echo "Unseal keys and root token saved to ${KEYS_FILE} (gitignored). Keep this file safe; it is demo-only."
fi

# Enable audit device only if not already enabled
if kubectl exec "$POD" -n "$NAMESPACE" -- vault audit list 2>/dev/null | grep -q '^file/'; then
  echo "Audit device 'file' already enabled. Skipping."
else
  kubectl exec "$POD" -n "$NAMESPACE" -- vault audit enable file file_path=stdout
fi

kubectl apply -f - <<EOF
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

# Enable kubernetes auth only if not already enabled
if kubectl exec "$POD" -n "$NAMESPACE" -- vault auth list 2>/dev/null | grep -q '^kubernetes/'; then
  echo "Kubernetes auth method already enabled. Skipping."
else
  kubectl exec "$POD" -n "$NAMESPACE" -- vault auth enable kubernetes
fi

# Enable kv-v2 secrets engine only if not already enabled
if kubectl exec "$POD" -n "$NAMESPACE" -- vault secrets list 2>/dev/null | grep -q '^kv-v2/'; then
  echo "Secrets engine kv-v2 already enabled. Skipping."
else
  kubectl exec "$POD" -n "$NAMESPACE" -- vault secrets enable -path=kv-v2 kv-v2
fi

kubectl exec "$POD" -n "$NAMESPACE" -- vault kv put kv-v2/vault-demo/mysecret username=larry
kubectl exec -i "$POD" -n "$NAMESPACE" -- vault policy write mysecret - <<EOF
path "kv-v2/data/vault-demo/mysecret" {
  capabilities = ["read"]
}
EOF

kubectl exec -i "$POD" -n "$NAMESPACE" -- vault policy write vault-metrics-read - <<EOF
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
kubectl exec "$POD" -n "$NAMESPACE" -- vault write auth/kubernetes/role/vault-demo \
    alias_name_source=serviceaccount_name \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default,mysecret \
    ttl=1h

kubectl exec "$POD" -n "$NAMESPACE" -- sh -c "vault write auth/kubernetes/config \
  kubernetes_host=https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT"

kubectl apply -f - <<EOF
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

kubectl exec "$POD" -n "$NAMESPACE" -- vault write auth/kubernetes/role/otel-vault-metrics \
    alias_name_source=serviceaccount_name \
    bound_service_account_names=otel-collector \
    bound_service_account_namespaces="$OBSERVABILITY_NAMESPACE" \
    policies=vault-metrics-read \
    ttl=1h

# Recreate vault-demo pod so the Vault Agent sidecar is freshly injected
# (the agent-injector mutating webhook only runs on pod CREATE, not UPDATE)
kubectl delete pod vault-demo -n "$NAMESPACE" --ignore-not-found=true --wait=true

kubectl apply -f - <<'EOF'
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

kubectl apply -f - <<EOF
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
kubectl wait -n "$OBSERVABILITY_NAMESPACE" --for=condition=Ready pod -l app=otel-collector --timeout=180s
kubectl wait -n "$OBSERVABILITY_NAMESPACE" --for=condition=Ready pod/vault-metrics-check --timeout=180s

VAULT_METRICS_URL="http://vault.${NAMESPACE}.svc.cluster.local:8200/v1/sys/metrics?format=prometheus"

echo "Checking that unauthenticated Vault metrics access is blocked..."
UNAUTH_STATUS=$(kubectl exec -n "$OBSERVABILITY_NAMESPACE" vault-metrics-check -c vault-metrics-check -- sh -c \
  "curl -s -o /tmp/vault-metrics-unauth.out -w '%{http_code}' '$VAULT_METRICS_URL'")
echo "Unauthenticated sys/metrics HTTP status: $UNAUTH_STATUS"
if [ "$UNAUTH_STATUS" = "200" ]; then
  echo "ERROR: unauthenticated sys/metrics access is enabled; this demo expects it to be blocked."
  exit 1
fi

echo "Checking that the injected Vault token can read sys/metrics..."
if ! kubectl exec -n "$OBSERVABILITY_NAMESPACE" vault-metrics-check -c vault-metrics-check -- sh -c \
  "curl -sf -H \"X-Vault-Token: \$(cat /vault/secrets/token)\" -o /tmp/vault-metrics-auth.out '$VAULT_METRICS_URL' && grep -m 1 '^# HELP vault_' /tmp/vault-metrics-auth.out"; then
  echo "ERROR: authenticated sys/metrics check failed."
  exit 1
fi

echo "OpenTelemetry collector is configured to scrape Vault sys/metrics with bearer_token_file=/vault/secrets/token."

# ============================================================================
# Vault Secrets Operator (VSO) demo path
# ----------------------------------------------------------------------------
# Additive and idempotent. VSO runs a cluster-wide operator that syncs Vault
# secrets into native Kubernetes Secret objects via CRDs, instead of injecting a
# per-pod Agent sidecar that writes a file. This block:
#   - installs VSO via Helm (pinned chart version)
#   - creates the vso-demo namespace + service account
#   - reuses the existing kubernetes auth method with a dedicated vso-demo role
#   - applies VaultConnection / VaultAuth / VaultStaticSecret CRDs
#   - deploys a plain consuming pod (no Vault annotations, no sidecar)
#   - asserts the native Secret materialized
# ============================================================================

echo ""
echo "=== Configuring the Vault Secrets Operator (VSO) demo path ==="

# Re-seed the demo secret to a known starting value so the rotation demo is
# repeatable (the vso-demo.sh rotation section also resets this at the end).
kubectl exec "$POD" -n "$NAMESPACE" -- vault kv put kv-v2/vault-demo/mysecret username=larry >/dev/null

# Dedicated Kubernetes auth role for VSO. Reuses the existing 'mysecret' policy
# (read on kv-v2/data/vault-demo/mysecret) but binds a distinct, auditable
# identity: the vso-demo service account in the vso-demo namespace.
kubectl exec "$POD" -n "$NAMESPACE" -- vault write auth/kubernetes/role/vso-demo \
    alias_name_source=serviceaccount_name \
    bound_service_account_names=vso-demo \
    bound_service_account_namespaces="$VSO_NAMESPACE" \
    policies=default,mysecret \
    ttl=1h

# Install the Vault Secrets Operator (idempotent; pinned chart version).
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace "$VSO_OPERATOR_NAMESPACE" \
  --create-namespace \
  --version "$VSO_CHART_VERSION"

echo "Waiting for the Vault Secrets Operator to be available..."
kubectl wait -n "$VSO_OPERATOR_NAMESPACE" \
  --for=condition=Available deployment \
  -l app.kubernetes.io/name=vault-secrets-operator --timeout=180s

# Namespace + service account that VSO authenticates as.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${VSO_NAMESPACE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vso-demo
  namespace: ${VSO_NAMESPACE}
EOF

# VSO CRDs: how to reach Vault, how to authenticate, and what to sync.
kubectl apply -f - <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vso-demo-connection
  namespace: ${VSO_NAMESPACE}
spec:
  address: http://vault.${NAMESPACE}.svc.cluster.local:8200
  skipTLSVerify: true
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vso-demo-auth
  namespace: ${VSO_NAMESPACE}
spec:
  vaultConnectionRef: vso-demo-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: vso-demo
    serviceAccount: vso-demo
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: vso-demo-mysecret
  namespace: ${VSO_NAMESPACE}
spec:
  vaultAuthRef: vso-demo-auth
  mount: kv-v2
  type: kv-v2
  path: vault-demo/mysecret
  refreshAfter: 30s
  destination:
    name: vso-demo-mysecret
    create: true
EOF

# Plain consuming pod: standard envFrom, zero Vault annotations, no sidecar.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: vso-demo-app
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
            name: vso-demo-mysecret
EOF

# Assert the native Secret materialized from Vault.
echo "Waiting for VSO to materialize the native Kubernetes Secret..."
VSO_SYNCED="false"
for _ in $(seq 1 30); do
  VSO_VALUE=$(kubectl get secret vso-demo-mysecret -n "$VSO_NAMESPACE" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ "$VSO_VALUE" = "larry" ]; then
    VSO_SYNCED="true"
    break
  fi
  sleep 3
done

if [ "$VSO_SYNCED" != "true" ]; then
  echo "ERROR: VSO did not materialize secret vso-demo-mysecret with username=larry."
  echo "Inspect with: kubectl describe vaultstaticsecret vso-demo-mysecret -n ${VSO_NAMESPACE}"
  exit 1
fi

echo "Waiting for the VSO consuming pod to be ready..."
kubectl wait -n "$VSO_NAMESPACE" --for=condition=Ready pod/vso-demo-app --timeout=180s

echo "Vault Secrets Operator demo is ready: kv-v2/vault-demo/mysecret is synced to native Secret vso-demo/vso-demo-mysecret."
