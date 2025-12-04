# Policy: k8s-auth-manager
# Purpose: Least privilege policy to allow a child token to create and manage Kubernetes auth methods
#
# Usage:
#   vault policy write k8s-auth-manager k8s-auth-manager-policy.hcl
#   vault token create -policy=k8s-auth-manager -ttl=1h

# Enable/disable Kubernetes auth methods at paths matching 'kubernetes-*'
# Allows: vault auth enable -path=kubernetes-new kubernetes
# Allows: vault auth disable kubernetes-new
path "sys/auth/kubernetes-*" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
}

# Full access to configure and manage ALL Kubernetes auth methods
# This includes: config, roles, and all sub-paths
# Note: The pattern "auth/kubernetes*" matches "auth/kubernetes-new", etc.
path "auth/kubernetes-*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}

# Read-only access to list all auth methods (for verification)
# Allows: vault auth list
path "sys/auth" {
  capabilities = ["read"]
}

# Note: This policy explicitly does NOT grant:
# - Access to secrets (kv-v2/*, secret/*, etc.)
# - Ability to create other types of auth methods (AppRole, LDAP, JWT, etc.)
# - Ability to modify policies or other administrative paths
# - Root or admin capabilities
# - Access to sys/policies or other sys/* administrative paths (except sys/auth)
