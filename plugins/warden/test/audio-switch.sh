#!/bin/bash
# audio-switch.sh — the mute switch, and which notifications earn an alarm.
#
# Two questions this file exists to answer:
#   1. Does `audioEnabled` actually stop sound — including in a daemon that was
#      already running when it was flipped — without stopping anything else?
#   2. Does an idle nudge still arm a repeating alarm? It must not: idle_prompt
#      is emitted for any quiet session, so re-pinging on it means nagging a
#      session that asked for nothing.
#
# SAFETY: like hook-flow.sh, `ps` is shadowed so warden_tty cannot resolve this
# tab, the spinner is disabled in the sandbox config, and `afplay` is stubbed —
# reaching a real one is itself a failure. Escalation daemons spawned here are
# reaped by pidfile and by an id-scoped pkill on exit.
#
#   bash plugins/warden/test/audio-switch.sh

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
HOOKS="$ROOT/hooks"

SANDBOX="$(mktemp -d "${WARDEN_TEST_TMPDIR:-${TMPDIR:-/tmp}}/warden-audio.XXXXXX")"
export HOME="$SANDBOX"
cleanup_sandbox() {
  # Scoped to this test's session id and nothing else — never a bare pattern
  # that could reach a real session's daemon. TERM first, then KILL, for the
  # deferred-signal reason described at reap().
  pkill -f "escalate-daemon.sh s7 " 2>/dev/null
  pkill -f "spinner-daemon.sh s7 " 2>/dev/null
  sleep 0.3
  pkill -9 -f "escalate-daemon.sh s7 " 2>/dev/null
  pkill -9 -f "spinner-daemon.sh s7 " 2>/dev/null
  rm -rf "$SANDBOX" 2>/dev/null
}
trap cleanup_sandbox EXIT

STUB="$SANDBOX/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/ps"; chmod +x "$STUB/ps"
cat > "$STUB/afplay" <<EOF
#!/bin/sh
printf 'PLAYED\n' >> "$SANDBOX/afplay.log"
EOF
chmod +x "$STUB/afplay"
export PATH="$STUB:$PATH"

mkdir -p "$SANDBOX/.claude/warden"
CFG="$SANDBOX/.claude/warden/config.json"
# escalateAfterSeconds is long enough that an armed daemon just sleeps: this
# file asserts whether one was armed, not what it does after 45 minutes.
printf '{"spinner": false, "escalateAfterSeconds": 3600, "escalateReping": true, "showProject": true}\n' > "$CFG"

# shellcheck source=../bin/helpers.sh
. "$BIN/helpers.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n     expected [%s] got [%s]\n' "$1" "$2" "$3"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

ID="s7"
DEV="$SANDBOX/fake-tty"; : > "$DEV"
TRANSCRIPT="$SANDBOX/t.jsonl"; : > "$TRANSCRIPT"
PROJ="$SANDBOX/proj"; mkdir -p "$PROJ"
BASE="\"session_id\":\"$ID\",\"cwd\":\"$PROJ\",\"transcript_path\":\"$TRANSCRIPT\""

muted() { warden_audio_enabled && echo no || echo yes; }

# warden_kill_pidfile sends SIGTERM, and the daemon spends its whole life inside
# `sleep` — bash defers a trapped signal until the current child returns, so
# with escalateAfterSeconds at 3600 a "killed" daemon lingers for an hour. Fine
# in production (it wakes, sees the state changed, and exits without pinging),
# a pile of stragglers here. So follow through.
reap() {
  local pf pid
  pf="$(warden_escalate_pid "$ID")"
  pid="$(cat "$pf" 2>/dev/null)"
  warden_kill_pidfile "$pf"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pid" -gt 1 ] && kill -9 "$pid" 2>/dev/null
  return 0
}

# The hook detaches the daemon with nohup and returns; the pidfile lands a beat
# later. Checking once immediately is a coin flip, so poll — and give the
# negative case a real window too, or "it didn't arm" just means "not yet".
armed() { # armed [tenths-of-a-second, default 40]
  local i=0 max="${1:-40}"
  while [ "$i" -lt "$max" ]; do
    [ -f "$(warden_escalate_pid "$ID")" ] && { echo yes; return; }
    sleep 0.1; i=$((i + 1))
  done
  echo no
}

printf '\naudio switch\n'

# 1. An existing install has no such key. It must keep making noise — a fix that
#    quietly silences everyone who upgrades is not a fix.
is "absent key means audio on" "no" "$(muted)"

printf '{"spinner": false, "escalateAfterSeconds": 3600, "audioEnabled": false}\n' > "$CFG"
is "audioEnabled=false mutes"  "yes" "$(muted)"
printf '{"spinner": false, "escalateAfterSeconds": 3600, "audioEnabled": true}\n' > "$CFG"
is "audioEnabled=true unmutes" "no"  "$(muted)"

# 2. Muting is a sound decision, not a tracking decision.
printf '{"spinner": false, "escalateAfterSeconds": 3600, "audioEnabled": false}\n' > "$CFG"
printf '%s' "{$BASE,\"notification_type\":\"permission_prompt\"}" \
  | bash "$HOOKS/on-notify.sh" >/dev/null 2>&1
is "muted: state still tracked"      "needs_you"        "$(cut -d'|' -f1 "$(warden_render_file "$ID")" 2>/dev/null)"
is "muted: bus still written"        "needs_you"        "$(warden_bus_read "$ID" state)"
is "muted: reason still published"   "permission_prompt" "$(warden_bus_read "$ID" notify_kind)"
is "muted: escalation still armed"   "yes"              "$(armed)"
reap
printf '{"spinner": false, "escalateAfterSeconds": 3600, "audioEnabled": true}\n' > "$CFG"

printf '\nwhich notifications earn an alarm\n'

# 3. A dialog that is genuinely on screen.
rm -f "$(warden_render_file "$ID")" "$(warden_session_file "$ID")"
printf '%s' "{$BASE,\"notification_type\":\"permission_prompt\"}" \
  | bash "$HOOKS/on-notify.sh" >/dev/null 2>&1
is "permission_prompt arms escalation" "yes" "$(armed)"
is "permission_prompt sets needs_you"  "needs_you" "$(cut -d'|' -f1 "$(warden_render_file "$ID")" 2>/dev/null)"
reap

# 4. An MCP elicitation is a dialog too.
rm -f "$(warden_render_file "$ID")" "$(warden_session_file "$ID")"
printf '%s' "{$BASE,\"notification_type\":\"elicitation_dialog\"}" \
  | bash "$HOOKS/on-notify.sh" >/dev/null 2>&1
is "elicitation_dialog arms escalation" "yes" "$(armed)"
reap

# 5. The idle nudge. This is the one that was nagging sessions that had asked
#    for nothing. It must now do NOTHING AT ALL — not paint, not write the bus,
#    not clear the in-flight marker, not arm a timer. Anything less and a quiet
#    session manufactures an attention state nobody asked for.
rm -f "$(warden_render_file "$ID")" "$(warden_session_file "$ID")" "$(warden_inflight_file "$ID")"
printf '%s' "{$BASE,\"notification_type\":\"idle_prompt\"}" \
  | bash "$HOOKS/on-notify.sh" >/dev/null 2>&1
is "idle_prompt writes no render file" "no" "$([ -f "$(warden_render_file "$ID")" ] && echo yes || echo no)"
is "idle_prompt writes no bus file"    "no" "$([ -f "$(warden_session_file "$ID")" ] && echo yes || echo no)"
is "idle_prompt arms no escalation"    "no" "$(armed 20)"

# 6. And it must not displace a permission prompt that is already waiting: the
#    old code cleared the in-flight marker and killed the escalation timer
#    BEFORE it looked at the type, so an idle nudge arriving a second later
#    quietly disarmed a real alarm.
rm -f "$(warden_render_file "$ID")" "$(warden_session_file "$ID")"
printf '%s' "{$BASE,\"notification_type\":\"permission_prompt\"}" \
  | bash "$HOOKS/on-notify.sh" >/dev/null 2>&1
armed >/dev/null
PIDBEFORE="$(cat "$(warden_escalate_pid "$ID")" 2>/dev/null)"
printf '%s' "{$BASE,\"notification_type\":\"idle_prompt\"}" \
  | bash "$HOOKS/on-notify.sh" >/dev/null 2>&1
is "a real ask survives a following idle nudge" "$PIDBEFORE" "$(cat "$(warden_escalate_pid "$ID")" 2>/dev/null)"
is "  ...and keeps its needs_you state" "needs_you" "$(cut -d'|' -f1 "$(warden_render_file "$ID")" 2>/dev/null)"
is "  ...and keeps notify_kind=permission_prompt" "permission_prompt" "$(warden_bus_read "$ID" notify_kind)"
reap

# 7. An unknown or missing type is uncertainty, not an ask.
for NT in some_future_type ''; do
  rm -f "$(warden_render_file "$ID")" "$(warden_session_file "$ID")"
  printf '%s' "{$BASE,\"notification_type\":\"$NT\"}" \
    | bash "$HOOKS/on-notify.sh" >/dev/null 2>&1
  is "unclassifiable (${NT:-missing}) writes nothing" "no" \
     "$([ -f "$(warden_render_file "$ID")" ] && echo yes || echo no)"
  is "  ...and arms nothing"                          "no" "$(armed 15)"
done

# 8. A dialog AFTER a turn reported done is ordinary, and used to be swallowed
#    by a blanket "already done, leave it alone" guard.
rm -f "$(warden_session_file "$ID")"
warden_render_write "$ID" "done" "proj" "" "" ""
printf '%s' "{$BASE,\"notification_type\":\"permission_prompt\"}" \
  | bash "$HOOKS/on-notify.sh" >/dev/null 2>&1
is "permission prompt after a done turn" "needs_you" "$(cut -d'|' -f1 "$(warden_render_file "$ID")" 2>/dev/null)"
armed >/dev/null; reap

# 9. ...but a trailing idle nudge after done still must not un-finish it.
rm -f "$(warden_session_file "$ID")"
warden_render_write "$ID" "done" "proj" "" "" ""
printf '%s' "{$BASE,\"notification_type\":\"idle_prompt\"}" \
  | bash "$HOOKS/on-notify.sh" >/dev/null 2>&1
is "idle nudge after a done turn leaves it done" "done" "$(cut -d'|' -f1 "$(warden_render_file "$ID")" 2>/dev/null)"

printf '\na running daemon obeys a mute it was not started with\n'

# 6. Start the daemon unmuted, with a 1s tick, and let it ring once.
printf '{"spinner": false, "escalateAfterSeconds": 1, "escalateReping": true, "audioEnabled": true}\n' > "$CFG"
warden_render_write "$ID" "needs_you" "proj" "" "" ""
: > "$SANDBOX/afplay.log"
bash "$BIN/escalate-daemon.sh" "$ID" "$DEV" >/dev/null 2>&1 &
DPID=$!
sleep 3
is "unmuted daemon pings" "yes" "$([ -s "$SANDBOX/afplay.log" ] && echo yes || echo no)"

# 7. Flip the switch under the running process. No restart, no kill.
printf '{"spinner": false, "escalateAfterSeconds": 1, "escalateReping": true, "audioEnabled": false}\n' > "$CFG"
: > "$SANDBOX/afplay.log"
sleep 3
is "same daemon goes quiet on the next tick" "no" "$([ -s "$SANDBOX/afplay.log" ] && echo yes || echo no)"
is "and is still running (mute != kill)" "yes" "$(kill -0 "$DPID" 2>/dev/null && echo yes || echo no)"
is "and is still painting the escalated state" "escalated" "$(cut -d'|' -f5 "$(warden_render_file "$ID")" 2>/dev/null)"
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null
reap

printf '\nthe CLI writes one field and nothing else\n'

printf '{"spinner": false, "spinnerIntervalMs": 500, "escalateAfterSeconds": 45, "audioEnabled": true, "glyphs": {"done": "OK"}}\n' > "$CFG"
bash "$BIN/warden-cli.sh" sound off >/dev/null 2>&1
is "warden sound off"           "false" "$(warden_cfg '.audioEnabled' 'true')"
is "  ...leaves spinnerInterval" "500"   "$(warden_cfg '.spinnerIntervalMs' '120')"
is "  ...leaves custom glyphs"   "OK"    "$(warden_cfg '.glyphs.done' 'X')"
bash "$BIN/warden-cli.sh" sound on >/dev/null 2>&1
is "warden sound on"            "true"  "$(warden_cfg '.audioEnabled' 'true')"
bash "$BIN/warden-cli.sh" sound reping off >/dev/null 2>&1
is "warden sound reping off"    "false" "$(warden_cfg '.escalateReping' 'true')"
is "  ...leaves audioEnabled"   "true"  "$(warden_cfg '.audioEnabled' 'false')"
bash "$BIN/warden-cli.sh" sound reping on >/dev/null 2>&1
is "warden sound reping on"     "true"  "$(warden_cfg '.escalateReping' 'false')"

printf '\nthe hook still says nothing on stdout\n'

# Anything printed here is injected into the model's context window and billed.
# The classification added a payload field and a bus patch — both are easy
# places for a stray jq error or a debug printf to leak out.
rm -f "$(warden_render_file "$ID")" "$(warden_session_file "$ID")"
for NT in permission_prompt idle_prompt elicitation_dialog ''; do
  OUT="$(printf '%s' "{$BASE,\"notification_type\":\"$NT\"}" | bash "$HOOKS/on-notify.sh" 2>/dev/null)"
  is "on-notify stdout is empty (${NT:-no-type})" "" "$OUT"
  armed 40 >/dev/null; reap
  rm -f "$(warden_render_file "$ID")" "$(warden_session_file "$ID")"
done

# Nothing may have escaped to a real speaker or a real terminal device.
if [ -s "$SANDBOX/afplay.log" ]; then
  no "no stray playback" "empty afplay log" "$(wc -l < "$SANDBOX/afplay.log" | tr -d ' ') plays"
else
  ok "no stray playback after the muted stretch"
fi
if [ -s "$DEV" ]; then ok "titles went to the fake device, not a terminal"
else ok "no title written (spinner disabled)"; fi

printf '\n  %s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
