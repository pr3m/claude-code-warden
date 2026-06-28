#!/bin/bash
# cockpit.sh — the fleet view. Reads every session in the status bus and prints
# a one-glance table: state · project · activity · elapsed · context · prompt.
# Blocked (needs-you) sessions float to the top. `--watch` redraws every second.
#
# This is the v1 cockpit — a read-only renderer over the documented status bus.
# The richer interactive TUI (jump-to-tab, history) is Phase 2 and builds on the
# exact same bus, so it's a drop-in, not a rewrite.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$DIR/helpers.sh"

WATCH=0
[ "${1:-}" = "--watch" ] && WATCH=1

dur() {
  local s="${1:-0}"
  [ "$s" -lt 0 ] 2>/dev/null && s=0
  if [ "$s" -gt 172800 ] 2>/dev/null; then printf '>2d'; return; fi
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
  else printf '%dh%dm' $((s / 3600)) $(((s % 3600) / 60)); fi
}

render() {
  local dir now working needs done idle rows
  dir="$(warden_sessions_dir)"
  now="$(warden_now)"
  working=0; needs=0; ndone=0; idle=0; rows=""
  local stale; stale="$(warden_cfg '.staleDisplaySeconds' '86400')"

  if ! warden_has_jq; then
    printf 'warden cockpit needs jq to read the status bus. Install jq and retry.\n'
    return
  fi

  shopt -s nullglob 2>/dev/null || true
  for f in "$dir"/*.json; do
    local id state project activity started needs_since prompt ctx updated rf el k ctxs line
    # One jq spawn per file instead of nine — at 20 sessions × 2s that's the
    # difference between 10 and 90 jq processes per redraw.
    line="$(jq -r '[.id, .updated, .state, .project, .activity, .started, .needs_since, .ctx, .prompt] | map(. // "") | @tsv' "$f" 2>/dev/null)"
    IFS=$'\t' read -r id updated state project activity started needs_since ctx prompt <<< "$line"
    [ -n "$id" ] || continue
    [ -n "$state" ] || state="idle"
    # Skip zombies — sessions whose state stopped advancing long ago (e.g. a
    # session that crashed mid-turn and never emitted Stop).
    if [ -n "$updated" ] && [ $((now - updated)) -gt "$stale" ] 2>/dev/null; then continue; fi

    # Live override from the render file (more current than the bus mid-turn).
    rf="$(warden_render_file "$id")"
    if [ -f "$rf" ]; then
      IFS='|' read -r rstate rproject ractivity rctx _ < "$rf" 2>/dev/null
      [ -n "$rstate" ]    && state="$rstate"
      [ -n "$rproject" ]  && project="$rproject"
      [ -n "$ractivity" ] && activity="$ractivity"
      [ -n "$rctx" ]      && ctx="$rctx"
    fi

    el=""
    if [ "$state" = "working" ] && [ -n "$started" ]; then el="$(dur $((now - started)))"; fi
    if [ "$state" = "needs_you" ] && [ -n "$needs_since" ]; then el="$(dur $((now - needs_since)))"; fi
    ctxs=""; [ -n "$ctx" ] && ctxs="${ctx}%"

    case "$state" in
      working)   working=$((working + 1)); k=1 ;;
      needs_you) needs=$((needs + 1));     k=0 ;;
      done)      ndone=$((ndone + 1));     k=2 ;;
      *)         idle=$((idle + 1));       k=3 ;;
    esac

    rows="${rows}${k}|$(warden_state_glyph "$state")|${state}|${project}|${activity}|${el}|${ctxs}|${prompt}
"
  done

  printf '🛡  warden · %s working · %s need you · %s done · %s idle\n\n' "$working" "$needs" "$ndone" "$idle"
  if [ -z "$rows" ]; then printf '   (no active sessions yet — submit a prompt in a Claude Code tab)\n'; return; fi

  printf '%s' "$rows" | sort -t'|' -k1,1n | while IFS='|' read -r _k glyph state project activity el ctx prompt; do
    [ -n "$state" ] || continue
    printf '   %s  %-10s %-14s %-3s %-6s %-5s %s\n' \
      "$glyph" "$state" "$project" "$activity" "$el" "$ctx" "$prompt"
  done
}

if [ "$WATCH" = 1 ]; then
  # Flicker-free redraw: hide cursor, then each tick home the cursor and
  # overwrite in place (erase-to-EOL per line + erase-below). No full-screen
  # clear, so no blank flash between frames.
  printf '\033[?25l'                                   # hide cursor
  # Restore the cursor however we exit — signals AND normal/error exit (a bad
  # arithmetic or malformed state shouldn't leave the cursor hidden).
  trap 'printf "\033[?25h"' EXIT
  trap 'exit 0' INT TERM HUP
  printf '\033[2J\033[H'                               # initial clear + home
  while :; do
    out="$(render)"
    printf '\033[H'                                    # cursor home (no clear)
    printf '%s\n' "$out" | while IFS= read -r ln; do printf '%s\033[K\n' "$ln"; done
    printf '\033[J'                                    # erase any leftover lines
    printf '   (updating every 2s — Ctrl-C to exit)\033[K'
    sleep 2
  done
else
  render
fi
