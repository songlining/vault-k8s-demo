# Design: Vault Secrets Operator (VSO) Demo

**Status:** Draft for review (superseded on cluster topology and auth method — see notes below)
**Author:** Larry Song
**Date:** 2026-05-30
**Target:** `make vso-demo`

> **Superseded note (cluster topology + auth method):** This document
> originally designed the VSO demo as a **single-cluster** scenario reusing
> the existing same-cluster `auth/kubernetes` mount (see "Auth method: Reuse
> `auth/kubernetes`" below). The **implemented** demo now runs Vault and VSO
> in **two separate Podman-backed kind clusters** (`kind-vault-lab` and
> `kind-vso-lab`) and authenticates VSO through a dedicated **JWT/OIDC**
> auth mount — `auth/jwt-vso` — that validates the VSO cluster's service
> account JWTs **cryptographically** against that cluster's own JWKS
> endpoint, with strict issuer/audience/subject claim binding and **no
> `token_reviewer_jwt` stored in Vault**. The older `auth/kubernetes-vso` /
> TokenReview approach described in the two-cluster plan
> ([`vso-two-cluster-podman-plan.md`](./vso-two-cluster-podman-plan.md))
> has been superseded by JWT/OIDC as the default production-oriented path;
> see [`vso-jwt-oidc-auth-plan.md`](./vso-jwt-oidc-auth-plan.md) for the
> full JWT/OIDC migration rationale and design.
>
> The rest of this document (CRD choice, rotation story, goals, non-goals,
> walkthrough narrative) remains accurate. For the current cluster topology,
> cross-cluster networking, and JWT/OIDC auth design, see
> [`vso-two-cluster-podman-plan.md`](./vso-two-cluster-podman-plan.md)
> (two-cluster topology) and [`vso-jwt-oidc-auth-plan.md`](./vso-jwt-oidc-auth-plan.md)
> (JWT/OIDC auth), and for user-facing instructions see
> [`vso-jwt-oidc-demo.md`](./vso-jwt-oidc-demo.md).
>
> **What is accurate vs. stale in this document:** the CRD pipeline
> (`VaultConnection` → `VaultAuth` → `VaultStaticSecret`), the rotation
> story, the app pod consumption model, and the Agent Injector vs VSO
> contrast table are all still accurate. The auth method details below —
> `method: kubernetes`, `mount: kubernetes`, `auth/kubernetes/role/vso-demo`,
> and the in-cluster `vault.default.svc.cluster.local` VaultConnection address
> — are **stale** and have been replaced by `method: jwt`, `mount: jwt-vso`,
> `auth/jwt-vso/role/vso-demo`, and the external `VAULT_ADDR`
> (`http://host.containers.internal:8200`) respectively. Read the auth and
> networking sections below as the *original* design, not the current
> implementation.

---

## 1. Purpose

Add a third guided demo scenario to this repo that showcases the **Vault Secrets
Operator (VSO)**. Today the repo demonstrates two patterns built on the **Vault
Agent Injector**:

1. The baseline KV **sidecar** demo (`vault-demo` pod).
2. The **OTel metrics** path (Agent sidecar writes a token file).

VSO is a fundamentally different delivery mechanism and the natural next demo:
instead of injecting a per-pod sidecar that writes secret material to a file
inside one pod, an **operator** runs cluster-wide and **syncs Vault secrets into
native Kubernetes `Secret` objects**. Any workload then consumes those secrets
the standard Kubernetes way (`envFrom`, `secretKeyRef`, volume mounts) with no
Vault-specific annotations or sidecars.

This demo will:

- Install VSO via its Helm chart.
- Authenticate VSO to the **existing** `auth/kubernetes` method (reuse, not a new
  auth backend).
- Sync the **existing** `kv-v2/vault-demo/mysecret` into a native K8s `Secret`
  using a `VaultStaticSecret` CRD.
- Prove a plain application pod can consume that secret with zero Vault
  awareness.
- Demonstrate **live secret rotation**: update the value in Vault and watch VSO
  refresh the Kubernetes `Secret` automatically.

### Scope decisions (confirmed)

| Decision | Choice | Rationale |
| --- | --- | --- |
| Secret type | **VaultStaticSecret** (static KV) + rotation | Lowest dependency; reuses the existing KV secret; rotation adds the "wow". |
| Auth method | **Reuse `auth/kubernetes`** | Consistent with the rest of the repo; minimal new config. |
| Narrative | **Standalone VSO walkthrough** | Self-contained story; does not depend on the audience having seen the sidecar demo. |

Out of scope for this iteration (possible future extensions): dynamic database
credentials (`VaultDynamicSecret`), PKI certificate issuance (`VaultPKISecret`),
and `rolloutRestartTargets` auto-rolling a consuming Deployment. Noted in
§10 Future Work.

---

## 2. Goals and non-goals

**Goals**

- A single command, `make vso-demo`, runs a guided walkthrough mirroring the
  style of the existing `make demo`.
- Idempotent setup that can be re-run safely, consistent with `create_vault.sh`.
- Clear proof points the audience can see: a native `Secret` appears, a plain
  pod reads it, and the value updates after a Vault change.
- No disruption to the existing two demos — VSO is **additive**.

**Non-goals**

- Replacing or modifying the Agent Injector demos.
- Production HA tuning of VSO.
- TLS between VSO and Vault (the demo Vault runs `tls_disable = 1`, matching the
  existing setup).

---

## 3. Background: VSO vs Agent Injector

| Aspect | Agent Injector (existing) | Vault Secrets Operator (new) |
| --- | --- | --- |
| Unit of deployment | Sidecar container per annotated pod | One operator Deployment per cluster |
| Where the secret lands | A file inside the pod (`/vault/secrets/...`) | A native Kubernetes `Secret` object |
| How the app consumes it | Reads a file (often a rendered template) | Standard `envFrom` / `secretKeyRef` / volume |
| Coupling to Vault | Pod needs Vault annotations | App needs **zero** Vault knowledge |
| Config mechanism | Pod annotations | Kubernetes **CRDs** (`VaultConnection`, `VaultAuth`, `VaultStaticSecret`) |
| Refresh model | Agent renews token / re-renders file | Operator reconciles on a `refreshAfter` interval |
| Best fit | Per-workload secret files, templating | Fleet-wide sync into K8s-native Secrets |

The teaching message: **same Vault, same Kubernetes auth, different delivery
model.** VSO turns Vault secrets into first-class Kubernetes Secrets.

---

## 4. Architecture

```text
                     ┌──────────────────────── Vault (default/vault-0) ─────────────────────┐
                     │  auth/kubernetes  (existing method)                                  │
                     │    └─ role: vso-demo  ── policy: mysecret (read kv-v2 demo secret)    │
                     │  kv-v2/vault-demo/mysecret   (existing secret)                       │
                     └─────────────────────────────▲────────────────────────────────────────┘
                                                    │ (3) login with SA JWT + read secret
                                                    │
   ┌──────────── vault-secrets-operator-system ─────┴───────────────────────────────────────┐
   │                                                                                          │
   │   VSO controller Deployment  ──reads CRDs──►  reconcile loop                             │
   │        ▲                                                                                 │
   │        │ (1) watches CRDs                                                                │
   └────────┼─────────────────────────────────────────────────────────────────────────────┘
            │
   ┌────────┼──────────────────── vso-demo namespace ──────────────────────────────────────┐
   │        │                                                                                │
   │  CRDs: VaultConnection ─► VaultAuth (k8s, role=vso-demo) ─► VaultStaticSecret           │
   │                                                              │                          │
   │                                                              │ (4) writes/refreshes     │
   │                                                              ▼                          │
   │                                         Kubernetes Secret: vso-demo-mysecret            │
   │                                                              │                          │
   │                                                              │ (5) envFrom / mount      │
   │                                                              ▼                          │
   │                                         Plain app pod: vso-demo-app (no Vault config)    │
   │                                                                                          │
   └──────────────────────────────────────────────────────────────────────────────────────┘
```

**Flow**

1. VSO controller watches the VSO CRDs cluster-wide.
2. A `VaultConnection` tells VSO how to reach Vault (in-cluster service URL).
3. A `VaultAuth` references the **existing** `auth/kubernetes` method and a new
   `vso-demo` role, using the `vso-demo` namespace's ServiceAccount JWT.
4. A `VaultStaticSecret` declares "read `kv-v2/vault-demo/mysecret` and
   materialize it as Secret `vso-demo-mysecret`, refreshing every N seconds."
5. The plain `vso-demo-app` pod consumes `vso-demo-mysecret` via `envFrom` — no
   sidecar, no annotations.

---

## 5. Vault configuration (added to `create_vault.sh`)

All additions are **idempotent** and follow the existing skip-if-present pattern.
The VSO path reuses `auth/kubernetes` and the existing `mysecret` policy, but
binds a **dedicated role** so VSO's identity is distinct and least-privilege.

### 5.1 Reuse existing pieces

- `auth/kubernetes` — already enabled.
- `kv-v2/vault-demo/mysecret` — already created.
- `mysecret` policy — already grants `read` on
  `kv-v2/data/vault-demo/mysecret`. VSO reuses this policy.

### 5.2 New role bound to the VSO service account

```sh
# vso-demo namespace + service account that VSO will authenticate as
kubectl create namespace vso-demo            # (idempotent guard in script)
kubectl create serviceaccount vso-demo \
  -n vso-demo                                # (idempotent guard in script)

# Dedicated Kubernetes auth role for the VSO workload
vault write auth/kubernetes/role/vso-demo \
  alias_name_source=serviceaccount_name \
  bound_service_account_names=vso-demo \
  bound_service_account_namespaces=vso-demo \
  policies=default,mysecret \
  ttl=1h
```

Rationale for a separate ServiceAccount/role rather than reusing `default`:
keeps VSO's Vault identity auditable and scoped, and avoids cross-wiring the
Agent Injector demo's `vault-demo` role.

> **Note on Vault version:** VSO works with the static KV pattern on Vault
> 1.21.x (cluster currently runs 1.21.2). No Enterprise features required.

---

## 6. VSO installation (Helm)

Installed in `create_vault.sh` after the existing OTel block, guarded for
idempotency.

```sh
helm repo add hashicorp https://helm.releases.hashicorp.com   # already added
helm repo update

helm upgrade --install vault-secrets-operator \
  hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system \
  --create-namespace \
  --version <pinned>     # pin to a known-good chart version
```

We will **pin the chart version** (consistent with the repo's habit of pinning
images, e.g. the OTel collector `0.114.0`). The exact pin is resolved during
implementation via `helm search repo hashicorp/vault-secrets-operator --versions`
and recorded in the script and README.

Default Helm values are sufficient for the demo; we will **not** use the chart's
optional default `VaultConnection`/`VaultAuth` values-file wiring, because we
want the CRDs to be visible, explicit objects the presenter can show and edit.

---

## 7. Kubernetes manifests (new, applied by `create_vault.sh`)

All live in the `vso-demo` namespace. Applied with `kubectl apply` (idempotent).

### 7.1 VaultConnection

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vso-demo-connection
  namespace: vso-demo
spec:
  address: http://vault.default.svc.cluster.local:8200
```

### 7.2 VaultAuth (reuse kubernetes auth, role vso-demo)

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vso-demo-auth
  namespace: vso-demo
spec:
  vaultConnectionRef: vso-demo-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: vso-demo
    serviceAccount: vso-demo
```

### 7.3 VaultStaticSecret (sync KV → native Secret)

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
    name: vso-demo-mysecret      # the native K8s Secret VSO creates/updates
    create: true
```

### 7.4 Consuming app (plain pod, no Vault config)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vso-demo-app
  namespace: vso-demo
spec:
  serviceAccountName: vso-demo
  restartPolicy: OnFailure
  containers:
    - name: app
      image: badouralix/curl-jq           # reuse image already pulled in repo
      command: ["sh", "-c", "sleep infinity"]
      envFrom:
        - secretRef:
            name: vso-demo-mysecret        # standard K8s secret consumption
```

The app reads `username` from the environment (sourced from the synced Secret)
with a plain `printenv username` / `env | grep` — no Vault token, no sidecar.

---

## 8. Demo script: `vso-demo.sh`

A new guided script that **reuses the existing helper conventions** from
`demo.sh` (`section`, `pause`, `p`, `pe`, `require_command`, color handling,
`NO_WAIT`). Same look and feel as `make demo`.

### Section outline

| # | Section | Proof point |
| --- | --- | --- |
| 0 | Intro / customer problem | "Deliver Vault secrets as native K8s Secrets, no per-pod sidecar." |
| 1 | Architecture | The operator + CRD model (ASCII diagram from §4). |
| 2 | Show the operator is running | `kubectl get pods -n vault-secrets-operator-system` → operator `Running`. |
| 3 | Show the CRDs | `kubectl get vaultconnection,vaultauth,vaultstaticsecret -n vso-demo`. |
| 4 | Show the synced native Secret | `kubectl get secret vso-demo-mysecret -n vso-demo -o jsonpath` → decode `username=larry`. |
| 5 | Plain app consumes it | `kubectl exec vso-demo-app -- printenv username` → `larry`, with no Vault annotations on the pod (`kubectl get pod vso-demo-app -o yaml \| grep -c vault.hashicorp.com` → 0). |
| 6 | Least-privilege identity | `kubectl exec vault-0 -- vault read auth/kubernetes/role/vso-demo` → bound to `vso-demo/vso-demo`, policy `mysecret`. |
| 7 | **Live rotation** | `vault kv put kv-v2/vault-demo/mysecret username=larry-rotated-1`, wait ≤ `refreshAfter`, re-read the K8s Secret → value changed automatically. |
| 8 | Summary | What we proved; contrast table; follow-up commands. |

### Rotation section detail (the highlight)

```sh
# Show current value in the K8s Secret
kubectl get secret vso-demo-mysecret -n vso-demo \
  -o jsonpath='{.data.username}' | base64 -d

# Change it in Vault
kubectl exec vault-0 -n default -- \
  vault kv put kv-v2/vault-demo/mysecret username=larry-rotated-1

# Wait for VSO to reconcile (refreshAfter=30s); poll the Secret
# Demo script polls up to ~45s and prints when the value flips.
kubectl get secret vso-demo-mysecret -n vso-demo \
  -o jsonpath='{.data.username}' | base64 -d   # -> larry-rotated-1
```

To keep the demo re-runnable, the script **resets the secret back to `larry`**
at the end of the rotation section (or setup re-seeds it), so repeated runs start
from a known state.

> **Live-demo timing:** `refreshAfter: 30s` keeps the wait short but real. The
> script polls and surfaces progress so there's no dead air; `NO_WAIT=true` still
> works for dry runs.

---

## 9. Makefile and verify changes

### New / changed targets

```make
vso-setup: ## Configure the VSO path on the current cluster (idempotent)
	@bash create_vault.sh        # VSO steps are part of the same idempotent script

vso-demo: ## Run the guided Vault Secrets Operator demo
	@bash vso-demo.sh
```

`vso-demo` is added to the help output automatically (the existing `help` target
greps `## ` comments).

### verify additions

Extend `make verify` (or add a `vso-verify`) to confirm:

- VSO operator pod is `Running` in `vault-secrets-operator-system`.
- `vso-demo-app` pod is `Running` in `vso-demo`.
- `VaultStaticSecret/vso-demo-mysecret` reports a synced status.
- Native Secret `vso-demo-mysecret` exists and decodes to the expected key.

Decision for review: fold VSO checks into the existing `verify`/`status`
targets, **or** add dedicated `vso-verify`/`vso-status` targets to keep each
demo independently checkable. **Recommendation: dedicated `vso-*` targets**, so
the three demos stay loosely coupled and each can be verified in isolation.

---

## 10. Setup integration strategy

VSO setup is folded into the **existing `create_vault.sh`** as an additive,
idempotent block placed **after** the OTel section, so a single `make setup`
provisions all three demos. Guard each step with the same "skip if present"
checks already used in the script:

- `helm upgrade --install` for VSO is inherently idempotent.
- Namespace / ServiceAccount creation guarded with `kubectl get ... || create`.
- `vault write auth/kubernetes/role/vso-demo` is declarative (safe to re-apply).
- CRD manifests applied with `kubectl apply` (declarative).
- Re-seed `kv-v2/vault-demo/mysecret` to `username=larry` so rotation demos start
  clean.

A short **readiness wait** mirrors the OTel block:

```sh
kubectl wait -n vault-secrets-operator-system \
  --for=condition=Available deployment \
  -l app.kubernetes.io/name=vault-secrets-operator --timeout=180s
kubectl wait -n vso-demo --for=condition=Ready pod/vso-demo-app --timeout=180s
```

Plus a post-setup assertion that the native Secret materialized (parallel to the
OTel script's auth/unauth metric assertions):

```sh
test "$(kubectl get secret vso-demo-mysecret -n vso-demo \
  -o jsonpath='{.data.username}' | base64 -d)" = "larry"
```

---

## 11. Files touched / added

| File | Change |
| --- | --- |
| `create_vault.sh` | **Add** idempotent VSO block: Helm install, `vso-demo` ns/SA, `vso-demo` role, CRD manifests, consuming pod, readiness waits, secret-materialized assertion. |
| `vso-demo.sh` | **New** guided demo driver (reuses `demo.sh` helper style). |
| `Makefile` | **Add** `vso-demo` (and recommended `vso-verify` / `vso-status`) targets. |
| `README.md` | **Add** a "Vault Secrets Operator demo" section: what it proves, architecture, CRDs, run instructions, troubleshooting. |
| `docs/vso-demo-design.md` | This design doc. |

No existing demo files' behavior changes; all edits are additive.

---

## 12. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| VSO chart/CRD API version drift (`v1beta1`) | Pin the chart version; verify CRD `apiVersion` against the installed chart during implementation. |
| Rotation wait causes dead air in live demo | `refreshAfter: 30s` + a polling loop that prints progress; `NO_WAIT` for dry runs. |
| Re-runs leave the secret in `larry-rotated-N` state | Setup re-seeds to `larry`; rotation section resets at the end. |
| Confusion with the Agent Injector demos | Standalone narrative + explicit contrast table in §3 and the summary. |
| `vault.default.svc.cluster.local` address assumes default ns | Matches existing scripts' assumption; parameterized via the same `NAMESPACE` convention. |
| Operator namespace name varies by chart version | Use the chart's documented default (`vault-secrets-operator-system`) and discover the deployment label at implementation time. |

---

## 13. Acceptance criteria

The feature is done when:

1. `make setup` on a clean cluster provisions Vault, both Agent-Injector demos,
   **and** the VSO path, ending with a "VSO secret materialized" success line.
2. `make vso-demo` runs end-to-end, pausing between sections, and visibly:
   - shows the operator running,
   - shows the three CRDs,
   - decodes the native `vso-demo-mysecret` Secret to `username=larry`,
   - shows a plain pod reading the value with **zero** Vault annotations,
   - performs a **live rotation** and shows the Secret value change.
3. The script is idempotent: a second `make setup` + `make vso-demo` works
   without manual cleanup.
4. The existing `make demo` and OTel/sidecar demos are unaffected.
5. README documents prerequisites, run steps, proof points, and troubleshooting.

---

## 14. Future work (explicitly deferred)

- `VaultDynamicSecret` with the database secrets engine (rotating Postgres
  creds) — high wow-factor follow-up.
- `VaultPKISecret` for auto-renewing TLS certificates.
- `rolloutRestartTargets` to auto-roll a consuming Deployment when the Secret
  changes.
- Transit-based encrypted sync / `VaultAuthGlobal` for multi-namespace fan-out.

---

## 15. Open questions for reviewer

1. **Verify targets:** fold VSO into existing `verify`/`status`, or add dedicated
   `vso-verify`/`vso-status`? (Design recommends dedicated.)
2. **Chart version pin:** any preference, or take the latest stable at
   implementation time and pin it?
3. **Rotation reset:** reset the secret to `larry` at the **end** of the demo, at
   the **start** of setup, or both? (Design currently does both for safety.)
4. **Single `make setup`** for all three demos (current plan) vs. a separate
   `make vso-setup` that only does the VSO block for faster iteration?
