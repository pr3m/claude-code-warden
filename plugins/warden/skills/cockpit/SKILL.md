---
name: warden:cockpit
description: Show the warden fleet view — a glance at every Claude Code session (which are working, which need you, which are done, how long, context fill). Use when the user says "cockpit", "/warden:cockpit", "fleet view", "show my sessions", "what are my agents doing", "who needs me".
---

# /warden:cockpit

Print a one-shot snapshot of the fleet:

```sh
~/.claude/warden/bin/warden status
```

Show the output verbatim.

Then add one line: for a **live** view that redraws every second, the user should
open a dedicated Ghostty split/tab and run `~/.claude/warden/bin/warden cockpit`
(it loops until Ctrl-C, so it belongs in its own pane, not here).

If the command isn't found, warden's `SessionStart` hook hasn't registered the
entry point yet — tell the user to restart Claude Code (or just start a session
in any tab) and retry.
