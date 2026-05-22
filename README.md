# Vault Kubernetes Auth and OTel Metrics Demo

This demo shows how an OpenTelemetry collector running in Kubernetes can scrape
Vault Prometheus metrics without enabling unauthenticated access to
`/v1/sys/metrics`.

The key pattern is:

1. Kubernetes authenticates the OTel collector workload to Vault.
2. Vault Agent runs as a sidecar and writes a short-lived Vault token to a local
   file.
3. The OTel collector reads that token through `bearer_token_file`.
4. Vault only grants that token read access to `sys/metrics`.

This is useful when port `8200` is reachable through the same access path used
for the Vault UI. In that situation, enabling
`unauthenticated_metrics_access = true` would allow any user with network access
to read Vault metrics. This demo keeps metrics authenticated and scoped to a
dedicated Kubernetes service account.

## What the demo proves

- Unauthenticated requests to `sys/metrics` are blocked.
- A Kubernetes workload can authenticate to Vault through Kubernetes auth.
- Vault Agent can provide the workload with a token file.
- OTel can use `bearer_token_file` to scrape Vault metrics.
- The issued Vault token is least-privilege: it can read `sys/metrics` and
  nothing else.

## Demo architecture

```text
                    Kubernetes cluster

  observability namespace
  -----------------------------------------------------------------
  ServiceAccount: otel-collector
          |
          | Kubernetes service account JWT
          v
  Pod: otel-collector
  +-------------------------------+      +-------------------------+
  | OpenTelemetry collector       |      | Vault Agent sidecar     |
  |                               |      |                         |
  | Prometheus receiver           |      | Kubernetes auth login   |
  | bearer_token_file:            |<-----| writes token to:        |
  | /vault/secrets/token          |      | /vault/secrets/token    |
  +-------------------------------+      +-------------------------+
          |
          | GET /v1/sys/metrics?format=prometheus
          | X-Vault-Token: <token from file>
          v
  -----------------------------------------------------------------
  default namespace

  Vault server
  - Kubernetes auth method enabled
  - role: otel-vault-metrics
  - policy: vault-metrics-read
```

## Resources created by the script

`create_vault.sh` installs and configures a complete demo environment.

| Resource | Purpose |
| --- | --- |
| `vault` Helm release | Runs Vault and the Vault Agent injector. |
| `default/vault-0` | Vault server pod. |
| `my-auth-delegator-binding` | Allows the Vault server service account to use the Kubernetes TokenReview API. |
| `auth/kubernetes` | Vault auth method used to validate Kubernetes service account tokens. |
| `kv-v2/vault-demo/mysecret` | Baseline secret used by the original sidecar demo. |
| `vault-demo` role and `mysecret` policy | Baseline Kubernetes auth role for reading the demo secret. |
| `observability` namespace | Namespace for the metrics collection path. |
| `observability/otel-collector` service account | Dedicated identity for the OTel collector. |
| `vault-metrics-read` policy | Grants read access only to `sys/metrics`. |
| `otel-vault-metrics` role | Maps the OTel service account to the metrics policy. |
| `observability/otel-collector` deployment | OTel collector with an injected Vault Agent sidecar. |
| `observability/vault-metrics-check` pod | Simple verification pod using the same auth pattern. |

## Important configuration

### Vault telemetry

The Helm values in `create_vault.sh` enable Prometheus metric retention:

```hcl
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname = true
}
```

The script does **not** enable `unauthenticated_metrics_access`.

### Vault policy

The OTel collector receives only this policy:

```hcl
path "sys/metrics" {
  capabilities = ["read"]
}
```

### Kubernetes auth role

The Vault role is bound only to the OTel collector service account in the
`observability` namespace:

```sh
vault write auth/kubernetes/role/otel-vault-metrics \
  alias_name_source=serviceaccount_name \
  bound_service_account_names=otel-collector \
  bound_service_account_namespaces=observability \
  policies=vault-metrics-read \
  ttl=1h
```

### Vault Agent token injection

The OTel deployment uses these annotations:

```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "otel-vault-metrics"
vault.hashicorp.com/agent-inject-token: "true"
vault.hashicorp.com/agent-inject-containers: "otel-collector"
```

`agent-inject-token: "true"` makes Vault Agent write the Vault token to:

```text
/vault/secrets/token
```

### OTel receiver configuration

The OTel collector uses the token file directly:

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

## Prepare for the demo

End-to-end checklist to go from a clean machine to "ready to present."

### 1. Prerequisites

- A disposable Kubernetes cluster (kind works well locally).
- `kubectl` configured for that cluster.
- `helm` installed.
- The HashiCorp Helm chart repository available.

### 2. Bootstrap a fresh cluster

```sh
kind create cluster --name vault-lab
kubectl config use-context kind-vault-lab
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

### 3. Build the demo environment

```sh
make setup
```

This runs `create_vault.sh`, which installs Vault and the Agent Injector,
initialises and unseals Vault, configures Kubernetes auth, deploys the baseline
secret demo, deploys the OTel metrics path, and runs two metrics checks. The
script is idempotent — re-running it skips steps that are already done and
re-injects the `vault-demo` sidecar.

A successful run ends with:

```text
Unauthenticated sys/metrics HTTP status: 403
# HELP vault_audit_log_request vault_audit_log_request
OpenTelemetry collector is configured to scrape Vault sys/metrics with bearer_token_file=/vault/secrets/token.
```

### 4. Pre-flight check

Right before the customer joins:

```sh
make verify    # confirms the cluster is ready
make status    # shows the demo resources
```

You're ready to present when all four pods report `2/2 Running`:

```text
default/vault-0
default/vault-demo
observability/otel-collector-...
observability/vault-metrics-check
```

### 5. Optional polish

- Open a second terminal with `kubectl get pods -A -w` for live visual feedback
  during the talk.
- If the cluster has been idle a while, re-run `make setup` — it's safe and
  takes ~30s on an already-configured cluster.
- For a totally fresh start: `kind delete cluster --name vault-lab` and return
  to step 2.

## Presenter commands

The repository includes a guided demo driver so the live demo is easier to run
than copying commands one by one.

```sh
make help      # Show available commands
make verify    # Check the cluster is ready for the demo
make demo      # Start the guided live demo flow
make status    # Show the Kubernetes resources used by the demo
```

Use `make demo` for the customer walkthrough. It pauses between sections and
prints each command before running it, so the audience can follow both the story
and the proof points.

## Live demo flow

`make demo` walks through these same steps. The commands below are included as a
reference if you prefer to drive the demo manually.

### 1. Show the workloads

```sh
kubectl get pods -n default
kubectl get pods -n observability
```

Expected result:

```text
vault-0                 1/1 Running
vault-demo              2/2 Running
otel-collector-...      2/2 Running
vault-metrics-check     2/2 Running
```

The `2/2` pods show that the application container and Vault Agent sidecar are
both running.

### 2. Show unauthenticated metrics are blocked

```sh
kubectl exec -n observability vault-metrics-check -c vault-metrics-check -- \
  sh -c 'curl -s -o /tmp/vault-metrics-unauth.out -w "%{http_code}" \
  "http://vault.default.svc.cluster.local:8200/v1/sys/metrics?format=prometheus"'
```

Expected result:

```text
403
```

This proves the demo has not enabled unauthenticated metrics access.

### 3. Show Vault Agent has injected a token file

```sh
kubectl exec -n observability vault-metrics-check -c vault-metrics-check -- \
  ls -l /vault/secrets/token
```

This token is generated by Vault Agent after it authenticates with Vault using
the pod's Kubernetes service account token.

### 4. Show authenticated metrics work

```sh
kubectl exec -n observability vault-metrics-check -c vault-metrics-check -- \
  sh -c 'curl -sf -H "X-Vault-Token: $(cat /vault/secrets/token)" \
  "http://vault.default.svc.cluster.local:8200/v1/sys/metrics?format=prometheus" | head'
```

Expected result:

```text
# HELP vault_...
# TYPE vault_...
```

This proves the same endpoint is available when the request includes a Vault
token with the right policy.

### 5. Show the least-privilege policy

```sh
kubectl exec vault-0 -- vault policy read vault-metrics-read
```

Expected result:

```hcl
path "sys/metrics" {
  capabilities = ["read"]
}
```

### 6. Show the role binding to Kubernetes identity

```sh
kubectl exec vault-0 -- vault read auth/kubernetes/role/otel-vault-metrics
```

Point out these fields:

```text
bound_service_account_names         [otel-collector]
bound_service_account_namespaces    [observability]
token_policies                      [vault-metrics-read]
```

### 7. Show the OTel scrape configuration

```sh
kubectl get configmap otel-collector-config -n observability -o yaml
```

Point out:

```yaml
metrics_path: /v1/sys/metrics
bearer_token_file: /vault/secrets/token
targets:
  - vault.default.svc.cluster.local:8200
```

## How the pieces work together

1. The OTel pod starts with Kubernetes service account
   `observability/otel-collector`.
2. Vault Agent is injected into the pod by the Vault Agent injector.
3. Vault Agent sends the pod's Kubernetes service account JWT to Vault's
   Kubernetes auth endpoint.
4. Vault asks the Kubernetes TokenReview API to validate that JWT.
5. Vault checks that the service account and namespace match the
   `otel-vault-metrics` role.
6. Vault issues a short-lived token with the `vault-metrics-read` policy.
7. Vault Agent writes that token to `/vault/secrets/token`.
8. The OTel collector's Prometheus receiver reads that token file and uses it as
   the bearer token when scraping `/v1/sys/metrics?format=prometheus`.

## Baseline sidecar secret demo

The script also keeps the original secret sidecar example. It demonstrates the
same Kubernetes auth wiring with a simple KV secret:

- Vault role: `vault-demo`
- Vault policy: `mysecret`
- Secret path: `kv-v2/data/vault-demo/mysecret`
- Pod: `default/vault-demo`

Check the rendered secret file:

```sh
kubectl exec vault-demo -c vault-demo -- cat /vault/secrets/mysecret
```

This is separate from the OTel metrics path. It is included as a simple baseline
to show the Kubernetes auth flow before the metrics-specific example.

## Troubleshooting

### OTel or check pod is not `2/2 Running`

Check the pod and sidecar logs:

```sh
kubectl describe pod -n observability -l app=otel-collector
kubectl logs -n observability deployment/otel-collector -c vault-agent
kubectl logs -n observability deployment/otel-collector -c otel-collector
```

### Unauthenticated metrics returns `200`

That means Vault has been configured with unauthenticated metrics access. This
demo expects that setting to remain disabled.

Check the Vault listener configuration and remove:

```hcl
telemetry {
  unauthenticated_metrics_access = true
}
```

### Authenticated metrics returns `403`

Check the Vault policy and role:

```sh
kubectl exec vault-0 -- vault policy read vault-metrics-read
kubectl exec vault-0 -- vault read auth/kubernetes/role/otel-vault-metrics
```

Also confirm the pod is using the expected Kubernetes service account:

```sh
kubectl get pod -n observability -l app=otel-collector \
  -o jsonpath='{.items[0].spec.serviceAccountName}{"\n"}'
```

Expected:

```text
otel-collector
```

### Vault is sealed

This demo script initialises and unseals Vault during setup. If you reuse an old
cluster and Vault is sealed, use a fresh disposable cluster for the demo rather
than trying to repair stale state.

## Cleanup

If you used kind:

```sh
kind delete cluster --name vault-lab
```

If you used another disposable Kubernetes cluster, delete the cluster or remove
the demo resources using your normal cluster cleanup process.

## Key takeaway

The demo shows a secure pull-based metrics pattern:

```text
OTel collector -> Vault Agent token file -> Vault sys/metrics
```

The metrics endpoint remains protected. Access is granted through Kubernetes
auth and a narrow Vault policy rather than through unauthenticated listener
configuration.
