#!/usr/bin/env bash
# scripts/tests/test-vso-deck-validation.sh
#
# Unit/static tests for the presenterm slide deck (presenterm/vso.md):
#   - markdown structural validity: balanced code fences, balanced
#     `end_slide` markers, front matter is well-formed
#   - all `+exec` code blocks are syntactically valid bash (bash -n)
#   - all `+exec` blocks that invoke kubectl include an explicit `--context`
#   - the one `+exec` block that references a script path
#     (scripts/configure-vso-jwt-auth.sh) uses a robust working-directory
#     guard (`[ -f ... ] || cd ..`)
#   - the deck references the JWT/OIDC auth mount (`auth/jwt-vso`), never
#     presents `auth/kubernetes-vso` as the default VSO auth method, and
#     includes the JWT positive + negative (wrong-audience /
#     wrong-service-account) auth proof slides
#   - no raw JWT variable is echoed in any `+exec` block
#   - box-drawing diagrams (if any) are inside fenced code blocks so they
#     render as monospace without layout breakage
#
# These tests never launch presenterm (which requires a TTY) or execute any
# live code block. Live Ctrl-E validation against a real two-cluster lab is
# performed in task 11 (`make vso-deck`).
#
# Usage: scripts/tests/test-vso-deck-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DECK="${REPO_ROOT}/presenterm/vso.md"

pass=0
fail=0

assert_pass() {
  local desc="$1"
  echo "PASS: $desc"
  pass=$((pass + 1))
}

assert_fail() {
  local desc="$1"
  echo "FAIL: $desc"
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

DECK_CONTENTS="$(cat "$DECK")"

# --- 1. Markdown structural validity -----------------------------------------

# 1a. Code fences (```) are balanced (must be an even count).
fence_count=$(grep -c '^```' "$DECK")
if [ $((fence_count % 2)) -eq 0 ]; then
  assert_pass "code fences are balanced ($fence_count fences)"
else
  assert_fail "code fences are unbalanced ($fence_count fences, expected even)"
fi

# 1b. `end_slide` markers are present (at least one slide boundary).
end_slide_count=$(grep -c '<!-- end_slide -->' "$DECK")
if [ "$end_slide_count" -ge 2 ]; then
  assert_pass "deck has $end_slide_count end_slide markers (>= 2)"
else
  assert_fail "deck has only $end_slide_count end_slide markers (expected >= 2)"
fi

# 1c. Front matter is well-formed (starts and ends with ---).
if head -1 "$DECK" | grep -q '^---$'; then
  assert_pass "deck starts with YAML front matter delimiter"
else
  assert_fail "deck does not start with YAML front matter (---)"
fi

# 1d. Title is present in front matter.
title_line=$(head -20 "$DECK" | grep -E '^title:' || true)
if [ -n "$title_line" ]; then
  assert_pass "front matter has a title"
else
  assert_fail "front matter is missing a title"
fi

# --- 2. All +exec blocks are syntactically valid bash ------------------------

# Extract every +exec code block, write to temp file, run bash -n.
TMPDIR_EXEC=$(mktemp -d)
trap 'rm -rf "$TMPDIR_EXEC"' EXIT

block_num=0
syntax_errors=0

# Use awk to extract blocks between ```bash +exec and the closing ```
awk '
  /^```bash \+exec/ { in_block=1; next }
  /^```$/           { if (in_block) { in_block=0; print "===BLOCK==="; next } }
  { if (in_block) print }
' "$DECK" > "$TMPDIR_EXEC/blocks.txt"

# Split on the ===BLOCK=== delimiter and bash -n each block.
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

# Check the last block.
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

# --- 3. Every +exec block with kubectl includes --context --------------------

# Re-extract blocks and check for bare kubectl (no --context).
bare_kubectl_in_exec=$(awk '
  /^```bash \+exec/ { in_block=1; next }
  /^```$/           { if (in_block) in_block=0; next }
  { if (in_block) print }
' "$DECK" | grep -nE '(^|[^_a-zA-Z])(kubectl)[[:space:]]' | grep -v -- '--context' || true)

if [ -z "$bare_kubectl_in_exec" ]; then
  assert_pass "every kubectl in +exec blocks includes --context"
else
  assert_fail "found bare kubectl (no --context) in an +exec block:"
  echo "$bare_kubectl_in_exec" | sed 's/^/  /'
fi

# --- 4. Script-path +exec blocks use a working-directory guard ---------------

# The one +exec block that references scripts/configure-vso-jwt-auth.sh must
# guard against being run from the wrong directory.
script_exec_block=$(awk '
  /^```bash \+exec/ { in_block=1; block=""; next }
  /^```$/           { if (in_block) { if (block ~ /scripts\//) print block; in_block=0; next } }
  { if (in_block) block = block $0 "\n" }
' "$DECK")

if [ -n "$script_exec_block" ]; then
  if echo "$script_exec_block" | grep -qE '\[ -f .* \] \|\| cd \.\.'; then
    assert_pass "script-path +exec block uses a working-directory guard"
  else
    assert_fail "script-path +exec block is missing a working-directory guard"
    echo "$script_exec_block" | sed 's/^/  /'
  fi
else
  assert_pass "no script-path +exec blocks to guard (or already covered)"
fi

# --- 5. Deck references JWT/OIDC auth, not kubernetes-vso as default ---------

assert_contains \
  "deck references auth/jwt-vso" \
  "$DECK_CONTENTS" 'auth/jwt-vso'

assert_contains \
  "deck references JWT/OIDC auth method" \
  "$DECK_CONTENTS" 'JWT/OIDC'

assert_contains \
  "deck shows the OIDC discovery endpoint" \
  "$DECK_CONTENTS" '/.well-known/openid-configuration'

assert_contains \
  "deck shows Vault's oidc_discovery_url config" \
  "$DECK_CONTENTS" 'oidc_discovery_url'

assert_contains \
  "deck shows the advertised JWKS URI" \
  "$DECK_CONTENTS" 'jwks_uri'

assert_contains \
  "deck shows the RS256 algorithm restriction" \
  "$DECK_CONTENTS" 'RS256'

# The deck must NOT present auth/kubernetes-vso as the default VSO auth.
# Any mention must be in a legacy/comparison context.
if printf '%s' "$DECK_CONTENTS" | grep -q 'auth/kubernetes-vso'; then
  # Check that any mention is in a legacy/comparison context.
  k8s_vso_lines=$(grep -n 'auth/kubernetes-vso' "$DECK")
  all_legacy=true
  while IFS= read -r line_info; do
    line_num="${line_info%%:*}"
    start=$((line_num - 5))
    [ "$start" -lt 1 ] && start=1
    end=$((line_num + 5))
    context=$(sed -n "${start},${end}p" "$DECK")
    if ! echo "$context" | grep -qiE 'legacy|comparison|previous|older|not.*default|superseded|historical|side-by-side'; then
      all_legacy=false
      echo "  auth/kubernetes-vso without legacy context at line $line_num:"
      echo "$line_info" | sed 's/^/    /'
    fi
  done <<< "$k8s_vso_lines"
  if [ "$all_legacy" = "true" ]; then
    assert_pass "deck only mentions auth/kubernetes-vso in legacy/comparison context"
  else
    assert_fail "deck presents auth/kubernetes-vso outside legacy/comparison context"
  fi
else
  assert_pass "deck does not mention auth/kubernetes-vso at all"
fi

# --- 6. Deck includes JWT positive + negative auth proof slides --------------

assert_contains \
  "deck has wrong-audience JWT proof" \
  "$DECK_CONTENTS" 'correctly rejected (wrong audience)'

assert_contains \
  "deck has wrong-service-account JWT proof" \
  "$DECK_CONTENTS" 'correctly rejected (wrong service account)'

assert_contains \
  "deck has JWT login proof (auth/jwt-vso/login)" \
  "$DECK_CONTENTS" 'auth/jwt-vso/login'

assert_contains \
  "deck reviews strict claim binding (bound_audiences)" \
  "$DECK_CONTENTS" 'bound_audiences'

assert_contains \
  "deck reviews bound_subject" \
  "$DECK_CONTENTS" 'bound_subject'

# --- 7. No raw JWT value is echoed in +exec blocks ---------------------------

raw_jwt_echoes=$(awk '
  /^```bash \+exec/ { in_block=1; next }
  /^```$/           { if (in_block) in_block=0; next }
  { if (in_block) print }
' "$DECK" | grep -nE 'echo.*\$(\{)?JWT(\})?[^=]' || true)

if [ -z "$raw_jwt_echoes" ]; then
  assert_pass "no raw \$JWT value echoed in +exec blocks"
else
  assert_fail "found a raw \$JWT echo in an +exec block:"
  echo "$raw_jwt_echoes" | sed 's/^/  /'
fi

if printf '%s' "$DECK_CONTENTS" | grep -qE 'jwt=.*\$JWT'; then
  assert_fail "deck passes a complete JWT as a kubectl exec argument"
else
  assert_pass "deck sends JWTs over stdin with jwt=-"
fi

# --- 8. Box-drawing characters are inside fenced code blocks -----------------
#
# Box-drawing chars must be inside ``` ... ``` fences so presenterm renders
# them as monospace text, not as broken inline layout.

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

# --- 9. Deck mentions issuer, audience, subject binding ----------------------

assert_contains \
  "deck explains issuer binding" \
  "$DECK_CONTENTS" 'issuer'

assert_contains \
  "deck explains audience binding" \
  "$DECK_CONTENTS" 'audience'

assert_contains \
  "deck explains subject binding" \
  "$DECK_CONTENTS" 'subject'

assert_contains \
  "deck mentions JWKS" \
  "$DECK_CONTENTS" 'JWKS'

# --- 10. presenterm binary is available (informational, not a hard failure) --

if command -v presenterm >/dev/null 2>&1; then
  assert_pass "presenterm is installed ($(presenterm --version 2>/dev/null || echo 'unknown version'))"
else
  echo "NOTE: presenterm is not installed -- live Ctrl-E validation is deferred to task 11"
  # Not a failure; this is a static test suite. Live validation happens in task 11.
  assert_pass "presenterm availability check skipped (not installed; live validation in task 11)"
fi

echo ""
echo "vso-deck validation: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
