# VSO JWT/OIDC Auth — Spike 01: Cluster Issuer, OIDC Discovery, JWKS Reachability

Investigation note for `tasks/vso-jwt-oidc-auth/01-spike-oidc-discovery-and-jwks.md`.
Linked from `docs/vso-jwt-oidc-auth-plan.md` Phase 1.

## Goal

Determine the exact VSO cluster service account issuer/JWKS configuration
Vault can use for JWT/OIDC auth (`auth/jwt-vso`) without TokenReview, and
decide between `oidc_discovery_url` and `jwks_url`.

## Environment

- `VAULT_CONTEXT=kind-vault-lab`, `VSO_CONTEXT=kind-vso-lab` (Podman-backed kind, per `scripts/lib/two-cluster-env.sh`).
- `VSO_API_ADDR=https://host.containers.internal:6444` (externally reachable mapping to the VSO cluster's API server, see `scripts/kind/vso-lab-config.yaml.tmpl`).
- Vault runs in `kind-vault-lab` namespace `default`, pod `vault-0`.
- `vso-demo` service account exists in namespace `vso-demo` of `kind-vso-lab` (created by `scripts/setup-vso-cluster.sh`).

## Step 1 — Mint a `vso-demo` JWT with audience `vault`

```bash
kubectl --context kind-vso-lab create token vso-demo \
  -n vso-demo \
  --audience vault \
  --duration 10m
```

## Step 2 — Decode the JWT payload

Deterministic decode command (no extra deps beyond python3; jq with `-R`/base64 works equivalently):

```bash
TOKEN=$(kubectl --context kind-vso-lab create token vso-demo -n vso-demo --audience vault --duration 10m)
python3 -c "
import sys, json, base64
token = '''$TOKEN'''
payload_b64 = token.split('.')[1]
padded = payload_b64 + '=' * (-len(payload_b64) % 4)
payload = json.loads(base64.urlsafe_b64decode(padded))
print(json.dumps(payload, indent=2))
"
```

**Recorded evidence** (values are deterministic in shape; `exp`/`iat`/`jti`/`uid` vary per mint):

```json
{
  "aud": ["vault"],
  "iss": "https://kubernetes.default.svc.cluster.local",
  "sub": "system:serviceaccount:vso-demo:vso-demo",
  "kubernetes.io": {
    "namespace": "vso-demo",
    "serviceaccount": {
      "name": "vso-demo",
      "uid": "9183679b-f4ff-4bad-8d7a-d0df5d24ba52"
    }
  }
}
```

Claims confirmed:

| Claim | Value |
|---|---|
| `iss` | `https://kubernetes.default.svc.cluster.local` |
| `sub` | `system:serviceaccount:vso-demo:vso-demo` |
| `aud` | `["vault"]` |
| namespace | `vso-demo` |
| service account | `vso-demo` |

This matches the acceptance criteria: `sub` is exactly
`system:serviceaccount:vso-demo:vso-demo`, and `aud` includes `vault`.

## Step 3 — Check VSO API server discovery endpoints

Default kind clusters do **not** set `service-account-issuer` explicitly, so
the API server falls back to `https://kubernetes.default.svc.cluster.local`
— a Kubernetes-internal DNS name that only resolves *inside* the cluster
that owns it. This is the critical finding driving the decision below.

### 3a. Discovery document (queried directly by path, bypassing the `iss` value)

```bash
curl -sk https://host.containers.internal:6444/.well-known/openid-configuration
```

Initial result: **HTTP 403** (`system:anonymous cannot get path`).

Root cause: default kubeadm/kind RBAC (`ClusterRole/system:public-info-viewer`,
bound to `system:authenticated` + `system:unauthenticated`) only covers:

```text
/healthz
/livez
/readyz
/version
/version/
```

It does **not** include `/.well-known/openid-configuration` or
`/openid/v1/jwks`. These OIDC endpoints exist and route correctly (proven by
the 403 coming from RBAC, not a 404), but are not part of the default
"public info" grant. **This is a required new deliverable**, not covered by
the existing plan phases: something must grant read access to these two
paths for unauthenticated callers (Vault's JWT auth does not send a bearer
token when fetching JWKS/discovery).

Fix applied for this spike (and recommended as a permanent addition to
`scripts/setup-vso-cluster.sh`, see Decision below):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: oidc-discovery-reader
rules:
- nonResourceURLs:
  - /.well-known/openid-configuration
  - /openid/v1/jwks
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-discovery-reader-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: oidc-discovery-reader
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:unauthenticated
```

After applying this, from the local host (outside either cluster):

```bash
curl -sk https://127.0.0.1:6444/.well-known/openid-configuration
```

```json
{
  "issuer": "https://kubernetes.default.svc.cluster.local",
  "jwks_uri": "https://10.89.0.5:6443/openid/v1/jwks",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"]
}
```

Two problems with using this discovery document as-is for `oidc_discovery_url`:

1. `issuer` is `https://kubernetes.default.svc.cluster.local`. Vault's OIDC
   discovery client fetches `${oidc_discovery_url}/.well-known/openid-configuration`
   using the configured `oidc_discovery_url` value itself, and also expects
   the document to be served at the issuer's own well-known path. If
   `oidc_discovery_url` were set to this cluster-internal DNS name, Vault
   (running in `kind-vault-lab`) cannot resolve or route to it at all — see
   Step 4.
2. `jwks_uri` in the document is `https://10.89.0.5:6443/openid/v1/jwks` —
   the VSO control-plane node's Podman-bridge IP. This is not a stable,
   externally addressable location (Podman bridge IPs can collide/change
   across clusters on the same host) and is not guaranteed reachable from
   another cluster's pod network namespace.

### 3b. JWKS endpoint (queried directly by the externally-mapped host:port)

```bash
curl -sk https://127.0.0.1:6444/openid/v1/jwks
```

```json
{
  "keys": [
    {
      "use": "sig",
      "kty": "RSA",
      "kid": "0YLcg7_GNQh15A5cloNs7GaRolFe7waTJIXuhLrN5do",
      "alg": "RS256",
      "n": "...",
      "e": "AQAB"
    }
  ]
}
```

This is the **same signing key** referenced by the `kid` in the JWT header
of the token minted in Step 1/2 — confirmed by matching `kid` values. This
path, served on the externally-mapped `host.containers.internal:6444`, is
what the demo should use directly.

## Step 4 — Reachability proof from the Vault cluster

Vault's container image (`vault-0` in `kind-vault-lab`) has no `curl`;
`busybox wget` is present but only verifies TLS if given a CA bundle via the
`SSL_CERT_FILE` environment variable (no `--ca-certificate` flag in this
busybox build).

```bash
# Copy the VSO cluster's CA (from local kubeconfig, same source used by
# scripts/configure-vso-kubernetes-auth.sh) into the Vault pod.
VSO_CLUSTER_NAME=$(kubectl config view --raw -o jsonpath='{.contexts[?(@.name=="kind-vso-lab")].context.cluster}')
kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${VSO_CLUSTER_NAME}\")].cluster.certificate-authority-data}" \
  | base64 --decode > /tmp/vso-ca.pem
kubectl --context kind-vault-lab cp /tmp/vso-ca.pem default/vault-0:/tmp/vso-ca.pem

kubectl --context kind-vault-lab exec vault-0 -n default -- sh -c '
  cat /etc/ssl/certs/ca-certificates.crt /tmp/vso-ca.pem > /tmp/combined-ca.pem
  echo "-- discovery --"
  SSL_CERT_FILE=/tmp/combined-ca.pem wget -q -S -O /dev/null https://host.containers.internal:6444/.well-known/openid-configuration 2>&1 | grep "HTTP/"
  echo "-- jwks --"
  SSL_CERT_FILE=/tmp/combined-ca.pem wget -q -S -O /dev/null https://host.containers.internal:6444/openid/v1/jwks 2>&1 | grep "HTTP/"
'
```

**Result:**

```text
-- discovery --
  HTTP/1.1 200 OK
-- jwks --
  HTTP/1.1 200 OK
```

Both the discovery document and the JWKS document, served at
`https://host.containers.internal:6444/...`, are reachable and return
`HTTP 200` from inside the Vault cluster, once (a) the VSO cluster CA is
trusted and (b) the `oidc-discovery-reader` RBAC grant above is applied.

### Negative control — the self-advertised internal addresses are NOT usable

Proving why the discovery document's own `issuer`/`jwks_uri` values cannot be
used directly, from the same Vault pod:

```bash
kubectl --context kind-vault-lab exec vault-0 -n default -- sh -c '
  timeout 5 wget -q -O - https://kubernetes.default.svc.cluster.local/.well-known/openid-configuration
  echo "exit:$?"
'
# TLS certificate verify failed -- this hostname resolves inside
# kind-vault-lab to *that* cluster's own kubernetes.default Service, an
# entirely different API server than the VSO cluster's. Confirms this
# issuer string is cluster-relative, not a globally resolvable identity.

kubectl --context kind-vault-lab exec vault-0 -n default -- sh -c '
  timeout 5 wget -q -O - https://10.89.0.5:6443/openid/v1/jwks
  echo "exit:$?"
'
# TLS certificate verify failed / not a stable cross-cluster address --
# Podman bridge IPs are not part of the supported cross-cluster contract
# (only host.containers.internal + the mapped host ports are, per
# scripts/lib/two-cluster-env.sh).
```

Both fail (TLS verification failure against the supplied VSO CA), confirming
these internal-only values must never be configured directly into Vault.

## Decision

**Use `jwks_url`, not `oidc_discovery_url`, for `auth/jwt-vso`.**

```bash
vault write auth/jwt-vso/config \
  jwks_url="https://host.containers.internal:6444/openid/v1/jwks" \
  jwks_ca_pem="$VSO_CA_PEM" \
  bound_issuer="https://kubernetes.default.svc.cluster.local"
```

Rationale:

- `jwks_url` mode fetches keys directly from the URL Vault is given. It does
  **not** fetch or trust the OIDC discovery document's self-reported
  `issuer`/`jwks_uri` fields, so the internal-only values found in Step 3a
  are never used for routing — only the externally-reachable
  `https://host.containers.internal:6444/openid/v1/jwks` path is used, and it
  is proven reachable in Step 4.
- `bound_issuer` is a pure string comparison against the token's `iss` claim
  — it does not need to be independently resolvable/reachable. Setting it to
  the actual (cluster-internal) `iss` value (`https://kubernetes.default.svc.cluster.local`)
  is safe and correct even though that URL itself is not reachable from
  Vault.
- `oidc_discovery_url` mode would additionally require Vault to resolve and
  fetch `${oidc_discovery_url}/.well-known/openid-configuration` at the
  issuer's own address, and (per the Kubernetes/OIDC discovery spec) the
  `issuer` field inside that document is expected to equal
  `oidc_discovery_url` — which is not achievable here without reconfiguring
  kind's `service-account-issuer` to an externally-reachable value (kind
  config change, task 02 territory). Since `jwks_url` mode already solves
  reachability without any kind config change, **task 02
  (`02-configure-kind-oidc-issuer.md`) is not required** for this demo: the
  default kind service account issuer is left as-is, and no
  `scripts/kind/vso-lab-config.yaml.tmpl` change is needed.
- This keeps the demo closer to a common production pattern for clusters
  whose issuer is not a public/routable URL: pin `jwks_url` +
  `bound_issuer`, with `jwks_ca_pem` for TLS trust, instead of relying on
  live discovery.

## New requirement surfaced (not in original plan phases)

The `oidc-discovery-reader` ClusterRole/ClusterRoleBinding (granting
`system:unauthenticated` GET on `/.well-known/openid-configuration` and
`/openid/v1/jwks`) is a **required addition**, since default kind/kubeadm
RBAC does not expose these paths. This spike applied it directly to
`kind-vso-lab` for evidence-gathering; a downstream task (`04-implement-vso-jwt-auth-setup`
or `05-refactor-vso-cluster-setup`) must add it idempotently to
`scripts/setup-vso-cluster.sh` (alongside, or replacing, the
`vault-token-reviewer` RBAC it currently creates) so `make setup` provisions
it automatically. It is currently applied out-of-band in the live
`kind-vso-lab` cluster used for this spike; it is **not yet captured in any
script** and will be lost if the cluster is recreated.

## Answers to the plan's Phase 1 questions

1. **Actual `iss` claim from `kind-vso-lab`:** `https://kubernetes.default.svc.cluster.local`.
2. **Is that issuer URL reachable from the Vault cluster?** No — it's a
   cluster-internal DNS name that resolves differently (to the wrong
   cluster's own API server) from `kind-vault-lab`.
3. **Does the issuer expose an OIDC discovery document?** Yes, at
   `/.well-known/openid-configuration` on the API server, but only reachable
   externally via the mapped `host.containers.internal:6444` path (not via
   the `issuer` value itself), and only after the RBAC grant above.
4. **Does the discovery document advertise a JWKS URL Vault can reach?** No
   — it advertises an internal Podman-bridge IP (`https://10.89.0.5:6443/openid/v1/jwks`)
   that is not part of the supported cross-cluster network contract.
5. **Does the API server certificate/SAN match the URL Vault uses?** Yes for
   `https://host.containers.internal:6444` (SAN added in
   `scripts/kind/vso-lab-config.yaml.tmpl`); not applicable/not matching for
   the internal issuer/jwks_uri strings, which is fine since those are never
   used directly under the `jwks_url` decision.
6. **`oidc_discovery_url` or `jwks_url`?** `jwks_url`, pointed at
   `https://host.containers.internal:6444/openid/v1/jwks`, with
   `bound_issuer` set to the real `iss` value and `jwks_ca_pem` set to the
   VSO cluster CA.

## Validation (repeatable)

```bash
# 1. Mint + decode, confirm iss/sub/aud
TOKEN=$(kubectl --context kind-vso-lab create token vso-demo -n vso-demo --audience vault --duration 10m)
python3 -c "
import json, base64
p = '$TOKEN'.split('.')[1]
p += '=' * (-len(p) % 4)
d = json.loads(base64.urlsafe_b64decode(p))
assert d['iss'] == 'https://kubernetes.default.svc.cluster.local'
assert d['sub'] == 'system:serviceaccount:vso-demo:vso-demo'
assert d['aud'] == ['vault']
print('OK: iss/sub/aud match recorded evidence')
"

# 2. Reachability from the Vault cluster (requires oidc-discovery-reader RBAC applied to kind-vso-lab)
kubectl --context kind-vault-lab exec vault-0 -n default -- sh -c \
  'SSL_CERT_FILE=/tmp/combined-ca.pem wget -q -S -O /dev/null https://host.containers.internal:6444/openid/v1/jwks 2>&1 | grep "HTTP/"'
# expect: HTTP/1.1 200 OK
```
