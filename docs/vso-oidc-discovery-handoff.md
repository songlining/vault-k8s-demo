# Handoff: migrate the VSO demo to OIDC discovery

## Objective

Change the default two-cluster VSO authentication path from Vault JWT auth with
a directly configured `jwks_url` to Vault JWT auth with
`oidc_discovery_url`.

The end state must keep VSO authentication non-interactive (`role_type=jwt`),
retain strict issuer/audience/subject binding, use no Kubernetes TokenReview,
and store no `token_reviewer_jwt` in Vault.

This is a control-plane and Vault auth configuration change. Do **not** modify
the default VSO or Vault Helm charts to achieve it.

## Implementation update — 2026-07-17

Implementation and live acceptance are complete. With explicit approval, only
`kind-vso-lab` was recreated; `kind-vault-lab` and its Vault data were reused.

Implemented:

- the VSO kind template now uses kubeadm `v1beta4` list-style API-server
  arguments for the external ServiceAccount issuer and advertised JWKS URI;
- shared environment values derive discovery, issuer, and expected JWKS from
  one host/port source and reject inconsistent overrides;
- `auth/jwt-vso` now uses `oidc_discovery_url`, the VSO cluster CA,
  `bound_issuer`, and RS256 only, with no active direct `jwks_url`;
- the role preserves exact audience/subject binding and issues non-renewable
  batch tokens with only `mysecret`; this lets VSO re-authenticate without the
  default policy's `auth/token/renew-self` capability;
- verification now checks TLS-verified discovery metadata, decoded JWT claims,
  Vault mount configuration, complete effective policies, positive/negative
  login paths, VSO sync/rotation, and the existing Agent Injector/OTel paths;
- JWTs are streamed to `vault write` over stdin (`jwt=-`) rather than appearing
  in Kubernetes exec command arguments;
- stale pre-discovery VSO clusters are detected and rejected with an explicit
  recreation instruction; no script deletes them automatically;
- customer-facing material describes discovery followed by the advertised
  JWKS, while direct-JWKS experiment documents retain historical notes; and
- all repository test suites, shell syntax checks, ShellCheck for edited
  implementation scripts, and `git diff --check` pass. Both Mermaid diagrams
  render to non-empty SVGs with Mermaid CLI.

Live validation completed on 2026-07-17:

- discovery reported issuer `https://host.containers.internal:6444` and
  `jwks_uri=https://host.containers.internal:6444/openid/v1/jwks`, verified
  with the VSO cluster CA and hostname;
- minted JWT claims matched the external issuer, audience `vault`, and exact
  subject `system:serviceaccount:vso-demo:vso-demo`;
- Vault reported `oidc_discovery_url` and `bound_issuer` equal to the external
  issuer, `jwt_supported_algs=[RS256]`, and an empty direct `jwks_url`;
- positive login succeeded with a non-renewable batch token whose complete
  effective policy set was exactly `[mysecret]`; wrong-audience and
  wrong-ServiceAccount logins were rejected;
- `VaultStaticSecret` reached Ready, the native Secret matched Vault, rotation
  propagated, and the baseline value was restored; and
- the existing Agent Injector secret and authenticated OTel metrics checks in
  `kind-vault-lab` remained functional.

A live issue found during validation was that renewable service tokens without
Vault's default policy cannot call `auth/token/renew-self`, causing VSO to fail
before syncing. The role now issues non-renewable batch tokens, preserving the
`mysecret`-only policy while allowing VSO to re-authenticate normally.

## Pre-implementation repository and working-tree state (historical)

- Repository: `songlining/vault-k8s-demo`; branch: `main`.
- At handoff creation, the working tree already contained the README split,
  scenario guides, presenterm work, and other user changes. Those changes were
  preserved throughout implementation.
- The three scenario guides and this handoff remain untracked in the current
  worktree. `scripts/prepare-vso-deck-env.sh` and its startup test were listed
  as untracked in the original snapshot but were committed by the preceding
  deck-startup work before this migration began.
- No reset, restore, overwrite, or deletion of unrelated work was performed.

`git status --short` was captured before implementation and after validation.

## Pre-migration implementation (historical baseline)

Before this migration, the demo deliberately used direct JWKS mode because the default kind
ServiceAccount issuer and advertised JWKS URI are cluster-internal:

```text
JWT iss:
https://kubernetes.default.svc.cluster.local

Externally reachable VSO API:
https://host.containers.internal:6444

Current direct JWKS URL:
https://host.containers.internal:6444/openid/v1/jwks
```

Vault is configured in `scripts/configure-vso-jwt-auth.sh` with:

```sh
vault write "auth/${VSO_JWT_AUTH_MOUNT}/config" \
  jwks_url="${VSO_OIDC_JWKS_URL}" \
  jwks_ca_pem="${VSO_CA_PEM}" \
  bound_issuer="${VSO_OIDC_ISSUER}"
```

The default issuer and JWKS URL are defined in
`scripts/lib/two-cluster-env.sh`:

```sh
VSO_OIDC_ISSUER="${VSO_OIDC_ISSUER:-https://kubernetes.default.svc.cluster.local}"
VSO_OIDC_JWKS_URL="${VSO_OIDC_JWKS_URL:-${VSO_API_ADDR}/openid/v1/jwks}"
```

The kind template intentionally did not set `service-account-issuer` or
`service-account-jwks-uri`. This section records the baseline and is not a
statement about the completed implementation.

## Required end state (achieved)

The VSO cluster must be a self-consistent, externally reachable ServiceAccount
OIDC issuer:

```text
Issuer/base discovery URL:
https://host.containers.internal:6444

Discovery document:
https://host.containers.internal:6444/.well-known/openid-configuration

JWKS URI advertised by discovery:
https://host.containers.internal:6444/openid/v1/jwks
```

The following values must be identical where required:

```text
Vault oidc_discovery_url
= discovery document issuer
= JWT iss claim
```

The discovery document's `jwks_uri` must be reachable and TLS-verifiable from
Vault in `kind-vault-lab`.

## Implemented migration design

### 1. Configure the VSO kind API server

Update `scripts/kind/vso-lab-config.yaml.tmpl` under the existing
`ClusterConfiguration.apiServer` block.

The intended kube-apiserver arguments are conceptually:

```yaml
apiServer:
  certSANs:
    - "${TWO_CLUSTER_HOST}"
    - "localhost"
    - "127.0.0.1"
  extraArgs:
    service-account-issuer: "https://${TWO_CLUSTER_HOST}:${VSO_API_HOST_PORT}"
    service-account-jwks-uri: "https://${TWO_CLUSTER_HOST}:${VSO_API_HOST_PORT}/openid/v1/jwks"
```

Verify the exact kubeadm configuration syntax against the kind/Kubernetes
version used locally before finalising the template. Do not assume an old
kubeadm schema.

Keep the existing API-server port mapping and certificate SAN. The external
issuer hostname must be present in the serving certificate.

Update the stale direct-JWKS comments in:

- `scripts/kind/vso-lab-config.yaml.tmpl`
- `scripts/create-clusters.sh`

The existing `render_config()` substitutions already render
`${TWO_CLUSTER_HOST}` and `${VSO_API_HOST_PORT}`. Add substitutions only if new
placeholders are introduced.

### 2. Make the discovery URL and issuer explicit

Update `scripts/lib/two-cluster-env.sh` so the externally reachable URL is the
default issuer and discovery base.

Recommended shape:

```sh
VSO_OIDC_DISCOVERY_URL="${VSO_OIDC_DISCOVERY_URL:-${VSO_API_ADDR}}"
VSO_OIDC_ISSUER="${VSO_OIDC_ISSUER:-${VSO_OIDC_DISCOVERY_URL}}"
VSO_OIDC_JWKS_URL="${VSO_OIDC_JWKS_URL:-${VSO_OIDC_DISCOVERY_URL}/openid/v1/jwks}"
```

`VSO_OIDC_JWKS_URL` can remain as the expected/validation value even though
Vault will discover it rather than configure it directly.

Add `VSO_OIDC_DISCOVERY_URL` to environment summaries and override tests.

### 3. Switch the Vault JWT mount to discovery mode

Update `scripts/configure-vso-jwt-auth.sh` to write:

```sh
vault write "auth/${VSO_JWT_AUTH_MOUNT}/config" \
  oidc_discovery_url="${VSO_OIDC_DISCOVERY_URL}" \
  oidc_discovery_ca_pem="${VSO_CA_PEM}" \
  bound_issuer="${VSO_OIDC_ISSUER}" \
  jwt_supported_algs=RS256
```

Remove active `jwks_url` and `jwks_ca_pem` parameters. Vault permits only one
JWT verification source at a time.

Keep:

- auth method type `jwt`;
- role type `jwt`;
- `user_claim=sub`;
- `bound_audiences=vault`;
- exact `bound_subject`;
- `policies=mysecret`;
- no reviewer identity;
- no `token_reviewer_jwt`.

Update script comments, status output, and safe verification filtering to refer
to discovery mode. Continue suppressing CA and public-key material in output.

### 4. Retain discovery/JWKS endpoint RBAC

`scripts/setup-vso-cluster.sh` already grants unauthenticated `GET` access to
exactly:

```text
/.well-known/openid-configuration
/openid/v1/jwks
```

Keep this narrowly scoped RBAC. Vault's discovery client does not present a
Kubernetes bearer token when retrieving these documents.

Update comments from direct-JWKS-only wording to discovery plus JWKS wording.

### 5. Do not change VSO or Vault Helm charts

No functional changes should be required in:

- the VSO Helm chart or values;
- the Vault Helm chart or values;
- `VaultConnection`;
- `VaultAuth` method, mount, role, ServiceAccount, or audience;
- `VaultStaticSecret`;
- the application pod;
- the `mysecret` policy;
- the JWT role's audience or subject bindings.

`VaultAuth` remains conceptually:

```yaml
method: jwt
mount: jwt-vso
jwt:
  role: vso-demo
  serviceAccount: vso-demo
  audiences:
    - vault
  tokenExpirationSeconds: 600
```

## Pre-migration tests that enforced the opposite design

These tests were updated test-first because they locked in direct JWKS mode and the
cluster-internal issuer:

1. `scripts/tests/test-vso-lab-kind-config-validation.sh`
   - previously asserted that `service-account-issuer` and
     `service-account-jwks-uri` were absent;
   - now requires both externally reachable settings, the existing
     certificate SAN, and stable API-server port mapping.

2. `scripts/tests/test-configure-vso-jwt-auth-validation.sh`
   - previously rejected active `oidc_discovery_url` and required `jwks_url`;
   - now requires `oidc_discovery_url`,
     `oidc_discovery_ca_pem`, `bound_issuer`, and `jwt_supported_algs=RS256`;
   - rejects active `jwks_url` and `jwks_ca_pem` configuration;
   - retains checks that no TokenReview mount or reviewer token is used.

3. `scripts/tests/test-two-cluster-env-validation.sh`
   - changed the default issuer expectation from
     `https://kubernetes.default.svc.cluster.local` to `VSO_API_ADDR`;
   - added default, override, and exported-summary checks for
     `VSO_OIDC_DISCOVERY_URL`;
   - retains the derived expected JWKS URL check.

The following related suites were also updated or retained as regressions:

- `scripts/tests/test-create-clusters-validation.sh`
- `scripts/tests/test-setup-vso-cluster-validation.sh`
- `scripts/tests/test-verify-two-cluster-validation.sh`
- `scripts/tests/test-vso-demo-validation.sh`
- `scripts/tests/test-vso-deck-validation.sh`
- `scripts/tests/test-vso-docs-validation.sh`

The asserted contracts were changed to the new design without weakening the
security or placement checks.

## Runtime verification procedure (completed 2026-07-17)

Changing the ServiceAccount issuer was a kube-apiserver creation-time change.
After explicit user confirmation, only the disposable `kind-vso-lab` was
recreated; `kind-vault-lab` was retained. The following checks were then run
and passed.

### Discovery metadata

From a location using the VSO cluster CA, retrieve:

```text
https://host.containers.internal:6444/.well-known/openid-configuration
```

Assert:

```text
.issuer == VSO_OIDC_DISCOVERY_URL
.jwks_uri == VSO_OIDC_DISCOVERY_URL + "/openid/v1/jwks"
```

Do not use `-k`/`--insecure` as the final validation. Validate with the expected
CA and hostname.

### Token claims

Mint a token for `vso-demo/vso-demo` with audience `vault` and confirm:

```text
iss == VSO_OIDC_ISSUER
aud contains "vault"
sub == "system:serviceaccount:vso-demo:vso-demo"
```

Do not print or persist the complete JWT.

### Vault mount

Read `auth/jwt-vso/config` safely and confirm:

```text
oidc_discovery_url == VSO_OIDC_DISCOVERY_URL
bound_issuer == VSO_OIDC_ISSUER
jwt_supported_algs contains RS256
jwks_url is unset
```

Do not print CA material.

### Positive and negative authentication

Confirm:

- the correct ServiceAccount JWT logs in successfully;
- a wrong-audience JWT is rejected;
- a JWT for the wrong ServiceAccount is rejected;
- the issued Vault token has only the intended `mysecret` policy.

### End-to-end VSO behaviour

Confirm:

- `VaultStaticSecret` reaches `Ready=True`;
- `vso-demo-mysecret` matches the Vault KV value;
- secret rotation still refreshes the Kubernetes Secret;
- the sidecar and OTel scenarios in `kind-vault-lab` remain unaffected.

Run the existing end-to-end verifier after updating its assertions:

```sh
make verify-two-cluster
```

## Documentation updates

Update current customer-facing material to describe discovery mode:

- `README.md`
- `docs/vso-jwt-oidc-demo.md`
- `PODMAN_MIGRATION.md`
- `vso-demo.sh`
- `presenterm/vso.md`
- comments and output in current setup/configuration scripts

Preserve historical evidence in:

- `docs/vso-jwt-oidc-auth-spike-01.md`
- `docs/vso-jwt-oidc-auth-task-02.md`
- `docs/vso-jwt-oidc-auth-plan.md`

Do not rewrite the historical experiment as though it never occurred. Add a
prominent follow-up or superseded note explaining that the original direct-JWKS
decision was correct for the then-default kind issuer, and that the demo later
changed the API-server issuer/JWKS metadata to make discovery intentionally
self-consistent.

Keep the Mermaid architecture and sequence diagrams valid. Validate both with
Mermaid CLI after editing.

## Acceptance criteria

- [x] VSO and Vault Helm charts are unchanged for this migration.
- [x] The VSO kind API server issues JWTs with the externally reachable issuer.
- [x] Discovery metadata is self-consistent and TLS-verifiable.
- [x] Vault uses `oidc_discovery_url`, not active direct `jwks_url` config.
- [x] Vault restricts signing algorithms to RS256.
- [x] Issuer, audience, and subject remain strictly bound.
- [x] No TokenReview call or reviewer JWT is introduced.
- [x] Positive login succeeds.
- [x] Wrong audience and wrong ServiceAccount logins fail.
- [x] VSO sync and rotation pass end to end.
- [x] Sidecar and OTel paths remain functional.
- [x] Targeted static tests and full relevant validation pass.
- [x] Both Mermaid diagrams render successfully.
- [x] `git diff --check` passes.
- [x] Existing unrelated working-tree changes are preserved.

## Suggested validation commands

Run targeted tests first:

```sh
bash scripts/tests/test-vso-lab-kind-config-validation.sh
bash scripts/tests/test-two-cluster-env-validation.sh
bash scripts/tests/test-configure-vso-jwt-auth-validation.sh
bash scripts/tests/test-create-clusters-validation.sh
bash scripts/tests/test-setup-vso-cluster-validation.sh
bash scripts/tests/test-verify-two-cluster-validation.sh
bash scripts/tests/test-vso-docs-validation.sh
```

Run shell syntax checks for every edited shell script:

```sh
bash -n scripts/create-clusters.sh
bash -n scripts/setup-vso-cluster.sh
bash -n scripts/configure-vso-jwt-auth.sh
bash -n scripts/verify-two-cluster.sh
```

Render all Mermaid diagrams in the VSO guide and verify two non-empty SVGs are
produced. Finish with:

```sh
git diff --check
git status --short
```

## Production notes

The demo value `host.containers.internal` is not a production identity URL. A
production cluster should use a unique, stable HTTPS issuer such as:

```text
https://k8s-cluster-a.identity.example.com
```

Production requirements include:

- trusted TLS with no verification bypass;
- stable DNS and highly available discovery/JWKS hosting;
- a unique issuer per Kubernetes cluster;
- overlapping public keys during ServiceAccount signing-key rotation;
- automated CA and metadata lifecycle management;
- network reachability from every Vault HA node;
- short-lived ServiceAccount and Vault tokens;
- monitoring for discovery/JWKS reachability and authentication failures;
- a dedicated Vault JWT auth mount per Kubernetes cluster where practical.

A hardened reverse proxy or cached discovery/JWKS endpoint can publish only the
OIDC metadata and public keys, avoiding exposure of the full Kubernetes API
server. If a managed Kubernetes provider already supplies a stable reachable
issuer, use that provider issuer rather than changing Helm charts or VSO.

## Authoritative references

- [Vault JWT auth](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Vault JWT auth API](https://developer.hashicorp.com/vault/api-docs/auth/jwt)
- [Kubernetes ServiceAccount issuer discovery](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-issuer-discovery)
