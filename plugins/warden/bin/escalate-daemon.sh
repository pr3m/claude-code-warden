#!/bin/bash
# escalate-daemon.sh — needs-you escalation timer. Launched by the Notification
# hook. After escalateAfterSeconds, if the session is STILL waiting on the user,
# it swaps the tab glyph to the escalated marker and (optionally) re-pings, then
# keeps nagging at the same interval until the user responds (which flips the
# render state away from needs_you and ends this loop).
#
# Usage: escalate-daemon.sh <session_id> <tty_device>

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$DIR/helpers.sh"

ID="${1:?session id required}"
TTY="${2:?tty device required}"
PIDFILE="$(warden_escalate_pid "$ID")"
RENDER="$(warden_render_file "$ID")"

warden_ensure_dirs
printf '%s\n' "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE" 2>/dev/null || true' EXIT
trap 'exit 0' TERM INT HUP

DELAY="$(warden_cfg '.escalateAfterSeconds' '45')"
REPING="$(warden_cfg '.escalateReping' 'true')"

# Populated by still_waiting() from a single render read (avoids a second,
# racy read in the loop and an unbound-variable abort under set -u).
PROJECT=""; CTX=""
still_waiting() {
  [ -f "$RENDER" ] || return 1
  IFS='|' read -r _state PROJECT _a CTX _ < "$RENDER" 2>/dev/null || return 1
  [ "$_state" = "needs_you" ]
}

ping() {
  [ "$REPING" = 'true' ] || return 0
  [ "$(warden_platform)" = 'darwin' ] || return 0
  afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &
}

while :; do
  sleep "$DELAY"
  still_waiting || break
  warden_write_title "$TTY" "$(warden_compose_title escalated "$PROJECT" "" "$CTX")"
  ping
done

exit 0
