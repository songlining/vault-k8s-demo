# 01. Audit Current Single-Cluster Assumptions

meta:
  id: vso-two-cluster-podman-01
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: []
  tags: [implementation, tests-required]

objective:

- Identify every script, Make target, manifest, and document that assumes Vault and VSO run in the same Kubernetes cluster.

deliverables:

- A concise audit note committed in `docs/vso-two-cluster-audit.md` or equivalent.
- Inline TODO-free source changes only if needed to support later tasks; prefer documentation in this task.
- A categorized list of files requiring follow-up edits for setup, networking, auth, demos, verification, and docs.

steps:

- Read `docs/vso-two-cluster-podman-plan.md` and use it as the source migration plan.
- Inspect `create_vault.sh`, `vso-demo.sh`, `Makefile`, `README.md`, `PODMAN_MIGRATION.md`, `presenterm/vso.md`, and any VSO-related manifests or docs.
- Record all uses of implicit current context, in-cluster Vault DNS such as `vault.default.svc.cluster.local`, `auth/kubernetes`, same-cluster TokenReview, and same-cluster VSO CRD assumptions.
- Group findings by follow-up task number so downstream tasks know where to edit.

tests:

- Unit: Not applicable; this is an audit task.
- Integration/e2e: Validate the audit by searching for the identified patterns and confirming every occurrence is categorized.

acceptance_criteria:

- The audit identifies all known single-cluster assumptions in setup scripts, demo scripts, Make targets, and docs.
- The audit maps each assumption to a later task or explicitly marks it as intentionally unchanged.
- The audit references `docs/vso-two-cluster-podman-plan.md` as the governing plan.

validation:

- Run pattern searches for `kubectl `, `helm `, `vault.default.svc.cluster.local`, `auth/kubernetes`, `vso-demo`, and `vault-secrets-operator` and confirm each relevant occurrence appears in the audit.
- Review `docs/vso-two-cluster-audit.md` and verify it contains setup, networking, auth, demo, verification, and documentation sections.

notes:

- Assumption source: `docs/vso-two-cluster-podman-plan.md`.
- Do not implement the migration in this task; keep it focused on discovery and task handoff quality.
