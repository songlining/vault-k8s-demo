# Vault Kubernetes Demo

This repository contains a script to demonstrate HashiCorp Vault integration with Kubernetes.

## What the Script Does

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

Once everything is running, check `/vault/secrets/mysecret` file has been populated. This is on the vault-demo container in vault-demo pod.

## Prerequisites

- A running Kubernetes cluster
- kubectl configured to access your cluster
- Helm installed
