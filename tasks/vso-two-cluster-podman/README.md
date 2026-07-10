# VSO Two Cluster Podman

Objective: Migrate the VSO demo from one kind cluster to two Podman-backed kind clusters with explicit cross-cluster Vault/VSO networking and verification.

Status legend: [ ] todo, [~] in-progress, [x] done

Tasks

- [x] 01 — audit-single-cluster-assumptions → `01-audit-single-cluster-assumptions.md`
- [x] 02 — add-two-cluster-kind-bootstrap → `02-add-two-cluster-kind-bootstrap.md`
- [x] 03 — add-shared-context-and-preflight-helpers → `03-add-shared-context-and-preflight-helpers.md`
- [x] 04 — refactor-vault-cluster-setup → `04-refactor-vault-cluster-setup.md`
- [x] 05 — expose-vault-cross-cluster → `05-expose-vault-cross-cluster.md`
- [x] 06 — refactor-vso-cluster-setup → `06-refactor-vso-cluster-setup.md`
- [x] 07 — configure-vso-kubernetes-auth → `07-configure-vso-kubernetes-auth.md`
- [x] 08 — apply-vso-crds-and-consuming-app → `08-apply-vso-crds-and-consuming-app.md`
- [ ] 09 — update-make-targets → `09-update-make-targets.md`
- [ ] 10 — update-demo-scripts → `10-update-demo-scripts.md`
- [ ] 11 — add-two-cluster-verification → `11-add-two-cluster-verification.md`
- [ ] 12 — update-documentation-and-slides → `12-update-documentation-and-slides.md`

Dependencies

- 02 depends on 01
- 03 depends on 01
- 04 depends on 02, 03
- 05 depends on 04
- 06 depends on 02, 03
- 07 depends on 04, 06
- 08 depends on 05, 07
- 09 depends on 08
- 10 depends on 08
- 11 depends on 09, 10
- 12 depends on 11

Exit criteria

- The feature is complete when `make setup` creates and configures `kind-vault-lab` and `kind-vso-lab` using Podman-backed kind.
- The feature is complete when Vault runs only in `kind-vault-lab`; VSO, VSO CRDs, and `vso-demo-app` run only in `kind-vso-lab`.
- The feature is complete when VSO reaches Vault through the documented external address and syncs `kv-v2/vault-demo/mysecret` into `vso-demo/vso-demo-mysecret`.
- The feature is complete when Vault Kubernetes auth uses dedicated `auth/kubernetes-vso` configured against the VSO cluster API server.
- The feature is complete when `make vso-demo` runs end-to-end with explicit cluster contexts.
- The feature is complete when Secret rotation performed through the Vault cluster appears in the VSO cluster native Secret within the configured refresh window.
- The feature is complete when `make verify-two-cluster` or equivalent proves both clusters, networking paths, auth, VSO reconciliation, synced Secret value, and rotation behavior.
