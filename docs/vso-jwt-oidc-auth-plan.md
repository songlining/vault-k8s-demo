# VSO JWT/OIDC Authentication Migration Plan

## Objective

Update the two-cluster Vault Secrets Operator (VSO) demo to use Vault's JWT/OIDC auth method instead of the current Kubernetes auth + TokenReview reviewer-token pattern.

Current demo:

```text
VSO service account JWT
  -> Vault auth/kubernetes-vso/login
  -> Vault calls VSO cluster TokenReview API
  -> VSO API server validates the JWT
  -> Vault checks the Kubernetes auth role
  -> Vault issues a Vault token
```

Target demo:

```text
VSO service account JWT
  -> Vault auth/jwt-vso/login
  -> Vault validates JWT signature using VSO cluster issuer/JWKS
  -> Vault checks issuer, audience, and subject claims
  -> Vault issues a Vault token
```

The updated demo should show the production-oriented pattern: Vault validates VSO service account JWTs directly using the VSO cluster's OIDC issuer/JWKS, with no reviewer JWT stored in Vault.

---

## Why change

The current TokenReview-based approach is clear for explaining Kubernetes auth, but it requires Vault to store a `token_reviewer_jwt` for a service account in the VSO cluster:

```text
vault-token-reviewer + system:auth-delegator
```

That token has a lifecycle and must be refreshed/rotated. This is acceptable for a demo, but it is an operational burden in production.

JWT/OIDC auth removes that reviewer-token dependency. Vault trusts the VSO cluster's issuer metadata and signing keys, then authorizes login using strict JWT claim bindings.

Key production security requirement:

```text
Only accept tokens with:
- the expected issuer
- the expected audience, e.g. vault
- the expected subject, e.g. system:serviceaccount:vso-demo:vso-demo
```

Loose claim binding is the main risk. A role that accepts any token from the issuer, or any token with the right audience, could accidentally allow the wrong service account to authenticate.

---

## Target architecture

### Current auth path

```text
auth/kubernetes-vso
  kubernetes_host     = https://host.containers.internal:6444
  kubernetes_ca_cert  = VSO cluster CA
  token_reviewer_jwt  = JWT for vso-demo/vault-token-reviewer

Vault login:
  role = vso-demo
  jwt  = vso-demo service account token

Vault validates by calling:
  TokenReview @ VSO_API_ADDR
```

### Target auth path

```text
auth/jwt-vso
  oidc_discovery_url or jwks_url = VSO cluster issuer/JWKS
  bound_issuer                  = VSO cluster issuer

Vault role:
  role_type       = jwt
  user_claim      = sub
  bound_audiences = vault
  bound_subject   = system:serviceaccount:vso-demo:vso-demo
  policies        = mysecret
```

VSO `VaultAuth` should move from Kubernetes auth:

```yaml
spec:
  method: kubernetes
  mount: kubernetes-vso
  kubernetes:
    role: vso-demo
    serviceAccount: vso-demo
```

to JWT auth:

```yaml
spec:
  method: jwt
  mount: jwt-vso
  jwt:
    role: vso-demo
    serviceAccount: vso-demo
    audiences:
      - vault
    tokenExpirationSeconds: 600
```

The installed VSO CRD already exposes these fields:

```text
vaultauth.spec.method = jwt
vaultauth.spec.jwt.role
vaultauth.spec.jwt.serviceAccount
vaultauth.spec.jwt.audiences
vaultauth.spec.jwt.tokenExpirationSeconds
```

---

## Implementation phases

### Phase 1 — Spike the VSO cluster OIDC/JWKS discovery path

> **Status: complete.** See [`docs/vso-jwt-oidc-auth-spike-01.md`](./vso-jwt-oidc-auth-spike-01.md)
> for full evidence (actual `iss`/`sub`/`aud` claims, discovery/JWKS reachability
> proof from the Vault cluster, and the decision below).
>
> **Decision: use `jwks_url`, not `oidc_discovery_url`.** The VSO cluster's
> default kind issuer (`https://kubernetes.default.svc.cluster.local`) is
> cluster-internal and its self-advertised `jwks_uri` is a Podman-bridge IP,
> neither reachable from the Vault cluster. `auth/jwt-vso` should instead be
> configured with `jwks_url=https://host.containers.internal:6444/openid/v1/jwks`,
> `jwks_ca_pem` set to the VSO cluster CA, and `bound_issuer` set to the actual
> `iss` claim value (a string comparison only, not a fetch target). This means
> **Phase 2 / task 02 (kind issuer reconfiguration) is not required** — no
> change to `scripts/kind/vso-lab-config.yaml.tmpl` is needed.
>
> **New requirement surfaced by the spike:** default kind/kubeadm RBAC
> (`system:public-info-viewer`) does not grant unauthenticated access to
> `/.well-known/openid-configuration` or `/openid/v1/jwks`. A
> `oidc-discovery-reader` ClusterRole/ClusterRoleBinding (granting
> `system:unauthenticated` GET on those two non-resource URLs) must be added
> to `scripts/setup-vso-cluster.sh` as part of Phase 5, or Vault's JWKS
> fetch will get `403 Forbidden`.

Goal: prove exactly how Vault can validate VSO cluster service account tokens without TokenReview.

**Primary risk:** the main risk is not Vault — Vault JWT auth supports this pattern. The main risk is kind/Kubernetes service account issuer discovery and reachability. Before changing the rest of the demo, prove the issuer/JWKS path end-to-end from the Vault cluster.

Questions to answer:

1. What is the VSO cluster's actual `iss` claim in a token minted by `kind-vso-lab`?
2. Is that issuer URL reachable from the Vault cluster?
3. Does the issuer expose an OIDC discovery document?
4. Does the discovery document advertise a JWKS URL that Vault can reach?
5. Does the API server certificate/SAN match the URL Vault uses?
6. Is `oidc_discovery_url` practical, or should the demo use `jwks_url` directly?

Commands to investigate:

```bash
kubectl --context kind-vso-lab create token vso-demo \
  -n vso-demo \
  --audience vault \
  --duration 10m
```

Decode the JWT and inspect:

```text
iss
sub
aud
exp
kubernetes.io.namespace
kubernetes.io.serviceaccount.name
```

Check VSO API discovery endpoints:

```bash
curl -k https://host.containers.internal:6444/.well-known/openid-configuration
curl -k https://host.containers.internal:6444/openid/v1/jwks
```

Acceptance criteria:

- We know the issuer value Vault must bind.
- We know whether to use `oidc_discovery_url` or `jwks_url`.
- Vault can reach the chosen issuer/JWKS endpoint from the Vault cluster.

---

### Phase 2 — Update kind/VSO cluster configuration if needed

> **Status: complete, no template change required.** See
> [`docs/vso-jwt-oidc-auth-task-02.md`](./vso-jwt-oidc-auth-task-02.md) for
> the re-validated evidence (fresh token `iss`, JWKS/discovery reachability
> from the Vault cluster, RBAC grant still present) confirming the Phase 1
> decision holds. Only explanatory comments were added to
> `scripts/create-clusters.sh` and `scripts/kind/vso-lab-config.yaml.tmpl`;
> no functional/behavioral change was made.

If the default kind service account issuer is not reachable or does not match the externally reachable API server address, update the VSO kind config template:

```text
scripts/kind/vso-lab-config.yaml.tmpl
```

Potential kubeadm API server args:

```yaml
apiServer:
  extraArgs:
    service-account-issuer: https://host.containers.internal:6444
    service-account-jwks-uri: https://host.containers.internal:6444/openid/v1/jwks
    service-account-signing-key-file: /etc/kubernetes/pki/sa.key
```

Acceptance criteria:

- Newly minted service account tokens have the desired `iss`.
- The issuer/JWKS URL is reachable from Vault.
- Existing Podman/kind networking remains intact.

---

### Phase 3 — Add shared JWT/OIDC environment variables

> **Status: complete.** See `scripts/lib/two-cluster-env.sh`
> (task `vso-jwt-oidc-auth-03`).
>
> **Correction from the original draft below, per the Phase 1 spike
> decision:** `VSO_OIDC_ISSUER` must default to the JWT's actual `iss`
> claim string (`https://kubernetes.default.svc.cluster.local` for default
> kind clusters) — it is a plain string compare (`bound_issuer`), not a
> fetch target, and setting it to the reachable host+port would make every
> real login fail claim validation. `VSO_OIDC_JWKS_URL` is instead derived
> from `${VSO_API_ADDR}` (the already-reachable cross-cluster API address,
> not from `VSO_OIDC_ISSUER`), since spike 01 found the VSO cluster's
> self-reported `jwks_uri` (a Podman-bridge IP) is not reliably reachable.

Update:

```text
scripts/lib/two-cluster-env.sh
```

Add defaults:

```bash
VSO_JWT_AUTH_MOUNT="${VSO_JWT_AUTH_MOUNT:-jwt-vso}"
VSO_JWT_AUTH_ROLE="${VSO_JWT_AUTH_ROLE:-vso-demo}"
VSO_JWT_AUDIENCE="${VSO_JWT_AUDIENCE:-vault}"
VSO_OIDC_ISSUER="${VSO_OIDC_ISSUER:-https://kubernetes.default.svc.cluster.local}"
VSO_OIDC_JWKS_URL="${VSO_OIDC_JWKS_URL:-${VSO_API_ADDR}/openid/v1/jwks}"
```

Keep the existing Kubernetes auth variables temporarily during migration:

```bash
VSO_AUTH_MOUNT="${VSO_AUTH_MOUNT:-kubernetes-vso}"
VSO_AUTH_ROLE="${VSO_AUTH_ROLE:-vso-demo}"
VAULT_TOKEN_REVIEWER_SA="${VAULT_TOKEN_REVIEWER_SA:-vault-token-reviewer}"
```

Acceptance criteria:

- New scripts can source JWT/OIDC defaults from one place.
- Existing Kubernetes-auth demo path is not accidentally broken mid-migration.

---

### Phase 4 — Implement Vault JWT/OIDC auth setup script

Create:

```text
scripts/configure-vso-jwt-auth.sh
```

Responsibilities:

1. Validate required commands and contexts.
2. Confirm Vault pod exists and is unsealed.
3. Resolve/verify VSO issuer and JWKS/discovery endpoint.
4. Enable `auth/jwt-vso` idempotently:

   ```bash
   vault auth enable -path="$VSO_JWT_AUTH_MOUNT" jwt
   ```

5. Configure the JWT auth mount.

OIDC discovery variant:

```bash
vault write "auth/${VSO_JWT_AUTH_MOUNT}/config" \
  oidc_discovery_url="$VSO_OIDC_ISSUER" \
  oidc_discovery_ca_pem="$VSO_CA_PEM"
```

JWKS direct variant:

```bash
vault write "auth/${VSO_JWT_AUTH_MOUNT}/config" \
  jwks_url="$VSO_OIDC_JWKS_URL" \
  jwks_ca_pem="$VSO_CA_PEM" \
  bound_issuer="$VSO_OIDC_ISSUER"
```

6. Write the tightly bound role:

```bash
vault write "auth/${VSO_JWT_AUTH_MOUNT}/role/${VSO_JWT_AUTH_ROLE}" \
  role_type=jwt \
  user_claim=sub \
  bound_audiences="$VSO_JWT_AUDIENCE" \
  bound_subject="system:serviceaccount:${VSO_NAMESPACE}:vso-demo" \
  policies=mysecret \
  ttl=1h
```

Acceptance criteria:

- Script can be safely re-run.
- No `token_reviewer_jwt` is written.
- Role binds issuer/audience/subject tightly.
- Same-cluster Agent Injector `auth/kubernetes` remains untouched.

---

### Phase 5 — Refactor VSO cluster setup

Update:

```text
scripts/setup-vso-cluster.sh
```

Current Kubernetes-auth setup creates:

```text
vault-token-reviewer service account
ClusterRoleBinding to system:auth-delegator
```

JWT/OIDC auth does not need this.

Options:

1. Remove reviewer SA/RBAC entirely.
2. Keep it temporarily behind a compatibility flag:

   ```bash
   ENABLE_TOKEN_REVIEWER_AUTH="${ENABLE_TOKEN_REVIEWER_AUTH:-0}"
   ```

Recommended: remove from the default path and mention in migration docs if preserving the old TokenReview path for comparison.

Acceptance criteria:

- VSO setup still installs operator and creates `vso-demo` namespace/service account.
- No TokenReview reviewer identity is required for the default JWT/OIDC path.

---

### Phase 6 — Update VSO custom resources

Update:

```text
scripts/apply-vso-demo.sh
```

Change `VaultAuth` to JWT:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vso-demo-auth
  namespace: vso-demo
spec:
  vaultConnectionRef: vso-demo-connection
  method: jwt
  mount: ${VSO_JWT_AUTH_MOUNT}
  jwt:
    role: ${VSO_JWT_AUTH_ROLE}
    serviceAccount: vso-demo
    audiences:
      - ${VSO_JWT_AUDIENCE}
    tokenExpirationSeconds: 600
```

`VaultConnection` remains pointed at Vault:

```yaml
spec:
  address: ${VAULT_ADDR}
```

`VaultStaticSecret` remains mostly unchanged:

```yaml
spec:
  vaultAuthRef: vso-demo-auth
```

Acceptance criteria:

- `kubectl get vaultauth vso-demo-auth -o yaml` shows `method: jwt`.
- VSO can still sync `vso-demo-mysecret`.

---

### Phase 7 — Update end-to-end verification

Update:

```text
scripts/verify-two-cluster.sh
```

Replace current auth verification:

```text
Vault login through auth/kubernetes-vso using TokenReview
```

with JWT verification:

```bash
VSO_SA_JWT=$(kubectl --context "$VSO_CONTEXT" create token vso-demo \
  -n "$VSO_NAMESPACE" \
  --audience "$VSO_JWT_AUDIENCE" \
  --duration 10m)

vault write "auth/${VSO_JWT_AUTH_MOUNT}/login" \
  role="$VSO_JWT_AUTH_ROLE" \
  jwt="$VSO_SA_JWT"
```

Add negative tests:

1. Wrong audience must fail:

```bash
WRONG_AUD_JWT=$(kubectl --context "$VSO_CONTEXT" create token vso-demo \
  -n "$VSO_NAMESPACE" \
  --audience not-vault \
  --duration 10m)

vault write "auth/${VSO_JWT_AUTH_MOUNT}/login" \
  role="$VSO_JWT_AUTH_ROLE" \
  jwt="$WRONG_AUD_JWT"
# expect non-zero
```

2. Wrong service account must fail:

```bash
WRONG_SA_JWT=$(kubectl --context "$VSO_CONTEXT" create token default \
  -n "$VSO_NAMESPACE" \
  --audience "$VSO_JWT_AUDIENCE" \
  --duration 10m)

vault write "auth/${VSO_JWT_AUTH_MOUNT}/login" \
  role="$VSO_JWT_AUTH_ROLE" \
  jwt="$WRONG_SA_JWT"
# expect non-zero
```

Acceptance criteria:

- Correct JWT login succeeds.
- Wrong audience login fails.
- Wrong subject/service account login fails.
- Secret sync and rotation still pass.

---

### Phase 8 — Update Makefile targets

Update:

```text
Makefile
```

Add explicit target:

```make
configure-vso-jwt-auth: ## Configure Vault JWT/OIDC auth for VSO service account tokens
	@bash scripts/configure-vso-jwt-auth.sh
```

Keep compatibility alias:

```make
configure-vso-auth: configure-vso-jwt-auth ## Configure VSO auth for Vault (JWT/OIDC default)
```

Update `setup` sequence:

```make
setup:
	@bash scripts/create-clusters.sh
	@bash scripts/setup-vault-cluster.sh
	@bash scripts/setup-vso-cluster.sh
	@bash scripts/configure-vso-jwt-auth.sh
	@bash scripts/apply-vso-demo.sh
```

Acceptance criteria:

- `make setup` uses JWT/OIDC by default.
- `make help` clearly identifies JWT/OIDC auth.

---

### Phase 9 — Update unit/validation tests

Update or add tests under:

```text
scripts/tests/
```

Required test changes:

- New `test-configure-vso-jwt-auth-validation.sh`.
- Update `test-apply-vso-demo-validation.sh` to assert `VaultAuth.method=jwt`.
- Update `test-verify-two-cluster-validation.sh` to assert JWT auth positive and negative checks.
- Update `test-vso-demo-validation.sh` and deck tests for `auth/jwt-vso` language.

Assertions:

```text
PASS: JWT auth setup never writes token_reviewer_jwt
PASS: JWT auth setup enables auth/jwt-vso
PASS: JWT role binds bound_audiences=vault
PASS: JWT role binds bound_subject=system:serviceaccount:vso-demo:vso-demo
PASS: VSO VaultAuth uses method: jwt
PASS: VSO VaultAuth uses jwt.audiences: [vault]
PASS: verification includes wrong-audience negative test
PASS: verification includes wrong-service-account negative test
```

Acceptance criteria:

- All validation tests pass without live cluster mutation.
- Test names and comments describe JWT/OIDC, not TokenReview.

---

### Phase 10 — Update docs, demo script, and slide deck

Update:

```text
README.md
PODMAN_MIGRATION.md
docs/vso-two-cluster-podman-plan.md
docs/vso-two-cluster-audit.md
docs/vso-demo-design.md
vso-demo.sh
presenterm/vso.md
```

Narrative shift:

Old:

```text
Vault delegates validation to the VSO cluster TokenReview API using a reviewer service account.
```

New:

```text
Vault validates VSO service account JWTs directly using the VSO cluster's OIDC issuer/JWKS. No reviewer token is stored in Vault. The Vault role strictly binds issuer, audience, and subject.
```

Presenterm deck should show:

- issuer/JWKS endpoint
- `auth/jwt-vso/config`
- role claim bindings
- VSO `VaultAuth method: jwt`
- positive and negative JWT auth proof
- unchanged secret sync and rotation proof

Acceptance criteria:

- No customer-facing docs describe reviewer JWT as the default production path.
- Deck uses actual live `Ctrl-E` execution and remains visually clean.

---

## Final acceptance criteria

The migration is complete when:

1. `make setup` builds the two-cluster demo with JWT/OIDC auth by default.
2. Vault uses `auth/jwt-vso`, not `auth/kubernetes-vso`, for VSO.
3. VSO `VaultAuth` uses `method: jwt`.
4. Vault stores no VSO `token_reviewer_jwt` in the default path.
5. Vault role requires:
   - correct issuer
   - `aud=vault`
   - `sub=system:serviceaccount:vso-demo:vso-demo`
6. Correct VSO service account JWT login succeeds.
7. Wrong audience login fails.
8. Wrong service account login fails.
9. `VaultStaticSecret` syncs the KV secret into a native Kubernetes Secret.
10. The app consumes the native Secret with zero Vault config.
11. Secret rotation still propagates from Vault cluster to VSO cluster.
12. Unit/validation tests pass.
13. `make verify-two-cluster` passes.
14. `make vso-deck` has been run in presenterm with actual `Ctrl-E` execution on every live block.

---

## Risks and mitigations

### Risk 1 — kind/Kubernetes service account issuer discovery

The main risk is not Vault — Vault JWT auth supports this pattern. The main risk is kind/Kubernetes service account issuer discovery and reachability.

Specific questions that must be answered before implementation:

- What is the VSO cluster's actual `iss` claim?
- Is the issuer URL reachable from the Vault cluster?
- Does the discovery document advertise a JWKS URL that Vault can reach?
- Does the API server certificate/SAN match the URL Vault uses?

Kind may default to an issuer that is not reachable from the Vault cluster or does not match the external host/port.

Mitigation:

- Spike issuer/JWKS first, before modifying the rest of the demo.
- Prefer `jwks_url` if full OIDC discovery is awkward.
- Document that production clusters should use their real OIDC issuer/discovery URL.

### Risk 2 — TLS/SAN mismatch

Vault may reject the issuer/JWKS endpoint if the certificate SAN does not match the URL.

Mitigation:

- Ensure VSO kind API server certificate includes `host.containers.internal`.
- Reuse existing VSO CA extraction logic.
- Validate from inside the Vault cluster before configuring Vault.

### Risk 3 — Overly broad JWT role

A role that binds only issuer or only audience could accept unintended service accounts.

Mitigation:

- Bind `bound_audiences=vault`.
- Bind `bound_subject=system:serviceaccount:vso-demo:vso-demo`.
- Add negative tests for wrong audience and wrong service account.

### Risk 4 — VSO JWT field behavior differs by operator version

The CRD exposes JWT fields, but runtime behavior still needs validation.

Mitigation:

- Test against the installed VSO version.
- Keep a small isolated spike before rewriting all docs/scripts.

---

## Suggested implementation order

1. Spike issuer/JWKS and JWT login manually.
2. Add shared env variables.
3. Implement `scripts/configure-vso-jwt-auth.sh`.
4. Switch `VaultAuth` CRD to `method: jwt`.
5. Update `make setup` and `make configure-vso-auth` alias.
6. Update `verify-two-cluster` with positive and negative JWT tests.
7. Remove/deprecate reviewer SA/RBAC.
8. Update unit tests.
9. Update docs and presenterm deck.
10. Run full validation:
    - all `scripts/tests/test-*.sh`
    - `make setup`
    - `make verify-two-cluster`
    - live `make vso-deck` with actual `Ctrl-E`
