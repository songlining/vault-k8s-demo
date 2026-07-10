# VSO two-cluster Podman Desktop migration plan

## Goal

Update the VSO demo from a single kind cluster to two Podman-backed kind clusters:

- Vault cluster: runs Vault server and owns Vault configuration/secrets.
- VSO cluster: runs Vault Secrets Operator, VSO CRDs, and the consuming demo app.

## Key design change

The single-cluster assumptions must be removed:

- `vault.default.svc.cluster.local` only works inside the Vault cluster.
- `auth/kubernetes` currently validates service account JWTs from the Vault cluster.
- VSO in a second cluster needs a Vault address reachable from the VSO cluster.
- Vault needs a Kubernetes auth mount configured against the VSO cluster API server so it can validate VSO service account JWTs.

## Target architecture

```text
Podman Desktop

kind-vault-lab cluster
  default/vault-0
  Vault service exposed to host/podman network, e.g. http://host.containers.internal:8200
  Vault auth mount: auth/kubernetes-vso
    -> TokenReview against kind-vso-lab API server
    -> role vso-demo bound to vso-demo/vso-demo
  kv-v2/vault-demo/mysecret

kind-vso-lab cluster
  vault-secrets-operator-system/vault-secrets-operator
  vso-demo namespace
  ServiceAccounts:
    - vso-demo
    - vault-token-reviewer
  VaultConnection -> external Vault address
  VaultAuth -> mount kubernetes-vso, role vso-demo
  VaultStaticSecret -> kv-v2/vault-demo/mysecret -> vso-demo-mysecret
  vso-demo-app -> envFrom vso-demo-mysecret
```

## Implementation phases

1. Podman/kind cluster bootstrap
   - Add explicit two-cluster creation flow.
   - Require `KIND_EXPERIMENTAL_PROVIDER=podman`.
   - Use deterministic contexts:
     - `VAULT_CONTEXT=kind-vault-lab`
     - `VSO_CONTEXT=kind-vso-lab`
   - Use kind config files or generated manifests so ports are deterministic.

2. Cross-cluster network contract
   - Expose Vault from the Vault cluster through a stable address reachable by pods in the VSO cluster.
   - Recommended demo path: Vault NodePort plus kind `extraPortMappings` to host port `8200`, then VSO uses `http://host.containers.internal:8200`.
   - Expose or address the VSO API server in a way Vault can use for Kubernetes TokenReview.
   - Recommended demo path: static VSO API host port, e.g. `6444`, plus kube-apiserver cert SAN for `host.containers.internal`, then Vault uses `https://host.containers.internal:6444`.

3. Split setup scripts
   - Refactor `create_vault.sh` into context-aware steps rather than implicit current-context setup.
   - Proposed scripts:
     - `scripts/create-clusters.sh`
     - `scripts/setup-vault-cluster.sh`
     - `scripts/setup-vso-cluster.sh`
     - `scripts/configure-vso-kubernetes-auth.sh`
   - Keep a top-level `make setup` that runs the full two-cluster flow.
   - Add faster targeted targets:
     - `make clusters`
     - `make setup-vault`
     - `make setup-vso`
     - `make configure-vso-auth`

4. Vault cluster setup
   - Install Vault via Helm on `VAULT_CONTEXT`.
   - Initialise/unseal as today, using existing local key file behaviour.
   - Enable `kv-v2` and seed `kv-v2/vault-demo/mysecret`.
   - Create `mysecret` policy.
   - Create a service or patch exposing Vault through NodePort/host port.
   - Configure a dedicated auth mount for the VSO cluster, e.g. `auth/kubernetes-vso`, not the existing same-cluster `auth/kubernetes`.

5. VSO cluster setup
   - Install VSO via Helm on `VSO_CONTEXT`.
   - Create `vso-demo` namespace and service accounts.
   - Create RBAC for `vault-token-reviewer` to call TokenReview.
   - Generate/refresh the reviewer JWT during setup.
   - Apply VSO CRDs using:
     - `VaultConnection.spec.address=http://host.containers.internal:8200`
     - `VaultAuth.spec.mount=kubernetes-vso`
     - `VaultAuth.spec.kubernetes.role=vso-demo`
   - Create the consuming pod in the VSO cluster.

6. Demo script updates
   - Make every `kubectl` call context-explicit.
   - Commands that inspect/update Vault use `--context "$VAULT_CONTEXT"`.
   - Commands that inspect VSO CRDs, synced Secret, app pod, and VSO logs use `--context "$VSO_CONTEXT"`.
   - Update architecture output and presenterm slides to show two clusters.

7. Verification
   - Add `make verify-two-cluster` or extend `make vso-verify`.
   - Verify:
     - both contexts exist and point to different clusters;
     - Vault is reachable from a pod in the VSO cluster;
     - Vault can reach the VSO API server for TokenReview;
     - VSO operator is available;
     - `VaultStaticSecret` reconciles successfully;
     - synced native Secret decodes to the expected value;
     - rotation from Vault cluster updates the Secret in the VSO cluster.

8. Documentation updates
   - Update README and `PODMAN_MIGRATION.md`.
   - Replace single-cluster bootstrap commands with two-cluster commands.
   - Document the cross-cluster networking assumptions and troubleshooting.
   - Update VSO design doc and presenterm deck.

## Main risks

- Podman Desktop host networking can differ by OS/version. Add preflight checks for `host.containers.internal` reachability from kind pods.
- Kubernetes auth TokenReview requires Vault to reach the VSO cluster API server and trust its CA/cert SAN.
- Reviewer tokens created with `kubectl create token` expire; setup should refresh them, or the demo must use a clearly documented long-lived demo-only token.
- Running two kind clusters consumes more resources than the previous single-cluster flow.

## Acceptance criteria

- `make setup` creates/configures two Podman-backed kind clusters end-to-end.
- Vault runs only in the Vault cluster.
- VSO, its CRDs, and the app pod run only in the VSO cluster.
- VSO syncs `kv-v2/vault-demo/mysecret` from Vault into a native Secret in the VSO cluster.
- `make vso-demo` runs end-to-end with context-explicit commands.
- Secret rotation performed in the Vault cluster appears in the VSO cluster Secret within the configured refresh window.
