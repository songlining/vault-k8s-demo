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
observability/otel-collector ServiceAccount
        |
        | (1) SA JWT
        v
┌─────────────────────────── Pod: otel-collector ───────────────────────────┐
│                                                                           │
│  ┌────────────────────────┐                                               │
│  │ Vault Agent sidecar    │──(2) login with JWT──► Vault Kubernetes auth  │
│  │ (container)            │                                  |            │
│  └───────────┬────────────┘                                  | (3) verify │
│              |                                               v            │
│              | (4) writes Vault token to             Kubernetes           │
│              |     /vault/secrets/token              TokenReview API      │
│              v       (shared volume)                                      │
│  ┌────────────────────────┐                                               │
│  │ OpenTelemetry          │                                               │
│  │ collector (container)  │                                               │
│  └───────────┬────────────┘                                               │
│              |                                                            │
└──────────────┼────────────────────────────────────────────────────────────┘
               |
               └─(5) bearer token from /vault/secrets/token──► Vault /v1/sys/metrics
```

Both containers run inside the **same pod** and share the `/vault/secrets/`
volume. Vault Agent writes the token; the OTel collector reads it.

The OTel collector never needs a hard-coded Vault token. Vault Agent obtains
one at runtime by authenticating the pod's Kubernetes identity.

### Step-by-step walkthrough

1. **SA JWT (pod identity)** — The pod runs as the
   `observability/otel-collector` ServiceAccount. Kubernetes automatically
   projects a signed JSON Web Token for that ServiceAccount into the pod at
   `/var/run/secrets/kubernetes.io/serviceaccount/token`. The token is signed
   by the cluster's API server and carries claims like the namespace, service
   account name, and pod UID. This is the pod's cluster-issued identity — no
   static credentials required.
2. **Login with JWT** — The Vault Agent sidecar reads that JWT and sends it
   to Vault's Kubernetes auth method (`auth/kubernetes/login`) along with the
   role name `otel-vault-metrics`.
3. **Verify JWT** — Vault calls the Kubernetes TokenReview API to confirm
   the JWT is valid and belongs to the expected ServiceAccount. It then
   checks the role's `bound_service_account_names` and
   `bound_service_account_namespaces` constraints.
4. **Write Vault token** — On success, Vault issues a short-lived token
   carrying the `vault-metrics-read` policy. Vault Agent writes it to
   `/vault/secrets/token` on the shared volume and renews it before expiry.
5. **Authenticated scrape** — The OTel collector container reads the token
   from the same shared volume (via `bearer_token_file`) and uses it as the
   `X-Vault-Token` when scraping `/v1/sys/metrics?format=prometheus`.

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
make help        # Show available commands
make verify      # Check the cluster is ready for the demo
make demo        # Start the guided live demo flow
make status      # Show the Kubernetes resources used by the demo
make vso-verify  # Check the Vault Secrets Operator demo is ready
make vso-demo    # Start the guided VSO walkthrough
make vso-status  # Show the VSO demo resources
```

Use `make demo` for the customer walkthrough. It pauses between sections and
prints each command before running it, so the audience can follow both the story
and the proof points. `make vso-demo` drives the separate Vault Secrets Operator
walkthrough the same way.

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

## Vault Secrets Operator (VSO) demo

This is a third, standalone demo (`make vso-demo`) that showcases a different
secret-delivery model from the Agent Injector used above.

Where the Agent Injector runs a **per-pod sidecar** that writes a secret to a
**file** inside one pod, the **Vault Secrets Operator** runs a single
**cluster-wide operator** that syncs Vault secrets into **native Kubernetes
`Secret` objects** via CRDs. Any workload then consumes those secrets the
standard Kubernetes way (`envFrom`, `secretKeyRef`, volume mounts) with **no
Vault annotations and no sidecar**.

### What the VSO demo proves

- The Vault Secrets Operator runs once, cluster-wide.
- Three CRDs declaratively describe the pipeline:
  `VaultConnection` → `VaultAuth` → `VaultStaticSecret`.
- A Vault KV secret (`kv-v2/vault-demo/mysecret`) is materialized as a native
  Kubernetes `Secret` (`vso-demo/vso-demo-mysecret`).
- A plain pod consumes it through `envFrom` with **zero** Vault configuration
  (the pod is `1/1`, not `2/2`, and carries no `vault.hashicorp.com`
  annotations).
- VSO authenticates with a least-privilege identity: the dedicated `vso-demo`
  Kubernetes auth role bound only to the `vso-demo/vso-demo` service account,
  using the existing `mysecret` policy.
- **Live rotation**: changing the value in Vault refreshes the Kubernetes
  `Secret` automatically (within `refreshAfter`, set to 30s).

### Agent Injector vs Vault Secrets Operator

| Aspect | Agent Injector (sidecar / OTel demos) | Vault Secrets Operator (this demo) |
| --- | --- | --- |
| Unit of deployment | Sidecar container per annotated pod | One operator Deployment per cluster |
| Where the secret lands | A file inside the pod (`/vault/secrets/...`) | A native Kubernetes `Secret` object |
| App consumption | Reads a file | Standard `envFrom` / `secretKeyRef` / volume |
| Coupling to Vault | Pod needs Vault annotations | App needs **zero** Vault knowledge |
| Config mechanism | Pod annotations | Kubernetes CRDs |
| Pod shape | `2/2` (app + Vault Agent) | `1/1` (app only) |

### VSO architecture

```text
                      Vault (default/vault-0)
                        auth/kubernetes ── role: vso-demo ── policy: mysecret
                        kv-v2/vault-demo/mysecret
                                  ^
                                  | (3) login with SA JWT + read secret
                                  |
   vault-secrets-operator-system  |
        VSO controller ───reconcile loop
                                  |
   vso-demo namespace             |
        VaultConnection ─► VaultAuth ─► VaultStaticSecret
                                            |
                                            | (4) writes / refreshes
                                            v
                            Kubernetes Secret: vso-demo-mysecret
                                            |
                                            | (5) envFrom (standard K8s)
                                            v
                            Plain app pod: vso-demo-app (no Vault config)
```

### Resources created for the VSO demo

`create_vault.sh` also provisions the VSO path (additive and idempotent):

| Resource | Purpose |
| --- | --- |
| `vault-secrets-operator` Helm release (chart `1.4.0`) | Runs the operator in `vault-secrets-operator-system`. |
| `vso-demo` namespace and service account | Dedicated identity VSO authenticates as. |
| `vso-demo` Kubernetes auth role | Binds `vso-demo/vso-demo` to the `mysecret` policy. |
| `VaultConnection/vso-demo-connection` | How VSO reaches Vault (in-cluster URL). |
| `VaultAuth/vso-demo-auth` | Reuses the `kubernetes` auth method with role `vso-demo`. |
| `VaultStaticSecret/vso-demo-mysecret` | Syncs `kv-v2/vault-demo/mysecret` → native Secret. |
| `vso-demo/vso-demo-mysecret` Secret | The materialized native Kubernetes Secret. |
| `vso-demo/vso-demo-app` pod | Plain consumer using `envFrom` (no Vault config). |

### Key VSO manifests

`VaultStaticSecret` ties it all together:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: vso-demo-mysecret
  namespace: vso-demo
spec:
  vaultAuthRef: vso-demo-auth
  mount: kv-v2
  type: kv-v2
  path: vault-demo/mysecret
  refreshAfter: 30s
  destination:
    name: vso-demo-mysecret
    create: true
```

The consuming pod is pure Kubernetes — note the absence of any Vault annotations:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vso-demo-app
  namespace: vso-demo
spec:
  serviceAccountName: vso-demo
  containers:
    - name: app
      image: badouralix/curl-jq
      command: ["sh", "-c", "sleep infinity"]
      envFrom:
        - secretRef:
            name: vso-demo-mysecret
```

### Run the VSO demo

The VSO path is provisioned by the same `make setup` (it is folded into
`create_vault.sh`). Once setup has completed:

```sh
make vso-verify    # Confirm the operator, CRDs, synced Secret, and app pod
make vso-demo      # Start the guided VSO walkthrough
make vso-status    # Show the VSO demo resources
```

`make vso-demo` walks through nine sections, pausing between each: intro,
architecture, operator running, the CRDs, the synced native Secret, the plain
app consuming it, the least-privilege identity, a **live rotation**, and a
summary. Set `NO_WAIT=true` to run it without pauses (useful for a dry run):

```sh
NO_WAIT=true make vso-demo
```

A successful `make setup` ends the VSO block with:

```text
Vault Secrets Operator demo is ready: kv-v2/vault-demo/mysecret is synced to native Secret vso-demo/vso-demo-mysecret.
```

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

This demo script initialises and unseals Vault during setup. On first run it
saves the unseal keys and root token to `vault-init-keys.json` (gitignored,
`chmod 600`, demo-only).

If the Vault pod restarts and comes back **sealed**, just re-run `make setup`.
The script detects the "initialized but sealed" state and automatically unseals
Vault from `vault-init-keys.json` — no cluster rebuild required.

If that file is missing (for example, the cluster was created by an older
version of the script that did not persist keys), the keys are unrecoverable.
Use a fresh disposable cluster:

```sh
kind delete cluster --name vault-lab
kind create cluster --name vault-lab
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
make setup
```

> **Note:** `vault-init-keys.json` contains the root token and unseal keys in
> plaintext. It is fine for a disposable demo cluster but must never be used for
> anything real or committed to git.

### VSO Secret never appears (`vso-demo-mysecret`)

Check the `VaultStaticSecret` status and the operator logs:

```sh
kubectl describe vaultstaticsecret vso-demo-mysecret -n vso-demo
kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator --tail=80
```

Common causes:

- The `vso-demo` Kubernetes auth role is missing or not bound to the
  `vso-demo/vso-demo` service account. Confirm with:

  ```sh
  kubectl exec vault-0 -- vault read auth/kubernetes/role/vso-demo
  ```

- The `mysecret` policy does not grant read on
  `kv-v2/data/vault-demo/mysecret`.

### VSO rotation does not update the Secret

The `VaultStaticSecret` uses `refreshAfter: 30s`, so allow up to ~30 seconds.
Force a faster check by inspecting the operator logs or re-reading the Secret:

```sh
kubectl get secret vso-demo-mysecret -n vso-demo \
  -o jsonpath='{.data.username}' | base64 -d; echo
```

If a previous run left the value as `larry-rotated-N`, re-seed it:

```sh
kubectl exec vault-0 -- vault kv put kv-v2/vault-demo/mysecret username=larry
```

### App pod value does not match the Secret after rotation

The `vso-demo-app` pod consumes the Secret through `envFrom`, so its environment
variables are captured when the pod starts. VSO refreshes the Kubernetes Secret
object after Vault changes; it does not mutate environment variables inside an
already-running process. Recreate the pod after the Secret syncs if you need the
process environment to pick up the latest value.

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
