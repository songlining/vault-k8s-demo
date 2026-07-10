# 04. Refactor Vault Cluster Setup

meta:
  id: vso-two-cluster-podman-04
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-02, vso-two-cluster-podman-03]
  tags: [implementation, tests-required]

objective:

- Move Vault installation, initialization, unseal, KV seeding, baseline policies, and same-cluster Agent Injector demo setup into an explicit Vault-cluster setup script.

deliverables:

- `scripts/setup-vault-cluster.sh` or equivalent context-aware Vault setup script.
- Updated or preserved local key file behavior for `vault-init-keys.json`.
- Vault installed only on `VAULT_CONTEXT`.
- KV engine and baseline secrets/policies seeded in the Vault cluster.

steps:

- Extract the Vault-specific portion of `create_vault.sh` into a new script.
- Source shared context/preflight helpers from task 03.
- Add `--kube-context "$VAULT_CONTEXT"` to Helm operations and `--context "$VAULT_CONTEXT"` to all kubectl operations.
- Preserve idempotent init/unseal behavior and safe recovery from saved unseal keys.
- Preserve the original Agent Injector and OTel metrics demo resources in the Vault cluster unless intentionally split by a later task.
- Avoid installing VSO resources from this script.

tests:

- Unit: Shell syntax check and targeted dry-read review for every kubectl/helm command to ensure explicit context use.
- Integration/e2e: Run Vault setup after cluster bootstrap and verify Vault initializes, unseals, and seeds `kv-v2/vault-demo/mysecret`.

acceptance_criteria:

- Vault setup succeeds when the current kubectl context is neither Vault nor VSO.
- Vault resources are present in `kind-vault-lab` and absent from `kind-vso-lab`.
- The existing local unseal key file behavior remains documented and functional.
- No VSO operator or VSO CRDs are applied by this script.

validation:

- Run `scripts/setup-vault-cluster.sh` with `VAULT_CONTEXT=kind-vault-lab`.
- Run `kubectl --context kind-vault-lab get pod vault-0 -n default`.
- Run `kubectl --context kind-vso-lab get pod vault-0 -n default` and confirm Vault is absent there.
- Run `kubectl --context kind-vault-lab exec vault-0 -n default -- vault kv get kv-v2/vault-demo/mysecret`.

notes:

- Use `docs/vso-two-cluster-audit.md` from task 01 to avoid missing single-cluster assumptions.
