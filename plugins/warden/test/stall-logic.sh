#!/bin/bash
# stall-logic.sh — the load-bearing truth tests for warden's indicators.
#
# Everything here guards one invariant: a glyph must describe reality. The
# regressions that motivated these tests were (a) 🐢 firing on any turn longer
# than five minutes regardless of whether work was happening, and (b) unknown
# tools painting the Bash wrench.
#
# Runs against an isolated $HOME, and pins the clock via $WARDEN_NOW so the
# thresholds are asserted at their exact boundaries instead of by sleeping.
#
#   bash plugins/warden/test/stall-logic.sh

set -u

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"

# shellcheck source=../bin/helpers.sh
. "$BIN/helpers.sh"

PASS=0; FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n     expected [%s] got [%s]\n' "$1" "$2" "$3"; }
is() { # is <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi
}

# perl's utime is the only thing both BSD and GNU userlands agree on without
# date-format gymnastics.
settime()  { perl -e 'utime $ARGV[1], $ARGV[1], $ARGV[0] or die' "$1" "$2"; }
backdate() { settime "$1" "$(($(date +%s) - $2))"; }

command -v perl >/dev/null 2>&1 || { printf 'perl required; skipping\n'; exit 0; }

ID="s1"
warden_ensure_dirs
BEAT="$(warden_beat_file "$ID")"
INFLIGHT="$(warden_inflight_file "$ID")"

# --- warden_attention: the rule that replaced turn-duration -----------------
printf '\nwarden_attention (defaults: stuck 300, stuck2 900, slowTool 900)\n'

# The clock is pinned for this whole section. Backdating a file and then letting
# warden_attention read a *live* `date +%s` races the second boundary: 899s
# becomes 900s and the just-under-threshold assertions flake.
T="$(date +%s)"
WARDEN_NOW="$T"

warden_beat "$ID"; warden_inflight_end "$ID"
settime "$BEAT" "$T"
is "fresh heartbeat is silent"            ""          "$(warden_attention "$ID")"

settime "$BEAT" "$((T - 299))"
is "299s idle: still silent"              ""          "$(warden_attention "$ID")"

settime "$BEAT" "$((T - 300))"
is "300s idle: stalled"                   "stalled"   "$(warden_attention "$ID")"

settime "$BEAT" "$((T - 899))"
is "899s idle: stalled"                   "stalled"   "$(warden_attention "$ID")"

settime "$BEAT" "$((T - 900))"
is "900s idle: stalled2"                  "stalled2"  "$(warden_attention "$ID")"

# The whole point of the in-flight marker: a long test run is slow, not stuck.
settime "$BEAT" "$((T - 3600))"
warden_inflight_begin "$ID"
settime "$INFLIGHT" "$T"
is "tool running: suppresses stall"       ""          "$(warden_attention "$ID")"

settime "$INFLIGHT" "$((T - 899))"
is "tool running 899s: still silent"      ""          "$(warden_attention "$ID")"

# ...but a tool blocked on stdin must not hide behind "a tool is running".
settime "$INFLIGHT" "$((T - 900))"
is "tool running 900s: slow_tool"         "slow_tool" "$(warden_attention "$ID")"

warden_inflight_end "$ID"
rm -f "$BEAT"
is "no heartbeat at all: silent"          ""          "$(warden_attention "$ID")"

unset WARDEN_NOW

# The headline regression. Pin the clock six hours into the future — a turn of
# any duration — and show the verdict depends ONLY on the heartbeat, never on
# how long the turn has been running.
warden_beat "$ID"
NOWX=$(($(date +%s) + 21600))
WARDEN_NOW="$NOWX"

settime "$BEAT" "$NOWX"              # 6h turn, heartbeat just fired
is "6h turn, live heartbeat: silent"   ""        "$(warden_attention "$ID")"

settime "$BEAT" "$((NOWX - 400))"    # 6h turn, nothing for 400s
is "6h turn, dead heartbeat: stalled"  "stalled" "$(warden_attention "$ID")"

unset WARDEN_NOW

# --- warden_cmd_kind: command-position matching -----------------------------
printf '\nwarden_cmd_kind\n'

is "npm test"                 "test" "$(warden_cmd_kind 'npm test')"
is "npm run test:unit"        "test" "$(warden_cmd_kind 'npm run test:unit')"
is "pnpm test"                "test" "$(warden_cmd_kind 'pnpm test')"
is "npx mocha --grep x"       "test" "$(warden_cmd_kind 'npx mocha --grep x')"
is "cargo test"               "test" "$(warden_cmd_kind 'cargo test')"
is "sudo make test"           "test" "$(warden_cmd_kind 'sudo make test')"
is "CI=1 pytest -q"           "test" "$(warden_cmd_kind 'CI=1 pytest -q')"
# A flag containing `=` must not be mistaken for a leading env assignment.
is "npm test --reporter=dot"  "test" "$(warden_cmd_kind 'npm test --reporter=dot')"
is "npm run lint"             "lint" "$(warden_cmd_kind 'npm run lint')"
is "lint && test -> test"     "test" "$(warden_cmd_kind 'yarn lint && npm test')"
is "plain command"            ""     "$(warden_cmd_kind 'echo hello')"
# The regression: a substring match called this a test run.
is 'git commit -m "fix npm test"' "" "$(warden_cmd_kind 'git commit -m "fix npm test"')"

# --- warden_activity_glyph: unknown tools must not impersonate Bash ---------
printf '\nwarden_activity_glyph\n'

is "Bash"            "🔧" "$(warden_activity_glyph Bash)"
is "Read"            "📖" "$(warden_activity_glyph Read)"
is "Skill"           "⚡" "$(warden_activity_glyph Skill)"
is "Task"            "🤖" "$(warden_activity_glyph Task)"
is "TaskCreate"      "🗒️" "$(warden_activity_glyph TaskCreate)"
is "mcp__foo__bar"   "🔌" "$(warden_activity_glyph mcp__foo__bar)"
is "unknown -> dot"  "•"  "$(warden_activity_glyph SomeFutureTool)"

# --- warden_state_glyph: the deleted error state -----------------------------
printf '\nwarden_state_glyph\n'

is "stalled"   "🐢" "$(warden_state_glyph stalled)"
is "stalled2"  "⏳" "$(warden_state_glyph stalled2)"
is "slow_tool" "⏳" "$(warden_state_glyph slow_tool)"
is "escalated" "‼️" "$(warden_state_glyph escalated)"
# `error` is gone; it must fall through to idle, never resurrect 🔴.
is "error -> idle" "·" "$(warden_state_glyph error)"

# --- End-to-end: the daemon paints 🐢 and publishes it ----------------------
printf '\nspinner-daemon (end-to-end)\n'

D_ID="s2"
D_TTY="$SANDBOX/faketty"
: > "$D_TTY"
warden_render_write "$D_ID" "working" "proj" "🔧" "50" ""
warden_beat "$D_ID"
backdate "$(warden_beat_file "$D_ID")" 400   # stalled tier 1

bash "$BIN/spinner-daemon.sh" "$D_ID" "$D_TTY" >/dev/null 2>&1 &
DPID=$!
sleep 1.5
kill "$DPID" 2>/dev/null || true
wait "$DPID" 2>/dev/null || true

TITLE="$(cat "$D_TTY" 2>/dev/null)"
case "$TITLE" in
  *🐢*) ok "stalled session paints 🐢 on the tab" ;;
  *)    no "stalled session paints 🐢 on the tab" "*🐢*" "$TITLE" ;;
esac
IFS='|' read -r _s _p _a _c D_ATT < "$(warden_render_file "$D_ID")"
is "daemon publishes attention to the render bus" "stalled" "$D_ATT"

# A healthy heartbeat must leave the tab clean.
D_ID2="s3"; D_TTY2="$SANDBOX/faketty2"; : > "$D_TTY2"
warden_render_write "$D_ID2" "working" "proj" "🔧" "50" ""
warden_beat "$D_ID2"

bash "$BIN/spinner-daemon.sh" "$D_ID2" "$D_TTY2" >/dev/null 2>&1 &
DPID2=$!
sleep 1.5
kill "$DPID2" 2>/dev/null || true
wait "$DPID2" 2>/dev/null || true

TITLE2="$(cat "$D_TTY2" 2>/dev/null)"
case "$TITLE2" in
  *🐢*|*⏳*) no "healthy session stays unmarked" "no marker" "$TITLE2" ;;
  *)         ok "healthy session stays unmarked" ;;
esac

# --- The context meter must move DURING a turn -------------------------------
# It used to be computed once at prompt-submit and never again, so a turn that
# climbed past the warn threshold displayed nothing at all.
printf '\ncontext meter (mid-turn refresh)\n'

C_ID="s4"; C_TTY="$SANDBOX/faketty3"; : > "$C_TTY"
C_TRANSCRIPT="$SANDBOX/transcript.jsonl"
# 150k of a 200k window = 75%, which is exactly the default warn threshold.
printf '%s\n' '{"cwd":"/x","message":{"model":"claude-opus-4-8","usage":{"input_tokens":150000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$C_TRANSCRIPT"

is "warden-context.sh reads the transcript" "75" "$(bash "$BIN/warden-context.sh" "$C_TRANSCRIPT")"

warden_render_write "$C_ID" "working" "proj" "🔧" "10" ""   # stale seed, as at prompt-submit
warden_beat "$C_ID"

bash "$BIN/spinner-daemon.sh" "$C_ID" "$C_TTY" "$C_TRANSCRIPT" >/dev/null 2>&1 &
CPID=$!
sleep 1.5
kill "$CPID" 2>/dev/null || true
wait "$CPID" 2>/dev/null || true

IFS='|' read -r _s _p _a C_CTX _ < "$(warden_render_file "$C_ID")"
is "daemon refreshes stale context 10 -> 75" "75" "$C_CTX"

C_TITLE="$(cat "$C_TTY" 2>/dev/null)"
case "$C_TITLE" in
  *·75%*) ok "crossing the warn threshold mid-turn shows ·75%" ;;
  *)      no "crossing the warn threshold mid-turn shows ·75%" "*·75%*" "$C_TITLE" ;;
esac

# --- Spinner lifecycle: self-heal without ever double-animating --------------
# A daemon that dies mid-turn used to leave the tab frozen on its last frame for
# the rest of the turn, because the relaunch only lived on the resume path.
printf '\nspinner lifecycle (self-heal)\n'

L_ID="s5"; L_TTY="$SANDBOX/faketty4"; : > "$L_TTY"
L_PIDF="$(warden_spinner_pid "$L_ID")"
L_LOCK="$(warden_spinner_lock "$L_ID")"
warden_render_write "$L_ID" "working" "proj" "🔧" "" ""
warden_beat "$L_ID"

bash "$BIN/spinner-daemon.sh" "$L_ID" "$L_TTY" >/dev/null 2>&1 &
sleep 0.6
PID1="$(cat "$L_PIDF" 2>/dev/null)"
[ -n "$PID1" ] && ok "daemon claimed the lock and wrote its pid" \
                || no "daemon claimed the lock and wrote its pid" "a pid" ""

# Calling ensure while the animator is alive must never spawn a second one.
warden_spinner_ensure "$L_ID" "$L_TTY" "$BIN"
sleep 0.4
is "ensure no-ops while the daemon is alive" "$PID1" "$(cat "$L_PIDF" 2>/dev/null)"

kill -9 "$PID1" 2>/dev/null || true
wait 2>/dev/null || true
sleep 0.3
is "SIGKILL strands the singleton lock" "yes" "$([ -d "$L_LOCK" ] && echo yes || echo no)"

# A lock younger than the guard belongs to a daemon that may still be starting
# up (it has not written its pidfile yet). Sweeping it would let a second
# animator in — the offset-frames bug. It must survive.
warden_clear_stale_spinner_lock "$L_ID"
is "a fresh lock is never swept" "yes" "$([ -d "$L_LOCK" ] && echo yes || echo no)"

# Once it's demonstrably stale, the animator revives on the next tool call.
settime "$L_LOCK" "$(($(date +%s) - 15))"
warden_spinner_ensure "$L_ID" "$L_TTY" "$BIN"
sleep 0.8
PID2="$(cat "$L_PIDF" 2>/dev/null)"
if [ -n "$PID2" ] && [ "$PID2" != "$PID1" ] && kill -0 "$PID2" 2>/dev/null; then
  ok "stale lock swept and the animator self-heals"
else
  no "stale lock swept and the animator self-heals" "a new live pid" "$PID2"
fi
kill "$PID2" 2>/dev/null || true
wait 2>/dev/null || true

# `warden_spinner_ensure` now runs on EVERY tool call, so the singleton has to
# hold under a storm. Two animators on one tab write offset frames — the bug the
# mkdir lock exists to prevent.
S_ID="s6"; S_TTY="$SANDBOX/faketty5"; : > "$S_TTY"
warden_render_write "$S_ID" "working" "proj" "🔧" "" ""
warden_beat "$S_ID"
i=0
while [ "$i" -lt 8 ]; do
  ( nohup bash "$BIN/spinner-daemon.sh" "$S_ID" "$S_TTY" >/dev/null 2>&1 & ) 2>/dev/null || true
  i=$((i + 1))
done
sleep 1.2
LIVE="$(ps -eo pid,command | grep "spinner-daemon.sh $S_ID" | grep -vc grep | tr -d ' ')"
is "8 concurrent launches leave exactly 1 animator" "1" "$LIVE"

for p in $(ps -eo pid,command | grep "spinner-daemon.sh $S_ID" | grep -v grep | awk '{print $1}'); do
  kill "$p" 2>/dev/null || true
done
wait 2>/dev/null || true

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
