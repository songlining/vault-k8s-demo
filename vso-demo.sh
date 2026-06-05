#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
VSO_NAMESPACE="${VSO_NAMESPACE:-vso-demo}"
VSO_OPERATOR_NAMESPACE="${VSO_OPERATOR_NAMESPACE:-vault-secrets-operator-system}"
SECRET_NAME="${SECRET_NAME:-vso-demo-mysecret}"
APP_POD="${APP_POD:-vso-demo-app}"
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

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf "Missing required command: %s\n" "$command_name" >&2
    exit 1
  fi
}

verify_ready() {
  require_command kubectl

  kubectl get pod vault-0 -n "$NAMESPACE" >/dev/null
  kubectl wait -n "$NAMESPACE" --for=condition=Ready pod/vault-0 --timeout=10s >/dev/null
  kubectl wait -n "$VSO_OPERATOR_NAMESPACE" --for=condition=Available deployment \
    -l app.kubernetes.io/name=vault-secrets-operator --timeout=20s >/dev/null
  kubectl get pod vso-demo-app -n "$VSO_NAMESPACE" >/dev/null
  kubectl wait -n "$VSO_NAMESPACE" --for=condition=Ready pod/vso-demo-app --timeout=20s >/dev/null
}

verify_ready

section "Vault Secrets Operator (VSO) Demo"
cat <<'INTRO'
This guided flow demonstrates the Vault Secrets Operator: a cluster-wide
operator that syncs Vault secrets into native Kubernetes Secret objects.

The customer problem:
  - Teams want Vault secrets, but their apps already consume native Kubernetes
    Secrets (envFrom, secretKeyRef, volume mounts).
  - They do not want every workload to carry Vault-specific annotations or run a
    per-pod sidecar just to read a secret.
  - They want secrets to stay in sync automatically when the source changes.

What we will prove:
  1. The Vault Secrets Operator is running cluster-wide.
  2. Three CRDs declare how to reach Vault, how to authenticate, and what to sync.
  3. A Vault KV secret is materialized as a native Kubernetes Secret.
  4. A plain pod consumes it with zero Vault configuration.
  5. The operator's Vault identity is least-privilege.
  6. Updating the value in Vault refreshes the Kubernetes Secret automatically.
INTRO
pause

section "1. Architecture: how VSO delivers secrets"
cat <<'OVERVIEW'
High-level concept
──────────────────
The Vault Secrets Operator (VSO) is a Kubernetes operator that runs ONCE per
cluster. It watches custom resources (CRDs) you define, logs into Vault on your
behalf, and syncs Vault secrets into native Kubernetes Secret objects.

Your application never talks to Vault. It just reads a normal Kubernetes Secret
the same way it always has — via envFrom, secretKeyRef, or a volume mount.
OVERVIEW

cat <<'DIAGRAM'
  ┌─────────────────────────────────────────────┐
  │            Kubernetes Cluster               │
  │                                             │
  │  ┌─────────────────────────────────────┐    │
  │  │  vault-secrets-operator-system      │    │
  │  │  ┌──────────────────────────────┐   │    │
  │  │  │   VSO Controller (operator)  │   │    │
  │  │  └──────────────────────────────┘   │    │
  │  └──────────────┬──────────────────────┘    │
  │                 │ watches / reconciles      │
  │  ┌──────────────▼──────────────────────┐    │
  │  │  vso-demo namespace                 │    │
  │  │  ┌────────────┐ ┌────────────┐      │    │
  │  │  │VaultConn.  │ │ VaultAuth  │  CRDs│    │
  │  │  └────────────┘ └────────────┘      │    │
  │  │  ┌──────────────────────────────┐   │    │
  │  │  │    VaultStaticSecret (CRD)   │   │    │
  │  │  └──────────────────────────────┘   │    │
  │  │         │ syncs into                │    │
  │  │  ┌──────▼───────────────────────┐   │    │
  │  │  │  K8s Secret: vso-demo-       │   │    │
  │  │  │             mysecret         │   │    │
  │  │  └──────────────────────────────┘   │    │
  │  │         │ envFrom (standard K8s)    │    │
  │  │  ┌──────▼───────────────────────┐   │    │
  │  │  │  App Pod: vso-demo-app       │   │    │
  │  │  │  (no Vault config at all)    │   │    │
  │  │  └──────────────────────────────┘   │    │
  │  └─────────────────────────────────────┘    │
  │                                             │
  │  ┌─────────────────────────────────────┐    │
  │  │  default namespace                  │    │
  │  │  ┌──────────────────────────────┐   │    │
  │  │  │  Vault (vault-0)             │   │    │
  │  │  │  auth/kubernetes             │   │    │
  │  │  │  kv-v2/vault-demo/mysecret   │   │    │
  │  │  └──────────────────────────────┘   │    │
  │  └─────────────────────────────────────┘    │
  └─────────────────────────────────────────────┘
DIAGRAM
pause

section "1b. Step-by-step flow"
cat <<'ARCH'
  ┌─────────────────────────────────────────────────────────────┐
  │ vso-demo namespace                                          │
  │  VaultConnection ──► VaultAuth ──► VaultStaticSecret (CRDs) │
  └──────────────────────────┬──────────────────────────────────┘
                             │
                (1) VSO controller watches these CRDs
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │ vault-secrets-operator-system                               │
  │  VSO Controller                                             │
  └──────────────────────────┬──────────────────────────────────┘
                             │
             (2) login with vso-demo SA JWT + read secret
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │ default namespace                                           │
  │  Vault (vault-0)                                            │
  │    auth/kubernetes ── role: vso-demo ── policy: mysecret    │
  │    kv-v2/vault-demo/mysecret                                │
  └──────────────────────────┬──────────────────────────────────┘
                             │
                  (3) writes / refreshes every 30s
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │ vso-demo namespace                                          │
  │  Kubernetes Secret: vso-demo-mysecret                       │
  └──────────────────────────┬──────────────────────────────────┘
                             │
               (4) envFrom — standard Kubernetes API
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │ vso-demo namespace                                          │
  │  App Pod: vso-demo-app  (no Vault annotations, no sidecar)  │
  └─────────────────────────────────────────────────────────────┘

Unlike the Agent Injector (a sidecar per pod that writes a file),
VSO runs once per cluster and turns Vault secrets into first-class
Kubernetes Secrets any app can consume with zero Vault knowledge.
ARCH
pause

section "2. The operator is running"
p "The Vault Secrets Operator runs as a cluster-wide controller"
pe "kubectl get pods -n ${VSO_OPERATOR_NAMESPACE}"

cat <<'POINTS'
Key points:
  - One operator Deployment serves the whole cluster.
  - There is no per-application sidecar in this model.
POINTS
pause

section "3. The CRDs that drive the sync"
p "Three declarative objects describe the whole pipeline"
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
pe "kubectl get vaultconnection,vaultauth,vaultstaticsecret -n ${VSO_NAMESPACE}"

p "The VaultStaticSecret declares the Vault path and the destination Secret"
pe "kubectl get vaultstaticsecret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{\"  mount: \"}{.spec.mount}{\"\\n  path: \"}{.spec.path}{\"\\n  type: \"}{.spec.type}{\"\\n  refreshAfter: \"}{.spec.refreshAfter}{\"\\n  destination: \"}{.spec.destination.name}{\"\\n\"}'"

cat <<'POINTS'
Key points:
  - VaultConnection: how to reach Vault (in-cluster service URL).
  - VaultAuth: reuse the existing kubernetes auth method with role vso-demo.
  - VaultStaticSecret: read kv-v2/vault-demo/mysecret, refresh every 30s, and
    materialize it as the native Secret vso-demo-mysecret.
POINTS
pause

section "4. The native Kubernetes Secret VSO created"
p "VSO wrote a standard Kubernetes Secret (not a file in a pod)"
pe "kubectl get secret ${SECRET_NAME} -n ${VSO_NAMESPACE}"

p "Decode the synced value"
pe "kubectl get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d; echo"

cat <<'POINTS'
Key points:
  - This is a first-class Secret object any workload can consume.
  - The value came from Vault, but the object is pure Kubernetes.
POINTS
pause

section "5. A plain pod consumes it with zero Vault config"
p "The app reads the secret through standard envFrom at pod start"
pe "kubectl exec ${APP_POD} -n ${VSO_NAMESPACE} -- printenv username"

p "The consuming pod has NO Vault annotations and NO sidecar (count should be 0)"
pe "kubectl get pod ${APP_POD} -n ${VSO_NAMESPACE} -o yaml | grep -c 'vault.hashicorp.com' || true"

p "It is a single-container pod (1/1), not 2/2 like an injected sidecar pod"
pe "kubectl get pod ${APP_POD} -n ${VSO_NAMESPACE}"

cat <<'POINTS'
Key points:
  - The application is completely Vault-agnostic.
  - Kubernetes envFrom values are captured when a pod starts; later Secret
    refreshes update the Secret object, not the existing process environment.
  - Contrast with the Agent Injector demo, where pods are 2/2 and carry
    vault.hashicorp.com annotations.
POINTS
pause

section "6. Least-privilege Vault identity"
p "VSO authenticates as a dedicated, narrowly-scoped Kubernetes auth role"
pe "kubectl exec vault-0 -n ${NAMESPACE} -- vault read auth/kubernetes/role/vso-demo | grep -E 'bound_service_account_names|bound_service_account_namespaces|token_policies|policies'"

p "The mysecret policy only allows reading this one KV path"
pe "kubectl exec vault-0 -n ${NAMESPACE} -- vault policy read mysecret"

cat <<'POINTS'
Key points:
  - The role only maps vso-demo/vso-demo to the mysecret policy.
  - The policy grants read on a single KV path and nothing else.
POINTS
pause

section "7. Live rotation: change Vault, watch the Secret update"
p "Seed Vault with the original value so rotation starts from a known baseline"
pe "kubectl exec vault-0 -n ${NAMESPACE} -- vault kv put kv-v2/vault-demo/mysecret username=${BASELINE_USERNAME}"

p "Wait for VSO to sync the baseline value into the Kubernetes Secret"
pe "for i in \$(seq 1 ${SYNC_ATTEMPTS}); do v=\$(kubectl get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d); echo \"  attempt \$i: \$v\"; if [ \"\$v\" = \"${BASELINE_USERNAME}\" ]; then echo '  -> Secret synced to baseline by VSO'; exit 0; fi; sleep 3; done; echo 'ERROR: Secret did not sync to ${BASELINE_USERNAME}' >&2; exit 1"

p "Current value in the native Kubernetes Secret"
pe "kubectl get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d; echo"

p "Update the value in Vault"
pe "kubectl exec vault-0 -n ${NAMESPACE} -- vault kv put kv-v2/vault-demo/mysecret username=${ROTATED_USERNAME}"

p "VSO reconciles within refreshAfter (30s). Poll the Secret until it flips..."
pe "for i in \$(seq 1 ${SYNC_ATTEMPTS}); do v=\$(kubectl get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d); echo \"  attempt \$i: \$v\"; if [ \"\$v\" = \"${ROTATED_USERNAME}\" ]; then echo '  -> Secret updated automatically by VSO'; exit 0; fi; sleep 3; done; echo 'ERROR: Secret did not sync to ${ROTATED_USERNAME}' >&2; exit 1"

p "Reset the secret back to its original value so the demo is repeatable"
pe "kubectl exec vault-0 -n ${NAMESPACE} -- vault kv put kv-v2/vault-demo/mysecret username=${BASELINE_USERNAME}"

p "Wait for the reset to sync so the next demo starts clean"
pe "for i in \$(seq 1 ${SYNC_ATTEMPTS}); do v=\$(kubectl get secret ${SECRET_NAME} -n ${VSO_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d); echo \"  attempt \$i: \$v\"; if [ \"\$v\" = \"${BASELINE_USERNAME}\" ]; then echo '  -> Secret reset synced by VSO'; exit 0; fi; sleep 3; done; echo 'ERROR: Secret did not reset to ${BASELINE_USERNAME}' >&2; exit 1"

cat <<'POINTS'
Key points:
  - No pod restart, no manual sync: VSO watches Vault and updates the Secret.
  - We reset the value to 'larry' so re-running the demo starts clean.
POINTS
pause

section "Demo complete"
printf "%s" "$GREEN"
cat <<'SUMMARY'
What we proved:
  - The Vault Secrets Operator runs once, cluster-wide.
  - CRDs declaratively describe connection, auth, and what to sync.
  - A Vault KV secret becomes a native Kubernetes Secret.
  - A plain pod consumes it with zero Vault knowledge (1/1, no annotations).
  - VSO's Vault identity is least-privilege (one role, one policy, one path).
  - Changing the value in Vault refreshes the Kubernetes Secret automatically.

Agent Injector vs Vault Secrets Operator:
  - Agent Injector: per-pod sidecar writes a secret file; pod is 2/2 and carries
    vault.hashicorp.com annotations.
  - VSO: cluster-wide operator syncs into native Secrets; app pods are 1/1 and
    Vault-agnostic.

Useful follow-up commands:
  make vso-verify
  make vso-status
  kubectl describe vaultstaticsecret vso-demo-mysecret -n vso-demo
  kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator
SUMMARY
printf "%s" "$RESET"
