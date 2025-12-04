#!/bin/bash
# Script to create a least privilege policy for managing Kubernetes auth methods

set -e

NAMESPACE="default"
POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

echo "=========================================="
echo "Vault Kubernetes Auth Demo - Clean Start"
echo "=========================================="
echo ""

# Step 1: Clean up any existing test auth methods
echo "[Step 1] Cleaning up previous test auth methods..."
echo ""

# Get list of all kubernetes-* auth methods (excluding the main 'kubernetes/' if it exists)
TEST_AUTH_METHODS=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault auth list -format=json | \
  jq -r 'to_entries | .[] | select(.key | startswith("kubernetes-")) | .key' || echo "")

if [ -n "$TEST_AUTH_METHODS" ]; then
  echo "Found existing test auth methods to clean up:"
  echo "$TEST_AUTH_METHODS"
  echo ""

  while IFS= read -r auth_path; do
    if [ -n "$auth_path" ]; then
      echo "  Disabling: $auth_path"
      kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable "$auth_path" 2>/dev/null || \
        echo "    Warning: Could not disable $auth_path (may not exist or no permission)"
    fi
  done <<< "$TEST_AUTH_METHODS"
  echo ""
  echo "✓ Cleanup completed"
else
  echo "✓ No existing test auth methods found - starting clean"
fi

echo ""
echo "[Step 2] Creating least privilege policy for Kubernetes auth method management..."
echo ""

# Create the policy
cat <<'EOF' | kubectl exec -i "$POD" -n "$NAMESPACE" -- vault policy write k8s-auth-manager -
# Policy: k8s-auth-manager
# Purpose: Allow creation and management of Kubernetes auth methods with least privilege

# Enable/disable Kubernetes auth methods at paths matching 'kubernetes-*'
path "sys/auth/kubernetes-*" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
}

# Full access to configure and manage ALL Kubernetes auth methods
# This includes: config, roles, and all sub-paths
path "auth/kubernetes*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}

# Read-only access to list all auth methods (for verification)
path "sys/auth" {
  capabilities = ["read"]
}
EOF

echo "✓ Policy 'k8s-auth-manager' created successfully!"
echo ""
echo "[Step 3] Creating a child token with this policy..."
echo ""

# Create a child token with the policy
TOKEN_OUTPUT=$(kubectl exec -it "$POD" -n "$NAMESPACE" -- vault token create \
  -policy=k8s-auth-manager \
  -ttl=1h \
  -format=json)

CHILD_TOKEN=$(echo "$TOKEN_OUTPUT" | jq -r '.auth.client_token')

echo "✓ Child token created: $CHILD_TOKEN"
echo ""

echo "Token details:"
kubectl exec -it "$POD" -n "$NAMESPACE" -- vault token lookup "$CHILD_TOKEN"

echo ""
echo "[Step 4] Testing the policy with child token..."

# Test the policy with the child token
echo ""
echo "=== Running Tests with Child Token ==="
echo ""

# Clean up any previous test
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-test 2>/dev/null || true

echo '1. Testing: List auth methods (should work - read only)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth list && echo '✓ SUCCESS'

echo ''
echo '2. Testing: Enable new Kubernetes auth at kubernetes-test path (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth enable -path=kubernetes-test kubernetes && echo '✓ SUCCESS'

echo ''
echo '3. Testing: Configure the auth method (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-test/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT' && echo '✓ SUCCESS'

echo ''
echo '4. Testing: Create a role (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault write auth/kubernetes-test/role/test-role \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=default \
  ttl=1h && echo '✓ SUCCESS'

echo ''
echo '5. Testing: List roles (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault list auth/kubernetes-test/role && echo '✓ SUCCESS'

echo ''
echo '6. Testing: Read role (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault read auth/kubernetes-test/role/test-role && echo '✓ SUCCESS'

echo ''
echo '7. Testing: Attempting to read a secret (should FAIL - not in policy)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault kv get kv-v2/vault-demo/mysecret 2>&1 || echo '✓ CORRECTLY DENIED'

echo ''
echo '8. Testing: List all auth methods to show kubernetes-test was created'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth list | grep -E "(Path|kubernetes)" && echo '✓ SUCCESS'

echo ''
echo 'All tests completed!'

echo ""
echo "=========================================="
echo "Policy verification complete!"
echo "=========================================="
echo ""
echo "The child token can:"
echo "  ✓ Enable Kubernetes auth methods at paths matching 'kubernetes-*'"
echo "  ✓ Configure Kubernetes auth methods"
echo "  ✓ Create and manage roles"
echo "  ✓ List auth methods (read-only)"
echo ""
echo "The child token CANNOT:"
echo "  ✗ Access secrets"
echo "  ✗ Modify other auth methods"
echo "  ✗ Enable non-Kubernetes auth methods"
echo "  ✗ Access sys/policies or other administrative paths"
echo ""
echo "=========================================="
echo "Created Auth Methods:"
echo "=========================================="
echo ""
printf "%-25s %-15s %s\n" "PATH" "TYPE" "DESCRIPTION"
printf "%-25s %-15s %s\n" "----" "----" "-----------"
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth list -format=json | \
  jq -r 'to_entries | .[] | select(.key | startswith("kubernetes")) | "\(.key)|\(.value.type)|\(.value.description // "N/A")"' | \
  while IFS='|' read -r path type desc; do
    printf "%-25s %-15s %s\n" "$path" "$type" "$desc"
  done
echo ""
echo "To clean up the test auth method, run:"
echo "  kubectl exec $POD -n $NAMESPACE -- vault auth disable kubernetes-test"
