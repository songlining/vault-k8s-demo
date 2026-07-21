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

<!-- speaker_note: This is a second, parallel VSO scenario. It coexists with the default (make vso-deck) JWT/OIDC scenario and never modifies it. Same two Podman-backed kind clusters -- Vault in kind-vault-lab, VSO in kind-vso-lab. -->

<!-- end_slide -->

Architecture — one JWT, two gates
==================================

```
┌─ VSO (kind-vso-lab) ──────────────────────┐
│ 600s JWT, SA vso-auth-delegator           │
│ aud: vault + API issuer URL               │
└────────────────────┬──────────────────────┘
                     │ [1] login jwt=<JWT>
                     ▼
┌─ Vault (kind-vault-lab) ──────────────────┐
│ auth/kubernetes-vso-self-review           │
└────────────────────┬──────────────────────┘
                     │ [2] TokenReview call
                     ▼
┌─ kube-apiserver (kind-vso-lab) ───────────┐
│ Bearer: the SAME JWT; allowed             │
│ for this SA (system:auth-delegator)       │
└───────────────────────────────────────────┘
```

<!-- speaker_note: The SAME JWT is both the Vault login credential and the Bearer of Vault's own TokenReview call -- two independent gates. Gate 1 is the Vault role (audience, ServiceAccount, namespace). Gate 2 is the API server's RBAC on TokenReview itself, plus TokenReview re-validating signature/issuer/binding/expiry. Dual audiences avoid changing the VSO kube-apiserver's creation-time arguments, so kind-vso-lab never needs recreating. -->

<!-- end_slide -->

End-to-end — the eight steps, one self-reviewing JWT
======================================================

The full sequence, from token mint to app env var. The SAME short-lived JWT
is both the Vault login credential and the TokenReview bearer:

```
[1] VSO mints a 600s dual-audience JWT for SA vso-auth-delegator
       audiences: vault  +  API-server issuer URL
       ▼
[2] VSO logs in to Vault with that JWT:  jwt=<JWT>
       ▼
[3] Vault verifies it with NO stored reviewer -- it reuses THAT SAME JWT
    as the HTTP bearer to call  POST tokenreviews  (on kind-vso-lab)
       ▼
[4] API server checks the bearer's RBAC: does SA vso-auth-delegator have
    permission to create tokenreviews?  YES, via system:auth-delegator.
       ▼
[5] API server validates the token (signature, issuer, expiry) and returns
    authenticated=true  +  identity  +  audiences
       ▼
[6] Vault cross-checks identity (right SA / namespace / audience), applies
    a least-privilege policy, returns a non-renewable BATCH Vault token
       ▼
[7] VSO reads the KV secret and writes a native Kubernetes Secret in the
    consumer namespace
       ▼
[8] The app pod (unprivileged SA vso-auth-delegator-app) reads the Secret
    via envFrom -- zero Vault awareness, zero TokenReview power
```

<!-- speaker_note: Steps 3-5 are the self-review itself. The previous slide's two gates map onto here. Gate 1 is the Vault role in step 6 checking audience, ServiceAccount, and namespace. Gate 2 is the API server RBAC on TokenReview in step 4 plus TokenReview re-validating the token in step 5. The same JWT satisfies both because it carries both audiences. Every later proof slide maps back to a numbered step here. -->

<!-- end_slide -->

Kubernetes RBAC: exactly one identity can review tokens
=========================================================

Only **one** identity holds `system:auth-delegator` — and it lives in the
*consumer* namespace, not the auth-config one:

```
kind-vso-lab (VSO cluster)
├── ns: vso-auth-config ─ AUTH CONFIG (VaultConnection + VaultAuth)
└── ns: vso-auth-delegator-app ──── CONSUMER   (both SAs live here)
      ├── SA: vso-auth-delegator     system:auth-delegator   [ CAN  review ]
      ├── SA: vso-auth-delegator-app unprivileged            [ cannot review ]
      ├── SA: default                unprivileged            [ cannot review ]
      └── VaultStaticSecret -> Secret;  app pod uses SA vso-auth-delegator-app
```

<!-- speaker_note: Both ServiceAccounts have automountServiceAccountToken disabled, so VSO mints the bounded 600s token via TokenRequest rather than relying on a mounted pod token. Note the names are deliberately distinct now. The AUTH-CONFIG namespace is vso-auth-config. The privileged self-review SA keeps the scenario name vso-auth-delegator (matching the Vault role, policy, and VaultAuth it is bound to) and lives in the CONSUMER namespace vso-auth-delegator-app. The app pod runs under the separate unprivileged SA vso-auth-delegator-app. Nothing here is shared with the default JWT/OIDC scenario. -->

<!-- end_slide -->

RBAC proof — one binding subject, one reviewer
================================================

The scenario-owned binding grants `system:auth-delegator` to exactly one
subject — the self-review SA, nothing else:

```bash +exec
kubectl --context kind-vso-lab get clusterrolebinding \
  vso-auth-delegator-self-review \
  -o jsonpath='{.roleRef.name}{" -> "}{.subjects[0].namespace}/{.subjects[0].name}{"\n"}'
```

And in that SAME namespace, only that one identity can create
TokenReviews — the app SA and `default` cannot:

```bash +exec
kubectl --context kind-vso-lab auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:vso-auth-delegator-app:vso-auth-delegator-app
kubectl --context kind-vso-lab auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:vso-auth-delegator-app:default
kubectl --context kind-vso-lab auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:vso-auth-delegator-app:vso-auth-delegator
```

<!-- end_slide -->

The token: one JWT, both audiences
================================================

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

<!-- speaker_note: kubectl create token is just the CLI wrapper around the TokenRequest API (the serviceaccounts/token subresource) that VSO calls natively to mint this exact token. The VSO operator ServiceAccount holds create on serviceaccounts/token via the vso-auth-delegator-token-creator Role, so it requests the token for the self-review SA with these audiences and this TTL. VSO never exposes the raw JWT, so this block only reproduces what step 1 produces, purely so you can read its claims. -->

<!-- end_slide -->

Direct proof: the same JWT is both bearer and reviewed token
=============================================================

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

Vault auth mount: no stored reviewer, no local pod JWT
========================================================

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

Vault role and policy: least privilege
========================================

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
LOGIN=$(printf '%s' "$JWT" | kubectl --context kind-vault-lab exec -i vault-0 -n default -- \
  vault write -format=json auth/kubernetes-vso-self-review/login role=vso-auth-delegator jwt=-)
ROLE_TT=$(kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault read -format=json auth/kubernetes-vso-self-review/role/vso-auth-delegator | jq -r '.data.token_type')
printf '%s' "$LOGIN" | jq --arg tt "$ROLE_TT" '{renewable: .auth.renewable, token_type: (.auth.token_type // $tt), policies: .auth.policies, identity_policies: .auth.identity_policies, lease_duration: .auth.lease_duration}'
unset JWT LOGIN ROLE_TT
```

**Key point:** `renewable: false`, `token_type: "batch"`, and exactly the
`vso-auth-delegator` policy — VSO re-authenticates rather than renewing.

<!-- speaker_note: Vault 2.x can return token_type=null in the login response even for batch tokens, so the block falls back to the role's configured token_type -- the same documented fallback scripts/verify-vso-auth-delegator.sh uses. The raw Vault token is never printed. -->

<!-- end_slide -->

Proof: wrong audience fails
============================

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

<!-- end_slide -->

Proof: wrong ServiceAccount fails
==================================

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
======================================

`VaultStaticSecret` lives in the consumer namespace and references the
centrally defined `VaultAuth` cross-namespace as
`vso-auth-config/vso-auth-delegator`, gated by `allowedNamespaces`:

```bash +exec
kubectl --context kind-vso-lab get vaultstaticsecret vso-auth-delegator-mysecret -n vso-auth-delegator-app \
  -o jsonpath='{"  vaultAuthRef: "}{.spec.vaultAuthRef}{"\n  destination: "}{.spec.destination.name}{"\n"}'
```

**Key point:** credentials resolve from the CONSUMING namespace
(`vso-auth-delegator-app`), not the central `VaultAuth` namespace.

<!-- end_slide -->

A plain app consumes the synced Secret
========================================

The app pod runs under the SEPARATE unprivileged ServiceAccount:

```bash +exec
kubectl --context kind-vso-lab get pod vso-auth-delegator-app -n vso-auth-delegator-app \
  -o jsonpath='{"  serviceAccount: "}{.spec.serviceAccountName}{"\n  containers: "}{.spec.containers[*].name}{"\n"}'
```

```bash +exec
kubectl --context kind-vso-lab exec vso-auth-delegator-app -n vso-auth-delegator-app -- printenv username
```

<!-- speaker_note: single container, no sidecar, no Vault annotations -- zero Vault awareness in the app. The Secret is a native k8s Secret synced by VSO. -->
