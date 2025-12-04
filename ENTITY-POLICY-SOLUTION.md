# Entity-Based Policy Solution for Workspace Isolation

## Client's Problem

The client has multiple Terraform workspaces for different environments within the same project:
- Each workspace creates a Vault auth backend: `my-project-<randomstring>`
- Example: `my-project-abc123`, `my-project-xyz789`, `my-project-def456`

**Issue**: Using a wildcard policy like `sys/auth/my-project-*` allows any workspace to access **all** backends with that prefix, not just their own.

**Client's Question**:
> "Is there a way to see what parameters are available on these actions that I can use to potentially further lock down those rules in future? If I could see what other parameters are available to play with, I might be able to find a solution that wouldn't necessitate code changes across the board."

## Solution: Vault Entity Metadata + Policy Templating

Vault supports **templated policies** that can use entity metadata to dynamically restrict access paths. This allows each workspace to only access its specific auth backend.

## How It Works

### 1. Store Backend Name in Entity Metadata

When a Terraform workspace authenticates via OIDC:
- Create or update the entity with metadata
- Store the full backend name: `workspace-name=my-project-abc123`

### 2. Use Templated Policies

Create a policy that templates the path using the metadata:

```hcl
# User can ONLY access the auth backend specified in their entity metadata
path "sys/auth/{{identity.entity.metadata.workspace-name}}" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
}

path "auth/{{identity.entity.metadata.workspace-name}}/*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}
```

### 3. Result: True Isolation

- Workspace with `workspace-name=my-project-abc123` can ONLY manage `my-project-abc123`
- **Cannot** access `my-project-xyz789` or any other backend
- No code changes needed in Terraform configurations
- No changes to backend naming conventions

## Implementation Steps

### Step 1: Enable Identity Management

Ensure your Vault setup has the identity secrets engine enabled (enabled by default).

### Step 2: Configure OIDC to Set Entity Metadata

When configuring your OIDC auth method, set up entity aliases with metadata:

```bash
# Example: When a workspace authenticates, set entity metadata
vault write identity/entity name="workspace-my-project-abc123" \
  metadata=workspace-name=my-project-abc123
```

Or use Terraform to manage this:

```hcl
resource "vault_identity_entity" "workspace" {
  name = "workspace-${var.workspace_id}"

  metadata = {
    workspace-name = "my-project-${var.random_suffix}"
  }
}
```

### Step 3: Create Templated Policy

```bash
vault policy write k8s-auth-manager-templated - <<EOF
path "sys/auth/{{identity.entity.metadata.workspace-name}}" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
}

path "auth/{{identity.entity.metadata.workspace-name}}/*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "identity/*" {
  capabilities = ["deny"]
}
EOF
```

### Step 4: Attach Policy to Entity

```bash
vault write identity/entity/id/<ENTITY_ID> \
  policies=k8s-auth-manager-templated
```

## Demo Script

The repository includes `create-entity-based-policy.sh` which demonstrates:

1. Setting up a userpass auth method (mimicking OIDC)
2. Creating an entity with `workspace-name` metadata
3. Creating an entity alias linking the user to the entity
4. Applying the templated policy
5. Testing that the user can ONLY access their specific backend

**Run the demo**:
```bash
chmod +x create-entity-based-policy.sh
./create-entity-based-policy.sh
```

### Verified Test Results ✅

The script has been successfully tested with all tests passing:

**✅ Tests that SUCCEEDED** (as expected):
- ✅ List auth methods (read-only access)
- ✅ Enable auth at `kubernetes-my_project_123` (matches entity metadata)
- ✅ Configure `kubernetes-my_project_123` auth method
- ✅ Create and manage roles in `kubernetes-my_project_123`
- ✅ List roles in the workspace-specific auth method

**❌ Tests that FAILED** (correctly denied - as expected):
- ❌ Enable auth at `kubernetes-other_project` - **Permission denied** ✓
- ❌ Enable auth at `kubernetes-dev` - **Permission denied** ✓
- ❌ Read secrets from `kv-v2/` path - **Permission denied** ✓

**Conclusion**: Entity-based templated policies successfully provide true workspace isolation!

## Available Template Variables

Vault provides these template variables for policies:

| Variable | Description | Example |
|----------|-------------|---------|
| `{{identity.entity.id}}` | Entity UUID | `a1b2c3d4-...` |
| `{{identity.entity.name}}` | Entity name | `workspace-abc123` |
| `{{identity.entity.metadata.KEY}}` | Custom metadata | `my-project-abc123` |
| `{{identity.entity.aliases.MOUNT.name}}` | Alias name for auth mount | `user@example.com` |
| `{{identity.entity.aliases.MOUNT.metadata.KEY}}` | Alias metadata | Custom alias data |

## Additional Use Cases

### 1. Identity Group Management

The client also asked about locking down `identity/groups`. You can use similar templating:

```hcl
# Allow managing ONLY groups with a specific prefix based on metadata
path "identity/group/name/{{identity.entity.metadata.workspace-name}}-*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}
```

### 2. Multi-Tenant Secrets

```hcl
# Each tenant can only access their own secret path
path "secret/data/{{identity.entity.metadata.tenant-id}}/*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}
```

### 3. Dynamic Database Credentials

```hcl
# Each app can only get credentials for its own database role
path "database/creds/{{identity.entity.metadata.app-name}}-*" {
  capabilities = ["read"]
}
```

## Security Considerations

### ✅ Prevent Metadata Tampering

Always deny access to identity paths in workspace policies:

```hcl
path "identity/*" {
  capabilities = ["deny"]
}
```

This prevents users from changing their own metadata to access other workspaces.

### ✅ Set Metadata at Authentication Time

- Metadata should be set by the authentication system (OIDC, LDAP, etc.)
- Do not allow users to set their own metadata
- Use claims mapping in OIDC to automatically populate metadata

### ✅ Audit Entity Changes

Enable audit logging to track:
- Entity creation and updates
- Metadata changes
- Policy attachments

## Advantages Over Wildcards

| Aspect | Wildcard (`my-project-*`) | Entity Metadata Template |
|--------|---------------------------|--------------------------|
| **Isolation** | All workspaces in project can access each other | Each workspace isolated to its specific backend |
| **Security** | Broader access | Precise, least-privilege access |
| **Code Changes** | None needed | None needed |
| **Management** | Single policy for all workspaces | Single policy, individualized via metadata |
| **Audit** | Can't distinguish workspace in logs | Entity metadata visible in audit logs |
| **Flexibility** | Fixed prefix pattern | Any metadata-based pattern |

## Recommendation

For the client's use case:

1. **Implement entity metadata approach** for workspace-level isolation
2. **Store full backend name** in `workspace-name` metadata during OIDC login
3. **Use templated policies** to restrict each workspace to its specific backend
4. **No code changes required** in existing Terraform configurations

This provides the "parameters available to play with" the client asked about, solving the isolation problem without requiring code changes across all projects.

## Next Steps

1. Test the demo script to understand the behavior
2. Configure OIDC claim mapping to set entity metadata automatically
3. Create the templated policy in production
4. Gradually migrate workspaces to use entity-based policies
5. Consider similar templating for `identity/groups` and other paths

## References

- [Vault Policy Templating](https://developer.hashicorp.com/vault/docs/concepts/policies#templated-policies)
- [Vault Identity Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/identity)
- [OIDC Auth Method](https://developer.hashicorp.com/vault/docs/auth/jwt)
