#!/usr/bin/env bash
# ensure-workspace.sh [--no-focus] <project-path>
#
# Print the workspace_id for a project, focusing an existing workspace if one is
# already open on that repo, else creating one. "Open on that repo" is decided by
# pane cwd (herdr pane list carries cwd + workspace_id) — the workspace `worktree`
# field is only populated for herdr-managed worktrees, and labels are cosmetic, so
# cwd is the reliable key. Matches by git top-level so a subdir pane still counts.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/repo-root.sh"

focus=1
[ "${1:-}" = "--no-focus" ] && { focus=0; shift; }
proj="${1:?usage: ensure-workspace.sh [--no-focus] <project-path>}"
[ -d "$proj" ] || { echo "ensure-workspace: not a directory: $proj" >&2; exit 1; }

# Canonical PROJECT root — repo_root (lib/repo-root.sh), shared with
# spawn-agent.sh/spawn-task.sh so all three agree on which repo a path
# belongs to.

root=$(repo_root "$proj")
label=$(basename "$root")

# Find an open workspace whose panes sit in this repo. Panes are matched through
# the same resolver, so a pane sitting in a worktree of this repo counts as being
# "on" the repo — which is what makes an existing project workspace get reused.
ws=$(
  herdr pane list 2>/dev/null \
    | jq -r '(.result.panes // .panes)[] | select((.cwd // "") != "") | [.workspace_id, .cwd] | @tsv' \
    | while IFS=$'\t' read -r w cwd; do
        cr=$(repo_root "$cwd")
        [ "$cr" = "$root" ] && { printf '%s\n' "$w"; break; }
      done | head -1
)

if [ -n "$ws" ]; then
  [ "$focus" = 1 ] && herdr workspace focus "$ws" >/dev/null 2>&1
  printf '%s\n' "$ws"
  exit 0
fi

# Create it. herdr auto-creates a root tab as part of workspace creation but
# gives it no label of its own (herdr's bare default is just the tab's
# position number, e.g. "1") — every OTHER tab in this repo's tooling gets a
# real label at creation (spawn-task.sh's worker tabs, layout.sh's project
# tabs), so a workspace's own root tab was the one gap left showing up as
# generic noise in herdr's Agents sidebar. Best-effort: a rename failing
# must not fail workspace creation, which already succeeded by this point.
foc=--no-focus; [ "$focus" = 1 ] && foc=--focus
ws_json=$(herdr workspace create --cwd "$root" --label "$label" "$foc" 2>/dev/null)
ws=$(printf '%s' "$ws_json" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$ws" ] || { echo "ensure-workspace: workspace create failed for $root" >&2; exit 1; }
tab_id=$(printf '%s' "$ws_json" | jq -r '.result.workspace.active_tab_id // empty')
[ -n "$tab_id" ] && herdr tab rename "$tab_id" "$label" >/dev/null 2>&1 || true
printf '%s\n' "$ws"
