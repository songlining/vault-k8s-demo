# 10. Update demo scripts, documentation, and presenterm deck for JWT/OIDC story

meta:
  id: vso-jwt-oidc-auth-10
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-07, vso-jwt-oidc-auth-08]
  tags: [implementation, tests-required]
  timeout: 15m

objective:

- Rewrite customer-facing demo material to explain JWT/OIDC issuer/JWKS validation and strict claim binding instead of TokenReview reviewer JWT delegation.

deliverables:

- Updated `README.md` VSO sections.
- Updated `PODMAN_MIGRATION.md` if it references VSO auth setup.
- Updated `docs/vso-demo-design.md`, `docs/vso-two-cluster-podman-plan.md`, and audit/migration notes as appropriate.
- Updated `vso-demo.sh` live demo narration.
- Updated `presenterm/vso.md` deck with JWT/OIDC auth setup and verification slides.

steps:

- Replace default VSO auth narrative from TokenReview reviewer JWT to JWT/OIDC issuer/JWKS validation.
- Explain claim binding in customer-friendly terms: issuer, audience, subject.
- Update commands to read `auth/jwt-vso/config` and `auth/jwt-vso/role/vso-demo`.
- Update diagrams to avoid broken ASCII/Unicode box rendering and keep layout clean.
- Update live demo script sections to show JWT positive and negative auth proof.
- Update presenterm deck and ensure all `+exec` blocks use robust working-directory patterns.
- Validate docs do not present reviewer JWT as the production/default path.

tests:

- Unit: documentation grep checks for stale default `auth/kubernetes-vso`, `TokenReview`, `vault-token-reviewer`, and `system:auth-delegator` wording, allowing only historical/legacy comparison sections.
- Unit: `vso-demo.sh` and `presenterm/vso.md` pass syntax/static validation tests.
- Integration/e2e: run `make vso-demo` in a live environment enough to verify commands and narrative alignment.
- Visual/e2e: run `make vso-deck` in presenterm with live Ctrl-E validation in task 11.

acceptance_criteria:

- Customer-facing docs state JWT/OIDC is the default VSO auth method.
- Docs explain no reviewer JWT is stored in Vault for the default path.
- Docs explain why issuer, audience, and subject binding matter.
- Presenterm deck has no torn box-drawing diagrams or crowded live output slides.
- Demo scripts reference `auth/jwt-vso` and JWT/OIDC verification.

validation:

- Run relevant docs/demo validation tests.
- Review README and deck manually for stale TokenReview-as-default language.
- Live presenterm visual validation (Ctrl-E, screenshots) is deferred to task 11.
  Do not attempt live presenterm rendering from this task.

notes:

- It is acceptable to mention TokenReview only as a previous/demo comparison path, not as the default production-oriented approach.
- **Never invoke `presenterm` directly, via `script -q ... presenterm ...`, or with
  `--export-html` / `-x -E` from a non-interactive shell.** presenterm requires a
  real PTY; without one it hangs indefinitely (it does not fail fast) instead of
  erroring, which will stall the whole task/agent loop for hours. This task's
  static tests (`scripts/tests/test-vso-deck-validation.sh`) intentionally never
  launch presenterm for this reason. If any live rendering check is genuinely
  needed here, use the tmux-backed validator described in
  `~/work/hashicorp/local_skills/presenterm-demo-decks/SKILL.md`
  (`scripts/validate-deck-visual.sh`), never a bare `script`/`export-html`/`-x -E` invocation.
