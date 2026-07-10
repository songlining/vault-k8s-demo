# 07. Configure Vault Kubernetes Auth Against VSO Cluster

meta:
  id: vso-two-cluster-podman-07
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-04, vso-two-cluster-podman-06]
  tags: [implementation, tests-required]

objective:

- Configure a dedicated Vault Kubernetes auth mount that validates service account JWTs against the VSO cluster API server.

deliverables:

- `scripts/configure-vso-kubernetes-auth.sh` or equivalent script.
- Vault auth mount `auth/kubernetes-vso`.
- Vault Kubernetes auth config using the VSO cluster API address, CA, and reviewer JWT.
- Vault role `vso-demo` bound to `vso-demo/vso-demo` and policy `mysecret`.
- Reviewer token refresh behavior documented or implemented.

steps:

- Source shared context/preflight helpers.
- Read the VSO cluster CA and API server address from `VSO_CONTEXT` or configured `VSO_API_ADDR`.
- Generate or refresh the reviewer JWT from the VSO cluster service account.
- Configure Vault in the Vault cluster through `kubectl --context "$VAULT_CONTEXT" exec vault-0`.
- Enable `auth/kubernetes-vso` idempotently without modifying unrelated `auth/kubernetes` behavior.
- Write or update the `vso-demo` role against the `kubernetes-vso` mount.
- Add clear handling for expiring reviewer tokens or document demo-only limitations.

tests:

- Unit: Shell syntax check and idempotence review for auth enable/config commands.
- Integration/e2e: Verify Vault can authenticate a VSO service account JWT through `auth/kubernetes-vso/login`.

acceptance_criteria:

- `vault auth list` in the Vault cluster shows `kubernetes-vso/`.
- `vault read auth/kubernetes-vso/config` reflects the VSO API server address and CA configuration.
- `vault read auth/kubernetes-vso/role/vso-demo` binds only `vso-demo/vso-demo`.
- A JWT from `kind-vso-lab` can log in to Vault through `auth/kubernetes-vso` and receives the expected policy.

validation:

- Run `scripts/configure-vso-kubernetes-auth.sh`.
- Run `kubectl --context kind-vault-lab exec vault-0 -n default -- vault auth list` and confirm `kubernetes-vso/`.
- Create a VSO service account token and run a Vault login against `auth/kubernetes-vso/login`; confirm success and `mysecret` policy.

notes:

- This is the highest-risk task because TokenReview requires Vault to reach the VSO API server and trust its CA/cert SAN.
