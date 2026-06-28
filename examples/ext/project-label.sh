#!/bin/bash
# project-label.sh — OPTIONAL warden extension (example template).
#
# Install: copy to ~/.claude/warden/ext/project-label.sh and `chmod +x` it.
# warden calls it with the session's working directory as $1 and uses the first
# line of stdout as the tab's project label (instead of the default git repo
# name). Keep it FAST — it runs once at the start of every turn.
#
# This template shows a CROSS-PROJECT pattern: it's global (one script for all
# your repos — wundamental, redmy, personal, …), and it enriches the label with
# the active ticket pulled from an overarching second brain (e.g. Cortex). The
# universal warden plugin stays generic; this personal glue lives here, at the
# user level, never inside any single project's plugin.

set -u
CWD="${1:-$PWD}"

# --- Base label: the git repo name, else the directory basename. ------------
top="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$top" ]; then label="$(basename "$top")"; else label="$(basename "$CWD")"; fi

# --- Optional: append the active ticket from a cross-project Cortex vault. ---
# Cortex spans every project (Personal / Redmy / Wundamental / …). Map the cwd
# to its Cortex domain, then find the In-Progress ticket scratchpad and tack its
# key onto the label, so the tab reads e.g.  "wunda · WUNDA-627".
#
# Uncomment and point CORTEX at your vault to enable.
#
# CORTEX="$HOME/Cortex"
# case "$CWD" in
#   *"/dev/wunda"*)  domain="Wundamental" ;;
#   *"/dev/redmy"*)  domain="Redmy" ;;
#   *)               domain="" ;;
# esac
# if [ -n "$domain" ] && [ -d "$CORTEX/$domain/tickets" ]; then
#   # First ticket note whose frontmatter marks it In Progress.
#   ticket="$(grep -lR 'status:.*In Progress' "$CORTEX/$domain/tickets" 2>/dev/null \
#             | head -n1 | xargs -I{} basename {} .md 2>/dev/null)"
#   [ -n "$ticket" ] && label="$label · $ticket"
# fi

printf '%s\n' "$label"
