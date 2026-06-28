#!/bin/bash
# helpers.sh — shared utilities for claude-code-warden.
# Sourced by every hook and bin/ script. Kept bash 3.2-safe (macOS default):
# no associative arrays, no ${var,,}.

set -u
# Bus/render/config files can hold prompt prefixes + cwd — keep them private.
umask 077

# Strip C0 control chars (incl. ESC/BEL/CR/LF), DEL, and the render delimiter |
# from any externally-derived string before it reaches a terminal or a file.
# This is the guard against OSC/terminal-escape injection via a crafted
# directory name or prompt. tr works on bytes under LC_ALL=C, so multi-byte
# UTF-8 (emoji glyphs) passes through untouched.
warden_strip_controls() {
  printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177|'
}

# ---------------------------------------------------------------------------
# Paths — all state pinned under $HOME/.claude/warden so every writer (hooks,
# detached spinner daemons, the cockpit) agrees on one location regardless of
# whether $CLAUDE_PLUGIN_ROOT is set in the calling context.
# ---------------------------------------------------------------------------

warden_data_dir()     { printf '%s\n' "$HOME/.claude/warden"; }
warden_sessions_dir() { printf '%s\n' "$HOME/.claude/warden/sessions"; }
warden_config_file()  { printf '%s\n' "$HOME/.claude/warden/config.json"; }
warden_log_file()     { printf '%s\n' "$HOME/.claude/warden/warden.log"; }

warden_session_file()  { printf '%s/%s.json\n'         "$(warden_sessions_dir)" "$1"; }
warden_render_file()   { printf '%s/%s.render\n'       "$(warden_sessions_dir)" "$1"; }
warden_spinner_pid()   { printf '%s/%s.spinner.pid\n'  "$(warden_sessions_dir)" "$1"; }
warden_escalate_pid()  { printf '%s/%s.escalate.pid\n' "$(warden_sessions_dir)" "$1"; }

warden_ensure_dirs() { mkdir -p "$(warden_sessions_dir)"; }

warden_now() { date +%s; }
warden_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

warden_log() {
  warden_ensure_dirs
  printf '[%s] %s\n' "$(warden_now_iso)" "$*" >> "$(warden_log_file)" 2>/dev/null || true
}

warden_has_jq() { command -v jq >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Platform / terminal detection
# ---------------------------------------------------------------------------

warden_platform() {
  case "$(uname -s)" in
    Darwin) printf 'darwin\n' ;;
    Linux)  printf 'linux\n' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'win32\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Best-effort terminal identity, used to pick per-terminal adapter behaviour.
# Returns one of: ghostty | iterm | apple | vscode | wezterm | unknown
warden_term() {
  if [ -n "${GHOSTTY_RESOURCES_DIR:-}" ] || [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
    printf 'ghostty\n'; return
  fi
  case "${TERM_PROGRAM:-}" in
    iTerm.app)       printf 'iterm\n' ;;
    Apple_Terminal)  printf 'apple\n' ;;
    vscode)          printf 'vscode\n' ;;
    WezTerm)         printf 'wezterm\n' ;;
    *)               printf 'unknown\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# TTY resolution — find the *named device* of the terminal this session runs
# in (e.g. /dev/ttys003). We must resolve the path (not rely on /dev/tty)
# because the detached spinner daemon has no controlling terminal of its own
# and needs an explicit device to write title sequences to.
# ---------------------------------------------------------------------------

warden_tty() {
  local pid="${1:-$$}" hops=0 tty
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 14 ]; do
    tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
    case "$tty" in
      ttys*|pts/*|pts[0-9]*|tty[0-9]*)
        printf '/dev/%s\n' "$tty"; return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    hops=$((hops + 1))
  done
  # Fallback: this process's controlling terminal, if any.
  if [ -e /dev/tty ]; then printf '/dev/tty\n'; return 0; fi
  return 1
}

# ---------------------------------------------------------------------------
# Project label — short tag shown next to the glyph. Git repo name, else dir.
# ---------------------------------------------------------------------------

warden_project() {
  local cwd="${1:-$PWD}" label="" cmd ext top
  # (1) User resolver via config command — gets the cwd in $WARDEN_CWD.
  cmd="$(warden_cfg '.projectLabelCommand' '')"
  if [ -n "$cmd" ]; then
    label="$(WARDEN_CWD="$cwd" sh -c "$cmd" 2>/dev/null | head -n1)"
  fi
  # (2) Drop-in resolver script — receives cwd as $1.
  if [ -z "$label" ]; then
    ext="$(warden_data_dir)/ext/project-label.sh"
    [ -x "$ext" ] && label="$("$ext" "$cwd" 2>/dev/null | head -n1)"
  fi
  # (3) Default: git repo name, else directory basename.
  if [ -z "$label" ]; then
    top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$top" ]; then label="$(basename "$top")"; else label="$(basename "$cwd")"; fi
  fi
  # Single chokepoint: every label (incl. attacker-influenced dir names and
  # custom resolvers) is sanitized before it can reach a tab title or the bus.
  warden_strip_controls "$label"
}

# ---------------------------------------------------------------------------
# Custom tab label — warden owns the tab title (it has to, to animate it), so a
# native terminal rename gets clobbered on the next tick. Instead the user sets
# a label warden keeps decorating with the live glyph. Precedence:
#   (1) explicit per-tty override file  (set via `warden label`)   — highest
#   (2) $WARDEN_LABEL env               (e.g. WARDEN_LABEL=x claude)
#   (3) warden_project (git repo / dir / resolver)                 — auto
# Keyed by the terminal device (tty), so it behaves like a normal tab rename:
# it sticks across turns and session resume until `warden label --clear`.
# ---------------------------------------------------------------------------

warden_label_path() {
  printf '%s/%s.label\n' "$(warden_sessions_dir)" \
    "$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9' '_')"
}

# The explicit per-tty override only (file), stripped. Empty if unset.
warden_label_read() {
  local lp; lp="$(warden_label_path "${1:-}")"
  [ -f "$lp" ] || return 0
  warden_strip_controls "$(head -n1 "$lp" 2>/dev/null)"
}

# Effective label for a tab: explicit override → $WARDEN_LABEL → auto project.
warden_label_for() {
  local tty="${1:-}" cwd="${2:-$PWD}" lbl
  lbl="$(warden_label_read "$tty")"
  [ -n "$lbl" ] && { printf '%s' "$lbl"; return; }
  if [ -n "${WARDEN_LABEL:-}" ]; then warden_strip_controls "$WARDEN_LABEL"; return; fi
  warden_project "$cwd"
}

# Re-apply the effective label to every session bound to a tty, live: rewrite
# the render project (a running spinner picks it up next tick), the bus project
# (cockpit), and repaint a static title (so idle/done/needs_you update at once).
warden_relabel_tty() {
  local tty="$1" f id cwd proj rf rs rp ra rc
  [ -n "$tty" ] || return 0
  warden_has_jq || return 0   # need jq to find sessions by tty + patch the bus
  for f in "$(warden_sessions_dir)"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.tty // ""' "$f" 2>/dev/null)" = "$tty" ] || continue
    id="$(jq -r '.id // ""' "$f" 2>/dev/null)"; [ -n "$id" ] || continue
    cwd="$(jq -r '.cwd // ""' "$f" 2>/dev/null)"
    proj="$(warden_label_for "$tty" "$cwd")"
    rs="idle"; ra=""; rc=""
    rf="$(warden_render_file "$id")"
    [ -f "$rf" ] && { IFS='|' read -r rs rp ra rc _ < "$rf" 2>/dev/null || true; }
    [ -n "$rs" ] || rs="$(jq -r '.state // "idle"' "$f" 2>/dev/null)"
    warden_render_write "$id" "$rs" "$proj" "$ra" "$rc"
    jq --arg p "$proj" '.project=$p' "$f" > "$f.$$.tmp" 2>/dev/null \
      && mv -f "$f.$$.tmp" "$f" 2>/dev/null || rm -f "$f.$$.tmp" 2>/dev/null
    warden_write_title "$tty" "$(warden_compose_title "$rs" "$proj" "$ra" "$rc")"
  done
}

# Extension dispatch — fire the optional user on-state hook after a transition.
# The full session bus JSON is piped to ~/.claude/warden/ext/on-state.sh on
# stdin. Fire-and-forget + detached so user logic (Cortex, Slack, trackers)
# never blocks or slows a Claude Code turn. This is warden's public seam for
# user-specific behaviour without forking the universal core.
warden_dispatch_state() {
  local ext f
  ext="$(warden_data_dir)/ext/on-state.sh"
  [ -x "$ext" ] || return 0
  f="$(warden_session_file "$1")"
  [ -f "$f" ] || return 0
  ( "$ext" < "$f" >/dev/null 2>&1 & ) || true
}

# ---------------------------------------------------------------------------
# Config — created on first SessionStart. warden_cfg reads a key with default.
# ---------------------------------------------------------------------------

warden_default_config() {
  cat <<'JSON'
{
  "spinner": true,
  "spinnerFrames": ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"],
  "spinnerIntervalMs": 120,
  "showProject": true,
  "showActivity": true,
  "showContext": true,
  "escalateAfterSeconds": 45,
  "escalateReping": true,
  "stuckAfterSeconds": 300,
  "stuck2AfterSeconds": 900,
  "contextWarnPercent": 75,
  "staleDisplaySeconds": 86400,
  "maxLifetimeSeconds": 7200,
  "glyphs": {
    "working": "⚙",
    "needs_you": "❓",
    "escalated": "‼️",
    "stuck": "🐢",
    "stuck2": "⏳",
    "done": "✅",
    "idle": "·",
    "error": "🔴"
  }
}
JSON
}

warden_ensure_config() {
  warden_ensure_dirs
  local f; f="$(warden_config_file)"
  [ -f "$f" ] || warden_default_config > "$f"
}

# warden_cfg <jq-path> <default> — reads config.json; falls back to default if
# jq is missing or the key is absent/null.
warden_cfg() {
  local path="$1" def="$2" f val
  f="$(warden_config_file)"
  if warden_has_jq && [ -f "$f" ]; then
    val="$(jq -r "$path // empty" "$f" 2>/dev/null)"
    if [ -n "$val" ]; then printf '%s\n' "$val"; return; fi
  fi
  printf '%s\n' "$def"
}

# ---------------------------------------------------------------------------
# Glyphs — state and activity. Config can override the state set via .glyphs.*
# ---------------------------------------------------------------------------

warden_state_glyph() {
  case "$1" in
    working)   warden_cfg '.glyphs.working'   '⚙' ;;
    needs_you) warden_cfg '.glyphs.needs_you' '❓' ;;
    escalated) warden_cfg '.glyphs.escalated' '‼️' ;;
    stuck)     warden_cfg '.glyphs.stuck'     '🐢' ;;
    stuck2)    warden_cfg '.glyphs.stuck2'    '⏳' ;;
    done)      warden_cfg '.glyphs.done'      '✅' ;;
    error)     warden_cfg '.glyphs.error'     '🔴' ;;
    *)         warden_cfg '.glyphs.idle'      '·' ;;
  esac
}

# Map a Claude Code tool name to a compact activity glyph.
warden_activity_glyph() {
  case "$1" in
    Bash)                 printf '🔧\n' ;;
    Read|NotebookRead)    printf '📖\n' ;;
    Edit|Write|NotebookEdit|MultiEdit) printf '✏️\n' ;;
    Grep|Glob)            printf '🔎\n' ;;
    WebSearch|WebFetch)   printf '🌐\n' ;;
    Task|Agent)           printf '🤖\n' ;;
    TodoWrite)            printf '🗒️\n' ;;
    *mcp*|mcp__*)         printf '🔌\n' ;;
    *)                    printf '🔧\n' ;;
  esac
}

# Heuristic: label a test-runner bash command so the tab can show 🧪.
warden_is_test_command() {
  case "$1" in
    *"npm test"*|*"npm run test"*|*"mocha"*|*vitest*|*jest*|*pytest*|*"go test"*|*"cargo test"*|*"npm run lint"*)
      return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# OSC title writer — composes nothing; just emits. OSC 0 sets icon+title
# (the portable choice; Ghostty ignores OSC 1, see ghostty#1026). Wraps in a
# tmux DCS passthrough when inside tmux (needs `set -g allow-passthrough on`).
# ---------------------------------------------------------------------------

warden_write_title() {
  local tty="$1" text="$2"
  [ -z "$tty" ] && return 0
  if [ -n "${TMUX:-}" ]; then
    # Inner OSC has exactly one ESC; tmux passthrough requires it doubled.
    printf '\033Ptmux;\033\033]0;%s\007\033\\' "$text" > "$tty" 2>/dev/null || true
  else
    printf '\033]0;%s\007' "$text" > "$tty" 2>/dev/null || true
  fi
}

# Ghostty/WezTerm/Windows-Terminal native progress pulse (OSC 9;4).
# state: 0=clear 1=normal 2=error 3=indeterminate(pulse). Harmless no-op
# on terminals that don't implement it.
warden_write_progress() {
  local tty="$1" pstate="$2" pct="${3:-0}"
  [ -z "$tty" ] && return 0
  if [ -n "${TMUX:-}" ]; then
    printf '\033Ptmux;\033\033]9;4;%s;%s\007\033\\' "$pstate" "$pct" > "$tty" 2>/dev/null || true
  else
    printf '\033]9;4;%s;%s\007' "$pstate" "$pct" > "$tty" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Render file — a cheap pipe-delimited line the spinner daemon reads every
# tick (no jq in the hot loop):  state|projectGlyphPrefix|project|activity|ctx
# ---------------------------------------------------------------------------

warden_render_write() {
  # $1 id  $2 state  $3 project  $4 activity_glyph  $5 ctx_pct
  # Atomic (temp + rename) so the spinner daemon never reads a truncated line
  # mid-rewrite.
  warden_ensure_dirs
  local f tmp
  f="$(warden_render_file "$1")"
  tmp="${f}.$$.tmp"
  printf '%s|%s|%s|%s|%s\n' "$2" "$3" "$4" "${5:-}" "" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# Compose a static one-shot title for a non-animated state (needs_you, done,
# idle) or as the instant working title before the spinner's first frame.
warden_compose_title() {
  local state="$1" project="$2" activity="$3" ctx="${4:-}"
  local t warn
  t="$(warden_state_glyph "$state")"
  [ "$(warden_cfg '.showActivity' 'true')" = 'true' ] && [ -n "$activity" ] && t="$t $activity"
  [ "$(warden_cfg '.showProject' 'true')" = 'true' ]  && [ -n "$project" ]  && t="$t $project"
  if [ "$(warden_cfg '.showContext' 'true')" = 'true' ] && [ -n "$ctx" ]; then
    warn="$(warden_cfg '.contextWarnPercent' '75')"
    [ "$ctx" -ge "$warn" ] 2>/dev/null && t="$t ·${ctx}%"
  fi
  printf '%s' "$t"
}

# ---------------------------------------------------------------------------
# Session bus (full JSON) — written by hooks, read by the cockpit. Uses jq
# when available; degrades to a minimal hand-written object otherwise.
# ---------------------------------------------------------------------------

warden_bus_write() {
  # named via env for clarity: id state project activity tty cwd started prompt ctx needs_since
  local id="$1" state="$2" project="$3" activity="$4" tty="$5" cwd="$6" \
        started="$7" prompt="$8" ctx="${9:-}" needs_since="${10:-}"
  warden_ensure_dirs
  local f tmp; f="$(warden_session_file "$id")"; tmp="${f}.$$.tmp"
  if warden_has_jq; then
    jq -n \
      --arg id "$id" --arg state "$state" --arg project "$project" \
      --arg activity "$activity" --arg tty "$tty" --arg cwd "$cwd" \
      --arg started "$started" --arg prompt "$prompt" --arg ctx "$ctx" \
      --arg needs "$needs_since" --arg updated "$(warden_now)" \
      '{id:$id,state:$state,project:$project,activity:$activity,tty:$tty,
        cwd:$cwd,started:$started,prompt:$prompt,ctx:$ctx,
        needs_since:$needs,updated:$updated}' > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    # jq-absent fallback: escape backslash and double-quote so the hand-built
    # JSON stays valid even if the project label contains them.
    local pe; pe="$(printf '%s' "$project" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{"id":"%s","state":"%s","project":"%s","tty":"%s","updated":"%s"}\n' \
      "$id" "$state" "$pe" "$tty" "$(warden_now)" > "$tmp" \
      && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
}

# Read one field from a session bus file (jq path without leading dot).
warden_bus_read() {
  local id="$1" key="$2" f
  f="$(warden_session_file "$id")"
  [ -f "$f" ] || { printf '\n'; return; }
  if warden_has_jq; then
    jq -r --arg k "$key" '.[$k] // ""' "$f" 2>/dev/null
  else
    printf '\n'
  fi
}

# ---------------------------------------------------------------------------
# Daemon lifecycle
# ---------------------------------------------------------------------------

warden_kill_pidfile() {
  local f="$1" pid
  [ -f "$f" ] || return 0
  pid="$(cat "$f" 2>/dev/null)"
  # Only signal a validated positive integer PID (>1) that's actually alive —
  # never a negative value (which kill treats as a process group) or garbage.
  case "$pid" in ''|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$f" 2>/dev/null || true
}

warden_pid_alive() {
  local f="$1" pid
  [ -f "$f" ] || return 1
  pid="$(cat "$f" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Resolve the plugin root (dir containing bin/ and hooks/) from this file.
warden_plugin_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); }

# Read the JSON hook payload from stdin into $WARDEN_PAYLOAD and extract a key.
warden_payload_get() {
  # $1 = jq path; relies on $WARDEN_PAYLOAD being set by the caller.
  if warden_has_jq && [ -n "${WARDEN_PAYLOAD:-}" ]; then
    printf '%s' "$WARDEN_PAYLOAD" | jq -r "$1 // empty" 2>/dev/null
  fi
}
