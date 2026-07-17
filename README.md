# Vault Kubernetes Demo Scenarios

This repository contains three independent Vault-on-Kubernetes demonstrations.
Each scenario has its own guide so its architecture, setup, walkthrough, and
troubleshooting remain focused.

## Choose a scenario

| Scenario | Secret delivery | Authentication | Topology | Guide |
| --- | --- | --- | --- | --- |
| Vault Agent sidecar | Vault Agent renders a KV secret to a pod-local file | Kubernetes auth and TokenReview | Vault and workload in `kind-vault-lab` | [Vault Agent sidecar secret demo](docs/sidecar-secret-demo.md) |
| OpenTelemetry metrics | Vault Agent writes a token file used by OTel's `bearer_token_file` | Kubernetes auth and TokenReview | Vault and OTel in `kind-vault-lab` | [OpenTelemetry authenticated metrics demo](docs/otel-metrics-demo.md) |
| Vault Secrets Operator | VSO synchronises Vault KV data to a native Kubernetes `Secret` | JWT/OIDC discovery, advertised JWKS, and strict issuer/audience/subject validation | Vault in `kind-vault-lab`; VSO in `kind-vso-lab` | [VSO two-cluster JWT/OIDC demo](docs/vso-jwt-oidc-demo.md) |

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

Start with [docs/vso-jwt-oidc-demo.md](docs/vso-jwt-oidc-demo.md).

## Cluster model

The repository uses two Podman-backed kind clusters:

- `kind-vault-lab` (`VAULT_CONTEXT`) runs Vault, the Vault Agent Injector,
  the baseline sidecar pod, and the OTel metrics workload.
- `kind-vso-lab` (`VSO_CONTEXT`) runs Vault Secrets Operator, its CRDs, and
  the plain `vso-demo-app` consumer.

The sidecar and OTel scenarios use only the Vault cluster. The VSO scenario
uses both clusters and reaches Vault through
`http://host.containers.internal:8200` by default.

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
make setup                      # Prepare all three scenarios
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
```

`make demo` combines the OTel flow with a brief baseline sidecar proof. The
documentation is separated because the two scenarios have different goals,
policies, and application consumption patterns.

## Security notes

- The OTel scenario deliberately leaves unauthenticated metrics access
  disabled.
- The VSO default uses JWT/OIDC validation and does not store a
  `token_reviewer_jwt` in Vault.
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
