#!/usr/bin/env bash
# close-done-workers.sh — close worker panes whose work is safely landed, and
# settle their registry rows. DRY-RUN BY DEFAULT.
#
#   close-done-workers.sh            # show what would close, change nothing
#   close-done-workers.sh --apply --reason=no-follow-on
#   close-done-workers.sh --apply --reason=shipped --task=task_abc \
#     --proof="https://github.com/org/repo/pull/1 abc1234"
#
# `--reason=shipped` needs `--pane=<id>` or `--task=<id>`: one proof cannot
# honestly cover every closable task in a batch, so shipped scopes to
# exactly the one it is evidence for. Other reasons stay batch-wide.
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
# shellcheck source=lib/pane-guard.sh
source "$HERE/lib/pane-guard.sh"

apply=0; include_lost=0; closure_reason=""; closure_proof=""; pane_filter=""; task_filter=""
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    --include-lost) include_lost=1 ;;
    # Required with --apply: no shim defaults a closure reason here either
    # (project-contract-plan.md item 1) — the operator running this cleanup
    # states why these panes are closing, uniformly for the whole batch.
    # Mixed reasons across one run: filter panes and run it more than once.
    --reason=*) closure_reason="${a#--reason=}" ;;
    --proof=*) closure_proof="${a#--proof=}" ;;
    --pane=*) pane_filter="${a#--pane=}" ;;
    --task=*) task_filter="${a#--task=}" ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'close-done-workers: unknown flag %s\n' "$a" >&2; exit 1 ;;
  esac
done
if [ "$apply" = 1 ]; then
  _valid_closure_reason "$closure_reason" || {
    printf 'close-done-workers: --apply requires --reason=<shipped|handed_off_to:<x>|blocked_on:<x>|canceled|no-follow-on>\n' >&2
    exit 1
  }
fi

# `--pane=<id>` is herdr's own pane numbering, and herdr reuses a pane_id
# once a pane closes — a stale registry row left behind by a PREVIOUS
# occupant of that id still matches `pane_id=<id>` alone. pane_birth (the
# fingerprint lib/pane-guard.sh's require_pane_birth_match validates
# against, herdr's own terminal_id) disambiguates: only the row whose
# registered pane_birth equals the CURRENTLY LIVE occupant's terminal_id is
# what --pane=<id> actually means right now. A pane reporting no live
# occupant at all (fully closed, never recycled) has nothing else it could
# be confused with, so pane_id alone stays sufficient there.
pane_birth_filter=""
if [ -n "$pane_filter" ]; then
  live_birth="$(pane_birth_now "$pane_filter")"
  [ -n "$live_birth" ] && pane_birth_filter=" AND pane_birth=$(_sq "$live_birth")"
fi

states="'running','blocked','starting'"
[ "$include_lost" = 1 ] && states="$states,'lost'"
[ -n "$pane_filter" ] && states_filter=" AND pane_id=$(_sq "$pane_filter")$pane_birth_filter" || states_filter=""
[ -n "$task_filter" ] && states_filter="$states_filter AND task_id=$(_sq "$task_filter")"

if [ "$apply" = 1 ] && [ "$closure_reason" = shipped ]; then
  # One proof cannot honestly stand for every closable task in a batch —
  # scope it to exactly the task it is evidence for. `--task=` is the
  # precise identifier; `--pane=` is the convenience form, resolved above
  # to the exact same row the main scan below will act on: state, pane_id,
  # and — when the pane is live — pane_birth all agree.
  { [ -n "$pane_filter" ] || [ -n "$task_filter" ]; } || {
    printf 'close-done-workers: --reason=shipped requires --pane=<id> or --task=<id> to scope the proof to one task\n' >&2
    exit 1
  }
  # A GONE pane (no live occupant at all) falls back to matching by
  # pane_id alone above, which is fine for a batch reason but NOT for
  # shipped: two stale rows can share one recycled pane_id with nobody
  # currently occupying it, and a proof validated against ONE of them
  # (via ORDER BY ... LIMIT 1 below) could otherwise get applied while the
  # main scan processes a DIFFERENT row first — refuse outright rather
  # than guess which one the proof is actually evidence for.
  match_count=$(_sql "SELECT count(*) FROM tasks WHERE state IN ($states)$states_filter;" 2>/dev/null)
  if [ "${match_count:-0}" -gt 1 ]; then
    printf 'close-done-workers: --reason=shipped matches %s tasks for this scope — refusing (one proof cannot cover more than one task; use --task=<id> to disambiguate)\n' "$match_count" >&2
    exit 1
  fi
  proof_wt=$(_sql "SELECT worktree FROM tasks WHERE state IN ($states)$states_filter ORDER BY updated_at DESC LIMIT 1;" 2>/dev/null)
  _valid_proof_ref "$closure_proof" "$proof_wt" || {
    printf 'close-done-workers: --reason=shipped requires --proof="<merged PR URL> <merge sha>" or a non-empty PROOF.md section in the selected task'"'"'s worktree%s\n' "${_PROOF_REF_WHY:+ ($_PROOF_REF_WHY)}" >&2
    exit 1
  }
fi

panes_json=$(herdr pane list 2>/dev/null)
pane_status() { printf '%s' "$panes_json" | jq -r --arg p "$1" '((.result.panes // .panes)[]|select(.pane_id==$p)|.agent_status) // "absent"'; }

closable=0; held=0; refused=0
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
  if ! set_task_state "$run_id" "$task_id" "completed" "$closure_reason" "$closure_proof" >/dev/null 2>&1; then
    # NEVER silently fall back to `cancelled` here — that used to convert
    # ANY refusal (a proof that doesn't actually match THIS task, a race,
    # an illegal transition) into a fabricated successful outcome: pane
    # closed, run reporting "closed N" at exit 0. A refused transition
    # means something is wrong with this exact row; leave its state and
    # pane untouched so the operator sees it, instead of a lie.
    refused=$((refused+1))
    printf '  REFUSED %-8s %-46s registry refused the completed transition — left running, pane not closed\n' "$pane" "$label"
    continue
  fi
  [ -x "$HERE/claim.sh" ] && HERDR_PANE_ID="$pane" "$HERE/claim.sh" drop >/dev/null 2>&1
  [ "$(pane_status "$pane")" = absent ] || herdr pane close "$pane" >/dev/null 2>&1
done < <(_sql "SELECT run_id || '|' || task_id || '|' || pane_id || '|' || worktree || '|' || label
               FROM tasks WHERE state IN ($states)$states_filter ORDER BY updated_at;")

echo
if [ "$apply" = 1 ]; then
  printf 'closed %d, held back %d, refused %d\n' "$((closable - refused))" "$held" "$refused"
  [ "$refused" -eq 0 ] || exit 1
else
  printf '%d closable, %d held back — DRY RUN, nothing changed. Re-run with --apply\n' "$closable" "$held"
fi
