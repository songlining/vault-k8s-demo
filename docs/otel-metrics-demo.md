# OpenTelemetry Authenticated Vault Metrics Demo

This scenario shows how an OpenTelemetry collector running in Kubernetes can
scrape Vault Prometheus metrics without enabling unauthenticated access to
`/v1/sys/metrics`.

The OTel collector and Vault run together in `kind-vault-lab`. Vault Agent
authenticates the collector's Kubernetes identity, writes a short-lived Vault
token to a shared file, and the collector reads that file through
`bearer_token_file`.

This scenario is independent of the [baseline sidecar secret demo](./sidecar-secret-demo.md)
and the [two-cluster VSO demo](./vso-jwt-oidc-demo.md).

## Why this pattern matters

Vault's UI and API commonly share port `8200`. Enabling
`unauthenticated_metrics_access = true` would allow anyone with network access
to that port to read Vault metrics. This scenario keeps the endpoint protected
and grants a dedicated observability identity permission to read only
`sys/metrics`.

## What this scenario proves

- Unauthenticated requests to `sys/metrics` receive HTTP `403`.
- The collector authenticates through Vault's Kubernetes auth method.
- Vault validates its ServiceAccount JWT through Kubernetes TokenReview.
- Vault Agent writes and renews a short-lived token in a shared volume.
- OTel uses `bearer_token_file` rather than a static token.
- The issued token can read `sys/metrics` and nothing else.

## Architecture

```text
observability/otel-collector ServiceAccount
        |
        | (1) projected ServiceAccount JWT
        v
┌────────────────────────── Pod: otel-collector ──────────────────────────┐
│                                                                         │
│  ┌──────────────────────┐                                               │
│  │ Vault Agent sidecar  │──(2) login──► Vault auth/kubernetes           │
│  └──────────┬───────────┘                         |                     │
│             |                                     | (3) TokenReview     │
│             | (4) writes and renews token         v                     │
│             |     /vault/secrets/token      Kubernetes API              │
│             v                                                           │
│  ┌──────────────────────┐                                               │
│  │ OTel collector      │                                               │
│  └──────────┬───────────┘                                               │
└─────────────┼───────────────────────────────────────────────────────────┘
              |
              └─(5) bearer token──► Vault /v1/sys/metrics
```

Both containers share `/vault/secrets/`. The collector never needs a
hard-coded Vault token.

## End-to-end flow

1. The pod runs as the `observability/otel-collector` ServiceAccount.
2. Kubernetes projects a signed ServiceAccount JWT into the pod.
3. Vault Agent sends the JWT and role `otel-vault-metrics` to
   `auth/kubernetes/login`.
4. Vault calls the TokenReview API and checks the role's bound ServiceAccount
   and namespace.
5. Vault issues a short-lived token carrying `vault-metrics-read`.
6. Vault Agent writes the token to `/vault/secrets/token` and renews it.
7. The Prometheus receiver reads that file and uses the value as the bearer
   token when scraping `/v1/sys/metrics?format=prometheus`.

## Resources

| Resource | Purpose |
| --- | --- |
| `default/vault-0` | Vault server and metrics endpoint. |
| `auth/kubernetes` | Validates the collector's ServiceAccount JWT. |
| `observability` namespace | Isolates the metrics workload. |
| `observability/otel-collector` ServiceAccount | Dedicated collector identity. |
| `vault-metrics-read` policy | Grants read access only to `sys/metrics`. |
| `otel-vault-metrics` role | Maps the collector identity to the metrics policy. |
| `observability/otel-collector` Deployment | OTel collector with a Vault Agent sidecar. |
| `observability/vault-metrics-check` pod | Verification workload using the same auth pattern. |

## Prepare the scenario

### Prerequisites

- Podman Desktop and the Podman CLI
- `kind`
- `kubectl`
- `helm`
- `KIND_EXPERIMENTAL_PROVIDER=podman`

From the repository root:

```sh
export KIND_EXPERIMENTAL_PROVIDER=podman

helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

make clusters
make setup-vault
```

This scenario uses only `kind-vault-lab`, even though `make clusters` prepares
the repository's Vault and VSO clusters.

## Important configuration

### Vault telemetry

The Helm values enable Prometheus retention but deliberately do not enable
unauthenticated metrics:

```hcl
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname = true
}
```

### Vault policy

```hcl
path "sys/metrics" {
  capabilities = ["read"]
}
```

### Kubernetes auth role

```sh
vault write auth/kubernetes/role/otel-vault-metrics \
  alias_name_source=serviceaccount_name \
  bound_service_account_names=otel-collector \
  bound_service_account_namespaces=observability \
  policies=vault-metrics-read \
  ttl=1h
```

### Vault Agent token injection

```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "otel-vault-metrics"
vault.hashicorp.com/agent-inject-token: "true"
vault.hashicorp.com/agent-inject-containers: "otel-collector"
```

`agent-inject-token: "true"` writes the token to:

```text
/vault/secrets/token
```

### OTel receiver

```yaml
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: vault
          scrape_interval: 15s
          metrics_path: /v1/sys/metrics
          params:
            format:
              - prometheus
          bearer_token_file: /vault/secrets/token
          static_configs:
            - targets:
                - vault.default.svc.cluster.local:8200
```

## Run the guided demo

The repository includes an interactive presenter flow:

```sh
make demo
```

Set `NO_WAIT=true` for a non-interactive dry run:

```sh
NO_WAIT=true make demo
```

The final section of that combined presenter flow briefly shows the baseline KV
sidecar. For the standalone explanation of that scenario, use the
[sidecar guide](./sidecar-secret-demo.md).

## Manual walkthrough

### 1. Show the workloads

```sh
kubectl --context kind-vault-lab get pods -n default
kubectl --context kind-vault-lab get pods -n observability
```

Expected state:

```text
default/vault-0                     1/1 Running
default/vault-demo                  2/2 Running
observability/otel-collector-...    2/2 Running
observability/vault-metrics-check   2/2 Running
```

### 2. Inspect the OTel scrape configuration

```sh
kubectl --context kind-vault-lab get configmap otel-collector-config \
  -n observability -o yaml
```

Point out `metrics_path`, `bearer_token_file`, and the in-cluster Vault target.

### 3. Prove unauthenticated metrics are blocked

```sh
kubectl --context kind-vault-lab exec -n observability \
  vault-metrics-check -c vault-metrics-check -- \
  sh -c 'curl -s -o /tmp/vault-metrics-unauth.out -w "%{http_code}" \
  "http://vault.default.svc.cluster.local:8200/v1/sys/metrics?format=prometheus"'
```

Expected result:

```text
403
```

### 4. Show the injected token file safely

```sh
kubectl --context kind-vault-lab exec -n observability \
  vault-metrics-check -c vault-metrics-check -- \
  ls -l /vault/secrets/token
```

Show that the file exists, but do not print its contents.

### 5. Prove authenticated metrics work

```sh
kubectl --context kind-vault-lab exec -n observability \
  vault-metrics-check -c vault-metrics-check -- \
  sh -c 'curl -sf -H "X-Vault-Token: $(cat /vault/secrets/token)" \
  "http://vault.default.svc.cluster.local:8200/v1/sys/metrics?format=prometheus" \
  | grep -m 1 "^# HELP vault_"'
```

Expected output starts with:

```text
# HELP vault_
```

The endpoint is identical to the unauthenticated request; only the valid,
policy-scoped Vault token changes the result.

### 6. Show the least-privilege policy

```sh
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault policy read vault-metrics-read
```

Expected policy:

```hcl
path "sys/metrics" {
  capabilities = ["read"]
}
```

### 7. Show the identity binding

```sh
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault read auth/kubernetes/role/otel-vault-metrics
```

Point out:

```text
bound_service_account_names         [otel-collector]
bound_service_account_namespaces    [observability]
token_policies                      [vault-metrics-read]
```

## Pre-flight checks

```sh
make verify
make status
```

`make verify` checks workload readiness, the unauthenticated `403`, and an
authenticated metrics sample. The command currently expects the active
`kubectl` context to be `kind-vault-lab`.

## Troubleshooting

### OTel or the check pod is not `2/2 Running`

```sh
kubectl --context kind-vault-lab describe pod \
  -n observability -l app=otel-collector
kubectl --context kind-vault-lab logs \
  -n observability deployment/otel-collector -c vault-agent
kubectl --context kind-vault-lab logs \
  -n observability deployment/otel-collector -c otel-collector
```

### Unauthenticated metrics returns `200`

Vault has been configured with unauthenticated metrics access. Remove
`unauthenticated_metrics_access = true`; this scenario expects the setting to
remain disabled.

### Authenticated metrics returns `403`

Check the policy, role, and ServiceAccount:

```sh
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault policy read vault-metrics-read
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault read auth/kubernetes/role/otel-vault-metrics
kubectl --context kind-vault-lab get pod -n observability \
  -l app=otel-collector \
  -o jsonpath='{.items[0].spec.serviceAccountName}{"\n"}'
```

The ServiceAccount must be `otel-collector`, and the role must bind it in the
`observability` namespace.

### Vault is sealed

Re-run the idempotent Vault setup:

```sh
make setup-vault
```

The setup script can unseal the disposable Vault instance using the gitignored
`vault-init-keys.json`. Never commit this file; it contains the demo root token
and unseal keys.

## Related scenarios

- [Vault Agent sidecar secret injection](./sidecar-secret-demo.md)
- [Vault Secrets Operator with cross-cluster JWT/OIDC](./vso-jwt-oidc-demo.md)
- [Repository overview](../README.md)
