# VSO JWT/OIDC Auth: End-to-End Validation Evidence

> **Historical validation — direct-JWKS implementation:** This evidence records
> the previous `jwks_url` design and its then-current `default` + `mysecret`
> token policy result. The current migration changes the VSO API server issuer
> and advertised JWKS metadata, uses `oidc_discovery_url`, restricts signing to
> RS256, and uses a non-renewable batch token with only `mysecret`. See
> [`vso-oidc-discovery-handoff.md`](./vso-oidc-discovery-handoff.md). Do not read
> the historical results below as validation of the new discovery design.

**Current discovery migration status:** passed on 2026-07-17 after the
explicitly approved recreation of only `kind-vso-lab`. The current verifier
confirmed TLS-verified discovery metadata, external JWT issuer claims,
RS256-only Vault configuration with no direct `jwks_url`, strict positive and
negative login behavior, a non-renewable `mysecret`-only batch token, VSO
sync/rotation, and unaffected sidecar/OTel paths. Detailed current evidence is
recorded in [`vso-oidc-discovery-handoff.md`](./vso-oidc-discovery-handoff.md).

Status: **PASSED (historical direct-JWKS design only)**. This is the completion audit for the `vso-jwt-oidc-auth`
feature (task 11). It records the evidence for every exit criterion in
`tasks/vso-jwt-oidc-auth/README.md`, run against the live two-cluster
Podman-backed kind lab (`kind-vault-lab` / `kind-vso-lab`).

## Environment

The two-cluster lab was already running (created by earlier tasks in this
feature) and was reused as-is per the task's "build or refresh" allowance:

- `kind-vault-lab` (Vault cluster): `vault-0` running/unsealed.
- `kind-vso-lab` (VSO cluster): VSO controller Available, CRDs installed,
  `vso-demo` namespace/app running.
- Both contexts present in `kubectl config get-contexts`; `kind get clusters`
  itself fails on this host due to an unrelated `kind`+Podman provider
  template bug (`cannot index slice/array with type string`), but this does
  not affect cluster reachability -- `kubectl --context <ctx> get nodes`
  works for both contexts, and Podman (`podman ps -a`) shows both control
  planes `Up`.

## 1. Fast validation test suite

`for f in scripts/tests/test-*.sh; do bash "$f"; done` -- all 15 suites,
269 total assertions, **0 failures**:

| Suite | Assertions |
|---|---|
| test-apply-vso-demo-validation.sh | 25 |
| test-check-vault-connectivity-validation.sh | 7 |
| test-configure-vso-jwt-auth-validation.sh | 21 |
| test-configure-vso-kubernetes-auth-validation.sh | 10 |
| test-create-clusters-validation.sh | 5 |
| test-demo-validation.sh | 5 |
| test-makefile-vso-jwt-auth-validation.sh | 14 |
| test-setup-vso-cluster-validation.sh | 12 |
| test-two-cluster-env-validation.sh | 19 |
| test-vault-cross-cluster-exposure-validation.sh | 11 |
| test-verify-two-cluster-validation.sh | 35 |
| test-vso-deck-validation.sh | 22 |
| test-vso-demo-validation.sh | 20 |
| test-vso-docs-validation.sh | 44 |
| test-vso-lab-kind-config-validation.sh | 7 |

## 2. `make verify-two-cluster` (full 7/7)

Ran multiple times across this task (including after a script fix, see
below) -- all green every time:

1. `[1/7 contexts]` -- both contexts exist and differ.
2. `[2/7 vault placement + readiness]` -- Vault only in the Vault cluster.
3. `[3/7 vso placement + readiness]` -- VSO/CRDs/app only in the VSO cluster.
4. `[4/7 network reachability]` -- VSO cluster reaches Vault at
   `http://host.containers.internal:8200`.
5. `[5/7 jwt/oidc auth (auth/jwt-vso)]` -- role strictly binds
   `bound_audiences=vault` / `bound_subject=system:serviceaccount:vso-demo:vso-demo`;
   correct JWT logs in; wrong-audience (`not-vault`) JWT rejected;
   wrong-service-account (`default`) JWT rejected.
6. `[6/7 vso reconciliation + secret sync]` -- `VaultStaticSecret` Ready,
   native Secret matches Vault (`larry`).
7. `[7/7 rotation]` -- rotated value observed in the native Secret within a
   few poll attempts; baseline `larry` restored and reconfirmed.

No `token_reviewer_jwt` exists anywhere in the default path: confirmed via
`kubectl --context kind-vso-lab get vaultconnection,vaultauth -n vso-demo -o yaml`
(no such field in the `VaultAuth` spec, which uses `method: jwt`) and via
`grep -rn token_reviewer_jwt scripts/configure-vso-jwt-auth.sh` (only appears
in comments explaining that it is deliberately never written).

## 3. Bug found and fixed during this task: idempotent auth-enable race

Live Ctrl-E execution of the deck's "Set up cross-cluster JWT/OIDC auth"
slide (re-running `scripts/configure-vso-jwt-auth.sh` against an
already-configured mount) surfaced a real `[finished with error]`:

```
Error enabling jwt auth: Error making API request.
URL: POST http://127.0.0.1:8200/v1/sys/auth/jwt-vso
Code: 400. Errors:
* path is already in use at jwt-vso/
command terminated with exit code 2
```

The script already had a `vault auth list | grep -q "^${VSO_JWT_AUTH_MOUNT}/"`
guard before calling `vault auth enable`, and re-running the script
immediately afterward (outside presenterm) succeeded and correctly printed
"already enabled. Skipping enable" -- so this was a one-off TOCTOU-style race
between the check and the enable call, not a broken guard. Fixed by making
the enable call itself tolerate "path is already in use" as success (in
`scripts/configure-vso-jwt-auth.sh`): capture `vault auth enable`'s output,
and if it fails specifically because the mount is already enabled, log and
continue instead of exiting non-zero. Verified:

- `bash -n` passes.
- `scripts/tests/test-configure-vso-jwt-auth-validation.sh` still 21/21
  (the existing idempotency-guard assertion pattern is unchanged).
- Ran the script twice in a row manually -- both idempotent, no errors.
- Re-ran `make verify-two-cluster` (7/7) and the full live Ctrl-E deck pass
  afterward -- clean.

## 4. Layout bug found and fixed: slide crowding/clipping during live Ctrl-E

The first full live Ctrl-E pass (see below) also surfaced two **layout**
defects only visible once real command output was rendered inline (not
caught by the deck's static structural tests, nor by extracting/running
`+exec` blocks outside presenterm):

1. `vault kv put ...` in the rotation/reset slides printed Vault CLI's
   default verbose secret-metadata table (~15 lines: `Secret Path`,
   `Metadata`, a 7-row key/value table) on every write. Combined with 2-3
   `+exec` blocks per slide, this pushed later blocks and the slide footer
   off the bottom of the pane.
2. The "7b -- Rotate the value in Vault" slide had three `+exec` blocks
   (read current value, write the rotated value, poll until it flips).
   presenterm's Ctrl+E chains and runs every not-yet-started block on a
   slide in one keypress, so with the verbose `kv put` output the third
   block (the actual "watch it flip" proof) was pushed off-screen and never
   became visible.

Fixes in `presenterm/vso.md`:

- All three `vault kv put ...` invocations (seed/rotate/reset) now redirect
  stdout to `/dev/null` and print one compact confirmation line instead
  (e.g. `-> wrote username=larry-rotated-1 to kv-v2/vault-demo/mysecret`).
- Split "7b -- Rotate the value in Vault" into two slides: the read+write
  step, and a new "7b -- Rotate the value in Vault (cont.)" slide with just
  the poll loop. Deck now has 16 `+exec`-relevant end_slide markers before
  the split -> 18 slides total after.

Re-validated after the fix (see below): the reset slide (2 blocks) was
independently exercised with a worst-case 10-attempt poll (by pre-seeding a
different value) and rendered every attempt line plus Key points and the
footer within a 220x55 pane -- confirms it was a genuine content-size issue,
now resolved, not a false positive.

## 5. Live presenterm Ctrl-E validation (`make vso-deck`)

Per the task notes and repo-wide guardrail, presenterm was **never** invoked
directly, via bare `script -q`, or with `--export-html`/`-x -E` from a
non-interactive shell. All validation used the tmux-backed validator
described in
`~/work/hashicorp/local_skills/presenterm-demo-decks/SKILL.md`
(`scripts/validate-deck-visual.sh`, private tmux socket + scoped cleanup)
for the non-executing visual pass, and an equivalent private-tmux-socket +
`kitty --detach` pattern (matching the skill's documented Step 5b recipe)
for the live Ctrl-E pass, run from a real bash tool call with the deck
launched directly as the tmux session command (never typed into an
already-interactive shell).

Final clean run (after both fixes above):

- Visual pass (`scripts/validate-deck-visual.sh`, no execution): captured
  all 18 slides; diagrams/box-drawing intact, no clipped bottoms, no raw
  HTML comments leaking, cleanup verified (no leftover tmux/kitty/presenterm
  processes).
- Live Ctrl-E pass: every slide containing an executable block reached
  `[finished]` -- **zero** `[finished error]` / `[finished with error]` /
  `[failed]` anywhere in `output/presenterm-ctrl-e-capture.txt`. Confirmed
  proofs visible in the captured output:
  - Correct `vso-demo` JWT (audience `vault`) authenticates via
    `auth/jwt-vso/login` and returns policies `["default" "mysecret"]`.
  - Wrong-audience JWT (`not-vault`) -> `-> correctly rejected (wrong audience)`.
  - Wrong-service-account JWT (`default`) -> `-> correctly rejected (wrong service account)`.
  - `bound_audiences [vault]` / `bound_subject system:serviceaccount:vso-demo:vso-demo`
    / `policies [mysecret]` reviewed live from `vault read auth/jwt-vso/role/vso-demo`.
  - Rotation slide: value flips from `larry` to `larry-rotated-1` in VSO's
    native Secret, observed by the live poll loop.
  - Reset slide: value flips back to `larry`, observed by the live poll
    loop; `Key points` and the `18` slide-count footer fully visible.
  - `FULL_CTRL_E_PASS=ok` reported; scoped cleanup confirmed no leftover
    tmux/kitty/presenterm validation processes after every run.
- Post-run live state check (outside presenterm): native Secret
  `vso-demo-mysecret` and Vault's `kv-v2/vault-demo/mysecret` both read
  `larry` -- baseline fully restored after the deck run.

## 6. Design decision carried over from Phase 1 (not new to this task)

`auth/jwt-vso` uses `jwks_url` (not `oidc_discovery_url`/full OIDC
discovery): the kind VSO cluster's default `iss` claim
(`https://kubernetes.default.svc.cluster.local`) is cluster-internal and its
self-advertised `jwks_uri` is a Podman-bridge IP, neither reachable from the
Vault cluster. `bound_issuer` is a pure string compare (no reachability
needed), while `jwks_url` points at the externally-mapped, proven-reachable
JWKS endpoint (`https://host.containers.internal:6444/openid/v1/jwks`). See
`docs/vso-jwt-oidc-auth-spike-01.md` for the full spike record. This is an
intentional demo design decision, re-confirmed still correct by this task's
live `[5/7 jwt/oidc auth]` and Ctrl-E proofs.

## Summary against exit criteria

| Exit criterion | Evidence |
|---|---|
| `make setup` configures JWT/OIDC by default | `scripts/tests/test-makefile-vso-jwt-auth-validation.sh` (14/14); live re-run of `scripts/configure-vso-jwt-auth.sh` idempotent |
| Vault uses `auth/jwt-vso` | live `vault auth list` shows `jwt-vso/` type `jwt`; `[5/7]` |
| VSO `VaultAuth` uses `method: jwt` | live `kubectl get vaultauth -o yaml` shows `spec.method: jwt`, `spec.mount: jwt-vso` |
| No `token_reviewer_jwt` in the default path | grep of script (comments only) + live `VaultAuth`/`VaultConnection` YAML has no such field |
| `make verify-two-cluster` proves correct/negative JWT logins, sync, rotation | full 7/7 output above, run multiple times |
| All validation tests pass | 15/15 suites, 269 assertions, 0 failures |
| `make vso-deck` passes live Ctrl-E validation with clean layout | live Ctrl-E capture: 0 errors, 0 clipped/crowded slides after the two fixes above |

**Feature status: all exit criteria met with live evidence.**
