# 12. Update Documentation and Presenterm Slides

meta:
  id: vso-two-cluster-podman-12
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-11]
  tags: [implementation, tests-required]

objective:

- Update user-facing documentation and presentation material to describe the final two-cluster Podman-backed VSO demo.

deliverables:

- Updated `README.md` bootstrap, architecture, verification, and troubleshooting sections.
- Updated `PODMAN_MIGRATION.md` with two-cluster Podman Desktop requirements and host networking notes.
- Updated VSO design documentation if present.
- Updated `presenterm/vso.md` deck showing Vault and VSO in separate clusters.
- Documentation for `make setup`, targeted setup targets, `make verify-two-cluster`, and `make vso-demo`.

steps:

- Replace single-cluster bootstrap instructions with the two-cluster flow.
- Document `KIND_EXPERIMENTAL_PROVIDER=podman`, deterministic contexts, host port mappings, and `host.containers.internal` assumptions.
- Explain why `auth/kubernetes-vso` is separate from same-cluster `auth/kubernetes`.
- Update diagrams to show Vault cluster, VSO cluster, Vault external address, and VSO API TokenReview path.
- Add troubleshooting for Podman networking, expiring reviewer tokens, VSO reconciliation failures, and resource pressure from two clusters.
- Ensure docs reference final Make targets and verification command names.

tests:

- Unit: Link/path review for all referenced scripts, Make targets, and docs.
- Integration/e2e: Follow the README from a clean environment or compare instructions directly against working commands from previous tasks.

acceptance_criteria:

- README no longer instructs users to run the VSO demo as a single-cluster setup.
- Podman migration docs explicitly describe two clusters and cross-cluster networking assumptions.
- Presenterm slides show the target two-cluster architecture.
- Documentation explains the verification and troubleshooting path clearly.
- All referenced commands, scripts, and Make targets exist.

validation:

- Review `README.md`, `PODMAN_MIGRATION.md`, and `presenterm/vso.md` for stale single-cluster VSO references.
- Run or inspect `make help` and confirm documented targets match actual targets.
- Run `make verify-two-cluster` as the final implementation proof before marking docs complete.

notes:

- Preserve the customer-facing explanation of the original OTel metrics demo where it remains valid.
- Be explicit about demo-only security tradeoffs such as reviewer token handling.
