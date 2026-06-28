---
name: warden:config
description: Show or change warden's configuration — glyphs, spinner frames/speed, escalation and stuck thresholds, context meter, what's shown on the tab. Use when the user says "warden config", "/warden:config", "change the spinner", "customize warden glyphs", "warden settings".
---

# /warden:config

Show the current config:

```sh
~/.claude/warden/bin/warden config show
```

The file lives at `~/.claude/warden/config.json`. To change a value, edit that
file directly (or `~/.claude/warden/bin/warden config edit`). Keys:

- `spinner`, `spinnerFrames` (array), `spinnerIntervalMs`
- `showProject`, `showActivity`, `showContext`
- `escalateAfterSeconds`, `escalateReping`
- `stuckAfterSeconds`, `stuck2AfterSeconds`
- `contextWarnPercent`
- `glyphs.{working,needs_you,escalated,stuck,stuck2,done,idle,error}`
- `projectLabelCommand` — a shell command (cwd in `$WARDEN_CWD`) that prints a
  custom project label; overridden by `~/.claude/warden/ext/project-label.sh`.

Changes take effect on the next prompt/turn (the spinner daemon reads config at
launch).
