#!/usr/bin/env bash
# close-done-workers.sh — close worker panes whose work is safely landed, and
# settle their registry rows. DRY-RUN BY DEFAULT.
#
#   close-done-workers.sh            # show what would close, change nothing
#   close-done-workers.sh --apply --reason=no-follow-on
#   close-done-workers.sh --apply --reason=shipped --task=task_abc \
#     --proof="https://github.com/org/repo/pull/1 abc1234"
#   close-done-workers.sh --apply --reason=superseded --task=task_old \
#     --superseded-by=task_new --proof=".handoffs/PROOF.md#check"
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
#
# ---- detached-HEAD reviewer closure -----------------------------------------
# A worktree with no branch (detached HEAD) has nothing the four checks
# above can evaluate — `git rev-parse --abbrev-ref HEAD` just prints the
# literal string "HEAD". Such a row closes ONLY when the spawning conductor
# named a PR for it (lib/run-registry.sh's set_task_review_pr) and every
# one of a separate, stricter set of checks holds: see
# _detached_pr_check below and docs/proposals/2026-10-05-worktree-archival-
# and-detached-close.md. Every other detached-HEAD row (no PR recorded)
# still HOLDs, unchanged, via the plain "no upstream" fallthrough.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/run-registry.sh
source "$HERE/lib/run-registry.sh"
# shellcheck source=lib/pane-guard.sh
source "$HERE/lib/pane-guard.sh"
# shellcheck source=lib/worktree-archive.sh
source "$HERE/lib/worktree-archive.sh"

apply=0; include_lost=0; closure_reason=""; closure_proof=""; pane_filter=""; task_filter=""; task_given=0; superseded_by=""
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    --include-lost) include_lost=1 ;;
    # Required with --apply: no shim defaults a closure reason here either
    # (project-contract-plan.md item 1) — the operator running this cleanup
    # states why these panes are closing, uniformly for the whole batch.
    # Mixed reasons across one run: filter panes and run it more than once.
    --reason=*) closure_reason="${a#--reason=}" ;;
    # Rule 1 of the `superseded` close path (brief 2026-10-06): names the
    # NEWER review-class task that supersedes this older one, both reviewing
    # the same repo#PR. Required whenever --reason=superseded is given, in
    # dry-run too -- a dry run with no --superseded-by previews nothing new
    # and the plain "PR is OPEN" hold stands unchanged (item 6).
    --superseded-by=*) superseded_by="${a#--superseded-by=}" ;;
    --proof=*) closure_proof="${a#--proof=}" ;;
    --pane=*) pane_filter="${a#--pane=}" ;;
    --task=*) task_filter="${a#--task=}"; task_given=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'close-done-workers: unknown flag %s\n' "$a" >&2; exit 1 ;;
  esac
done
# An empty (or whitespace-only) --task= is never "no filter" — it is a
# caller bug (e.g. `--task=$(jq -r .task_id identity.json)` against a
# missing/malformed identity.json). Falling through to the unfiltered scan
# closed EVERY eligible pane fleet-wide, twice, 2026-09-30. A flag that was
# never passed at all (task_given=0) is the one case that legitimately
# means batch mode and must keep working.
if [ "$task_given" = 1 ] && [ -z "${task_filter//[[:space:]]/}" ]; then
  printf 'close-done-workers: --task= was given but empty — refusing (an empty filter would match every task; omit --task entirely for batch mode)\n' >&2
  exit 1
fi
if [ "$apply" = 1 ]; then
  _valid_closure_reason "$closure_reason" || {
    printf 'close-done-workers: --apply requires --reason=<shipped|handed_off_to:<x>|blocked_on:<x>|canceled|no-follow-on|abandoned|superseded>\n' >&2
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

if [ "$apply" = 1 ] && case "$closure_reason" in shipped|abandoned|superseded) true ;; *) false ;; esac; then
  # One proof cannot honestly stand for every closable task in a batch —
  # scope it to exactly the task it is evidence for. `--task=` is the
  # precise identifier; `--pane=` is the convenience form, resolved above
  # to the exact same row the main scan below will act on: state, pane_id,
  # and — when the pane is live — pane_birth all agree.
  { [ -n "$pane_filter" ] || [ -n "$task_filter" ]; } || {
    printf 'close-done-workers: --reason=%s requires --pane=<id> or --task=<id> to scope the proof to one task\n' "$closure_reason" >&2
    exit 1
  }
  # A GONE pane (no live occupant at all) falls back to matching by
  # pane_id alone above, which is fine for a batch reason but NOT for
  # shipped/abandoned/superseded: two stale rows can share one recycled
  # pane_id with nobody currently occupying it, and a proof validated
  # against ONE of them (via ORDER BY ... LIMIT 1 below) could otherwise
  # get applied while the main scan processes a DIFFERENT row first —
  # refuse outright rather than guess which one the proof is actually
  # evidence for.
  match_count=$(_sql "SELECT count(*) FROM tasks WHERE state IN ($states)$states_filter;" 2>/dev/null)
  if [ "${match_count:-0}" -gt 1 ]; then
    printf 'close-done-workers: --reason=%s matches %s tasks for this scope — refusing (one proof cannot cover more than one task; use --task=<id> to disambiguate)\n' "$closure_reason" "$match_count" >&2
    exit 1
  fi
  proof_wt=$(_sql "SELECT worktree FROM tasks WHERE state IN ($states)$states_filter ORDER BY updated_at DESC LIMIT 1;" 2>/dev/null)
  # `superseded`'s proof requirement depends on which of its two paths
  # this one scoped row actually takes. With no --superseded-by at all,
  # ONLY the older, CLOSED-unmerged `superseded` disposition is even
  # reachable (_superseded_check never runs) — pre-check exactly like
  # abandoned, so a missing/invalid proof refuses before any archiving,
  # never after (review PR #249 r2 N3: skipping this unconditionally left
  # a CLOSED+superseded run with no proof archiving first, then refused
  # by set_task_state — fails closed but leaves an orphan archive dir).
  # With --superseded-by given, which path applies is not yet known here
  # (that needs a per-row GitHub lookup the main scan below does): the
  # OPEN-PR bypass's own rules 1-4 (newer review, clean tree, provable
  # ancestry, verified archive) already ARE the proof and need no
  # separate --proof (review PR #249: "superseded must never require a
  # merged-PR proof — the PR is OPEN by definition, so the proof is the
  # archive and the newer task"); set_task_state re-checks that evidence
  # itself and falls back to requiring a real proof for anything else,
  # including this same CLOSED-unmerged disposition when --superseded-by
  # happened to be given alongside it.
  if [ "$closure_reason" != superseded ] || [ -z "$superseded_by" ]; then
    _valid_proof_ref "$closure_proof" "$proof_wt" || {
      printf 'close-done-workers: --reason=%s requires --proof="<merged PR URL> <merge sha>" or a non-empty PROOF.md section in the selected task'"'"'s worktree%s\n' "$closure_reason" "${_PROOF_REF_WHY:+ ($_PROOF_REF_WHY)}" >&2
      exit 1
    }
  fi
fi

panes_json=$(herdr pane list 2>/dev/null)
# F2 (security review round 2, 2026-10-04): `herdr pane list` failing (empty
# output, or any shape jq cannot walk) used to make every status query
# return "" from jq's own stderr-only failure, which matched none of the
# case arms below and fell through to CLOSABLE -- the exact opposite of
# "fail closed" for a check that exists to gate on whether a pane is still
# being used. Validate the shape ONCE, and every row holds, not passes,
# when it cannot be verified at all.
panes_ok=0
printf '%s' "$panes_json" | jq -e '(.result.panes // .panes) | type == "array"' >/dev/null 2>&1 && panes_ok=1
pane_status() {
  [ "$panes_ok" = 1 ] || { printf 'unknown'; return; }
  printf '%s' "$panes_json" | jq -r --arg p "$1" '((.result.panes // .panes)[]|select(.pane_id==$p)|.agent_status) // "absent"'
}
# F1: herdr reuses a pane_id once a pane closes (documented above, lines
# 78-86) -- a row's pane_id alone can match a DIFFERENT, unrelated live
# session. Only a pane whose LIVE terminal_id (birth) matches what this row
# registered is actually the session this row thinks it is; a pane with NO
# live occupant at all (closed, never recycled) has nothing else it could
# be confused with and stays matchable by id alone.
pane_live_birth() {
  [ "$panes_ok" = 1 ] || { printf ''; return; }
  printf '%s' "$panes_json" | jq -r --arg p "$1" '((.result.panes // .panes)[]|select(.pane_id==$p)|.terminal_id) // empty'
}

# _detached_pr_check <worktree> <run_id> <task_id> <repo_path> <repo_slug> \
#                     <pr_number> <requested-reason> <apply:0|1> [superseded_by_task_id]
#
# Sets _DPR_REASON (HOLD text; empty means closable), _DPR_STATE (the PR's
# gh state), _DPR_HEAD_SHA, _DPR_REF_SHA, _DPR_ARCHIVE_MANIFEST (path, or
# empty when there was nothing to archive), _DPR_VIA ("superseded" when the
# closure went through _superseded_check, empty otherwise) — the caller
# prints all of these regardless of outcome, which is this function's "log
# the tuple" contract.
#
# Order: (1) a PR must be named at all, (2) refs/pull/<N>/head on origin
# must equal HEAD exactly — RECOVERABILITY, not delivery, (3) no tracked
# changes and no untracked files (git plumbing, not `git status`, which
# honors status.showUntrackedFiles=no), (4) GitHub's PR state — asked
# BEFORE anything is archived, so an OPEN PR or a reason mismatch never
# leaves a fresh archive dir behind (review r1 L4 of PR #236): CLOSED never
# closes without a matching reason, MERGED needs shipped; an OPEN PR is a
# hold UNLESS --reason=superseded names a newer reviewing task via
# [superseded_by_task_id], in which case _superseded_check (brief
# 2026-10-06, "superseded close reason") runs its own stricter rule set
# past the usual "PR is OPEN" fallthrough, (5) every ignored artifact
# archived+verified (skipped when there are none; regenerable dirs like
# node_modules are left in place and listed in the manifest as EXCLUDED).
# A plain dry run (apply=0) never mutates the filesystem — archiving
# included — and never requires the requested reason to match: it previews
# pure eligibility; the printed state names which reason --apply will
# require.
_DPR_REASON=""; _DPR_STATE=""; _DPR_HEAD_SHA=""; _DPR_REF_SHA=""; _DPR_ARCHIVE_MANIFEST=""; _DPR_VIA=""
_detached_pr_check() {
  local wt="$1" run_id="$2" task_id="$3" repo_path="$4" repo_slug="$5" pr_num="$6" \
        want_reason="$7" apply="$8" superseded_by="${9:-}" \
        head_sha ref_sha td ut dirty files info state url oid repo_base ts archive_dir required \
        archive_root root_why
  _DPR_REASON=""; _DPR_STATE=""; _DPR_HEAD_SHA=""; _DPR_REF_SHA=""; _DPR_ARCHIVE_MANIFEST=""; _DPR_VIA=""

  if [ -z "$repo_slug" ] || [ -z "$pr_num" ]; then
    _DPR_REASON="detached HEAD with no PR recorded (conductor must call set_task_review_pr before this can close)"
    return
  fi

  head_sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  _DPR_HEAD_SHA="$head_sha"
  if [ -z "$head_sha" ]; then
    _DPR_REASON="could not resolve detached HEAD"
    return
  fi

  # The `superseded` close path bypasses the strict ref/dirty gates below —
  # which exist for "is this HEAD exactly the delivered commit" (merged) or
  # "is this worktree pristine" recoverability, neither of which fits a
  # still-OPEN PR a NEWER review has moved past. _superseded_check (brief
  # 2026-10-06) does its own, looser rules instead: ancestor-of-the-CURRENT-
  # PR-head (not equality), and dirty/untracked scoped to tmp/.handoffs. A
  # CLOSED-unmerged PR keeps its OWN, older `superseded`/`abandoned`
  # disposition below completely unchanged, whether or not --superseded-by
  # happens to be set (review PR #249 M4: this used to HOLD outright on any
  # non-OPEN state instead of falling through, silently breaking that older
  # contract whenever the caller passed --superseded-by at all).
  if [ "$want_reason" = superseded ] && [ -n "$superseded_by" ]; then
    if ! info=$(_gh_pr_lookup "$repo_slug" --number "$pr_num") || [ -z "$info" ]; then
      _DPR_REASON="could not determine PR state for $repo_slug#$pr_num (gh unavailable or failed)"
      return
    fi
    IFS='|' read -r state url oid <<<"$info"
    _DPR_STATE="$state"
    if [ "$state" = OPEN ]; then
      _superseded_check "$wt" "$run_id" "$task_id" "$repo_path" "$repo_slug" "$pr_num" \
        "$head_sha" "$superseded_by" "$apply"
      return
    fi
    # Not OPEN: fall through to the generic flow below, which already has
    # $state and skips its own lookup.
  fi

  ref_sha=$(git -C "$wt" ls-remote origin "refs/pull/$pr_num/head" 2>/dev/null | cut -f1)
  _DPR_REF_SHA="$ref_sha"
  if [ -z "$ref_sha" ]; then
    _DPR_REASON="could not resolve refs/pull/$pr_num/head on origin — recoverability not proven"
    return
  fi
  if [ "$ref_sha" != "$head_sha" ]; then
    _DPR_REASON="HEAD ($head_sha) does not match refs/pull/$pr_num/head ($ref_sha) — recoverability not proven"
    return
  fi

  if ! td=$(archive_enumerate_tracked_dirty "$wt") || ! ut=$(archive_enumerate_untracked "$wt"); then
    _DPR_REASON="git could not list tracked changes/untracked files"
    return
  fi
  dirty=$(printf '%s\n%s\n' "$td" "$ut" | grep -c .)
  if [ "$dirty" != 0 ]; then
    _DPR_REASON="$dirty uncommitted/untracked file(s)"
    return
  fi

  if [ -z "$state" ]; then
    if ! info=$(_gh_pr_lookup "$repo_slug" --number "$pr_num") || [ -z "$info" ]; then
      _DPR_REASON="could not determine PR state for $repo_slug#$pr_num (gh unavailable or failed)"
      return
    fi
    IFS='|' read -r state url oid <<<"$info"
    _DPR_STATE="$state"
  fi

  case "$state" in
    MERGED) required=shipped ;;
    CLOSED) required="abandoned or superseded" ;;
    *)
      _DPR_REASON="$repo_slug#$pr_num is ${state:-unknown} — not yet closable"
      return
      ;;
  esac
  if [ "$apply" = 1 ]; then
    case "$required|$want_reason" in
      shipped\|shipped|"abandoned or superseded|abandoned"|"abandoned or superseded|superseded") ;;
      *)
        _DPR_REASON="$repo_slug#$pr_num is $state — needs --reason=$required, not ${want_reason:-<empty>}"
        return
        ;;
    esac
  fi

  if ! files=$(archive_enumerate_ignored "$wt") || ! archive_split_regenerable "$files"; then
    _DPR_REASON="could not list ignored artifacts"
    return
  fi
  files="$_ARCHIVE_KEEP"
  if [ -n "$files" ]; then
    if [ "$apply" != 1 ]; then
      _DPR_REASON="$(printf '%s\n' "$files" | wc -l | tr -d ' ') ignored artifact(s) not yet archived (rerun with --apply to archive and close)"
      return
    fi
    repo_base="$(basename "$repo_path")"
    [ -n "$repo_base" ] || repo_base="unknown-repo"
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    archive_root="${HERDR_ARCHIVE_ROOT:-$HOME/Code/.archive/worktrees}"
    root_why=$(archive_root_why "$archive_root" "$wt")
    if [ -n "$root_why" ]; then
      _DPR_REASON="$root_why"
      return
    fi
    # Unique per run (pid) and created with a plain mkdir, never -p: two runs
    # in the same second must never share, and truncate, one manifest
    # (review r2 M3 of PR #236).
    archive_dir="$archive_root/$repo_base/detached-pr-$pr_num-$ts-$$"
    if ! mkdir -p "$archive_root/$repo_base" 2>/dev/null || ! mkdir "$archive_dir" 2>/dev/null; then
      _DPR_REASON="archiving ignored artifacts failed: could not create $archive_dir (or it already exists)"
      return
    fi
    if ! archive_copy_and_manifest "$wt" "$archive_dir" "$files"; then
      _DPR_REASON="archiving ignored artifacts failed: $_ARCHIVE_WHY"
      return
    fi
    if ! archive_verify_manifest "$wt" "$_ARCHIVE_MANIFEST"; then
      _DPR_REASON="archive verification failed: $_ARCHIVE_WHY"
      return
    fi
    if ! archive_record_exclusions "$archive_dir" "$_ARCHIVE_EXCLUDED"; then
      _DPR_REASON="$_ARCHIVE_WHY"
      return
    fi
    _DPR_ARCHIVE_MANIFEST="$_ARCHIVE_MANIFEST"
  fi
}

# _superseded_check <worktree> <run_id> <task_id> <repo_path> <repo_slug> \
#                    <pr_num> <old_head_sha> <superseded_by_task_id> <apply:0|1>
#
# The `superseded` close path (brief 2026-10-06): a review task whose PR is
# still OPEN holds forever under the plain _detached_pr_check rules above,
# even once a NEWER review of the exact same PR has made it redundant —
# live examples w6G:pB/pC/pH/pM/pK in tntpgh-dev. This closes that one row
# ONLY when every rule below holds; any failure sets _DPR_REASON (a HOLD,
# never a close) and changes nothing on disk.
#
# Rule 1: both tasks review-class (label "review:..." or "deep-review:...",
#   spawn-task.sh's two review job classes; every live example this closes
#   is deep-review), reviewing the same
#   repo#PR (compared via review_pr_repo/review_pr_number, the fields
#   set_task_review_pr already stamps for a detached reviewer), and the
#   named task was registered strictly after this one.
# Rule 2: zero dirty TRACKED files anywhere, and zero untracked files
#   outside tmp/ and .handoffs/ — those two dirs are what rule 4 archives;
#   anything else uncommitted/untracked is real work this must not discard.
# Rule 3: old HEAD is an ancestor of the PR's CURRENT refs/pull/<N>/head,
#   fetched fresh (never trusted from a stale local ref) — recoverable via
#   the newer review's own checkout, not merely "was reachable once". This
#   ancestry check against a ref fetched straight from origin proves HEAD's
#   own history is reachable from a remote object. A separate check reads
#   the worktree's own HEAD reflog (review PR #249 M2): any commit left
#   behind there by a stray local commit before re-detaching, not itself
#   reachable from the fetched PR head or any remote, is real work the
#   worktree-removal `git worktree remove` would otherwise destroy
#   unrecoverably (that reflog lives only in the worktree's own private
#   `logs/HEAD`, which no archive bundles today).
# Rule 4: every ignored file in the worktree is archived — not merely the
#   ones under tmp/ and .handoffs/ (review PR #249 M1: an ignored file
#   anywhere else, e.g. .private/, was silently dropped) — split via the
#   same archive_split_regenerable the generic detached path uses, unioned
#   with the untracked files rule 2 already proved confined to
#   tmp/.handoffs/. Each enumerator's own failure HOLDs rather than reading
#   as "nothing to archive" (review PR #249 M3). Archived via the same
#   copy-then-verify primitives _detached_pr_check uses, and the archive
#   dir always gets a HEAD.txt naming the old head — proof of what exactly
#   got superseded, independent of whether there was anything else to
#   copy. Dry run (apply=0) never archives (never mutates the filesystem):
#   it HOLDs when there is something that would need archiving, closable
#   when there is nothing to archive and rules 1-3 already passed.
# Rule 5: the caller (main loop below) records reason=superseded, this
#   task's id, superseded_by, the old head, the fetched PR head, and the
#   archive path in the state_changed event's detail payload — never
#   `shipped`, and never reusing _detached_pr_check's own detached-pr-*
#   archive naming (this uses superseded-*, a distinct lineage).
_superseded_check() {
  local wt="$1" run_id="$2" task_id="$3" repo_path="$4" repo_slug="$5" pr_num="$6" \
        head_sha="$7" superseded_by="$8" apply="$9" \
        old_json old_label old_created new_json new_label new_repo new_pr new_created \
        td td_n ut outside pr_head reflog c cnt ign files repo_base ts archive_root root_why archive_dir
  _DPR_REASON=""

  old_json=$(read_task "$run_id" "$task_id" 2>/dev/null)
  old_label=$(printf '%s' "$old_json" | jq -r '.label // ""' 2>/dev/null)
  old_created=$(printf '%s' "$old_json" | jq -r '.created_at // ""' 2>/dev/null)
  case "$old_label" in
    review:*|deep-review:*) ;;
    *) _DPR_REASON="this task (label=${old_label:-?}) is not review-class"; return ;;
  esac

  new_json=$(_sql "$(_task_json_select) WHERE task_id=$(_sq "$superseded_by") LIMIT 1;" 2>/dev/null)
  if [ -z "$new_json" ]; then
    _DPR_REASON="--superseded-by=$superseded_by does not match any registered task"
    return
  fi
  new_label=$(printf '%s' "$new_json" | jq -r '.label // ""' 2>/dev/null)
  new_repo=$(printf '%s' "$new_json" | jq -r '.review_pr_repo // ""' 2>/dev/null)
  new_pr=$(printf '%s' "$new_json" | jq -r '.review_pr_number // ""' 2>/dev/null)
  new_created=$(printf '%s' "$new_json" | jq -r '.created_at // ""' 2>/dev/null)
  case "$new_label" in
    review:*|deep-review:*) ;;
    *) _DPR_REASON="--superseded-by=$superseded_by (label=${new_label:-?}) is not review-class"; return ;;
  esac
  if [ "$new_repo" != "$repo_slug" ] || [ "$new_pr" != "$pr_num" ]; then
    _DPR_REASON="--superseded-by=$superseded_by reviews ${new_repo:-?}#${new_pr:-?}, not $repo_slug#$pr_num"
    return
  fi
  if [ -z "$new_created" ] || [ -z "$old_created" ] || ! [[ "$new_created" > "$old_created" ]]; then
    _DPR_REASON="--superseded-by=$superseded_by was not created after this task (new=${new_created:-?} old=${old_created:-?})"
    return
  fi

  if ! td=$(archive_enumerate_tracked_dirty "$wt") || ! ut=$(archive_enumerate_untracked "$wt"); then
    _DPR_REASON="git could not list tracked changes/untracked files"
    return
  fi
  td_n=$(printf '%s\n' "$td" | grep -c .)
  if [ "${td_n:-0}" != 0 ]; then
    _DPR_REASON="$td_n uncommitted tracked file(s)"
    return
  fi
  outside=$(printf '%s\n' "$ut" | grep -v '^$' | grep -vE '^(tmp/|\.handoffs/)')
  if [ -n "$outside" ]; then
    _DPR_REASON="$(printf '%s\n' "$outside" | grep -c .) untracked file(s) outside tmp/ and .handoffs/"
    return
  fi

  if ! git -C "$wt" fetch -q origin "refs/pull/$pr_num/head" 2>/dev/null; then
    _DPR_REASON="could not fetch refs/pull/$pr_num/head on origin"
    return
  fi
  pr_head=$(git -C "$wt" rev-parse FETCH_HEAD 2>/dev/null)
  _DPR_REF_SHA="$pr_head"
  if [ -z "$pr_head" ]; then
    _DPR_REASON="could not resolve refs/pull/$pr_num/head after fetch"
    return
  fi
  if ! git -C "$wt" merge-base --is-ancestor "$head_sha" "$pr_head" 2>/dev/null; then
    _DPR_REASON="HEAD ($head_sha) is not an ancestor of refs/pull/$pr_num/head ($pr_head) — not safely superseded"
    return
  fi
  # Rule 3 also covers the HEAD reflog: a commit this worktree once checked
  # out and left behind (e.g. a stray local commit before re-detaching at
  # the PR head) lives ONLY in <common>/worktrees/<id>/logs/HEAD, which
  # `git worktree remove` deletes outright — `merge-base --is-ancestor`
  # above only proves the CURRENT HEAD's own history, never the reflog
  # (review PR #249 M2). Any reflog entry that is neither an ancestor of
  # the fetched PR head nor already on some other remote means real,
  # unrecoverable work; fail closed on an unreadable reflog too.
  if ! reflog=$(git -C "$wt" log -g --format=%H HEAD 2>/dev/null); then
    _DPR_REASON="could not read the HEAD reflog"
    return
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    cnt=$(git -C "$wt" rev-list --count "$c" --not "$pr_head" --remotes 2>/dev/null)
    case "$cnt" in
      0) ;;
      *)
        _DPR_REASON="the HEAD reflog holds a commit ($c) not reachable from refs/pull/$pr_num/head or any remote — not safely superseded"
        return
        ;;
    esac
  done <<<"$reflog"
  # Rules 1-3 all hold: this row IS going through the superseded path,
  # regardless of what rule 4 (archiving) decides below — a dry run that
  # finds nothing to archive is closable via superseded exactly as much as
  # an --apply that archives something, and the caller's "(superseded)"
  # marker must show for both, not only once archiving has actually run.
  _DPR_VIA="superseded"
  # No separate "exists on no remote" rev-list check: `fetch`d straight from
  # origin, `pr_head` IS a remote object, and merge-base --is-ancestor above
  # already proved HEAD's entire history is reachable from it — rule 3's
  # "no commits that no remote contains" is satisfied BY that ancestry, not
  # by a second check. A `--not --remotes` rev-list check was tried here and
  # false-positived: `git fetch origin refs/pull/N/head` only updates
  # FETCH_HEAD, never a refs/remotes/origin/* ref, so `--remotes` never sees
  # commits that exist ONLY via a PR ref nobody has fetched into a tracking
  # branch — exactly this function's own normal case.

  # Rule 4 covers every ignored file in the worktree, not only ones under
  # tmp/ or .handoffs/ — a client-data file under .private/ or a stray
  # ignored file elsewhere is exactly the "real, unrecoverable work" rule 2
  # already refuses to discard when it is merely untracked; being ignored
  # must never be a loophole past that (review PR #249 M1). Split it the
  # same way the generic detached path does: a regenerable dir (e.g.
  # node_modules) is excluded-and-recorded, never copied; everything else
  # is archived. The untracked half ($ut) is already proven confined to
  # tmp/.handoffs/ by rule 2 above, so it is unioned in as-is. Each
  # enumerator's own failure HOLDs instead of silently reading as "nothing
  # to archive" (review PR #249 M3).
  if ! ign=$(archive_enumerate_ignored "$wt") || ! archive_split_regenerable "$ign"; then
    _DPR_REASON="could not list ignored artifacts"
    return
  fi
  files=$(printf '%s\n%s\n' "$_ARCHIVE_KEEP" "$ut" | grep -v '^$' | sort -u)

  if [ "$apply" != 1 ]; then
    if [ -n "$files" ]; then
      _DPR_REASON="$(printf '%s\n' "$files" | grep -c .) artifact(s) not yet archived (rerun with --apply to archive and close)"
    fi
    return
  fi

  repo_base="$(basename "$repo_path")"
  [ -n "$repo_base" ] || repo_base="unknown-repo"
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  archive_root="${HERDR_ARCHIVE_ROOT:-$HOME/Code/.archive/worktrees}"
  root_why=$(archive_root_why "$archive_root" "$wt")
  if [ -n "$root_why" ]; then
    _DPR_REASON="$root_why"
    return
  fi
  # superseded-* names this archive lineage distinctly from
  # _detached_pr_check's own detached-pr-*; unique per run (pid), never -p,
  # for the same reason given there.
  archive_dir="$archive_root/$repo_base/superseded-$pr_num-$ts-$$"
  if ! mkdir -p "$archive_root/$repo_base" 2>/dev/null || ! mkdir "$archive_dir" 2>/dev/null; then
    _DPR_REASON="archiving failed: could not create $archive_dir (or it already exists)"
    return
  fi
  if [ -n "$files" ]; then
    if ! archive_copy_and_manifest "$wt" "$archive_dir" "$files"; then
      _DPR_REASON="archiving failed: $_ARCHIVE_WHY"
      return
    fi
    if ! archive_verify_manifest "$wt" "$_ARCHIVE_MANIFEST"; then
      _DPR_REASON="archive verification failed: $_ARCHIVE_WHY"
      return
    fi
  fi
  if ! archive_record_exclusions "$archive_dir" "$_ARCHIVE_EXCLUDED"; then
    _DPR_REASON="$_ARCHIVE_WHY"
    return
  fi
  if ! printf '%s\n' "$head_sha" > "$archive_dir/HEAD.txt" 2>/dev/null; then
    _DPR_REASON="could not write HEAD.txt to $archive_dir"
    return
  fi
  _DPR_ARCHIVE_MANIFEST="$archive_dir"
}

closable=0; held=0; refused=0
while IFS='|' read -r run_id task_id pane pane_birth wt label trunk repo review_pr_repo review_pr_number; do
  [ -n "$pane" ] || continue
  dpr_tuple=""; dpr_detail=""; _DPR_VIA=""
  if [ "$panes_ok" != 1 ]; then
    reason="herdr pane list is unavailable or unparseable; status cannot be verified"
  else
    st=$(pane_status "$pane")
    reason=""
    case "$st" in
      working) reason="pane is WORKING" ;;
      ''|unknown) reason="pane status unknown" ;;
    esac
    if [ -z "$reason" ]; then
      live_birth=$(pane_live_birth "$pane")
      if [ -n "$live_birth" ] && [ -n "$pane_birth" ] && [ "$live_birth" != "$pane_birth" ]; then
        reason="pane_id recycled to a different session (pane_birth mismatch)"
      fi
    fi
  fi
  # abandoned/superseded describe ONE thing: a detached reviewer whose PR
  # closed unmerged, checked against GitHub in _detached_pr_check. On any
  # other row nothing would check them, so they HOLD (review r1 L3).
  if [ -z "$reason" ]; then
    case "$closure_reason" in
      abandoned|superseded)
        if [ ! -d "$wt" ] || git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1; then
          reason="--reason=$closure_reason is only for a detached-HEAD reviewer whose PR closed unmerged; this row is not one"
        fi
        ;;
    esac
  fi
  if [ -z "$reason" ] && [ -d "$wt" ]; then
    if git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1; then
      br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
      dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      up=$(git -C "$wt" for-each-ref --format='%(upstream:short)' "refs/heads/$br" 2>/dev/null)
      [ "${dirty:-0}" != 0 ] && reason="$dirty uncommitted file(s)"
      if [ -z "$reason" ]; then
        if [ -z "$up" ]; then
          # No upstream is only a risk when the branch holds commits no remote
          # has. A review/probe branch created on an already-pushed commit has
          # none — holding it made the conductor close such panes by hand, and
          # every one landed in the registry as `lost` (2026-09-28). A
          # research task's branch (git: none) is never pushed at all, so
          # `--remotes` alone is the wrong bar for it: also exclude whatever
          # the task's own recorded trunk resolves to (local or
          # remote-tracking) -- a branch still sitting on its base has
          # nothing any remote could lose, pushed or not. Without this, every
          # finished research task held forever since none ever push
          # (2026-10-02, caught by remote-mcp/verify-tasks-e2e.py).
          excl=(--remotes)
          if [ -n "$trunk" ]; then
            if git -C "$wt" show-ref --verify -q "refs/remotes/origin/$trunk"; then
              excl+=("refs/remotes/origin/$trunk")
            elif git -C "$wt" show-ref --verify -q "refs/heads/$trunk"; then
              excl+=("refs/heads/$trunk")
            fi
          fi
          only_here=$(git -C "$wt" rev-list --count "refs/heads/$br" --not "${excl[@]}" 2>/dev/null)
          case "$only_here" in
            0) ;;
            ''|*[!0-9]*) reason="branch $br has no upstream and its commits cannot be checked against the remotes" ;;
            *) reason="branch $br has no upstream ($only_here commit(s) exist only here)" ;;
          esac
        else
          un=$(git -C "$wt" rev-list --count "$up..$br" 2>/dev/null)
          [ "${un:-0}" != 0 ] && reason="$un unpushed commit(s) on $br"
        fi
      fi
    else
      # Detached HEAD: no branch, no upstream, nothing the checks above can
      # evaluate. Closable only via the stricter PR-recoverability path.
      _detached_pr_check "$wt" "$run_id" "$task_id" "$repo" "$review_pr_repo" "$review_pr_number" \
        "$closure_reason" "$apply" "$superseded_by"
      reason="$_DPR_REASON"
      dpr_tuple="pr=${review_pr_repo:-?}#${review_pr_number:-?} head=${_DPR_HEAD_SHA:-?} ref=${_DPR_REF_SHA:-?} state=${_DPR_STATE:-?} archive=${_DPR_ARCHIVE_MANIFEST:-none}${_DPR_VIA:+ via=$_DPR_VIA}"
      if [ "$_DPR_VIA" = superseded ]; then
        # Rule 5: record old/new task ids and superseded_by alongside the
        # usual pr/head/ref/archive tuple — never a `shipped` detail shape.
        dpr_detail=$(jq -nc --arg pr "${review_pr_repo}#${review_pr_number}" --arg head "$_DPR_HEAD_SHA" \
          --arg ref "$_DPR_REF_SHA" --arg state "$_DPR_STATE" --arg archive "$_DPR_ARCHIVE_MANIFEST" \
          --arg old_task "$task_id" --arg superseded_by "$superseded_by" \
          '{superseded_close: {pr: $pr, old_head: $head, pr_head: $ref, state: $state, archive: $archive,
            old_task: $old_task, superseded_by: $superseded_by}}')
      else
        dpr_detail=$(jq -nc --arg pr "${review_pr_repo}#${review_pr_number}" --arg head "$_DPR_HEAD_SHA" \
          --arg ref "$_DPR_REF_SHA" --arg state "$_DPR_STATE" --arg archive "$_DPR_ARCHIVE_MANIFEST" \
          '{detached_close: {pr: $pr, head: $head, ref: $ref, state: $state, archive: $archive}}')
      fi
    fi
  fi

  if [ -n "$reason" ]; then
    held=$((held+1))
    printf '  HOLD   %-8s %-46s %s\n' "$pane" "$label" "$reason"
    [ -n "$dpr_tuple" ] && printf '         %-8s %-46s %s\n' '' '' "$dpr_tuple"
    continue
  fi
  closable=$((closable+1))
  printf '  close  %-8s %-46s (%s)%s\n' "$pane" "$label" "$st" "${_DPR_VIA:+ (superseded)}"
  [ -n "$dpr_tuple" ] && printf '         %-8s %-46s %s\n' '' '' "$dpr_tuple"
  [ "$apply" = 1 ] || continue

  # Settle the registry FIRST. If the pane close succeeds and this did not
  # run, the task stays `running` forever against a pane that no longer
  # exists — which is precisely the stale state that made the attention view
  # report seven phantom items all day.
  if ! set_task_state "$run_id" "$task_id" "completed" "$closure_reason" "$closure_proof" "$dpr_detail" >/dev/null 2>&1; then
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
done < <(_sql "SELECT run_id || '|' || task_id || '|' || pane_id || '|' || pane_birth || '|' || worktree || '|' || label || '|' || trunk
               || '|' || repo || '|' || review_pr_repo || '|' || review_pr_number
               FROM tasks WHERE state IN ($states)$states_filter ORDER BY updated_at;")

echo
if [ "$apply" = 1 ]; then
  printf 'closed %d, held back %d, refused %d\n' "$((closable - refused))" "$held" "$refused"
  [ "$refused" -eq 0 ] || exit 1
else
  printf '%d closable, %d held back — DRY RUN, nothing changed. Re-run with --apply\n' "$closable" "$held"
fi
