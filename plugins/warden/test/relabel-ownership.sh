#!/bin/bash
# relabel-ownership.sh — warden_relabel_tty must paint the owning session only.
#
# A tty outlives the sessions that used it: the OS recycles /dev/ttysNNN and
# every past session keeps a record naming that device. The relabel loop finds
# sessions by tty, so without an ownership guard it paints one title per record
# — each label derived from that record's own cwd — and a live tab flickers
# through the labels of dead sessions. A desktop activity tracker samples the
# title and books every repaint as input, so an unattended run reads as work.
#
# Guards both halves of warden_owns_tty: a definite different owner is skipped,
# and a missing owner file stays tolerant (paints, never silences a live tab).
#
#   bash plugins/warden/test/relabel-ownership.sh

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"

SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
trap 'rm -rf "$SANDBOX" 2>/dev/null' EXIT

mkdir -p "$SANDBOX/.claude/warden"
printf '{"spinner": false, "showContext": false}\n' > "$SANDBOX/.claude/warden/config.json"

# shellcheck source=../bin/helpers.sh
. "$BIN/helpers.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n     expected [%s] got [%s]\n' "$1" "$2" "$3"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

printf 'relabel-ownership\n'

if ! warden_has_jq; then
  printf '  SKIP  jq not installed\n'
  exit 0
fi

SESS="$(warden_sessions_dir)"; mkdir -p "$SESS"
TTY="$SANDBOX/faketty"

# The real writer redirects with `>`, which truncates: a plain file would hold
# only the last title and every count would read 1 — green whatever the loop
# did. Record the calls instead. What is under test is which sessions the loop
# iterates; the OSC bytes themselves are covered by animator.sh.
TITLE_LOG="$SANDBOX/titles"; : > "$TITLE_LOG"
warden_write_title() { printf '%s\n' "${2:-}" >> "$TITLE_LOG"; }

# Three sessions that all named this device, in three different projects. Only
# `live` still exists; `ghostA`/`ghostB` are the recycled-device leftovers.
for s in live:alpha ghostA:bravo ghostB:charlie; do
  id="${s%%:*}"; proj="${s##*:}"
  mkdir -p "$SANDBOX/$proj"
  printf '{"id":"%s","tty":"%s","cwd":"%s","project":"%s","state":"idle"}\n' \
    "$id" "$TTY" "$SANDBOX/$proj" "$proj" > "$SESS/$id.json"
done

paints() { wc -l < "$TITLE_LOG" | tr -d ' '; }

# --- a definite different owner is skipped ---------------------------------
printf 'live\n' > "$(warden_owner_path "$TTY")"
: > "$TITLE_LOG"
warden_relabel_tty "$TTY"
is "owned tty is painted exactly once" "1" "$(paints)"

case "$(cat "$TITLE_LOG")" in
  *alpha*) ok "the painted label is the owner's project" ;;
  *)       no "the painted label is the owner's project" "alpha" "$(cat "$TITLE_LOG")" ;;
esac
case "$(cat "$TITLE_LOG")" in
  *bravo*|*charlie*) no "a dead session's label never bleeds through" "no bravo/charlie" "$(cat "$TITLE_LOG")" ;;
  *)                 ok "a dead session's label never bleeds through" ;;
esac

# --- the guard is tolerant when ownership is unknown ------------------------
rm -f "$(warden_owner_path "$TTY")"
: > "$TITLE_LOG"
warden_relabel_tty "$TTY"
is "unclaimed tty still repaints every session" "3" "$(paints)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
