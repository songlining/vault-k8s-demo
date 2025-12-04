# Vault Kubernetes Demo - Least-Privileged Auth Management

This repository demonstrates security best practices for managing HashiCorp Vault Kubernetes authentication methods using least-privileged child tokens instead of root tokens.

## Overview

The `auth-test` branch contains scripts that show how to safely delegate Kubernetes auth method management without exposing root credentials. This follows the principle of least privilege by creating specialized tokens with minimal required permissions.

## Prerequisite

Tested on Docker Desktop on MacOS, using "kind" to manage the cluster.

## Test Scenario

**Goal**: Create and manage multiple Kubernetes auth methods at different paths using a least-privileged child token.

**What We're Testing**:
- Creating a restricted policy that can only manage Kubernetes auth methods
- Generating a child token with this policy (no root access)
- Using the child token to enable and configure multiple Kubernetes auth methods
- Verifying the policy correctly restricts access to other Vault paths

## Scripts

### `create-k8s-auth-policy.sh`
Main test script that demonstrates the complete workflow:

1. **Creates the `k8s-auth-manager` policy** with minimal required permissions:
   - Enable/disable Kubernetes auth methods at `kubernetes-*` paths
   - Configure and manage roles within those auth methods
   - Read-only access to list all auth methods
   - **Explicitly denies**: access to secrets, other auth methods, and admin paths

2. **Generates a child token** with only the `k8s-auth-manager` policy attached

3. **Tests the child token** by creating multiple Kubernetes auth methods:
   - `kubernetes-dev` - Development environment
   - `kubernetes-prod` - Production environment
   - `kubernetes-staging` - Staging environment

4. **Verifies policy restrictions** by attempting prohibited operations:
   - Reading secrets (should fail)
   - Enabling other auth types (should fail)
   - Accessing admin paths (should fail)

### `k8s-auth-manager-policy.hcl`
Policy definition file containing the least-privileged permissions:

```hcl
# Allow enabling/disabling kubernetes auth methods at kubernetes-* paths
path "sys/auth/kubernetes-*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

# Allow full configuration of kubernetes auth methods
path "auth/kubernetes-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Read-only access to list all auth methods
path "sys/auth" {
  capabilities = ["read"]
}

# Deny access to secrets and other sensitive paths
path "secret/*" {
  capabilities = ["deny"]
}
```

## Understanding the Three Path Layers

These three paths each control a different layer of the Kubernetes auth lifecycle. You need all of them if you want a role that can both create the auth method and fully manage it, while also being able to verify what exists.

### 1. `path "sys/auth/kubernetes-*"` – Manage the mount itself

- This path hits the **system auth-mount API**, which is where enabling, tuning, or disabling auth methods happens.
- Granting `create`, `update`, `read`, `delete`, `sudo` here lets the principal:
  - Enable a new Kubernetes auth method at paths like `auth/kubernetes-dev`, `auth/kubernetes-prod`, etc.
  - Tune or remove those mounts later.
- **Without this stanza**, they could not create a *new* Kubernetes auth backend; they could only configure one that already exists.

### 2. `path "auth/kubernetes-*"` – Manage everything under that auth mount

- This covers the **plugin's own endpoints** under the mount: `/config`, `/role/*`, `/login`, etc., for any mount whose path begins with `auth/kubernetes`.
- With `create`, `update`, `read`, `delete`, `list`, the principal can:
  - Configure how Vault talks to the Kubernetes API (`auth/kubernetes-foo/config`).
  - Create and update roles (`auth/kubernetes-foo/role/app`), and generally manage all Kubernetes auth-specific objects.
- **If you only had the `sys/auth/...` stanza**, you could enable the backend but not configure it or create roles; it would be unusable.

### 3. `path "sys/auth"` – Read-only view of all auth methods

- This is the **global listing of all auth mounts** in the cluster.
- `read` here allows:
  - Checking which auth methods are currently enabled and at what paths.
  - Verifying that the new Kubernetes auth method mounted correctly (e.g. appears as `kubernetes-dev/`, `kubernetes-prod/`, etc.).
- It does not grant any ability to change auth methods; it is purely for **observability/verification**.

**In short**: `sys/auth/kubernetes-*` lets you create/tune the Kubernetes auth mount, `auth/kubernetes-*` lets you configure and manage that mount's internals, and `sys/auth` lets you see the overall auth layout so you can confirm what you've created.

## Running the Test

### Prerequisites
- Vault server installed and unsealed
- Root token or sufficient permissions to create policies and tokens
- `kubectl` access to Kubernetes cluster (for auth method configuration)

### Execute
```bash
chmod +x create-k8s-auth-policy.sh
./create-k8s-auth-policy.sh
```

## Expected Results

**✅ Should Succeed**:
- Policy creation
- Child token generation
- Enabling kubernetes-dev, kubernetes-prod, kubernetes-staging auth methods
- Configuring each auth method with Kubernetes API details
- Creating and managing roles within each auth method

**❌ Should Fail (Verifying Restrictions)**:
- Reading secrets from `secret/` path
- Enabling non-Kubernetes auth methods (e.g., `userpass`)
- Accessing administrative paths
- Managing auth methods not matching `kubernetes-*` pattern

## Why This Matters

**Security Best Practice**: Instead of distributing root tokens to teams or automation, you can create specialized child tokens with just enough permissions to perform specific tasks. This minimizes the blast radius if a token is compromised.

**Real-World Use Case**: A platform team can safely delegate the ability to configure Kubernetes auth methods for different environments (dev/staging/prod) to application teams without giving them access to secrets or other sensitive Vault operations.

---

## Advanced: Entity-Based Templated Policies

### Problem Statement

The basic wildcard approach (`kubernetes-*`) has a limitation: **multiple workspaces within the same project can access each other's auth backends**.

For example, if you have:
- `my-project-abc123` (dev environment)
- `my-project-xyz789` (staging environment)
- `my-project-def456` (prod environment)

A policy with `sys/auth/my-project-*` would allow any workspace to manage **all three** backends, not just their own.

### Solution: Entity Metadata + Templated Policies

Vault supports **policy templating** using entity metadata. This allows you to create policies where the allowed paths are dynamically determined based on the authenticated user's entity metadata.

### `create-entity-based-policy.sh`

This script demonstrates workspace isolation using entity metadata:

1. **Sets up userpass auth** (mimicking Terraform workspace OIDC login)
2. **Creates an Entity** with metadata: `workspace-name=kubernetes-my_project_123`
3. **Creates an EntityAlias** linking the userpass user to the entity
4. **Applies a templated policy** using `{{identity.entity.metadata.workspace-name}}`
5. **Tests isolation** - the user can ONLY access `kubernetes-my_project_123`, not other paths

**Note**: This script also updates `create-k8s-auth-policy.sh` which now uses the same entity-based approach.

### `k8s-auth-manager-policy-templated.hcl`

Templated policy that uses entity metadata for precise access control:

```hcl
# Enable/disable auth method ONLY at the workspace-specific path
path "sys/auth/{{identity.entity.metadata.workspace-name}}" {
  capabilities = ["create", "update", "read", "delete", "sudo"]
}

# Manage ONLY the workspace-specific auth method
path "auth/{{identity.entity.metadata.workspace-name}}/*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}

# Read-only access to list all auth methods
path "sys/auth" {
  capabilities = ["read"]
}

# Deny access to secrets and identity tampering
path "secret/*" {
  capabilities = ["deny"]
}

path "identity/*" {
  capabilities = ["deny"]
}
```

### Running the Entity-Based Demo

**Prerequisites**: Vault must be initialized with root token access.

```bash
# First, ensure Vault is set up (if not already)
./create_vault.sh

# Then run the entity-based policy demo
chmod +x create-entity-based-policy.sh
./create-entity-based-policy.sh
```

**Verified Test Results** (all tests passed):
- ✅ List auth methods (read-only access)
- ✅ Enable/configure/manage `kubernetes-my_project_123` (own workspace)
- ✅ Create roles in own workspace
- ❌ **Correctly denied**: Access to `kubernetes-other_project` (other workspace)
- ❌ **Correctly denied**: Access to `kubernetes-dev` (generic path)
- ❌ **Correctly denied**: Read secrets
- ❌ **Correctly denied**: Modify entity metadata

### Key Benefits

**✅ True Workspace Isolation**:
- Each workspace can ONLY manage its specific auth backend
- Workspace with `workspace-name=my-project-abc123` cannot access `my-project-xyz789`
- No risk of cross-workspace interference

**✅ No Code Changes Required**:
- Works with existing backend naming conventions
- Simply store the full backend name in entity metadata
- Policy template handles the rest

**✅ Additional Security**:
- Prevents metadata tampering (identity paths are denied)
- Follows principle of least privilege
- Easy to audit (metadata is visible in entity)

### How This Solves the Client's Problem

The client had projects with backends named `my-project-<randomstring>`, where multiple environments share the same prefix. Using entity-based templating:

1. **During OIDC login**: Store the full backend name in entity metadata
   - Example: `workspace-name=my-project-abc123`

2. **Apply templated policy**: User can only access paths matching their metadata
   - Can manage: `sys/auth/my-project-abc123`
   - Cannot manage: `sys/auth/my-project-xyz789` or `sys/auth/my-project-*`

3. **Result**: True isolation without code changes across projects

### Template Variables Available

Vault provides several template variables you can use in policies:

- `{{identity.entity.id}}` - Entity ID
- `{{identity.entity.name}}` - Entity name
- `{{identity.entity.metadata.KEY}}` - Custom metadata (like `workspace-name`)
- `{{identity.entity.aliases.AUTH_MOUNT.name}}` - Alias name for specific auth mount

### Comparison: Wildcard vs Entity-Based

| Approach | Access Pattern | Use Case |
|----------|---------------|----------|
| **Wildcard** (`kubernetes-*`) | All backends matching pattern | Team manages multiple environments (dev/staging/prod) |
| **Entity-Based** (metadata template) | Single specific backend | Individual workspace needs isolated access |

Both approaches are valid - choose based on your security and operational requirements.