#!/bin/bash
# hook-flow.sh — drives the five hooks in sequence against an isolated $HOME and
# asserts the session state they leave behind.
#
# Guards two things unit tests can't see: the in-flight marker's lifecycle
# across a whole turn (a leftover marker silently suppresses stall detection for
# 15 minutes), and that a permission prompt does not restart the turn clock.
#
# SAFETY: warden_tty walks the process tree to find the real terminal device, so
# running the hooks unguarded here would claim THIS tab, reap its daemons, and
# drop its label. We shadow `ps` so warden_tty falls back to /dev/tty, which
# warden_claim_tty deliberately refuses to arbitrate. The sandbox config also
# disables the spinner, so no daemon is ever spawned.
#
#   bash plugins/warden/test/hook-flow.sh

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
HOOKS="$ROOT/hooks"

SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
# Belt to the sandbox config's braces: if a daemon ever does get spawned here,
# it must not outlive the test loop repainting a tab that isn't ours.
cleanup_sandbox() {
  pkill -f "spinner-daemon.sh s9 " 2>/dev/null
  pkill -f "escalate-daemon.sh s9 " 2>/dev/null
  rm -rf "$SANDBOX" 2>/dev/null
}
trap cleanup_sandbox EXIT

STUB="$SANDBOX/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/ps"; chmod +x "$STUB/ps"
export PATH="$STUB:$PATH"

PROJ="$SANDBOX/proj"; mkdir -p "$PROJ"
mkdir -p "$SANDBOX/.claude/warden"
# escalateAfterSeconds 0 keeps on-notify from detaching an escalation daemon
# that would outlive the test and play an alert sound 45 seconds later.
printf '{"spinner": false, "escalateAfterSeconds": 0, "escalateReping": false}\n' \
  > "$SANDBOX/.claude/warden/config.json"

# shellcheck source=../bin/helpers.sh
. "$BIN/helpers.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n     expected [%s] got [%s]\n' "$1" "$2" "$3"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

ID="s9"
TRANSCRIPT="$SANDBOX/t.jsonl"; : > "$TRANSCRIPT"

fire() { # fire <hook.sh> <json payload> [args...]
  printf '%s' "$2" | bash "$HOOKS/$1" "${@:3}" >/dev/null 2>&1
}
field() { # field <n>  (1=state 2=project 3=activity 4=ctx 5=attention)
  cut -d'|' -f"$1" "$(warden_render_file "$ID")" 2>/dev/null
}
inflight() { [ -f "$(warden_inflight_file "$ID")" ] && echo yes || echo no; }

BASE="\"session_id\":\"$ID\",\"cwd\":\"$PROJ\",\"transcript_path\":\"$TRANSCRIPT\""

printf '\nhook chain\n'

# 1. Prompt submitted — the turn begins thinking, nothing in flight.
fire on-prompt.sh "{$BASE,\"prompt\":\"hello there\"}"
is "on-prompt: state working"      "working" "$(field 1)"
is "on-prompt: activity thinking"  "🧠"      "$(field 3)"
is "on-prompt: heartbeat exists"   "yes"     "$([ -f "$(warden_beat_file "$ID")" ] && echo yes || echo no)"
is "on-prompt: nothing in flight"  "no"      "$(inflight)"
is "on-prompt: transcript on bus"  "$TRANSCRIPT" "$(warden_bus_read "$ID" transcript)"
STARTED0="$(warden_bus_read "$ID" started)"
[ -n "$STARTED0" ] && ok "on-prompt: started recorded" || no "on-prompt: started recorded" "non-empty" ""

# 2. A test command starts — 🧪, and the tool is in flight.
fire on-pretool.sh "{$BASE,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}"
is "on-pretool: test glyph"        "🧪"  "$(field 3)"
is "on-pretool: tool in flight"    "yes" "$(inflight)"

# 3. The tool finished — back to thinking, nothing in flight.
fire on-posttool.sh "{$BASE,\"tool_name\":\"Bash\"}"
is "on-posttool: back to thinking" "🧠"  "$(field 3)"
is "on-posttool: flight cleared"   "no"  "$(inflight)"

# 4. Another tool starts, then a permission prompt interrupts it.
fire on-pretool.sh "{$BASE,\"tool_name\":\"Read\",\"tool_input\":{}}"
is "on-pretool: read glyph"        "📖"  "$(field 3)"
is "on-pretool: tool in flight"    "yes" "$(inflight)"

fire on-notify.sh "{$BASE,\"message\":\"permission needed\"}"
is "on-notify: state needs_you"    "needs_you" "$(field 1)"
# A permission prompt fires BEFORE the tool runs. A stale marker here would
# suppress stall detection for the entire time the session sits blocked.
is "on-notify: flight cleared"     "no"        "$(inflight)"

# 5. The user approves; the next tool call resumes the SAME turn.
fire on-pretool.sh "{$BASE,\"tool_name\":\"Edit\",\"tool_input\":{}}"
is "resume: state working"         "working" "$(field 1)"
is "resume: edit glyph"            "✏️"      "$(field 3)"
is "resume: turn clock preserved"  "$STARTED0" "$(warden_bus_read "$ID" started)"

# 6. Turn ends.
fire on-stop.sh "{$BASE}"
is "on-stop: state done"           "done" "$(field 1)"
is "on-stop: flight cleared"       "no"   "$(inflight)"

# --- Background work --------------------------------------------------------
# A turn can end with work still running. Calling that "done" sends you to a tab
# that has nothing for you — the exact false alarm this state exists to prevent.
printf '\nbackground work\n'

BID="s10"
BBASE="\"session_id\":\"$BID\",\"cwd\":\"$PROJ\",\"transcript_path\":\"$TRANSCRIPT\""
bfield() { cut -d'|' -f"$1" "$(warden_render_file "$BID")" 2>/dev/null; }

# A subagent still running when the turn ends.
fire on-prompt.sh "{$BBASE,\"prompt\":\"go wide\"}"
fire on-subagent.sh "{$BBASE,\"agent_id\":\"agent-1\",\"agent_type\":\"senior-developer\"}" start
fire on-subagent.sh "{$BBASE,\"agent_id\":\"agent-2\",\"agent_type\":\"qa-engineer\"}" start
is "two subagents tracked"          "2"       "$(warden_bg_agent_count "$BID")"
fire on-stop.sh "{$BBASE}"
is "stop with subagents: waiting"   "waiting" "$(bfield 1)"
is "stop with subagents: 🤖 marker" "🤖"      "$(bfield 3)"

# One finishes: still waiting on the other.
fire on-subagent.sh "{$BBASE,\"agent_id\":\"agent-1\"}" stop
is "one subagent left: still waiting" "waiting" "$(bfield 1)"
# The last one finishes: now it really is yours again.
fire on-subagent.sh "{$BBASE,\"agent_id\":\"agent-2\"}" stop
is "last subagent done: state done"  "done" "$(bfield 1)"
is "agent set emptied"               "0"    "$(warden_bg_agent_count "$BID")"

# A backgrounded shell still running when the turn ends.
fire on-prompt.sh "{$BBASE,\"prompt\":\"kick off the build\"}"
fire on-pretool.sh "{$BBASE,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run build\",\"run_in_background\":true}}"
is "background shell counted"        "1" "$(warden_bg_shell_count "$BID")"
fire on-stop.sh "{$BBASE}"
is "stop with a shell: waiting"      "waiting" "$(bfield 1)"
is "stop with a shell: 🐚 marker"    "🐚"      "$(bfield 3)"

# A foreground command must NOT count as background work.
fire on-prompt.sh "{$BBASE,\"prompt\":\"now something quick\"}"
fire on-pretool.sh "{$BBASE,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
is "foreground shell not counted"    "1" "$(warden_bg_shell_count "$BID")"
fire on-stop.sh "{$BBASE}"
is "your turn ends, shell still out" "waiting" "$(bfield 1)"

# The shell finishes. Claude Code wakes the session by submitting a prompt ON
# ITS BEHALF — a `<task-notification>` block — so UserPromptSubmit fires even
# though no human typed. Mistaking that for your turn is what would pin the tab
# on the waiting moon forever.
fire on-prompt.sh "{$BBASE,\"prompt\":\"<task-notification> <task-id>b30wopw5c</task-id>\"}"
is "wake-up is not a human turn"     "no"   "$([ -f "$(warden_humanturn_file "$BID")" ] && echo yes || echo no)"
is "wake-up keeps the tab's label"   "now something quick" "$(warden_bus_read "$BID" prompt)"
fire on-stop.sh "{$BBASE}"
is "wake-up turn clears the shell"   "0"    "$(warden_bg_shell_count "$BID")"
is "nothing left: state done"        "done" "$(bfield 1)"

# Session ends: no daemon may outlive the tab.
fire on-session-end.sh "{$BBASE}"
is "session end drops the render"    "no" "$([ -f "$(warden_render_file "$BID")" ] && echo yes || echo no)"
is "session end clears background"   "0"  "$(warden_bg_pending "$BID")"

# --- Cockpit ----------------------------------------------------------------
printf '\ncockpit\n'

NOW="$(date +%s)"
NEEDS_SINCE=$((NOW - 125))

# A blocked session: activity, started, ctx and prompt are all empty. Reading
# the bus with a *whitespace* delimiter collapsed those empties and shifted
# needs_since into the activity column, printing a raw epoch as the wait time.
jq -n --arg ns "$NEEDS_SINCE" --arg up "$NOW" \
  '{id:"blocked",state:"needs_you",project:"someproj",activity:"",tty:"/dev/tty",
    cwd:"/x",started:"",prompt:"",ctx:"",needs_since:$ns,attention:"",
    transcript:"",updated:$up}' > "$(warden_session_file "blocked")"

# A session that says it's working but hasn't done anything in seven minutes.
jq -n --arg up "$NOW" \
  '{id:"zombie",state:"working",project:"deadproj",activity:"📖",tty:"/dev/tty",
    cwd:"/x",started:"1",prompt:"a task",ctx:"",needs_since:"",attention:"",
    transcript:"",updated:$up}' > "$(warden_session_file "zombie")"
warden_beat "zombie"
perl -e 'my $t = time - 420; utime $t, $t, $ARGV[0] or die' "$(warden_beat_file "zombie")"

# A session waiting on background work: it must read as waiting, never as done
# (nothing to do there) and never as stalled (nothing is supposed to be running).
jq -n --arg up "$NOW" \
  '{id:"bg",state:"waiting",project:"fanout",activity:"🤖",tty:"/dev/tty",
    cwd:"/x",started:"1",prompt:"review it all",ctx:"",needs_since:"",attention:"",
    transcript:"",updated:$up}' > "$(warden_session_file "bg")"

OUT="$(bash "$BIN/cockpit.sh" 2>&1)"

case "$OUT" in
  *"$NEEDS_SINCE"*) no "blocked row shows a duration, not a raw epoch" "no epoch" "$NEEDS_SINCE" ;;
  *)                ok "blocked row shows a duration, not a raw epoch" ;;
esac
case "$OUT" in
  *"2m"*) ok "blocked row shows how long it has waited (2m)" ;;
  *)      no "blocked row shows how long it has waited (2m)" "*2m*" "$OUT" ;;
esac
# The whole point of publishing attention: the fleet view must see a stall.
case "$OUT" in
  *🐢*stalled*) ok "cockpit shows a stalled session as 🐢 stalled" ;;
  *)            no "cockpit shows a stalled session as 🐢 stalled" "🐢 stalled" "$OUT" ;;
esac
case "$OUT" in
  *"1 stalled"*) ok "cockpit header counts the stalled session" ;;
  *)             no "cockpit header counts the stalled session" "1 stalled" "$OUT" ;;
esac
# ...and its clock counts from the last sign of life (7m), not the turn start.
case "$OUT" in
  *"7m"*) ok "stalled row clocks idle time, not turn duration" ;;
  *)      no "stalled row clocks idle time, not turn duration" "*7m*" "$OUT" ;;
esac

case "$OUT" in
  *waiting*fanout*) ok "cockpit shows a waiting session as its own row" ;;
  *)                no "cockpit shows a waiting session as its own row" "waiting fanout" "$OUT" ;;
esac
case "$OUT" in
  *"1 waiting"*) ok "cockpit header counts the waiting session" ;;
  *)             no "cockpit header counts the waiting session" "1 waiting" "$OUT" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
