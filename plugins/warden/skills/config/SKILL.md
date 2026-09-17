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
- `waitingFrames` (array), `waitingIntervalMs` — the slow animation for a session
  waiting on subagents or background shells. Keep it visibly slower than the
  spinner: the contrast between the two is what tells the states apart at a glance
- `keeperIntervalSeconds` — how often a static tab (`✅`/`❓`) is repainted, so
  Claude Code's own `✳ <task summary>` title cannot take the tab back
- `showProject`, `showActivity`, `showContext`
- `escalateAfterSeconds`, `escalateReping`, `escalateMaxSeconds`
- `stuckAfterSeconds`, `stuck2AfterSeconds` — seconds since the last tool call or
  return (a progress heartbeat), **not** since the turn started
- `slowToolAfterSeconds` — how long a single tool may run before ⏳
- `contextWarnPercent`, `contextRefreshSeconds`
- `maxLifetimeSeconds` — crash backstop for the animator, not a turn limit
- `glyphs.{working,waiting,needs_you,escalated,stuck,stuck2,done,idle}`
- `projectLabelCommand` — a shell command (cwd in `$WARDEN_CWD`) that prints a
  custom project label; overridden by `~/.claude/warden/ext/project-label.sh`.

Changes take effect within a second or two — the animator re-reads the file when
its mtime changes, so you can tune the spinner speed and watch the tab settle.

**If the tab feels busy**, the knob that matters is `showActivity: false`. The
activity glyph changes on every tool call and return, so on a fast turn it
flickers between 🧠 and 🔧 several times a second — turning it off leaves the
tab calm, and the detail is still in `/warden:cockpit`.

**If you track your time**, leave `spinnerFrames` and `waitingFrames` at one
frame each (the default). A desktop tracker — Toggl, RescueTime, Timing —
samples the foreground window title and counts every repaint as input, so an
animated spinner makes an unattended overnight run look like hours at the
keyboard. `showActivity: true` does the same thing on a smaller scale. Holding
the title still costs nothing: liveness rides the OSC 9;4 progress pulse, which
never touches the title, and the state glyphs still change on every real
transition.
