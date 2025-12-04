#!/bin/bash
# Script to demonstrate entity-based templated policies for workspace isolation
# This solves the problem where multiple workspaces share a project prefix

set -e

NAMESPACE="default"
POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

echo "POD name: $POD"

echo "============================================================================"
echo "Vault Entity-Based Policy Demo - Workspace Isolation with Metadata"
echo "============================================================================"
echo ""

# Check if we have vault access (need root or admin token)
echo "Checking Vault authentication..."
if ! kubectl exec "$POD" -n "$NAMESPACE" -- vault token lookup &>/dev/null; then
  echo "ERROR: Not authenticated to Vault. Please ensure you have a root token."
  echo ""
  echo "To set up Vault, run:"
  echo "  ./create_vault.sh"
  echo ""
  echo "Or if Vault is already initialized, login with root token:"
  echo "  kubectl exec $POD -n $NAMESPACE -- vault login <root-token>"
  exit 1
fi

# Check if we have sufficient permissions (try to test a privileged operation)
echo "Verifying admin/root privileges..."
CURRENT_TOKEN_POLICIES=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault token lookup -format=json 2>/dev/null | jq -r '.data.policies[]' 2>/dev/null)
if echo "$CURRENT_TOKEN_POLICIES" | grep -q "root"; then
  echo "✓ Root token detected"
elif ! kubectl exec "$POD" -n "$NAMESPACE" -- vault auth list &>/dev/null; then
  echo "ERROR: Current token does not have sufficient permissions."
  echo ""
  echo "Current token policies: $CURRENT_TOKEN_POLICIES"
  echo ""
  echo "This script requires root or admin token to:"
  echo "  - Enable userpass auth method"
  echo "  - Create entities and entity aliases"
  echo "  - Create and attach policies"
  echo ""
  echo "Please login with root token:"
  echo "  kubectl exec $POD -n $NAMESPACE -- vault login <root-token>"
  exit 1
else
  echo "✓ Vault authentication verified (admin token)"
fi
echo ""

# Step 1: Clean up any existing kubernetes auth methods and userpass
echo "[Step 1] Cleaning up previous test resources..."
echo ""

# Clean up kubernetes auth methods
ALL_K8S_AUTH_METHODS=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault auth list -format=json | \
  jq -r 'to_entries | .[] | select(.key | startswith("kubernetes")) | .key' || echo "")

if [ -n "$ALL_K8S_AUTH_METHODS" ]; then
  echo "Cleaning up existing Kubernetes auth methods:"
  while IFS= read -r auth_path; do
    if [ -n "$auth_path" ]; then
      echo "  Disabling: $auth_path"
      kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable "$auth_path" 2>/dev/null || true
    fi
  done <<< "$ALL_K8S_AUTH_METHODS"
fi

# Clean up userpass auth method
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable userpass 2>/dev/null || true

echo "✓ Cleanup completed"
echo ""

# Step 2: Enable userpass auth method (mimicking Terraform workspace OIDC login)
echo "[Step 2] Setting up userpass auth method (mimicking Terraform workspace OIDC)..."
echo ""

kubectl exec "$POD" -n "$NAMESPACE" -- vault auth enable userpass
echo "✓ Userpass auth method enabled"
echo ""

# Step 3: Create userpass user (representing a Terraform workspace)
echo "[Step 3] Creating userpass user 'workspace-tf-user' (mimicking workspace OIDC login)..."
kubectl exec "$POD" -n "$NAMESPACE" -- vault write auth/userpass/users/workspace-tf-user \
  password=test123 \
  token_ttl=1h

echo "✓ User 'workspace-tf-user' created"
echo ""

# Step 4: Create entity with metadata
echo "[Step 4] Creating Entity with metadata for workspace isolation..."
echo ""

# Get userpass accessor
USERPASS_ACCESSOR=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault auth list -format=json | \
  jq -r '.["userpass/"].accessor')

echo "Userpass accessor: $USERPASS_ACCESSOR"

# Create entity with metadata
ENTITY_OUTPUT=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault write -format=json identity/entity \
  name=workspace-entity \
  metadata=workspace-name=kubernetes-my_project_123)

ENTITY_ID=$(echo "$ENTITY_OUTPUT" | jq -r '.data.id')
echo "✓ Entity created with ID: $ENTITY_ID"
echo "  Metadata: workspace-name=kubernetes-my_project_123"
echo ""

# Step 5: Create entity alias linking userpass user to entity
echo "[Step 5] Creating EntityAlias linking userpass user to entity..."
kubectl exec "$POD" -n "$NAMESPACE" -- vault write identity/entity-alias \
  name=workspace-tf-user \
  canonical_id="$ENTITY_ID" \
  mount_accessor="$USERPASS_ACCESSOR" > /dev/null

echo "✓ EntityAlias created"
echo ""

# Verify entity metadata
echo "Entity details:"
kubectl exec "$POD" -n "$NAMESPACE" -- vault read identity/entity/id/"$ENTITY_ID" | grep -E "(metadata|name|policies)"
echo ""

# Step 6: Create templated policy using entity metadata
echo "[Step 6] Creating templated policy using entity metadata..."
echo ""

cat k8s-auth-manager-policy.hcl | kubectl exec -i "$POD" -n "$NAMESPACE" -- vault policy write k8s-auth-manager -

echo "✓ Templated policy 'k8s-auth-manager' created"
echo ""

# Step 7: Attach policy to entity
echo "[Step 7] Attaching templated policy to entity..."
kubectl exec "$POD" -n "$NAMESPACE" -- vault write identity/entity/id/"$ENTITY_ID" \
  policies=k8s-auth-manager > /dev/null

echo "✓ Policy attached to entity"
echo ""

# Step 8: Login as workspace user
echo "[Step 8] Testing - Login as workspace user..."
echo ""

LOGIN_OUTPUT=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault login -format=json -method=userpass \
  username=workspace-tf-user \
  password=test123)

USER_TOKEN=$(echo "$LOGIN_OUTPUT" | jq -r '.auth.client_token')

echo "✓ Logged in as workspace-tf-user"
echo "  Token: $USER_TOKEN"
echo ""

# Step 9: Test templated policy
echo "[Step 9] Testing templated policy - workspace isolation..."
echo ""

echo "=== Running Tests with Entity-Based Templated Token ==="
echo ""

# Clean up any previous test auth methods
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-my_project_123 2>/dev/null || true
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-other_project 2>/dev/null || true
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-dev 2>/dev/null || true

echo '1. Testing: List auth methods (should work - read only)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault auth list && echo '✓ SUCCESS'

echo ''
echo '2. Testing: Enable auth at templated path (kubernetes-my_project_123) - should WORK'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault auth enable -path=kubernetes-my_project_123 kubernetes && echo '✓ SUCCESS - Can access own workspace path'

echo ''
echo '3. Testing: Configure kubernetes-my_project_123 auth method - should WORK'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-my_project_123/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT' && echo '✓ SUCCESS'

echo ''
echo '4. Testing: Create role in kubernetes-my_project_123 - should WORK'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault write auth/kubernetes-my_project_123/role/app-role \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=default \
  ttl=1h && echo '✓ SUCCESS'

echo ''
echo '5. Testing: List roles in kubernetes-my_project_123 - should WORK'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault list auth/kubernetes-my_project_123/role && echo '✓ SUCCESS'

echo ''
echo '6. Testing: Enable auth at different path (kubernetes-other_project) - should FAIL'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault auth enable -path=kubernetes-other_project kubernetes 2>&1 || echo '✓ CORRECTLY DENIED - Cannot access other workspace paths'

echo ''
echo '7. Testing: Enable auth at generic path (kubernetes-dev) - should FAIL'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault auth enable -path=kubernetes-dev kubernetes 2>&1 || echo '✓ CORRECTLY DENIED - Can only access workspace-specific path'

echo ''
echo '8. Testing: Attempt to read secrets - should FAIL'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault kv get kv-v2/vault-demo/mysecret 2>&1 || echo '✓ CORRECTLY DENIED - No access to secrets'

echo ''
echo '9. Testing: Attempt to modify entity metadata - should FAIL'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault write identity/entity/id/"$ENTITY_ID" metadata=workspace-name=kubernetes-other_project 2>&1 || echo '✓ CORRECTLY DENIED - Cannot tamper with metadata'

echo ''
echo 'All tests completed!'

echo ""
echo "============================================================================"
echo "Entity-Based Policy Verification Complete!"
echo "============================================================================"
echo ""
echo "This demonstration shows workspace isolation using entity metadata:"
echo ""
echo "The workspace user (workspace-tf-user) can ONLY:"
echo "  ✓ Access auth path: sys/auth/{{identity.entity.metadata.workspace-name}}"
echo "  ✓ In this case: sys/auth/kubernetes-my_project_123"
echo "  ✓ Configure and manage ONLY that specific auth backend"
echo "  ✓ List auth methods (read-only for verification)"
echo ""
echo "The workspace user CANNOT:"
echo "  ✗ Access other workspace auth backends (kubernetes-other_project)"
echo "  ✗ Access generic auth backends (kubernetes-dev, kubernetes-prod)"
echo "  ✗ Access secrets or other sensitive paths"
echo "  ✗ Modify entity metadata (prevents tampering)"
echo ""
echo "============================================================================"
echo "Solution for Client's Use Case:"
echo "============================================================================"
echo ""
echo "For projects with backends named 'my-project-<randomstring>', you can:"
echo ""
echo "1. Store the full backend name in entity metadata:"
echo "   workspace-name=my-project-abc123"
echo ""
echo "2. Use templated policies with:"
echo "   {{identity.entity.metadata.workspace-name}}"
echo ""
echo "3. Each workspace can ONLY manage its specific backend,"
echo "   not others with same prefix"
echo ""
echo "This provides true isolation without requiring code changes!"
echo ""
echo "============================================================================"
echo "Created Auth Methods:"
echo "============================================================================"
echo ""
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth list | grep -E "(Path|kubernetes-my_project)" || echo "No auth methods found"
echo ""
echo "To clean up:"
echo "  kubectl exec $POD -n $NAMESPACE -- vault auth disable userpass"
echo "  kubectl exec $POD -n $NAMESPACE -- vault auth disable kubernetes-my_project_123"
echo ""
echo "Or simply run this script again - it will clean up automatically!"
echo ""
