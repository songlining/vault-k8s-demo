# 08. Update end-to-end verification for JWT positive and negative auth cases

meta:
  id: vso-jwt-oidc-auth-08
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-04, vso-jwt-oidc-auth-06]
  tags: [implementation, tests-required]

objective:

- Update `verify-two-cluster` to prove JWT/OIDC auth succeeds only for the intended issuer, audience, and service account subject.

deliverables:

- Updated `scripts/verify-two-cluster.sh` auth verification section.
- Positive JWT login test using `vso-demo` service account and audience `vault`.
- Negative JWT login test for wrong audience.
- Negative JWT login test for wrong service account/subject.
- Updated final verification summary referencing `auth/jwt-vso`.

steps:

- Replace the current `auth/kubernetes-vso/login` verification with `auth/${VSO_JWT_AUTH_MOUNT}/login`.
- Mint a `vso-demo` token from the VSO cluster with `--audience ${VSO_JWT_AUDIENCE}`.
- Login to Vault JWT auth and assert a client token is returned.
- Mint a `vso-demo` token with a wrong audience and assert Vault login fails.
- Mint a token for a different service account and assert Vault login fails.
- Verify the role/config output includes strict claim binding.
- Keep existing placement, network, sync, and rotation checks intact.

tests:

- Unit: script passes `bash -n`.
- Unit: static tests assert `auth/${VSO_JWT_AUTH_MOUNT}/login` is used.
- Unit: static tests assert wrong-audience and wrong-service-account negative paths exist.
- Integration/e2e: run `make verify-two-cluster` and confirm all auth, sync, and rotation sections pass.

acceptance_criteria:

- Correct `vso-demo` JWT with audience `vault` authenticates successfully.
- Wrong audience JWT is rejected by Vault.
- Wrong service account JWT is rejected by Vault.
- Verification summary names `auth/jwt-vso` and JWT/OIDC claim validation.
- Secret sync and rotation checks still pass after auth verification changes.

validation:

- Run `scripts/tests/test-verify-two-cluster-validation.sh` after updates.
- Run `make verify-two-cluster` against a live JWT/OIDC-configured environment.
- Confirm final native Secret value is restored to baseline `larry` after rotation.

notes:

- Negative tests are mandatory because JWT/OIDC security depends on strict claim binding.
- Do not print full JWT values in logs or failure messages.
