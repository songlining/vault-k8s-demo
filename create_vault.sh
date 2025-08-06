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

    # Step 4: Login with root token
    vault login "$root_token"
    # store root_token to a file so it can be found later
    echo "$root_token" > /vault/config/root_token
}

echo "Vault initialized, unsealed, logged in and ready for use"
EOF

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
