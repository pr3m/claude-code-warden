#!/bin/bash
# on-state.sh — OPTIONAL warden extension (example template).
#
# Install: copy to ~/.claude/warden/ext/on-state.sh and `chmod +x` it.
# warden invokes it on every state transition (working / needs_you / done) and
# pipes the full session bus JSON to stdin. It runs DETACHED and fire-and-forget,
# so it never blocks or slows a Claude Code turn — but keep it quick anyway.
#
# This is the seam for personal, cross-project reactions: log to a second brain,
# post to Slack when a long job needs you, append to a tracker, etc. It's global
# (user-level), so one script serves every project.
#
# Session JSON shape:
#   { "id", "state", "project", "activity", "tty", "cwd",
#     "started", "prompt", "ctx", "needs_since", "updated" }

set -u

# Need jq to parse; degrade silently if absent.
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
state="$(printf '%s' "$payload" | jq -r '.state // ""')"
project="$(printf '%s' "$payload" | jq -r '.project // ""')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"

# --- Example 1: a simple cross-project activity log. ------------------------
log="$HOME/.claude/warden/state-history.log"
printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$state" "$project" >> "$log" 2>/dev/null || true

# --- Example 2: notify on a *new* needs-you (uncomment to enable). ----------
# Fires a desktop notification the moment a session blocks on you — handy when
# the tab is on another monitor/Space. (warden's own escalation handles nagging.)
#
# if [ "$state" = "needs_you" ] && [ "$(uname -s)" = "Darwin" ]; then
#   # SECURITY: never interpolate $project straight into `osascript -e` — a
#   # crafted directory name (project label) could inject AppleScript and run
#   # arbitrary commands. Pass it via the environment and read it inside
#   # AppleScript with `system attribute`, so the value stays data, not code.
#   WARDEN_PROJECT="$project" osascript \
#     -e 'display notification ((system attribute "WARDEN_PROJECT") & " needs your input") with title "warden"' \
#     >/dev/null 2>&1 || true
# fi

# --- Example 3: append to a Cortex (or other) second-brain note. ------------
# CORTEX="$HOME/Cortex"
# if [ "$state" = "done" ] && [ -d "$CORTEX" ]; then
#   # ...append a one-line build-log entry, post to a tracker, etc.
#   :
# fi

exit 0
