#!/bin/bash
# animator.sh — runs the real spinner daemon against a pipe standing in for a
# terminal device, and asserts what it paints.
#
# WHAT IS ASSERTED: each state paints from its own glyph set, a waiting session
# is never accused of stalling, config edits apply to a running animator, the
# keeper takes the tab back after something overwrites it, and the daemon exits
# on both the session-end and the crash path.
#
# WHAT IS NOT: the frame *rate*. Every attempt to measure it fought the thing it
# was measuring — a regular file is truncated by each title write; a shell
# sampler forking per sample starved the daemon; `cat` block-buffers the frames
# away; a reader that reopens the pipe drops every frame in the gap. The cadence
# comes from two config values, so this asserts those instead, and the animation
# itself was verified by tracing the daemon (`bash -x`) cycling ◐ ◓ ◑ ◒ on
# schedule.
#
#   bash plugins/warden/test/animator.sh

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"

SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
mkdir -p "$SANDBOX/.claude/warden"
write_config() { cat > "$SANDBOX/.claude/warden/config.json"; }
write_config <<'JSON'
{
  "spinner": true,
  "spinnerFrames": ["⠋", "⠙", "⠹", "⠸"],
  "spinnerIntervalMs": 200,
  "waitingFrames": ["◐", "◓", "◑", "◒"],
  "waitingIntervalMs": 600,
  "keeperIntervalSeconds": 1,
  "showActivity": true,
  "showProject": true,
  "showContext": false
}
JSON

# shellcheck source=../bin/helpers.sh
. "$BIN/helpers.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n     %s\n' "$1" "$2"; }

ID="anim"
TAB="$SANDBOX/tab"          # the "terminal device"
PAINTED="$SANDBOX/painted"  # every title it ever received, one per line
mkfifo "$TAB"
: > "$PAINTED"

# The permanent reader, opened read-write so the pipe never reports EOF. Without
# a reader the daemon's `> "$tty"` blocks on open and the animator freezes —
# which is also what makes this a fair model of a terminal that always listens.
perl -e '
  my ($fifo, $out) = @ARGV;
  open(my $log, ">>", $out) or die;
  select((select($log), $| = 1)[0]);
  open(my $fh, "+<", $fifo) or die;
  while (1) {
    my $buf = "";
    my $n = sysread($fh, $buf, 4096);
    last unless defined $n;
    next unless $n;
    $buf =~ s/\a/\n/g;          # BEL terminates a title → one line each
    $buf =~ s/\e//g;
    print $log $buf;
  }' "$TAB" "$PAINTED" &
READER=$!
disown "$READER" 2>/dev/null || true

cleanup() {
  warden_kill_pidfile "$(warden_spinner_pid "$ID")"
  kill "$READER" 2>/dev/null
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

warden_ensure_dirs
warden_claim_tty "$TAB" "$ID"

mark() { wc -l < "$PAINTED" | tr -d ' '; }          # where the next phase starts
since() { tail -n "+$(( $1 + 1 ))" "$PAINTED"; }    # what was painted since mark

printf '\nanimator\n'

# --- working: the spinner ---------------------------------------------------
M="$(mark)"
warden_render_write "$ID" "working" "proj" "🔧" "" ""
( nohup bash "$BIN/spinner-daemon.sh" "$ID" "$TAB" >/dev/null 2>&1 & ) 2>/dev/null
sleep 3
WORK="$SANDBOX/work.txt"; since "$M" > "$WORK"

if grep -aq '⠋\|⠙\|⠹\|⠸' "$WORK"; then
  ok "working paints the spinner frames"
else
  no "working paints the spinner frames" "$(tail -n1 "$WORK")"
fi
if grep -aq '🔧' "$WORK" && grep -aq 'proj' "$WORK"; then
  ok "working title carries activity + project"
else
  no "working title carries activity + project" "$(tail -n1 "$WORK")"
fi

# --- waiting: the moon, and no stall accusation -----------------------------
M="$(mark)"
warden_render_write "$ID" "waiting" "proj" "🤖" "" ""
sleep 3
WAIT="$SANDBOX/wait.txt"; since "$M" > "$WAIT"

if grep -aq '◐\|◓\|◑\|◒' "$WAIT"; then
  ok "waiting paints the moon"
else
  no "waiting paints the moon" "$(tail -n1 "$WAIT")"
fi
if grep -aq '⠋\|⠙\|⠹\|⠸' "$WAIT"; then
  no "waiting never falls back to the spinner" "found a braille frame while waiting"
else
  ok "waiting never falls back to the spinner"
fi
if grep -aq '🤖' "$WAIT"; then
  ok "waiting says what it is waiting on"
else
  no "waiting says what it is waiting on" "$(tail -n1 "$WAIT")"
fi
# A session with no tool running is not stalled — it is waiting, on purpose.
if grep -aq '🐢\|⏳' "$WAIT"; then
  no "waiting is never called stalled" "found a stall glyph"
else
  ok "waiting is never called stalled"
fi
# The contrast between the two cadences is the signal; assert the values that
# drive it, since the rate itself is not reliably measurable from outside.
SPIN_MS="$(warden_cfg '.spinnerIntervalMs' '120')"
WAIT_MS="$(warden_cfg '.waitingIntervalMs' '400')"
if [ "$WAIT_MS" -gt "$SPIN_MS" ]; then
  ok "waiting is configured slower than working (${WAIT_MS}ms vs ${SPIN_MS}ms)"
else
  no "waiting is configured slower than working" "waiting ${WAIT_MS}ms vs working ${SPIN_MS}ms"
fi

# --- config is re-read while running ----------------------------------------
# The animator outlives the turn, so without this, changing the spinner would
# mean restarting every session.
M="$(mark)"
write_config <<'JSON'
{
  "spinner": true,
  "spinnerFrames": ["A", "B"],
  "spinnerIntervalMs": 200,
  "waitingFrames": ["◐", "◓", "◑", "◒"],
  "waitingIntervalMs": 600,
  "keeperIntervalSeconds": 1,
  "showActivity": true,
  "showProject": true,
  "showContext": false
}
JSON
warden_render_write "$ID" "working" "proj" "🔧" "" ""
sleep 3
if since "$M" | grep -aq ';A \|;B '; then
  ok "config edits apply without restarting the session"
else
  no "config edits apply without restarting the session" "$(since "$M" | tail -n1)"
fi

# --- static: the keeper takes the tab back ----------------------------------
warden_render_write "$ID" "done" "proj" "" "" ""
sleep 1.5
M="$(mark)"
printf '\033]0;✳ some claude code task\007' > "$TAB"   # Claude Code steals the tab
sleep 3
if since "$M" | grep -aq '✅.*proj'; then
  ok "keeper repaints over an overwrite"
else
  no "keeper repaints over an overwrite" "last title: [$(since "$M" | tail -n1)]"
fi

# --- exit: a dead session must not leave a loop painting a dead tab ---------
# The crash path. SessionEnd never fires, so the recorded CLAUDE_PID going away
# is the only signal — without it an orphan repaints someone else's tab for a
# day, which is exactly the kind of stray process a long fleet session cannot
# afford.
sleep 0.2 & DEAD=$!
wait "$DEAD" 2>/dev/null
printf '%s\n' "$DEAD" > "$(warden_session_pid_file "$ID")"
sleep 3
if warden_pid_alive "$(warden_spinner_pid "$ID")"; then
  no "daemon exits when the session process dies" "still running after CLAUDE_PID went away"
  warden_kill_pidfile "$(warden_spinner_pid "$ID")"
else
  ok "daemon exits when the session process dies"
fi

# --- exit: the render file disappearing is the daemon's off switch ----------
rm -f "$(warden_session_pid_file "$ID")"
( nohup bash "$BIN/spinner-daemon.sh" "$ID" "$TAB" >/dev/null 2>&1 & ) 2>/dev/null
sleep 1
rm -f "$(warden_render_file "$ID")"
sleep 2
if warden_pid_alive "$(warden_spinner_pid "$ID")"; then
  no "daemon exits when the session ends" "still running after the render file went"
  warden_kill_pidfile "$(warden_spinner_pid "$ID")"
else
  ok "daemon exits when the session ends"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
