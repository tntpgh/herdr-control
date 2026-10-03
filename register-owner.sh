#!/usr/bin/env bash
# register-owner.sh <label> <pane|tab|label-target>
#
# Register a NAMED, long-lived session (a conductor, a dedicated tab) as an
# owner a remote MCP client can address with send_owner_message
# (remote-mcp/README.md, ZERO-LOOP-001 #5). This is deliberately NOT a
# spawned task: no run_id, no lifecycle, nothing in the `tasks` table — a
# task's agent stays reachable only through send_message.
#
# <label> is the name Zero will use (register_owner's own regex, run-registry.sh):
#   lowercase letters/digits/hyphens, 2-41 chars, must start alnum.
# <target> resolves the same way herdr-deliver.sh resolves one:
#   w8:p2    a pane id
#   w8:t2    a tab id -> its first pane
#   <label>  an agent/pane label (resolved via pane list)
#
#   register-owner.sh conductor w8:p2
#   register-owner.sh conductor "implement:feat/x"
#
# Exit 0 registered, 1 bad usage / pane not found / not an agent pane,
# 2 database unwritable (run-registry.sh's own failure).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"

label="${1:?usage: register-owner.sh <label> <pane|tab|label-target>}"
target="${2:?usage: register-owner.sh <label> <pane|tab|label-target>}"

# Exact mirror of the Worker's OWNER_LABEL regex (remote-mcp/worker/src/policy.ts) --
# refuse here too, so a typo'd label is caught at registration time, not on
# the first send attempt.
if [[ ! "$label" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]]; then
  echo "register-owner: label '$label' must match ^[a-z0-9][a-z0-9-]{1,40}\$ (lowercase/digits/hyphens, 2-41 chars)" >&2
  exit 1
fi

panes=$(herdr pane list 2>/dev/null) || { echo "register-owner: pane list failed" >&2; exit 1; }
case "$target" in
  *:p*) pane=$(printf '%s' "$panes" | jq -r --arg p "$target" '(.result.panes // .panes)[] | select(.pane_id==$p) | .pane_id' | head -1) ;;
  *:t*) pane=$(printf '%s' "$panes" | jq -r --arg t "$target" '(.result.panes // .panes)[] | select(.tab_id==$t) | .pane_id' | head -1) ;;
  *)    pane=$(printf '%s' "$panes" | jq -r --arg l "$target" '(.result.panes // .panes)[] | select(.label==$l) | .pane_id' | head -1) ;;
esac
[ -n "$pane" ] || { echo "register-owner: could not resolve target '$target'" >&2; exit 1; }
require_agent_pane "$pane" || exit 1

pane_birth=$(printf '%s' "$panes" | jq -r --arg p "$pane" '(.result.panes // .panes)[] | select(.pane_id==$p) | .terminal_id // empty')
workspace=$(printf '%s' "$panes" | jq -r --arg p "$pane" '(.result.panes // .panes)[] | select(.pane_id==$p) | .workspace // empty')
# Best-effort, like spawn-task.sh's own capture: herdr reports this natively
# for claude/codex (empty for omp today). Never fatal -- publisher.py's own
# identity re-check at delivery time falls back to pane_birth alone when this
# is empty, same as reconcile.sh already does for a task's agent_session.
agent_session=$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.agent_session.value // empty')

register_owner "$label" "$pane" "$pane_birth" "$agent_session" "$workspace" || exit 2
read_owner "$label"
