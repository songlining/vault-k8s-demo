# Vault Kubernetes Demo Scenarios

This repository contains four independent Vault-on-Kubernetes demonstrations.
Each scenario has its own guide so its architecture, setup, walkthrough, and
troubleshooting remain focused.

## Choose a scenario

| Scenario | Secret delivery | Authentication | Topology | Guide |
| --- | --- | --- | --- | --- |
| Vault Agent sidecar | Vault Agent renders a KV secret to a pod-local file | Kubernetes auth and TokenReview | Vault and workload in `kind-vault-lab` | [Vault Agent sidecar secret demo](docs/sidecar-secret-demo.md) |
| OpenTelemetry metrics | Vault Agent writes a token file used by OTel's `bearer_token_file` | Kubernetes auth and TokenReview | Vault and OTel in `kind-vault-lab` | [OpenTelemetry authenticated metrics demo](docs/otel-metrics-demo.md) |
| Vault Secrets Operator (default) | VSO synchronises Vault KV data to a native Kubernetes `Secret` | JWT/OIDC discovery, advertised JWKS, and strict issuer/audience/subject validation | Vault in `kind-vault-lab`; VSO in `kind-vso-lab` | [VSO two-cluster JWT/OIDC demo](docs/vso-jwt-oidc-demo.md) |
| Vault Secrets Operator (client JWT self-review) | VSO synchronises a dedicated Vault KV secret cross-namespace to a native Kubernetes `Secret` | Kubernetes auth: the client's own short-lived, dual-audience JWT is both the Vault login credential and the TokenReview HTTP bearer, authorized by a scenario-owned `system:auth-delegator` binding | Vault in `kind-vault-lab`; VSO in `kind-vso-lab` (separate namespaces from the default scenario) | [VSO client JWT self-review demo](docs/vso-kubernetes-auth-delegator-demo.md) |

### Vault Agent sidecar secret injection

Use this scenario to show the baseline sidecar pattern: a pod authenticates
with its Kubernetes ServiceAccount, Vault Agent retrieves a least-privilege KV
secret, and the application reads `/vault/secrets/mysecret`.

Start with [docs/sidecar-secret-demo.md](docs/sidecar-secret-demo.md).

### OpenTelemetry authenticated metrics

Use this scenario to show how OTel can scrape `/v1/sys/metrics` while
unauthenticated access remains disabled. Vault Agent manages a short-lived
token file; the collector consumes it through `bearer_token_file`.

Start with [docs/otel-metrics-demo.md](docs/otel-metrics-demo.md).

### Vault Secrets Operator with cross-cluster JWT/OIDC

Use this scenario to show a central Vault cluster serving a separate workload
cluster. Vault validates VSO identity through `auth/jwt-vso`: it retrieves the
VSO cluster's OIDC discovery document, follows the advertised JWKS URI, and
strictly checks issuer, audience, and subject before VSO syncs or rotates data.
This remains the **default** VSO scenario.

Start with [docs/vso-jwt-oidc-demo.md](docs/vso-jwt-oidc-demo.md).

### Vault Secrets Operator with client JWT self-review (alternative)

Use this scenario to show Kubernetes auth's client JWT self-review mode: the
same short-lived, dual-audience ServiceAccount JWT VSO submits as its Vault
login credential is also the HTTP bearer Vault uses for its own
TokenReview call to the VSO cluster, authorized by a scenario-owned
`system:auth-delegator` ClusterRoleBinding. It runs in dedicated namespaces
alongside (never in place of) the default JWT/OIDC scenario, and
cross-namespace `VaultAuth`/`VaultStaticSecret` references are demonstrated
explicitly. This is an explicit alternative, not the default.

Start with [docs/vso-kubernetes-auth-delegator-demo.md](docs/vso-kubernetes-auth-delegator-demo.md).

## Cluster model

The repository uses two Podman-backed kind clusters:

- `kind-vault-lab` (`VAULT_CONTEXT`) runs Vault, the Vault Agent Injector,
  the baseline sidecar pod, and the OTel metrics workload.
- `kind-vso-lab` (`VSO_CONTEXT`) runs Vault Secrets Operator, its CRDs, and
  the plain `vso-demo-app` consumer, plus the client-JWT-self-review
  scenario's dedicated namespaces (`vso-auth-delegator`,
  `vso-auth-delegator-app`) and app.

The sidecar and OTel scenarios use only the Vault cluster. Both VSO scenarios
use both clusters and reach Vault through `http://host.containers.internal:8200`
by default; they never share a namespace, Vault mount, or Secret name with
each other.

## Prerequisites

- Podman Desktop with the Podman CLI
- `kind`
- `kubectl`
- `helm`
- The HashiCorp Helm chart repository

Set Podman as the kind provider:

```sh
export KIND_EXPERIMENTAL_PROVIDER=podman

helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

See [PODMAN_MIGRATION.md](PODMAN_MIGRATION.md) for Podman machine setup,
resource sizing, port mappings, and cross-cluster networking details.

## Quick start: prepare every scenario

```sh
make setup
```

The setup is idempotent and performs these stages:

1. Create or validate `kind-vault-lab` and `kind-vso-lab`.
2. Install and configure Vault, Kubernetes auth, the sidecar pod, and OTel in
   `VAULT_CONTEXT`.
3. Install VSO and create its namespace and ServiceAccounts in `VSO_CONTEXT`.
4. Configure Vault's dedicated `auth/jwt-vso` mount with the VSO cluster's
   TLS-verified OIDC discovery URL and RS256-only JWT validation.
5. Apply the VSO CRDs and application pod.

`make setup` prepares the default JWT/OIDC VSO scenario only. The client
JWT self-review scenario is a separate, explicit opt-in
(`make auth-delegator-setup`) -- see
[docs/vso-kubernetes-auth-delegator-demo.md](docs/vso-kubernetes-auth-delegator-demo.md).

To prepare one part at a time:

```sh
make clusters
make setup-vault
make setup-vso
make configure-vso-auth
make vso-apply
```

## Command index

```sh
make help                       # Show all available commands
make setup                      # Prepare all default scenarios
make clusters                   # Create or validate both kind clusters
make setup-vault                # Prepare Vault, sidecar, and OTel resources
make setup-vso                  # Install VSO and its namespace/identities
make configure-vso-auth         # Configure auth/jwt-vso and strict JWT bindings
make vso-apply                  # Apply VSO CRDs and vso-demo-app

make demo                       # Guided Agent Injector and OTel walkthrough
make verify                     # Verify the single-cluster sidecar/OTel path
make status                     # Show sidecar and OTel resources
make logs-agent                 # Show OTel pod Vault Agent logs
make logs-otel                  # Show OTel collector logs

make vso-demo                   # Guided two-cluster VSO walkthrough
make vso-deck                   # Start/verify/reuse the lab; reconcile only if unhealthy, then run the deck
make vso-verify                 # Verify VSO, its CRDs, Secret, and app
make vso-status                 # Show VSO resources across both clusters
make logs-vso                   # Show VSO controller logs
make check-vault-connectivity   # Test VSO-cluster to Vault connectivity
make verify-two-cluster         # Full placement/auth/sync/rotation proof

make configure-auth-delegator   # Configure the dedicated Kubernetes auth mount/role/policy
make auth-delegator-apply       # Apply the cross-namespace VSO resources
make auth-delegator-setup       # Both of the above, once
make auth-delegator-verify      # Full proof, including CAS rotation
make auth-delegator-status      # Show resources across both clusters
make auth-delegator-deck        # Health-first: verify both scenarios, then run the deck
```

`make demo` combines the OTel flow with a brief baseline sidecar proof. The
documentation is separated because the two scenarios have different goals,
policies, and application consumption patterns.

## Security notes

- The OTel scenario deliberately leaves unauthenticated metrics access
  disabled.
- The default VSO scenario uses JWT/OIDC validation and does not store a
  `token_reviewer_jwt` in Vault.
- The client-JWT-self-review VSO scenario also stores no reviewer JWT
  (`token_reviewer_jwt` is explicitly cleared); the scenario-owned
  `system:auth-delegator` binding has exactly one subject, and no target
  ever creates, deletes, or recreates a cluster, or runs Helm
  install/upgrade.
- `vault-init-keys.json` contains the disposable demo's root token and unseal
  keys. It is gitignored and must never be committed or reused outside this
  local lab.
- Do not print injected Vault token files during a demonstration.

## Cleanup

```sh
kind delete cluster --name vault-lab
kind delete cluster --name vso-lab
```

Keep `KIND_EXPERIMENTAL_PROVIDER=podman` set so kind deletes clusters from the
expected provider.

## Supporting documentation

- [Podman Desktop migration and networking](PODMAN_MIGRATION.md)
- [VSO JWT/OIDC implementation plan](docs/vso-jwt-oidc-auth-plan.md)
- [VSO end-to-end validation evidence](docs/vso-jwt-oidc-auth-e2e-validation.md)
- [VSO presenterm deck](presenterm/vso.md)
- [VSO client JWT self-review implementation plan](docs/vso-kubernetes-auth-delegator-plan.md)
- [VSO client JWT self-review presenterm deck](presenterm/auth-delegator.md)
