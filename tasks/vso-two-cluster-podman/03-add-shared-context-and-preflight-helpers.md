# 03. Add Shared Context Variables and Preflight Helpers

meta:
  id: vso-two-cluster-podman-03
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-01]
  tags: [implementation, tests-required]

objective:

- Add shared shell helpers so all setup and demo scripts use explicit Vault/VSO contexts, consistent names, and common preflight checks.

deliverables:

- A shared helper file such as `scripts/lib/two-cluster-env.sh`.
- Defaults for `VAULT_CONTEXT=kind-vault-lab`, `VSO_CONTEXT=kind-vso-lab`, `VAULT_ADDR`, `VSO_API_ADDR`, namespaces, chart versions, and resource names.
- Reusable functions for command checks, context checks, context-specific kubectl/helm wrappers, and basic Podman/kind network preflight output.

steps:

- Define canonical environment variables with override support.
- Add functions that validate `kubectl`, `kind`, `helm`, `jq`, and any other required commands.
- Add functions that assert the Vault and VSO contexts exist and are different.
- Add helper wrappers or documented patterns for `kubectl --context "$VAULT_CONTEXT"` and `kubectl --context "$VSO_CONTEXT"`.
- Add preflight checks for `host.containers.internal` assumptions that later tasks can reuse.

tests:

- Unit: Source the helper file in a shell and assert required variables and functions exist.
- Integration/e2e: Run helper validation with missing or renamed contexts and confirm clear failures.

acceptance_criteria:

- All shared defaults are centralized and overrideable through environment variables.
- Helpers never rely on `kubectl config current-context` for correctness.
- Preflight failures are actionable and mention the relevant context or command.

validation:

- Run a shell syntax check for the helper file.
- Run a minimal command that sources the helper and prints `VAULT_CONTEXT`, `VSO_CONTEXT`, `VAULT_ADDR`, and `VSO_API_ADDR`.
- Temporarily set invalid context variables and confirm helper validation fails before making changes.

notes:

- This task prepares the implementation seam used by setup, demo, and verification scripts.
- Keep functions POSIX-ish Bash with `set -euo pipefail` compatibility.
