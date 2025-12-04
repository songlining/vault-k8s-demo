# Manual Commands to Create Kubernetes Auth Methods

## Prerequisites

First, create the policy and get a child token by running the main script:

```bash
./create-k8s-auth-policy.sh
```

Copy the `CHILD_TOKEN` from the output, then use it in the commands below.

## Setup Variables

```bash
# Set your variables
export CHILD_TOKEN="hvs.YOUR_TOKEN_HERE"  # Replace with actual token
export NAMESPACE="default"
export POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

echo "POD: $POD"
echo "CHILD_TOKEN: ${CHILD_TOKEN:0:20}..."
```

## 1. List Current Auth Methods

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth list
```

## 2. Enable Kubernetes Auth Methods

### Create kubernetes-dev

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth enable -path=kubernetes-dev kubernetes
```

### Create kubernetes-prod

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth enable -path=kubernetes-prod kubernetes
```

### Create kubernetes-staging

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth enable -path=kubernetes-staging kubernetes
```

## 3. Configure the Auth Methods

### Configure kubernetes-dev

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-dev/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
```

### Configure kubernetes-prod

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-prod/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
```

### Configure kubernetes-staging

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c \
  'vault write auth/kubernetes-staging/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
```

## 4. Create Roles

### Create dev-role in kubernetes-dev

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault write auth/kubernetes-dev/role/dev-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default \
    ttl=1h
```

### Create prod-role in kubernetes-prod

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault write auth/kubernetes-prod/role/prod-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default \
    ttl=1h
```

### Create staging-role in kubernetes-staging

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault write auth/kubernetes-staging/role/staging-role \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default \
    ttl=30m
```

## 5. Verify Configuration

### List all auth methods

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth list
```

### List roles in kubernetes-dev

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault list auth/kubernetes-dev/role
```

### Read dev-role details

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault read auth/kubernetes-dev/role/dev-role
```

### List roles in kubernetes-prod

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault list auth/kubernetes-prod/role
```

### Read prod-role details

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault read auth/kubernetes-prod/role/prod-role
```

### Read kubernetes-dev config

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault read auth/kubernetes-dev/config
```

## 6. Test Denied Operations

These commands should FAIL with "permission denied":

### Try to read secrets (should fail)

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault kv get kv-v2/vault-demo/mysecret
```

### Try to enable AppRole auth (should fail)

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault auth enable approle
```

### Try to create policy (should fail)

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" \
  vault policy write test-policy -
```

## 7. Cleanup

When you're done testing, remove the auth methods:

```bash
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-dev
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-prod
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-staging
```

Or simply run the main script again - it will auto-cleanup:

```bash
./create-k8s-auth-policy.sh
```

## Quick Copy-Paste Commands

Here are all the commands in one block for easy copy-paste:

```bash
# Setup
export CHILD_TOKEN="hvs.YOUR_TOKEN_HERE"
export NAMESPACE="default"
export POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

# Enable auth methods
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth enable -path=kubernetes-dev kubernetes
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth enable -path=kubernetes-prod kubernetes
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth enable -path=kubernetes-staging kubernetes

# Configure auth methods
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c 'vault write auth/kubernetes-dev/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c 'vault write auth/kubernetes-prod/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" /bin/sh -c 'vault write auth/kubernetes-staging/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'

# Create roles
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault write auth/kubernetes-dev/role/dev-role bound_service_account_names=default bound_service_account_namespaces=default policies=default ttl=1h
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault write auth/kubernetes-prod/role/prod-role bound_service_account_names=default bound_service_account_namespaces=default policies=default ttl=1h
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault write auth/kubernetes-staging/role/staging-role bound_service_account_names=default bound_service_account_namespaces=default policies=default ttl=30m

# Verify
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault auth list
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault list auth/kubernetes-dev/role
kubectl exec "$POD" -n "$NAMESPACE" -- env VAULT_TOKEN="$CHILD_TOKEN" vault read auth/kubernetes-dev/role/dev-role

# Cleanup when done
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-dev
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-prod
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth disable kubernetes-staging
```

## Alternative: Using vault login

Instead of passing `VAULT_TOKEN` with each command, you can login once:

```bash
# Login with the child token
kubectl exec -it "$POD" -n "$NAMESPACE" -- vault login "$CHILD_TOKEN"

# Now run commands without env VAULT_TOKEN=
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth enable -path=kubernetes-dev kubernetes
kubectl exec "$POD" -n "$NAMESPACE" -- vault auth list
# etc...
```

**Note:** The `vault login` approach changes the token for the entire Vault CLI session in that pod, so use it carefully.

---

## Working Inside the Vault Container

Instead of running `kubectl exec` for every command, you can bash directly into the Vault pod and work interactively.

### Get Shell Access to Vault Pod

```bash
# Simple access (most common)
kubectl exec -it vault-0 -n default -- /bin/sh

# Or using variables
NAMESPACE="default"
POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$POD" -n "$NAMESPACE" -- /bin/sh
```

**Note:** Vault containers use `/bin/sh` (not `/bin/bash`) since they're based on Alpine Linux.

### Understanding the `--` Separator

The `--` in kubectl commands is a **command separator** that tells kubectl:
> "Everything after this point is the command to run inside the container, NOT kubectl options"

**Examples:**

```bash
# CORRECT - -- separates kubectl flags from container command flags
kubectl exec vault-0 -- vault auth list --detailed

# WRONG - kubectl will try to parse --detailed as its own flag
kubectl exec vault-0 vault auth list --detailed  # ❌ Error!

# Interactive shell
kubectl exec -it vault-0 -- /bin/sh
│              │         │  │
│              │         │  └─ Command to run INSIDE pod
│              │         └─ Separator
│              └─ kubectl options
└─ kubectl command
```

**Best Practice:** Always use `--` even when optional - it makes commands clearer.

### Setup Environment Inside the Pod

Once you're inside the Vault container, set up your environment:

```bash
# 1. Check if VAULT_ADDR is already set (usually it is)
echo $VAULT_ADDR

# 2. If not set, configure it
export VAULT_ADDR='http://127.0.0.1:8200'

# 3. Set your child token
export VAULT_TOKEN='hvs.YOUR_CHILD_TOKEN_HERE'

# 4. Verify connection
vault status

# 5. Check your complete Vault environment
echo "VAULT_ADDR: $VAULT_ADDR"
echo "VAULT_TOKEN: ${VAULT_TOKEN:0:20}..."
vault token lookup
```

### Running Commands Inside the Pod

Now you can run Vault commands directly without `kubectl exec`:

```bash
# List auth methods
vault auth list

# Enable an auth method
vault auth enable -path=kubernetes-dev kubernetes

# Configure it (environment variables are available)
vault write auth/kubernetes-dev/config \
  kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT

# Create a role
vault write auth/kubernetes-dev/role/dev-role \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=default \
  ttl=1h

# List roles
vault list auth/kubernetes-dev/role

# Read role details
vault read auth/kubernetes-dev/role/dev-role

# Exit the pod when done
exit
```

### Complete Workflow Inside Pod

```bash
# Step 1: Get into the pod
kubectl exec -it vault-0 -n default -- /bin/sh

# Step 2: Setup environment (inside pod now)
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='hvs.YOUR_CHILD_TOKEN_HERE'

# Step 3: Verify
vault status
vault auth list

# Step 4: Create auth methods
vault auth enable -path=kubernetes-dev kubernetes
vault auth enable -path=kubernetes-prod kubernetes
vault auth enable -path=kubernetes-staging kubernetes

# Step 5: Configure them
vault write auth/kubernetes-dev/config \
  kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT

vault write auth/kubernetes-prod/config \
  kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT

vault write auth/kubernetes-staging/config \
  kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT

# Step 6: Create roles
vault write auth/kubernetes-dev/role/dev-role \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=default \
  ttl=1h

vault write auth/kubernetes-prod/role/prod-role \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=default \
  ttl=1h

# Step 7: Verify
vault auth list
vault list auth/kubernetes-dev/role
vault read auth/kubernetes-dev/role/dev-role

# Step 8: Exit when done
exit
```

### Quick Environment Check Script

Run this inside the pod to see your complete Vault environment:

```bash
echo "=== Vault Environment ==="
echo "VAULT_ADDR: $VAULT_ADDR"
echo "VAULT_TOKEN: ${VAULT_TOKEN:0:20}..."
echo "VAULT_NAMESPACE: $VAULT_NAMESPACE"
echo "KUBERNETES_SERVICE_HOST: $KUBERNETES_SERVICE_HOST"
echo "KUBERNETES_SERVICE_PORT: $KUBERNETES_SERVICE_PORT"
echo ""
echo "=== Vault Status ==="
vault status
echo ""
echo "=== Token Info ==="
vault token lookup
```

### Advantages of Working Inside the Pod

✅ No need to type `kubectl exec` for every command
✅ Faster iteration and testing
✅ Access to pod environment variables directly
✅ Can use shell features (history, tab completion, etc.)
✅ Easier to debug and troubleshoot

**Note:** Remember that changes persist in Vault (not just in the container session), so be careful with what you create/modify!
