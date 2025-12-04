# Implementation Summary: Entity-Based Policy for Workspace Isolation

## What Was Implemented

Based on the requirements in [entity-alias-policy.md](entity-alias-policy.md), I've updated the demo to use **entity-based templated policies** instead of simple child tokens with wildcard policies.

## Changes Made

### 1. Updated [create-k8s-auth-policy.sh](create-k8s-auth-policy.sh)

**Before**: Created a child token with wildcard policy `kubernetes-*`
**After**: Implements entity-based authentication with templated policies

The script now:
1. Sets up **userpass auth method** (mimicking Terraform workspace OIDC login)
2. Creates a **userpass user** (`workspace-tf-user`) representing a Terraform workspace
3. Creates an **Entity** with metadata: `workspace-name=kubernetes-my_project_123`
4. Creates an **EntityAlias** linking the userpass user to the entity
5. Applies a **templated policy** that uses `{{identity.entity.metadata.workspace-name}}`
6. Tests that the user can ONLY access `kubernetes-my_project_123`, not other paths

### 2. Updated [k8s-auth-manager-policy.hcl](k8s-auth-manager-policy.hcl)

**Before**:
```hcl
path "sys/auth/kubernetes-*" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
}

path "auth/kubernetes-*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}
```

**After**:
```hcl
path "sys/auth/{{identity.entity.metadata.workspace-name}}" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
}

path "auth/{{identity.entity.metadata.workspace-name}}/*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}

# Deny identity tampering
path "identity/*" {
  capabilities = ["deny"]
}
```

### 3. Additional Files Created

- **[k8s-auth-manager-policy-templated.hcl](k8s-auth-manager-policy-templated.hcl)**: Standalone templated policy file
- **[create-entity-based-policy.sh](create-entity-based-policy.sh)**: Alternative standalone script (kept for reference)
- **[ENTITY-POLICY-SOLUTION.md](ENTITY-POLICY-SOLUTION.md)**: Comprehensive documentation

### 4. Updated [README.md](README.md)

Added new section: **"Advanced: Entity-Based Templated Policies"** covering:
- Problem statement
- Solution explanation
- Key benefits
- How it solves the client's problem
- Available template variables
- Comparison table

## How It Solves the Client's Problem

### Client's Issue:
> "We have multiple environments for a project, wherein each creates a vault auth backend called `my-project-<randomstring>`. I can mostly restrict this to my workspace policies by allowing access to `sys/auth/my-project-*`, but this would also allow it to talk to the backends created by the other environment workspaces within this project."

### Solution:
Using entity metadata + policy templating:

1. **During OIDC login**: Store the full backend name in entity metadata
   ```
   workspace-name=my-project-abc123
   ```

2. **Use templated policy**: Paths are dynamically resolved using metadata
   ```hcl
   path "sys/auth/{{identity.entity.metadata.workspace-name}}" {
     capabilities = ["create", "update", "read", "delete", "sudo"]
   }
   ```

3. **Result**: True isolation
   - Workspace with `my-project-abc123` can ONLY manage that backend
   - **Cannot** access `my-project-xyz789` or `my-project-def456`
   - No code changes needed in Terraform configurations

## Running the Demo

### Prerequisites
- Vault server running and unsealed
- Root token or admin access
- kubectl access to cluster

### Steps

1. **Ensure Vault is initialized** (if not already):
   ```bash
   ./create_vault.sh
   ```

2. **Run the entity-based policy demo**:
   ```bash
   chmod +x create-entity-based-policy.sh
   ./create-entity-based-policy.sh
   ```

### Verified Test Results

**✅ Tests that SUCCEEDED** (as expected):
- ✅ List auth methods (read-only)
- ✅ Enable auth at `kubernetes-my_project_123` (matches metadata)
- ✅ Configure `kubernetes-my_project_123` auth method
- ✅ Create roles in `kubernetes-my_project_123`
- ✅ List roles in `kubernetes-my_project_123`

**❌ Tests that FAILED** (correctly denied - as expected):
- ❌ Enable auth at `kubernetes-other_project` (doesn't match metadata) - **Permission denied**
- ❌ Enable auth at `kubernetes-dev` (generic path, not allowed) - **Permission denied**
- ❌ Read secrets from `kv-v2/*` - **Permission denied**

**Status**: All tests passed successfully! ✅

## Key Security Features

1. **Metadata-Based Isolation**: Each workspace restricted to exact path in metadata
2. **Prevents Metadata Tampering**: `identity/*` paths are explicitly denied
3. **No Privilege Escalation**: Cannot access other workspaces or admin paths
4. **Audit Trail**: Entity metadata visible in all audit logs
5. **No Code Changes**: Works with existing naming conventions

## Production Implementation

For production use with Terraform Cloud/Enterprise OIDC:

1. **Configure OIDC claim mapping** to set entity metadata:
   ```hcl
   resource "vault_jwt_auth_backend_role" "terraform_workspace" {
     backend         = vault_auth_backend.oidc.path
     role_name       = "terraform-workspace"
     token_policies  = ["k8s-auth-manager"]

     user_claim      = "sub"
     allowed_redirect_uris = ["..."]

     # Map workspace ID to entity metadata
     claim_mappings = {
       workspace_id = "workspace_name"
     }
   }
   ```

2. **Ensure workspace ID includes full backend name**:
   ```
   workspace_id = "kubernetes-my_project_abc123"
   ```

3. **Metadata automatically set** during OIDC authentication

## Advantages Over Wildcard Approach

| Aspect | Wildcard (`my-project-*`) | Entity Metadata |
|--------|---------------------------|-----------------|
| **Isolation** | All workspaces can access each other | Each workspace fully isolated |
| **Security** | Broad access to prefix | Precise, least-privilege |
| **Code Changes** | None | None |
| **Management** | One policy for all | One policy, individualized |
| **Audit** | Hard to distinguish workspaces | Metadata in all logs |

## Files Modified/Created

- ✏️ Modified: `create-k8s-auth-policy.sh`
- ✏️ Modified: `k8s-auth-manager-policy.hcl`
- ✏️ Modified: `README.md`
- ➕ Created: `k8s-auth-manager-policy-templated.hcl`
- ➕ Created: `create-entity-based-policy.sh`
- ➕ Created: `ENTITY-POLICY-SOLUTION.md`
- ➕ Created: `IMPLEMENTATION-SUMMARY.md` (this file)

## Next Steps

1. Test the demo script in your environment
2. Review the templated policy for your specific needs
3. Configure OIDC claim mapping for production
4. Consider similar approach for `identity/groups` (mentioned in client email)
