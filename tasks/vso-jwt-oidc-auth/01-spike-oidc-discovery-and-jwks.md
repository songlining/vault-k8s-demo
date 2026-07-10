# 01. Spike VSO cluster issuer, OIDC discovery, and JWKS reachability

meta:
  id: vso-jwt-oidc-auth-01
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: []
  tags: [implementation, tests-required]

objective:

- Determine the exact VSO cluster service account issuer/JWKS configuration Vault can use for JWT/OIDC auth without TokenReview.

deliverables:

- A short investigation note added to `docs/vso-jwt-oidc-auth-plan.md` or a new linked note under `docs/` documenting the chosen issuer/JWKS strategy.
- Evidence of the actual `iss`, `aud`, and `sub` claims from a `vso-demo` service account JWT.
- Evidence that the chosen issuer/JWKS endpoint is reachable from the Vault cluster.

steps:

- Mint a `vso-demo` service account token in `kind-vso-lab` with audience `vault`.
- Decode the JWT payload and record `iss`, `sub`, `aud`, `exp`, namespace, and service account claims.
- Check the VSO API server discovery endpoints: `/.well-known/openid-configuration` and `/openid/v1/jwks`.
- From a pod or exec context in `kind-vault-lab`, prove the chosen issuer/JWKS URL is reachable.
- Decide whether the demo should use Vault JWT auth `oidc_discovery_url` or `jwks_url`.
- Document the decision and any kind-specific caveats.

tests:

- Unit: no code unit tests expected; validate parsing commands used to decode JWT claims produce deterministic fields.
- Integration/e2e: mint a live service account JWT and prove the chosen issuer/JWKS URL is reachable from the Vault cluster.

acceptance_criteria:

- The actual VSO JWT `iss` claim is documented.
- The expected `sub` claim is documented as `system:serviceaccount:vso-demo:vso-demo`.
- The `aud` claim for a Vault-targeted token is documented as including `vault`.
- The chosen issuer/JWKS endpoint is proven reachable from the Vault cluster.
- The plan explicitly states whether to use `oidc_discovery_url` or `jwks_url`.

validation:

- Run the documented JWT mint/decode command and confirm `iss`, `sub`, and `aud` match the recorded evidence.
- Run the documented reachability check from the Vault cluster and confirm HTTP success for the chosen discovery/JWKS endpoint.

notes:

- Primary risk is kind/Kubernetes service account issuer discovery and reachability, not Vault JWT support.
- Relevant plan: `docs/vso-jwt-oidc-auth-plan.md` Phase 1.
