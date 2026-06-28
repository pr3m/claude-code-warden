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
case "$MODEL" in
  *1m*) MAX="$(warden_cfg '.contextMax1m' '1000000')" ;;
  *)    MAX="$(warden_cfg '.contextMax' '200000')" ;;
esac

awk -v u="$USED" -v m="$MAX" 'BEGIN {
  if (m + 0 <= 0) exit
  p = int(100 * u / m + 0.5)
  if (p < 0) p = 0
  if (p > 100) p = 100
  printf "%d", p
}'
