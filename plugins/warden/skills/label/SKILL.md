---
name: warden:label
description: Rename the current Claude Code tab without losing the warden indicator. Use when the user says "warden label", "/warden:label", "rename this tab", "rename the tab", "name this session", "set the tab title", "call this tab X", or wants a custom tab name that keeps the spinner/glyph.
---

# /warden:label

warden owns the terminal tab title so it can animate the spinner — which means a
native terminal rename gets overwritten on warden's next tick. Instead, set a
**custom label** that warden keeps decorating with the live glyph.

## Set the label for this tab

Take the name from the user's request (everything after "label"/"rename to"):

```sh
~/.claude/warden/bin/warden label "WUNDA-627 portal"
```

The tab now reads e.g. `⚙ 🔧 WUNDA-627 portal` while working, `✅ WUNDA-627 portal`
when done, and so on. The label **persists** across turns and session resume,
keyed to this terminal tab, until cleared.

## Clear it (back to the auto label — git repo / dir name)

```sh
~/.claude/warden/bin/warden label --clear
```

## Show the current label

```sh
~/.claude/warden/bin/warden label
```

## Notes

- **Precedence:** an explicit label set here  →  `$WARDEN_LABEL` (set at launch,
  e.g. `WARDEN_LABEL="My tab" claude`)  →  the auto label (git repo / directory).
- **Rename a *different* tab** (e.g. a background session seen in `/warden:cockpit`):
  `warden label --session <session_id> "Name"`.
- Run the command and report the result verbatim. If it says no terminal device
  was found, the session has no resolvable tty (rare) — tell the user.
