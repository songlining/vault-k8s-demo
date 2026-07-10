# 02. Configure kind VSO cluster issuer and JWKS endpoint if required

meta:
  id: vso-jwt-oidc-auth-02
  feature: vso-jwt-oidc-auth
  priority: P2
  depends_on: [vso-jwt-oidc-auth-01]
  tags: [implementation, tests-required]

objective:

- Ensure the VSO kind cluster exposes service account issuer/JWKS metadata through a URL Vault can validate against.

deliverables:

- Updated `scripts/kind/vso-lab-config.yaml.tmpl` if Phase 1 proves default kind issuer settings are unsuitable.
- Updated comments in `scripts/create-clusters.sh` or related kind configuration docs explaining issuer/JWKS host mapping.
- Evidence that newly minted VSO service account tokens use the intended issuer.

steps:

- Review Phase 1 findings for issuer reachability, OIDC discovery, JWKS URL, and TLS/SAN behavior.
- If default kind config is sufficient, document that no template change is required.
- If required, update `scripts/kind/vso-lab-config.yaml.tmpl` with service account issuer/JWKS API server args.
- Ensure the API server certificate/SAN and host port mapping match the URL Vault will use.
- Recreate or validate the VSO kind cluster and mint a new `vso-demo` token.
- Confirm the token's `iss` matches the intended externally reachable issuer.

tests:

- Unit: validation test for the kind config template to assert issuer/JWKS args are present when required.
- Integration/e2e: create/validate the VSO kind cluster, mint a token, and confirm `iss` plus JWKS reachability from Vault.

acceptance_criteria:

- The VSO cluster issuer URL is compatible with Vault JWT auth.
- The JWKS endpoint URL is reachable from the Vault cluster.
- TLS/SAN behavior is documented and either validates cleanly or has a deliberate demo-safe handling.
- Existing Podman/kind networking for Vault and VSO remains functional.

validation:

- Run the cluster creation/validation path after any template change.
- Mint a `vso-demo` service account token and verify the `iss` claim matches the planned value.
- Curl the chosen JWKS URL from the Vault cluster and confirm a valid JWKS document is returned.

notes:

- Skip file changes in this task if Phase 1 proves the existing kind configuration is already sufficient.
- Do not change Vault cluster API server issuer settings unless required for unrelated same-cluster demos.
