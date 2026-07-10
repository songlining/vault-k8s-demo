# 09. Update Make Targets for Two-Cluster Workflow

meta:
  id: vso-two-cluster-podman-09
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-08]
  tags: [implementation, tests-required]

objective:

- Update Make targets so users can run the full two-cluster setup and targeted setup steps through stable commands.

deliverables:

- Updated `Makefile` with two-cluster targets.
- `make setup` running the full two-cluster flow.
- Targeted targets: `make clusters`, `make setup-vault`, `make setup-vso`, `make configure-vso-auth`, and a VSO demo apply/setup target if needed.
- Updated help text describing contexts and Podman assumptions.

steps:

- Replace or adapt the current single-cluster `setup` target.
- Add targets that call the scripts created in earlier tasks.
- Ensure Make targets pass through environment variables such as `VAULT_CONTEXT`, `VSO_CONTEXT`, `VAULT_ADDR`, and `VSO_API_ADDR` naturally.
- Keep existing demo/verify/status targets where still valid, or split them clearly between old and two-cluster flows.

tests:

- Unit: Run `make help` and verify target descriptions are accurate.
- Integration/e2e: Run each targeted target in sequence and then run `make setup` on a fresh environment.

acceptance_criteria:

- `make clusters` creates or validates both clusters.
- `make setup-vault` configures Vault only in the Vault cluster.
- `make setup-vso` configures VSO only in the VSO cluster.
- `make configure-vso-auth` configures `auth/kubernetes-vso` in Vault.
- `make setup` orchestrates the complete two-cluster flow end-to-end.

validation:

- Run `make help`.
- Run `make clusters`, `make setup-vault`, `make setup-vso`, `make configure-vso-auth`, and the VSO apply target if separate.
- Run `make setup` in a clean or reset demo environment and confirm it completes.

notes:

- Preserve user-facing simplicity: `make setup` should remain the primary command.
