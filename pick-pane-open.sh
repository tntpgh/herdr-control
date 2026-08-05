#!/usr/bin/env bash
# pick-pane-open.sh <pane-entrypoint-id>
#
# Action dispatcher for the fzf-based pickers (open-project.sh --pick,
# quick-action.sh --pick). Herdr invokes a plugin ACTION's `command` on the
# server, WITHOUT a TTY — fzf cannot run there. This script instead opens the
# matching `[[panes]]` entrypoint in herdr-plugin.toml, which DOES get a real
# terminal, and is where the actual `--pick` invocation lives.
#
# Also forwards the ORIGIN pane/workspace's cwd via `--cwd`, so
# quick-action.sh's repo-local (.herdr-control/quick-actions/) tier resolves
# the repo the user was actually looking at — not this plugin's own install
# directory, which is where an action's `command` runs by default. Herdr's
# own pane-open forwards `--cwd` as the pane's REAL process cwd (verified
# against jt.command-palette's overlay pane), so nothing downstream needs a
# second cwd-override mechanism: bare $PWD in the target script is enough.
# open-project.sh has no cwd-dependent tier (its two tiers are both
# ${XDG_CONFIG_HOME:-~/.config}-rooted), so for it this is a no-op beyond
# correctness/consistency — same dispatcher either way, one code path.
#
# Pattern credited to jt.command-palette's open.sh
# (~/.config/herdr/plugins/github/jt.command-palette-*/open.sh) — identical
# problem (fzf needs a TTY, actions don't get one), identical fix.
set -uo pipefail

entrypoint="${1:?usage: pick-pane-open.sh <pane-entrypoint-id>}"
herdr_bin="${HERDR_BIN_PATH:-herdr}"
plugin_id="${HERDR_PLUGIN_ID:-tntpgh.herdr-control}"
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"

# Resolve the repo/dir the user triggered the action from.
repo=""
if [ -n "$ctx" ] && command -v jq >/dev/null 2>&1; then
  repo="$(printf '%s' "$ctx" | jq -r '.focused_pane_cwd // .workspace_cwd // empty' 2>/dev/null || true)"
fi
[ -n "$repo" ] || repo="${HERDR_WORKSPACE_CWD:-}"

set -- plugin pane open \
  --plugin "$plugin_id" \
  --entrypoint "$entrypoint" \
  --placement overlay \
  --focus

# Only forward --cwd when it's a real directory; otherwise the pane falls
# back to the plugin root, which is at least a valid, existing directory.
if [ -n "$repo" ] && [ -d "$repo" ]; then
  set -- "$@" --cwd "$repo"
fi

exec "$herdr_bin" "$@"
