# inspired by https://www.youtube.com/watch?v=HHZO4_-GRYs

helm install vault hashicorp/vault \
  --create-namespace \
  --set "injector.enabled=true" \
  --set='server.auditStorage.enabled=true' \
  --set='server.auditStorage.size=1Gi' \
  --set='server.auditStorage.type=file'

# Wait for Vault pod to be ready
NAMESPACE="default"
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

kubectl exec -i "$POD" -n "$NAMESPACE" -- sh <<'EOF'
# Step 1: Initialize Vault and capture output
VAULT_INIT_OUTPUT=$(vault operator init -key-shares=5 -key-threshold=3)

# Step 2: Split output into lines and parse keys/token
ROOT_TOKEN_VALUE=""
echo "$VAULT_INIT_OUTPUT" | while IFS= read -r line; do
    if echo "$line" | grep -q "Initial Root Token:"; then
        ROOT_TOKEN_VALUE=$(echo "$line" | awk '{print $NF}')
        echo "Root token: $ROOT_TOKEN_VALUE"
    fi
done

# Save the full output to extract token later
echo "$VAULT_INIT_OUTPUT" > /tmp/vault_init_output.txt

# Parse keys and token
KEY1=$(echo "$VAULT_INIT_OUTPUT" | grep "Unseal Key 1:" | awk '{print $NF}')
KEY2=$(echo "$VAULT_INIT_OUTPUT" | grep "Unseal Key 2:" | awk '{print $NF}')
KEY3=$(echo "$VAULT_INIT_OUTPUT" | grep "Unseal Key 3:" | awk '{print $NF}')
ROOT_TOKEN=$(echo "$VAULT_INIT_OUTPUT" | grep "Initial Root Token:" | awk '{print $NF}')

# Step 3: Unseal with first three keys
vault operator unseal "$KEY1"
vault operator unseal "$KEY2"
vault operator unseal "$KEY3"

# Step 4: Login with root token
vault login "$ROOT_TOKEN"

# Store root token to a file
echo "$ROOT_TOKEN" > /vault/config/root_token
chmod 644 /vault/config/root_token

echo "Vault initialized, unsealed, and root token saved"
EOF

# Extract root token from pod and save locally
echo ""
echo "Saving root token for future use..."
ROOT_TOKEN=$(kubectl exec "$POD" -n "$NAMESPACE" -- cat /vault/config/root_token)
echo "$ROOT_TOKEN" > root_token.txt
echo "✓ Root token saved to root_token.txt"
echo ""

kubectl exec -ti "$POD" -n "$NAMESPACE" -- vault audit enable file file_path=stdout

kubectl apply -f - <<'EOF'
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
  name: default
  namespace: default
EOF

sleep 5

kubectl exec -it "$POD" -n "$NAMESPACE" -- vault auth enable kubernetes
kubectl exec -it "$POD" -n "$NAMESPACE" -- vault secrets enable -path=kv-v2 kv-v2
kubectl exec -it "$POD" -n "$NAMESPACE" -- vault kv put kv-v2/vault-demo/mysecret username=larry
kubectl exec -it "$POD" -n "$NAMESPACE" -- vault policy write mysecret - <<EOF
path "kv-v2/data/vault-demo/mysecret" {
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
kubectl exec -it "$POD" -n "$NAMESPACE" -- vault write auth/kubernetes/role/vault-demo \
    alias_name_source=serviceaccount_name \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default,mysecret \
    ttl=1h

kubectl exec -it "$POD" -n "$NAMESPACE" -- sh -c 'vault write auth/kubernetes/config \
  kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'

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
