# 02. Add Podman Kind Two-Cluster Bootstrap

meta:
  id: vso-two-cluster-podman-02
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-01]
  tags: [implementation, tests-required]

objective:

- Add an explicit bootstrap flow that creates deterministic Podman-backed kind clusters for Vault and VSO.

deliverables:

- `scripts/create-clusters.sh` or equivalent two-cluster bootstrap script.
- Kind configuration files or generated manifests for `kind-vault-lab` and `kind-vso-lab`.
- Deterministic context names: `kind-vault-lab` and `kind-vso-lab`.
- Deterministic host port contracts for Vault and the VSO API server where required by later tasks.

steps:

- Require or validate `KIND_EXPERIMENTAL_PROVIDER=podman` before creating clusters.
- Create or reuse `kind-vault-lab` with a stable Vault host port mapping for port `8200`.
- Create or reuse `kind-vso-lab` with a stable Kubernetes API host port such as `6444` and certificate SAN support for `host.containers.internal` if supported by kind config.
- Make the script idempotent enough for demo workflows: existing clusters should be detected with clear output.
- Avoid relying on the user's current kubectl context.

tests:

- Unit: Shell validation for missing commands and missing `KIND_EXPERIMENTAL_PROVIDER=podman`.
- Integration/e2e: Run the bootstrap script on a clean machine or disposable environment and confirm both contexts exist.

acceptance_criteria:

- `scripts/create-clusters.sh` creates or validates both `kind-vault-lab` and `kind-vso-lab`.
- The script fails clearly when required tools or Podman provider settings are missing.
- The resulting kubeconfig contains both deterministic contexts.
- The configured ports match the cross-cluster networking plan.

validation:

- Run `KIND_EXPERIMENTAL_PROVIDER=podman scripts/create-clusters.sh`.
- Run `kubectl config get-contexts kind-vault-lab kind-vso-lab`.
- Run `kind get clusters` and confirm `vault-lab` and `vso-lab` or the intended cluster names are present.

notes:

- Follow the target architecture in `docs/vso-two-cluster-podman-plan.md`.
- Keep host port values centralized for later scripts.
