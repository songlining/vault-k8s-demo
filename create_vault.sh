#!/usr/bin/env bash
# inspired by https://www.youtube.com/watch?v=HHZO4_-GRYs

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
if kubectl exec "$POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Initialized.*true' \
    && kubectl exec "$POD" -n "$NAMESPACE" -- vault status 2>/dev/null | grep -q 'Sealed.*false'; then
  echo "Vault is already initialized and unsealed. Skipping init/unseal."
else
kubectl exec -i "$POD" -n "$NAMESPACE" -- sh <<'EOF'
# Step 1: Initialize Vault and capture output
VAULT_INIT_OUTPUT=$(vault operator init -key-shares=5 -key-threshold=3)

# Step 2: Split output into lines and parse keys/token
echo "$VAULT_INIT_OUTPUT" | awk '{
    gsub(/Unseal Key [0-9]+: |Initial Root Token: /, "\n&")
    sub(/^\n/, "")
    print
}' | {
    while IFS= read -r line; do
        case $line in
            "Unseal Key"*)
                key=$(echo "$line" | awk '{print $4}')
                # Store keys sequentially
                case $line in
                    *"1:"*) key1=$key ;;
                    *"2:"*) key2=$key ;;
                    *"3:"*) key3=$key ;;
                esac
                ;;
            "Initial Root Token"*)
                root_token=$(echo "$line" | awk '{print $4}')
                ;;
        esac
    done

    # Step 3: Unseal with first three keys
    vault operator unseal "$key1"
    vault operator unseal "$key2"
    vault operator unseal "$key3"

    # Step 4: Login with root token without printing it to the terminal
    vault login -no-print "$root_token"
}

echo "Vault initialized, unsealed, logged in and ready for use"
EOF
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
