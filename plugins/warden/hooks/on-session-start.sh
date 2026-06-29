#!/bin/bash
# on-session-start.sh — SessionStart hook.
# Ensures config + data dirs exist, registers a stable CLI entry point so the
# skills can call warden regardless of install path, seeds the session bus to
# idle, and reaps any stale daemons for this session id. Stays silent (no
# stdout) so it never injects noise into the session.

set -u
BIN_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../bin/helpers.sh
. "$BIN_DIR/helpers.sh"

WARDEN_PAYLOAD="$(cat 2>/dev/null)"

warden_ensure_config
warden_ensure_dirs

# Stable entry point for skills: ~/.claude/warden/bin/warden -> warden-cli.sh
mkdir -p "$(warden_data_dir)/bin"
printf '%s\n' "$PLUGIN_ROOT" > "$(warden_data_dir)/plugin-root"
ln -sfn "$BIN_DIR/warden-cli.sh" "$(warden_data_dir)/bin/warden"

# SessionStart fires for startup / resume / clear AND compact. On compact the
# SAME session keeps working mid-turn — reaping its spinner and reseeding to
# idle here would blank the tab during a long turn. Do the (idempotent) setup
# above, then bail without touching live state.
SOURCE="$(warden_payload_get '.source')"
[ "$SOURCE" = "compact" ] && exit 0

ID="$(warden_payload_get '.session_id')"
ID="$(printf '%s' "$ID" | tr -c 'A-Za-z0-9._-' '_')"
TTY="$(warden_tty)"
[ -z "$ID" ] && ID="tty$(printf '%s' "$TTY" | tr -c 'A-Za-z0-9' '_')"
CWD="$(warden_payload_get '.cwd')"; [ -z "$CWD" ] && CWD="$PWD"

# Claim this terminal device for this session BEFORE computing the label: if a
# prior session's number was recycled onto this tab, this reaps its orphaned
# daemons and drops its stale custom label so PROJECT reflects our own context.
warden_claim_tty "$TTY" "$ID"

PROJECT="$(warden_label_for "$TTY" "$CWD")"   # honours a custom tab label / $WARDEN_LABEL

# Reap stale daemons in case a prior session with this id crashed.
warden_kill_pidfile "$(warden_spinner_pid "$ID")"
warden_kill_pidfile "$(warden_escalate_pid "$ID")"

# Session ids are unique, so bus files would otherwise accumulate forever.
# Prune anything untouched for over a day, drop orphaned pidfiles whose process
# is dead, and remove stale singleton locks. Cheap, self-healing, once/session.
find "$(warden_sessions_dir)" -type f \( -name '*.json' -o -name '*.render' -o -name '*.owner' \) \
  -mtime +1 -delete 2>/dev/null || true
for p in "$(warden_sessions_dir)"/*.pid; do
  [ -f "$p" ] || continue
  warden_pid_alive "$p" || rm -f "$p" 2>/dev/null || true
done
for lk in "$(warden_sessions_dir)"/*.spinner.lock; do
  [ -d "$lk" ] || continue
  warden_pid_alive "${lk%.lock}.pid" || rmdir "$lk" 2>/dev/null || true
done

# Seed the bus as idle. We deliberately do NOT write a title here — Claude
# Code sets its own title at startup; warden takes over on the first prompt.
warden_render_write "$ID" "idle" "$PROJECT" "" ""
warden_bus_write "$ID" "idle" "$PROJECT" "" "$TTY" "$CWD" "" "" "" ""

exit 0
