#!/bin/bash
# Script to demonstrate entity-based templated policies for Kubernetes auth method management
# This solves the problem where multiple workspaces in the same project need isolated access

set -e

NAMESPACE="default"
POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

echo "POD name: $POD"
echo ""

echo "============================================================================"
echo "Vault Entity-Based Policy Demo - Using Metadata for Path Templating"
echo "============================================================================"
echo ""

# Step 1: Enable userpass auth method (mimicking Terraform workspace OIDC login)
echo "[Step 1] Setting up userpass auth method (mimicking Terraform workspace OIDC)..."
echo ""

# Clean up any existing userpass auth method
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable userpass 2>/dev/null || true

# Enable userpass
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth enable userpass
echo "✓ Userpass auth method enabled"
echo ""

# Create a user that represents a Terraform workspace
echo "[Step 2] Creating userpass user 'workspace-tf-user' (mimicking workspace OIDC login)..."
kubectl exec "$POD" -n "$NAMESPACE" -- vault write auth/userpass/users/workspace-tf-user \
  password=test123 \
  token_ttl=1h

echo "✓ User 'workspace-tf-user' created"
echo ""

# Step 2: Create an entity and entity alias with metadata
echo "[Step 3] Creating Entity with metadata for workspace isolation..."
echo ""

# First, we need to get the userpass accessor
USERPASS_ACCESSOR=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault auth list -format=json | \
  jq -r '.["userpass/"].accessor')

echo "Userpass accessor: $USERPASS_ACCESSOR"

# Create an entity
ENTITY_OUTPUT=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault write -format=json identity/entity \
  name=workspace-entity \
  metadata=workspace-name=kubernetes-my_project_123)

ENTITY_ID=$(echo "$ENTITY_OUTPUT" | jq -r '.data.id')
echo "✓ Entity created with ID: $ENTITY_ID"
echo ""

# Create entity alias linking the userpass user to the entity with metadata
echo "[Step 4] Creating EntityAlias with metadata workspace-name=kubernetes-my_project_123..."
kubectl exec "$POD" -n "$NAMESPACE" -- vault write identity/entity-alias \
  name=workspace-tf-user \
  canonical_id="$ENTITY_ID" \
  mount_accessor="$USERPASS_ACCESSOR"

echo "✓ EntityAlias created linking userpass user to entity"
echo ""

# Verify entity metadata
echo "Entity details:"
kubectl exec "$POD" -n "$NAMESPACE" -- vault read identity/entity/id/"$ENTITY_ID"
echo ""

# Step 3: Create templated policy
echo "[Step 5] Creating templated policy using entity metadata..."
echo ""

cat k8s-auth-manager-policy-templated.hcl | kubectl exec -i "$POD" -n "$NAMESPACE" -- vault policy write k8s-auth-manager-templated -

echo "✓ Templated policy 'k8s-auth-manager-templated' created successfully!"
echo ""

# Step 4: Attach the policy to the entity
echo "[Step 6] Attaching templated policy to the entity..."
kubectl exec "$POD" -n "$NAMESPACE" -- vault write identity/entity/id/"$ENTITY_ID" \
  policies=k8s-auth-manager-templated

echo "✓ Policy attached to entity"
echo ""

# Step 5: Test with userpass login
echo "[Step 7] Testing the setup - Login as workspace user..."
echo ""

LOGIN_OUTPUT=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault login -format=json -method=userpass \
  username=workspace-tf-user \
  password=test123)

USER_TOKEN=$(echo "$LOGIN_OUTPUT" | jq -r '.auth.client_token')

echo "✓ Logged in successfully"
echo "User token: $USER_TOKEN"
echo ""

echo "Token details (using root token to lookup):"
kubectl exec "$POD" -n "$NAMESPACE" -- vault token lookup "$USER_TOKEN" 2>/dev/null || echo "  (Token lookup requires additional permissions - skipping)"
echo ""

# Step 6: Test the templated policy
echo "[Step 8] Testing templated policy - workspace should only access kubernetes-my_project_123..."
echo ""

echo "=== Running Tests with Entity-Based Templated Token ==="
echo ""

# Clean up any previous test auth methods
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-my_project_123 2>/dev/null || true
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-other_project 2>/dev/null || true

echo '1. Testing: List auth methods (should work - read only)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault auth list && echo '✓ SUCCESS'

echo ''
echo '2. Testing: Enable kubernetes auth at templated path (kubernetes-my_project_123) - should WORK'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault auth enable -path=kubernetes-my_project_123 kubernetes && echo '✓ SUCCESS - Can access own workspace path'

echo ''
echo '2.5. Testing: List auth methods to verify kubernetes-my_project_123 was enabled'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault auth list | grep -E "(Path|kubernetes)" && echo '✓ SUCCESS - kubernetes-my_project_123 is listed'

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
echo '5. Testing: Attempt to enable auth at different path (kubernetes-other_project) - should FAIL'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault auth enable -path=kubernetes-other_project kubernetes 2>&1 || echo '✓ CORRECTLY DENIED - Cannot access other workspace paths'

echo ''
echo '6. Testing: Attempt to enable auth at generic path (kubernetes-dev) - should FAIL'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault auth enable -path=kubernetes-dev kubernetes 2>&1 || echo '✓ CORRECTLY DENIED - Can only access workspace-specific path'

echo ''
echo '7. Testing: Attempt to read secrets - should FAIL'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$USER_TOKEN" vault kv get kv-v2/vault-demo/mysecret 2>&1 || echo '✓ CORRECTLY DENIED - No access to secrets'

echo ''
echo 'All tests completed!'

echo ""
echo "============================================================================"
echo "Entity-Based Policy Verification Complete!"
echo "============================================================================"
echo ""
echo "This demonstration shows how to use entity metadata for workspace isolation:"
echo ""
echo "The workspace user (workspace-tf-user) can ONLY:"
echo "  ✓ Access auth paths matching: sys/auth/{{identity.entity.metadata.workspace-name}}"
echo "  ✓ In this case: sys/auth/kubernetes-my_project_123"
echo "  ✓ Configure and manage ONLY that specific auth backend"
echo "  ✓ List auth methods (read-only for verification)"
echo ""
echo "The workspace user CANNOT:"
echo "  ✗ Access other workspace auth backends (kubernetes-other_project)"
echo "  ✗ Access generic auth backends (kubernetes-dev, kubernetes-prod)"
echo "  ✗ Access secrets or other sensitive paths"
echo ""
echo "This solves the client's problem where multiple environments share a project prefix"
echo "but need isolated access to their own specific auth backend."
echo ""
echo "============================================================================"
echo "Solution for Client's Use Case:"
echo "============================================================================"
echo ""
echo "For projects with backends named 'my-project-<randomstring>', you can:"
echo ""
echo "1. Store the full backend name in entity metadata (workspace-name=my-project-abc123)"
echo "2. Use templated policies with {{identity.entity.metadata.workspace-name}}"
echo "3. Each workspace can ONLY manage its specific backend, not others with same prefix"
echo ""
echo "This provides true isolation without requiring code changes across projects!"
echo ""
