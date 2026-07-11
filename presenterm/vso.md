---
title: "Vault Secrets Operator (VSO) Demo"

sub_title: "Sync Vault secrets into native Kubernetes Secrets"

author: "Larry Song — HashiCorp Solutions Engineering"
---

This guided flow demonstrates the **Vault Secrets Operator**: a cluster-wide
operator that syncs Vault secrets into native Kubernetes Secret objects,
running across **two separate Podman-backed kind clusters** — Vault in
`kind-vault-lab`, VSO in `kind-vso-lab`.

**The customer problem**

- Teams want Vault secrets, but their apps already consume native Kubernetes
  Secrets (`envFrom`, `secretKeyRef`, volume mounts).
- They do not want every workload to carry Vault-specific annotations or run a
  per-pod sidecar just to read a secret.
- They want secrets to stay in sync automatically when the source changes.
- Vault and the clusters that consume its secrets often live in **different**
  clusters — a central Vault serving many downstream clusters.

**What we will prove**

1. Vault runs only in the Vault cluster; VSO, its CRDs, and the consuming app
   run only in a separate VSO cluster.
2. The Vault Secrets Operator is running cluster-wide in the VSO cluster.
3. Three CRDs declare how to reach Vault, how to authenticate, and what to sync.
4. A pod in the VSO cluster can reach Vault at its documented external address.
5. Vault validates VSO-cluster service accounts through a dedicated
   `auth/jwt-vso` **JWT/OIDC** mount — Vault checks the JWT's signature
   against the VSO cluster's own JWKS, then strictly binds issuer, audience,
   and subject. No reviewer service account, no `token_reviewer_jwt`.
6. A wrong-audience JWT and a wrong-service-account JWT are both correctly
   rejected by Vault.
7. A Vault KV secret is materialized as a native Kubernetes Secret in the VSO
   cluster.
8. A plain pod consumes it with zero Vault configuration.
9. The operator's Vault identity is least-privilege.
10. Updating the value in Vault refreshes the Kubernetes Secret automatically.

<!-- speaker_note: Launch with `presenterm -x presenterm/vso.md`. Run `make verify-two-cluster` first to confirm both clusters are green. Press ctrl+e on each live block. -->

<!-- end_slide -->

1 — Architecture: two clusters, cross-cluster auth
=================================================

Vault runs in one cluster; VSO runs in another. The important point is the
trust boundary: the auth method lives in Vault, but it validates JWTs
cryptographically against the VSO cluster's own JWKS — Vault never calls
back into the VSO cluster's API server to ask if a token is still valid.

<!-- column_layout: [1, 1] -->

<!-- column: 0 -->

**Vault cluster**

`kind-vault-lab`

- `vault-0`
- `auth/jwt-vso` (JWT/OIDC)
- role `vso-demo` → policy `mysecret`
- `kv-v2/vault-demo/mysecret`
- exposed at `host.containers.internal:8200`

<!-- column: 1 -->

**VSO cluster**

`kind-vso-lab`

- VSO controller runs cluster-wide
- `VaultConnection` → `VaultAuth` → `VaultStaticSecret`
- native Secret `vso-demo-mysecret`
- pod `vso-demo-app` is `1/1`
- no sidecar, no Vault annotations

<!-- reset_layout -->

**Cross-cluster flow**

`VaultConnection` → `VAULT_ADDR` → `auth/jwt-vso` (JWT/OIDC) →
signature + claims verified against `VSO_API_ADDR`'s JWKS → native
Kubernetes Secret

<!-- speaker_note: This is not a same-cluster shortcut -- Vault and VSO are provably different kind clusters, connected only through host.containers.internal and a dedicated auth/jwt-vso JWT/OIDC mount. Vault fetches the VSO cluster's public signing keys once and verifies tokens locally by checking the signature plus issuer/audience/subject claims -- no reviewer credential, no TokenReview callback. VSO watches CRDs you define, logs into Vault on your behalf, and syncs secrets into native Kubernetes Secret objects. The app consumes via envFrom, secretKeyRef, or a volume mount -- zero Vault awareness. -->

<!-- end_slide -->

1b — Step-by-step flow
=====================

```
 kind-vso-lab:  VaultConnection -> VaultAuth -> VaultStaticSecret   (CRDs)
        |  (1) VSO controller watches these CRDs
        v
 kind-vso-lab:  VSO Controller (vault-secrets-operator-system)
        |  (2) login with the vso-demo pod's own SA JWT over auth/jwt-vso/login
        |      address: VAULT_ADDR (http://host.containers.internal:8200)
        v
 kind-vault-lab:  Vault (vault-0)
              auth/jwt-vso (JWT/OIDC) . role vso-demo . policy mysecret
              kv-v2/vault-demo/mysecret
        |  (3) Vault verifies the JWT locally: signature checked against
        |      the VSO cluster's JWKS (VSO_API_ADDR), then
        |      issuer/audience/subject claims checked against the role's
        |      strict bindings. No callback, no reviewer JWT.
        |  (4) on success: writes / refreshes every 30s
        v
 kind-vso-lab:  Secret vso-demo-mysecret   (native K8s Secret)
        |  (5) envFrom -- standard Kubernetes API
        v
 kind-vso-lab:  Pod vso-demo-app   (no Vault annotations, no sidecar)
```

Unlike the Agent Injector (a sidecar per pod that writes a file), VSO runs once
per cluster and turns Vault secrets into first-class Kubernetes Secrets any app
can consume with zero Vault knowledge — and here, Vault itself lives in a
separate cluster from every consumer.

<!-- end_slide -->

2 — The operator is running
==========================

The Vault Secrets Operator runs as a cluster-wide controller in the VSO
cluster:

```bash +exec
kubectl --context kind-vso-lab get pods -n vault-secrets-operator-system
```

**Key points**

- One operator Deployment serves the whole (VSO) cluster.
- There is no per-application sidecar in this model.
- Vault itself is not installed here — it runs in the separate
  `kind-vault-lab` cluster.

<!-- end_slide -->

3 — The CRDs that drive the sync
===============================

Three declarative objects describe the whole pipeline, all in the VSO cluster:

```
  ┌──────────────────┬──────────────┬────────────────────────┐
  │ VaultConnection  │ VaultAuth    │ VaultStaticSecret      │
  ├──────────────────┼──────────────┼────────────────────────┤
  │ Where is Vault?  │ How login?   │ What secret to sync?   │
  └──────────────────┴──────────────┴────────────────────────┘
```

Other VSO secret CRDs you can use: **VaultDynamicSecret** (dynamic leased creds,
e.g. database users), **VaultPKISecret** (issued/renewed certs from Vault PKI),
**HCPVaultSecretsApp** (sync from HCP Vault Secrets). This demo uses
VaultStaticSecret because the source is an existing KV secret.

```bash +exec
kubectl --context kind-vso-lab get vaultconnection,vaultauth,vaultstaticsecret -n vso-demo
```

<!-- end_slide -->

3b — What the VaultStaticSecret declares
=======================================

The VaultStaticSecret declares the Vault path and the destination Secret:

```bash +exec
kubectl --context kind-vso-lab get vaultstaticsecret vso-demo-mysecret -n vso-demo -o jsonpath='{"  mount: "}{.spec.mount}{"\n  path: "}{.spec.path}{"\n  type: "}{.spec.type}{"\n  refreshAfter: "}{.spec.refreshAfter}{"\n  destination: "}{.spec.destination.name}{"\n"}'
```

And the VaultConnection declares the external address VSO uses to reach Vault
in the other cluster (not an in-cluster DNS name):

```bash +exec
kubectl --context kind-vso-lab get vaultconnection vso-demo-connection -n vso-demo -o jsonpath='{.spec.address}{"\n"}'
```

**Key points**

- **VaultConnection**: how to reach Vault — here, the host-level address
  `http://host.containers.internal:8200` (`VAULT_ADDR`), since Vault lives in
  a different cluster.
- **VaultAuth**: uses the dedicated `jwt-vso` JWT/OIDC mount with role
  `vso-demo`, distinct from the same-cluster `auth/kubernetes` mount used by
  the Agent Injector demos. No `token_reviewer_jwt` field exists in this
  manifest — VSO presents the pod's own service account JWT directly.
- **VaultStaticSecret**: read `kv-v2/vault-demo/mysecret`, refresh every 30s, and
  materialize it as the native Secret `vso-demo-mysecret`.

<!-- end_slide -->

4 — The native Kubernetes Secret VSO created
===========================================

VSO wrote a standard Kubernetes Secret (not a file in a pod), in the VSO
cluster:

```bash +exec
kubectl --context kind-vso-lab get secret vso-demo-mysecret -n vso-demo
```

Decode the synced value:

```bash +exec
kubectl --context kind-vso-lab get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d; echo
```

**Key points**

- This is a first-class Secret object any workload can consume.
- The value came from Vault in a different cluster, but the object here is
  pure Kubernetes.

<!-- end_slide -->

5 — A plain pod consumes it with zero Vault config
=================================================

The app reads the secret through standard `envFrom` at pod start:

```bash +exec
kubectl --context kind-vso-lab exec vso-demo-app -n vso-demo -- printenv username
```

The consuming pod has **NO** Vault annotations and **NO** sidecar (count = 0):

```bash +exec
kubectl --context kind-vso-lab get pod vso-demo-app -n vso-demo -o yaml | grep -c 'vault.hashicorp.com' || true
```

It is a single-container pod (`1/1`), not `2/2` like an injected sidecar pod:

```bash +exec
kubectl --context kind-vso-lab get pod vso-demo-app -n vso-demo
```

<!-- speaker_note: envFrom values are captured when a pod starts; later Secret refreshes update the Secret object, not the existing process environment. Contrast with the Agent Injector demo, where pods are 2/2 and carry vault.hashicorp.com annotations -- and where everything runs in a single cluster instead of two. -->

<!-- end_slide -->

6 — Set up cross-cluster JWT/OIDC auth
=====================================

This is the customer-facing setup step: configure a **Vault auth method in
the Vault cluster** that validates VSO-cluster service account JWTs
**cryptographically**, using the VSO cluster's own JSON Web Key Set (JWKS) —
no reviewer service account, no `token_reviewer_jwt`, ever stored in Vault.

```bash +exec
set -euo pipefail
[ -f scripts/configure-vso-jwt-auth.sh ] || cd ..
bash scripts/configure-vso-jwt-auth.sh > /tmp/vso-auth-setup.out 2>&1
awk '
  /^==> Configuring/ ||
  /^    Vault cluster/ ||
  /^    VSO cluster/ ||
  /^    Auth mount/ ||
  /^==> Writing auth\/jwt-vso\/config/ ||
  /^Success! Data written to: auth\/jwt-vso\/config/ ||
  /^==> Writing auth\/jwt-vso\/role/ ||
  /^Success! Data written to: auth\/jwt-vso\/role/ ||
  /^==> Verifying configuration/
' /tmp/vso-auth-setup.out
```

Watch for the important asymmetry in the output: **auth is hosted in
`kind-vault-lab`, but trusts a JWKS served by `kind-vso-lab`**.

<!-- speaker_note: This is the key customer question -- Vault is not using its own cluster's Kubernetes API here. The auth method lives in Vault, and it validates JWTs itself by fetching the other cluster's public signing keys once, rather than calling back into that cluster's API server on every login. -->

<!-- end_slide -->

6b — Verify the cross-cluster trust boundary
===========================================

The Vault auth method lives in the **Vault cluster**, but its config trusts a
JWKS served by the **VSO cluster** — no CA material or signing keys are ever
printed:

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault read -format=json auth/jwt-vso/config | \
  jq 'del(.data.jwks_ca_pem, .data.jwt_validation_pubkeys, .data.oidc_discovery_ca_pem)'
```

Confirm the mount is a **JWT** auth method, not Kubernetes auth:

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault auth list -format=json | jq -r '."jwt-vso/".type'
```

<!-- end_slide -->

6c — Least-privilege Vault identity: strict claim binding
=========================================================

The role only accepts JWTs whose audience and subject match exactly — not
just JWTs from the right cluster:

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault read auth/jwt-vso/role/vso-demo | \
  grep -E 'bound_audiences|bound_subject|token_policies|policies'
```

The `mysecret` policy only allows reading this one KV path:

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- vault policy read mysecret
```

**Key point:** `auth/jwt-vso` is the cross-cluster JWT/OIDC auth mount. The
existing same-cluster `auth/kubernetes` mount remains separate for the Agent
Injector demo path.

<!-- end_slide -->

6d — Proof: correct JWT logs in, wrong audience/service account do not
=======================================================================

Mint a correct JWT for `vso-demo` (audience `vault`) and log in:

```bash +exec
JWT=$(kubectl --context kind-vso-lab create token vso-demo -n vso-demo --audience vault)
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault write auth/jwt-vso/login role=vso-demo jwt="$JWT" | grep -E 'token |policies'
unset JWT
```

A JWT minted for the **wrong audience** is rejected:

```bash +exec
JWT=$(kubectl --context kind-vso-lab create token vso-demo -n vso-demo --audience not-vault)
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault write auth/jwt-vso/login role=vso-demo jwt="$JWT" >/dev/null 2>&1 \
  && echo 'UNEXPECTED: login succeeded' \
  || echo '-> correctly rejected (wrong audience)'
unset JWT
```

A JWT minted for the **wrong service account** (`default`, not `vso-demo`) is
rejected:

```bash +exec
JWT=$(kubectl --context kind-vso-lab create token default -n vso-demo --audience vault)
kubectl --context kind-vault-lab exec vault-0 -n default -- \
  vault write auth/jwt-vso/login role=vso-demo jwt="$JWT" >/dev/null 2>&1 \
  && echo 'UNEXPECTED: login succeeded' \
  || echo '-> correctly rejected (wrong service account)'
unset JWT
```

<!-- speaker_note: This is the payoff slide for the whole JWT/OIDC story -- Vault never asks the VSO cluster "is this token still valid?"; it verifies the signature against the cluster's JWKS and checks the claims itself, and wrong audience/wrong service account are both rejected before Vault ever looks at policies. make verify-two-cluster runs this same proof non-interactively. -->

<!-- end_slide -->

7 — Live rotation: change Vault, watch the Secret update
=======================================================

Seed Vault (in the Vault cluster) with the original value so rotation starts
from a known baseline:

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- vault kv put kv-v2/vault-demo/mysecret username=larry
```

Wait for VSO (in the VSO cluster) to sync the baseline value into the
Kubernetes Secret:

```bash +exec
for i in $(seq 1 20); do
  v=$(kubectl --context kind-vso-lab get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d)
  echo "  attempt $i: $v"
  if [ "$v" = "larry" ]; then echo '  -> Secret synced to baseline by VSO'; exit 0; fi
  sleep 3
done
echo 'ERROR: Secret did not sync to larry' >&2; exit 1
```

<!-- end_slide -->

7b — Rotate the value in Vault
=============================

Current value in the native Kubernetes Secret (VSO cluster):

```bash +exec
kubectl --context kind-vso-lab get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d; echo
```

Update the value in Vault (Vault cluster):

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- vault kv put kv-v2/vault-demo/mysecret username=larry-rotated-1
```

VSO reconciles within `refreshAfter` (30s). Poll the Secret in the VSO
cluster until it flips:

```bash +exec
for i in $(seq 1 20); do
  v=$(kubectl --context kind-vso-lab get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d)
  echo "  attempt $i: $v"
  if [ "$v" = "larry-rotated-1" ]; then echo '  -> Secret updated automatically by VSO'; exit 0; fi
  sleep 3
done
echo 'ERROR: Secret did not sync to larry-rotated-1' >&2; exit 1
```

<!-- speaker_note: No pod restart, no manual sync -- VSO watches Vault across the cluster boundary and updates the Secret. This is the highlight of the demo -- the rotation happened in a completely different cluster from the one running the app. -->

<!-- end_slide -->

7c — Reset so the demo is repeatable
===================================

Reset the secret back to its original value (Vault cluster):

```bash +exec
kubectl --context kind-vault-lab exec vault-0 -n default -- vault kv put kv-v2/vault-demo/mysecret username=larry
```

Wait for the reset to sync (VSO cluster) so the next demo starts clean:

```bash +exec
for i in $(seq 1 20); do
  v=$(kubectl --context kind-vso-lab get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d)
  echo "  attempt $i: $v"
  if [ "$v" = "larry" ]; then echo '  -> Secret reset synced by VSO'; exit 0; fi
  sleep 3
done
echo 'ERROR: Secret did not reset to larry' >&2; exit 1
```

**Key points**

- No pod restart, no manual sync: VSO watches Vault and updates the Secret
  across the cluster boundary.
- We reset the value to `larry` so re-running the demo starts clean.

<!-- end_slide -->

Demo complete
=============

**What we proved**

- Vault runs only in `kind-vault-lab`; VSO, its CRDs, and the app run only in
  `kind-vso-lab`.
- The Vault Secrets Operator runs once, cluster-wide, in the VSO cluster.
- CRDs declaratively describe connection, auth, and what to sync.
- A pod in the VSO cluster reaches Vault over the Podman host network at a
  documented external address, and Vault validates its service account JWT
  cryptographically via a dedicated `auth/jwt-vso` JWT/OIDC mount that
  fetches the VSO cluster's own JWKS — no reviewer credential, no
  TokenReview callback.
- A wrong-audience JWT and a wrong-service-account JWT are both correctly
  rejected by Vault, proving the issuer/audience/subject claim binding is
  actually enforced.
- A Vault KV secret becomes a native Kubernetes Secret in the VSO cluster.
- A plain pod consumes it with zero Vault knowledge (`1/1`, no annotations).
- VSO's Vault identity is least-privilege (one role, one policy, one path).
- Changing the value in Vault refreshes the Kubernetes Secret automatically,
  even though Vault and the Secret live in different clusters.

<!-- column_layout: [1, 1] -->

<!-- column: 0 -->

**Agent Injector (single cluster)**

- Per-pod sidecar writes a secret file
- Pod is `2/2`
- Carries `vault.hashicorp.com` annotations
- Vault and the app share one cluster

<!-- column: 1 -->

**Vault Secrets Operator (two clusters, this demo)**

- Cluster-wide operator syncs into native Secrets
- App pods are `1/1`
- Vault-agnostic
- Vault lives in its own cluster; VSO/app live in another

<!-- reset_layout -->

**Useful follow-up commands**

```bash
make vso-verify
make vso-status
make verify-two-cluster
kubectl --context kind-vso-lab describe vaultstaticsecret vso-demo-mysecret -n vso-demo
```
