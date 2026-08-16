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
# The trailing `tr` turns jq's closing newline into a space, so trim it — the
# label ends up in a tab title and a cockpit column, both of which show it raw.
PROMPT="$(warden_strip_controls "$(warden_payload_get '.prompt' | tr '\n' ' ' | cut -c1-48)")"
PROMPT="${PROMPT%"${PROMPT##*[![:space:]]}"}"
STARTED="$(warden_now)"

# A background task reporting in wakes the session through this same hook. It is
# not your turn: it must not arm the human-turn marker, and it must not overwrite
# the tab's label with `<task-notification>` — the cockpit column is there to
# remind you what the tab is doing, not what woke it.
WAKEUP=0
if warden_is_wakeup_prompt "$PROMPT"; then
  WAKEUP=1
  PREV="$(warden_bus_read "$ID" prompt)"
  # Blank beats `<task-notification>`: an empty label is merely unhelpful, a
  # wrong one actively misleads.
  PROMPT="$PREV"
fi

CTX="$(bash "$BIN_DIR/warden-context.sh" "$TRANSCRIPT" 2>/dev/null)"

# A fresh turn supersedes any pending needs-you escalation.
warden_kill_pidfile "$(warden_escalate_pid "$ID")"

# Start the turn's progress heartbeat. Nothing is in flight yet — a leftover
# marker from a killed turn would otherwise mask a stall for the next 15 min.
warden_beat "$ID"
warden_inflight_end "$ID"

# Mark this turn as one a human asked for. Stop reads it to tell your turn from
# the ones the session starts for itself when background work reports in.
[ "$WAKEUP" -eq 0 ] && warden_human_turn_begin "$ID"
# Proof of life for the animator, which now outlives the turn.
warden_session_pid_write "$ID"

warden_render_write "$ID" "working" "$PROJECT" "🧠" "$CTX" ""
warden_bus_write "$ID" "working" "$PROJECT" "🧠" "$TTY" "$CWD" "$STARTED" "$PROMPT" "$CTX" "" "" "$TRANSCRIPT"
warden_dispatch_state "$ID"

# Instant feedback before the spinner's first frame.
warden_write_title "$TTY" "$(warden_compose_title working "$PROJECT" "🧠" "$CTX")"

warden_spinner_ensure "$ID" "$TTY" "$BIN_DIR" || true

exit 0
