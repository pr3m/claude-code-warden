#!/bin/bash
# on-prompt.sh — UserPromptSubmit hook. Enters the WORKING state: seeds the
# bus, writes an instant working title, and launches the spinner daemon.

set -u
BIN_DIR="$(cd "$(dirname "$0")/../bin" && pwd)"
# shellcheck source=../bin/helpers.sh
. "$BIN_DIR/helpers.sh"
# NOTE: do not `export` the payload — a huge prompt/tool_input would bloat the
# environment and could trip ARG_MAX (E2BIG) for child jq/ps/git calls.
WARDEN_PAYLOAD="$(cat 2>/dev/null)"

ID="$(warden_payload_get '.session_id')"
ID="$(printf '%s' "$ID" | tr -c 'A-Za-z0-9._-' '_')"   # filename-safe: no path traversal
TTY="$(warden_tty)"
[ -z "$ID" ] && ID="tty$(printf '%s' "$TTY" | tr -c 'A-Za-z0-9' '_')"
[ -z "$TTY" ] && TTY="$(warden_bus_read "$ID" tty)"
CWD="$(warden_payload_get '.cwd')"; [ -z "$CWD" ] && CWD="$PWD"
warden_claim_tty "$TTY" "$ID"   # own this device before painting (recycled-tty guard)
PROJECT="$(warden_label_for "$TTY" "$CWD")"
TRANSCRIPT="$(warden_payload_get '.transcript_path')"
PROMPT="$(warden_strip_controls "$(warden_payload_get '.prompt' | tr '\n' ' ' | cut -c1-48)")"
STARTED="$(warden_now)"

CTX="$(bash "$BIN_DIR/warden-context.sh" "$TRANSCRIPT" 2>/dev/null)"

# A fresh turn supersedes any pending needs-you escalation.
warden_kill_pidfile "$(warden_escalate_pid "$ID")"

warden_render_write "$ID" "working" "$PROJECT" "🧠" "$CTX"
warden_bus_write "$ID" "working" "$PROJECT" "🧠" "$TTY" "$CWD" "$STARTED" "$PROMPT" "$CTX" ""
warden_dispatch_state "$ID"

# Instant feedback before the spinner's first frame.
warden_write_title "$TTY" "$(warden_compose_title working "$PROJECT" "🧠" "$CTX")"

if [ "$(warden_cfg '.spinner' 'true')" = 'true' ] && ! warden_pid_alive "$(warden_spinner_pid "$ID")"; then
  ( nohup bash "$BIN_DIR/spinner-daemon.sh" "$ID" "$TTY" >/dev/null 2>&1 & ) 2>/dev/null || true
fi

exit 0
