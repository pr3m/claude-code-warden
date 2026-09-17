# 🛡 claude-code-warden

**Keep watch over a fleet of parallel Claude Code sessions — right from your terminal tabs.**

You run Claude Code in a dozen tabs. Which ones are working? Which finished?
Which is quietly blocked waiting for your permission while you stare at a
different tab? warden answers all three at a glance, without you switching tabs:

```
  ⠙ 🔧 wunda            ← spinning: working, running a bash command
  ⠹ 🧪 redmy            ← spinning: working, running tests
  ❓ wundamental-web    ← needs you (permission / input) — escalates if ignored
  🐢 ⠼ 🤖 mia           ← nothing has happened for a while — worth a look
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

**One required step:** Claude Code writes its own terminal title (`·` working,
`✳` idle) and will overwrite warden's. Turn it off in `~/.claude/settings.json`
(top level), then restart your sessions:

```json
"env": {
  "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"
}
```

(Official env var, [confirmed by Anthropic](https://x.com/bcherny/status/2007957770725949686).
Without it the spinner still shows *while a turn runs*, but warden's label/`✅`
vanishes the instant the turn ends and Claude repaints the title.)

Otherwise no config: warden is hook-driven and starts on your next prompt in any
tab. (`jq` recommended: `brew install jq` — the spinner and glyphs work without
it; the context meter and cockpit need it.)

Verify: `/warden:doctor` (it reports whether the title override is disabled).

---

## What you get

### Tab states

| Glyph | State | When |
|------:|-------|------|
| `⠙` (animated, fast) | **working** | Claude is on your turn |
| `🔧 🧪 🧹 📖 ✏️ 🔎 🌐 🤖 🗒️ ⚡ 🔌 🧠` | **activity** | what kind of work, from the tool in flight (`🧠` = thinking, no tool running) |
| `◓` (animated, slow) | **waiting** | the turn ended but subagents (`🤖`) or background shells (`🐚`) are still running — it will wake itself, you are not needed |
| `❓` | **needs you** | Claude asked for permission/input |
| `‼️` | **escalated** | still waiting after `escalateAfterSeconds` (+ re-ping) |
| `🐢` | **stalled** | nothing has happened for `stuckAfterSeconds`, and no tool is running |
| `⏳` | **stalled longer** | same, past `stuck2AfterSeconds` — or a single tool has run for `slowToolAfterSeconds` (a command hung on stdin looks exactly like this) |
| `✅` | **done** | turn finished — your move |
| `·` | **idle** | session open, nothing running |

**A moving tab never wants your attention.** The two animated states both mean
"leave it alone" — fast for a turn in progress, slow for background work you
already asked for. Only the static glyphs are addressed to you. That is the
whole triage rule: if it moves, skip it.

**warden repaints even when nothing changes.** Claude Code writes the tab title
itself (`✳ <task summary>`) and there is no setting to stop it, so a title
painted once is gone by the time you look. The animator therefore lives as long
as the session and repaints static states every `keeperIntervalSeconds` — that
is what keeps a `✅` or `❓` on the tab instead of a title that tells you nothing
about which of your twelve tabs needs a human.

**`🐢` measures progress, not duration.** An agent may legitimately work for
hours; what matters is whether anything is still happening. warden beats a
heartbeat on every tool call and every tool return, and a tool that is genuinely
executing suppresses the stall markers — so a 20-minute test suite spins happily,
while a session that went quiet five minutes ago flags itself.

Each tab also shows the **project** (git repo name by default) and, past a
threshold, the **context-window fill** (`·78%`) so auto-compaction never
surprises you. The meter is recomputed *during* the turn, so it warns you on the
turn that crosses the threshold rather than after it.

### The cockpit

```
/warden:cockpit
```

```
🛡  warden · 2 working · 1 need you · 1 stalled · 1 done · 1 idle

   ‼️   escalated  wundamental-web      4m         what should the CTA say?
   ❓  needs_you  mia                  2m         approve the migration?
   🐢  stalled    sage           📖   6m    41%   trace the booking webhook
   ⚙   working    wunda          🔧   14s   78%   fix the SOF marker map
   ⏳  slow op    redmy          🧪   22m         add the retry tests
   ✅  done       smartbeat            -          reconcile the LHV export
   ·   idle       personal             -
```

Rows are ranked by what needs a human first: escalated, then blocked, then
stalled, then healthy work. A stalled row's clock counts **since the last sign of
life**, not since the turn began. The cockpit derives that independently of the
spinner, so a session whose animator died still reports the truth rather than
cheerfully claiming to be working.

For a live view that redraws every 2s, run `~/.claude/warden/bin/warden cockpit`
in its own Ghostty split.

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
background services beyond one small per-session animator.

```
 UserPromptSubmit ─► working  ─► start animator ─┐
 PreToolUse       ─► activity glyph · beat · tool in flight
                     (background shell / Monitor → counted as work that outlives the turn)
 PostToolUse      ─► 🧠 thinking   · beat · flight cleared
 SubagentStart    ─► track agent id
 SubagentStop     ─► drop agent id ─► last one out of a waiting session → ✅
 Notification     ─► ❓ needs you  ─► start escalation timer
 Stop             ─► ◓ waiting  if subagents/shells still running
                     ✅ done     if nothing is left
 SessionEnd       ─► stop daemons · forget the session
                                   │
                 each transition ──┼──► STATUS BUS  ~/.claude/warden/sessions/<id>.json
                                   └──► OSC 0 title  ─► your terminal tab
```

- **OSC 0**, not OSC 1 — Ghostty (and others) honor `ESC ] 0 ; … BEL` for the
  tab; OSC 1 is ignored on Ghostty ([ghostty#1026](https://github.com/ghostty-org/ghostty/issues/1026)).
- The spinner reads a cheap per-session render file each frame (no `jq` in the
  hot loop) and resolves the terminal's real device (`/dev/ttysNNN`) so it can
  paint a tab even when that tab isn't focused.
- **Progress is evidence, not a guess.** `PreToolUse` and `PostToolUse` touch a
  per-session `.beat` file; `PreToolUse` also drops an `.inflight` marker that
  `PostToolUse` removes. Stall detection reads those two mtimes and nothing else
   — turn duration is never an input.
- **Background work is tracked two ways, because Claude Code reports it two
  ways.** Subagents are exact — `SubagentStart`/`SubagentStop` carry an
  `agent_id`, so warden keeps the live set. Background shells have no completion
  hook at all, so they are counted at launch and decremented per *self-started*
  turn: when one finishes it wakes the session, and a turn that ends without a
  prompt behind it is the evidence. Any tool call re-syncs the tab to `working`
  regardless, so drift is cosmetic and brief.
- **The animator outlives the turn**, so its exit conditions matter: the render
  file disappearing (`SessionEnd`), another session claiming the tty, the
  recorded `CLAUDE_PID` dying (the crash path), or the lifetime backstop.
- The animator owns everything that needs a clock (stall detection, the
  context meter), because a hook runs on the critical path of a tool call and has
  a 5-second timeout. It also self-heals: if the animator dies mid-turn, the next
  tool call revives it.
- On Ghostty/WezTerm it also emits an **OSC 9;4** native progress pulse on the
  focused tab; a no-op elsewhere.

With `"spinner": false` there is no daemon, and therefore no stall detection and
no mid-turn context refresh — the tab still shows state, activity, and label.

---

## Configuration

`~/.claude/warden/config.json` (created on first run). `/warden:config` to view.

| Key | Default | Meaning |
|-----|---------|---------|
| `spinner` | `true` | run the animator that owns the tab title |
| `spinnerFrames` | `["⚙"]` | array of frames. One frame holds the title still; list more to animate — try `["🌑","🌒","🌓","🌔","🌕","🌖","🌗","🌘"]`. See the note below first |
| `spinnerIntervalMs` | `500` | frame interval |
| `waitingFrames` | `["◐"]` | frames for waiting-on-background-work |
| `waitingIntervalMs` | `1000` | waiting frame interval — if you animate both, keep this visibly slower than the spinner, that contrast *is* the signal |
| `keeperIntervalSeconds` | `2` | how often a static tab is repainted so Claude Code's own title can't take it back (`0` is treated as 1) |
| `showProject` / `showActivity` / `showContext` | `true` | what rides the tab |
| `audioEnabled` | `true` | the machine's mute switch — see below |
| `escalateAfterSeconds` | `45` | needs-you → escalated threshold (`0` = off) |
| `escalateReping` | `true` | re-ping the system sound on escalation |
| `escalateMaxSeconds` | `3600` | stop nagging a session nobody ever came back to |
| `stuckAfterSeconds` / `stuck2AfterSeconds` | `300` / `900` | 🐢 / ⏳ thresholds — seconds **since the last tool call or return**, not since the turn began |
| `slowToolAfterSeconds` | `900` | how long one tool may run before ⏳ (catches a command hung on stdin) |
| `contextWarnPercent` | `75` | only show the context meter past this |
| `contextRefreshSeconds` | `15` | how often the daemon recomputes the context meter mid-turn |
| `maxLifetimeSeconds` | `86400` | backstop for a session that crashed without emitting `Stop` — **not** a turn limit |
| `glyphs.*` | see above | override any state glyph |
| `projectLabelCommand` | — | a shell command (`$WARDEN_CWD`) printing a label |

### A note on animating the frames

The frame lists ship with one frame each, so the tab title is **stable while a
state lasts** and changes only on a real transition. That is deliberate.

Animating repaints the title several times a second, and a desktop activity
tracker — Toggl, RescueTime, Timing — samples the foreground window title and
reads every repaint as input. An unattended overnight agent run then books
itself as hours at the keyboard. One user's tracker credited a 10.6-hour
"focus session" to a spinner animating over a sleeping laptop; 28% of a
fortnight's recorded activity turned out to be the animation.

You lose nothing by holding it still. Liveness already rides the OSC 9;4
progress pulse, which the terminal renders natively and which never touches the
title — and the state glyphs (⚙ ❓ ‼️ 🐢 ✅) still change the moment the state
does. Add frames back if you want the motion and don't track your time.

### Sound

```sh
warden sound             # what's set right now
warden sound off         # silence — tracking keeps running
warden sound on          # unmute
warden sound reping off  # hand the repeating chime to another tool
```

`audioEnabled` is a **shared** switch rather than a warden-only one. Most setups
end up with more than one thing that chimes — warden's escalation ping, a
personal notification hook, an app — and muting them one at a time is how you
end up hunting a sound you can't find. Any local tool can opt in in one line:

```sh
[ "$(jq -r '.audioEnabled' ~/.claude/warden/config.json 2>/dev/null)" != false ] || exit 0
```

Scope, precisely: it silences the emitters that **choose to read the key**. It
is not a system mute, and it cannot reach a program that has never heard of it.

Two things it deliberately does **not** do:

- **It never turns off tracking.** Muted, warden still classifies, still paints
  `❓`/`‼️`, still writes the status bus, still escalates. You lose the noise, not
  the information.
- **It is read live, at the moment of playback**, so a daemon that is already
  detached goes quiet on its next tick without being killed. That applies to a
  daemon *running this version of the script*: a process launched from an older
  copy carries that older code for its whole life and has to be restarted before
  it can honour anything new. Updating a file on disk never reaches a running
  shell.

`escalateReping` is the separate question of *who owns* the repeating chime.
Leave it on if warden is the only thing making noise; turn it off when something
else already covers a blocked session, so the two don't talk over each other.

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
  "attention": "|stalled|stalled2|slow_tool|escalated",
  "project": "wunda", "activity": "🔧", "tty": "/dev/ttys003",
  "cwd": "…", "started": "1719582000", "prompt": "fix the …",
  "ctx": "78", "needs_since": "", "transcript": "…", "updated": "1719582012" }
```

`state` is what the session is doing; `attention` is whether it needs you. They
are orthogonal — a `working` session can be `stalled`, and a `needs_you` session
can be `escalated`. Both fire `on-state.sh`, so an extension sees a stalled
session, not just whoever happens to be looking at that tab.

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

- **warden's label/glyph shows while working but reverts when the turn ends** —
  this is the big one. Claude Code writes its own title (`·` working, `✳` idle);
  it overwrites warden's the moment a turn finishes. **Fix:** set
  `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (see Install — the `env` block in
  `~/.claude/settings.json`) and restart your sessions. `/warden:doctor` reports
  whether it's disabled. (Claude's title write is hardcoded and event-driven, so
  warden can't beat it from a hook — it has to be turned off.)
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
