#!/usr/bin/env bash
# close-done-workers.sh — close worker panes whose work is safely landed, and
# settle their registry rows. DRY-RUN BY DEFAULT.
#
#   close-done-workers.sh            # show what would close, change nothing
#   close-done-workers.sh --apply    # actually close
#   close-done-workers.sh --apply --include-lost
#
# ---- the distinction this script exists to enforce --------------------------
# Closing a PANE and removing a WORKTREE are different operations with wildly
# different blast radius, and conflating them is how work disappears:
#
#   * closing a pane      — reversible. The worktree, its branch, and every
#                           commit survive untouched. Worst case you reopen it.
#   * removing a worktree — destroys uncommitted files, and orphans commits
#                           that exist on no remote.
#
# This script does ONLY the first, and never the second. Measured 2026-09-22:
# `worktree_debt` reported ~40 worktrees holding commits NOT ON ANY REMOTE and
# several with dirty trees. A cleanup that swept those would have been
# unrecoverable. Worktree removal stays a deliberate, separate, human act.
#
# ---- what makes a pane closable --------------------------------------------
# All four, verified per-pane at run time rather than assumed:
#   1. herdr reports the pane idle or done (never `working`)
#   2. its worktree is gone, OR
#   3. the worktree is clean (no uncommitted files) AND
#   4. its branch has no unpushed commits
#
# A pane failing any check is REPORTED and skipped, never closed quietly —
# the whole point is that the operator sees what was held back and why.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/run-registry.sh
source "$HERE/lib/run-registry.sh"

apply=0; include_lost=0
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    --include-lost) include_lost=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'close-done-workers: unknown flag %s\n' "$a" >&2; exit 1 ;;
  esac
done

states="'running','blocked','starting'"
[ "$include_lost" = 1 ] && states="$states,'lost'"

panes_json=$(herdr pane list 2>/dev/null)
pane_status() { printf '%s' "$panes_json" | jq -r --arg p "$1" '((.result.panes // .panes)[]|select(.pane_id==$p)|.agent_status) // "absent"'; }

closable=0; held=0
while IFS='|' read -r run_id task_id pane wt label; do
  [ -n "$pane" ] || continue
  st=$(pane_status "$pane")
  reason=""
  case "$st" in
    working) reason="pane is WORKING" ;;
  esac
  if [ -z "$reason" ] && [ -d "$wt" ]; then
    br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    up=$(git -C "$wt" for-each-ref --format='%(upstream:short)' "refs/heads/$br" 2>/dev/null)
    [ "${dirty:-0}" != 0 ] && reason="$dirty uncommitted file(s)"
    if [ -z "$reason" ]; then
      if [ -z "$up" ]; then
        reason="branch $br has no upstream (commits exist only here)"
      else
        un=$(git -C "$wt" rev-list --count "$up..$br" 2>/dev/null)
        [ "${un:-0}" != 0 ] && reason="$un unpushed commit(s) on $br"
      fi
    fi
  fi

  if [ -n "$reason" ]; then
    held=$((held+1))
    printf '  HOLD   %-8s %-46s %s\n' "$pane" "$label" "$reason"
    continue
  fi
  closable=$((closable+1))
  printf '  close  %-8s %-46s (%s)\n' "$pane" "$label" "$st"
  [ "$apply" = 1 ] || continue

  # Settle the registry FIRST. If the pane close succeeds and this did not
  # run, the task stays `running` forever against a pane that no longer
  # exists — which is precisely the stale state that made the attention view
  # report seven phantom items all day.
  set_task_state "$run_id" "$task_id" "completed" >/dev/null 2>&1 ||
    set_task_state "$run_id" "$task_id" "cancelled" >/dev/null 2>&1
  [ -x "$HERE/claim.sh" ] && HERDR_PANE_ID="$pane" "$HERE/claim.sh" drop >/dev/null 2>&1
  [ "$(pane_status "$pane")" = absent ] || herdr pane close "$pane" >/dev/null 2>&1
done < <(_sql "SELECT run_id || '|' || task_id || '|' || pane_id || '|' || worktree || '|' || label
               FROM tasks WHERE state IN ($states) ORDER BY updated_at;")

echo
if [ "$apply" = 1 ]; then
  printf 'closed %d, held back %d\n' "$closable" "$held"
else
  printf '%d closable, %d held back — DRY RUN, nothing changed. Re-run with --apply\n' "$closable" "$held"
fi
