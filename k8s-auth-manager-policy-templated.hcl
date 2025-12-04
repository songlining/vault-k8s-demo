# Policy: k8s-auth-manager-templated
# Purpose: Allow creation and management of Kubernetes auth methods using entity metadata
# This solves the problem of workspace isolation when multiple workspaces share a project prefix

# Enable/disable Kubernetes auth methods ONLY at the path specified in entity metadata
# The path is templated using {{identity.entity.metadata.workspace-name}}
# Example: If workspace-name=kubernetes-my_project_123, can only access sys/auth/kubernetes-my_project_123
path "sys/auth/{{identity.entity.metadata.workspace-name}}" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
}

# Full access to configure and manage ONLY the Kubernetes auth method at the templated path
# This includes: config, roles, and all sub-paths for the specific workspace
path "auth/{{identity.entity.metadata.workspace-name}}/*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}

# Read-only access to list all auth methods (for verification)
path "sys/auth" {
  capabilities = ["read"]
}

# Explicitly deny access to secrets
path "secret/*" {
  capabilities = ["deny"]
}

# Explicitly deny access to identity endpoints (prevent metadata tampering)
path "identity/*" {
  capabilities = ["deny"]
}
