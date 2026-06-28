---
name: warden:install
description: Explain how warden works and how to get it running — it's automatic once installed (no setup), this skill confirms it and shows how to customize. Use when the user says "warden install", "/warden:install", "how do I set up warden", "how does warden work", "get warden running".
---

# /warden:install

warden is **hook-driven — there's no install step beyond enabling the plugin**.
Once installed, its hooks fire on every Claude Code session automatically.

Confirm it's live:

```sh
~/.claude/warden/bin/warden doctor
```

Explain to the user:

1. **It just works** — submit a prompt in any Claude Code tab and watch the tab
   title: an animated spinner while Claude works, an activity glyph (🔧 bash /
   🧪 tests / 📖 read / ✏️ edit / 🌐 web / 🧠 thinking / 🤖 subagent), ❓ when
   Claude needs you (escalating to ‼️ if ignored), ✅ when done.
2. **Fleet view** — `/warden:cockpit` (or `~/.claude/warden/bin/warden cockpit`
   in its own pane) shows every session at a glance.
3. **Customize** — `/warden:config` for glyphs, spinner, and thresholds.
4. **Extend (advanced)** — drop `~/.claude/warden/ext/project-label.sh` to set a
   custom per-project label (e.g. include the active ticket), or
   `~/.claude/warden/ext/on-state.sh` to react to every state change (read the
   session JSON on stdin). See the README's "Extending warden" section.

If titles don't appear, run `/warden:doctor` and check the README troubleshooting
(Claude Code's own title override, Ghostty `title=`, or tmux passthrough).
