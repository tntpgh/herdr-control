#!/usr/bin/env bash
# spawn-agent.sh [--focus] <project-path> <role-label> [command...]
#
# Launch an agent SESSION in its own new tab of the project's workspace:
#   - ensure the project's workspace is open (ensure-workspace.sh, always --no-focus)
#   - create a tab in it, labeled <role-label>, cwd = the repo
#   - run <command> in that tab's pane (default: $HERDR_DEFAULT_AGENT)
#   - mark the pane 'working' so the tab shows active
#
# Default is BACKGROUND: the new tab does not steal focus from wherever you
# are (a spawned sub-agent/task worker should never yank your terminal out
# from under you). Pass --focus to jump to it immediately instead.
#
#   spawn-agent.sh ~/src/app fix-bug                    # default agent, background
#   spawn-agent.sh ~/src/app audit codex                # a specific agent, background
#   spawn-agent.sh --focus ~/src/app shell bash          # jump to the new tab
#
# NOTE: routes agent *sessions*, which become panes. It cannot route an in-process
# sub-agent (those are not herdr panes).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/repo-root.sh"

foc=--no-focus
args=()
for a in "$@"; do
  if [ "$a" = "--focus" ]; then foc=--focus; else args+=("$a"); fi
done
set -- "${args[@]}"

proj="${1:?usage: spawn-agent.sh [--focus] <project-path> <role-label> [command...]}"
role="${2:?usage: spawn-agent.sh [--focus] <project-path> <role-label> [command...]}"
shift 2
cmd=("$@"); [ "${#cmd[@]}" -eq 0 ] && cmd=("$HERDR_DEFAULT_AGENT")

# repo_root (lib/repo-root.sh), not --show-toplevel: inside a linked worktree
# --show-toplevel returns the WORKTREE's own path, which would give a task
# worktree its own separate workspace instead of joining its parent repo's.
root=$(repo_root "$proj")

ws=$(bash "$here/ensure-workspace.sh" --no-focus "$root") || exit 1

# Create the tab; the response carries both the tab and its root pane.
tc=$(herdr tab create --workspace "$ws" --cwd "$root" --label "$role" "$foc" 2>/dev/null)
tab=$(printf '%s' "$tc" | jq -r '.result.tab.tab_id // empty')
pane=$(printf '%s' "$tc" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$tab" ] && [ -n "$pane" ] || { echo "spawn-agent: tab create failed in $ws" >&2; exit 1; }

# Launch the agent command in the tab's shell pane (types command + Enter).
herdr pane run "$pane" "${cmd[*]}" >/dev/null 2>&1 \
  || { echo "spawn-agent: failed to run '${cmd[*]}' in $pane" >&2; exit 1; }

# Reflect 'active' on the tab immediately (the agent's own status hook takes over later).
herdr pane report-agent "$pane" --source "$HERDR_SOURCE" --agent "$role" --state working >/dev/null 2>&1 || true

bgtag="background"; [ "$foc" = --focus ] && bgtag="focused"
printf 'spawned %-14s ws=%s tab=%s pane=%s  cmd=%s  [%s]\n' "$role" "$ws" "$tab" "$pane" "${cmd[*]}" "$bgtag"
