# claude-code-warden

A **public, installable Claude Code plugin** that keeps watch over a fleet of
parallel Claude Code sessions by riding each terminal tab's title: an animated
spinner while a turn works, an activity-aware glyph, a needs-you alarm that
escalates, stuck detection, a context meter, and a `/warden:cockpit` fleet view.

It is **pure Claude Code hooks + terminal escape sequences (OSC) + a tiny
per-session shell daemon**. No LLM calls, no network, no background services
beyond the spinner while a turn is active. It costs **zero tokens**.

## Repository layout

```
.claude-plugin/marketplace.json        marketplace manifest (lists `warden` + version)
plugins/warden/
  .claude-plugin/plugin.json           plugin manifest (name, version, keywords)
  hooks/hooks.json                     registers the 5 hooks
  hooks/on-*.sh                         the hook scripts (session-start/prompt/pretool/notify/stop)
  bin/helpers.sh                        SHARED LIBRARY — sourced by every hook + script
  bin/spinner-daemon.sh                 detached title animator (one per working session)
  bin/escalate-daemon.sh               detached needs-you re-ping timer
  bin/warden-cli.sh                     the `warden` command (status|cockpit|config|label|doctor|clean)
  bin/cockpit.sh                        fleet table + flicker-free --watch
  bin/warden-context.sh                 best-effort context-window % from the transcript
  skills/*/SKILL.md                     the /warden:* skills
examples/ext/*.sh                       extension-seam templates (project-label, on-state)
README.md  CHANGELOG.md  LICENSE (MIT)
```

`bin/helpers.sh` is the spine — paths, tty resolution, glyphs, the render/bus
writers, label resolution, daemon lifecycle. Read it first.

## Critical constraints — do not violate

1. **bash 3.2 compatible.** macOS ships `/bin/bash` 3.2.57 and that's what runs
   these scripts. NO associative arrays, NO `${var,,}` / `${var^^}`, NO
   `mapfile`/`readarray`, NO `&>>`. (`arr+=(x)` is fine — that's bash 3.1+.)
   Always check with `/bin/bash -n <file>`, not your Homebrew bash 5.
2. **Hooks must emit NOTHING on stdout.** `UserPromptSubmit` stdout is injected
   into the model's context window. Every hook writes only to files and the tty
   device, and ends `exit 0`. A stray `echo`/`printf` to stdout = token cost +
   context pollution. (Regression-test this — see below.)
3. **Zero LLM, zero network.** warden never calls an API and never injects
   context (`systemMessage`/`additionalContext`/`hookSpecificOutput`). Keep it
   that way — that's the whole "costs no tokens" promise.
4. **Atomic file writes.** Bus/render files are written to a temp path then
   `mv`-renamed so a reader never sees a truncated line. Use the helpers
   (`warden_render_write`, `warden_bus_write`) — don't hand-roll `> file`.
5. **Sanitize anything externally-derived.** Directory names, prompts, and
   `session_id` flow into terminal titles and file paths. Route project/prompt
   text through `warden_strip_controls` (strips control/escape bytes + the `|`
   render delimiter — the OSC-injection guard) and sanitize `session_id` with
   `tr -c 'A-Za-z0-9._-' '_'` (path-traversal guard) before using it in a path.
6. **Keep state private.** `umask 077` is set in helpers — bus files hold prompt
   prefixes and cwd. Don't loosen it.

## How it works

```
 SessionStart      -> seed bus to idle, register the warden CLI symlink, reap stale daemons
                      (skips reseed when .source == "compact" — a mid-turn compaction)
 UserPromptSubmit  -> WORKING; seed bus; launch spinner-daemon
 PreToolUse        -> refresh activity glyph; resume-after-permission (relaunch spinner)
 Notification      -> NEEDS_YOU; arm escalate-daemon
 Stop              -> DONE; reap both daemons
        each transition --> STATUS BUS ~/.claude/warden/sessions/<id>.json   (public contract)
                        --> OSC 0 title  --> the terminal tab
```

- **Status bus** `~/.claude/warden/sessions/<id>.json` is the documented public
  interface other tools read. Don't change its field shape without reason.
- **Render file** `<id>.render` is a cheap pipe-delimited line
  (`state|project|activity|ctx|`) the spinner reads every tick — **no `jq` in the
  hot loop**.
- **Daemons**: exactly one spinner per session (atomic `mkdir` lock), killed via
  `SIGTERM` (a `trap` releases the lock). The spinner resolves the terminal's
  real device (`/dev/ttysNNN`, via a parent-pid walk) so it can paint an
  unfocused tab.
- **Custom labels**: a per-tty `<tty>.label` override → `$WARDEN_LABEL` → auto
  (git repo / dir). warden owns the title to animate it, so renaming goes
  through `warden label`, not the terminal's native rename.

## Developing & releasing

**Installed plugins are FROZEN cache copies** at
`~/.claude/plugins/cache/claude-code-warden/...`. Editing the source here does
**not** affect running or new sessions until you bump the version and reinstall.

To ship a change:
1. Edit source under `plugins/warden/`.
2. **Bump BOTH version files together** (they must match):
   `plugins/warden/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.
3. **Update `CHANGELOG.md`** for any user-facing change.
4. Propagate: `/plugin marketplace update` (or remove + re-add the marketplace),
   then reinstall `warden`.

Do **not** commit or push unless the user explicitly asks. Commit messages are
imperative mood; end with the project's Co-Authored-By trailer.

## Verify before committing

```sh
# 1. bash 3.2 syntax on every script
for f in plugins/warden/hooks/*.sh plugins/warden/bin/*.sh examples/ext/*.sh; do
  /bin/bash -n "$f" || echo "SYNTAX FAIL $f"
done

# 2. JSON manifests are valid
jq -e . .claude-plugin/marketplace.json \
       plugins/warden/.claude-plugin/plugin.json \
       plugins/warden/hooks/hooks.json >/dev/null && echo "json ok"

# 3. Hooks emit NO stdout (must print nothing)
printf '{"session_id":"t","cwd":"/tmp","prompt":"hi"}' | bash plugins/warden/hooks/on-prompt.sh

# 4. Skill frontmatter present
for s in plugins/warden/skills/*/SKILL.md; do head -1 "$s" | grep -q '^---' || echo "FRONTMATTER FAIL $s"; done
```

Exercise hooks/daemons against an **isolated `HOME`** (`export HOME="$(mktemp -d)"`)
and a **regular file standing in for the tty**, so you never paint your real
terminal or mutate real session state. A spinner daemon takes
`<session_id> <tty_device>` — pass a temp file as the device. Pull the title
back with `cat <file> | tr -d '\007' | sed 's/\x1b]0;/[TAB] /'`.

## Conventions

- Shell: `set -u`; mirror the existing helper idiom; comment the *why*, not the *what*.
- New config keys → add to `warden_default_config` in `helpers.sh` (read via `warden_cfg`).
- New per-session state file → key it `<id>.<suffix>` in the sessions dir and add
  it to the SessionStart prune loop **and** `warden clean`.
- New glyphs/states → `warden_state_glyph` / `warden_activity_glyph` + the
  `glyphs.*` config block.
- Degrade gracefully: not every terminal supports OSC 9;4 (Ghostty/WezTerm do);
  `jq` may be absent (helpers fall back). Never hard-require an optional feature.
