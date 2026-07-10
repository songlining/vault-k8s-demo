# 10. Update Demo Scripts to Use Explicit Contexts

meta:
  id: vso-two-cluster-podman-10
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-08]
  tags: [implementation, tests-required]

objective:

- Update guided demo scripts so every Kubernetes and Vault operation targets the correct cluster explicitly.

deliverables:

- Updated `vso-demo.sh` with explicit `VAULT_CONTEXT` and `VSO_CONTEXT` usage.
- Updated `demo.sh` if the broader demo flow references VSO or assumes a single cluster.
- Updated architecture diagrams/output in demo scripts to show two clusters.
- Demo commands that inspect Vault use the Vault context; commands that inspect VSO resources use the VSO context.

steps:

- Source shared context/preflight helpers from demo scripts.
- Update `verify_ready` to check Vault readiness in the Vault cluster and VSO/app readiness in the VSO cluster.
- Replace every `kubectl` invocation with the correct explicit context.
- Update narrative text and diagrams from single-cluster to two-cluster architecture.
- Update rotation commands so writes happen through the Vault cluster and reads happen through the VSO cluster.

tests:

- Unit: Review every `kubectl` command in demo scripts for explicit context.
- Integration/e2e: Run `NO_WAIT=true ./vso-demo.sh` or equivalent non-interactive mode end-to-end.

acceptance_criteria:

- `vso-demo.sh` succeeds when the current kubectl context is unrelated to both demo clusters.
- Vault commands in the demo target `VAULT_CONTEXT`.
- VSO CRD, native Secret, app pod, and VSO operator log/status commands target `VSO_CONTEXT`.
- The displayed architecture clearly shows Vault and VSO in separate clusters.
- Secret rotation still demonstrates Vault-to-VSO sync.

validation:

- Set current context to a non-demo context if available, then run `NO_WAIT=true ./vso-demo.sh`.
- Search `vso-demo.sh` for `kubectl ` and confirm each usage includes `--context` directly or through an approved helper.
- Confirm the demo prints two-cluster architecture text.

notes:

- Keep the script presentation-friendly; avoid excessive internal implementation details in customer-facing output.
