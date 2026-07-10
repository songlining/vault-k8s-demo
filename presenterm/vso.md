---
title: "Vault Secrets Operator (VSO) Demo"

sub_title: "Sync Vault secrets into native Kubernetes Secrets"

author: "Larry Song — HashiCorp Solutions Engineering"
---

This guided flow demonstrates the **Vault Secrets Operator**: a cluster-wide
operator that syncs Vault secrets into native Kubernetes Secret objects.

**The customer problem**

- Teams want Vault secrets, but their apps already consume native Kubernetes
  Secrets (`envFrom`, `secretKeyRef`, volume mounts).
- They do not want every workload to carry Vault-specific annotations or run a
  per-pod sidecar just to read a secret.
- They want secrets to stay in sync automatically when the source changes.

**What we will prove**

1. The Vault Secrets Operator is running cluster-wide.
2. Three CRDs declare how to reach Vault, how to authenticate, and what to sync.
3. A Vault KV secret is materialized as a native Kubernetes Secret.
4. A plain pod consumes it with zero Vault configuration.
5. The operator's Vault identity is least-privilege.
6. Updating the value in Vault refreshes the Kubernetes Secret automatically.

<!-- speaker_note: Launch with `presenterm -x presenterm/vso.md`. Run `make vso-verify` first to confirm the cluster is green. Press ctrl+e on each live block. -->

<!-- end_slide -->

1 — Architecture: how VSO delivers secrets
=========================================

VSO runs **once per cluster** and syncs Vault secrets into native K8s Secrets.
Your app reads a normal Secret and never talks to Vault.

```
 namespace: vault-secrets-operator-system  (cluster-wide)
   ┌─────────────────────────────┐
   │  VSO Controller (operator)  │
   └─────────────┬───────────────┘
                 │ watches / reconciles
 namespace: vso-demo
   ┌─────────────▼───────────────────────────────────┐
   │  VaultConnection → VaultAuth → VaultStaticSecret│  (CRDs)
   └─────────────┬───────────────────────────────────┘
                 │ syncs into
   ┌─────────────▼───────────────┐
   │  Secret: vso-demo-mysecret  │  native K8s Secret
   └─────────────┬───────────────┘
                 │ envFrom (standard K8s)
   ┌─────────────▼───────────────┐
   │  Pod: vso-demo-app          │  1/1, no sidecar, no Vault config
   └─────────────────────────────┘

 namespace: default  —  Vault (vault-0): auth/kubernetes · kv-v2/vault-demo/mysecret
```

<!-- speaker_note: It watches CRDs you define, logs into Vault on your behalf, and syncs secrets into native Kubernetes Secret objects. The app consumes via envFrom, secretKeyRef, or a volume mount — zero Vault awareness. -->

<!-- end_slide -->

1b — Step-by-step flow
=====================

```
 vso-demo ns:  VaultConnection → VaultAuth → VaultStaticSecret   (CRDs)
        │  (1) VSO controller watches these CRDs
        ▼
 vault-secrets-operator-system:  VSO Controller
        │  (2) login with vso-demo SA JWT, then read secret
        ▼
 default ns:  Vault (vault-0)
              auth/kubernetes · role vso-demo · policy mysecret
              kv-v2/vault-demo/mysecret
        │  (3) writes / refreshes every 30s
        ▼
 vso-demo ns:  Secret vso-demo-mysecret   (native K8s Secret)
        │  (4) envFrom — standard Kubernetes API
        ▼
 vso-demo ns:  Pod vso-demo-app   (no Vault annotations, no sidecar)
```

Unlike the Agent Injector (a sidecar per pod that writes a file), VSO runs once
per cluster and turns Vault secrets into first-class Kubernetes Secrets any app
can consume with zero Vault knowledge.

<!-- end_slide -->

2 — The operator is running
==========================

The Vault Secrets Operator runs as a cluster-wide controller:

```bash +exec
kubectl get pods -n vault-secrets-operator-system
```

**Key points**

- One operator Deployment serves the whole cluster.
- There is no per-application sidecar in this model.

<!-- end_slide -->

3 — The CRDs that drive the sync
===============================

Three declarative objects describe the whole pipeline:

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
kubectl get vaultconnection,vaultauth,vaultstaticsecret -n vso-demo
```

<!-- end_slide -->

3b — What the VaultStaticSecret declares
=======================================

The VaultStaticSecret declares the Vault path and the destination Secret:

```bash +exec
kubectl get vaultstaticsecret vso-demo-mysecret -n vso-demo -o jsonpath='{"  mount: "}{.spec.mount}{"\n  path: "}{.spec.path}{"\n  type: "}{.spec.type}{"\n  refreshAfter: "}{.spec.refreshAfter}{"\n  destination: "}{.spec.destination.name}{"\n"}'
```

**Key points**

- **VaultConnection**: how to reach Vault (in-cluster service URL).
- **VaultAuth**: reuse the existing kubernetes auth method with role `vso-demo`.
- **VaultStaticSecret**: read `kv-v2/vault-demo/mysecret`, refresh every 30s, and
  materialize it as the native Secret `vso-demo-mysecret`.

<!-- end_slide -->

4 — The native Kubernetes Secret VSO created
===========================================

VSO wrote a standard Kubernetes Secret (not a file in a pod):

```bash +exec
kubectl get secret vso-demo-mysecret -n vso-demo
```

Decode the synced value:

```bash +exec
kubectl get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d; echo
```

**Key points**

- This is a first-class Secret object any workload can consume.
- The value came from Vault, but the object is pure Kubernetes.

<!-- end_slide -->

5 — A plain pod consumes it with zero Vault config
=================================================

The app reads the secret through standard `envFrom` at pod start:

```bash +exec
kubectl exec vso-demo-app -n vso-demo -- printenv username
```

The consuming pod has **NO** Vault annotations and **NO** sidecar (count = 0):

```bash +exec
kubectl get pod vso-demo-app -n vso-demo -o yaml | grep -c 'vault.hashicorp.com' || true
```

It is a single-container pod (`1/1`), not `2/2` like an injected sidecar pod:

```bash +exec
kubectl get pod vso-demo-app -n vso-demo
```

<!-- speaker_note: envFrom values are captured when a pod starts; later Secret refreshes update the Secret object, not the existing process environment. Contrast with the Agent Injector demo, where pods are 2/2 and carry vault.hashicorp.com annotations. -->

<!-- end_slide -->

6 — Least-privilege Vault identity
=================================

VSO authenticates as a dedicated, narrowly-scoped Kubernetes auth role:

```bash +exec
kubectl exec vault-0 -n default -- vault read auth/kubernetes/role/vso-demo | grep -E 'bound_service_account_names|bound_service_account_namespaces|token_policies|policies'
```

The `mysecret` policy only allows reading this one KV path:

```bash +exec
kubectl exec vault-0 -n default -- vault policy read mysecret
```

**Key points**

- The role only maps `vso-demo/vso-demo` to the `mysecret` policy.
- The policy grants read on a single KV path and nothing else.

<!-- end_slide -->

7 — Live rotation: change Vault, watch the Secret update
=======================================================

Seed Vault with the original value so rotation starts from a known baseline:

```bash +exec
kubectl exec vault-0 -n default -- vault kv put kv-v2/vault-demo/mysecret username=larry
```

Wait for VSO to sync the baseline value into the Kubernetes Secret:

```bash +exec
for i in $(seq 1 20); do
  v=$(kubectl get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d)
  echo "  attempt $i: $v"
  if [ "$v" = "larry" ]; then echo '  -> Secret synced to baseline by VSO'; exit 0; fi
  sleep 3
done
echo 'ERROR: Secret did not sync to larry' >&2; exit 1
```

<!-- end_slide -->

7b — Rotate the value in Vault
=============================

Current value in the native Kubernetes Secret:

```bash +exec
kubectl get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d; echo
```

Update the value in Vault:

```bash +exec
kubectl exec vault-0 -n default -- vault kv put kv-v2/vault-demo/mysecret username=larry-rotated-1
```

VSO reconciles within `refreshAfter` (30s). Poll the Secret until it flips:

```bash +exec
for i in $(seq 1 20); do
  v=$(kubectl get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d)
  echo "  attempt $i: $v"
  if [ "$v" = "larry-rotated-1" ]; then echo '  -> Secret updated automatically by VSO'; exit 0; fi
  sleep 3
done
echo 'ERROR: Secret did not sync to larry-rotated-1' >&2; exit 1
```

<!-- speaker_note: No pod restart, no manual sync — VSO watches Vault and updates the Secret. This is the highlight of the demo. -->

<!-- end_slide -->

7c — Reset so the demo is repeatable
===================================

Reset the secret back to its original value:

```bash +exec
kubectl exec vault-0 -n default -- vault kv put kv-v2/vault-demo/mysecret username=larry
```

Wait for the reset to sync so the next demo starts clean:

```bash +exec
for i in $(seq 1 20); do
  v=$(kubectl get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d)
  echo "  attempt $i: $v"
  if [ "$v" = "larry" ]; then echo '  -> Secret reset synced by VSO'; exit 0; fi
  sleep 3
done
echo 'ERROR: Secret did not reset to larry' >&2; exit 1
```

**Key points**

- No pod restart, no manual sync: VSO watches Vault and updates the Secret.
- We reset the value to `larry` so re-running the demo starts clean.

<!-- end_slide -->

Demo complete
=============

**What we proved**

- The Vault Secrets Operator runs once, cluster-wide.
- CRDs declaratively describe connection, auth, and what to sync.
- A Vault KV secret becomes a native Kubernetes Secret.
- A plain pod consumes it with zero Vault knowledge (`1/1`, no annotations).
- VSO's Vault identity is least-privilege (one role, one policy, one path).
- Changing the value in Vault refreshes the Kubernetes Secret automatically.

<!-- column_layout: [1, 1] -->

<!-- column: 0 -->

**Agent Injector**

- Per-pod sidecar writes a secret file
- Pod is `2/2`
- Carries `vault.hashicorp.com` annotations

<!-- column: 1 -->

**Vault Secrets Operator**

- Cluster-wide operator syncs into native Secrets
- App pods are `1/1`
- Vault-agnostic

<!-- reset_layout -->

**Useful follow-up commands**

```bash
make vso-verify
make vso-status
kubectl describe vaultstaticsecret vso-demo-mysecret -n vso-demo
```
