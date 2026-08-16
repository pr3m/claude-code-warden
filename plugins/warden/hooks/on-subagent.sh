#!/bin/bash
# on-subagent.sh — SubagentStart / SubagentStop. Keeps the live set of subagents
# for this session, which is what lets Stop tell "done" from "waiting".
#
# Subagents are tracked by agent_id rather than a counter: a crashed or missed
# event can only ever leave one stale id behind, where a counter would drift
# permanently and pin the tab to the waiting moon forever.
#
# A subagent finishing while the session is already WAITING is the moment the
# tab may need to change — either the marker (🤖 drops off, 🐚 remains) or the
# whole state (nothing left → done). Mid-turn it changes nothing: the session
# is working either way.
#
# Usage: on-subagent.sh start|stop

set -u
MODE="${1:?start or stop required}"
BIN_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
# shellcheck source=../bin/helpers.sh
. "$BIN_DIR/helpers.sh"
WARDEN_PAYLOAD="$(cat 2>/dev/null)"

ID="$(warden_payload_get '.session_id')"
ID="$(printf '%s' "$ID" | tr -c 'A-Za-z0-9._-' '_')"
TTY="$(warden_tty)"
[ -z "$ID" ] && ID="tty$(printf '%s' "$TTY" | tr -c 'A-Za-z0-9' '_')"
[ -z "$TTY" ] && TTY="$(warden_bus_read "$ID" tty)"

AGENT="$(warden_payload_get '.agent_id')"
[ -z "$AGENT" ] && AGENT="$(warden_payload_get '.agent_type')"
[ -z "$AGENT" ] && AGENT="anonymous"

case "$MODE" in
  start) warden_bg_agent_add "$ID" "$AGENT"; exit 0 ;;
  stop)  warden_bg_agent_del "$ID" "$AGENT" ;;
  *)     exit 0 ;;
esac

# --- stop only: the waiting tab may now be stale --------------------------
RENDER="$(warden_render_file "$ID")"
[ -f "$RENDER" ] || exit 0
IFS='|' read -r STATE PROJECT _ACT CTX _ATT < "$RENDER" 2>/dev/null || exit 0
[ "$STATE" = "waiting" ] || exit 0

CWD="$(warden_payload_get '.cwd')"; [ -z "$CWD" ] && CWD="$PWD"
TRANSCRIPT="$(warden_bus_read "$ID" transcript)"
PROMPT="$(warden_bus_read "$ID" prompt)"

if [ "$(warden_bg_pending "$ID")" -gt 0 ] 2>/dev/null; then
  BGACT="$(warden_bg_activity "$ID")"
  warden_render_write "$ID" "waiting" "$PROJECT" "$BGACT" "$CTX" ""
  warden_bus_patch "$ID" activity "$BGACT"
  exit 0
fi

# Nothing left in flight: the session really is finished and yours again.
warden_render_write "$ID" "done" "$PROJECT" "" "$CTX" ""
warden_write_title "$TTY" "$(warden_compose_title done "$PROJECT" "" "$CTX")"
warden_write_progress "$TTY" 0 0
warden_bus_write "$ID" "done" "$PROJECT" "" "$TTY" "$CWD" "" "$PROMPT" "$CTX" "" "" "$TRANSCRIPT"
warden_dispatch_state "$ID"

exit 0
