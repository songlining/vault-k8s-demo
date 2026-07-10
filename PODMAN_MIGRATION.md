# Podman Desktop Migration Guide

This demo has been migrated from Docker Desktop to Podman Desktop in compliance with IBM's container runtime policy.

## Overview

The demo uses `kind` (Kubernetes in Docker) for local Kubernetes clusters. Since kind v0.17.0, Podman is supported as a backend provider through the `KIND_EXPERIMENTAL_PROVIDER` environment variable.

The VSO (Vault Secrets Operator) demo runs **two** Podman-backed kind
clusters instead of one:

- `kind-vault-lab` — runs Vault only.
- `kind-vso-lab` — runs the Vault Secrets Operator, its CRDs, and the
  `vso-demo-app` consumer only.

The original single-cluster Agent Injector/OTel demo (`make demo`) is
unaffected and continues to run entirely inside `kind-vault-lab`.

## Migration Impact

**Low effort required.** The migration is minimal because:

1. **No Dockerfiles or docker-compose files** - The repo doesn't build custom images
2. **No direct Docker CLI calls** - Scripts use kubectl/helm, not docker commands
3. **kind abstraction** - kind handles container runtime differences transparently

The two-cluster VSO topology adds one real requirement beyond a single
Podman-backed cluster: **cross-cluster networking**. Vault must be reachable
from pods running in the *other* cluster, and Vault must be able to reach the
other cluster's API server to validate service account tokens. Both use the
Podman host gateway address `host.containers.internal` (see
[Host Networking for the Two-Cluster VSO Demo](#host-networking-for-the-two-cluster-vso-demo)
below) rather than in-cluster DNS names, which only resolve inside their own
cluster.

## Prerequisites

Install Podman Desktop and the CLI:

```bash
# macOS (using Homebrew)
brew install podman

# Initialize Podman machine (required on macOS)
podman machine init
podman machine start

# Verify installation
podman version
```

## Using kind with Podman

### One-time setup (export in your shell profile)

```bash
# Add to ~/.zshrc or ~/.bashrc
export KIND_EXPERIMENTAL_PROVIDER=podman
```

### Per-session setup

```bash
# For current shell session only
export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster --name vault-lab
```

## Verification

After setting the provider variable, kind will use Podman instead of Docker:

```bash
# Create a test cluster
export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster --name test

# Verify it works
kubectl get nodes

# Clean up
kind delete cluster --name test
```

## Full Demo Setup with Podman (two clusters)

```bash
# 1. Set Podman as the kind provider
export KIND_EXPERIMENTAL_PROVIDER=podman

# 2. Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# 3. Create BOTH Podman-backed kind clusters (kind-vault-lab, kind-vso-lab)
#    with the host port mappings each cluster needs to reach the other.
make clusters

# 4. Run the full two-cluster demo setup: Vault, VSO, cross-cluster auth,
#    and the VSO demo app -- each targeting its own cluster context
#    explicitly (never the ambient `kubectl config current-context`).
make setup
```

`make setup` is equivalent to running these in order, each of which is also
its own Make target if you want to re-run a single stage:

```bash
scripts/create-clusters.sh              # make clusters
scripts/setup-vault-cluster.sh          # make setup-vault
scripts/setup-vso-cluster.sh            # make setup-vso
scripts/configure-vso-kubernetes-auth.sh  # make configure-vso-auth
scripts/apply-vso-demo.sh               # make vso-apply
```

## Host Networking for the Two-Cluster VSO Demo

Both `kind-vault-lab` and `kind-vso-lab` are Podman-backed kind clusters, so
they do **not** share a pod network or in-cluster DNS. Cross-cluster traffic
goes through the host, using Podman's host gateway hostname:

```text
host.containers.internal
```

This is the Podman-specific hostname that resolves, from inside any
Podman-managed container (including kind nodes), to the Podman machine's
host network. Two things use it:

1. **VSO → Vault**: The Vault cluster exposes Vault via a NodePort Service
   mapped 1:1 to a host port (`VAULT_HOST_PORT`, default `8200`) by the kind
   cluster's `extraPortMappings` config
   (`scripts/kind/vault-lab-config.yaml.tmpl`). VSO's `VaultConnection` in
   the VSO cluster points at `VAULT_ADDR`
   (`http://host.containers.internal:8200` by default) rather than the
   in-cluster name `vault.default.svc.cluster.local`, which only resolves
   inside `kind-vault-lab`.
2. **Vault → VSO's API server**: Vault's dedicated `auth/kubernetes-vso`
   mount validates VSO-cluster service account JWTs by calling the VSO
   cluster's Kubernetes TokenReview API. That API server is similarly mapped
   to a host port (`VSO_API_HOST_PORT`, default `6444`), and Vault is
   configured with `kubernetes_host=VSO_API_ADDR`
   (`https://host.containers.internal:6444` by default).

All of these defaults live in `scripts/lib/two-cluster-env.sh` and can be
overridden via environment variables (`TWO_CLUSTER_HOST`, `VAULT_HOST_PORT`,
`VAULT_NODE_PORT`, `VSO_API_HOST_PORT`, `VAULT_ADDR`, `VSO_API_ADDR`) if you
need different port mappings, e.g. because a port is already in use on your
host.

> **Linux note:** `host.containers.internal` requires a reasonably recent
> Podman (4.7+ generally resolves it out of the box via `--add-host` in
> rootless netavark/slirp4netns setups). If it does not resolve on your
> Linux host, you can override `TWO_CLUSTER_HOST` to your host's real IP on
> the Podman network instead.

## Troubleshooting

### kind cannot connect to Podman

If you get connection errors, ensure Podman machine is running:

```bash
podman machine status
podman machine start  # if stopped
```

### Images not found

Podman maintains separate image storage from Docker. Pre-pull images if needed:

```bash
# kind will auto-pull most images, but you can pre-load:
kind load docker-image nginx:latest --name vault-lab
kind load docker-image nginx:latest --name vso-lab
```

### Performance considerations

- First cluster creation with Podman may be slower as images are downloaded
- Subsequent runs are faster as images are cached in Podman's local storage
- Running **two** clusters concurrently (Vault + VSO) uses noticeably more
  CPU/memory than one. If your Podman machine is resource-constrained,
  increase it before demoing: `podman machine set --cpus 4 --memory 8192`
  (stop/start the machine for this to take effect).

### `host.containers.internal` does not resolve, or a VSO-cluster pod cannot reach Vault

- Confirm `KIND_EXPERIMENTAL_PROVIDER=podman` was exported **before**
  `make clusters` created both clusters — a cluster created against the
  Docker provider will not share the Podman host gateway.
- Run `make check-vault-connectivity` to isolate the failure to network
  reachability specifically (as opposed to auth/policy).
- Confirm the host port mappings are actually bound:
  `podman machine ssh -- sudo ss -ltnp | grep -E '8200|6444'`.

### Reviewer JWT for `auth/kubernetes-vso` expires

`scripts/configure-vso-kubernetes-auth.sh` mints a demo-only, time-bounded
JWT (`kubectl create token`) for the `vault-token-reviewer` service account
and writes it into `auth/kubernetes-vso/config`. It is **not**
auto-refreshed. Re-run `make configure-vso-auth` periodically (well before
the configured TTL, default `8760h`) to mint a fresh one -- it is safe to
re-run at any time and does not disturb any other Vault configuration.

### VSO in `kind-vso-lab` fails to reconcile

```bash
kubectl --context kind-vso-lab logs -n vault-secrets-operator-system \
  -l app.kubernetes.io/name=vault-secrets-operator --tail=200
```

Look for TokenReview/RBAC errors (missing `vault-token-reviewer`
`system:auth-delegator` binding, re-run `make setup-vso`), connection
timeouts to `VAULT_ADDR` (see the networking section above), or `403`s from
Vault (expired reviewer JWT or a policy/role mismatch, see above).

## Compatibility

- **kind version**: v0.17.0+ (Podman support requires this or newer)
- **Podman version**: 4.0+ recommended
- **macOS**: Requires `podman machine` (VM-based)
- **Linux**: Native Podman works directly

## Cleanup

```bash
# Delete both demo clusters
kind delete cluster --name vault-lab
kind delete cluster --name vso-lab

# Optional: Stop Podman machine when not in use (macOS only)
podman machine stop
```

## Migration Checklist

- [x] Install Podman Desktop
- [x] Install Podman CLI
- [x] Set `KIND_EXPERIMENTAL_PROVIDER=podman`
- [x] Verify `kind create cluster` works
- [x] Test full demo flow (`make setup` and `make demo`)
- [x] Update documentation references
- [x] Migrate the VSO demo from one cluster to two Podman-backed kind
      clusters (`kind-vault-lab`, `kind-vso-lab`)
- [x] Verify cross-cluster networking via `host.containers.internal`
      (`make check-vault-connectivity`)
- [x] Verify cross-cluster Kubernetes auth via `auth/kubernetes-vso`
      (`make verify-two-cluster`)
