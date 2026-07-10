# 06. Refactor VSO Cluster Setup

meta:
  id: vso-two-cluster-podman-06
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-02, vso-two-cluster-podman-03]
  tags: [implementation, tests-required]

objective:

- Install Vault Secrets Operator and create VSO demo namespace/service accounts only in the VSO cluster.

deliverables:

- `scripts/setup-vso-cluster.sh` or equivalent context-aware VSO cluster setup script.
- VSO Helm install using `VSO_CONTEXT` only.
- `vso-demo` namespace and required service accounts in `kind-vso-lab` only.
- RBAC for `vault-token-reviewer` or the selected reviewer identity to call TokenReview in the VSO cluster.

steps:

- Extract VSO operator installation and namespace/service-account setup from `create_vault.sh`.
- Source shared context/preflight helpers.
- Add `--kube-context "$VSO_CONTEXT"` to Helm operations and `--context "$VSO_CONTEXT"` to all kubectl operations.
- Create `vso-demo` and `vault-token-reviewer` service accounts as required by the cross-cluster auth design.
- Add TokenReview RBAC in the VSO cluster.
- Do not configure Vault auth or apply VSO CRDs in this task unless they are necessary for setup scaffolding.

tests:

- Unit: Shell syntax check and review every kubectl/helm command for explicit VSO context.
- Integration/e2e: Run the VSO setup after cluster bootstrap and verify the operator deployment becomes available.

acceptance_criteria:

- VSO operator runs only in `kind-vso-lab`.
- `vso-demo` namespace and service accounts exist only in the VSO cluster.
- TokenReview RBAC exists in the VSO cluster for the reviewer identity.
- The script succeeds regardless of the user's current kubectl context.

validation:

- Run `scripts/setup-vso-cluster.sh` with `VSO_CONTEXT=kind-vso-lab`.
- Run `kubectl --context kind-vso-lab wait -n vault-secrets-operator-system --for=condition=Available deployment -l app.kubernetes.io/name=vault-secrets-operator --timeout=180s`.
- Run `kubectl --context kind-vault-lab get ns vault-secrets-operator-system` and confirm VSO is absent from the Vault cluster.

notes:

- Keep this task focused on the VSO cluster prerequisites; Vault auth comes next.
