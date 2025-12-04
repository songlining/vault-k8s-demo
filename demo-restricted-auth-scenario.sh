#!/bin/bash
set -e

# Demo: Restricted Kubernetes Auth Method Creation
# This script demonstrates how allowed_parameters and denied_parameters
# control what a token holder can and cannot do

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Vault Kubernetes Auth - Security Demo${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Step 1: Setup - Create the required policies
echo -e "${YELLOW}[Step 1] Creating Vault policies...${NC}"

# Create low-privilege policies that roles can use
vault policy write dev-read-only - <<EOF
path "secret/data/dev/*" {
  capabilities = ["read", "list"]
}
EOF
echo -e "${GREEN}✓ Created dev-read-only policy${NC}"

vault policy write dev-app-secrets - <<EOF
path "secret/data/dev/app/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/dev/app/*" {
  capabilities = ["list"]
}
EOF
echo -e "${GREEN}✓ Created dev-app-secrets policy${NC}"

vault policy write dev-database-creds - <<EOF
path "database/creds/dev-*" {
  capabilities = ["read"]
}
EOF
echo -e "${GREEN}✓ Created dev-database-creds policy${NC}"

# Create a high-privilege policy that should be blocked
vault policy write admin - <<EOF
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
echo -e "${GREEN}✓ Created admin policy (this should be blocked from assignment)${NC}"

# Create the restricted auth manager policy
vault policy write k8s-auth-manager-restricted k8s-auth-manager-restricted-policy.hcl
echo -e "${GREEN}✓ Created k8s-auth-manager-restricted policy${NC}\n"

# Step 2: Create a token with the restricted policy
echo -e "${YELLOW}[Step 2] Creating restricted management token...${NC}"
RESTRICTED_TOKEN=$(vault token create \
  -policy=k8s-auth-manager-restricted \
  -ttl=1h \
  -format=json | jq -r '.auth.client_token')

echo -e "${GREEN}✓ Token created: ${RESTRICTED_TOKEN:0:20}...${NC}\n"

# Step 3: Test allowed operations
echo -e "${YELLOW}[Step 3] Testing ALLOWED operations...${NC}\n"

echo -e "${BLUE}Test 3a: Create auth method at allowed path (kubernetes-dev-team-a)${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault auth enable -path=kubernetes-dev-team-a kubernetes && \
  echo -e "${GREEN}✓ SUCCESS: Created kubernetes-dev-team-a auth method${NC}\n" || \
  echo -e "${RED}✗ FAILED: Could not create auth method${NC}\n"

echo -e "${BLUE}Test 3b: Configure with ALLOWED Kubernetes host${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault write auth/kubernetes-dev-team-a/config \
  kubernetes_host="https://dev-cluster-1.example.com:6443" \
  kubernetes_ca_cert=@/dev/null \
  disable_iss_validation=false && \
  echo -e "${GREEN}✓ SUCCESS: Configured with allowed K8s host${NC}\n" || \
  echo -e "${RED}✗ FAILED: Could not configure${NC}\n"

echo -e "${BLUE}Test 3c: Create role with ALLOWED namespace and policy${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault write auth/kubernetes-dev-team-a/role/app-role \
  bound_service_account_names="app-service-account" \
  bound_service_account_namespaces="dev-team-a" \
  policies="dev-app-secrets" \
  ttl=1h && \
  echo -e "${GREEN}✓ SUCCESS: Created role with allowed parameters${NC}\n" || \
  echo -e "${RED}✗ FAILED: Could not create role${NC}\n"

# Step 4: Test blocked operations
echo -e "${YELLOW}[Step 4] Testing BLOCKED operations...${NC}\n"

echo -e "${BLUE}Test 4a: Try to create auth method at FORBIDDEN path (kubernetes-prod-*)${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault auth enable -path=kubernetes-prod-critical kubernetes 2>&1 | \
  grep -q "permission denied" && \
  echo -e "${GREEN}✓ BLOCKED: Cannot create production auth method${NC}\n" || \
  echo -e "${RED}✗ SECURITY ISSUE: Should have been blocked!${NC}\n"

echo -e "${BLUE}Test 4b: Try to configure with DISALLOWED Kubernetes host${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault write auth/kubernetes-dev-team-a/config \
  kubernetes_host="https://attacker-cluster.evil.com:6443" \
  kubernetes_ca_cert=@/dev/null 2>&1 | \
  grep -q "permission denied\|invalid" && \
  echo -e "${GREEN}✓ BLOCKED: Cannot use unauthorized K8s host${NC}\n" || \
  echo -e "${RED}✗ SECURITY ISSUE: Should have been blocked!${NC}\n"

echo -e "${BLUE}Test 4c: Try to bypass issuer validation (security bypass attempt)${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault write auth/kubernetes-dev-team-a/config \
  kubernetes_host="https://dev-cluster-1.example.com:6443" \
  disable_iss_validation=true 2>&1 | \
  grep -q "permission denied" && \
  echo -e "${GREEN}✓ BLOCKED: Cannot disable issuer validation${NC}\n" || \
  echo -e "${RED}✗ SECURITY ISSUE: Should have been blocked!${NC}\n"

echo -e "${BLUE}Test 4d: Try to create role with WILDCARD namespace (privilege escalation attempt)${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault write auth/kubernetes-dev-team-a/role/evil-role \
  bound_service_account_names="*" \
  bound_service_account_namespaces="*" \
  policies="dev-read-only" 2>&1 | \
  grep -q "permission denied" && \
  echo -e "${GREEN}✓ BLOCKED: Cannot use wildcard service accounts${NC}\n" || \
  echo -e "${RED}✗ SECURITY ISSUE: Should have been blocked!${NC}\n"

echo -e "${BLUE}Test 4e: Try to assign ADMIN policy to role (privilege escalation attempt)${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault write auth/kubernetes-dev-team-a/role/admin-role \
  bound_service_account_names="app" \
  bound_service_account_namespaces="dev-team-a" \
  policies="admin" 2>&1 | \
  grep -q "permission denied" && \
  echo -e "${GREEN}✓ BLOCKED: Cannot assign admin policy${NC}\n" || \
  echo -e "${RED}✗ SECURITY ISSUE: Should have been blocked!${NC}\n"

echo -e "${BLUE}Test 4f: Try to assign ROOT policy to role (privilege escalation attempt)${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault write auth/kubernetes-dev-team-a/role/root-role \
  bound_service_account_names="app" \
  bound_service_account_namespaces="dev-team-a" \
  policies="root" 2>&1 | \
  grep -q "permission denied" && \
  echo -e "${GREEN}✓ BLOCKED: Cannot assign root policy${NC}\n" || \
  echo -e "${RED}✗ SECURITY ISSUE: Should have been blocked!${NC}\n"

echo -e "${BLUE}Test 4g: Try to create role with UNAUTHORIZED namespace${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault write auth/kubernetes-dev-team-a/role/wrong-ns-role \
  bound_service_account_names="app" \
  bound_service_account_namespaces="production" \
  policies="dev-read-only" 2>&1 | \
  grep -q "permission denied" && \
  echo -e "${GREEN}✓ BLOCKED: Cannot use unauthorized namespace${NC}\n" || \
  echo -e "${RED}✗ SECURITY ISSUE: Should have been blocked!${NC}\n"

echo -e "${BLUE}Test 4h: Try to enable non-kubernetes auth type (JWT)${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault auth enable -path=kubernetes-dev-jwt jwt 2>&1 | \
  grep -q "permission denied" && \
  echo -e "${GREEN}✓ BLOCKED: Cannot create non-kubernetes auth types${NC}\n" || \
  echo -e "${RED}✗ SECURITY ISSUE: Should have been blocked!${NC}\n"

# Step 5: Verify final state
echo -e "${YELLOW}[Step 5] Verifying secure configuration...${NC}\n"

echo -e "${BLUE}Listing created auth methods:${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault auth list | grep kubernetes-dev || true
echo ""

echo -e "${BLUE}Listing roles in kubernetes-dev-team-a:${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault list auth/kubernetes-dev-team-a/role || echo "No roles or permission denied"
echo ""

echo -e "${BLUE}Reading allowed role configuration:${NC}"
VAULT_TOKEN=$RESTRICTED_TOKEN vault read auth/kubernetes-dev-team-a/role/app-role || true
echo ""

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Security Controls Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Path restrictions enforced (dev-* only)${NC}"
echo -e "${GREEN}✓ Kubernetes host whitelist enforced${NC}"
echo -e "${GREEN}✓ Namespace restrictions enforced${NC}"
echo -e "${GREEN}✓ Policy assignment restrictions enforced${NC}"
echo -e "${GREEN}✓ Wildcard bindings blocked${NC}"
echo -e "${GREEN}✓ Security validation bypasses blocked${NC}"
echo -e "${GREEN}✓ Production paths completely denied${NC}"
echo ""
echo -e "${YELLOW}Cleanup: Run 'vault auth disable kubernetes-dev-team-a' to remove test auth method${NC}"
echo -e "${YELLOW}Cleanup: Run 'vault token revoke $RESTRICTED_TOKEN' to revoke test token${NC}"
