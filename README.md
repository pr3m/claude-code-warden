# 🛡 claude-code-warden

**Keep watch over a fleet of parallel Claude Code sessions — right from your terminal tabs.**

You run Claude Code in a dozen tabs. Which ones are working? Which finished?
Which is quietly blocked waiting for your permission while you stare at a
different tab? warden answers all three at a glance, without you switching tabs:

```
  ⠙ 🔧 wunda            ← spinning: working, running a bash command
  ⠹ 🧪 redmy            ← spinning: working, running tests
  ❓ wundamental-web    ← needs you (permission / input) — escalates if ignored
  🐢 ⠼ 🤖 mia           ← still working, but this turn is dragging
  ✅ smartbeat          ← done, your move
  · personal           ← idle
```

An animated spinner rides each tab while Claude works, a glyph tells you *what
kind* of work, a needs-you alarm escalates so nothing waits unnoticed, and
`/warden:cockpit` gives you the whole fleet in one view. **Be in the pilot seat.**

> Ghostty-first — but the core is standard terminal escape sequences, so it works
> in **iTerm2, Terminal.app, and tmux** too.

---

## Install

```
/plugin marketplace add pr3m/claude-code-warden
/plugin install warden
```

That's it — no config, no setup. warden is hook-driven: it starts working the
moment you submit your next prompt in any Claude Code tab. (`jq` recommended:
`brew install jq` — the spinner and glyphs work without it; the context meter and
cockpit need it.)

Verify: `/warden:doctor`.

---

## What you get

### Tab states

| Glyph | State | When |
|------:|-------|------|
| `⠙` (animated) | **working** | Claude is on your turn |
| `🔧 🧪 📖 ✏️ 🔎 🌐 🤖 🧠` | **activity** | what kind of work, from the tool in flight |
| `❓` | **needs you** | Claude asked for permission/input |
| `‼️` | **escalated** | still waiting after `escalateAfterSeconds` (+ re-ping) |
| `🐢` / `⏳` | **stuck** | the turn has been running a long time |
| `✅` | **done** | turn finished — your move |
| `·` | **idle** | session open, nothing running |

Each tab also shows the **project** (git repo name by default) and, past a
threshold, the **context-window fill** (`·78%`) so auto-compaction never
surprises you.

### The cockpit

```
/warden:cockpit
```

```
🛡  warden · 2 working · 1 need you · 1 done · 1 idle

   ❓  needs_you  wundamental-web      2m         what should the CTA say?
   ⚙   working    wunda          🔧   14s   78%   fix the SOF marker map
   ⚙   working    redmy          🧪   1m          add the retry tests
   ✅  done       smartbeat            -          reconcile the LHV export
   ·   idle       personal             -
```

Blocked sessions float to the top. For a live view that redraws every 2s,
run `~/.claude/warden/bin/warden cockpit` in its own Ghostty split.

### Renaming a tab

warden owns the tab title so it can animate the spinner — which means a native
terminal rename gets overwritten on the next tick. Set a **custom label** that
warden keeps decorating with the live glyph instead:

```
/warden:label WUNDA-627 portal      # or: warden label "WUNDA-627 portal"
```

→ the tab reads `⚙ 🔧 WUNDA-627 portal` while working, `✅ WUNDA-627 portal` when
done. The label persists across turns and session resume, per tab.

```
warden label              # show the current label
warden label --clear      # back to the auto label (git repo / dir name)
WARDEN_LABEL="My tab" claude   # name it at launch
```

Precedence: an explicit label → `$WARDEN_LABEL` → the auto label. To rename a
*background* session you see in the cockpit: `warden label --session <id> "Name"`.

---

## How it works

warden is pure Claude Code hooks + standard terminal escape sequences. No
background services beyond a tiny per-session spinner while a turn is active.

```
 UserPromptSubmit ─► working  ─► start spinner daemon ─┐
 PreToolUse       ─► activity glyph / resume-after-permission
 Notification     ─► ❓ needs you ─► start escalation timer
 Stop             ─► ✅ done      ─► stop daemons
                                   │
                 each transition ──┼──► STATUS BUS  ~/.claude/warden/sessions/<id>.json
                                   └──► OSC 0 title  ─► your terminal tab
```

- **OSC 0**, not OSC 1 — Ghostty (and others) honor `ESC ] 0 ; … BEL` for the
  tab; OSC 1 is ignored on Ghostty ([ghostty#1026](https://github.com/ghostty-org/ghostty/issues/1026)).
- The spinner reads a cheap per-session render file each frame (no `jq` in the
  hot loop) and resolves the terminal's real device (`/dev/ttysNNN`) so it can
  paint a tab even when that tab isn't focused.
- On Ghostty/WezTerm it also emits an **OSC 9;4** native progress pulse on the
  focused tab; a no-op elsewhere.

---

## Configuration

`~/.claude/warden/config.json` (created on first run). `/warden:config` to view.

| Key | Default | Meaning |
|-----|---------|---------|
| `spinner` | `true` | animate the tab while working |
| `spinnerFrames` | braille | array of frames — try `["🌑","🌒","🌓","🌔","🌕","🌖","🌗","🌘"]` |
| `spinnerIntervalMs` | `120` | frame interval |
| `showProject` / `showActivity` / `showContext` | `true` | what rides the tab |
| `escalateAfterSeconds` | `45` | needs-you → escalated threshold (`0` = off) |
| `escalateReping` | `true` | re-ping the system sound on escalation |
| `stuckAfterSeconds` / `stuck2AfterSeconds` | `300` / `900` | 🐢 / ⏳ thresholds |
| `contextWarnPercent` | `75` | only show the context meter past this |
| `glyphs.*` | see above | override any state glyph |
| `projectLabelCommand` | — | a shell command (`$WARDEN_CWD`) printing a label |

---

## Extending warden

warden's core stays universal. Your personal, cross-project behavior plugs in at
the **user level** via three layers — never by forking the plugin:

1. **Config** — the table above (glyphs, frames, thresholds).
2. **Drop-in extension scripts** at `~/.claude/warden/ext/` (see [`examples/ext/`](examples/ext/)):
   - **`project-label.sh`** — gets the cwd as `$1`, prints a custom tab label.
     Use it to map a repo to its active ticket from a second brain, so a tab can
     read `wunda · WUNDA-627`. It's global, so one script serves every project.
   - **`on-state.sh`** — gets the session JSON on stdin on every transition
     (detached, non-blocking). React however you like: log it, notify, append to
     a tracker.
3. **The status bus** — `~/.claude/warden/sessions/<id>.json` is a documented
   contract. Because Claude Code merges hooks across plugins, a *separate* plugin
   can subscribe to the same events and read the bus — fully decoupled.

Status bus schema:

```json
{ "id": "…", "state": "working|needs_you|done|idle",
  "project": "wunda", "activity": "🔧", "tty": "/dev/ttys003",
  "cwd": "…", "started": "1719582000", "prompt": "fix the …",
  "ctx": "78", "needs_since": "", "updated": "1719582012" }
```

---

## Terminal support

| Terminal | Tab spinner + glyphs (OSC 0) | Progress pulse (OSC 9;4) | Adapter extras |
|----------|:---:|:---:|---|
| **Ghostty** ≥ 1.2 | ✅ | ✅ | — |
| **WezTerm** | ✅ | ✅ | — |
| **iTerm2** | ✅ | — | tab color / badge / jump-to-tab *(roadmap)* |
| **Terminal.app** | ✅ | — | — |
| **VS Code** terminal | ✅ | — | — |
| **tmux** | ✅¹ | ✅¹ | — |

¹ tmux needs `set -g allow-passthrough on`.

---

## Troubleshooting

- **Titles flicker between warden's and Claude's own** — Claude Code sets the tab
  title too. warden owns it during a turn, but if they fight, try
  `export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` in your shell rc. See the open
  Claude Code requests [#29349](https://github.com/anthropics/claude-code/issues/29349),
  [#22578](https://github.com/anthropics/claude-code/issues/22578).
- **Nothing appears in Ghostty** — make sure you don't have `title = …` pinned in
  your Ghostty config (it freezes escape-sequence titles). Run `/warden:doctor`.
- **In tmux** — add `set -g allow-passthrough on` to `~/.tmux.conf`.
- **`tty resolved : FAILED`** — warden couldn't find a real PTY; titles won't
  paint. Run `/warden:doctor` for details.

---

## Roadmap

- **Phase 2 — interactive cockpit TUI**: cursor through sessions, jump to a tab,
  per-session history/timeline, all on the same status bus.
- **iTerm2 adapter**: native tab background-color flash on needs-you, a "needs
  input" badge, and true auto-focus/jump via the iTerm2 Python API.
- **Menubar fleet indicator** (SwiftBar/xbar): `🟢2 🟡1 🔴1`, always visible.
- **kitty / WezTerm adapters**, configurable sound packs, done-with-summary tab.

---

## Built by

[Christjan Schumann](https://github.com/pr3m) — also
[claude-code-roam](https://github.com/pr3m/claude-code-roam) and
[claude-code-bash-smart-approve](https://github.com/pr3m/claude-code-bash-smart-approve).

MIT licensed. PRs welcome — especially terminal adapters.
