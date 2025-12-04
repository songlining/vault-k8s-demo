# Policy: k8s-auth-manager
# Purpose: Least privilege policy to allow a child token to create and manage Kubernetes auth methods
#
# Usage:
#   vault policy write k8s-auth-manager k8s-auth-manager-policy-enhanced.hcl
#   vault token create -policy=k8s-auth-manager -ttl=1h

# Enable/disable Kubernetes auth methods at paths matching 'kubernetes-*'
# Allows: vault auth enable -path=kubernetes-new kubernetes
# Allows: vault auth disable kubernetes-new
# Restricted to only kubernetes type
path "sys/auth/kubernetes-*" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
  allowed_parameters = {
    "type" = ["kubernetes"]
    "description" = []
    "config" = []
    "local" = ["true", "false"]
    "seal_wrap" = ["true", "false"]
    "external_entropy_access" = ["true", "false"]
  }
}

# Full access to configure and manage Kubernetes auth methods
# Restricted to only allow specific configuration parameters
path "auth/kubernetes-*/config" {
  capabilities = ["create", "update", "read", "delete"]
  allowed_parameters = {
    "kubernetes_host" = []
    "kubernetes_ca_cert" = []
    "token_reviewer_jwt" = []
    "pem_keys" = []
    "issuer" = []
    "disable_iss_validation" = ["true", "false"]
    "disable_local_ca_jwt" = ["true", "false"]
  }
}

# Full access to create and manage Kubernetes roles
# Restricted to only allow specific role parameters
path "auth/kubernetes-*/role/*" {
  capabilities = ["create", "update", "read", "delete", "list"]
  allowed_parameters = {
    "bound_service_account_names" = []
    "bound_service_account_namespaces" = []
    "ttl" = []
    "max_ttl" = []
    "period" = []
    "policies" = []
    "alias_name_source" = ["serviceaccount_namespace", "serviceaccount_name"]
    "token_num_uses" = []
    "token_ttl" = []
    "token_max_ttl" = []
  }
}

# List roles and configuration (read-only)
path "auth/kubernetes-*" {
  capabilities = ["list", "read"]
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
# - Setting arbitrary parameters through allowed_parameters restrictions
