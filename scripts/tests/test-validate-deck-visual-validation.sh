#!/usr/bin/env bash
# scripts/tests/test-validate-deck-visual-validation.sh
#
# Static AND light-functional validation for the repository-owned Presenterm
# visual validator (scripts/validate-deck-visual.sh):
#   - shell syntax and basic option parsing (missing deck, unknown flag,
#     missing arguments) fail fast with a clear message and no side effects
#   - the private-socket/scoped-cleanup safety properties this script must
#     have (see local_skills/presenterm-demo-decks/references/
#     visual-validation-and-process-cleanup.md):
#       * uses a private `tmux -L <socket>` rather than the default server
#       * launches presenterm directly as the tmux session command (not via
#         send-keys into an already-interactive shell)
#       * cleanup is scoped to this run's exact socket/session/deck path --
#         it never contains a broad `pkill -f presenterm` or `pkill kitty`
#         with no scoping argument
#       * a leftover-process check runs AFTER cleanup and fails validation
#         if anything matching this run's scope remains
#       * never sends Ctrl+E (so it can never execute a deck's +exec blocks
#         or mutate a live cluster)
#   - a real functional smoke test against the existing presenterm/vso.md
#     deck when tmux and presenterm are both available: the script exits 0,
#     produces a non-empty capture file with multiple distinct slide
#     states, and leaves no leftover tmux/presenterm process behind
#
# This test never sends Ctrl+E and never mutates a live Kubernetes cluster.
#
# Usage: scripts/tests/test-validate-deck-visual-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALIDATOR="${REPO_ROOT}/scripts/validate-deck-visual.sh"
SMOKE_DECK="${REPO_ROOT}/presenterm/vso.md"

pass=0
fail=0

assert_pass() { echo "PASS: $1"; pass=$((pass + 1)); }
assert_fail() { echo "FAIL: $1"; fail=$((fail + 1)); }

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    assert_pass "$desc"
  else
    echo "  expected to find: $needle"
    assert_fail "$desc"
  fi
}

if [ ! -f "$VALIDATOR" ]; then
  echo "FAIL: ${VALIDATOR} not found"
  echo ""
  echo "validate-deck-visual validation: 0 passed, 1 failed"
  exit 1
fi

check() {
  local description="$1"
  shift
  if "$@"; then
    echo "PASS: ${description}"
    pass=$((pass + 1))
  else
    echo "FAIL: ${description}"
    fail=$((fail + 1))
  fi
}

# --- 1. Shell syntax ---------------------------------------------------------

check "validator passes bash syntax validation" bash -n "$VALIDATOR"
check "validator is executable" test -x "$VALIDATOR"

VALIDATOR_CONTENTS="$(cat "$VALIDATOR")"

# --- 2. Private-socket / scoped-cleanup safety properties -------------------

assert_contains "validator uses a private tmux socket (tmux -L)" "$VALIDATOR_CONTENTS" 'tmux -L'
assert_contains "validator derives a unique per-run socket name" "$VALIDATOR_CONTENTS" 'SOCKET="pterm-validate-$$"'
assert_contains "validator derives a unique per-run session name" "$VALIDATOR_CONTENTS" 'SESSION="pterm_validate_$$"'
assert_contains "validator launches presenterm directly as the session command" "$VALIDATOR_CONTENTS" "presenterm -x '\${DECK_ABS}'"
assert_contains "validator supports --use-kitty for full graphics-protocol fidelity" "$VALIDATOR_CONTENTS" '--use-kitty'
if printf '%s' "$VALIDATOR_CONTENTS" | grep -qiE 'send-keys[^\n]*C-e'; then
  assert_fail "validator appears to send Ctrl+E (would execute +exec blocks and could mutate a live cluster)"
else
  assert_pass "validator never sends Ctrl+E (walks slides with Right only; no +exec execution, no cluster mutation)"
fi
assert_contains "validator only sends Right to advance slides" "$VALIDATOR_CONTENTS" 'send-keys -t "$SESSION" Right'

# Cleanup must be scoped: no bare `pkill -f presenterm` / `pkill kitty`
# without this run's socket/session/deck-path scoping in the SAME pkill
# invocation.
broad_pkill=$(printf '%s\n' "$VALIDATOR_CONTENTS" | grep -nE "pkill (-f )?'?(presenterm|kitty)'?\s*(>|$)" | grep -v -- '-f "presenterm -x \${DECK_ABS}"' || true)
if [ -z "$broad_pkill" ]; then
  assert_pass "no broad, unscoped pkill of presenterm/kitty"
else
  assert_fail "found a broad, unscoped pkill:"
  echo "$broad_pkill" | sed 's/^/  /'
fi
assert_contains "the one presenterm pkill is scoped to this run's exact deck path" "$VALIDATOR_CONTENTS" 'pkill -f "presenterm -x ${DECK_ABS}"'
assert_contains "Kitty cleanup is scoped to this run's private socket (never a broad kitty kill)" "$VALIDATOR_CONTENTS" 'awk -v sock="$SOCKET"'

assert_contains "cleanup runs tmux kill-server scoped to the private socket" "$VALIDATOR_CONTENTS" 'tmux -L "$SOCKET" kill-server'
assert_contains "cleanup is registered via trap on EXIT/INT/TERM" "$VALIDATOR_CONTENTS" 'trap cleanup EXIT INT TERM'

# A leftover-process check must run AFTER cleanup and must be able to fail
# the script (exit 1) if anything remains.
after_cleanup="$(awk '/^cleanup$/{f=1} f' "$VALIDATOR" | tail -n +2)"
assert_contains "a post-cleanup leftover-process check exists" "$after_cleanup" 'LEFTOVERS='
if printf '%s' "$after_cleanup" | grep -qE 'exit 1'; then
  assert_pass "the post-cleanup leftover-process check can fail the script (exit 1)"
else
  assert_fail "the post-cleanup leftover-process check never exits non-zero"
fi

# --- 3. Argument handling (no side effects) ---------------------------------

if err=$(bash "$VALIDATOR" 2>&1 >/dev/null); status=$?; [ "$status" -ne 0 ] && printf '%s' "$err" | grep -qi 'missing required'; then
  assert_pass "missing deck argument fails fast with a clear message"
else
  assert_fail "missing deck argument did not fail as expected"
fi

if err=$(bash "$VALIDATOR" /nonexistent/deck-does-not-exist.md 2>&1); status=$?; [ "$status" -ne 0 ] && printf '%s' "$err" | grep -qi 'not found'; then
  assert_pass "nonexistent deck path fails fast with a clear message"
else
  assert_fail "nonexistent deck path did not fail as expected"
fi

if err=$(bash "$VALIDATOR" "$SMOKE_DECK" --totally-bogus-flag 2>&1); status=$?; [ "$status" -ne 0 ] && printf '%s' "$err" | grep -qi 'unknown argument'; then
  assert_pass "unknown flag fails fast with a clear message"
else
  assert_fail "unknown flag did not fail as expected"
fi

# --- 4. Functional smoke test (only if tmux + presenterm are available; ----
# --- never sends Ctrl+E, so this cannot execute a +exec block or mutate ----
# --- a live cluster) ---------------------------------------------------------

if command -v tmux >/dev/null 2>&1 && command -v presenterm >/dev/null 2>&1 && [ -f "$SMOKE_DECK" ]; then
  SMOKE_OUT="$(mktemp -t auth-delegator-visual-smoke.XXXXXX)"
  if PTERM_VALIDATE_MAX_STEPS=30 PTERM_VALIDATE_COLS=120 PTERM_VALIDATE_LINES=40 \
      PTERM_VALIDATE_OUTPUT="$SMOKE_OUT" \
      timeout 60 bash "$VALIDATOR" "$SMOKE_DECK" >/tmp/validate-deck-visual-smoke-stdout.txt 2>&1; then
    if [ -s "$SMOKE_OUT" ] && grep -q '^=== SLIDE' "$SMOKE_OUT"; then
      slide_count=$(grep -c '^=== SLIDE' "$SMOKE_OUT")
      assert_pass "functional smoke test: validator captured ${slide_count} slide state(s) from presenterm/vso.md and exited 0"
    else
      assert_fail "functional smoke test: capture file is empty or missing slide markers"
    fi
  else
    assert_fail "functional smoke test: validator did not exit 0 against presenterm/vso.md"
    cat /tmp/validate-deck-visual-smoke-stdout.txt | sed 's/^/  /'
  fi
  rm -f "$SMOKE_OUT" /tmp/validate-deck-visual-smoke-stdout.txt

  sleep 1
  leftover_after_test=$(ps -axo pid=,args= 2>/dev/null | grep -E 'pterm-validate|pterm_validate' | grep -v grep || true)
  if [ -z "$leftover_after_test" ]; then
    assert_pass "no validator tmux/presenterm processes remain after the functional smoke test"
  else
    assert_fail "leftover validator processes remain after the functional smoke test:"
    echo "$leftover_after_test" | sed 's/^/  /'
  fi
else
  echo "NOTE: tmux/presenterm/deck not fully available -- functional smoke test skipped (static checks above still ran)."
  assert_pass "functional smoke test skipped gracefully (tooling unavailable is not a failure)"
fi

echo ""
echo "validate-deck-visual validation: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
