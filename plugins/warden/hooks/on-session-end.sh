#!/bin/bash
# on-session-end.sh — SessionEnd. The animator now outlives every turn, so
# something has to end it: removing the render file is the daemon's own exit
# condition, and the pidfiles are killed for the case where it is mid-sleep.
#
# Without this, closing a tab would leave a bash loop repainting a title to a
# terminal device that no longer belongs to anyone — and eventually to a
# recycled one that belongs to somebody else.

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

# Order matters: drop the render file first so a daemon waking mid-kill sees
# its exit condition rather than repainting one last frame.
rm -f "$(warden_render_file "$ID")" 2>/dev/null || true
warden_kill_pidfile "$(warden_spinner_pid "$ID")"
warden_kill_pidfile "$(warden_escalate_pid "$ID")"
warden_bg_clear "$ID"
warden_inflight_end "$ID"
warden_write_progress "$TTY" 0 0

exit 0
