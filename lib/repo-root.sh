#!/usr/bin/env bash
# lib/repo-root.sh — canonical PROJECT root for a path, worktree-aware.
#
# Extracted from ensure-workspace.sh so spawn-agent.sh and spawn-task.sh stop
# carrying their own naive `git rev-parse --show-toplevel` copy. That copy
# diverged in a way that mattered: --show-toplevel inside a linked worktree
# returns the WORKTREE's own path, not the shared main-repo root, so calling
# spawn-task.sh again against an existing task worktree (the natural "worker
# spawns a nested sub-task" pattern this toolkit targets) named the new
# worktree's parent directory after the sub-worktree instead of the real
# project — worktrees scattered under the wrong parent on disk. This is the
# ONE place that resolution lives now.
#
# --git-common-dir points at the MAIN repo's .git from anywhere, worktree
# included, so a worktree and its parent always resolve to the same root.

repo_root() {  # <path> -> canonical project root
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
