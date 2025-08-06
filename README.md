# Vault Kubernetes Demo

This repository contains a script to demonstrate HashiCorp Vault integration with Kubernetes.

## What the Script (create_vault.sh) Does

Running the script against an existing k8s cluster, it will -
1. Install vault server into "default" namespace using Helm with audit storage enabled
2. Wait for the Vault pod to be ready, then initialize it with 5 key shares (threshold of 3)
3. Unseal the vault server using the first 3 keys and login with the root token
4. Enable file audit logging to stdout
5. Create necessary Kubernetes RBAC permissions (ClusterRoleBinding)
6. Enable the kubernetes authentication method in Vault
7. Enable kv-v2 secrets engine and create a sample secret "mysecret" with username "larry"
8. Create a policy to allow reading the secret and configure a Kubernetes role
9. Install a demo app (vault-demo) into the same namespace for simplicity
10. A vault sidecar will be injected together with the demo app using annotations
11. The demo app authenticates with Vault using its service account token and retrieves the secret

## Verification

Once everything is running, check `/vault/secrets/mysecret` file has been populated. This is on the vault-demo container in vault-demo pod. When using k9s, type 's' on the pod to shell to it.

## Prerequisites

- A running Kubernetes cluster
- kubectl configured to access your cluster
- Helm installed

# More explanation of Vault Configuration in create_vault.sh

Question is: how does vault authenticate to k8s TokenReview API ?

## 1. RBAC Configuration

The script creates a ClusterRoleBinding that grants the `system:auth-delegator` role to the default service account:

```yaml:/Users/larry.song/work/hashicorp/vault-k8s-demo/create_vault.sh
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: my-auth-delegator-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: default
  namespace: default
```

The `system:auth-delegator` ClusterRole provides the necessary permissions to:
- Access the TokenReview API (`tokenreviews.authentication.k8s.io`)
- Validate service account tokens on behalf of other services

## 2. Service Account Token Authentication

When Vault runs in a Kubernetes pod, it automatically receives:
- **Service Account Token**: Mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`
- **CA Certificate**: For verifying the Kubernetes API server's TLS certificate
- **Namespace**: The pod's namespace information

## 3. Authentication Flow

When Vault needs to validate a JWT token through the TokenReview API:

1. **Vault uses its own service account token** to authenticate to the Kubernetes API server
2. **Makes a POST request** to `/apis/authentication.k8s.io/v1/tokenreviews` endpoint
3. **Includes the JWT to be validated** in the request body
4. **Kubernetes validates the JWT** and returns information about the token's validity and associated service account
5. **Vault uses this response** to make authorization decisions

## 4. Configuration in Vault

The script configures Vault with the Kubernetes API endpoint:

```bash:/Users/larry.song/work/hashicorp/vault-k8s-demo/create_vault.sh
vault write auth/kubernetes/config \
  kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT
```

This tells Vault:
- **Where to find the Kubernetes API server** (using cluster-internal service discovery)
- **How to connect securely** (HTTPS with cluster CA)

## Key Points

- **No explicit credentials needed**: Vault leverages the automatic service account token mounting in Kubernetes
- **RBAC is crucial**: Without the `system:auth-delegator` role, Vault cannot access the TokenReview API
- **Cluster-internal communication**: Uses Kubernetes service discovery for secure API access
- **Mutual authentication**: Both Vault and Kubernetes validate each other's credentials

This design follows Kubernetes security best practices by using built-in RBAC and service account mechanisms rather than managing separate credentials.
        

# Another question

Question:

in this command (runs in the k8s container):

VAULT_RESPONSE=$(curl -X POST -H "X-Vault-Request: true" -d '{"jwt": "'"$SA_TOKEN"'", "role": "vault-demo"}' $VAULT_ADDR/v1/auth/kubernetes/login | jq .)

the container uses the SA_TOKEN in the payload to authenticate to Vault (using k8s as the auth engine).  What happens between Vault and K8S API?

## Step-by-Step Authentication Flow

When the container executes that curl command with the `SA_TOKEN`, here's the detailed flow between Vault and the Kubernetes API:

### 1. Container Sends Authentication Request
```bash
VAULT_RESPONSE=$(curl -X POST -H "X-Vault-Request: true" -d '{"jwt": "'"$SA_TOKEN"'", "role": "vault-demo"}' \
  $VAULT_ADDR/v1/auth/kubernetes/login | jq .)
```

The container sends:
- **JWT Token**: The service account token (`$SA_TOKEN`) from `/var/run/secrets/kubernetes.io/serviceaccount/token`
- **Role**: `vault-demo` (the Vault role to authenticate against)
- **Endpoint**: `/v1/auth/kubernetes/login`

### 2. Vault Receives the Request

Vault's Kubernetes auth method receives the JWT and:
- Extracts the JWT from the request payload
- Identifies the role (`vault-demo`) and its configuration
- Prepares to validate the JWT with Kubernetes

### 3. Vault Calls Kubernetes TokenReview API

Vault makes an API call to Kubernetes using **its own service account token**:

```http
POST /apis/authentication.k8s.io/v1/tokenreviews
Authorization: Bearer <vault-service-account-token>
Content-Type: application/json

{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "spec": {
    "token": "<container-sa-token>"
  }
}
```

### 4. Kubernetes Validates the Token

Kubernetes API server:
- **Verifies the JWT signature** using its internal signing keys
- **Checks token expiration** and validity
- **Extracts service account information** (name, namespace, UID)
- **Returns validation results**

### 5. Kubernetes Responds to Vault

```json
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "status": {
    "authenticated": true,
    "user": {
      "username": "system:serviceaccount:default:default",
      "uid": "<service-account-uid>",
      "groups": [
        "system:serviceaccounts",
        "system:serviceaccounts:default",
        "system:authenticated"
      ]
    }
  }
}
```

### 6. Vault Validates Against Role Configuration

Vault checks if the validated service account matches the role configuration:

```bash
# From the script's role configuration:
vault write auth/kubernetes/role/vault-demo \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default,mysecret \
    ttl=1h
```

Vault verifies:
- ✅ Service account name: `default` (matches `bound_service_account_names`)
- ✅ Namespace: `default` (matches `bound_service_account_namespaces`)
- ✅ Token is valid and authenticated

### 7. Vault Issues Token

If validation succeeds, Vault:
- **Creates a new Vault token** with the configured policies (`default`, `mysecret`)
- **Sets TTL** to 1 hour
- **Returns the token** to the container

```json
{
  "auth": {
    "client_token": "hvs.CAESIJ...",
    "accessor": "hmac-sha256:...",
    "policies": ["default", "mysecret"],
    "token_policies": ["default", "mysecret"],
    "lease_duration": 3600,
    "renewable": true
  }
}
```

## Key Security Aspects

1. **Vault never stores the original JWT** - it only uses it for validation
2. **Kubernetes is the source of truth** for token validity
3. **Vault uses its own credentials** to call the TokenReview API (via the `system:auth-delegator` role)
4. **Short-lived tokens** - both the original JWT and the issued Vault token have TTLs
5. **Role-based authorization** - Vault maps validated service accounts to specific policies

This design ensures that Vault can securely validate Kubernetes service account tokens without needing to manage Kubernetes signing keys or understand JWT internals - it delegates that complexity to Kubernetes itself.