# Policy: k8s-auth-manager-restricted
# Purpose: Demonstrate fine-grained control over which K8s service accounts can create auth methods
#          with specific parameter restrictions
#
# This policy shows:
# 1. Only specific service account namespaces can authenticate
# 2. Only allowed parameters can be set when creating auth methods
# 3. Restrictions on which policies can be assigned to roles
#
# Usage:
#   vault policy write k8s-auth-manager-restricted k8s-auth-manager-restricted-policy.hcl

# Allow creating/managing Kubernetes auth methods, but ONLY at specific paths
# This restricts which "tenant" or "team" paths can be created
path "sys/auth/kubernetes-dev-*" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
  allowed_parameters = {
    "type" = ["kubernetes"]
    "description" = []
    "local" = ["true"]  # Force local mounts only
    "seal_wrap" = ["false"]  # Disallow seal wrap
  }
  # Deny certain parameters explicitly
  denied_parameters = {
    "external_entropy_access" = ["true"]  # Block entropy access
  }
}

# Configure K8s auth - restrict to specific Kubernetes clusters by host
path "auth/kubernetes-dev-*/config" {
  capabilities = ["create", "update", "read"]
  allowed_parameters = {
    # Only allow specific K8s API endpoints (whitelist approach)
    "kubernetes_host" = [
      "https://dev-cluster-1.example.com:6443",
      "https://dev-cluster-2.example.com:6443"
    ]
    "kubernetes_ca_cert" = []
    "token_reviewer_jwt" = []
    "issuer" = ["https://kubernetes.default.svc.cluster.local"]
    "disable_iss_validation" = ["false"]  # Force issuer validation
    "disable_local_ca_jwt" = ["false"]
  }
  denied_parameters = {
    "disable_iss_validation" = ["true"]  # Explicitly deny bypassing validation
  }
}

# Create roles with restrictions on service account bindings
path "auth/kubernetes-dev-*/role/*" {
  capabilities = ["create", "update", "read", "delete", "list"]
  allowed_parameters = {
    # Only allow binding to specific namespaces (no wildcards allowed here)
    "bound_service_account_namespaces" = [
      "dev-team-a",
      "dev-team-b",
      "development"
    ]
    # Limit service account names (no wildcards)
    "bound_service_account_names" = []  # Empty means any specific name, but...

    # Restrict which policies can be assigned
    "policies" = [
      "dev-read-only",
      "dev-app-secrets",
      "dev-database-creds"
    ]

    # Token TTL restrictions
    "ttl" = []  # Allow any, but max_ttl will cap it
    "max_ttl" = []
    "token_ttl" = []
    "token_max_ttl" = []
    "period" = []
    "token_num_uses" = []
    "alias_name_source" = ["serviceaccount_uid", "serviceaccount_name"]
  }
  # Explicitly deny dangerous patterns
  denied_parameters = {
    "bound_service_account_names" = ["*"]  # No wildcards
    "bound_service_account_namespaces" = ["*"]  # No wildcards
    "policies" = [
      "root",
      "admin",
      "k8s-auth-manager",
      "k8s-auth-manager-restricted"
    ]
  }
}

# List and read operations (limited)
path "auth/kubernetes-dev-*" {
  capabilities = ["list", "read"]
}

# Read-only access to list auth methods
path "sys/auth" {
  capabilities = ["read"]
}

# EXPLICITLY DENY access to production paths
path "sys/auth/kubernetes-prod-*" {
  capabilities = ["deny"]
}

path "auth/kubernetes-prod-*" {
  capabilities = ["deny"]
}

# Note: This demonstrates defense-in-depth:
# - Path restrictions (only kubernetes-dev-*)
# - Parameter whitelisting (allowed_parameters)
# - Parameter blacklisting (denied_parameters)
# - Cluster endpoint restrictions
# - Namespace restrictions
# - Policy assignment restrictions
# - Explicit denials for sensitive paths
