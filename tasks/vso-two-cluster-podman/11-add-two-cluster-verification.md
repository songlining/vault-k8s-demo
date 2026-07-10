# 11. Add End-to-End Two-Cluster Verification

meta:
  id: vso-two-cluster-podman-11
  feature: vso-two-cluster-podman
  priority: P2
  depends_on: [vso-two-cluster-podman-09, vso-two-cluster-podman-10]
  tags: [implementation, tests-required]

objective:

- Add an automated verification target that proves the two-cluster VSO demo works end-to-end.

deliverables:

- `scripts/verify-two-cluster.sh` or equivalent verification script.
- `make verify-two-cluster` target, or an extended `make vso-verify` with explicit two-cluster semantics.
- Verification for contexts, cluster separation, network reachability, Kubernetes auth, VSO readiness, secret sync, and rotation.

steps:

- Verify `VAULT_CONTEXT` and `VSO_CONTEXT` exist and point to different clusters.
- Verify Vault is installed and ready in the Vault cluster only.
- Verify VSO operator, CRDs, app namespace, and app pod are installed in the VSO cluster only.
- Verify Vault is reachable from a pod in the VSO cluster through the documented external address.
- Verify Vault can authenticate a VSO service account JWT through `auth/kubernetes-vso`.
- Verify `VaultStaticSecret` reconciliation status and native Secret value.
- Perform a rotation write in Vault and poll the VSO cluster Secret until it updates, then reset the baseline value.

tests:

- Unit: Shell syntax check and failure-path review for each verification section.
- Integration/e2e: Run the verification target against a freshly set up two-cluster environment.

acceptance_criteria:

- Verification fails fast with actionable messages for missing contexts, unreachable network paths, failed auth, or failed sync.
- Verification proves both positive placement and negative placement where practical.
- Verification confirms rotation from Vault cluster to VSO cluster within the refresh window.
- The final output is concise enough for pre-demo checks.

validation:

- Run `make verify-two-cluster`.
- Temporarily break one expected variable or resource in a disposable environment and confirm the script reports the correct failing section.
- Confirm the script resets the secret back to the baseline value after rotation.

notes:

- This target is the primary completion gate for the implementation tasks.
