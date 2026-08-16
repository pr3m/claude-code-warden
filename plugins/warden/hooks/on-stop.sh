#!/bin/bash
# on-stop.sh — Stop hook. The turn finished, but that does not always mean the
# session is done: subagents and background shells outlive a turn, and a session
# waiting on those will wake itself up. Painting ✅ there is a lie that costs you
# a context switch — you go and look, and there is nothing to do.
#
# So the turn ends in one of two states:
#   waiting  background work still in flight → the moon animation keeps moving
#   done     nothing left → ✅, and the next move is yours

set -u
BIN_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
# shellcheck source=../bin/helpers.sh
. "$BIN_DIR/helpers.sh"
WARDEN_PAYLOAD="$(cat 2>/dev/null)"

ID="$(warden_payload_get '.session_id')"
ID="$(printf '%s' "$ID" | tr -c 'A-Za-z0-9._-' '_')"
TTY="$(warden_tty)"
[ -z "$ID" ] && ID="tty$(printf '%s' "$TTY" | tr -c 'A-Za-z0-9' '_')"
[ -z "$TTY" ] && TTY="$(warden_bus_read "$ID" tty)"
CWD="$(warden_payload_get '.cwd')"; [ -z "$CWD" ] && CWD="$PWD"
warden_claim_tty "$TTY" "$ID"   # own this device before painting (recycled-tty guard)

RENDER="$(warden_render_file "$ID")"
PROJECT=""
if [ -f "$RENDER" ]; then IFS='|' read -r _s PROJECT _a _c _ < "$RENDER"; fi
[ -z "$PROJECT" ] && PROJECT="$(warden_label_for "$TTY" "$CWD")"

warden_kill_pidfile "$(warden_escalate_pid "$ID")"

# The turn is over: nothing is in flight, and the heartbeat must not go stale
# and make a finished session look stalled to the cockpit.
warden_inflight_end "$ID"
warden_beat "$ID"

# A turn nobody typed a prompt for is a wake-up — the session resumed because
# something it launched reported back. That is our only evidence a background
# shell finished, since Claude Code has no completion hook for one.
warden_human_turn_taken "$ID" || warden_bg_shell_dec "$ID"

TRANSCRIPT="$(warden_payload_get '.transcript_path')"
CTX="$(bash "$BIN_DIR/warden-context.sh" "$TRANSCRIPT" 2>/dev/null)"
# Keep what this tab was working on. Blanking it left the cockpit's most useful
# column empty on exactly the rows you scan — and a waiting row with no label
# tells you nothing about which job is still out.
PROMPT="$(warden_bus_read "$ID" prompt)"

if [ "$(warden_bg_pending "$ID")" -gt 0 ] 2>/dev/null; then
  BGACT="$(warden_bg_activity "$ID")"
  warden_render_write "$ID" "waiting" "$PROJECT" "$BGACT" "$CTX" ""
  warden_write_title "$TTY" "$(warden_compose_title waiting "$PROJECT" "$BGACT" "$CTX")"
  warden_bus_write "$ID" "waiting" "$PROJECT" "$BGACT" "$TTY" "$CWD" "" "$PROMPT" "$CTX" "" "" "$TRANSCRIPT"
  warden_dispatch_state "$ID"
  # Keep the animator alive: the moon is the whole point of this state.
  warden_spinner_ensure "$ID" "$TTY" "$BIN_DIR" || true
  exit 0
fi

warden_render_write "$ID" "done" "$PROJECT" "" "$CTX" ""
warden_write_title "$TTY" "$(warden_compose_title done "$PROJECT" "" "$CTX")"
warden_write_progress "$TTY" 0 0
warden_bus_write "$ID" "done" "$PROJECT" "" "$TTY" "$CWD" "" "$PROMPT" "$CTX" "" "" "$TRANSCRIPT"
warden_dispatch_state "$ID"
# The daemon stays alive in keeper mode: Claude Code repaints the tab title on
# its own schedule, and a ✅ painted once here would be gone by the time you
# looked at the tab.
warden_spinner_ensure "$ID" "$TTY" "$BIN_DIR" || true

exit 0
