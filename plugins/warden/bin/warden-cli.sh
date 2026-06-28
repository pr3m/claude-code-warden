#!/bin/bash
# warden-cli.sh — the `warden` command. Reached via the stable symlink
# ~/.claude/warden/bin/warden (created by the SessionStart hook), so the skills
# can call it regardless of where the plugin is installed.

set -u
# Resolve through the symlink (~/.claude/warden/bin/warden) to the real plugin
# bin dir, so helpers.sh + sibling scripts are found regardless of install path.
# dirname(BASH_SOURCE) alone would point at the symlink's own dir, which has no
# helpers.sh — that breaks every skill that calls warden via the stable entry.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  _wd="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$_wd/$SOURCE" ;; esac
done
DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
# shellcheck source=./helpers.sh
. "$DIR/helpers.sh"

cmd="${1:-help}"; shift 2>/dev/null || true

warden_version() {
  local pj="$DIR/../.claude-plugin/plugin.json"
  if warden_has_jq && [ -f "$pj" ]; then jq -r '.version // "?"' "$pj"; else printf '?\n'; fi
}

case "$cmd" in
  status)
    bash "$DIR/cockpit.sh"
    ;;

  cockpit|watch)
    bash "$DIR/cockpit.sh" --watch
    ;;

  config)
    sub="${1:-show}"
    warden_ensure_config
    case "$sub" in
      show|"") printf 'config file: %s\n\n' "$(warden_config_file)"; cat "$(warden_config_file)" ;;
      edit)    "${EDITOR:-vi}" "$(warden_config_file)" ;;
      path)    warden_config_file ;;
      *)       printf 'usage: warden config [show|edit|path]\n' ;;
    esac
    ;;

  label)
    # Rename the current tab (or another session's tab) without losing the
    # warden glyph. warden owns the tab title to animate it, so this is how you
    # set a custom label that rides alongside the live indicator.
    #
    #   warden label                  show the effective label for this tab
    #   warden label <text...>        set a custom label (persists, survives resume)
    #   warden label --clear          revert to the auto label (git repo / dir)
    #   warden label --session <id> … target another session's tab
    #   warden label --tty <dev> …    target a specific terminal device
    target_tty=""
    if [ "${1:-}" = "--session" ]; then
      sid="${2:-}"; shift 2 2>/dev/null || true
      target_tty="$(warden_bus_read "$sid" tty)"
      [ -n "$target_tty" ] || { printf 'warden label: no session "%s" (or it has no tty).\n' "$sid"; exit 1; }
    elif [ "${1:-}" = "--tty" ]; then
      target_tty="${2:-}"; shift 2 2>/dev/null || true
    fi
    [ -n "$target_tty" ] || target_tty="$(warden_tty)"
    [ -n "$target_tty" ] || { printf 'warden label: no terminal device found for this tab.\n'; exit 1; }
    lp="$(warden_label_path "$target_tty")"
    case "${1:-}" in
      ""|--show|show)
        cur="$(warden_label_read "$target_tty")"
        if [ -n "$cur" ]; then
          printf '🛡  label: %s\n' "$cur"
        elif [ -n "${WARDEN_LABEL:-}" ]; then
          printf '🛡  label: %s   (from $WARDEN_LABEL)\n' "$(warden_strip_controls "$WARDEN_LABEL")"
        else
          printf '🛡  label: «auto» — %s\n' "$(warden_project "$PWD")"
        fi
        ;;
      --clear|clear)
        rm -f "$lp" 2>/dev/null || true
        warden_relabel_tty "$target_tty"
        printf '🛡  warden: label cleared — back to the auto label.\n'
        ;;
      *)
        newlabel="$(warden_strip_controls "$*")"
        warden_ensure_dirs
        printf '%s\n' "$newlabel" > "$lp"
        warden_relabel_tty "$target_tty"
        printf '🛡  warden: this tab is now labeled "%s".\n' "$newlabel"
        ;;
    esac
    ;;

  doctor)
    printf '🛡  warden doctor\n\n'
    printf '  version        : %s\n' "$(warden_version)"
    printf '  platform       : %s\n' "$(warden_platform)"
    printf '  terminal       : %s (TERM_PROGRAM=%s)\n' "$(warden_term)" "${TERM_PROGRAM:-unset}"
    printf '  CC title write : %s\n' "$([ -n "${CLAUDE_CODE_DISABLE_TERMINAL_TITLE:-}" ] && echo 'disabled — warden owns the tab (good)' || echo 'ENABLED — Claude Code overwrites warden titles! set CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 (see README)')"
    printf '  tty resolved   : %s\n' "$(warden_tty || echo 'FAILED')"
    printf '  label (tab)    : %s\n' "$(warden_label_for "$(warden_tty)" "$PWD")"
    printf '  jq present     : %s\n' "$(warden_has_jq && echo yes || echo 'NO — context meter + cockpit degraded')"
    printf '  data dir       : %s\n' "$(warden_data_dir)"
    printf '  config         : %s\n' "$([ -f "$(warden_config_file)" ] && echo present || echo 'missing (run any session to create)')"
    printf '  sessions known : %s\n' "$(ls -1 "$(warden_sessions_dir)"/*.json 2>/dev/null | wc -l | tr -d ' ')"
    printf '  ext label hook : %s\n' "$([ -x "$(warden_data_dir)/ext/project-label.sh" ] && echo active || echo 'none (default: git repo name)')"
    printf '  ext state hook : %s\n' "$([ -x "$(warden_data_dir)/ext/on-state.sh" ] && echo active || echo none)"
    printf '\n  live title test → check your tab for "🛡 warden":\n'
    local_tty="$(warden_tty)"; [ -n "$local_tty" ] && warden_write_title "$local_tty" "🛡 warden"
    printf '  (a state hook will repaint it on the next prompt)\n'
    ;;

  clean)
    # Stop all daemons and clear the status bus. Titles reset on next prompt.
    n=0
    for p in "$(warden_sessions_dir)"/*.spinner.pid "$(warden_sessions_dir)"/*.escalate.pid; do
      [ -f "$p" ] || continue
      warden_kill_pidfile "$p"; n=$((n + 1))
    done
    rm -f "$(warden_sessions_dir)"/*.json "$(warden_sessions_dir)"/*.render \
          "$(warden_sessions_dir)"/*.label 2>/dev/null || true
    printf '🛡  warden: stopped %s daemon(s), cleared the status bus.\n' "$n"
    ;;

  version)
    warden_version
    ;;

  help|*)
    cat <<'USAGE'
🛡  warden — keep watch over your fleet of Claude Code sessions

usage: warden <command>

  status        one-shot fleet table (state · project · activity · elapsed · ctx)
  cockpit       live fleet view, redraws every 2s (Ctrl-C to exit)
  label         rename this tab without losing the glyph:
                  warden label "My feature"   set a custom label (persists)
                  warden label --clear         back to the auto label
                  warden label                 show the current label
  config        show | edit | path   — tweak glyphs, spinner, thresholds
  doctor        environment + terminal diagnostics, paints a test title
  clean         stop all daemons and clear the status bus
  version       print the installed warden version

Status bus (the public contract):  ~/.claude/warden/sessions/<id>.json
User extension seam:                ~/.claude/warden/ext/{project-label,on-state}.sh
USAGE
    ;;
esac
