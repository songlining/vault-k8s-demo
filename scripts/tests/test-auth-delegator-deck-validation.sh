#!/usr/bin/env bash
# scripts/tests/test-auth-delegator-deck-validation.sh
#
# Static structural/safety validation for the presenterm deck
# presenterm/auth-delegator.md (the client-JWT-self-review scenario, see
# docs/vso-kubernetes-auth-delegator-plan.md). Mirrors
# scripts/tests/test-vso-deck-validation.sh's checks for presenterm/vso.md,
# plus additional checks specific to this deck's stricter safety
# requirements (no raw JWT/token/secret/CA output at all).
#
# The deck is a read-only 12-slide auth flow (k8s RBAC -> token
# claims/self-review -> Vault mount/role/policy -> login proofs -> app
# consumption). No slide mutates Vault or Kubernetes; no script-path
# +exec blocks are present.
#
# Never launches presenterm (needs a real PTY) or executes a live +exec
# block. Live slide-walk validation is
# scripts/validate-deck-visual.sh; live Ctrl+E rehearsal against a real
# two-cluster lab is a separate, explicitly-approved step.
#
# Usage: scripts/tests/test-auth-delegator-deck-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DECK="${REPO_ROOT}/presenterm/auth-delegator.md"
VALIDATOR="${REPO_ROOT}/scripts/validate-deck-visual.sh"

pass=0
fail=0

assert_pass() {
  echo "PASS: $1"
  pass=$((pass + 1))
}

assert_fail() {
  echo "FAIL: $1"
  fail=$((fail + 1))
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    assert_pass "$desc"
  else
    echo "  expected to find: $needle"
    assert_fail "$desc"
  fi
}

if [ ! -f "$DECK" ]; then
  echo "FAIL: deck file not found: $DECK"
  echo ""
  echo "auth-delegator-deck validation: 0 passed, 1 failed"
  exit 1
fi

DECK_CONTENTS="$(cat "$DECK")"

# --- 1. Markdown structural validity -----------------------------------------

fence_count=$(grep -c '^```' "$DECK")
if [ $((fence_count % 2)) -eq 0 ]; then
  assert_pass "code fences are balanced ($fence_count fences)"
else
  assert_fail "code fences are unbalanced ($fence_count fences, expected even)"
fi

end_slide_count=$(grep -c '<!-- end_slide -->' "$DECK")
if [ "$end_slide_count" -ge 8 ]; then
  assert_pass "deck has $end_slide_count end_slide markers (>= 8)"
else
  assert_fail "deck has only $end_slide_count end_slide markers (expected >= 8)"
fi

if head -1 "$DECK" | grep -q '^---$'; then
  assert_pass "deck starts with YAML front matter delimiter"
else
  assert_fail "deck does not start with YAML front matter (---)"
fi

# Per SKILL.md GUARD-5: the visible cover must be a custom slide, not the
# raw YAML title/sub_title/author intro (which has no spacing control).
if head -5 "$DECK" | grep -q '^title:'; then
  assert_fail "cover uses YAML front matter title (no spacing control) instead of a custom cover slide"
else
  assert_pass "cover uses a custom slide, not raw YAML front matter"
fi

# --- 2. All +exec blocks are syntactically valid bash ------------------------

TMPDIR_EXEC=$(mktemp -d)
trap 'rm -rf "$TMPDIR_EXEC"' EXIT

awk '
  /^```bash \+exec/ { in_block=1; next }
  /^```$/           { if (in_block) { in_block=0; print "===BLOCK==="; next } }
  { if (in_block) print }
' "$DECK" > "$TMPDIR_EXEC/blocks.txt"

block_num=0
syntax_errors=0
: > "$TMPDIR_EXEC/current.bash"
while IFS= read -r line; do
  if [ "$line" = "===BLOCK===" ]; then
    block_num=$((block_num + 1))
    if [ -s "$TMPDIR_EXEC/current.bash" ]; then
      if ! bash -n "$TMPDIR_EXEC/current.bash" 2>/dev/null; then
        echo "  syntax error in +exec block #$block_num:"
        sed 's/^/    /' "$TMPDIR_EXEC/current.bash"
        syntax_errors=$((syntax_errors + 1))
      fi
    fi
    : > "$TMPDIR_EXEC/current.bash"
  else
    printf '%s\n' "$line" >> "$TMPDIR_EXEC/current.bash"
  fi
done < "$TMPDIR_EXEC/blocks.txt"
block_num=$((block_num + 1))
if [ -s "$TMPDIR_EXEC/current.bash" ]; then
  if ! bash -n "$TMPDIR_EXEC/current.bash" 2>/dev/null; then
    echo "  syntax error in +exec block #$block_num:"
    sed 's/^/    /' "$TMPDIR_EXEC/current.bash"
    syntax_errors=$((syntax_errors + 1))
  fi
fi

if [ "$syntax_errors" -eq 0 ]; then
  assert_pass "all +exec code blocks pass bash -n syntax check ($block_num blocks)"
else
  assert_fail "$syntax_errors +exec code block(s) have bash syntax errors"
fi

# --- 3. Every +exec block with kubectl includes --context, with one -------
# --- documented exception: context-agnostic `kubectl config view --raw`  --
# --- (reads kubeconfig metadata directly; matches the same exception    --
# --- already accepted in scripts/verify-vso-auth-delegator.sh and       --
# --- scripts/configure-vso-auth-delegator.sh) -----------------------------

bare_kubectl_in_exec=$(awk '
  /^```bash \+exec/ { in_block=1; next }
  /^```$/           { if (in_block) in_block=0; next }
  { if (in_block) print }
' "$DECK" | grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' | grep -v -- '--context' | grep -v -- 'kubectl config view' || true)

if [ -z "$bare_kubectl_in_exec" ]; then
  assert_pass "every kubectl in +exec blocks includes --context (except the documented 'kubectl config view --raw' CA/cluster-metadata reads)"
else
  assert_fail "found bare kubectl (no --context, not a config-view exception) in an +exec block:"
  echo "$bare_kubectl_in_exec" | sed 's/^/  /'
fi

# --- 4. Script-path +exec blocks (none expected in read-only deck) ---------
# The revamp removed all scripts/ invocations from the deck. Every +exec
# block is a self-contained read-only command (kubectl/get, vault read,
# vault write login, kubectl exec printenv, curl TokenReview). Assert
# zero script-path blocks exist. Keep the guard logic in case one is
# later re-added.

script_exec_blocks=$(awk '
  /^```bash \+exec/ { in_block=1; block=""; next }
  /^```$/           { if (in_block) { if (block ~ /scripts\//) { print block; print "\004" }; in_block=0; next } }
  { if (in_block) block = block $0 "\n" }
' "$DECK")

if [ -z "$script_exec_blocks" ]; then
  assert_pass "deck has zero script-path +exec blocks (all blocks are read-only)"
else
  # If any scripts/ blocks reappear, verify they have a working-directory guard
  guard_missing=0
  script_block_count=0
  current_block=""
  while IFS= read -r line; do
    if [ "$line" = $'\004' ]; then
      script_block_count=$((script_block_count + 1))
      if ! printf '%s' "$current_block" | grep -qE '\[ -f .* \] \|\| cd \.\.'; then
        guard_missing=$((guard_missing + 1))
        echo "  script-path block missing working-directory guard:"
        printf '%s\n' "$current_block" | sed 's/^/    /'
      fi
      current_block=""
    else
      current_block="${current_block}${line}
"
    fi
  done <<< "$script_exec_blocks"
  if [ "$guard_missing" -eq 0 ] && [ "$script_block_count" -gt 0 ]; then
    assert_pass "all $script_block_count script-path +exec block(s) use a working-directory guard"
  else
    assert_fail "$guard_missing of $script_block_count script-path +exec block(s) missing a working-directory guard"
  fi
fi

# --- 5. Deck references the dedicated auth mount/scenario, never the ---------
# --- default JWT/OIDC mount as if it were this scenario's own ---------------

assert_contains "deck references auth/kubernetes-vso-self-review" "$DECK_CONTENTS" 'auth/kubernetes-vso-self-review'
assert_contains "deck references system:auth-delegator" "$DECK_CONTENTS" 'system:auth-delegator'
assert_contains "deck references the dedicated namespaces" "$DECK_CONTENTS" 'vso-auth-delegator-app'
assert_contains "deck explains disable_local_ca_jwt" "$DECK_CONTENTS" 'disable_local_ca_jwt'
assert_contains "deck explains token_reviewer_jwt_set" "$DECK_CONTENTS" 'token_reviewer_jwt_set'
assert_contains "deck explains dual audiences" "$DECK_CONTENTS" 'audience'
assert_contains "deck mentions the default JWT/OIDC scenario for contrast" "$DECK_CONTENTS" 'JWT/OIDC'
assert_contains "deck mentions cross-namespace allowedNamespaces" "$DECK_CONTENTS" 'allowedNamespaces'
assert_contains "deck references TokenReview" "$DECK_CONTENTS" 'TokenReview'

# --- 6. No raw JWT, Vault token, secret, or CA material is ever printed ------
#
# Stricter than presenterm/vso.md: this deck must never pipe a Vault login
# response's raw client_token, a raw JWT, or CA PEM data to stdout.

exec_only="$(awk '
  /^```bash \+exec/ { in_block=1; next }
  /^```$/           { if (in_block) in_block=0; next }
  { if (in_block) print }
' "$DECK")"

# 6a. No echo/printf of a bare $JWT or ${JWT} variable (only used inside
# larger constructs like headers/bodies/pipelines, never echoed alone).
raw_jwt_echoes=$(printf '%s' "$exec_only" | grep -nE '^\s*(echo|printf)[^|]*\$\{?JWT\}?[^A-Za-z_]*$' || true)
if [ -z "$raw_jwt_echoes" ]; then
  assert_pass "no bare \$JWT/\${JWT} is echoed/printed directly in any +exec block"
else
  assert_fail "found a direct echo/printf of \$JWT in an +exec block:"
  echo "$raw_jwt_echoes" | sed 's/^/  /'
fi

# 6b. JWTs are always sent to Vault over stdin with jwt=-, never as a
# jwt=$JWT argv value.
if printf '%s' "$DECK_CONTENTS" | grep -qE 'jwt=[^-].*\$JWT|jwt="\$JWT"'; then
  assert_fail "deck passes a complete JWT as a 'jwt=' CLI argument instead of stdin (jwt=-)"
else
  assert_pass "deck sends JWTs to Vault over stdin with jwt=-"
fi

# 6c. The Vault login proof block(s) must filter the JSON response through
# jq rather than dumping the raw table output (which would include the
# literal token value, as presenterm/vso.md's login slide intentionally
# does -- this deck must not).
login_blocks="$(printf '%s' "$exec_only" | grep -n 'auth/kubernetes-vso-self-review/login' || true)"
if [ -n "$login_blocks" ]; then
  if printf '%s' "$exec_only" | grep -A2 'auth/kubernetes-vso-self-review/login' | grep -qE '\-format=json.*\||jq '; then
    assert_pass "Vault login proof is filtered through jq (-format=json | jq), not raw table output"
  else
    assert_fail "Vault login proof does not appear to filter output through jq -- raw token risk"
  fi
  if printf '%s' "$exec_only" | grep -A3 'auth/kubernetes-vso-self-review/login' | grep -qE '\.auth\.client_token|"client_token"'; then
    assert_fail "Vault login proof appears to reference/print .auth.client_token"
  else
    assert_pass "Vault login proof never references .auth.client_token"
  fi
else
  assert_fail "expected at least one Vault login proof exec block (auth/kubernetes-vso-self-review/login)"
fi

# 6d. The direct TokenReview proof must only print .status, never the whole
# response object or .spec (which echoes the submitted token back).
if printf '%s' "$exec_only" | grep -q 'tokenreviews'; then
  if printf '%s' "$exec_only" | grep -A1 'tokenreviews' | grep -qE "jq '\.status'"; then
    assert_pass "direct TokenReview proof prints only .status (never .spec, which echoes the JWT)"
  else
    assert_fail "direct TokenReview proof does not appear to filter to .status only"
  fi
else
  assert_fail "expected a direct TokenReview (tokenreviews) proof exec block"
fi

# 6e. The Vault mount config read must exclude kubernetes_ca_cert.
if printf '%s' "$exec_only" | grep -q 'auth/kubernetes-vso-self-review/config'; then
  mount_config_block="$(printf '%s' "$exec_only" | grep -A3 'auth/kubernetes-vso-self-review/config' || true)"
  if printf '%s' "$mount_config_block" | grep -qE 'kubernetes_ca_cert'; then
    assert_fail "Vault mount config read includes kubernetes_ca_cert in its jq filter"
  else
    assert_pass "Vault mount config read excludes kubernetes_ca_cert (CA never printed)"
  fi
else
  assert_fail "expected a Vault mount config read (auth/kubernetes-vso-self-review/config)"
fi

# 6f. No literal certificate/PEM material anywhere in the deck.
if printf '%s' "$DECK_CONTENTS" | grep -qE 'BEGIN (RSA |EC )?(PRIVATE KEY|CERTIFICATE)'; then
  assert_fail "deck contains literal PEM/certificate material"
else
  assert_pass "deck contains no literal PEM/certificate material"
fi

# --- 7. Negative-case proofs are present (wrong audience / wrong SA) --------

assert_contains "deck has a vault-audience-only negative proof" "$DECK_CONTENTS" 'vault-audience-only'
assert_contains "deck has a wrong-service-account negative proof" "$DECK_CONTENTS" 'wrong service account'

# --- 8. Box-drawing characters are inside fenced code blocks -----------------

box_outside_fence=$(awk '
  /^```/ { in_fence = !in_fence; next }
  /[┌├│└─┐┤┘┴┬┼]/ { if (!in_fence) print NR ": " $0 }
' "$DECK" || true)

if [ -z "$box_outside_fence" ]; then
  assert_pass "all box-drawing characters are inside fenced code blocks"
else
  assert_fail "found box-drawing characters outside fenced code blocks:"
  echo "$box_outside_fence" | sed 's/^/  /'
fi

# --- 9. All +exec blocks are read-only (no mutating scripts/ calls) ----------
#
# The revamp removed every scripts/ invocation from the deck. Every +exec
# block is a self-contained read-only command. Assert the deck contains
# ZERO calls to scripts/verify-vso-auth-delegator.sh — the verifier is
# only called by make auth-delegator-deck's startup gates, never from
# inside the deck itself.

rotation_call_count=$(printf '%s' "$exec_only" | grep -cF 'bash scripts/verify-vso-auth-delegator.sh' || true)
if [ "$rotation_call_count" -eq 0 ]; then
  assert_pass "deck contains zero calls to scripts/verify-vso-auth-delegator.sh (all +exec blocks are read-only)"
else
  assert_fail "deck calls scripts/verify-vso-auth-delegator.sh ($rotation_call_count call(s)); expected zero (all +exec blocks should be read-only)"
fi

# No exec block should call `vault kv put`/`vault write .../data/` directly.
if printf '%s' "$exec_only" | grep -qE 'vault kv put|vault write .*kv-v2/data/'; then
  assert_fail "deck contains a hand-rolled KV mutation"
else
  assert_pass "deck contains no hand-rolled KV mutation (all blocks are read-only)"
fi

# --- 10. No destructive commands anywhere in the deck ------------------------
#
# The revamp removed the Reset slide. Assert no destructive command
# (namespace/cluster deletion, Helm uninstall) appears anywhere.

if printf '%s' "$DECK_CONTENTS" | grep -qE 'delete (namespace|cluster)|kind delete|helm uninstall'; then
  assert_fail "deck contains a destructive command (delete/helm uninstall)"
else
  assert_pass "deck contains no destructive commands"
fi

# --- 11. validate-deck-visual.sh exists and is referenced by this scenario --

if [ -x "$VALIDATOR" ] || [ -f "$VALIDATOR" ]; then
  assert_pass "scripts/validate-deck-visual.sh exists"
else
  assert_fail "scripts/validate-deck-visual.sh not found"
fi

echo ""
echo "auth-delegator-deck validation: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
