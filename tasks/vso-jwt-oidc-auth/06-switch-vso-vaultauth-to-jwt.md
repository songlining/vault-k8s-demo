# 06. Switch VSO VaultAuth custom resource to JWT auth

meta:
  id: vso-jwt-oidc-auth-06
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-03, vso-jwt-oidc-auth-04]
  tags: [implementation, tests-required]

objective:

- Change the VSO `VaultAuth` resource from Kubernetes auth to JWT auth while preserving VaultConnection and VaultStaticSecret behavior.

deliverables:

- Updated `scripts/apply-vso-demo.sh` `VaultAuth` manifest.
- `VaultAuth.spec.method: jwt` using `mount: ${VSO_JWT_AUTH_MOUNT}`.
- JWT auth fields for role, service account, audience, and token expiration.
- Static validation tests for the manifest content.

steps:

- Update `scripts/apply-vso-demo.sh` to use JWT/OIDC environment variables.
- Replace `spec.method: kubernetes` with `spec.method: jwt`.
- Replace the `kubernetes:` auth stanza with `jwt:` fields.
- Set `jwt.role` to `${VSO_JWT_AUTH_ROLE}`.
- Set `jwt.serviceAccount` to `vso-demo`.
- Set `jwt.audiences` to `${VSO_JWT_AUDIENCE}`.
- Set `jwt.tokenExpirationSeconds` to a short bounded value such as `600`.
- Keep `VaultConnection` address pointed to `${VAULT_ADDR}`.
- Keep `VaultStaticSecret.vaultAuthRef` pointed at `vso-demo-auth`.

tests:

- Unit: script passes `bash -n`.
- Unit: static tests assert `method: jwt`, `mount: ${VSO_JWT_AUTH_MOUNT}`, `jwt.role`, `jwt.serviceAccount`, and `jwt.audiences` are present.
- Unit: static tests assert the old `kubernetes:` stanza is absent from the default VSO VaultAuth manifest.
- Integration/e2e: apply CRDs and confirm `VaultAuth` becomes Ready and `VaultStaticSecret` syncs.

acceptance_criteria:

- Applied `VaultAuth/vso-demo-auth` shows `method: jwt`.
- Applied `VaultAuth/vso-demo-auth` uses `mount: jwt-vso` by default.
- VSO can authenticate and sync `vso-demo-mysecret`.
- No same-cluster or TokenReview auth settings are required for VSO sync.

validation:

- Run `scripts/tests/test-apply-vso-demo-validation.sh` after updates.
- Run `make vso-apply` and inspect `kubectl --context kind-vso-lab get vaultauth vso-demo-auth -n vso-demo -o yaml`.
- Verify `kubectl --context kind-vso-lab get vaultstaticsecret vso-demo-mysecret -n vso-demo` reports Ready.

notes:

- The installed CRD supports `spec.jwt` fields; keep field names aligned with `kubectl explain vaultauth.spec --recursive`.
