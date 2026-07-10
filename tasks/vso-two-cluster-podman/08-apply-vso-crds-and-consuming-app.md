# 08. Apply VSO CRDs and Consuming App in VSO Cluster

meta:
  id: vso-two-cluster-podman-08
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-05, vso-two-cluster-podman-07]
  tags: [implementation, tests-required]

objective:

- Apply VSO custom resources and the consuming demo app in the VSO cluster using the external Vault address and dedicated auth mount.

deliverables:

- Context-aware manifest application in `scripts/setup-vso-cluster.sh`, a new `scripts/apply-vso-demo.sh`, or equivalent.
- `VaultConnection` with `spec.address` set to the external Vault address such as `http://host.containers.internal:8200`.
- `VaultAuth` with `mount: kubernetes-vso`, role `vso-demo`, and service account `vso-demo`.
- `VaultStaticSecret` syncing `kv-v2/vault-demo/mysecret` into `vso-demo-mysecret`.
- Plain `vso-demo-app` consuming the native Secret with no Vault annotations or sidecar.

steps:

- Ensure the Vault secret is seeded to the baseline value in the Vault cluster.
- Apply `VaultConnection`, `VaultAuth`, and `VaultStaticSecret` in the VSO cluster.
- Apply or recreate the consuming app pod in the VSO cluster.
- Wait for the native Secret to materialize with the expected value.
- Ensure no VSO CRDs are applied in the Vault cluster.

tests:

- Unit: Manifest review for address, mount, role, namespace, and service account values.
- Integration/e2e: Confirm VSO reconciles the native Secret and the app pod reads it through envFrom.

acceptance_criteria:

- `VaultConnection`, `VaultAuth`, and `VaultStaticSecret` exist only in `kind-vso-lab`.
- `VaultConnection.spec.address` uses the external Vault address, not `vault.default.svc.cluster.local`.
- `VaultAuth.spec.mount` is `kubernetes-vso`.
- Native Secret `vso-demo-mysecret` contains `username=larry` after reconciliation.
- `vso-demo-app` is a single-container pod with no Vault annotations.

validation:

- Run `kubectl --context kind-vso-lab get vaultconnection,vaultauth,vaultstaticsecret -n vso-demo`.
- Run `kubectl --context kind-vso-lab get secret vso-demo-mysecret -n vso-demo -o jsonpath='{.data.username}' | base64 -d; echo`.
- Run `kubectl --context kind-vso-lab exec vso-demo-app -n vso-demo -- printenv username`.
- Run `kubectl --context kind-vso-lab get pod vso-demo-app -n vso-demo -o yaml | grep -c 'vault.hashicorp.com' || true` and confirm zero.

notes:

- Kubernetes envFrom captures values at pod start; this affects demo copy and rotation explanation.
