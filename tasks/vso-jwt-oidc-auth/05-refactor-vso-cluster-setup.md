# 05. Remove or gate TokenReview reviewer resources from VSO setup

meta:
  id: vso-jwt-oidc-auth-05
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-04]
  tags: [implementation, tests-required]

objective:

- Remove the default dependency on `vault-token-reviewer` and `system:auth-delegator` from the VSO cluster setup path.

deliverables:

- Updated `scripts/setup-vso-cluster.sh` with reviewer SA/RBAC removed or gated behind an explicit compatibility flag.
- Updated comments and output describing JWT/OIDC as the default VSO auth path.
- Tests proving TokenReview reviewer resources are not created by default.

steps:

- Identify all `vault-token-reviewer`, `system:auth-delegator`, and TokenReview-specific setup logic.
- Decide whether to remove these resources entirely or keep them behind `ENABLE_TOKEN_REVIEWER_AUTH=1`.
- Update script comments and completion output to describe JWT/OIDC defaults.
- Ensure the VSO namespace and `vso-demo` service account are still created.
- Update static validation tests for the new default behavior.

tests:

- Unit: `scripts/setup-vso-cluster.sh` passes `bash -n`.
- Unit: validation tests assert default setup does not create `vault-token-reviewer` or bind `system:auth-delegator` unless compatibility flag is set.
- Integration/e2e: run VSO setup and confirm VSO operator plus `vso-demo` service account exist.

acceptance_criteria:

- Default setup no longer requires TokenReview reviewer credentials.
- `vso-demo` namespace and service account still exist after setup.
- VSO operator deployment remains Available.
- Any retained TokenReview compatibility path is explicit and disabled by default.

validation:

- Run the setup-vso validation test.
- Run `make setup-vso` against live clusters and verify expected resources.
- Confirm `kubectl --context kind-vso-lab get sa -n vso-demo` includes `vso-demo` and does not require `vault-token-reviewer` by default.

notes:

- Removing reviewer RBAC is part of proving JWT/OIDC auth avoids a stored reviewer JWT.
- If compatibility is retained, docs must clearly mark it as legacy/demo comparison only.
