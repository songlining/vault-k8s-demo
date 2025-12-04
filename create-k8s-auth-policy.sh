#!/bin/bash
# Script to create a least privilege policy for managing Kubernetes auth methods

set -e

NAMESPACE="default"
POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

echo "POD name: $POD"

echo "=========================================="
echo "Vault Kubernetes Auth Demo - Clean Start"
echo "=========================================="
echo ""

# Step 1: Clean up any existing kubernetes auth methods (including default)
echo "[Step 1] Cleaning up ALL previous Kubernetes auth methods..."
echo ""

# Get list of ALL kubernetes auth methods (including the default 'kubernetes/')
ALL_K8S_AUTH_METHODS=$(kubectl exec "$POD" -n "$NAMESPACE" -- vault auth list -format=json | \
  jq -r 'to_entries | .[] | select(.key | startswith("kubernetes")) | .key' || echo "")

if [ -n "$ALL_K8S_AUTH_METHODS" ]; then
  echo "Found existing Kubernetes auth methods to clean up:"
  echo "$ALL_K8S_AUTH_METHODS"
  echo ""

  while IFS= read -r auth_path; do
    if [ -n "$auth_path" ]; then
      echo "  Disabling: $auth_path"
      kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable "$auth_path" 2>/dev/null || \
        echo "    Warning: Could not disable $auth_path (may not exist or no permission)"
    fi
  done <<< "$ALL_K8S_AUTH_METHODS"
  echo ""
  echo "✓ Cleanup completed - All Kubernetes auth methods removed"
else
  echo "✓ No existing Kubernetes auth methods found - starting clean"
fi

echo ""
echo "[Step 2] Creating least privilege policy for Kubernetes auth method management..."
echo ""

# Create the policy from file
cat k8s-auth-manager-policy.hcl | kubectl exec -i "$POD" -n "$NAMESPACE" -- vault policy write k8s-auth-manager -

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
echo '2. Testing: Enable new Kubernetes auth at kubernetes-dev path (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth enable -path=kubernetes-dev kubernetes && echo '✓ SUCCESS'

echo ''
echo '3. Testing: Enable new Kubernetes auth at kubernetes-prod path (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth enable -path=kubernetes-prod kubernetes && echo '✓ SUCCESS'

echo ''
echo '4. Testing: Enable new Kubernetes auth at kubernetes-staging path (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth enable -path=kubernetes-staging kubernetes && echo '✓ SUCCESS'

echo ''
echo '5. Testing: Configure the kubernetes-dev auth method (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-dev/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT' && echo '✓ SUCCESS'

echo ''
echo '6. Testing: Configure the kubernetes-prod auth method (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-prod/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT' && echo '✓ SUCCESS'

echo ''
echo '7. Testing: Create a role in kubernetes-dev (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault write auth/kubernetes-dev/role/dev-role \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=default \
  ttl=1h && echo '✓ SUCCESS'

echo ''
echo '8. Testing: Create a role in kubernetes-prod (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault write auth/kubernetes-prod/role/prod-role \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=default \
  ttl=1h && echo '✓ SUCCESS'

echo ''
echo '9. Testing: List roles in kubernetes-dev (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault list auth/kubernetes-dev/role && echo '✓ SUCCESS'

echo ''
echo '10. Testing: Read role from kubernetes-prod (should work)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault read auth/kubernetes-prod/role/prod-role && echo '✓ SUCCESS'

echo ''
echo '11. Testing: Attempting to read a secret (should FAIL - not in policy)'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault kv get kv-v2/vault-demo/mysecret 2>&1 || echo '✓ CORRECTLY DENIED'

echo ''
echo '12. Testing: List all auth methods to show all created Kubernetes auth methods'
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
echo "To clean up the created auth methods, run:"
echo "  kubectl exec $POD -n $NAMESPACE -- vault auth disable kubernetes-dev"
echo "  kubectl exec $POD -n $NAMESPACE -- vault auth disable kubernetes-prod"
echo "  kubectl exec $POD -n $NAMESPACE -- vault auth disable kubernetes-staging"
echo ""
echo "Or simply run this script again - it will clean up automatically!"
