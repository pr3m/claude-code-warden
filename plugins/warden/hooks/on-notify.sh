#!/bin/bash
# on-notify.sh — Notification hook. Claude needs you (permission or input).
# Stops the spinner, paints the needs-you glyph, and arms the escalation timer
# so a blocked session in a background tab never waits unnoticed.

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

RENDER="$(warden_render_file "$ID")"
CURSTATE=""; PROJECT=""; CTX=""
if [ -f "$RENDER" ]; then IFS='|' read -r CURSTATE PROJECT _a CTX _ < "$RENDER" 2>/dev/null; fi
[ -z "$PROJECT" ] && PROJECT="$(warden_label_for "$TTY" "$CWD")"

# A turn that already finished cleanly (✅) must not be flipped back to ❓ by a
# trailing/idle Notification — that's a false alarm. Leave it as done.
[ "$CURSTATE" = "done" ] && exit 0

warden_kill_pidfile "$(warden_spinner_pid "$ID")"
# Replace any prior escalation timer, so repeated Notifications (permission
# cascades) don't stack multiple alarm daemons (duplicate sounds + orphans).
warden_kill_pidfile "$(warden_escalate_pid "$ID")"
NOW="$(warden_now)"

warden_render_write "$ID" "needs_you" "$PROJECT" "" "$CTX"
warden_write_title "$TTY" "$(warden_compose_title needs_you "$PROJECT" "" "$CTX")"
warden_write_progress "$TTY" 2 100   # red/attention bar on terminals that support OSC 9;4
warden_bus_write "$ID" "needs_you" "$PROJECT" "" "$TTY" "$CWD" "" "" "$CTX" "$NOW"
warden_dispatch_state "$ID"

ESC="$(warden_cfg '.escalateAfterSeconds' '45')"
if [ "$ESC" -gt 0 ] 2>/dev/null && ! warden_pid_alive "$(warden_escalate_pid "$ID")"; then
  ( nohup bash "$BIN_DIR/escalate-daemon.sh" "$ID" "$TTY" >/dev/null 2>&1 & ) 2>/dev/null || true
fi

exit 0
