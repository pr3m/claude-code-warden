#!/bin/bash
# on-stop.sh — Stop hook. The turn finished; Claude is waiting on you. Stops
# the spinner + escalation, paints the done glyph, and refreshes the context
# meter from the final transcript state.

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

warden_kill_pidfile "$(warden_spinner_pid "$ID")"
warden_kill_pidfile "$(warden_escalate_pid "$ID")"

TRANSCRIPT="$(warden_payload_get '.transcript_path')"
CTX="$(bash "$BIN_DIR/warden-context.sh" "$TRANSCRIPT" 2>/dev/null)"

warden_render_write "$ID" "done" "$PROJECT" "" "$CTX"
warden_write_title "$TTY" "$(warden_compose_title done "$PROJECT" "" "$CTX")"
warden_write_progress "$TTY" 0 0
warden_bus_write "$ID" "done" "$PROJECT" "" "$TTY" "$CWD" "" "" "$CTX" ""
warden_dispatch_state "$ID"

exit 0
