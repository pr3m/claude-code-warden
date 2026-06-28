---
name: warden:uninstall
description: Turn warden off or remove it — stops its background daemons, clears the status bus, and explains how to disable/uninstall the plugin. Use when the user says "warden uninstall", "/warden:uninstall", "turn warden off", "remove warden", "stop the spinners".
---

# /warden:uninstall

First, stop all warden daemons and clear its state:

```sh
~/.claude/warden/bin/warden clean
```

Then explain the levels:

- **Temporary off** — set `"spinner": false` in `~/.claude/warden/config.json`
  to stop the animation while keeping the static state glyphs.
- **Disable the plugin** — `/plugin` → disable `warden` (hooks stop firing on new
  sessions). Existing tab titles clear on the next prompt or terminal reset.
- **Full removal** — `/plugin` → uninstall `warden`, then optionally
  `rm -rf ~/.claude/warden` to remove its data dir (config, status bus, the CLI
  symlink). Note: this also removes any `ext/` extension scripts you added there,
  so back those up first if you want to keep them.
