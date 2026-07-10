# 05. Expose Vault Through Stable Cross-Cluster Address

meta:
  id: vso-two-cluster-podman-05
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-04]
  tags: [implementation, tests-required]

objective:

- Expose Vault from the Vault cluster through a stable address reachable by pods in the VSO cluster.

deliverables:

- Vault service/Helm/kind configuration that exposes Vault through host port `8200` or the chosen stable port.
- Script logic or manifest changes ensuring `VAULT_ADDR` defaults to `http://host.containers.internal:8200` for VSO-cluster consumers.
- A reusable connectivity check from the VSO cluster to Vault.

steps:

- Decide whether Vault exposure is handled through kind `extraPortMappings`, a NodePort service, Helm service values, or a patch after install.
- Implement the stable exposure path in the Vault bootstrap/setup flow.
- Add a test pod or one-shot `kubectl run` pattern in the VSO cluster that curls `VAULT_ADDR`.
- Ensure the approach does not rely on `vault.default.svc.cluster.local` from outside the Vault cluster.

tests:

- Unit: Validate generated manifests or service patches contain the expected host/container ports.
- Integration/e2e: From a pod in `kind-vso-lab`, curl the Vault health endpoint through `http://host.containers.internal:8200`.

acceptance_criteria:

- Vault remains reachable inside the Vault cluster.
- Pods in the VSO cluster can reach `http://host.containers.internal:8200/v1/sys/health` or the documented equivalent.
- The chosen Vault address is centralized and used by later VSO CRDs.
- Failure output explains Podman Desktop networking assumptions.

validation:

- Run `kubectl --context kind-vso-lab run vault-connectivity-check --rm -i --restart=Never --image=curlimages/curl -- http://host.containers.internal:8200/v1/sys/health` or an equivalent command.
- Confirm the response is a Vault health response, accepting initialized/sealed status codes as appropriate for the stage.

notes:

- The migration plan recommends Vault NodePort plus kind `extraPortMappings` to host port `8200`.
