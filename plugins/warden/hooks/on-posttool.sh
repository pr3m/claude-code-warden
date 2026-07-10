#!/bin/bash
# on-posttool.sh — PostToolUse hook (all tools). The counterpart to on-pretool:
# the tool finished, so clear the in-flight marker and beat the heartbeat.
#
# Without this hook warden cannot distinguish "a 20-minute test suite is running"
# from "the agent stopped doing anything 20 minutes ago" — both look identical
# from the outside. It also lets the activity glyph stop claiming 📖 while Claude
# is thinking about what it just read.
#
# Kept deliberately cheap: this runs after every single tool call.

set -u
BIN_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
# shellcheck source=../bin/helpers.sh
. "$BIN_DIR/helpers.sh"
WARDEN_PAYLOAD="$(cat 2>/dev/null)"

ID="$(warden_payload_get '.session_id')"
ID="$(printf '%s' "$ID" | tr -c 'A-Za-z0-9._-' '_')"
# warden_tty walks the process tree with up to 14 `ps` calls. This hook runs
# after EVERY tool call, so resolve the device only on the paths that need it.
TTY=""
if [ -z "$ID" ]; then
  TTY="$(warden_tty)"
  ID="tty$(printf '%s' "$TTY" | tr -c 'A-Za-z0-9' '_')"
fi

# The tool is done: no longer in flight, and finishing counts as progress.
warden_inflight_end "$ID"
warden_beat "$ID"

RENDER="$(warden_render_file "$ID")"
[ -f "$RENDER" ] || exit 0
IFS='|' read -r CURSTATE PROJECT _a CTX _ < "$RENDER"
# Only decorate a live turn. A trailing PostToolUse after Stop must not resurrect
# the working title over the ✅.
[ "$CURSTATE" = "working" ] || exit 0

# Back to thinking: no tool is running, so no tool glyph should be shown.
warden_render_write "$ID" "working" "$PROJECT" "🧠" "$CTX" ""

# The spinner repaints from the render file on its next tick. With the spinner
# disabled nothing else would, so paint the static title ourselves.
if [ "$(warden_cfg '.spinner' 'true')" != 'true' ]; then
  [ -z "$TTY" ] && TTY="$(warden_tty)"
  [ -z "$TTY" ] && TTY="$(warden_bus_read "$ID" tty)"
  warden_owns_tty "$TTY" "$ID" \
    && warden_write_title "$TTY" "$(warden_compose_title working "$PROJECT" "🧠" "$CTX")"
fi

exit 0
