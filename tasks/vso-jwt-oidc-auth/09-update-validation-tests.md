# 09. Update validation tests for JWT/OIDC behavior and removed TokenReview assumptions

meta:
  id: vso-jwt-oidc-auth-09
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-05, vso-jwt-oidc-auth-06, vso-jwt-oidc-auth-08]
  tags: [implementation, tests-required]

objective:

- Align all fast validation tests with the new JWT/OIDC default path and remove stale TokenReview assumptions.

deliverables:

- New `scripts/tests/test-configure-vso-jwt-auth-validation.sh`.
- Updated `test-apply-vso-demo-validation.sh`.
- Updated `test-setup-vso-cluster-validation.sh`.
- Updated `test-verify-two-cluster-validation.sh`.
- Updated `test-vso-demo-validation.sh` and any deck validation tests that assert auth text.

steps:

- Add tests for the new JWT auth setup script's syntax, preflight behavior, idempotent intent, and static safety.
- Assert `token_reviewer_jwt` is absent from the JWT/OIDC default setup path.
- Assert `VaultAuth` uses `method: jwt`, `mount: ${VSO_JWT_AUTH_MOUNT}`, `jwt.role`, `jwt.serviceAccount`, and `jwt.audiences`.
- Assert VSO setup no longer requires `system:auth-delegator` by default.
- Assert verification includes positive login plus wrong-audience and wrong-service-account negative tests.
- Update presenterm/demo script validation to mention JWT/OIDC issuer/JWKS and claim binding.
- Run the full fast validation suite and fix failures.

tests:

- Unit: all `scripts/tests/test-*.sh` pass without live cluster mutation unless explicitly documented.
- Unit: new JWT setup validation test covers missing tools, missing contexts, same-context rejection, unknown flags, and `--check-only`.
- Integration/e2e: after fast tests pass, run live verification in task 11.

acceptance_criteria:

- Validation tests no longer expect `auth/kubernetes-vso` as the default VSO path.
- Validation tests assert no default reviewer JWT dependency remains.
- Tests fail if JWT role binding omits `bound_audiences` or `bound_subject`.
- Tests fail if VSO `VaultAuth` regresses to Kubernetes auth.
- All fast validation tests pass.

validation:

- Run `for f in scripts/tests/test-*.sh; do bash "$f"; done`.
- Confirm zero failures and review output for stale TokenReview wording.

notes:

- Keep any same-cluster Agent Injector tests separate; do not remove legitimate `auth/kubernetes` coverage for that demo path.
