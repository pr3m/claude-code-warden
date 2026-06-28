---
name: warden:doctor
description: Diagnose warden — checks platform, terminal, tty resolution, jq, config, the status bus, and extension hooks, then paints a test title on the current tab. Use when the user says "warden doctor", "/warden:doctor", "is warden working", "warden isn't showing", "debug warden", "the spinner isn't appearing".
---

# /warden:doctor

```sh
~/.claude/warden/bin/warden doctor
```

Show the output verbatim, then interpret:

- **tty resolved : FAILED** → warden can't find the terminal device; titles won't
  paint. Usually means it's running somewhere without a real PTY.
- **jq present : NO** → install `jq` (`brew install jq`); the context meter and
  cockpit need it (spinner + glyphs still work).
- **terminal : unknown** → the OSC core still works; only terminal-specific
  adapter touches (Ghostty progress pulse, iTerm2 tab color) are skipped.
- The **live title test** should make the current tab read `🛡 warden` briefly.
  If it doesn't, the terminal may have a frozen title (e.g. Ghostty `title=` set,
  or Claude Code's own title override winning — see the README troubleshooting).
