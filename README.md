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

- **Podman Desktop** with Podman CLI installed (IBM standard container runtime).
- `kubectl` installed.
- `helm` installed.
- The HashiCorp Helm chart repository available.

### 2. Bootstrap two Podman-backed kind clusters

This repo runs **two** kind clusters, both backed by Podman:

- `kind-vault-lab` (`VAULT_CONTEXT`) — runs Vault (and the Agent Injector /
  OTel single-cluster demo) only.
- `kind-vso-lab` (`VSO_CONTEXT`) — runs the Vault Secrets Operator, its CRDs,
  and the `vso-demo-app` consumer only.

Vault is never installed in the VSO cluster, and VSO/its CRDs/app are never
installed in the Vault cluster. See [Architecture](#architecture-two-clusters)
below.

```sh
# Set Podman as the kind provider (add to ~/.zshrc or ~/.bashrc for persistence)
export KIND_EXPERIMENTAL_PROVIDER=podman

helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Create/validate both clusters (kind-vault-lab, kind-vso-lab) with the
# host port mappings the two clusters need to reach each other.
make clusters
```

> **Note:** See [PODMAN_MIGRATION.md](PODMAN_MIGRATION.md) for detailed
> Podman setup instructions and the two-cluster networking assumptions
> (`host.containers.internal`, host port mappings).

### 3. Build the demo environment

```sh
make setup
```

`make setup` runs the full two-cluster bootstrap end to end, targeting each
cluster context explicitly (never the ambient `kubectl config
current-context`):

1. `scripts/create-clusters.sh` — create/validate `kind-vault-lab` and
   `kind-vso-lab`.
2. `scripts/setup-vault-cluster.sh` — install and configure Vault (Agent
   Injector, `auth/kubernetes`, baseline secret, OTel path) in
   `VAULT_CONTEXT` only.
3. `scripts/setup-vso-cluster.sh` — install VSO and create the `vso-demo`
   namespace/service accounts in `VSO_CONTEXT` only.
4. `scripts/configure-vso-jwt-auth.sh` — configure Vault's dedicated
   `auth/jwt-vso` JWT/OIDC auth mount (in the Vault cluster), trusting the
   VSO cluster's JWKS endpoint and binding the exact issuer, audience, and
   subject VSO's service account presents. No reviewer service account or
   `token_reviewer_jwt` is created or stored anywhere in this default path.
5. `scripts/apply-vso-demo.sh` — apply the VSO CRDs
   (`VaultConnection`/`VaultAuth`/`VaultStaticSecret`) and `vso-demo-app` in
   the VSO cluster.

Each step is also available as its own Make target (`make clusters`,
`make setup-vault`, `make setup-vso`, `make configure-vso-auth`,
`make vso-apply`) if you want to run or re-run a single stage. All scripts
are idempotent.

A successful run ends with the single-cluster OTel path reporting:

```text
Unauthenticated sys/metrics HTTP status: 403
# HELP vault_audit_log_request vault_audit_log_request
OpenTelemetry collector is configured to scrape Vault sys/metrics with bearer_token_file=/vault/secrets/token.
```

and the VSO path reporting:

```text
Vault Secrets Operator demo is ready: kv-v2/vault-demo/mysecret is synced to native Secret vso-demo/vso-demo-mysecret.
```

### 4. Pre-flight check

Right before the customer joins:

```sh
make verify              # confirms the single-cluster OTel/Agent Injector demo (VAULT_CONTEXT)
make status              # shows those single-cluster demo resources
make vso-verify           # confirms the VSO demo is synced end-to-end (VSO_CONTEXT)
make verify-two-cluster   # full end-to-end proof across BOTH clusters (placement, network, auth, sync, rotation)
```

You're ready to present when, in the Vault cluster (`kind-vault-lab`), all
four single-cluster demo pods report `2/2 Running`:

```text
default/vault-0
default/vault-demo
observability/otel-collector-...
observability/vault-metrics-check
```

and, in the VSO cluster (`kind-vso-lab`), the VSO operator and `vso-demo-app`
are `Running`/`1/1` with the `VaultStaticSecret` reporting `Ready: True`.

`make verify-two-cluster` is the strongest single signal: it fails fast and
names the exact section (contexts, placement, network reachability, real
`auth/jwt-vso` JWT login — including proof that a wrong-audience or
wrong-service-account JWT is correctly rejected — synced Secret value, or
rotation) if anything is wrong.

### 5. Optional polish

- Open a second terminal with
  `kubectl --context kind-vault-lab get pods -A -w` and a third with
  `kubectl --context kind-vso-lab get pods -A -w` for live visual feedback
  from both clusters during the talk.
- If the clusters have been idle a while, re-run `make setup` — it's safe and
  fast on already-configured clusters.
- For a totally fresh start:
  `kind delete cluster --name vault-lab && kind delete cluster --name vso-lab`
  and return to step 2. (Ensure `KIND_EXPERIMENTAL_PROVIDER=podman` is set).

## Presenter commands

The repository includes a guided demo driver so the live demo is easier to run
than copying commands one by one.

```sh
make help                 # Show all available commands
make setup                # Full two-cluster bootstrap: clusters, Vault, VSO, cross-cluster auth, VSO apply
make clusters              # Create/validate kind-vault-lab and kind-vso-lab only
make setup-vault           # Install/configure Vault in VAULT_CONTEXT only
make setup-vso             # Install VSO + vso-demo namespace/SAs in VSO_CONTEXT only
make configure-vso-auth    # Configure auth/jwt-vso (JWT/OIDC) trusting the VSO cluster's JWKS endpoint
make vso-apply             # Apply VSO CRDs + vso-demo-app in VSO_CONTEXT
make check-vault-connectivity  # Prove a VSO-cluster pod can reach Vault at VAULT_ADDR
make verify-two-cluster    # Full end-to-end two-cluster proof (placement/network/auth/sync/rotation)
make verify      # Check the single-cluster OTel/Agent Injector demo is ready (VAULT_CONTEXT)
make demo        # Start the guided single-cluster live demo flow (Agent Injector/OTel)
make status      # Show the Kubernetes resources used by the single-cluster demo
make vso-verify  # Check the Vault Secrets Operator demo is ready (VSO_CONTEXT)
make vso-demo    # Start the guided VSO walkthrough across both clusters
make vso-status  # Show the VSO demo resources across both clusters
make vso-deck    # Run the VSO demo as a presenterm slide deck
```

Use `make demo` for the single-cluster Agent Injector/OTel customer walkthrough
(current `kubectl` context, normally `kind-vault-lab`). It pauses between
sections and prints each command before running it, so the audience can
follow both the story and the proof points. `make vso-demo` drives the
separate Vault Secrets Operator walkthrough the same way, but always targets
`VAULT_CONTEXT`/`VSO_CONTEXT` explicitly rather than the ambient context.

## Live demo flow (single-cluster Agent Injector/OTel demo)

`make demo` walks through these same steps, run against the Vault cluster
(`kind-vault-lab`). The commands below are included as a reference if you
prefer to drive the demo manually; make sure your current `kubectl` context
is `kind-vault-lab` (or pass `--context kind-vault-lab` to each command).

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

## Vault Secrets Operator (VSO) demo: two clusters, cross-cluster auth

This is a third, standalone demo (`make vso-demo`) that showcases a different
secret-delivery model from the Agent Injector used above — and, unlike the
single-cluster Agent Injector/OTel demo, it runs **Vault and VSO in two
separate Podman-backed kind clusters**:

- `kind-vault-lab` (`VAULT_CONTEXT`) — runs Vault only.
- `kind-vso-lab` (`VSO_CONTEXT`) — runs VSO, its CRDs, and `vso-demo-app` only.

Where the Agent Injector runs a **per-pod sidecar** that writes a secret to a
**file** inside one pod, the **Vault Secrets Operator** runs a single
**cluster-wide operator** that syncs Vault secrets into **native Kubernetes
`Secret` objects** via CRDs. Any workload then consumes those secrets the
standard Kubernetes way (`envFrom`, `secretKeyRef`, volume mounts) with **no
Vault annotations and no sidecar**.

### Why two clusters

A single-cluster VSO demo would only prove that VSO can talk to Vault when
both run in the same Kubernetes API server and pod network. This demo proves
the pattern customers actually need: **Vault and the consumers of its
secrets often live in different clusters** (a central Vault cluster serving
many downstream clusters). That requires:

- Vault reachable from **outside** its own cluster, at a host-level address
  (`VAULT_ADDR`, default `http://host.containers.internal:8200`) rather than
  the in-cluster DNS name `vault.default.svc.cluster.local`.
- A **separate** Vault auth mount, `auth/jwt-vso`, configured as a **JWT/OIDC**
  auth method rather than Kubernetes auth. Vault validates the VSO cluster's
  service account JWTs itself, cryptographically, using the VSO cluster's own
  JSON Web Key Set (JWKS, reachable at `VSO_API_ADDR`, default
  `https://host.containers.internal:6444/openid/v1/jwks`) — it never calls
  back into the VSO cluster's API server to ask "is this token still valid?"
  the way Kubernetes auth's TokenReview does. This is deliberately distinct
  from the pre-existing `auth/kubernetes` mount used by the Agent
  Injector/OTel demo, which validates JWTs from the Vault cluster only —
  mixing the two would let a token minted in one cluster be replayed against
  the other.

> **Why JWT/OIDC instead of Kubernetes auth's TokenReview here?** Kubernetes
> auth's cross-cluster form requires Vault to hold a standing credential (a
> `token_reviewer_jwt`) for a service account in the *other* cluster, plus a
> `system:auth-delegator` RBAC binding there, just so Vault can ask that
> cluster's API server to confirm a token is still valid on every login. JWT
> auth removes that dependency entirely: Vault fetches the VSO cluster's
> public signing keys (JWKS) once, then verifies tokens locally by checking
> the signature plus three claims — **issuer** (which cluster minted this
> token), **audience** (was this token minted for Vault specifically), and
> **subject** (exactly which service account). No reviewer credential is
> minted, rotated, or stored in Vault for this default path. The older
> `auth/kubernetes-vso` / TokenReview approach still exists in this repo
> (`scripts/configure-vso-kubernetes-auth.sh`) purely as a side-by-side
> comparison path — it is not the default and `make setup` never configures
> it.

### What the VSO demo proves

- Vault runs only in `kind-vault-lab`; VSO, its CRDs, and `vso-demo-app` run
  only in `kind-vso-lab`.
- The Vault Secrets Operator runs once, cluster-wide, in the VSO cluster.
- Three CRDs declaratively describe the pipeline:
  `VaultConnection` → `VaultAuth` → `VaultStaticSecret`.
- A pod in the VSO cluster can reach Vault at the documented external
  address (`VAULT_ADDR`) across the Podman host network.
- VSO authenticates through the dedicated `auth/jwt-vso` **JWT/OIDC** mount,
  which validates the VSO cluster service account's JWT cryptographically
  against that cluster's own JWKS (`VSO_API_ADDR`) and strictly checks its
  issuer, audience, and subject claims — no TokenReview call, and no
  reviewer JWT stored in Vault.
- **Negative-path proof**: `make verify-two-cluster` also mints a JWT with
  the wrong audience and a JWT for the wrong service account and confirms
  Vault **rejects** both — proving the claim binding is actually enforced,
  not just present.
- A Vault KV secret (`kv-v2/vault-demo/mysecret`) is materialized as a native
  Kubernetes `Secret` (`vso-demo/vso-demo-mysecret`) in the VSO cluster.
- A plain pod consumes it through `envFrom` with **zero** Vault configuration
  (the pod is `1/1`, not `2/2`, and carries no `vault.hashicorp.com`
  annotations).
- VSO authenticates with a least-privilege identity: the dedicated `vso-demo`
  JWT/OIDC role bound only to issuer `bound_issuer`, audience
  `bound_audiences=vault`, and subject
  `bound_subject=system:serviceaccount:vso-demo:vso-demo` (in the VSO
  cluster), using the existing `mysecret` policy.
- **Live rotation**: changing the value in Vault (in the Vault cluster)
  refreshes the native Secret in the VSO cluster automatically (within
  `refreshAfter`, set to 30s).

### Agent Injector vs Vault Secrets Operator

| Aspect | Agent Injector (sidecar / OTel demos, single-cluster) | Vault Secrets Operator (this demo, two clusters) |
| --- | --- | --- |
| Cluster topology | One cluster (`kind-vault-lab`) | Two clusters: Vault (`kind-vault-lab`) + VSO (`kind-vso-lab`) |
| Unit of deployment | Sidecar container per annotated pod | One operator Deployment per (VSO) cluster |
| Where the secret lands | A file inside the pod (`/vault/secrets/...`) | A native Kubernetes `Secret` object |
| App consumption | Reads a file | Standard `envFrom` / `secretKeyRef` / volume |
| Coupling to Vault | Pod needs Vault annotations | App needs **zero** Vault knowledge |
| Config mechanism | Pod annotations | Kubernetes CRDs |
| Pod shape | `2/2` (app + Vault Agent) | `1/1` (app only) |
| Auth method | `auth/kubernetes` (validates Vault-cluster JWTs via TokenReview) | `auth/jwt-vso` (JWT/OIDC — validates VSO-cluster JWTs cryptographically via JWKS, no TokenReview) |

### VSO architecture (two clusters)

```text
kind-vault-lab (VAULT_CONTEXT)              kind-vso-lab (VSO_CONTEXT)
---------------------------------------     ---------------------------------------
default/vault-0                             vault-secrets-operator-system
  auth/jwt-vso (JWT/OIDC)                     VSO controller -- reconcile loop
    -> role vso-demo
    -> bound_audiences: vault                vso-demo namespace
    -> bound_subject: vso-demo SA               VaultConnection -> VaultAuth ->
    -> policy mysecret                            VaultStaticSecret
  kv-v2/vault-demo/mysecret                    ServiceAccount: vso-demo

NodePort/host port mapping:
  :8200 -> host.containers.internal
---------------------------------------     ---------------------------------------

Step 1: VaultConnection points at VAULT_ADDR (http://host.containers.internal:8200)
        [VSO cluster] ----------------------------------------> [Vault cluster]

Step 2: VaultAuth logs in with the vso-demo pod's own SA JWT over auth/jwt-vso/login
        [VSO cluster] ----------------------------------------> [Vault cluster]

Step 3: Vault verifies the JWT locally: signature checked against the VSO
        cluster's JWKS (VSO_API_ADDR), then issuer/audience/subject claims
        checked against the role's strict bindings. No callback, no
        TokenReview, no reviewer JWT.

Step 4: On success, Vault returns a token scoped to the mysecret policy;
        VSO reads kv-v2/vault-demo/mysecret and writes/refreshes the native
        Kubernetes Secret vso-demo-mysecret every 30s.
        [Vault cluster] ---------------------------------------> [VSO cluster]

Step 5: The plain app pod vso-demo-app consumes the Secret via envFrom
        (standard Kubernetes API, no Vault config).
```

### Resources created for the VSO demo

`make setup` (via `scripts/setup-vault-cluster.sh`,
`scripts/setup-vso-cluster.sh`, `scripts/configure-vso-jwt-auth.sh`, and
`scripts/apply-vso-demo.sh`) provisions the VSO path across both clusters,
additively and idempotently:

| Resource | Cluster | Purpose |
| --- | --- | --- |
| Vault NodePort/host port mapping (`VAULT_ADDR`) | `kind-vault-lab` | Exposes Vault at `http://host.containers.internal:8200`, reachable from the VSO cluster. |
| `auth/jwt-vso` mount | `kind-vault-lab` | Dedicated JWT/OIDC auth mount that trusts the VSO cluster's JWKS, separate from `auth/kubernetes`. No reviewer service account or `token_reviewer_jwt` involved. |
| `auth/jwt-vso/role/vso-demo` | `kind-vault-lab` | Strictly binds issuer, `bound_audiences=vault`, and `bound_subject=system:serviceaccount:vso-demo:vso-demo` (VSO cluster) to the `mysecret` policy. |
| `oidc-discovery-reader` ClusterRole/ClusterRoleBinding | `kind-vso-lab` | Grants unauthenticated read of the VSO cluster's OIDC discovery document and JWKS endpoint, so Vault can fetch the public signing keys it needs to validate JWTs locally. |
| `vault-secrets-operator` Helm release (chart `1.4.0`) | `kind-vso-lab` | Runs the operator in `vault-secrets-operator-system`. |
| `vso-demo` namespace and service account | `kind-vso-lab` | Dedicated identity VSO authenticates as. |
| `VaultConnection/vso-demo-connection` | `kind-vso-lab` | How VSO reaches Vault: the external `VAULT_ADDR`, not an in-cluster URL. |
| `VaultAuth/vso-demo-auth` | `kind-vso-lab` | Uses `method: jwt`, mount `jwt-vso`, role `vso-demo`. |
| `VaultStaticSecret/vso-demo-mysecret` | `kind-vso-lab` | Syncs `kv-v2/vault-demo/mysecret` → native Secret. |
| `vso-demo/vso-demo-mysecret` Secret | `kind-vso-lab` | The materialized native Kubernetes Secret. |
| `vso-demo/vso-demo-app` pod | `kind-vso-lab` | Plain consumer using `envFrom` (no Vault config). |

> **Legacy comparison path (not installed by default):** this repo also
> keeps `scripts/configure-vso-kubernetes-auth.sh`, which configures the
> older `auth/kubernetes-vso` Kubernetes-auth/TokenReview mount plus a
> `vault-token-reviewer` service account and `system:auth-delegator`
> binding. `make setup` never runs it, and no Make target wires it in by
> default — it exists only so you can run it by hand
> (`bash scripts/configure-vso-kubernetes-auth.sh`, after
> `ENABLE_TOKEN_REVIEWER_AUTH=1 scripts/setup-vso-cluster.sh`) to show the
> two approaches side by side.

### Key VSO manifests

`VaultConnection` points at the external Vault address, not an in-cluster URL:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vso-demo-connection
  namespace: vso-demo
spec:
  address: http://host.containers.internal:8200
```

`VaultAuth` uses the dedicated `jwt-vso` JWT/OIDC mount — the pod's own
service account JWT is presented directly to Vault, and there is no
`token_reviewer_jwt` field anywhere in this manifest:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vso-demo-auth
  namespace: vso-demo
spec:
  vaultConnectionRef: vso-demo-connection
  method: jwt
  mount: jwt-vso
  jwt:
    role: vso-demo
    serviceAccount: vso-demo
    audiences:
      - vault
    tokenExpirationSeconds: 600
```

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

The VSO path is provisioned by the same `make setup` (or the individual
`make setup-vault`, `make setup-vso`, `make configure-vso-auth`,
`make vso-apply` targets). Once setup has completed:

```sh
make check-vault-connectivity  # Prove a VSO-cluster pod can reach Vault at VAULT_ADDR
make vso-verify                # Confirm the operator, CRDs, synced Secret, and app pod (VSO_CONTEXT)
make vso-demo                  # Start the guided VSO walkthrough across both clusters
make vso-status                # Show the VSO demo resources across both clusters
make verify-two-cluster        # Full end-to-end proof: placement, network, auth, sync, rotation
```

`make vso-demo` walks through nine sections, pausing between each: intro,
architecture, operator running, the CRDs, the synced native Secret, the plain
app consuming it, the least-privilege identity, a **live rotation**, and a
summary. Every command in the walkthrough targets `VAULT_CONTEXT` or
`VSO_CONTEXT` explicitly via `--context`, so it works correctly regardless of
your ambient `kubectl config current-context`. Set `NO_WAIT=true` to run it
without pauses (useful for a dry run):

```sh
NO_WAIT=true make vso-demo
```

A successful `make setup` (or `make vso-apply`) ends the VSO block with:

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

This demo's setup scripts initialise and unseal Vault (in `VAULT_CONTEXT`,
default `kind-vault-lab`) during setup. On first run they save the unseal
keys and root token to `vault-init-keys.json` (gitignored, `chmod 600`,
demo-only).

If the Vault pod restarts and comes back **sealed**, just re-run
`make setup` (or `make setup-vault` to only re-run the Vault cluster step).
The script detects the "initialized but sealed" state and automatically
unseals Vault from `vault-init-keys.json` — no cluster rebuild required.

If that file is missing (for example, the cluster was created by an older
version of the script that did not persist keys), the keys are unrecoverable.
Use a fresh disposable cluster:

```sh
kind delete cluster --name vault-lab
export KIND_EXPERIMENTAL_PROVIDER=podman
make clusters
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
make setup
```

(Ensure `KIND_EXPERIMENTAL_PROVIDER=podman` is set before creating the cluster).

> **Note:** `vault-init-keys.json` contains the root token and unseal keys in
> plaintext. It is fine for a disposable demo cluster but must never be used for
> anything real or committed to git.

### VSO Secret never appears (`vso-demo-mysecret`)

Check the `VaultStaticSecret` status and the operator logs, both in the VSO
cluster:

```sh
kubectl --context kind-vso-lab describe vaultstaticsecret vso-demo-mysecret -n vso-demo
kubectl --context kind-vso-lab logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator --tail=80
```

Common causes:

- The `vso-demo` role under `auth/jwt-vso` (in the **Vault** cluster, not
  `auth/kubernetes`) is missing, or its `bound_audiences`/`bound_subject`
  claim binding does not exactly match the JWT the `vso-demo/vso-demo`
  service account (in the **VSO** cluster) presents. Confirm with:

  ```sh
  kubectl --context kind-vault-lab exec vault-0 -- vault read auth/jwt-vso/role/vso-demo
  ```

- Vault cannot fetch the VSO cluster's JWKS — check that the
  `oidc-discovery-reader` ClusterRole/ClusterRoleBinding still exists in the
  VSO cluster (`kubectl --context kind-vso-lab get clusterrolebinding
  oidc-discovery-reader-binding`) and that `auth/jwt-vso/config`'s
  `jwks_url`/`bound_issuer` still match `VSO_OIDC_JWKS_URL`/`VSO_OIDC_ISSUER`.
- The `mysecret` policy does not grant read on
  `kv-v2/data/vault-demo/mysecret`.
- The `VaultConnection` still points at an in-cluster URL
  (`vault.default.svc.cluster.local`) instead of the external `VAULT_ADDR`
  (`http://host.containers.internal:8200`) — that only resolves inside the
  Vault cluster, never from the VSO cluster.
- Run `make check-vault-connectivity` to isolate whether this is a network
  reachability problem (see below) versus an auth/policy problem.

### VSO rotation does not update the Secret

The `VaultStaticSecret` uses `refreshAfter: 30s`, so allow up to ~30 seconds.
Force a faster check by inspecting the operator logs or re-reading the Secret
in the VSO cluster:

```sh
kubectl --context kind-vso-lab get secret vso-demo-mysecret -n vso-demo \
  -o jsonpath='{.data.username}' | base64 -d; echo
```

If a previous run left the value as `larry-rotated-N`, re-seed it in the
Vault cluster:

```sh
kubectl --context kind-vault-lab exec vault-0 -- vault kv put kv-v2/vault-demo/mysecret username=larry
```

### App pod value does not match the Secret after rotation

The `vso-demo-app` pod consumes the Secret through `envFrom`, so its environment
variables are captured when the pod starts. VSO refreshes the Kubernetes Secret
object after Vault changes; it does not mutate environment variables inside an
already-running process. Recreate the pod after the Secret syncs if you need the
process environment to pick up the latest value.

### Podman networking: a VSO-cluster pod cannot reach Vault

`make check-vault-connectivity` (or section 4 of `make verify-two-cluster`)
runs a throwaway pod in the VSO cluster that curls `VAULT_ADDR`
(`http://host.containers.internal:8200` by default). If that fails:

- Confirm `podman machine` is running (macOS): `podman machine list`. If it
  is stopped, `podman machine start` and re-run `make setup`.
- Confirm `KIND_EXPERIMENTAL_PROVIDER=podman` was set for **both**
  `kind create cluster` invocations (i.e. `make clusters` was run with it
  exported) — a mixed Docker/Podman pair of clusters will not share the
  `host.containers.internal` gateway.
- Confirm Vault's NodePort/host port mapping (`VAULT_HOST_PORT`, default
  `8200`) is actually bound on the host: `podman machine ssh -- sudo ss -ltnp | grep 8200`
  (or use the `kind` cluster's control-plane container port mapping).
- `host.containers.internal` is a Podman-specific DNS name for the host
  gateway. If you switch back to a Docker-backed provider, the equivalent is
  `host.docker.internal` — override `TWO_CLUSTER_HOST` accordingly rather
  than editing scripts.

### JWT/OIDC login through `auth/jwt-vso` fails

`auth/jwt-vso` validates the VSO cluster service account's JWT itself
(signature against the VSO cluster's JWKS, then issuer/audience/subject
claims) — there is no reviewer token to expire, because none is stored. If
login fails, it's almost always one of:

- **Wrong audience.** VSO's `VaultAuth` must request the `vault` audience
  (`spec.jwt.audiences: [vault]`) to match the role's `bound_audiences`.
- **Wrong subject.** The role's `bound_subject` is pinned to
  `system:serviceaccount:vso-demo:vso-demo`; a JWT from any other namespace
  or service account is rejected by design (see `make verify-two-cluster`,
  which proves this by deliberately minting and rejecting both).
- **JWKS unreachable.** Vault fetches the VSO cluster's public signing keys
  from `jwks_url` (`VSO_OIDC_JWKS_URL`, default
  `https://host.containers.internal:6444/openid/v1/jwks`). If that endpoint
  is unreachable or returns `403`, confirm the `oidc-discovery-reader`
  ClusterRole/ClusterRoleBinding still exists in the VSO cluster.

Re-run the configuration at any time — it's safe and idempotent:

```sh
make configure-vso-auth   # re-applies auth/jwt-vso/config and auth/jwt-vso/role/vso-demo
```

This does not disturb any other Vault configuration (including the
pre-existing `auth/kubernetes` mount).

> **Using the legacy `auth/kubernetes-vso` comparison path instead?** That
> path (`scripts/configure-vso-kubernetes-auth.sh`, not run by default) does
> mint a demo-only `token_reviewer_jwt` via `kubectl create token` for the
> `vault-token-reviewer` service account, with a default TTL of `8760h` (1
> year). If you've explicitly opted into that path and it later fails with
> an expired/invalid reviewer token, re-mint it with
> `bash scripts/configure-vso-kubernetes-auth.sh`.

### VSO reconciliation failures / CrashLoopBackOff in the VSO cluster

```sh
kubectl --context kind-vso-lab get pods -n vault-secrets-operator-system
kubectl --context kind-vso-lab describe pod -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator
kubectl --context kind-vso-lab logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator --tail=200
```

Look for JWT/OIDC errors (invalid audience/subject claim, or a JWKS fetch
failure — see the section above), Vault connection timeouts (see the Podman
networking section above), or `403`s from Vault (policy/role mismatch, see
above). If you're deliberately using the legacy `auth/kubernetes-vso`
comparison path, also check for TokenReview/RBAC errors (missing
`vault-token-reviewer`/`system:auth-delegator` binding — re-run
`ENABLE_TOKEN_REVIEWER_AUTH=1 scripts/setup-vso-cluster.sh`).

### Resource pressure from running two clusters

Two kind clusters (each with a control-plane container plus Vault or VSO
workloads) use noticeably more CPU/memory than one. If Podman machine
resources are constrained:

- Increase the Podman machine's CPU/memory before demoing:
  `podman machine set --cpus 4 --memory 8192` (stop/start the machine for
  this to take effect).
- Delete unrelated kind clusters you aren't using for this demo.
- `make vso-status` and `kubectl --context <ctx> top pods -A` (if
  `metrics-server` is installed) can help identify which workload is under
  pressure.
- If a laptop genuinely cannot run both clusters concurrently, this two-
  cluster topology is not optional for this demo — it is the entire point
  (Vault and VSO consumers must be provably separate clusters) — so plan
  demo hardware accordingly rather than collapsing back to one cluster.

## Cleanup

```sh
kind delete cluster --name vault-lab
kind delete cluster --name vso-lab
```

(With `KIND_EXPERIMENTAL_PROVIDER=podman` set, this cleans up both
Podman-based clusters.)

If you used other disposable Kubernetes clusters, delete them or remove the
demo resources using your normal cluster cleanup process.

## Key takeaway

The demo shows a secure pull-based metrics pattern:

```text
OTel collector -> Vault Agent token file -> Vault sys/metrics
```

The metrics endpoint remains protected. Access is granted through Kubernetes
auth and a narrow Vault policy rather than through unauthenticated listener
configuration.
