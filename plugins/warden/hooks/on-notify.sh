#!/bin/bash
# on-notify.sh — Notification hook. Claude needs you (permission or input).
#
# Classify BEFORE touching anything. Claude Code sends one hook for several very
# different situations, and only some of them mean a human is blocking:
#
#   permission_prompt / elicitation_*  a modal dialog is on screen. Real.
#   idle_prompt                        "this session has been quiet." Emitted for
#                                      ANY quiet session, including one parked on
#                                      its own background work. Not evidence.
#   anything else / missing field      uncertainty, which is not an ask either.
#
# A generic event therefore returns without writing a single byte. It used to
# flip the tab to ❓, clear the in-flight marker and reset the escalation timer
# first, which meant an idle nudge could manufacture an attention state nobody
# asked for — and, worse, displace a real permission prompt that was already
# waiting.

set -u
BIN_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
# shellcheck source=../bin/helpers.sh
. "$BIN_DIR/helpers.sh"
WARDEN_PAYLOAD="$(cat 2>/dev/null)"

# Why Claude Code is notifying. Read with jq, then without it: an install with
# no jq must still be able to tell a dialog from an idle nudge, or every event
# would look like the uncertain case and warden would go blind.
NKIND="$(warden_payload_get '.notification_type')"
if [ -z "$NKIND" ]; then
  NKIND="$(printf '%s' "$WARDEN_PAYLOAD" \
    | sed -n 's/.*"notification_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
fi
NKIND="$(warden_strip_controls "$NKIND")"

# ---------------------------------------------------------------------------
# The gate. Everything below this line only ever runs for a real dialog.
# ---------------------------------------------------------------------------
case "$NKIND" in
  permission_prompt|elicitation_dialog|elicitation_url_dialog) ;;
  *) exit 0 ;;
esac

ID="$(warden_payload_get '.session_id')"
ID="$(printf '%s' "$ID" | tr -c 'A-Za-z0-9._-' '_')"
TTY="$(warden_tty)"
[ -z "$ID" ] && ID="tty$(printf '%s' "$TTY" | tr -c 'A-Za-z0-9' '_')"
[ -z "$TTY" ] && TTY="$(warden_bus_read "$ID" tty)"
CWD="$(warden_payload_get '.cwd')"; [ -z "$CWD" ] && CWD="$PWD"
warden_claim_tty "$TTY" "$ID"   # own this device before painting (recycled-tty guard)

RENDER="$(warden_render_file "$ID")"
CURSTATE=""; PROJECT=""; CTX=""
if [ -f "$RENDER" ]; then IFS='|' read -r CURSTATE PROJECT _a CTX _ < "$RENDER" 2>/dev/null; fi
[ -z "$PROJECT" ] && PROJECT="$(warden_label_for "$TTY" "$CWD")"

# NOTE: no "already done, leave it alone" guard here any more. That guard existed
# to stop a trailing idle notification from un-finishing a completed turn — and
# the classification above now does that job properly. Applying it to a dialog
# was the bug: asking for permission right after a turn reports done is ordinary,
# and warden used to swallow it.

# The animator is not killed: it reads the render file and drops to its slow
# keeper tick for a static state, which is what stops Claude Code's own title
# from overwriting the ❓ a second later.
# Replace any prior escalation timer, so repeated Notifications (permission
# cascades) don't stack multiple alarm daemons (duplicate sounds + orphans).
warden_kill_pidfile "$(warden_escalate_pid "$ID")"
NOW="$(warden_now)"

# Blocking on the user means no tool is executing — a permission prompt fires
# before the tool runs. Leaving the marker set would suppress stall detection
# for the whole time the session sits waiting.
warden_inflight_end "$ID"

STARTED="$(warden_bus_read "$ID" started)"
PROMPT="$(warden_bus_read "$ID" prompt)"
TRANSCRIPT="$(warden_bus_read "$ID" transcript)"

warden_render_write "$ID" "needs_you" "$PROJECT" "" "$CTX" ""
warden_write_title "$TTY" "$(warden_compose_title needs_you "$PROJECT" "" "$CTX")"
warden_write_progress "$TTY" 2 100   # red/attention bar on terminals that support OSC 9;4
warden_bus_write "$ID" "needs_you" "$PROJECT" "" "$TTY" "$CWD" \
  "$STARTED" "$PROMPT" "$CTX" "$NOW" "" "$TRANSCRIPT"
# Publish which dialog it was, so the cockpit and any external reader don't have
# to re-derive it.
warden_bus_patch "$ID" notify_kind "$NKIND"
warden_dispatch_state "$ID"
# Keep the ❓ on the tab: without a repainting daemon, Claude Code's own title
# takes the tab back and the blocked session looks like every other one.
warden_spinner_ensure "$ID" "$TTY" "$BIN_DIR" || true

ESC="$(warden_cfg '.escalateAfterSeconds' '45')"
if [ "$ESC" -gt 0 ] 2>/dev/null && ! warden_pid_alive "$(warden_escalate_pid "$ID")"; then
  ( nohup bash "$BIN_DIR/escalate-daemon.sh" "$ID" "$TTY" >/dev/null 2>&1 & ) 2>/dev/null || true
fi

exit 0
