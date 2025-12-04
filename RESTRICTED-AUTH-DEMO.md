# Restricted Kubernetes Auth Method Creation - Security Demo

## Overview

This demo shows how to use Vault's `allowed_parameters` and `denied_parameters` in policies to enforce fine-grained security controls when delegating Kubernetes auth method management.

## The Security Problem

When you give someone a token to manage Kubernetes auth methods, without proper restrictions they could:

1. **Create backdoor auth methods** pointing to clusters they control
2. **Assign high-privilege policies** (admin, root) to their roles
3. **Use wildcard bindings** (`*`) to accept any service account
4. **Bypass security validations** (disable issuer validation)
5. **Access production environments** when they should only have dev access

## The Solution: Defense-in-Depth Policy

The [k8s-auth-manager-restricted-policy.hcl](k8s-auth-manager-restricted-policy.hcl) demonstrates multiple security controls:

### 1. Path Restrictions
```hcl
# Only allow dev paths
path "sys/auth/kubernetes-dev-*" { ... }

# Explicitly deny production
path "sys/auth/kubernetes-prod-*" {
  capabilities = ["deny"]
}
```

### 2. Cluster Endpoint Whitelist
```hcl
path "auth/kubernetes-dev-*/config" {
  allowed_parameters = {
    "kubernetes_host" = [
      "https://dev-cluster-1.example.com:6443",
      "https://dev-cluster-2.example.com:6443"
    ]
  }
}
```
**Prevents**: Attacker pointing auth to their own cluster

### 3. Namespace Restrictions
```hcl
path "auth/kubernetes-dev-*/role/*" {
  allowed_parameters = {
    "bound_service_account_namespaces" = [
      "dev-team-a",
      "dev-team-b",
      "development"
    ]
  }
  denied_parameters = {
    "bound_service_account_namespaces" = ["*"]
  }
}
```
**Prevents**: Wildcard namespace bindings

### 4. Policy Assignment Restrictions
```hcl
path "auth/kubernetes-dev-*/role/*" {
  allowed_parameters = {
    "policies" = [
      "dev-read-only",
      "dev-app-secrets",
      "dev-database-creds"
    ]
  }
  denied_parameters = {
    "policies" = ["root", "admin", "k8s-auth-manager"]
  }
}
```
**Prevents**: Privilege escalation via policy assignment

### 5. Security Validation Enforcement
```hcl
path "auth/kubernetes-dev-*/config" {
  allowed_parameters = {
    "disable_iss_validation" = ["false"]
  }
  denied_parameters = {
    "disable_iss_validation" = ["true"]
  }
}
```
**Prevents**: Bypassing issuer validation

## Running the Demo

### Prerequisites

1. Vault server running and accessible
2. Vault CLI installed
3. Authenticated to Vault with sufficient privileges to create policies

### Execute the Demo

```bash
./demo-restricted-auth-scenario.sh
```

### What the Demo Does

The script performs **allowed operations** (these succeed):
- ✅ Creates auth method at `kubernetes-dev-team-a`
- ✅ Configures with whitelisted K8s host
- ✅ Creates role with allowed namespace and policy

Then tests **blocked operations** (these fail with permission denied):
- ❌ Create production auth method (`kubernetes-prod-*`)
- ❌ Configure unauthorized K8s cluster host
- ❌ Disable issuer validation (security bypass)
- ❌ Use wildcard service account bindings
- ❌ Assign admin/root policies
- ❌ Use unauthorized namespaces
- ❌ Create non-kubernetes auth types

## Expected Output

```
========================================
Vault Kubernetes Auth - Security Demo
========================================

[Step 1] Creating Vault policies...
✓ Created dev-read-only policy
✓ Created dev-app-secrets policy
✓ Created dev-database-creds policy
✓ Created admin policy (this should be blocked from assignment)
✓ Created k8s-auth-manager-restricted policy

[Step 2] Creating restricted management token...
✓ Token created: s.XYZ...

[Step 3] Testing ALLOWED operations...
✓ SUCCESS: Created kubernetes-dev-team-a auth method
✓ SUCCESS: Configured with allowed K8s host
✓ SUCCESS: Created role with allowed parameters

[Step 4] Testing BLOCKED operations...
✓ BLOCKED: Cannot create production auth method
✓ BLOCKED: Cannot use unauthorized K8s host
✓ BLOCKED: Cannot disable issuer validation
✓ BLOCKED: Cannot use wildcard service accounts
✓ BLOCKED: Cannot assign admin policy
✓ BLOCKED: Cannot assign root policy
✓ BLOCKED: Cannot use unauthorized namespace
✓ BLOCKED: Cannot create non-kubernetes auth types

========================================
Security Controls Summary
========================================
✓ Path restrictions enforced (dev-* only)
✓ Kubernetes host whitelist enforced
✓ Namespace restrictions enforced
✓ Policy assignment restrictions enforced
✓ Wildcard bindings blocked
✓ Security validation bypasses blocked
✓ Production paths completely denied
```

## Attack Scenarios Prevented

### Scenario 1: Backdoor Cluster Attack
**Without restrictions:**
```bash
# Attacker creates auth pointing to their cluster
vault auth enable -path=kubernetes-backdoor kubernetes
vault write auth/kubernetes-backdoor/config \
  kubernetes_host="https://attacker.evil.com:6443" \
  disable_iss_validation=true
```
**With restrictions:** ✅ BLOCKED by kubernetes_host whitelist and disable_iss_validation denial

### Scenario 2: Privilege Escalation via Policy
**Without restrictions:**
```bash
# Attacker assigns admin policy to their role
vault write auth/kubernetes-dev/role/pwned \
  bound_service_account_names="app" \
  bound_service_account_namespaces="dev" \
  policies="admin"
```
**With restrictions:** ✅ BLOCKED by policies allowed_parameters whitelist

### Scenario 3: Wildcard Binding Attack
**Without restrictions:**
```bash
# Attacker accepts any service account from any namespace
vault write auth/kubernetes-dev/role/open-door \
  bound_service_account_names="*" \
  bound_service_account_namespaces="*" \
  policies="dev-secrets"
```
**With restrictions:** ✅ BLOCKED by denied_parameters for wildcards

### Scenario 4: Production Environment Access
**Without restrictions:**
```bash
# Attacker creates production auth method
vault auth enable -path=kubernetes-prod-critical kubernetes
```
**With restrictions:** ✅ BLOCKED by explicit deny on kubernetes-prod-* paths

## Real-World Application

### Use Case: Multi-Tenant Platform

You're running a platform with multiple development teams:
- **Team A**: Works in `dev-team-a` namespace, needs access to their secrets
- **Team B**: Works in `dev-team-b` namespace, needs access to their database
- **Platform Team**: Manages Vault but wants to delegate K8s auth creation

**Solution:**
1. Create one restricted policy per team
2. Each policy allows only their namespace
3. Each policy allows only their required Vault policies
4. Each policy restricts to their assigned K8s cluster

```bash
# Team A gets their own restricted token
vault token create -policy=k8s-auth-manager-team-a -ttl=8h

# Team A can only:
# - Create auth at kubernetes-team-a-*
# - Bind to namespace "dev-team-a"
# - Assign policies "team-a-secrets", "team-a-db"
# - Point to dev-cluster-1.example.com
```

## Security Best Practices

1. **Principle of Least Privilege**: Only allow what's absolutely necessary
2. **Defense in Depth**: Use both `allowed_parameters` and `denied_parameters`
3. **Explicit Denials**: Use `capabilities = ["deny"]` for sensitive paths
4. **Whitelist Approach**: Prefer allowed lists over blocked lists
5. **Regular Audits**: Review who has these management tokens
6. **Short TTLs**: Use `-ttl=1h` or `-ttl=8h` for management tokens
7. **Audit Logging**: Enable Vault audit logs to track all operations

## Comparison: Original vs Enhanced vs Restricted

| Feature | Original | Enhanced | Restricted |
|---------|----------|----------|------------|
| Path wildcards | `kubernetes*` | `kubernetes*` | `kubernetes-dev-*` only |
| Parameter control | ❌ None | ✅ Whitelist | ✅ Whitelist + Blacklist |
| Cluster restriction | ❌ Any | ❌ Any | ✅ Specific hosts |
| Namespace restriction | ❌ Any | ❌ Any | ✅ Specific namespaces |
| Policy restriction | ❌ Any | ❌ Any | ✅ Specific policies |
| Production access | ⚠️ Allowed | ⚠️ Allowed | ✅ Explicitly denied |
| Wildcard blocking | ❌ Allowed | ❌ Allowed | ✅ Blocked |

## Cleanup

```bash
# Remove test auth method
vault auth disable kubernetes-dev-team-a

# Revoke test token
vault token revoke <token>

# Remove test policies
vault policy delete dev-read-only
vault policy delete dev-app-secrets
vault policy delete dev-database-creds
vault policy delete admin
vault policy delete k8s-auth-manager-restricted
```

## Additional Resources

- [Vault Policy Syntax](https://developer.hashicorp.com/vault/docs/concepts/policies)
- [Kubernetes Auth Method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Policy Parameters](https://developer.hashicorp.com/vault/docs/concepts/policies#parameter-constraints)

## License

This demo is provided as-is for educational purposes.
