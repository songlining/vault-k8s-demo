#!/bin/bash
# Manual Commands to Create Kubernetes Auth Methods
#
# Prerequisites:
# 1. Run the main script first to get a child token:
#    ./create-k8s-auth-policy.sh
# 2. Copy the CHILD_TOKEN from the output
# 3. Set it as an environment variable or use it directly in the commands below

# ============================================
# Step 1: Set your child token
# ============================================
# Replace with your actual child token from the script output
export CHILD_TOKEN="hvs.YOUR_TOKEN_HERE"

# OR get it programmatically:
# NAMESPACE="default"
# POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')
# CHILD_TOKEN=$(kubectl exec -it "$POD" -n "$NAMESPACE" -- vault token create -policy=k8s-auth-manager -ttl=1h -format=json | jq -r '.auth.client_token')

NAMESPACE="default"
POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

echo "Using POD: $POD"
echo "Using NAMESPACE: $NAMESPACE"
echo "Using CHILD_TOKEN: ${CHILD_TOKEN:0:20}..."
echo ""

# ============================================
# Step 2: List current auth methods
# ============================================
echo "=== Listing current auth methods ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth list
echo ""

# ============================================
# Step 3: Enable Kubernetes auth methods
# ============================================
echo "=== Creating kubernetes-dev auth method ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth enable -path=kubernetes-dev kubernetes
echo ""

echo "=== Creating kubernetes-prod auth method ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth enable -path=kubernetes-prod kubernetes
echo ""

echo "=== Creating kubernetes-staging auth method ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth enable -path=kubernetes-staging kubernetes
echo ""

# ============================================
# Step 4: Configure the auth methods
# ============================================
echo "=== Configuring kubernetes-dev ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-dev/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
echo ""

echo "=== Configuring kubernetes-prod ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-prod/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
echo ""

echo "=== Configuring kubernetes-staging ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-staging/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
echo ""

# ============================================
# Step 5: Create roles in the auth methods
# ============================================
echo "=== Creating dev-role in kubernetes-dev ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault write auth/kubernetes-dev/role/dev-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default \
    ttl=1h
echo ""

echo "=== Creating prod-role in kubernetes-prod ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault write auth/kubernetes-prod/role/prod-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default \
    ttl=1h
echo ""

echo "=== Creating staging-role in kubernetes-staging ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault write auth/kubernetes-staging/role/staging-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default \
    ttl=30m
echo ""

# ============================================
# Step 6: Verify the configuration
# ============================================
echo "=== Listing all auth methods ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth list
echo ""

echo "=== Listing roles in kubernetes-dev ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault list auth/kubernetes-dev/role
echo ""

echo "=== Reading dev-role configuration ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault read auth/kubernetes-dev/role/dev-role
echo ""

echo "=== Listing roles in kubernetes-prod ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault list auth/kubernetes-prod/role
echo ""

echo "=== Reading prod-role configuration ==="
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault read auth/kubernetes-prod/role/prod-role
echo ""

# ============================================
# Cleanup commands (run these when done)
# ============================================
echo "=========================================="
echo "To clean up, run these commands:"
echo "=========================================="
echo "kubectl exec $POD -n $NAMESPACE -- vault auth disable kubernetes-dev"
echo "kubectl exec $POD -n $NAMESPACE -- vault auth disable kubernetes-prod"
echo "kubectl exec $POD -n $NAMESPACE -- vault auth disable kubernetes-staging"
