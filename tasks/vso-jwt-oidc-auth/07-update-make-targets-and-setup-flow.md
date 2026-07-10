# 07. Update Make targets and setup flow for JWT/OIDC auth

meta:
  id: vso-jwt-oidc-auth-07
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-04, vso-jwt-oidc-auth-06]
  tags: [implementation, tests-required]

objective:

- Make JWT/OIDC auth the default setup path while preserving a clear compatibility alias for existing workflows.

deliverables:

- Updated `Makefile` targets.
- New `configure-vso-jwt-auth` target.
- Updated `configure-vso-auth` target as an alias or description pointing to JWT/OIDC default.
- Updated `setup` target sequence to call the JWT/OIDC setup script.

steps:

- Add `configure-vso-jwt-auth` to `.PHONY`.
- Implement `configure-vso-jwt-auth` to run `scripts/configure-vso-jwt-auth.sh`.
- Update `configure-vso-auth` to call or depend on `configure-vso-jwt-auth`.
- Update target descriptions in `make help` comments to mention JWT/OIDC.
- Update `setup` to call `scripts/configure-vso-jwt-auth.sh` before `apply-vso-demo.sh`.
- Ensure legacy Kubernetes auth setup is not invoked in the default setup sequence.

tests:

- Unit: Makefile help output includes `configure-vso-jwt-auth` and a JWT/OIDC description.
- Unit: static validation asserts `setup` invokes `configure-vso-jwt-auth.sh`.
- Integration/e2e: run `make configure-vso-jwt-auth` against live clusters.

acceptance_criteria:

- `make help` shows a JWT/OIDC auth setup target.
- `make setup` uses JWT/OIDC auth by default.
- `make configure-vso-auth` remains usable as a compatibility entry point.
- No default Make path calls `scripts/configure-vso-kubernetes-auth.sh` for VSO.

validation:

- Run `make help` and inspect target descriptions.
- Run the Makefile-related validation tests.
- Run `make configure-vso-jwt-auth` in a live environment and confirm Vault `auth/jwt-vso` exists.

notes:

- Keep target naming clear for customer demos: JWT/OIDC should be visible, not hidden behind generic auth wording only.
