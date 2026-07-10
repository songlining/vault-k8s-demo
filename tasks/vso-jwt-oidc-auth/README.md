# VSO JWT OIDC Auth

Objective: Migrate the two-cluster VSO demo from Kubernetes TokenReview auth to Vault JWT/OIDC auth using strict issuer, audience, and subject claim binding.

Status legend: [ ] todo, [~] in-progress, [x] done

Tasks

- [x] 01 — spike-oidc-discovery-and-jwks → `01-spike-oidc-discovery-and-jwks.md`
- [x] 02 — configure-kind-oidc-issuer → `02-configure-kind-oidc-issuer.md`
- [x] 03 — add-jwt-oidc-env-defaults → `03-add-jwt-oidc-env-defaults.md`
- [x] 04 — implement-vso-jwt-auth-setup → `04-implement-vso-jwt-auth-setup.md`
- [x] 05 — refactor-vso-cluster-setup → `05-refactor-vso-cluster-setup.md`
- [x] 06 — switch-vso-vaultauth-to-jwt → `06-switch-vso-vaultauth-to-jwt.md`
- [x] 07 — update-make-targets-and-setup-flow → `07-update-make-targets-and-setup-flow.md`
- [x] 08 — update-two-cluster-verification → `08-update-two-cluster-verification.md`
- [x] 09 — update-validation-tests → `09-update-validation-tests.md`
- [~] 10 — update-demo-scripts-docs-and-deck → `10-update-demo-scripts-docs-and-deck.md`
- [ ] 11 — run-end-to-end-validation → `11-run-end-to-end-validation.md`

Dependencies

- 02 depends on 01
- 03 depends on 01
- 04 depends on 01, 02, 03
- 05 depends on 04
- 06 depends on 03, 04
- 07 depends on 04, 06
- 08 depends on 04, 06
- 09 depends on 05, 06, 08
- 10 depends on 07, 08
- 11 depends on 09, 10

Exit criteria

- The feature is complete when `make setup` configures the two-cluster VSO demo with Vault JWT/OIDC auth by default; Vault uses `auth/jwt-vso`; VSO `VaultAuth` uses `method: jwt`; no VSO `token_reviewer_jwt` is stored in the default path; `make verify-two-cluster` proves correct JWT login succeeds, wrong-audience login fails, wrong-service-account login fails, VSO sync works, and rotation restores the baseline secret; all validation tests pass; and `make vso-deck` passes live Ctrl-E validation with clean layout.
