#!/usr/bin/env bash
# scripts/validate-deck-visual.sh
#
# Repository-owned, reusable Presenterm visual validator. This is the ONLY
# entry point for slide-by-slide visual/text validation of any deck in
# presenterm/ (currently presenterm/vso.md and presenterm/auth-delegator.md).
# It never sends Ctrl+E, so it never executes a deck's `+exec` blocks and
# never mutates a live cluster -- it only walks slides forward and captures
# each one, proving the deck loads, every slide renders, and no execution
# error banner is already present at load time.
#
# Why this script exists instead of an ad-hoc `tmux new-session` one-off:
#   - Bash tool sessions have no PTY, so presenterm cannot start there (its
#     terminal-graphics probe fails with "Device not configured"). tmux
#     always provides a real PTY server-side, so it works even with no
#     attached GUI terminal -- this is the default, headless-safe path.
#   - For full Kitty-graphics-protocol fidelity (inline images, exact pixel
#     rendering), --use-kitty wraps the same private-socket tmux session in
#     a detached Kitty OS window. Both paths use the SAME footer-tracking
#     capture loop and the SAME scoped cleanup.
#   - Cleanup is scoped to this run's private tmux socket/session name and
#     this run's exact deck path. It NEVER runs a broad
#     `pkill -f presenterm` or `pkill kitty` -- doing so would kill any
#     OTHER presenterm/Kitty session the user has open. See
#     local_skills/presenterm-demo-decks/references/visual-validation-and-process-cleanup.md.
#
# Usage:
#   scripts/validate-deck-visual.sh <deck.md>
#   scripts/validate-deck-visual.sh <deck.md> --use-kitty
#   scripts/validate-deck-visual.sh <deck.md> --use-kitty --screenshot-dir output/screens
#
# Env overrides:
#   PTERM_VALIDATE_COLS         tmux pane width  (default: current terminal's tput cols, else 120)
#   PTERM_VALIDATE_LINES        tmux pane height (default: current terminal's tput lines, else 40)
#   PTERM_VALIDATE_MAX_STEPS    max Right-key steps before giving up (default: 60)
#   PTERM_VALIDATE_STEP_SLEEP   seconds to sleep between steps (default: 0.4)
#   PTERM_VALIDATE_OUTPUT       capture file path (default: output/presenterm-visual-capture.txt)
#
# Exit status is non-zero if: presenterm/tmux/kitty are missing, the deck
# file does not exist, presenterm fails to start, a slide shows
# `[finished error]`/`[failed]`, or any validation process is still running
# after cleanup.
#
# This script never creates, deletes, or mutates a Kubernetes cluster, and
# it never presses Ctrl+E -- functional (`+exec` block) validation and the
# live Ctrl+E rehearsal are separate, explicitly user-approved steps (see
# local_skills/presenterm-demo-decks/SKILL.md, Steps 5 and 5b).

set -euo pipefail

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}"
}

if [ "$#" -lt 1 ]; then
  echo "ERROR: missing required <deck.md> argument." >&2
  usage >&2
  exit 1
fi

DECK="$1"
shift

USE_KITTY=0
SCREENSHOT_DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --use-kitty)
      USE_KITTY=1
      shift
      ;;
    --screenshot-dir)
      [ "$#" -ge 2 ] || { echo "ERROR: --screenshot-dir requires a path argument." >&2; exit 1; }
      SCREENSHOT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1' (supported: --use-kitty, --screenshot-dir <dir>)" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$DECK" ]; then
  echo "ERROR: deck file not found: ${DECK}" >&2
  exit 1
fi

command -v tmux >/dev/null 2>&1 || { echo "ERROR: tmux not installed (required -- no Bash-tool workaround exists; see SKILL.md Step 6)." >&2; exit 1; }
command -v presenterm >/dev/null 2>&1 || { echo "ERROR: presenterm not installed (brew install presenterm)." >&2; exit 1; }
if [ "$USE_KITTY" -eq 1 ]; then
  command -v kitty >/dev/null 2>&1 || { echo "ERROR: kitty not installed (required for --use-kitty)." >&2; exit 1; }
fi

DECK_ABS="$(cd "$(dirname "$DECK")" && pwd)/$(basename "$DECK")"

SOCKET="pterm-validate-$$"
SESSION="pterm_validate_$$"

COLS="${PTERM_VALIDATE_COLS:-}"
LINES="${PTERM_VALIDATE_LINES:-}"
if [ -z "$COLS" ]; then COLS="$(tput cols 2>/dev/null || echo 120)"; fi
if [ -z "$LINES" ]; then LINES="$(tput lines 2>/dev/null || echo 40)"; fi

MAX_STEPS="${PTERM_VALIDATE_MAX_STEPS:-60}"
STEP_SLEEP="${PTERM_VALIDATE_STEP_SLEEP:-0.4}"
OUT="${PTERM_VALIDATE_OUTPUT:-output/presenterm-visual-capture.txt}"
mkdir -p "$(dirname "$OUT")"
[ -z "$SCREENSHOT_DIR" ] || mkdir -p "$SCREENSHOT_DIR"

LAUNCHED_KITTY=0
CLEANED_UP=0

# cleanup
#
# Scoped teardown: only this run's private tmux socket/session and any
# Kitty process whose command line contains this run's private socket name
# are terminated. Never a broad `pkill presenterm` / `pkill kitty` -- those
# would kill unrelated user sessions.
cleanup() {
  [ "$CLEANED_UP" -eq 1 ] && return 0
  CLEANED_UP=1
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  pkill -f "presenterm -x ${DECK_ABS}" >/dev/null 2>&1 || true
  if [ "$LAUNCHED_KITTY" -eq 1 ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill "$pid" >/dev/null 2>&1 || true
    done < <(ps -axo pid=,args= 2>/dev/null | awk -v sock="$SOCKET" '/kitty/ && index($0, sock) {print $1}')
  fi
}
trap cleanup EXIT INT TERM

IN_KITTY=0
if [ "${TERM:-}" = "xterm-kitty" ] || [ -n "${KITTY_PID:-}" ]; then
  IN_KITTY=1
fi

echo "==> Validating deck: ${DECK_ABS}"
echo "    socket=${SOCKET} session=${SESSION} viewport=${COLS}x${LINES} use_kitty=${USE_KITTY}"

if [ "$USE_KITTY" -eq 1 ] && [ "$IN_KITTY" -eq 0 ]; then
  LAUNCHED_KITTY=1
  # Launch presenterm directly as the tmux session command (not via
  # send-keys into an already-interactive shell -- see SKILL.md Step 5b on
  # why send-keys launch corrupts the command line).
  kitty --detach sh -lc "tmux -L '${SOCKET}' new-session -s '${SESSION}' -x ${COLS} -y ${LINES} \"presenterm -x '${DECK_ABS}'\"" 2>/dev/null &
  KITTY_LAUNCH_PID=$!
  disown "$KITTY_LAUNCH_PID" 2>/dev/null || true
  sleep 4
else
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x "$COLS" -y "$LINES" "presenterm -x '${DECK_ABS}'"
  sleep 2
fi

if ! tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
  echo "ERROR: presenterm failed to start (tmux session '${SESSION}' on private socket '${SOCKET}' not found)." >&2
  exit 1
fi

: > "$OUT"
SEEN_SLIDES=""
FAILED=0
SLIDE_COUNT=0

for step in $(seq 1 "$MAX_STEPS"); do
  if ! tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    echo "ERROR: presenterm/tmux session ended unexpectedly at step ${step}." >&2
    FAILED=1
    break
  fi

  CAP="$(tmux -L "$SOCKET" capture-pane -t "$SESSION" -p 2>/dev/null | cat -s)"
  FOOTER="$(printf '%s\n' "$CAP" | grep -Eo '[0-9]+ */ *[0-9]+' | tail -1 || true)"
  SLIDE_KEY="${FOOTER:-cover/no-footer}"

  case " ${SEEN_SLIDES} " in
    *" ${SLIDE_KEY} "*) ;;
    *)
      SEEN_SLIDES="${SEEN_SLIDES} ${SLIDE_KEY}"
      SLIDE_COUNT=$((SLIDE_COUNT + 1))
      {
        echo "=== SLIDE ${SLIDE_KEY} (step ${step}) ==="
        printf '%s\n\n' "$CAP"
      } >> "$OUT"
      if [ -n "$SCREENSHOT_DIR" ] && [ "$USE_KITTY" -eq 1 ] && [ "$(uname -s)" = "Darwin" ] && command -v screencapture >/dev/null 2>&1; then
        SAFE_KEY="$(printf '%s' "$SLIDE_KEY" | tr -c 'A-Za-z0-9._-' '_')"
        screencapture -x "${SCREENSHOT_DIR}/slide-${SAFE_KEY}.png" 2>/dev/null || true
      fi
      ;;
  esac

  if printf '%s\n' "$CAP" | grep -q '\[finished error\]\|\[failed\]'; then
    {
      echo "DETECTED presenterm execution-failure banner at slide ${SLIDE_KEY} (step ${step})."
    } >> "$OUT"
    echo "FAILED: presenterm shows an execution-failure banner at slide ${SLIDE_KEY}. See ${OUT}." >&2
    FAILED=1
    break
  fi

  if [ -n "$FOOTER" ]; then
    CURRENT="$(printf '%s' "$FOOTER" | awk -F'/' '{gsub(/ /,"",$1); print $1}')"
    TOTAL="$(printf '%s' "$FOOTER" | awk -F'/' '{gsub(/ /,"",$2); print $2}')"
    if [ -n "$CURRENT" ] && [ "$CURRENT" = "$TOTAL" ]; then
      break
    fi
  fi

  tmux -L "$SOCKET" send-keys -t "$SESSION" Right
  sleep "$STEP_SLEEP"
done

cleanup
trap - EXIT INT TERM

LEFTOVERS="$(ps -axo pid=,ppid=,comm=,args= 2>/dev/null | grep -E -- "${SOCKET}|${SESSION}" | grep -v grep || true)"
LEFTOVER_DECK="$(ps -axo pid=,ppid=,comm=,args= 2>/dev/null | grep -F -- "presenterm -x ${DECK_ABS}" | grep -v grep || true)"
if [ -n "$LEFTOVERS" ] || [ -n "$LEFTOVER_DECK" ]; then
  echo "ERROR: validation leftovers remain after cleanup:" >&2
  [ -z "$LEFTOVERS" ] || echo "$LEFTOVERS" >&2
  [ -z "$LEFTOVER_DECK" ] || echo "$LEFTOVER_DECK" >&2
  exit 1
fi
echo "OK: no validation tmux/kitty/presenterm processes remain (socket '${SOCKET}', session '${SESSION}')."

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: see ${OUT} for the captured slides leading up to the failure." >&2
  exit 1
fi

echo "OK: captured ${SLIDE_COUNT} distinct slide state(s) to ${OUT}."
echo "    Inspect ${OUT} for raw-comment leaks, missing content, and footer progression."
echo "    For diagram/column/image slides, re-run with --use-kitty and inspect a real screenshot"
echo "    (or pass --screenshot-dir on macOS for a best-effort automatic capture) -- text"
echo "    capture alone cannot prove pixel-level layout (see GUARD-3b)."
