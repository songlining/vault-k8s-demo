# Policy: k8s-auth-manager
# Purpose: Allow creation and management of Kubernetes auth methods with least privilege

# Enable/disable Kubernetes auth methods at paths matching 'kubernetes-*'
path "sys/auth/kubernetes-*" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
}

# Full access to configure and manage ALL Kubernetes auth methods
# This includes: config, roles, and all sub-paths
path "auth/kubernetes-*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}

# Read-only access to list all auth methods (for verification)
path "sys/auth" {
  capabilities = ["read"]
}