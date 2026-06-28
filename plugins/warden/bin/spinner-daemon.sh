#!/bin/bash
# spinner-daemon.sh — detached background animator for one session's tab title.
# Launched by the UserPromptSubmit hook; killed by Notification/Stop hooks.
#
# Reads the cheap per-session render file every tick (no jq in the hot loop)
# and writes an OSC 0 title frame to the resolved terminal device. Also owns
# stuck-detection (🐢 / ⏳) since it's the loop that already tracks elapsed time.
#
# Usage: spinner-daemon.sh <session_id> <tty_device>

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$DIR/helpers.sh"

ID="${1:?session id required}"
TTY="${2:?tty device required}"

RENDER="$(warden_render_file "$ID")"
PIDFILE="$(warden_spinner_pid "$ID")"
LOCK="${PIDFILE%.pid}.lock"

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

# --- Read config once up front (jq is fine here, outside the hot loop) ---
INTERVAL_MS="$(warden_cfg '.spinnerIntervalMs' '120')"
STUCK="$(warden_cfg '.stuckAfterSeconds' '300')"
STUCK2="$(warden_cfg '.stuck2AfterSeconds' '900')"
SHOW_ACTIVITY="$(warden_cfg '.showActivity' 'true')"
SHOW_PROJECT="$(warden_cfg '.showProject' 'true')"
SHOW_CONTEXT="$(warden_cfg '.showContext' 'true')"
CTX_WARN="$(warden_cfg '.contextWarnPercent' '75')"
STUCK_GLYPH="$(warden_state_glyph stuck)"
STUCK2_GLYPH="$(warden_state_glyph stuck2)"
MAXLIFE="$(warden_cfg '.maxLifetimeSeconds' '7200')"

# LC_ALL=C so the fractional seconds use a dot, not a locale decimal comma
# (which would make `sleep 0,120` invalid → error → busy loop).
SLEEP_S="$(LC_ALL=C awk -v m="$INTERVAL_MS" 'BEGIN { s = m / 1000; if (s < 0.04) s = 0.04; printf "%.3f", s }')"

# --- Frames: prefer the JSON array; fall back to a baked-in braille set ---
FRAMES=()
if warden_has_jq && [ -f "$(warden_config_file)" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && FRAMES+=("$f")
  done < <(jq -r '.spinnerFrames[]?' "$(warden_config_file)" 2>/dev/null)
fi
if [ "${#FRAMES[@]}" -eq 0 ]; then
  FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧")
fi
NFRAMES="${#FRAMES[@]}"

START_TS="$(warden_now)"
i=0

# Native progress pulse for terminals that support OSC 9;4 (Ghostty/WezTerm).
warden_write_progress "$TTY" 3 0

while :; do
  # Stop animating the moment the render file is gone or the turn ended.
  [ -f "$RENDER" ] || break
  line="$(cat "$RENDER" 2>/dev/null)"
  # Tolerate a transient empty read during an atomic rewrite — retry next tick.
  [ -n "$line" ] || { sleep "$SLEEP_S"; continue; }
  IFS='|' read -r r_state r_project r_activity r_ctx _ <<< "$line"
  [ "$r_state" = "working" ] || break

  elapsed=$(( $(warden_now) - START_TS ))

  # Self-reap on absurdly long runs (e.g. a crashed session whose Stop hook
  # never fired) so we never animate a dead tab indefinitely.
  [ "$elapsed" -ge "$MAXLIFE" ] 2>/dev/null && break

  # Lead = spinner frame, with a stuck marker prepended once it's been a while.
  frame="${FRAMES[$i]}"
  if [ "$elapsed" -ge "$STUCK2" ] 2>/dev/null; then
    lead="$STUCK2_GLYPH $frame"
  elif [ "$elapsed" -ge "$STUCK" ] 2>/dev/null; then
    lead="$STUCK_GLYPH $frame"
  else
    lead="$frame"
  fi

  title="$lead"
  [ "$SHOW_ACTIVITY" = "true" ] && [ -n "$r_activity" ] && title="$title $r_activity"
  [ "$SHOW_PROJECT" = "true" ]  && [ -n "$r_project" ]  && title="$title $r_project"
  if [ "$SHOW_CONTEXT" = "true" ] && [ -n "$r_ctx" ]; then
    if [ "$r_ctx" -ge "$CTX_WARN" ] 2>/dev/null; then
      title="$title ·${r_ctx}%"
    fi
  fi

  warden_write_title "$TTY" "$title"

  i=$(( (i + 1) % NFRAMES ))
  sleep "$SLEEP_S"
done

# Leaving the loop means a state hook took over the title; clear the pulse.
warden_write_progress "$TTY" 0 0
exit 0
