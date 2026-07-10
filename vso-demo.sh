#!/usr/bin/env bash
# vso-demo.sh
#
# Guided, presentation-friendly demo of the Vault Secrets Operator (VSO)
# running ACROSS TWO Podman-backed kind clusters:
#   - Vault cluster (VAULT_CONTEXT, default kind-vault-lab): runs Vault only.
#   - VSO cluster   (VSO_CONTEXT,   default kind-vso-lab):   runs VSO, its
#     CRDs, and the plain consuming app (vso-demo-app) only.
#
# Every kubectl command below targets one of these two clusters EXPLICITLY
# via `--context`, and is never run against whatever the ambient
# `kubectl config current-context` happens to be. This lets the demo work
# correctly even when the operator's shell is pointed at some unrelated
# cluster.
#
# Env overrides live in scripts/lib/two-cluster-env.sh (VAULT_CONTEXT,
# VSO_CONTEXT, NAMESPACE, VSO_NAMESPACE, VSO_OPERATOR_NAMESPACE,
# VSO_AUTH_MOUNT, VSO_AUTH_ROLE, SECRET_NAME, APP_POD), plus
# BASELINE_USERNAME, ROTATION_NUMBER/ROTATED_USERNAME, SYNC_ATTEMPTS, and
# NO_WAIT (set NO_WAIT=true for non-interactive/CI runs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./scripts/lib/two-cluster-env.sh
source "${SCRIPT_DIR}/scripts/lib/two-cluster-env.sh"

BASELINE_USERNAME="${BASELINE_USERNAME:-larry}"
ROTATION_NUMBER="${ROTATION_NUMBER:-1}"
ROTATED_USERNAME="${ROTATED_USERNAME:-${BASELINE_USERNAME}-rotated-${ROTATION_NUMBER}}"
SYNC_ATTEMPTS="${SYNC_ATTEMPTS:-20}"
NO_WAIT="${NO_WAIT:-false}"

if [ -t 1 ]; then
  BLUE="$(printf '\033[34m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  CYAN="$(printf '\033[36m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
else
  BLUE=""
  GREEN=""
  YELLOW=""
  CYAN=""
  BOLD=""
  RESET=""
fi

pause() {
  if [ "$NO_WAIT" = "true" ]; then
    return
  fi

  printf "\n%sPress ENTER to continue...%s" "$YELLOW" "$RESET"
  read -r _
}

section() {
  local title="$1"

  if [ "$NO_WAIT" != "true" ]; then
    clear
  fi

  printf "%s\n" "$BLUE"
  printf "======================================================================\n"
  printf "%s\n" "$title"
  printf "======================================================================\n"
  printf "%s\n\n" "$RESET"
}

p() {
  printf "%s# %s%s\n" "$CYAN" "$1" "$RESET"
}

pe() {
  local cmd="$1"

  printf "%s$ %s%s\n" "$BOLD" "$cmd" "$RESET"
  bash -o pipefail -c "$cmd"
  printf "\n"
}

# --- Preflight ---------------------------------------------------------------
#
# Every kubectl invocation in this demo targets VAULT_CONTEXT or VSO_CONTEXT
# explicitly (see the `--context ${VAULT_CONTEXT}` / `--context ${VSO_CONTEXT}`
# on every `pe "kubectl ..."` call below), so this demo works correctly no
# matter what the ambient `kubectl config current-context` is set to.

fail=0
require_commands kubectl base64 || fail=1
require_contexts || fail=1
if [ "$fail" -ne 0 ]; then
  exit 1
fi

# Resolve the Vault pod name once, in the Vault cluster only.
VAULT_POD=$(kubectl_vault get pods -n "$NAMESPACE" -l "$VAULT_POD_LABEL_SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$VAULT_POD" ]; then
  echo "ERROR: no Vault pod found in context '${VAULT_CONTEXT}' namespace '${NAMESPACE}'." >&2
  echo "       Run 'make setup-vault' (or scripts/setup-vault-cluster.sh) first." >&2
  exit 1
fi

verify_ready() {
  # Vault readiness lives entirely in the Vault cluster.
  kubectl_vault get pod "$VAULT_POD" -n "$NAMESPACE" >/dev/null
  kubectl_vault wait -n "$NAMESPACE" --for=condition=Ready "pod/${VAULT_POD}" --timeout=10s >/dev/null

  # VSO, its CRDs, and the consuming app all live in the VSO cluster.
  kubectl_vso wait -n "$VSO_OPERATOR_NAMESPACE" --for=condition=Available deployment \
    -l app.kubernetes.io/name=vault-secrets-operator --timeout=20s >/dev/null
  kubectl_vso get pod "$APP_POD" -n "$VSO_NAMESPACE" >/dev/null
  kubectl_vso wait -n "$VSO_NAMESPACE" --for=condition=Ready "pod/${APP_POD}" --timeout=20s >/dev/null
}

if ! verify_ready 2>/dev/null; then
  echo "ERROR: demo environment is not ready." >&2
  echo "       Vault cluster:  ${VAULT_CONTEXT} (namespace ${NAMESPACE})" >&2
  echo "       VSO cluster:    ${VSO_CONTEXT} (namespaces ${VSO_OPERATOR_NAMESPACE}, ${VSO_NAMESPACE})" >&2
  echo "       Run 'make setup' first, or the individual scripts/*.sh steps." >&2
  exit 1
fi

section "Vault Secrets Operator (VSO) Demo -- Two Clusters"
cat <<INTRO
This guided flow demonstrates the Vault Secrets Operator across TWO
Podman-backed kind clusters: Vault runs in one cluster, and VSO (plus its
CRDs and the consuming app) runs in a completely separate cluster.

  Vault cluster: ${VAULT_CONTEXT}
  VSO cluster:   ${VSO_CONTEXT}

The customer problem:
  - Teams want Vault secrets, but their apps already consume native Kubernetes
    Secrets (envFrom, secretKeyRef, volume mounts).
  - They do not want every workload to carry Vault-specific annotations or run a
    per-pod sidecar just to read a secret.
  - They want secrets to stay in sync automatically when the source changes.
  - Vault and the workloads that consume its secrets may not even live in the
    same Kubernetes cluster.

What we will prove:
  1. The Vault Secrets Operator is running cluster-wide, in its own cluster.
  2. Three CRDs in the VSO cluster declare how to reach Vault (in the OTHER
     cluster), how to authenticate, and what to sync.
  3. A Vault KV secret is materialized as a native Kubernetes Secret in the
     VSO cluster.
  4. A plain pod in the VSO cluster consumes it with zero Vault configuration.
  5. The operator's Vault identity is least-privilege and dedicated to
     cross-cluster (VSO cluster) Kubernetes auth.
  6. Updating the value in Vault (Vault cluster) refreshes the Kubernetes
     Secret (VSO cluster) automatically.
INTRO
pause

section "1. Architecture: two clusters, one sync pipeline"
cat <<'OVERVIEW'
High-level concept
──────────────────
The Vault Secrets Operator (VSO) is a Kubernetes operator that runs ONCE per
cluster -- and in this demo, it runs in a cluster that does NOT run Vault. VSO
watches custom resources (CRDs) you define, logs into Vault across the
cluster boundary on your behalf, and syncs Vault secrets into native
Kubernetes Secret objects in its own cluster.

Your application never talks to Vault, and it never has to be in the same
cluster as Vault. It just reads a normal Kubernetes Secret the same way it
always has -- via envFrom, secretKeyRef, or a volume mount.
OVERVIEW

cat <<DIAGRAM
  ============================        ============================
   VAULT CLUSTER                       VSO CLUSTER
   context: ${VAULT_CONTEXT}                context: ${VSO_CONTEXT}
  ============================        ============================

   Namespace: ${NAMESPACE}                  Namespace: vault-secrets-operator-system
     Vault (${VAULT_POD})                     VSO Controller (watches CRDs below)
     auth/${VSO_AUTH_MOUNT}
     kv-v2/vault-demo/mysecret         Namespace: ${VSO_NAMESPACE}
                                         VaultConnection / VaultAuth /
     external address:                    VaultStaticSecret (CRDs)
     ${VAULT_ADDR}   <----- reached by ---- (spec.address above)
                                         K8s Secret: ${SECRET_NAME}
                                           <----- synced by VSO -----
     VSO API server (for TokenReview):   App Pod: ${APP_POD}
     ${VSO_API_ADDR}   ----> validates SA JWTs against this cluster
                                           (no Vault config at all)

  Vault never runs in the VSO cluster. VSO, its CRDs, and the app pod never
  run in the Vault cluster. The only link between them is the network path
  above: VaultConnection reaches Vault's external address, and Vault reaches
  the VSO cluster's API server for Kubernetes auth TokenReview requests.
DIAGRAM
pause

section "1b. Step-by-step flow"
cat <<STEPS
  ┌─────────────────────────────────────────────────────────────┐
  │ VSO cluster (${VSO_CONTEXT}), ${VSO_NAMESPACE} namespace                    │
  │  VaultConnection ──► VaultAuth ──► VaultStaticSecret (CRDs) │
  └──────────────────────────┬──────────────────────────────────┘
                             │
                (1) VSO controller watches these CRDs
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │ VSO cluster (${VSO_CONTEXT}), vault-secrets-operator-system  │
  │  VSO Controller                                             │
  └──────────────────────────┬──────────────────────────────────┘
                             │
     (2) login across the cluster boundary with vso-demo SA JWT,
         validated by Vault via TokenReview against the VSO
         cluster's API server (${VSO_API_ADDR})
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │ Vault cluster (${VAULT_CONTEXT}), ${NAMESPACE} namespace     │
  │  Vault (${VAULT_POD}), reachable at ${VAULT_ADDR}            │
  │    auth/${VSO_AUTH_MOUNT} ── role: ${VSO_AUTH_ROLE} ── policy: mysecret │
  │    kv-v2/vault-demo/mysecret                                 │
  └──────────────────────────┬──────────────────────────────────┘
                             │
                  (3) writes / refreshes every 30s
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │ VSO cluster (${VSO_CONTEXT}), ${VSO_NAMESPACE} namespace     │
  │  Kubernetes Secret: ${SECRET_NAME}                           │
  └──────────────────────────┬──────────────────────────────────┘
                             │
               (4) envFrom -- standard Kubernetes API
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │ VSO cluster (${VSO_CONTEXT}), ${VSO_NAMESPACE} namespace     │
  │  App Pod: ${APP_POD}  (no Vault annotations, no sidecar)     │
  └─────────────────────────────────────────────────────────────┘

Unlike the Agent Injector (a same-cluster sidecar per pod that writes a
file), VSO runs once per cluster -- a DIFFERENT cluster from Vault in this
demo -- and turns Vault secrets into first-class Kubernetes Secrets any app
can consume with zero Vault knowledge.
STEPS
pause

section "2. The operator is running (VSO cluster)"
p "The Vault Secrets Operator runs as a cluster-wide controller in the VSO cluster"
pe "kubectl --context ${VSO_CONTEXT} get pods -n ${VSO_OPERATOR_NAMESPACE}"

cat <<'POINTS'
Key points:
  - One operator Deployment serves the whole VSO cluster.
  - There is no per-application sidecar in this model.
  - VSO does not need to run in the same cluster as Vault.
POINTS
pause

section "3. The CRDs that drive the sync (VSO cluster)"
p "Three declarative objects describe the whole pipeline, all in the VSO cluster"
cat <<'MODEL'
  ┌──────────────────┬──────────────┬────────────────────────┐
  │ VaultConnection  │ VaultAuth    │ VaultStaticSecret      │
  ├──────────────────┼──────────────┼────────────────────────┤
  │ Where is Vault?  │ How login?   │ What secret to sync?   │
  └──────────────────┴──────────────┴────────────────────────┘

Other VSO secret CRDs you can use:
  - VaultDynamicSecret: dynamic leased credentials, such as database users.
  - VaultPKISecret: issued and renewed certificates from Vault PKI.
  - HCPVaultSecretsApp: sync from HCP Vault Secrets instead of self-managed Vault.

This demo uses VaultStaticSecret because the source is an existing KV secret.

MODEL
pe "kubectl --context ${VSO_CONTEXT} get vaultconnection,vaultauth,vaultstaticsecret -n ${VSO_NAMESPACE}"

p "VaultConnection points at Vault's EXTERNAL, cross-cluster address"
pe "kubectl --context ${VSO_CONTEXT} get vaultconnection vso-demo-connection -n ${VSO_NAMESPACE} -o jsonpath='{\"  address: \"}{.spec.address}{\"\\n\"}'"

p "The VaultStaticSecret declares the Vault path and the destination Secret"
pe "kubectl --context ${VSO_CONTEXT} get vaultstaticsecret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{\"  mount: \"}{.spec.mount}{\"\\n  path: \"}{.spec.path}{\"\\n  type: \"}{.spec.type}{\"\\n  refreshAfter: \"}{.spec.refreshAfter}{\"\\n  destination: \"}{.spec.destination.name}{\"\\n\"}'"

cat <<POINTS
Key points:
  - VaultConnection: how to reach Vault from a DIFFERENT cluster
    (spec.address = ${VAULT_ADDR}, never a same-cluster
    *.svc.cluster.local DNS name).
  - VaultAuth: authenticate against the dedicated cross-cluster mount
    auth/${VSO_AUTH_MOUNT}, role ${VSO_AUTH_ROLE}.
  - VaultStaticSecret: read kv-v2/vault-demo/mysecret, refresh every 30s, and
    materialize it as the native Secret ${SECRET_NAME} in the VSO cluster.
POINTS
pause

section "4. The native Kubernetes Secret VSO created (VSO cluster)"
p "VSO wrote a standard Kubernetes Secret in the VSO cluster (not a file in a pod)"
pe "kubectl --context ${VSO_CONTEXT} get secret ${SECRET_NAME} -n ${VSO_NAMESPACE}"

p "Decode the synced value"
pe "kubectl --context ${VSO_CONTEXT} get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d; echo"

cat <<'POINTS'
Key points:
  - This is a first-class Secret object any workload in the VSO cluster can
    consume.
  - The value came from Vault in an entirely different cluster, but the
    object is pure Kubernetes.
POINTS
pause

section "5. A plain pod consumes it with zero Vault config (VSO cluster)"
p "The app reads the secret through standard envFrom at pod start"
pe "kubectl --context ${VSO_CONTEXT} exec ${APP_POD} -n ${VSO_NAMESPACE} -- printenv username"

p "The consuming pod has NO Vault annotations and NO sidecar (count should be 0)"
pe "kubectl --context ${VSO_CONTEXT} get pod ${APP_POD} -n ${VSO_NAMESPACE} -o yaml | grep -c 'vault.hashicorp.com' || true"

p "It is a single-container pod (1/1), not 2/2 like an injected sidecar pod"
pe "kubectl --context ${VSO_CONTEXT} get pod ${APP_POD} -n ${VSO_NAMESPACE}"

cat <<'POINTS'
Key points:
  - The application is completely Vault-agnostic, and does not know or care
    that Vault is running in a different cluster.
  - Kubernetes envFrom values are captured when a pod starts; later Secret
    refreshes update the Secret object, not the existing process environment.
  - Contrast with the Agent Injector demo, where pods are 2/2 and carry
    vault.hashicorp.com annotations.
POINTS
pause

section "6. Least-privilege Vault identity (Vault cluster)"
p "VSO authenticates as a dedicated, narrowly-scoped, cross-cluster Kubernetes auth role"
pe "kubectl --context ${VAULT_CONTEXT} exec ${VAULT_POD} -n ${NAMESPACE} -- vault read auth/${VSO_AUTH_MOUNT}/role/${VSO_AUTH_ROLE} | grep -E 'bound_service_account_names|bound_service_account_namespaces|token_policies|policies'"

p "The mysecret policy only allows reading this one KV path"
pe "kubectl --context ${VAULT_CONTEXT} exec ${VAULT_POD} -n ${NAMESPACE} -- vault policy read mysecret"

cat <<POINTS
Key points:
  - auth/${VSO_AUTH_MOUNT} is a mount dedicated to the VSO cluster --
    completely separate from the same-cluster auth/kubernetes mount used by
    the Agent Injector/OTel demo paths.
  - The role only maps ${VSO_NAMESPACE}/${VSO_AUTH_ROLE} (in the VSO cluster)
    to the mysecret policy.
  - The policy grants read on a single KV path and nothing else.
POINTS
pause

section "7. Live rotation: change Vault, watch the VSO cluster's Secret update"
p "Seed Vault with the original value (write happens in the Vault cluster)"
pe "kubectl --context ${VAULT_CONTEXT} exec ${VAULT_POD} -n ${NAMESPACE} -- vault kv put kv-v2/vault-demo/mysecret username=${BASELINE_USERNAME}"

p "Wait for VSO to sync the baseline value into the VSO cluster's Kubernetes Secret"
pe "for i in \$(seq 1 ${SYNC_ATTEMPTS}); do v=\$(kubectl --context ${VSO_CONTEXT} get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d); echo \"  attempt \$i: \$v\"; if [ \"\$v\" = \"${BASELINE_USERNAME}\" ]; then echo '  -> Secret synced to baseline by VSO'; exit 0; fi; sleep 3; done; echo 'ERROR: Secret did not sync to ${BASELINE_USERNAME}' >&2; exit 1"

p "Current value in the native Kubernetes Secret (read happens in the VSO cluster)"
pe "kubectl --context ${VSO_CONTEXT} get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d; echo"

p "Update the value in Vault (write happens in the Vault cluster)"
pe "kubectl --context ${VAULT_CONTEXT} exec ${VAULT_POD} -n ${NAMESPACE} -- vault kv put kv-v2/vault-demo/mysecret username=${ROTATED_USERNAME}"

p "VSO reconciles within refreshAfter (30s). Poll the VSO cluster's Secret until it flips..."
pe "for i in \$(seq 1 ${SYNC_ATTEMPTS}); do v=\$(kubectl --context ${VSO_CONTEXT} get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d); echo \"  attempt \$i: \$v\"; if [ \"\$v\" = \"${ROTATED_USERNAME}\" ]; then echo '  -> Secret updated automatically by VSO'; exit 0; fi; sleep 3; done; echo 'ERROR: Secret did not sync to ${ROTATED_USERNAME}' >&2; exit 1"

p "Reset the secret back to its original value so the demo is repeatable (Vault cluster)"
pe "kubectl --context ${VAULT_CONTEXT} exec ${VAULT_POD} -n ${NAMESPACE} -- vault kv put kv-v2/vault-demo/mysecret username=${BASELINE_USERNAME}"

p "Wait for the reset to sync so the next demo starts clean (VSO cluster)"
pe "for i in \$(seq 1 ${SYNC_ATTEMPTS}); do v=\$(kubectl --context ${VSO_CONTEXT} get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d); echo \"  attempt \$i: \$v\"; if [ \"\$v\" = \"${BASELINE_USERNAME}\" ]; then echo '  -> Secret reset synced by VSO'; exit 0; fi; sleep 3; done; echo 'ERROR: Secret did not reset to ${BASELINE_USERNAME}' >&2; exit 1"

cat <<'POINTS'
Key points:
  - No pod restart, no manual sync: VSO watches Vault across the cluster
    boundary and updates the Secret in its own cluster.
  - We reset the value to 'larry' so re-running the demo starts clean.
POINTS
pause

section "Demo complete"
printf "%s" "$GREEN"
cat <<SUMMARY
What we proved:
  - The Vault Secrets Operator runs once, cluster-wide, in the VSO cluster
    (${VSO_CONTEXT}) -- a different cluster from Vault (${VAULT_CONTEXT}).
  - CRDs in the VSO cluster declaratively describe connection, auth, and
    what to sync, reaching Vault via its documented external address
    (${VAULT_ADDR}).
  - A Vault KV secret becomes a native Kubernetes Secret in the VSO cluster.
  - A plain pod consumes it with zero Vault knowledge (1/1, no annotations).
  - VSO's Vault identity is least-privilege and dedicated to cross-cluster
    auth (auth/${VSO_AUTH_MOUNT}, one role, one policy, one path).
  - Changing the value in Vault (Vault cluster) refreshes the Kubernetes
    Secret (VSO cluster) automatically, within the refresh window.

Agent Injector vs Vault Secrets Operator:
  - Agent Injector: per-pod sidecar writes a secret file, same cluster as
    Vault; pod is 2/2 and carries vault.hashicorp.com annotations.
  - VSO: cluster-wide operator syncs into native Secrets, can run in a
    completely different cluster from Vault; app pods are 1/1 and
    Vault-agnostic.

Useful follow-up commands:
  make vso-verify
  make vso-status
  kubectl --context ${VSO_CONTEXT} describe vaultstaticsecret ${SECRET_NAME} -n ${VSO_NAMESPACE}
  kubectl --context ${VSO_CONTEXT} logs -n ${VSO_OPERATOR_NAMESPACE} -l app.kubernetes.io/name=vault-secrets-operator
SUMMARY
printf "%s" "$RESET"
