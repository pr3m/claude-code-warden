#!/bin/bash
# on-pretool.sh — PreToolUse hook (all tools). Refreshes the activity glyph and
# guarantees the WORKING state. Crucially, this also handles "resume after a
# permission prompt": a Notification flips the tab to ❓, then the next tool
# call lands here and flips it back to working + restarts the spinner.

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

TOOL="$(warden_payload_get '.tool_name')"
CMD="$(warden_payload_get '.tool_input.command')"
ACT="$(warden_activity_glyph "$TOOL")"
if [ "$TOOL" = "Bash" ] && warden_is_test_command "$CMD"; then ACT="🧪"; fi

RENDER="$(warden_render_file "$ID")"
CURSTATE=""; PROJECT=""; CTX=""
if [ -f "$RENDER" ]; then IFS='|' read -r CURSTATE PROJECT _a CTX _ < "$RENDER"; fi
[ -z "$PROJECT" ] && PROJECT="$(warden_label_for "$TTY" "$(warden_payload_get '.cwd')")"

SPINNER_ON="$(warden_cfg '.spinner' 'true')"

if [ "$CURSTATE" != "working" ]; then
  # (Re)enter working — resume after a permission Notification killed the spinner.
  # Deliberately NOT triggered on the normal first tool of a turn: on-prompt has
  # already launched the spinner, and relaunching here would race its startup and
  # spawn a SECOND animator writing offset frames (the "random flashing" bug).
  warden_kill_pidfile "$(warden_escalate_pid "$ID")"
  warden_render_write "$ID" "working" "$PROJECT" "$ACT" "$CTX"
  # Keep the public JSON bus consistent with the render on resume — otherwise
  # the cockpit / external readers stay stuck on the prior needs_you state.
  warden_bus_write "$ID" "working" "$PROJECT" "$ACT" "$TTY" "$(warden_payload_get '.cwd')" "$(warden_now)" "" "$CTX" ""
  warden_dispatch_state "$ID"
  warden_write_title "$TTY" "$(warden_compose_title working "$PROJECT" "$ACT" "$CTX")"
  if [ "$SPINNER_ON" = 'true' ] && ! warden_pid_alive "$(warden_spinner_pid "$ID")"; then
    ( nohup bash "$BIN_DIR/spinner-daemon.sh" "$ID" "$TTY" >/dev/null 2>&1 & ) 2>/dev/null || true
  fi
else
  # Already working — just refresh the activity glyph; the spinner picks it up.
  warden_render_write "$ID" "working" "$PROJECT" "$ACT" "$CTX"
  [ "$SPINNER_ON" = 'true' ] || warden_write_title "$TTY" "$(warden_compose_title working "$PROJECT" "$ACT" "$CTX")"
fi

exit 0
