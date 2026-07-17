# VSO JWT/OIDC Auth — Task 02: kind VSO Cluster Issuer/JWKS Configuration

> **Historical record — superseded implementation:** The no-change decision
> below was correct while kind used its cluster-internal default issuer and the
> demo configured Vault with direct `jwks_url`. The later OIDC-discovery
> migration intentionally configures an externally reachable ServiceAccount
> issuer and advertised JWKS URI in the VSO kind template. See
> [`vso-oidc-discovery-handoff.md`](./vso-oidc-discovery-handoff.md). The
> original decision record remains unchanged below.

Evidence and decision record for
`tasks/vso-jwt-oidc-auth/02-configure-kind-oidc-issuer.md`.
Builds directly on
[`docs/vso-jwt-oidc-auth-spike-01.md`](./vso-jwt-oidc-auth-spike-01.md).

## Decision

**No kind config template change is required.** Both
`scripts/kind/vault-lab-config.yaml.tmpl` and
`scripts/kind/vso-lab-config.yaml.tmpl` keep kubeadm's default
`service-account-issuer` (`https://kubernetes.default.svc.cluster.local`)
with no `apiServer.extraArgs.service-account-issuer` /
`service-account-jwks-uri` override.

This matches the task's own skip condition:

> Skip file changes in this task if Phase 1 proves the existing kind
> configuration is already sufficient.

Phase 1 (task 01) proved it is sufficient, via the `jwks_url` + `bound_issuer`
strategy documented in `docs/vso-jwt-oidc-auth-spike-01.md`:

- `auth/jwt-vso` will be configured with
  `jwks_url=https://host.containers.internal:6444/openid/v1/jwks` (the VSO
  cluster's API server, reachable and TLS-valid via the existing
  `certSANs` patch and `apiServerPort` host mapping already present in
  `scripts/kind/vso-lab-config.yaml.tmpl`) plus `jwks_ca_pem` (VSO cluster
  CA) for TLS trust.
- `bound_issuer` will be set to the actual (cluster-internal, non-reachable)
  `iss` claim value. `bound_issuer` is a pure string comparison in Vault's
  JWT auth backend — it is never fetched or resolved — so the issuer string
  itself does not need to be externally reachable.
- Because `jwks_url` mode is used (not `oidc_discovery_url`), Vault never
  fetches `${issuer}/.well-known/openid-configuration`, so the issuer never
  needs to be a routable URL, and no `service-account-issuer` override is
  needed to make it one.

Given this, changing kind's `service-account-issuer`/`service-account-jwks-uri`
would add complexity (a new API server flag surface, a new thing to keep in
sync with `TWO_CLUSTER_HOST`/`VSO_API_HOST_PORT`, and a new failure mode if
kubeadm rejects the flags) with no corresponding benefit for this demo.

## Deliverables completed

- **No template change** to `scripts/kind/vso-lab-config.yaml.tmpl` service
  account issuer/JWKS API server args (per the skip condition above) —
  only an explanatory comment was added (see below), not a functional
  change.
- **Explanatory comments added** (functional behavior unchanged):
  - `scripts/create-clusters.sh` header comment now documents that neither
    kind config template overrides `service-account-issuer`, and why, with
    a pointer to this doc and the spike.
  - `scripts/kind/vso-lab-config.yaml.tmpl` now has an inline comment next
    to the existing `certSANs` explanation documenting the same decision
    at the point where a future reader would look for it.
- **Evidence** that newly minted VSO service account tokens still use the
  intended issuer and that the JWKS endpoint remains reachable — re-run
  live against the current `kind-vso-lab` / `kind-vault-lab` clusters (see
  below), confirming the task 01 spike findings still hold unchanged.

## Re-validation evidence (live, re-run for this task)

### 1. Cluster state unchanged

```text
$ podman ps -a
CONTAINER ID  IMAGE                          ... NAMES
...                                          ... vault-lab-control-plane
...                                          ... vso-lab-control-plane
```

Both clusters were already running from the task 01 spike session; no
recreation was needed or performed (per the task's "Recreate or validate"
step — validated, not recreated, since no config changed).

### 2. Freshly minted `vso-demo` token still carries the expected issuer

```bash
kubectl --context kind-vso-lab create token vso-demo \
  -n vso-demo --audience vault --duration 10m
```

Decoded payload (fresh mint for this task):

```json
{
  "aud": ["vault"],
  "iss": "https://kubernetes.default.svc.cluster.local",
  "sub": "system:serviceaccount:vso-demo:vso-demo",
  "kubernetes.io": {
    "namespace": "vso-demo",
    "serviceaccount": { "name": "vso-demo", "uid": "9183679b-f4ff-4bad-8d7a-d0df5d24ba52" }
  }
}
```

`iss`/`sub`/`aud` match the task 01 spike evidence exactly — the intended
externally-reachable issuer/JWKS binding plan (`bound_issuer` = this `iss`
string, `jwks_url` = the mapped API server address) is unaffected by cluster
uptime/token freshness.

### 3. JWKS/discovery still reachable from the host and from the Vault cluster

From the host:

```text
$ curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:6444/.well-known/openid-configuration
200
$ curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:6444/openid/v1/jwks
200
```

From inside the Vault cluster (`vault-0`), using the VSO cluster CA copied
in via the same pattern as `scripts/configure-vso-kubernetes-auth.sh`:

```text
-- discovery --
  HTTP/1.1 200 OK
-- jwks --
  HTTP/1.1 200 OK
```

Both endpoints remain reachable and TLS-valid over
`https://host.containers.internal:6444/...`, confirming the
`certSANs`/`apiServerPort` mapping already in
`scripts/kind/vso-lab-config.yaml.tmpl` is sufficient — no change needed.

### 4. `oidc-discovery-reader` RBAC still present

```text
$ kubectl --context kind-vso-lab get clusterrole oidc-discovery-reader -o name
clusterrole.rbac.authorization.k8s.io/oidc-discovery-reader
$ kubectl --context kind-vso-lab get clusterrolebinding oidc-discovery-reader-binding -o name
clusterrolebinding.rbac.authorization.k8s.io/oidc-discovery-reader-binding
```

This confirms the RBAC grant applied out-of-band during the task 01 spike is
still in place on the live `kind-vso-lab` cluster. **This remains a known
gap, unchanged by this task**: it is not yet captured in any script
(`scripts/setup-vso-cluster.sh` is the intended home) and will be lost if
`kind-vso-lab` is recreated from scratch. Task 01's reflection already
flags this for task 04/05; this task does not change that ownership.

## Acceptance criteria mapping

| Criterion | Status |
|---|---|
| VSO cluster issuer URL is compatible with Vault JWT auth | Met — via `bound_issuer` string match, no reachability needed |
| JWKS endpoint URL is reachable from the Vault cluster | Met — re-confirmed live, `HTTP 200` from `vault-0` |
| TLS/SAN behavior documented, validates cleanly | Met — existing `certSANs` patch already covers `TWO_CLUSTER_HOST`; no gap found |
| Existing Podman/kind networking remains functional | Met — no config changed, both clusters unaffected |

## Unit test

`scripts/tests/test-vso-lab-kind-config-validation.sh` asserts:

1. The rendered VSO kind config template does **not** set
   `service-account-issuer` / `service-account-jwks-uri` API server
   `extraArgs` (documents/locks in the "not required" decision so a future
   change doesn't silently reintroduce issuer complexity without updating
   this doc).
2. The template still includes the `certSANs` entry for
   `${TWO_CLUSTER_HOST}` and the `apiServerPort` mapping to
   `${VSO_API_HOST_PORT}` (the two things Vault's `jwks_url` reachability
   actually depends on).
3. `scripts/create-clusters.sh` and the template both reference this
   decision doc / the spike doc in their comments (keeps the "why" adjacent
   to the "what" for future maintainers).

Run directly:

```bash
scripts/tests/test-vso-lab-kind-config-validation.sh
```
