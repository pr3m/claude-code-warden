# Changelog

All notable changes to **warden** are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow semver.

## [0.1.4] — unreleased

### Fixed / Docs
- **Document the required `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` setup.** Claude
  Code writes its own terminal title (hardcoded `·` while working, `✳` when
  idle) and overwrites warden's the instant a turn ends — so warden's label/glyph
  appeared to "not stick" in the real terminal tab even though warden wrote it
  correctly. warden can't beat an event-driven write from a hook, so Claude's
  title management must be turned off. Install + Troubleshooting + the
  `/warden:install` skill now make this the required first step (env block in
  `~/.claude/settings.json`).
- **`warden doctor`** now reports whether `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` is
  set (`CC title write: disabled` vs a loud `ENABLED — Claude Code overwrites
  warden titles!`).

## [0.1.3] — unreleased

### Added
- **Custom tab labels.** Rename a tab without losing the warden glyph. warden
  owns the title (to animate it), so a native terminal rename gets clobbered;
  instead set a label warden keeps decorating with the live indicator:
  - `/warden:label "My feature"` skill, or `warden label "My feature"` — set
  - `warden label --clear` — back to the auto label (git repo / dir)
  - `warden label` — show the current label
  - `WARDEN_LABEL="My tab" claude` — name it at launch
  - `warden label --session <id> "Name"` — rename another session's tab (fleet)

  Precedence: explicit label → `$WARDEN_LABEL` → auto. Keyed per terminal tab,
  so it persists across turns and session resume until cleared. Setting it
  applies live (a running spinner picks it up next tick). `warden clean` and
  `--clear` remove it.

## [0.1.2] — unreleased

Hardening pass from a multi-reviewer code review (incl. an independent codex pass).

### Security
- **Terminal-escape (OSC) injection fixed.** Project labels (derived from a
  directory name, git repo, or a custom resolver) and the prompt summary are now
  stripped of control bytes (`warden_strip_controls`) before reaching the tab
  title or the bus — a crafted directory name can no longer inject OSC 52
  clipboard writes or other escape sequences.
- **Path traversal fixed.** `session_id` is sanitized to a filename-safe form, so
  it can't escape the sessions dir (e.g. `../../config`).
- **Status files are now private** (`umask 077`).
- **Example `ext/on-state.sh`** no longer interpolates `$project` into
  `osascript -e` (would have been an injection if copied); it passes it via the
  environment instead.

### Fixed
- **Long sessions no longer break the spinner.** `warden-context.sh` read the
  *whole* transcript (`jq -rs`); on a multi-MB transcript that blew the 5s hook
  timeout, so on-prompt/on-stop got killed and the spinner never started/stopped.
  It now reads only the tail.
- **Compaction no longer blanks the tab.** `SessionStart` fires on `compact`
  mid-turn; warden now detects `source=compact` and preserves live state instead
  of reaping the spinner and resetting to idle.
- **Escalation alarms no longer stack.** Repeated Notifications replaced the old
  escalate daemon (duplicate sounds + orphans); a Notification after a clean
  finish no longer flips ✅→❓.
- **Spinner singleton** via an atomic `mkdir` lock + clean kill semantics — two
  daemons can never animate the same tab; orphans self-reap (max-lifetime cap).
- Dropped `export` of the hook payload (could trip `ARG_MAX`/`E2BIG` on huge
  prompts); validated PIDs before `kill`; `LC_ALL=C` for the locale-safe sleep
  interval; escaped the no-jq JSON fallback; cockpit uses one `jq` per file
  instead of nine, homes the cursor on the first frame, and restores it on any
  exit.

### Notes
- Confirmed: warden makes **zero LLM calls** and injects nothing into the
  context window — it costs no Claude Code tokens.

## [0.1.1] — unreleased

### Fixed
- **Tab no longer flashes "randomly" while working.** Two causes: (1) the
  PostToolUse hook reset the glyph to 🧠 between every tool, so it flickered
  against the per-tool activity glyph — removed (the activity glyph now persists
  stably); (2) PreToolUse could race PreToolUse-vs-prompt and spawn a *second*
  spinner daemon writing offset frames — it now only (re)launches on a genuine
  resume-after-permission, never on the normal first tool of a turn.
- **`warden cockpit` no longer flashes.** The live view did a full-screen `clear`
  each tick; it now redraws in place (cursor-home + erase-to-EOL), flicker-free,
  and refreshes every 2s.

### Changed
- CLI entry point resolves through its symlink (readlink walk) so the skills find
  `helpers.sh`/`cockpit.sh` regardless of install path.

## [0.1.0] — unreleased

Initial release.

### Added
- **Animated spinner** on each terminal tab while Claude works — a per-session
  braille daemon that writes OSC 0 title frames (~120ms), killed when the turn
  ends or pauses.
- **Activity-aware glyph** derived from `PreToolUse`: 🔧 bash · 🧪 tests · 📖 read
  · ✏️ edit · 🔎 search · 🌐 web · 🤖 subagent · 🧠 thinking.
- **Needs-you state** (❓) on `Notification`, with **escalation** to ‼️ + a
  re-ping if you don't respond — a blocked background session never waits unseen.
  Resume-after-permission is detected (the next tool flips it back to working).
- **Stuck detection** — long-running turns shift ⚙→🐢→⏳.
- **Done state** (✅) on `Stop`.
- **Best-effort context-window meter** shown on the tab past a threshold.
- **Status bus** at `~/.claude/warden/sessions/<id>.json` — the documented public
  contract other tools/plugins can read.
- **Cockpit** — `/warden:cockpit` (and `warden cockpit` live view) showing the
  whole fleet at a glance, blocked sessions first.
- **Skills** — `/warden:cockpit`, `:status`, `:config`, `:doctor`, `:install`,
  `:uninstall`.
- **Extension seam** — `ext/project-label.sh` (custom per-project label) and
  `ext/on-state.sh` (react to every transition); examples included.
- **Terminal adapters** — Ghostty OSC 9;4 progress pulse; portable OSC 0 core for
  iTerm2 / Terminal.app / tmux (passthrough-aware).

[0.1.0]: https://github.com/pr3m/claude-code-warden/releases/tag/v0.1.0
