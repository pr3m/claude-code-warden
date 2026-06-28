---
name: warden:status
description: Quick warden status — a one-shot table of all Claude Code sessions and their states. Use when the user says "warden status", "/warden:status", "session status", "fleet status".
---

# /warden:status

```sh
~/.claude/warden/bin/warden status
```

Show the output verbatim. If it reports no active sessions, that's expected
until a prompt has been submitted in at least one Claude Code tab.
