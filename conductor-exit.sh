#!/usr/bin/env bash
# conductor-exit.sh — close worker panes whose branches have shipped, with the
# merged PR as proof. DRY-RUN BY DEFAULT.
#
#   conductor-exit.sh                          # this pane's workers ($HERDR_PANE_ID)
#   conductor-exit.sh --conductor=w19:p7       # a named conductor's workers
#   conductor-exit.sh --all                    # every registered worker
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
CLOSE_DONE_SH=$HERE/close-done-workers.sh
if [ "${HERDR_CONDUCTOR_EXIT_TEST_MODE:-0}" = 1 ]; then
  CLOSE_DONE_SH=${HERDR_CLOSE_DONE_SH:-$CLOSE_DONE_SH}
elif [ -n "${HERDR_CLOSE_DONE_SH:-}" ]; then
  echo "conductor-exit: dependency overrides require HERDR_CONDUCTOR_EXIT_TEST_MODE=1" >&2
  exit 3
fi

apply=0; summary=0; orphans=0; all=0; conductor="${HERDR_PANE_ID:-}"; conductor_explicit=0
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    --summary) summary=1 ;;
    --all) all=1 ;;
    --orphans) orphans=1 ;;
    --conductor=*) conductor="${a#--conductor=}"; conductor_explicit=$((conductor_explicit+1)) ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'conductor-exit: unknown flag %s\n' "$a" >&2; exit 2 ;;
  esac
done

scope_count=$((all + orphans + conductor_explicit))
[ "$scope_count" -le 1 ] || {
  echo "conductor-exit: --all, --orphans, and --conductor are mutually exclusive" >&2
  exit 2
}

pane_list_rc=0
pane_list_json=$(herdr pane list 2>/dev/null) || pane_list_rc=$?
live_panes=""
if [ "$pane_list_rc" -eq 0 ]; then
  live_panes=$(printf '%s' "$pane_list_json" | jq -er '(.result.panes // .panes) | if type == "array" then .[]?.pane_id else error("panes is not an array") end' 2>/dev/null) || live_panes=""
fi
is_live() { printf '%s\n' "$live_panes" | grep -qxF "$1"; }

if [ "$all" = 1 ]; then
  scope="1=1"
elif [ "$orphans" = 1 ]; then
  # An empty pane list (herdr down) would make every conductor look gone.
  [ -n "$live_panes" ] || { echo "conductor-exit: herdr returned no panes; refusing --orphans" >&2; exit 3; }
  scope="conductor_pane_id IS NOT NULL AND conductor_pane_id != ''"
else
  [ -n "$conductor" ] || { echo "conductor-exit: no conductor pane (set HERDR_PANE_ID or pass --conductor=)" >&2; exit 2; }
  scope="conductor_pane_id=$(_sq "$conductor")"
fi

query="SELECT task_id || '|' || pane_id || '|' || conductor_pane_id || '|' || worktree || '|' || label
       FROM tasks WHERE state IN ('running','blocked','starting') AND $scope ORDER BY updated_at;"
rows=$(_sql "$query") || {
  echo "conductor-exit: registry query failed" >&2
  exit 3
}

closable=0; held=0; apply_failed=0
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
  # A merged PR is only a candidate. Run the same dry safety gate that --apply
  # will re-run so --summary and the stop hook never call dirty, unpushed, or
  # prompted work "closable".
  if [ -z "$why" ]; then
    gate_rc=0
    gate_out=$(bash "$CLOSE_DONE_SH" --task="$task_id" 2>&1) || gate_rc=$?
    close_count=$(printf '%s\n' "$gate_out" | grep -Ec '^[[:space:]]*close[[:space:]]')
    if [ "$gate_rc" -ne 0 ] || [ "$close_count" -ne 1 ] || printf '%s\n' "$gate_out" | grep -Eq '^[[:space:]]*(HOLD|REFUSED)[[:space:]]'; then
      why=$(printf '%s\n' "$gate_out" | sed -En 's/^ *(HOLD|REFUSED) +[^ ]+ +[^ ]+ +//p' | sed -n '1p')
      [ -n "$why" ] || why="close-done-workers safety gate failed (exit $gate_rc)"
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
  close_rc=0
  close_out=$(bash "$CLOSE_DONE_SH" --apply --reason=shipped --task="$task_id" --proof="$proof" 2>&1) || close_rc=$?
  printf '%s\n' "$close_out" \
    | sed -En 's/^ *(HOLD|REFUSED)/    close-done-workers: \1/p; /^closed /s/^/    /p; /^close-done-workers: /s/^/    /p'
  if [ "$close_rc" -ne 0 ] || printf '%s\n' "$close_out" | grep -Eq '^[[:space:]]*(HOLD|REFUSED)[[:space:]]' \
    || ! printf '%s\n' "$close_out" | grep -q '^closed 1, held back 0, refused 0, pane-close failed 0$'; then
    apply_failed=$((apply_failed+1))
    printf '    close-done-workers: apply did not close exactly one task (exit %d)\n' "$close_rc" >&2
  fi
done <<<"$rows"

if [ "$summary" = 1 ]; then printf '%d %d\n' "$closable" "$held"; exit 0; fi
echo
if [ "$apply" = 1 ]; then
  printf '%d shipped task(s) sent to close-done-workers, %d held, %d failed\n' "$closable" "$held" "$apply_failed"
  [ "$apply_failed" -eq 0 ] || exit 4
else
  printf '%d shipped (closable), %d held — DRY RUN, nothing changed. Re-run with --apply\n' "$closable" "$held"
fi
