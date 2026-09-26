#!/usr/bin/env bash
# conductor-exit.sh — a conductor's exit step: close every worker pane it
# dispatched whose work has SHIPPED, with the merged PR as proof. DRY-RUN BY
# DEFAULT.
#
#   conductor-exit.sh                          # this pane's workers ($HERDR_PANE_ID)
#   conductor-exit.sh --conductor=w19:p7       # a named conductor's workers
#   conductor-exit.sh --orphans                # workers whose conductor pane is gone
#   conductor-exit.sh --summary                # one line: "<closable> <held>", for hooks
#   ... --apply                                # actually close
#
# Why: a conductor that saves its session and lessons then exits leaves its
# finished workers open. Their panes sit idle, their registry rows stay
# `running`, and the hub counts them as needing attention. On 2026-09-24 a
# conductor tab (w19:p7) was closed with four workers whose PRs had all merged
# hours earlier; each needed a hand lookup of PR, merge sha and task id.
#
# Rule, per task: a MERGED PR for the worktree's branch → close as `shipped`
# with "<PR URL> <merge sha>" as proof. Anything else (open PR, no PR,
# worktree missing) is HELD and printed with the reason; closing those is
# a judgement call, not bookkeeping. The pane-level safety checks (not working,
# clean tree, nothing unpushed) are close-done-workers.sh's, reused as-is:
# this script only decides the reason and proof, never bypasses them.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/run-registry.sh
source "$HERE/lib/run-registry.sh"

apply=0; summary=0; orphans=0; conductor="${HERDR_PANE_ID:-}"
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    --summary) summary=1 ;;
    --orphans) orphans=1 ;;
    --conductor=*) conductor="${a#--conductor=}" ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'conductor-exit: unknown flag %s\n' "$a" >&2; exit 2 ;;
  esac
done

live_panes=$(herdr pane list 2>/dev/null | jq -r '(.result.panes // .panes)[]?.pane_id' 2>/dev/null)
is_live() { printf '%s\n' "$live_panes" | grep -qxF "$1"; }

if [ "$orphans" = 1 ]; then
  # An empty pane list (herdr down) would make every conductor look gone.
  [ -n "$live_panes" ] || { echo "conductor-exit: herdr returned no panes; refusing --orphans" >&2; exit 3; }
  scope="conductor_pane_id IS NOT NULL AND conductor_pane_id != ''"
else
  [ -n "$conductor" ] || { echo "conductor-exit: no conductor pane (set HERDR_PANE_ID or pass --conductor=)" >&2; exit 2; }
  scope="conductor_pane_id=$(_sq "$conductor")"
fi

closable=0; held=0
while IFS='|' read -r task_id pane cpane wt label; do
  [ -n "$task_id" ] || continue
  # --orphans: only tasks whose conductor pane no longer exists.
  if [ "$orphans" = 1 ] && is_live "$cpane"; then continue; fi
  why=""; proof=""
  if [ ! -d "$wt" ]; then
    why="worktree missing"
  else
    br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
    slug=$(git -C "$wt" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
    if ! pr=$(_gh_pr_lookup "$slug" --head "$br"); then
      why="gh lookup failed for $slug:$br"
    else
      IFS='|' read -r pr_state pr_url pr_oid <<<"$pr"
      case "$pr_state" in
        MERGED) if [ -n "$pr_oid" ]; then proof="$pr_url ${pr_oid:0:8}"; else why="merged PR reports no merge commit: $pr_url"; fi ;;
        OPEN)   why="PR still open: $pr_url" ;;
        CLOSED) why="PR closed unmerged: $pr_url" ;;
        *)      why="no PR for $slug:$br" ;;
      esac
    fi
  fi
  if [ -n "$why" ]; then
    held=$((held+1))
    [ "$summary" = 1 ] || printf '  HOLD   %-8s %-44s %s\n' "$pane" "$label" "$why"
    continue
  fi
  closable=$((closable+1))
  [ "$summary" = 1 ] && continue
  printf '  ship   %-8s %-44s %s\n' "$pane" "$label" "$proof"
  [ "$apply" = 1 ] || continue
  bash "$HERE/close-done-workers.sh" --apply --reason=shipped --task="$task_id" --proof="$proof" 2>&1 \
    | sed -n 's/^ *\(HOLD\|REFUSED\)/    close-done-workers: \1/p; /^closed /s/^/    /p'
done < <(_sql "SELECT task_id || '|' || pane_id || '|' || conductor_pane_id || '|' || worktree || '|' || label
               FROM tasks WHERE state IN ('running','blocked','starting') AND $scope ORDER BY updated_at;")

if [ "$summary" = 1 ]; then printf '%d %d\n' "$closable" "$held"; exit 0; fi
echo
if [ "$apply" = 1 ]; then
  printf '%d shipped task(s) sent to close-done-workers, %d held\n' "$closable" "$held"
else
  printf '%d shipped (closable), %d held — DRY RUN, nothing changed. Re-run with --apply\n' "$closable" "$held"
fi
