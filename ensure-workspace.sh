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

# Canonical repo root (fall back to the abs path for a non-git dir).
root=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null || (cd "$proj" && pwd))
label=$(basename "$root")

# Find an open workspace whose panes sit in this repo.
ws=$(
  herdr pane list 2>/dev/null \
    | jq -r '(.result.panes // .panes)[] | select((.cwd // "") != "") | [.workspace_id, .cwd] | @tsv' \
    | while IFS=$'\t' read -r w cwd; do
        cr=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")
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
