#!/usr/bin/env bash
# remove-clean-scratch.sh <path>... — remove throwaway DETACHED git worktrees
# that are provably disposable. Dry run unless --apply.
#
# A path is removed ONLY when ALL hold, re-checked at action time:
#   * it is a registered linked worktree with a detached HEAD;
#   * `git status --porcelain --ignored` prints NOTHING: any tracked change,
#     untracked file, ignored file or symlink HOLDs. This script never
#     unlinks, deletes or moves anything to make a tree look clean
#     (2026-10-21: a conductor unlinked an untracked .venv-bashlex to force a
#     "clean" removal outside the approved clean-only scope);
#   * HEAD is contained in at least one remote-tracking ref;
#   * no process has a file open under it (lsof).
# Removal is plain `git worktree remove` (never --force, never prune).
set -u
apply=0; paths=()
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) paths+=("$a") ;;
  esac
done
[ "${#paths[@]}" -gt 0 ] || { echo "usage: $0 [--apply] <worktree>..." >&2; exit 2; }

held=0
for p in "${paths[@]}"; do
  reason=""
  if [ ! -d "$p" ]; then reason="not a directory"
  elif ! top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) || [ "$(cd "$top" && pwd -P)" != "$(cd "$p" && pwd -P)" ]; then reason="not a worktree root"
  elif [ "$(git -C "$p" rev-parse --git-dir)" = "$(git -C "$p" rev-parse --git-common-dir)" ]; then reason="main checkout, not a linked worktree"
  elif git -C "$p" symbolic-ref -q HEAD >/dev/null; then reason="HEAD is on a branch (only detached scratch trees qualify)"
  elif ! st=$(git -C "$p" status --porcelain --ignored 2>/dev/null); then reason="git status failed"
  elif [ -n "$st" ]; then reason="$(printf '%s\n' "$st" | grep -c .) uncommitted/untracked/ignored item(s)"
  elif [ -z "$(git -C "$p" branch -r --contains HEAD 2>/dev/null)" ]; then reason="HEAD not contained in any remote-tracking ref"
  elif command -v lsof >/dev/null && lsof +D "$p" >/dev/null 2>&1; then reason="files open under it"
  fi
  if [ -n "$reason" ]; then
    held=$((held+1)); printf 'HOLD    %s  %s\n' "$p" "$reason"; continue
  fi
  if [ "$apply" = 1 ]; then
    if git -C "$p" worktree remove "$p" 2>/dev/null; then printf 'REMOVED %s\n' "$p"
    else held=$((held+1)); printf 'HOLD    %s  git worktree remove refused\n' "$p"; fi
  else
    printf 'would remove %s (dry run)\n' "$p"
  fi
done
[ "$held" = 0 ]
