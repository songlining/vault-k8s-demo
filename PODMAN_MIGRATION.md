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
from pods running in the *other* cluster, and Vault must be able to fetch
that cluster's public JSON Web Key Set (JWKS) so it can validate service
account tokens cryptographically, without ever calling back into that
cluster's API server. Both use the Podman host gateway address
`host.containers.internal` (see
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
scripts/configure-vso-jwt-auth.sh       # make configure-vso-auth (auth/jwt-vso, JWT/OIDC)
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
2. **Vault → VSO cluster's OIDC discovery and JWKS**: The VSO API server is
   configured as the externally reachable ServiceAccount issuer at
   `VSO_OIDC_DISCOVERY_URL` (`https://host.containers.internal:6444` by
   default). Vault's `auth/jwt-vso` mount retrieves the TLS-verified discovery
   document, requires its issuer to match the JWT `iss`, follows its advertised
   `jwks_uri`, and validates RS256 signatures plus audience and subject locally.
   It never calls TokenReview and stores no reviewer credential. Both discovery
   and JWKS use the stable `VSO_API_HOST_PORT` mapping and the VSO cluster CA;
   Vault does not configure a direct `jwks_url` verification source.

All of these defaults live in `scripts/lib/two-cluster-env.sh` and can be
overridden via environment variables (`TWO_CLUSTER_HOST`, `VAULT_HOST_PORT`,
`VAULT_NODE_PORT`, `VSO_API_HOST_PORT`, `VAULT_ADDR`, `VSO_API_ADDR`,
`VSO_OIDC_DISCOVERY_URL`) if you
need different port mappings, e.g. because a port is already in use on your
host.

> **Linux note:** `host.containers.internal` requires a reasonably recent
> Podman (4.7+ generally resolves it out of the box via `--add-host` in
> rootless netavark/slirp4netns setups). If it does not resolve on your
> Linux host, you can override `TWO_CLUSTER_HOST` to your host's real IP on
> the Podman network instead.

### Vault-to-VSO TokenReview path (client JWT self-review scenario, port 6444)

The optional client-JWT-self-review VSO scenario (`make auth-delegator-deck`,
see
[docs/vso-kubernetes-auth-delegator-demo.md](docs/vso-kubernetes-auth-delegator-demo.md))
reuses the SAME `VSO_API_ADDR`/`VSO_API_HOST_PORT` mapping
(`https://host.containers.internal:6444` by default) as the default JWT/OIDC
scenario's discovery/JWKS path, but for a different call: Vault's dedicated
`auth/kubernetes-vso-self-review` mount makes a live, per-login
`POST /apis/authentication.k8s.io/v1/tokenreviews` request to this same
address, using the client's own short-lived ServiceAccount JWT as the
`Authorization: Bearer` header. This is why the credential-provider config
requests a token whose audiences include both `vault` and the VSO cluster's
issuer URL -- the issuer-URL audience is what lets the same JWT authenticate
as the outer HTTP bearer for this TokenReview call, since the VSO
kube-apiserver does not set `--api-audiences` and therefore defaults its
accepted audience to its own issuer.

No new port mapping, kube-apiserver flag, or cluster recreation is required
for this scenario -- it reuses the existing port-6444 mapping and CA trust
already established for OIDC discovery.

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

### JWT/OIDC login through `auth/jwt-vso` fails

`scripts/configure-vso-jwt-auth.sh` configures `auth/jwt-vso` to trust the
VSO cluster's JWKS and strictly bind issuer, audience, and subject claims --
no reviewer service account, and no `token_reviewer_jwt`, is ever created or
stored. If login fails, re-check that the `oidc-discovery-reader`
ClusterRole/ClusterRoleBinding still exists in the VSO cluster (Vault needs
it to fetch the JWKS), and that the role's `bound_audiences`/`bound_subject`
still match what `VaultAuth` presents. Re-running the configuration is safe
and idempotent at any time:

```bash
make configure-vso-auth   # re-applies auth/jwt-vso/config and auth/jwt-vso/role/vso-demo
```

> **Legacy comparison path:** `scripts/configure-vso-kubernetes-auth.sh`
> (not run by `make setup`) instead mints a demo-only, time-bounded JWT via
> `kubectl create token` for a `vault-token-reviewer` service account and
> writes it into `auth/kubernetes-vso/config`. That JWT is **not**
> auto-refreshed; if you've deliberately opted into this path
> (`ENABLE_TOKEN_REVIEWER_AUTH=1 scripts/setup-vso-cluster.sh` then
> `bash scripts/configure-vso-kubernetes-auth.sh`), re-run it periodically
> (well before the default `8760h` TTL) to mint a fresh one.

### VSO in `kind-vso-lab` fails to reconcile

```bash
kubectl --context kind-vso-lab logs -n vault-secrets-operator-system \
  -l app.kubernetes.io/name=vault-secrets-operator --tail=200
```

Look for JWT/OIDC errors (invalid audience/subject claim, or a JWKS fetch
failure -- see the section above), connection timeouts to `VAULT_ADDR` (see
the networking section above), or `403`s from Vault (policy/role mismatch,
see above). If you're deliberately using the legacy `auth/kubernetes-vso`
comparison path, also look for TokenReview/RBAC errors (missing
`vault-token-reviewer`/`system:auth-delegator` binding).

### Client JWT self-review login (`auth/kubernetes-vso-self-review`) fails

This is the opt-in scenario from
[docs/vso-kubernetes-auth-delegator-demo.md](docs/vso-kubernetes-auth-delegator-demo.md)
(`make auth-delegator-deck`), separate from the default JWT/OIDC path above.
Since Vault's TokenReview call to the VSO cluster reuses the port-6444
mapping, first rule out the same connectivity issues as the OIDC path
(`make check-vault-connectivity`, host port mappings). If connectivity is
fine, check:

- the live mount config has `disable_local_ca_jwt=true`,
  `disable_iss_validation=true`, and no stored reviewer JWT:
  `kubectl --context kind-vault-lab exec vault-0 -n default -- vault read auth/kubernetes-vso-self-review/config`;
- the VSO cluster's advertised issuer still equals
  `AUTH_DELEGATOR_API_AUDIENCE`/`VSO_OIDC_ISSUER` (a dual-audience token
  needs both to match exactly); and
- the scenario ClusterRoleBinding
  (`vso-auth-delegator-self-review`) still grants `system:auth-delegator`
  to exactly the self-review ServiceAccount --
  `make auth-delegator-verify` proves this and every other gate
  non-interactively, including the direct same-JWT TokenReview proof.

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
- [x] Verify cross-cluster JWT/OIDC auth via `auth/jwt-vso`, including
      wrong-audience and wrong-service-account JWTs being correctly rejected
      (`make verify-two-cluster`)
