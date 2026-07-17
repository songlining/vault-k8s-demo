---
---

<!-- jump_to_middle -->
<!-- alignment: center -->
<!-- no_footer -->
<!-- font_size: 2 -->

Client JWT Self-Review

<!-- new_lines: 2 -->
<!-- font_size: 1 -->

VSO's own ServiceAccount JWT authenticates to Vault AND authorizes Vault's TokenReview call

<!-- new_lines: 4 -->

*Larry Song — HashiCorp Solutions Engineering*

<!-- end_slide -->

<!-- jump_to_middle -->
<!-- alignment: center -->

This is a **second, parallel** Vault Secrets Operator scenario. It coexists
with — and never modifies — the default `make vso-deck` JWT/OIDC scenario.

Same two Podman-backed kind clusters: Vault in `kind-vault-lab`, VSO in
`kind-vso-lab`. A different Vault Kubernetes auth mount, different
namespaces, different everything — proven side by side.

<!-- speaker_note: Launch with make auth-delegator-deck. The target requires both existing kind control planes (no cluster creation), verifies the default JWT/OIDC scenario, health-checks this scenario, runs setup only if unhealthy, then runs the full verifier including CAS rotation before opening this deck. -->

<!-- end_slide -->

What we will prove
===================

<!-- list_item_newlines: 2 -->

1. VSO mints one short-lived, dual-audience ServiceAccount JWT.
2. That SAME JWT is the Vault login credential AND the HTTP bearer Vault
   uses for its own Kubernetes TokenReview call.
3. Exactly one ServiceAccount holds `system:auth-delegator`; the app,
   `default`, and the VSO controller identity cannot review tokens.
4. Vault never stores a reviewer JWT and never loads its own pod's token.
5. A centrally defined `VaultAuth` is consumed cross-namespace by a
   `VaultStaticSecret`, materializing a native Secret for a plain app.
6. Rotation and full-object restoration both happen safely, inside a
   single trap-protected verifier run.

<!-- end_slide -->

Four ways to authenticate a Kubernetes client to Vault
=======================================================

<!-- list_item_newlines: 1 -->

- **Vault-local review** — Vault's own pod JWT/CA reviews the client token.
  Historical `auth-test` runtime path; not used by either scenario here.
- **Dedicated reviewer** — a separate stored reviewer ServiceAccount JWT
  reviews every client token. Opt-in legacy path
  (`configure-vso-kubernetes-auth.sh`), not run by default.
- **JWT/OIDC discovery** — Vault verifies signatures locally via JWKS; no
  TokenReview at all. **Default scenario** (`make vso-deck`).
- **Client JWT self-review (this deck)** — the client's OWN login JWT is
  also the reviewer's HTTP bearer, authorized by `system:auth-delegator`.

<!-- speaker_note: This deck's third design is not the same as auth-test's Vault-local review -- auth-test's extra system:auth-delegator binding on default/default is redundant there because the chart-created binding on the Vault server service account already supplies the real reviewer permission. -->

<!-- end_slide -->

Architecture — two clusters, one JWT does both jobs
=====================================================

<!-- column_layout: [1, 1] -->

<!-- column: 0 -->

**Vault cluster** (`kind-vault-lab`)

- `vault-0`
- `auth/kubernetes-vso-self-review`
- role/policy `vso-auth-delegator`
- `kv-v2/vso-auth-delegator/mysecret`

<!-- column: 1 -->

**VSO cluster** (`kind-vso-lab`)

- ns `vso-auth-delegator` (auth/config)
- ns `vso-auth-delegator-app` (consumer)
- SA `vso-auth-delegator`: `system:auth-delegator`
- SA `vso-auth-delegator-app`: unprivileged

<!-- reset_layout -->

**Key design point:** the JWT VSO submits as `jwt=` to Vault's login
endpoint is the SAME JWT Vault sends as `Authorization: Bearer` for its
own TokenReview call to the VSO cluster.

<!-- speaker_note: Dual-audience token -- one audience satisfies the Vault role's requested TokenReview audience; the other lets the same JWT authenticate as the outer HTTP bearer, since the API server does not set --api-audiences. -->

<!-- end_slide -->

Why the token needs two audiences
==================================

The VSO cluster's kube-apiserver sets `--service-account-issuer` but not
`--api-audiences`, so it defaults its accepted bearer audience to its own
issuer URL:

```
  vault            <- audience the Vault role requests (TokenReview.spec.audiences)
  https://host.containers.internal:6444   <- audience the outer HTTP bearer needs
```

A token with only `vault` cannot authenticate as the HTTP bearer to the API
server at all. A token with only the issuer URL fails the Vault role's
requested-audience check. **Both audiences, one token, two independent
gates** — verified independently later in this deck.

<!-- speaker_note: This design avoids changing the VSO kube-apiserver's creation-time arguments, so it never requires deleting or recreating kind-vso-lab. -->

<!-- end_slide -->

Placement and ownership
========================

Every scenario resource is dedicated and labeled; nothing shared with the
default JWT/OIDC scenario (`vso-demo` namespace, `auth/jwt-vso`):

```bash +exec
kubectl --context kind-vso-lab get namespace vso-auth-delegator vso-auth-delegator-app
```

```bash +exec
kubectl --context kind-vso-lab get serviceaccount,clusterrolebinding \
  -n vso-auth-delegator-app
```

**Key point:** the self-review ServiceAccount exists ONLY in the consumer
namespace, alongside a separate, unprivileged app ServiceAccount — never on
the app pod.

<!-- end_slide -->

RBAC proof: exactly one identity can review tokens
====================================================

The scenario-owned binding grants `system:auth-delegator` to exactly one
subject:

```bash +exec
kubectl --context kind-vso-lab get clusterrolebinding \
  vso-auth-delegator-self-review \
  -o jsonpath='{.roleRef.name}{" -> "}{.subjects[0].namespace}/{.subjects[0].name}{"\n"}'
```

The app ServiceAccount and `default` in the SAME namespace CANNOT create
TokenReviews — only the self-review identity can:

```bash +exec
kubectl --context kind-vso-lab auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:vso-auth-delegator-app:vso-auth-delegator-app
kubectl --context kind-vso-lab auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:vso-auth-delegator-app:default
kubectl --context kind-vso-lab auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:vso-auth-delegator-app:vso-auth-delegator
```

<!-- end_slide -->

The short-lived JWT's claims — never the JWT itself
=====================================================

Mint a 600-second, dual-audience token and decode only its claims. The raw
JWT is never printed:

```bash +exec
JWT=$(kubectl --context kind-vso-lab create token vso-auth-delegator -n vso-auth-delegator-app \
  --duration 600s --audience vault --audience https://host.containers.internal:6444)
PAYLOAD="${JWT#*.}"; PAYLOAD="${PAYLOAD%%.*}"
PAYLOAD="${PAYLOAD//-/+}"; PAYLOAD="${PAYLOAD//_//}"
case $(( ${#PAYLOAD} % 4 )) in 2) PAYLOAD+="==" ;; 3) PAYLOAD+="=" ;; esac
printf '%s' "$PAYLOAD" | base64 -d | jq '{iss, sub, aud, lifetime_seconds: (.exp - .iat)}'
unset JWT PAYLOAD
```

**Key point:** issuer, subject, both audiences, and a bounded (≤600s)
lifetime — exactly what the Vault role and the API server both check.

<!-- end_slide -->

Direct proof: the same JWT is both bearer and reviewed token
===============================================================

One in-memory token, used as both the outer HTTP `Authorization` bearer
AND the reviewed `spec.token` — proving self-review directly, independent
of Vault:

```bash +exec
JWT=$(kubectl --context kind-vso-lab create token vso-auth-delegator -n vso-auth-delegator-app \
  --duration 600s --audience vault --audience https://host.containers.internal:6444)
CLUSTER=$(kubectl config view --raw -o jsonpath='{.contexts[?(@.name=="kind-vso-lab")].context.cluster}')
CA_B64=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$CLUSTER\")].cluster.certificate-authority-data}")
CA_PEM=$(printf '%s' "$CA_B64" | base64 -d)
BODY=$(jq -n --arg t "$JWT" '{apiVersion:"authentication.k8s.io/v1",kind:"TokenReview",spec:{token:$t,audiences:["vault"]}}')
curl -s --cacert <(printf '%s' "$CA_PEM") --resolve host.containers.internal:6444:127.0.0.1 \
  -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -X POST --data "$BODY" \
  https://host.containers.internal:6444/apis/authentication.k8s.io/v1/tokenreviews | jq '.status'
unset JWT CLUSTER CA_B64 CA_PEM BODY
```

<!-- speaker_note: Only .status is printed -- the response object's own spec.token would otherwise echo the JWT back. authenticated=true plus the exact identity and the vault audience prove system:auth-delegator authorized this exact call. -->

<!-- end_slide -->

Vault: no reviewer stored, no local pod JWT loaded
====================================================

Read back the live mount configuration — CA material is deliberately
excluded from the filter:

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault read -format=json auth/kubernetes-vso-self-review/config | \
  jq '{kubernetes_host: .data.kubernetes_host, disable_local_ca_jwt: .data.disable_local_ca_jwt, disable_iss_validation: .data.disable_iss_validation, token_reviewer_jwt_set: .data.token_reviewer_jwt_set}'
```

**Key point:** `disable_local_ca_jwt=true` means Vault never falls back to
its own pod's ServiceAccount token/CA — it uses only the client JWT
presented at login. `token_reviewer_jwt_set=false` — no reviewer is ever
stored.

<!-- end_slide -->

Least-privilege Vault role and policy
=======================================

The role binds exactly the self-review ServiceAccount, the consumer
namespace, and the `vault` audience — no default policy, non-renewable
batch tokens:

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault read auth/kubernetes-vso-self-review/role/vso-auth-delegator | \
  grep -E 'bound_service_account|audience|token_type|token_policies|ttl'
```

The policy allows only one read:

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- vault policy read vso-auth-delegator
```

<!-- end_slide -->

Proof: correct JWT logs in
============================

Login succeeds; only token metadata is shown, never the token value
itself:

```bash +exec
JWT=$(kubectl --context kind-vso-lab create token vso-auth-delegator -n vso-auth-delegator-app \
  --duration 600s --audience vault --audience https://host.containers.internal:6444)
printf '%s' "$JWT" | kubectl --context kind-vault-lab exec -i vault-0 -n default -- \
  vault write -format=json auth/kubernetes-vso-self-review/login role=vso-auth-delegator jwt=- | \
  jq '{renewable: .auth.renewable, token_type: .auth.token_type, policies: .auth.policies, identity_policies: .auth.identity_policies, lease_duration: .auth.lease_duration}'
unset JWT
```

**Key point:** `renewable: false`, `token_type: "batch"`, and exactly the
`vso-auth-delegator` policy — VSO re-authenticates rather than renewing.

<!-- end_slide -->

Proof: wrong audience or wrong ServiceAccount both fail
==========================================================

A token with ONLY the `vault` audience cannot authenticate as the outer
HTTP bearer, so the whole login fails:

```bash +exec
JWT=$(kubectl --context kind-vso-lab create token vso-auth-delegator -n vso-auth-delegator-app \
  --duration 600s --audience vault)
printf '%s' "$JWT" | kubectl --context kind-vault-lab exec -i vault-0 -n default -- \
  vault write auth/kubernetes-vso-self-review/login role=vso-auth-delegator jwt=- >/dev/null 2>&1 \
  && echo 'UNEXPECTED: login succeeded' || echo '-> correctly rejected (vault-audience-only)'
unset JWT
```

A dual-audience token from the WRONG (app) ServiceAccount also fails:

```bash +exec
JWT=$(kubectl --context kind-vso-lab create token vso-auth-delegator-app -n vso-auth-delegator-app \
  --duration 600s --audience vault --audience https://host.containers.internal:6444)
printf '%s' "$JWT" | kubectl --context kind-vault-lab exec -i vault-0 -n default -- \
  vault write auth/kubernetes-vso-self-review/login role=vso-auth-delegator jwt=- >/dev/null 2>&1 \
  && echo 'UNEXPECTED: login succeeded' || echo '-> correctly rejected (wrong service account)'
unset JWT
```

<!-- speaker_note: make auth-delegator-verify runs these same audience and identity negatives, plus an API-audience-only case, non-interactively. -->

<!-- end_slide -->

Cross-namespace VaultAuth consumption
========================================

`VaultConnection`/`VaultAuth` live in the auth namespace; `VaultStaticSecret`
lives in the consumer namespace and references them as `namespace/name`:

```bash +exec
kubectl --context kind-vso-lab get vaultconnection,vaultauth -n vso-auth-delegator
```

```bash +exec
kubectl --context kind-vso-lab get vaultstaticsecret vso-auth-delegator-mysecret -n vso-auth-delegator-app \
  -o jsonpath='{"  vaultAuthRef: "}{.spec.vaultAuthRef}{"\n  destination: "}{.spec.destination.name}{"\n"}'
```

**Key point:** Kubernetes credentials are resolved from the CONSUMING
resource's namespace (`vso-auth-delegator-app`), even though `VaultAuth`
itself is centrally defined in `vso-auth-delegator`.

<!-- end_slide -->

A plain app consumes it — zero Vault awareness
=================================================

The native Secret exists only in the consumer namespace:

```bash +exec
kubectl --context kind-vso-lab get secret vso-auth-delegator-mysecret -n vso-auth-delegator-app
```

The app pod runs under the SEPARATE unprivileged ServiceAccount, has no
Vault annotations, and is a single container (no sidecar):

```bash +exec
kubectl --context kind-vso-lab get pod vso-auth-delegator-app -n vso-auth-delegator-app \
  -o jsonpath='{"  serviceAccount: "}{.spec.serviceAccountName}{"\n  containers: "}{.spec.containers[*].name}{"\n"}'
```

```bash +exec
kubectl --context kind-vso-lab exec vso-auth-delegator-app -n vso-auth-delegator-app -- printenv username
```

<!-- end_slide -->

Full proof: deny-by-default and reversible rotation
======================================================

One trap-protected script run proves: a third namespace is denied by
`allowedNamespaces` with no Secret created, then a full-object CAS
rotation is observed and exactly restored — on success, error, or signal:

```bash +exec
set -euo pipefail
[ -f scripts/verify-vso-auth-delegator.sh ] || cd ..
bash scripts/verify-vso-auth-delegator.sh > /tmp/auth-delegator-verify.out 2>&1
awk '/^==> \[/ || /^====/ || /^VERIFIED:/ || /^  [A-Za-z]/' /tmp/auth-delegator-verify.out
```

<!-- speaker_note: This calls the exact same scripts/verify-vso-auth-delegator.sh used by make auth-delegator-verify and make auth-delegator-deck's own startup gate. Its own HUP/INT/TERM traps and CAS-version checks guarantee the KV fixture and synced Secret are restored to their original object before this block exits -- no later slide performs any restoration. -->

<!-- end_slide -->

Self-review vs. JWT/OIDC — side by side
==========================================

<!-- column_layout: [1, 1] -->

<!-- column: 0 -->

**JWT/OIDC (default, `make vso-deck`)**

- Vault fetches JWKS, verifies locally
- No TokenReview, ever
- One mount: `auth/jwt-vso`
- Same namespace for auth and app

<!-- column: 1 -->

**Client JWT self-review (this deck)**

- Vault calls TokenReview using the
  client's own JWT as bearer
- `system:auth-delegator` on one SA
- One mount: `auth/kubernetes-vso-self-review`
- Auth namespace ≠ consumer namespace

<!-- reset_layout -->

Both coexist unmodified — proven by the no-regression gate in every
verifier run.

<!-- end_slide -->

Demo complete
=============

<!-- jump_to_middle -->
<!-- alignment: center -->

**What we proved**

1. One short-lived, dual-audience JWT is both the Vault login credential
   and the TokenReview HTTP bearer.
2. Exactly one ServiceAccount holds `system:auth-delegator`; every other
   identity is correctly denied.
3. Vault stores no reviewer JWT and never loads its own pod's token.
4. Wrong audience and wrong ServiceAccount both fail independently.
5. A centrally defined `VaultAuth` is consumed cross-namespace; a plain
   app reads the resulting native Secret with zero Vault awareness.
6. Rotation and full-object restoration happened safely inside one
   trap-protected verifier run — and the default JWT/OIDC scenario is
   unchanged.

<!-- end_slide -->

Reset — confirm a clean, repeatable baseline
===============================================

Nothing here deletes a cluster, a namespace, or the Vault mount. It only
re-confirms the environment is healthy so the demo can be re-run:

```bash +exec
set -euo pipefail
[ -f scripts/verify-vso-auth-delegator.sh ] || cd ..
OUT=/tmp/auth-delegator-reset.out
if bash scripts/verify-vso-auth-delegator.sh --skip-rotation > "$OUT" 2>&1; then
  echo 'OK: scenario healthy, baseline confirmed (rotation already restored above).'
else
  echo "FAILED health re-check -- see $OUT"
  tail -40 "$OUT"
  exit 1
fi
```

<!-- speaker_note: Manual teardown (deleting the two dedicated namespaces, the ClusterRoleBinding, the auth mount, the policy, and the KV path) is documented in docs/vso-kubernetes-auth-delegator-demo.md and always requires explicit user confirmation -- no target here or in the Makefile performs it automatically. -->
