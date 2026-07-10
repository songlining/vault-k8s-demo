# 04. Implement Vault JWT/OIDC auth setup script

meta:
  id: vso-jwt-oidc-auth-04
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-01, vso-jwt-oidc-auth-02, vso-jwt-oidc-auth-03]
  tags: [implementation, tests-required]

objective:

- Add an idempotent script that configures Vault `auth/jwt-vso` for VSO service account JWT authentication with strict claim binding.

deliverables:

- New `scripts/configure-vso-jwt-auth.sh`.
- Validation test file for script preflight and static safety checks.
- Script output that clearly shows issuer/JWKS config, audience, subject, and policy binding.

steps:

- Create `scripts/configure-vso-jwt-auth.sh` using strict shell options.
- Source `scripts/lib/two-cluster-env.sh` and require needed commands.
- Validate both Kubernetes contexts exist and differ.
- Locate and verify the Vault pod is running and unsealed.
- Resolve the VSO cluster CA and chosen issuer/JWKS URL from Phase 1.
- Enable `auth/${VSO_JWT_AUTH_MOUNT}` as Vault JWT auth idempotently.
- Write JWT auth config using either `oidc_discovery_url` or `jwks_url`, based on Phase 1.
- Write role `${VSO_JWT_AUTH_ROLE}` with `role_type=jwt`, `user_claim=sub`, `bound_audiences=${VSO_JWT_AUDIENCE}`, `bound_subject=system:serviceaccount:${VSO_NAMESPACE}:vso-demo`, and policy `mysecret`.
- Print a verification summary without secrets.

tests:

- Unit: script passes `bash -n`.
- Unit: `--check-only` validates required commands and contexts without cluster mutation.
- Unit: static tests assert no `token_reviewer_jwt` is written by the JWT setup script.
- Unit: static tests assert role includes `bound_audiences` and `bound_subject`.
- Integration/e2e: run the script against live clusters and verify `vault auth list`, `auth/jwt-vso/config`, and role output.

acceptance_criteria:

- `scripts/configure-vso-jwt-auth.sh --check-only` succeeds in a valid environment.
- Running the script twice is safe and idempotent.
- Vault has an enabled `auth/jwt-vso` mount.
- Vault JWT role binds the exact `vso-demo/vso-demo` subject and `vault` audience.
- The script never writes `token_reviewer_jwt`.

validation:

- Run `bash -n scripts/configure-vso-jwt-auth.sh`.
- Run the new validation test under `scripts/tests/`.
- Run `scripts/configure-vso-jwt-auth.sh` against live clusters and read back the config/role.

notes:

- Do not modify the same-cluster Agent Injector `auth/kubernetes` mount.
- Avoid printing JWTs, CA material, or other sensitive values in script output.
