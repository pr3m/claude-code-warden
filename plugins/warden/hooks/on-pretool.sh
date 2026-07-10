#!/bin/bash
# on-pretool.sh — PreToolUse hook (all tools). Beats the progress heartbeat,
# marks a tool as in-flight, refreshes the activity glyph, and guarantees the
# WORKING state. Crucially, this also handles "resume after a permission
# prompt": a Notification flips the tab to ❓, then the next tool call lands
# here and flips it back to working + restarts the spinner.

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
warden_claim_tty "$TTY" "$ID"   # own this device before painting (recycled-tty guard)

TOOL="$(warden_payload_get '.tool_name')"
CMD="$(warden_payload_get '.tool_input.command')"
ACT="$(warden_activity_glyph "$TOOL")"
if [ "$TOOL" = "Bash" ]; then
  case "$(warden_cmd_kind "$CMD")" in
    test) ACT="🧪" ;;
    lint) ACT="🧹" ;;
  esac
fi

# A tool is starting: that is progress, and it is now in flight. Both must be
# recorded before we paint, so the daemon's next tick sees the truth.
warden_beat "$ID"
warden_inflight_begin "$ID"

RENDER="$(warden_render_file "$ID")"
CURSTATE=""; PROJECT=""; CTX=""
if [ -f "$RENDER" ]; then IFS='|' read -r CURSTATE PROJECT _a CTX _ < "$RENDER"; fi
[ -z "$PROJECT" ] && PROJECT="$(warden_label_for "$TTY" "$(warden_payload_get '.cwd')")"

if [ "$CURSTATE" != "working" ]; then
  # (Re)enter working — resume after a permission Notification killed the spinner.
  warden_kill_pidfile "$(warden_escalate_pid "$ID")"
  # Preserve the turn's original start time: stamping `now` here would make the
  # cockpit's elapsed column restart at every permission prompt.
  STARTED="$(warden_bus_read "$ID" started)"
  [ -z "$STARTED" ] && STARTED="$(warden_now)"
  CWD="$(warden_payload_get '.cwd')"
  TRANSCRIPT="$(warden_payload_get '.transcript_path')"
  PROMPT="$(warden_bus_read "$ID" prompt)"

  warden_render_write "$ID" "working" "$PROJECT" "$ACT" "$CTX" ""
  # Keep the public JSON bus consistent with the render on resume — otherwise
  # the cockpit / external readers stay stuck on the prior needs_you state.
  warden_bus_write "$ID" "working" "$PROJECT" "$ACT" "$TTY" "$CWD" \
    "$STARTED" "$PROMPT" "$CTX" "" "" "$TRANSCRIPT"
  warden_dispatch_state "$ID"
  warden_write_title "$TTY" "$(warden_compose_title working "$PROJECT" "$ACT" "$CTX")"
  # The Notification lit a red OSC 9;4 bar. The spinner resets it to a pulse on
  # start; if the spinner is off, nothing would — clear it here.
  warden_spinner_ensure "$ID" "$TTY" "$BIN_DIR" || warden_write_progress "$TTY" 0 0
else
  # Already working — refresh the activity glyph and clear any attention marker
  # (a tool call IS progress). The spinner picks both up on its next tick.
  warden_render_write "$ID" "working" "$PROJECT" "$ACT" "$CTX" ""
  # Self-heal: revive an animator that died mid-turn (crash, OOM, or the
  # lifetime backstop tripping on a genuinely long turn). No-ops when alive.
  if ! warden_spinner_ensure "$ID" "$TTY" "$BIN_DIR"; then
    warden_write_title "$TTY" "$(warden_compose_title working "$PROJECT" "$ACT" "$CTX")"
  fi
fi

exit 0
