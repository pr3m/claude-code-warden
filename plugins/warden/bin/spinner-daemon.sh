#!/bin/bash
# spinner-daemon.sh — the one process that owns a session's tab title.
#
# It runs for the life of the session, not just the life of a turn, because
# Claude Code paints the tab title itself (`✳ <task summary>`) and there is no
# setting to stop it. Whoever wrote last wins. A title painted once by a hook
# survives only until Claude Code's next repaint, after which the tab shows no
# warden state at all — the fleet looks idle while half of it is busy. So the
# daemon repaints on a slow keeper tick even when nothing is animating.
#
# Three cadences, read from the per-session render file every tick (no jq in
# the hot loop):
#
#   working  fast braille frames; attention markers (🐢/⏳) and a live context
#            meter, both of which need a clock and so cannot live in a hook
#   waiting  slow moon frames — the turn ended but subagents or background
#            shells are still running. Nothing is being asked of you, and the
#            movement says so. Attention markers are deliberately OFF here: a
#            session with no tool running is not stalled, it is waiting.
#   static   done / needs_you / idle — repaint the same title every
#            keeperIntervalSeconds so Claude Code cannot overwrite it away
#
# Usage: spinner-daemon.sh <session_id> <tty_device> [transcript_path]

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$DIR/helpers.sh"

ID="${1:?session id required}"
TTY="${2:?tty device required}"
TRANSCRIPT="${3:-}"
[ -n "$TRANSCRIPT" ] || TRANSCRIPT="$(warden_bus_read "$ID" transcript)"

RENDER="$(warden_render_file "$ID")"
PIDFILE="$(warden_spinner_pid "$ID")"
LOCK="$(warden_spinner_lock "$ID")"

warden_ensure_dirs
# Atomic singleton: mkdir succeeds for exactly one process. A racing second
# launch loses the lock and exits — so two daemons can never write offset
# frames to the same tab.
mkdir "$LOCK" 2>/dev/null || exit 0
printf '%s\n' "$$" > "$PIDFILE"

# Clean up pidfile + lock however we exit. `kill` (SIGTERM from the hooks) runs
# the TERM trap → exit → EXIT trap, so the lock is always released.
cleanup() { rm -f "$PIDFILE" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT
trap 'exit 0' TERM INT HUP

# --- Config: read up front, re-read when the file changes -------------------
# The animator outlives the turn now, so "restart Claude Code to change the
# spinner" would mean "restart to change anything". One stat per second-tick
# buys back edit-and-see-it.
CFG_MTIME=""
load_config() {
  INTERVAL_MS="$(warden_cfg '.spinnerIntervalMs' '120')"
  WAIT_MS="$(warden_cfg '.waitingIntervalMs' '400')"
  KEEPER_S="$(warden_cfg '.keeperIntervalSeconds' '2')"
  STUCK="$(warden_cfg '.stuckAfterSeconds' '300')"
  STUCK2="$(warden_cfg '.stuck2AfterSeconds' '900')"
  SLOW="$(warden_cfg '.slowToolAfterSeconds' '900')"
  SHOW_ACTIVITY="$(warden_cfg '.showActivity' 'true')"
  SHOW_PROJECT="$(warden_cfg '.showProject' 'true')"
  SHOW_CONTEXT="$(warden_cfg '.showContext' 'true')"
  CTX_WARN="$(warden_cfg '.contextWarnPercent' '75')"
  CTX_REFRESH="$(warden_cfg '.contextRefreshSeconds' '15')"
  # A backstop for a session that died without emitting SessionEnd — NOT a turn
  # limit. Turns may legitimately run for hours; if this ever trips on a live
  # session, the next tool call revives us via warden_spinner_ensure.
  MAXLIFE="$(warden_cfg '.maxLifetimeSeconds' '86400')"

  SLEEP_S="$(ms_to_sleep "$INTERVAL_MS")"
  WSLEEP_S="$(ms_to_sleep "$WAIT_MS")"
  case "$KEEPER_S" in ''|*[!0-9]*) KEEPER_S=2 ;; esac
  [ "$KEEPER_S" -lt 1 ] && KEEPER_S=1
  # Attention/context are re-evaluated about once a second, not once per frame —
  # a `stat` per frame would be several forks/sec for state that changes slowly.
  TICKS_PER_SEC="$(LC_ALL=C awk -v m="$INTERVAL_MS" 'BEGIN { t = int(1000 / m); if (t < 1) t = 1; printf "%d", t }')"

  FRAMES=()
  while IFS= read -r f; do [ -n "$f" ] && FRAMES+=("$f"); done < <(read_frames '.spinnerFrames')
  [ "${#FRAMES[@]}" -eq 0 ] && FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧")
  WFRAMES=()
  while IFS= read -r f; do [ -n "$f" ] && WFRAMES+=("$f"); done < <(read_frames '.waitingFrames')
  [ "${#WFRAMES[@]}" -eq 0 ] && WFRAMES=("◐" "◓" "◑" "◒")

  CFG_MTIME="$(warden_mtime "$(warden_config_file)" 2>/dev/null)"
}

# LC_ALL=C so the fractional seconds use a dot, not a locale decimal comma
# (which would make `sleep 0,120` invalid → error → busy loop).
ms_to_sleep() {
  LC_ALL=C awk -v m="$1" 'BEGIN { s = m / 1000; if (s < 0.04) s = 0.04; printf "%.3f", s }'
}

read_frames() { # read_frames <jq-path> — prefer the JSON array, else the default
  local path="$1"
  if warden_has_jq && [ -f "$(warden_config_file)" ]; then
    jq -r "${path}[]?" "$(warden_config_file)" 2>/dev/null
  fi
}

config_changed() {
  local m; m="$(warden_mtime "$(warden_config_file)" 2>/dev/null)"
  [ "$m" != "$CFG_MTIME" ]
}

load_config

START_TS="$(warden_now)"
i=0
tick=0
ATT=""          # last published attention marker
ATT_GLYPH=""
CTX_TS=0        # epoch of the last context recompute
PULSE=""        # last OSC 9;4 state written, so we only write on change

set_pulse() { # set_pulse <state>
  [ "$PULSE" = "$1" ] && return 0
  PULSE="$1"
  warden_write_progress "$TTY" "$1" 0
}

while :; do
  # Stop the moment the session's render file is gone (SessionEnd cleaned up).
  [ -f "$RENDER" ] || break
  # Stop the instant a newer session has taken this terminal device over (the
  # OS recycled the /dev/ttysNNN number) — never paint our title onto its tab.
  warden_owns_tty "$TTY" "$ID" || break
  # ...or the session died without firing SessionEnd (crash, kill -9, closed
  # terminal). Without this the loop would repaint a dead tab until MAXLIFE.
  warden_session_alive "$ID" || break
  line="$(cat "$RENDER" 2>/dev/null)"
  # Tolerate a transient empty read during an atomic rewrite — retry next tick.
  [ -n "$line" ] || { sleep "$SLEEP_S"; continue; }
  IFS='|' read -r r_state r_project r_activity r_ctx r_att <<< "$line"

  now="$(warden_now)"

  # Self-reap on an absurdly long life (a session whose end hook never fired).
  # Harmless on a live session: the next tool call relaunches us.
  [ "$((now - START_TS))" -ge "$MAXLIFE" ] 2>/dev/null && break

  # --- Static states: keep the title, let Claude Code repaint over nothing ---
  if [ "$r_state" != "working" ] && [ "$r_state" != "waiting" ]; then
    # The pulse is left exactly as the state hook set it — Stop clears it,
    # Notification lights it red. Touching it here would wipe the red bar a
    # second after a permission prompt raised it.
    PULSE=""
    config_changed && load_config
    # An escalated session must keep its ‼️ rather than fall back to ❓.
    lead_state="$r_state"
    [ -n "$r_att" ] && lead_state="$r_att"
    warden_write_title "$TTY" "$(warden_compose_title "$lead_state" "$r_project" "$r_activity" "$r_ctx")"
    ATT=""; ATT_GLYPH=""
    sleep "$KEEPER_S"
    continue
  fi

  if [ "$r_state" = "waiting" ]; then
    # Waiting on background work: animate, but never accuse it of stalling —
    # no tool is running because none is supposed to be.
    set_pulse 3
    config_changed && load_config
    nframes="${#WFRAMES[@]}"
    frame="${WFRAMES[$((i % nframes))]}"
    title="$frame"
    [ "$SHOW_ACTIVITY" = "true" ] && [ -n "$r_activity" ] && title="$title $r_activity"
    [ "$SHOW_PROJECT" = "true" ]  && [ -n "$r_project" ]  && title="$title $r_project"
    if [ "$SHOW_CONTEXT" = "true" ] && [ -n "$r_ctx" ]; then
      [ "$r_ctx" -ge "$CTX_WARN" ] 2>/dev/null && title="$title ·${r_ctx}%"
    fi
    warden_write_title "$TTY" "$title"
    ATT=""; ATT_GLYPH=""
    i=$(( (i + 1) % nframes ))
    sleep "$WSLEEP_S"
    continue
  fi

  # --- Working: the fast lane, with attention + live context ----------------
  set_pulse 3
  if [ "$((tick % TICKS_PER_SEC))" -eq 0 ]; then
    att_changed=0; ctx_changed=0
    config_changed && load_config

    # --- Attention: is anything actually happening? -----------------------
    att="$(warden_attention "$ID" "$SLOW" "$STUCK" "$STUCK2")"
    if [ "$att" != "$ATT" ]; then
      ATT="$att"
      ATT_GLYPH=""
      [ -n "$ATT" ] && ATT_GLYPH="$(warden_state_glyph "$ATT")"
      att_changed=1
    fi

    # --- Context meter: recompute mid-turn --------------------------------
    # The value seeded at prompt-submit is already wrong by the time it matters;
    # a turn that crosses the warn threshold must actually say so.
    if [ -n "$TRANSCRIPT" ] && [ "$((now - CTX_TS))" -ge "$CTX_REFRESH" ] 2>/dev/null; then
      CTX_TS="$now"
      fresh="$(bash "$DIR/warden-context.sh" "$TRANSCRIPT" 2>/dev/null)"
      if [ -n "$fresh" ] && [ "$fresh" != "$r_ctx" ]; then
        r_ctx="$fresh"
        ctx_changed=1
      fi
    fi

    # Publish, so the cockpit and the on-state extension see a stalled session
    # too — not just whoever happens to be looking at this one tab.
    if [ "$att_changed" -eq 1 ] || [ "$ctx_changed" -eq 1 ]; then
      # Re-read immediately before writing: a PreToolUse may have landed a new
      # activity glyph since our tick began, and a blind write-back of the line
      # we read ~1s ago would silently revert it.
      cur="$(cat "$RENDER" 2>/dev/null)"
      if [ -n "$cur" ]; then
        IFS='|' read -r c_state c_project c_activity _c_ctx _c_att <<< "$cur"
        if [ "$c_state" = "working" ]; then
          r_project="$c_project"; r_activity="$c_activity"
          warden_render_write "$ID" "working" "$c_project" "$c_activity" "$r_ctx" "$ATT"
        fi
      fi
      [ "$att_changed" -eq 1 ] && warden_bus_patch "$ID" attention "$ATT"
      [ "$ctx_changed" -eq 1 ] && warden_bus_patch "$ID" ctx "$r_ctx"
      [ "$att_changed" -eq 1 ] && warden_dispatch_state "$ID"
    fi
  fi

  # Lead = spinner frame, with the attention marker prepended when one is live.
  nframes="${#FRAMES[@]}"
  frame="${FRAMES[$((i % nframes))]}"
  if [ -n "$ATT_GLYPH" ]; then lead="$ATT_GLYPH $frame"; else lead="$frame"; fi

  title="$lead"
  [ "$SHOW_ACTIVITY" = "true" ] && [ -n "$r_activity" ] && title="$title $r_activity"
  [ "$SHOW_PROJECT" = "true" ]  && [ -n "$r_project" ]  && title="$title $r_project"
  if [ "$SHOW_CONTEXT" = "true" ] && [ -n "$r_ctx" ]; then
    if [ "$r_ctx" -ge "$CTX_WARN" ] 2>/dev/null; then
      title="$title ·${r_ctx}%"
    fi
  fi

  warden_write_title "$TTY" "$title"

  i=$(( (i + 1) % nframes ))
  tick=$(( tick + 1 ))
  sleep "$SLEEP_S"
done

# Leaving the loop means the session is gone or the tab belongs to someone
# else; clear the pulse rather than leave it spinning forever.
warden_write_progress "$TTY" 0 0
exit 0
