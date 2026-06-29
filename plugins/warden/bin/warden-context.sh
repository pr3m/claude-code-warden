#!/bin/bash
# warden-context.sh — best-effort context-window fill estimate.
# Reads the session transcript (JSONL), takes the latest assistant usage entry,
# sums the tokens that occupy the context window (input + cache read + cache
# creation), and expresses it as a percentage of the model's context limit.
#
# This is an APPROXIMATION — token accounting and the real compaction threshold
# are internal to Claude Code. Prints an integer percentage, or nothing if it
# can't be determined. Usage: warden-context.sh <transcript_path>

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$DIR/helpers.sh"

TRANSCRIPT="${1:-}"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
warden_has_jq || exit 0

# Only the LAST usage entry matters, and it lives near the end of the file.
# Read just the tail (last 512 KB) instead of slurping the whole transcript —
# transcripts grow to many MB and `jq -rs` over the full file would blow the
# 5s hook timeout (killing the hook → spinner never starts/stops). Parse each
# line with fromjson? so the partial first line from the byte-cut is ignored.
TAIL="$(tail -c 524288 "$TRANSCRIPT" 2>/dev/null)"

USED="$(printf '%s' "$TAIL" | jq -rR '
  fromjson?
  | select(.message.usage.input_tokens != null)
  | ( .message.usage.input_tokens
      + (.message.usage.cache_read_input_tokens // 0)
      + (.message.usage.cache_creation_input_tokens // 0) )
' 2>/dev/null | tail -n1)"
[ -n "$USED" ] || exit 0

MODEL="$(printf '%s' "$TAIL" | jq -rR 'fromjson? | .message.model // empty' 2>/dev/null | tail -n1)"
CWD="$(printf '%s' "$TAIL" | jq -rR 'fromjson? | .cwd // empty' 2>/dev/null | tail -n1)"

STD_MAX="$(warden_cfg '.contextMax' '200000')"
BIG_MAX="$(warden_cfg '.contextMax1m' '1000000')"
OVERRIDE="$(warden_cfg '.contextWindowOverride' '')"

# Pick the denominator (the true context window). The [1m] 1M tier is invisible
# to a hook: the transcript's per-message model is the bare base id (e.g.
# "claude-opus-4-8"), the environment carries no model, and only ~/.claude.json
# persists the full "<base>[1m]" id (under projects[cwd].lastModelUsage). So:
#   1. an explicit .contextWindowOverride wins outright;
#   2. else treat as 1M if the model field itself carries a 1m marker, or if
#      Claude Code recorded a "<base>[1m]" usage for this project;
#   3. else the standard window — auto-upgraded to the 1M tier when observed
#      usage already exceeds it (a turn can't use more tokens than its window).
if [ -n "$OVERRIDE" ] && [ "$OVERRIDE" -gt 0 ] 2>/dev/null; then
  MAX="$OVERRIDE"
else
  is1m=no
  case "$MODEL" in *1m*) is1m=yes ;; esac
  if [ "$is1m" = no ] && [ -n "$MODEL" ] && [ -n "$CWD" ] && warden_has_jq && [ -f "$HOME/.claude.json" ]; then
    if jq -e --arg b "$MODEL" --arg c "$CWD" '
         (.projects[$c].lastModelUsage // {} | keys[])
         | select(startswith($b) and test("1m"))
       ' "$HOME/.claude.json" >/dev/null 2>&1; then
      is1m=yes
    fi
  fi
  if [ "$is1m" = yes ]; then
    MAX="$BIG_MAX"
  else
    MAX="$STD_MAX"
    [ "$USED" -gt "$MAX" ] 2>/dev/null && MAX="$BIG_MAX"
  fi
fi

awk -v u="$USED" -v m="$MAX" 'BEGIN {
  if (m + 0 <= 0) exit
  p = int(100 * u / m + 0.5)
  if (p < 0) p = 0
  if (p > 100) p = 100
  printf "%d", p
}'
