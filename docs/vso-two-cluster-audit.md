# Audit: Single-Cluster Assumptions in the Vault/VSO Demo

Governing plan: [`docs/vso-two-cluster-podman-plan.md`](./vso-two-cluster-podman-plan.md).

This audit inventories every place in the repo that currently assumes Vault,
the Vault Secrets Operator (VSO), and the demo app all run in one Kubernetes
cluster (`kind-vault-lab`, single `kubectl` context). It groups findings by
follow-up task number from `tasks/vso-two-cluster-podman/` so downstream work
knows exactly where to edit. This is a discovery task only — no migration
code changes are made here.

## How this audit was produced

- Read `docs/vso-two-cluster-podman-plan.md` in full as the source migration
  plan.
- Read `create_vault.sh`, `vso-demo.sh`, `demo.sh`, `Makefile`, `README.md`,
  `PODMAN_MIGRATION.md`, `presenterm/vso.md` in full.
- Searched for `kubectl `, `helm `, `vault.default.svc.cluster.local`,
  `auth/kubernetes`, `kind create/delete cluster`, `context`, `vso-demo`, and
  `vault-secrets-operator`.

## 1. Setup / cluster bootstrap assumptions

**Symptom:** every setup path creates or assumes a single kind cluster and
operates on "the current context" with no notion of a second cluster.

| Location | Assumption | Follow-up task |
| --- | --- | --- |
| `Makefile` `setup:` target — `bash create_vault.sh` run against "current kubectl context" (comment: "Running create_vault.sh on current kubectl context...") | One context, no cluster selection | 02, 09 |
| `README.md:200-203` — `kind create cluster --name vault-lab` then `kubectl config use-context kind-vault-lab` | Only one cluster (`vault-lab`) is ever created; VSO/app are assumed to live in the same cluster | 02, 12 |
| `README.md:626-628`, `README.md:686-689` — recovery/cleanup instructions (`kind delete/create cluster --name vault-lab`) | Same single-cluster name; no `vso-lab` cluster exists to delete/recreate | 02, 12 |
| `PODMAN_MIGRATION.md` (whole doc: lines 39-131) — "Full Demo Setup with Podman" section creates one cluster (`vault-lab`), sets one context, then runs `make setup` | Entire Podman migration guide is single-cluster | 02, 12 |
| `create_vault.sh` (top of file) — no `--context` flag anywhere; all `kubectl`/`helm` calls implicitly target whatever context is currently active | Script has zero notion of `VAULT_CONTEXT` / `VSO_CONTEXT`; installs Vault and VSO into the *same* current context | 02, 03, 04, 06 |
| `create_vault.sh` VSO block (`helm upgrade --install vault-secrets-operator ...`, VSO CRDs, `vso-demo-app` pod) all appended to the same script that sets up Vault, run against the same current context | VSO, its CRDs, and the demo app are installed into the Vault cluster, not a separate `kind-vso-lab` | 06, 08, 09 |

## 2. Networking assumptions (in-cluster DNS / addresses)

**Symptom:** every Vault address used by consumers (Agent Injector pod, OTel
collector, VSO `VaultConnection`) is the in-cluster Kubernetes Service DNS
name, which only resolves inside the Vault cluster.

| Location | Assumption | Follow-up task |
| --- | --- | --- |
| `create_vault.sh` — `vault-demo` pod script: `VAULT_ADDR="http://vault-internal:8200"` | In-cluster short DNS name; unreachable from a second cluster | 05 (documented as intentionally unchanged — this pod is Agent Injector demo, stays in Vault cluster) |
| `create_vault.sh` — otel-collector config: `targets: - vault.${NAMESPACE}.svc.cluster.local:8200` | In-cluster FQDN (`vault.default.svc.cluster.local`) | 05 (intentionally unchanged; otel-collector stays in Vault cluster) |
| `create_vault.sh` — VSO `VaultConnection.spec.address: http://vault.${NAMESPACE}.svc.cluster.local:8200` | **This is the one that must change.** VSO will run in `kind-vso-lab` and cannot resolve `vault.default.svc.cluster.local`, which only exists inside `kind-vault-lab` | 05, 06, 08 |
| `Makefile` `verify:` target — `curl ... "http://vault.default.svc.cluster.local:8200/v1/sys/metrics?..."` (two occurrences) | Runs from a pod (`vault-metrics-check`) inside the Vault cluster's `observability` namespace; stays valid as-is since that check stays same-cluster | 09 (confirm unchanged), 11 (two-cluster verification is additive, not a replacement) |
| `README.md:179`, `README.md:302-304`, `README.md:330`, `README.md:383` — narrative references to `vault.default.svc.cluster.local:8200` for OTel/metrics | Documents same-cluster otel-collector behavior | 12 (clarify these stay same-cluster; only the VSO `VaultConnection` address changes) |
| Plan's recommended fix: `VaultConnection.spec.address=http://host.containers.internal:8200`, exposed via Vault NodePort + kind `extraPortMappings` to host port 8200 | Not yet implemented anywhere in the repo | 02 (kind config/port mappings), 05 (Vault-side exposure), 06/08 (VSO-side `VaultConnection`) |

## 3. Authentication assumptions (`auth/kubernetes`, same-cluster TokenReview)

**Symptom:** there is exactly one Kubernetes auth mount (`auth/kubernetes`),
configured once against the Vault cluster's own API server, and every role
(including `vso-demo`) is bound to that same mount — meaning Vault can only
validate JWTs issued by its own cluster's API server.

| Location | Assumption | Follow-up task |
| --- | --- | --- |
| `create_vault.sh` — `vault auth enable kubernetes` (single mount, default path `kubernetes`) | Only one Kubernetes auth mount exists; no dedicated VSO mount | 07 |
| `create_vault.sh` — `vault write auth/kubernetes/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT` (executed via `kubectl exec` into the Vault pod, so `$KUBERNETES_SERVICE_HOST/PORT` resolve to the **Vault cluster's own** API server) | TokenReview target is hardcoded to the Vault cluster's in-cluster API server env vars; cannot validate VSO cluster service account JWTs | 07 |
| `create_vault.sh` — `vault write auth/kubernetes/role/vault-demo ...` and `.../role/otel-vault-metrics ...` | Roles bound to same-cluster mount `auth/kubernetes`; intentionally unchanged (these stay same-cluster, Agent Injector + OTel demo paths) | 04 (kept as-is), noted here as "intentionally unchanged" |
| `create_vault.sh` — `vault write auth/kubernetes/role/vso-demo ... bound_service_account_namespaces="$VSO_NAMESPACE"` | **Must move.** Currently VSO's role is bound to the same `auth/kubernetes` mount validated against the Vault cluster's API server. Once VSO runs in `kind-vso-lab`, its service account JWTs will be issued by `kind-vso-lab`'s API server/JWKS, which the existing mount cannot validate | 07 |
| `create_vault.sh` — `ClusterRoleBinding my-auth-delegator-binding` for `system:auth-delegator` bound to `ServiceAccount vault` in the Vault cluster — this grants Vault's own SA permission to call TokenReview against **its own** cluster's API server | Needs an equivalent mechanism for calling TokenReview against the **VSO cluster's** API server (plan's `vault-token-reviewer` ServiceAccount + RBAC created in the VSO cluster, with its token supplied to `auth/kubernetes-vso/config`) | 06, 07 |
| `README.md:95` — table entry `auth/kubernetes` — "Vault auth method used to validate Kubernetes service account tokens" (singular, undifferentiated) | Docs don't yet distinguish `auth/kubernetes` (same-cluster Agent Injector/OTel) from the new `auth/kubernetes-vso` (cross-cluster VSO) | 12 |
| `README.md:463`, `README.md:653` — narrative/diagram text and troubleshooting command `kubectl exec vault-0 -- vault read auth/kubernetes/role/vso-demo` describing VSO's role as living under `auth/kubernetes` | Must be updated to `auth/kubernetes-vso/role/vso-demo` and to explicit `--context` | 07, 10, 12 |
| `vso-demo.sh` — section 6 ("Least-privilege Vault identity"): `kubectl exec vault-0 -n ${NAMESPACE} -- vault read auth/kubernetes/role/vso-demo` | Same-cluster assumption baked into the demo script; also assumes `vault-0` and `vso-demo-app` pods are reachable from the same context with no `--context` flags | 07, 10 |
| `presenterm/vso.md` — slide 6, `kubectl exec vault-0 -n default -- vault read auth/kubernetes/role/vso-demo` | Same mount-path and same-cluster/no-context assumption, in slide form | 07, 12 |

## 4. Demo script assumptions (implicit current context)

**Symptom:** `vso-demo.sh` and `demo.sh` issue every `kubectl` call without an
explicit `--context`, and mix Vault-cluster and VSO-cluster resources as if
they were one cluster.

| Location | Assumption | Follow-up task |
| --- | --- | --- |
| `vso-demo.sh` `verify_ready()` — `kubectl get pod vault-0 -n "$NAMESPACE"`, `kubectl wait ... deployment -l app.kubernetes.io/name=vault-secrets-operator`, `kubectl get pod vso-demo-app -n "$VSO_NAMESPACE"` all run with no `--context`, assuming Vault, VSO, and the app pod are all in the one currently-active context | Needs `VAULT_CONTEXT`/`VSO_CONTEXT` env vars and explicit `--context` per call, split by which cluster owns the resource | 03, 10 |
| `vso-demo.sh` sections 2–6 — every `kubectl get|exec|wait` call (operator pods, CRDs, Secret, app pod, Vault role/policy reads) has no `--context` | Same issue throughout the whole guided demo | 03, 10 |
| `vso-demo.sh` section 7 (rotation) — `kubectl exec vault-0 -n "$NAMESPACE" -- vault kv put ...` and `kubectl get secret ${SECRET_NAME} -n "$VSO_NAMESPACE" ...` polling loop, no `--context` on either side | Rotation demo currently only works because both resources happen to be in one cluster; this is the crux of exit-criterion "Secret rotation ... appears in the VSO cluster native Secret" | 03, 10, 11 |
| `demo.sh` (Agent Injector / OTel demo, not VSO) — uses `NAMESPACE`/`OBSERVABILITY_NAMESPACE` conventions with no `--context` | Out of scope for two-cluster split (Agent Injector + OTel demo path intentionally stays entirely in the Vault cluster) — **intentionally unchanged** | none (explicitly out of scope; confirm in task 10 that only VSO-related demo flows are touched) |
| `Makefile` `vso-verify`, `vso-status`, `logs-vso` targets — `kubectl get/exec` with no `--context`, mixing `vault-secrets-operator-system`/`vso-demo` namespace queries and (indirectly, via `vso-demo.sh`) `vault-0` queries | Needs context-explicit rewiring once namespaces are split across clusters | 09 |
| `Makefile` `verify`, `status`, `logs-otel`, `logs-agent` targets | These stay single-context (Vault cluster only) since Agent Injector/OTel remain same-cluster — **intentionally unchanged**, but should gain an explicit `--context $(VAULT_CONTEXT)` for consistency once `VAULT_CONTEXT` exists | 09 |
| `presenterm/vso.md` — every `+exec` code block (`kubectl get pods -n vault-secrets-operator-system`, `kubectl get vaultconnection,vaultauth,vaultstaticsecret -n vso-demo`, `kubectl exec vault-0 -n default -- ...`, etc.) has no `--context` | Same as `vso-demo.sh`; slide deck needs matching context-explicit updates | 10, 12 |

## 5. Verification assumptions

**Symptom:** there is no target that proves two distinct clusters exist, that
networking/auth cross-cluster paths work, or that rotation crosses cluster
boundaries — verification today only ever checks one context.

| Location | Assumption | Follow-up task |
| --- | --- | --- |
| `Makefile` `verify:` target | Checks `kubectl config current-context` (singular) and pods in `default`/`observability` namespaces of that one context; no notion of a second cluster to check | 09, 11 |
| `Makefile` `vso-verify:` target | Checks VSO deployment, `vso-demo` namespace pods, `VaultStaticSecret` status, synced Secret value, and app pod env — all implicitly in one context; does not check that VSO is running in a *different* cluster from Vault, nor that cross-cluster TokenReview/reachability succeeded | 09, 11 |
| No `make verify-two-cluster` (or equivalent) target exists anywhere in the `Makefile` | Missing entirely; required by acceptance criteria: verify both contexts exist and differ, Vault reachable from VSO cluster, Vault can reach VSO API server for TokenReview, VSO operator available, `VaultStaticSecret` reconciles, Secret value correct, rotation crosses cluster boundary | 11 (new target) |
| `create_vault.sh` inline rotation/sync assertion loop (`VSO_SYNCED` check) and `vso-demo.sh` section 7 rotation-and-reset loops | Useful logic to reuse/adapt for two-cluster verification, but currently single-context | 11 |

## 6. Documentation assumptions

**Symptom:** README, `PODMAN_MIGRATION.md`, and the VSO design/slide deck all
describe and diagram a single cluster containing both Vault and VSO.

| Location | Assumption | Follow-up task |
| --- | --- | --- |
| `README.md:193-260` ("Bootstrap a fresh cluster" section) | Single `kind create cluster --name vault-lab` + single context bootstrap instructions | 12 |
| `README.md:427-500` (VSO architecture section, ASCII diagram, CRD table) — diagram shows `vault-secrets-operator-system`, `vso-demo`, and `default` (Vault) namespaces inside **one** cluster boundary | Diagram and prose must be redrawn as two cluster boundaries (`kind-vault-lab`, `kind-vso-lab`) connected by the documented external address and cross-cluster auth mount | 12 |
| `README.md:619-689` (recovery/troubleshooting/cleanup) | Single-cluster recovery (`kind delete/create cluster --name vault-lab`) and single-cluster cleanup instructions; no mention of `kind-vso-lab` | 12 |
| `PODMAN_MIGRATION.md` (entire document) | Describes only a single `vault-lab` cluster bootstrap with Podman; needs a two-cluster bootstrap section (`kind-vault-lab` + `kind-vso-lab`, `KIND_EXPERIMENTAL_PROVIDER=podman` for both) | 02, 12 |
| `docs/vso-demo-design.md` | Not yet audited line-by-line here beyond confirming its existence; likely describes the current single-cluster VSO design and will need a two-cluster addendum | 12 |
| `presenterm/vso.md` (entire deck) | Diagrams (slides "1", "1b") show one cluster boundary containing both Vault and VSO namespaces; all `+exec` commands lack `--context`; slide 6/7 reference `auth/kubernetes` and `vault-0`/`vso-demo-app` as if co-located | 10, 12 |

## Summary: files requiring follow-up edits, by category

- **Setup:** `create_vault.sh`, `Makefile` (`setup` target), `README.md` (bootstrap section), `PODMAN_MIGRATION.md` → tasks 02, 03, 04, 06, 09.
- **Networking:** `create_vault.sh` (VSO `VaultConnection` address), kind cluster configs (to be created), `README.md` (OTel/metrics narrative, left mostly as-is) → tasks 02, 05, 06, 08.
- **Auth:** `create_vault.sh` (`auth/kubernetes` enable/config/role blocks), `README.md` (auth table + troubleshooting commands), `vso-demo.sh` (role read command), `presenterm/vso.md` (slide 6) → task 07 (primary), 10, 12 (doc echoes).
- **Demos:** `vso-demo.sh`, `demo.sh` (confirm out of scope), `presenterm/vso.md`, `Makefile` (`vso-*` targets) → tasks 03, 09, 10.
- **Verification:** `Makefile` (`verify`, `vso-verify`, new `verify-two-cluster`) → task 11.
- **Docs:** `README.md`, `PODMAN_MIGRATION.md`, `docs/vso-demo-design.md`, `presenterm/vso.md` → task 12.

## Explicitly unchanged (intentionally single-cluster)

Per the plan, only the **VSO / VSO CRDs / demo app** path moves to a second
cluster. The following remain intentionally in the Vault cluster and are
**not** in scope for this migration:

- The Agent Injector demo path (`vault-demo` pod, `auth/kubernetes/role/vault-demo`, `demo.sh`).
- The OpenTelemetry collector / `vault-metrics-read` policy / `auth/kubernetes/role/otel-vault-metrics` path (`create_vault.sh` observability block, `Makefile` `verify`/`logs-otel`/`logs-agent` targets).
- The existing `auth/kubernetes` mount and its same-cluster roles (`vault-demo`, `otel-vault-metrics`) — these keep validating JWTs from the Vault cluster's own API server; only a **new**, additional mount (`auth/kubernetes-vso`) is added for the VSO cluster.

## Validation of this audit

Pattern searches performed and cross-checked against the tables above:

- `kubectl ` — found across `create_vault.sh`, `vso-demo.sh`, `demo.sh`, `Makefile`, `README.md`, `presenterm/vso.md`; every relevant occurrence lacking `--context` is captured in sections 1, 3, and 4.
- `helm ` — found in `create_vault.sh` (Vault, VSO installs) and `README.md`/`PODMAN_MIGRATION.md` (repo add/update); captured in section 1.
- `vault.default.svc.cluster.local` — found in `create_vault.sh` (otel-collector config) and `README.md` (four occurrences); captured in section 2, marked intentionally unchanged except for the VSO `VaultConnection` (which uses the equivalent `vault.${NAMESPACE}.svc.cluster.local` form and *does* need to change).
- `auth/kubernetes` — found in `create_vault.sh` (enable, config, three role writes), `README.md` (table + narrative + troubleshooting), `vso-demo.sh`, `presenterm/vso.md`; captured in section 3.
- `vso-demo` — found across `create_vault.sh`, `vso-demo.sh`, `Makefile`, `README.md`, `presenterm/vso.md`; captured in sections 1, 3, 4, 5, 6.
- `vault-secrets-operator` — found in `create_vault.sh` (helm install), `Makefile` (`vso-verify`/`vso-status`/`logs-vso`), `vso-demo.sh`, `presenterm/vso.md`; captured in sections 1, 4, 5, 6.
