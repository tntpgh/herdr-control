#!/usr/bin/env bash
# ensure-workspace.sh [--no-focus] <project-path>
#
# Print the workspace_id for a project, focusing an existing workspace if one is
# already open on that repo, else creating one. "Open on that repo" is decided by
# pane cwd (herdr pane list carries cwd + workspace_id) — the workspace `worktree`
# field is only populated for herdr-managed worktrees, and labels are cosmetic, so
# cwd is the reliable key. Matches by git top-level so a subdir pane still counts.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

focus=1
[ "${1:-}" = "--no-focus" ] && { focus=0; shift; }
proj="${1:?usage: ensure-workspace.sh [--no-focus] <project-path>}"
[ -d "$proj" ] || { echo "ensure-workspace: not a directory: $proj" >&2; exit 1; }

# Canonical PROJECT root. Deliberately NOT --show-toplevel: inside a linked
# worktree that returns the WORKTREE's own path, so every worktree resolves to a
# different "project" and gets its own top-level workspace — task worktrees end up
# scattered beside real projects instead of grouped under the repo they belong to.
# --git-common-dir points at the MAIN repo's .git from anywhere, worktree
# included, so a worktree and its parent share one workspace.
repo_root() {
  local d="$1" common
  common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  if [ -z "$common" ]; then
    # Not a repo, or git too old for --path-format: best effort.
    git -C "$d" rev-parse --show-toplevel 2>/dev/null || (cd "$d" && pwd)
    return
  fi
  if [ "$(basename "$common")" = ".git" ]; then
    dirname "$common"
  else
    printf '%s' "$common"   # bare repo / unusual layout: the common dir is the repo
  fi
}

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

# Create it.
foc=--no-focus; [ "$focus" = 1 ] && foc=--focus
ws=$(herdr workspace create --cwd "$root" --label "$label" "$foc" 2>/dev/null \
       | jq -r '.result.workspace.workspace_id // empty')
[ -n "$ws" ] || { echo "ensure-workspace: workspace create failed for $root" >&2; exit 1; }
printf '%s\n' "$ws"
