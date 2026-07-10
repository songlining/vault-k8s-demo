# 11. Run full end-to-end JWT/OIDC validation and capture evidence

meta:
  id: vso-jwt-oidc-auth-11
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-09, vso-jwt-oidc-auth-10]
  tags: [implementation, tests-required]

objective:

- Prove the completed JWT/OIDC migration works end-to-end across setup, verification, secret sync, rotation, docs, and live deck execution.

deliverables:

- Validation evidence summary in task notes, `.ralpi` reflection, or a new `docs/` validation note.
- Passing fast validation test output.
- Passing `make setup` or documented incremental setup output.
- Passing `make verify-two-cluster` output.
- Live `make vso-deck` Ctrl-E validation evidence with clean layout.

steps:

- Run all fast validation tests.
- Build or refresh the two-cluster environment using the updated setup flow.
- Run JWT/OIDC auth setup and apply VSO resources.
- Run `make verify-two-cluster` and confirm positive/negative JWT auth checks pass.
- Confirm `VaultStaticSecret` syncs and app consumes the native Secret.
- Confirm rotation propagates and baseline value is restored to `larry`.
- Run presenterm visual validation.
- Run live `make vso-deck` with actual Ctrl-E execution on every executable slide.
- Capture and summarize evidence, including any known caveats.

tests:

- Unit: all `scripts/tests/test-*.sh` pass.
- Integration/e2e: `make setup` or equivalent full setup path completes successfully.
- Integration/e2e: `make verify-two-cluster` passes all sections.
- Visual/e2e: live presenterm Ctrl-E walkthrough reaches `[finished]` for every executable slide, with readable output and clean diagrams.

acceptance_criteria:

- Fast validation test suite passes with zero failures.
- `make verify-two-cluster` proves JWT login succeeds only for correct claims.
- Wrong audience and wrong service account JWTs fail authentication.
- VSO sync and rotation pass end-to-end.
- Final native Kubernetes Secret username is restored to `larry`.
- Deck live Ctrl-E validation has no `[finished error]`, no broken diagrams, and no crowded/clipped output.

validation:

- Run `for f in scripts/tests/test-*.sh; do bash "$f"; done`.
- Run `make setup` or the documented equivalent setup sequence.
- Run `make verify-two-cluster`.
- Run `make vso-deck` in presenterm and perform live Ctrl-E validation.

notes:

- This is the completion audit task. Do not mark the feature complete until all explicit exit criteria in `tasks/vso-jwt-oidc-auth/README.md` have evidence.
- If kind issuer/JWKS limitations require `jwks_url` rather than full discovery, record that as an intentional demo design decision.
