---
description: Optional standalone tab-naming and attention-classification scripts, independent of the Slack alert path.
globs: ["smart-name.sh", "attention.sh", "docs/herdr-config-snippet.toml"]
---
# Tab Naming & Attention

## Step 9 — optional: tab naming + attention

These two need no hook wiring — they are standalone scripts, plus optional
herdr keybindings. Independent of the Slack path above.

```bash
./smart-name.sh --dry-run --all          # see proposed tab names; renames nothing
./attention.sh  --dry-run --focus        # classify agents + the "what next" view
```

`smart-name.sh` needs the `claude` CLI on `PATH` for the model path (set
`SMART_NAME_AI=0` to skip it and use deterministic names only). Verify isolation
did its job: a proposed label must describe the **target** pane's work, not the
repo this script was run from — if a tab is named after *your* current task, the
model context leaked and the isolation flags in `ai_name()` need checking.

To render the `$task`/`$status` sidebar cards and bind the keys, merge
`docs/herdr-config-snippet.toml` into `~/.config/herdr/config.toml`, replace
`__HERDR_CONTROL__`, then `herdr server reload-config`. **Invalid token names
fail silently** — reload reports `partial` and keeps the old layout; run
`herdr config check` and re-verify names if a row never appears.