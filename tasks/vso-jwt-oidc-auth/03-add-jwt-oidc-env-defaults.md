# 03. Add shared JWT/OIDC environment defaults and helpers

meta:
  id: vso-jwt-oidc-auth-03
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-01]
  tags: [implementation, tests-required]

objective:

- Centralize JWT/OIDC auth names, issuer/JWKS URLs, and audience defaults for all setup, apply, verification, and demo scripts.

deliverables:

- Updated `scripts/lib/two-cluster-env.sh` with JWT/OIDC defaults.
- Helper output in environment summaries for `VSO_JWT_AUTH_MOUNT`, `VSO_JWT_AUTH_ROLE`, `VSO_JWT_AUDIENCE`, `VSO_OIDC_ISSUER`, and `VSO_OIDC_JWKS_URL`.
- Validation coverage for override behavior.

steps:

- Add defaults for `VSO_JWT_AUTH_MOUNT`, `VSO_JWT_AUTH_ROLE`, `VSO_JWT_AUDIENCE`, `VSO_OIDC_ISSUER`, and `VSO_OIDC_JWKS_URL`.
- Keep existing Kubernetes auth variables temporarily for migration compatibility.
- Ensure variables can be overridden from the environment or Make command line.
- Update any environment summary/help functions to include the new JWT/OIDC variables.
- Add or update validation tests for default values and overrides.

tests:

- Unit: source `scripts/lib/two-cluster-env.sh` in a test shell and assert default JWT/OIDC values.
- Unit: set environment overrides and assert the helper preserves them.
- Integration/e2e: downstream scripts that source the helper can print/use the new variables without unbound variable errors.

acceptance_criteria:

- JWT/OIDC variables have documented defaults in one shared location.
- Existing Kubernetes auth variables remain available during migration.
- Override behavior works for all new variables.
- Tests prove defaults and overrides are stable.

validation:

- Run the relevant `scripts/tests/test-*.sh` files for shared env behavior.
- Run `bash scripts/lib/two-cluster-env.sh` only if the helper supports direct execution; otherwise validate by sourcing from a test script.

notes:

- The default audience should be `vault`.
- The default mount should be `jwt-vso` to clearly distinguish it from `kubernetes-vso`.
