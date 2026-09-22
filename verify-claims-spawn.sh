#!/usr/bin/env bash
# verify-claims-spawn.sh — the loop that makes the ownership view worth having:
# a spawned worker's worktree is claimed on its behalf, so attention.sh's
# UNOWNED list DISCRIMINATES instead of naming every task forever.
#
# Does not spawn a real pane (that needs a live herdr). It exercises the two
# halves that can be wrong independently: the claim spawn-task.sh makes, and
# the query attention.sh uses to subtract it.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

# mktemp -d hands back /tmp/..., and on macOS /tmp is a symlink to /private/tmp
# — so `git rev-parse --show-toplevel` (what claim.sh canonicalizes with)
# returns the /private form while a raw fixture path stays /tmp, and the two
# never compare equal. Real spawn paths do NOT have this problem (verified:
# ~/.herdr/worktrees/... and ~/Code/... resolve to themselves), so canonicalize
# the fixture up front rather than weaken the comparison the product uses.
TMPROOT=$(cd "$(mktemp -d)" && pwd -P)
export HERDR_RUN_STATE_DIR="$TMPROOT/state"
DB="$HERDR_RUN_STATE_DIR/registry.sqlite3"
REPO="$TMPROOT/repo"; WT_A="$TMPROOT/wt-a"; WT_B="$TMPROOT/wt-b"
for d in "$REPO" "$WT_A" "$WT_B"; do mkdir -p "$d" && git -C "$d" init -q 2>/dev/null; done

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

claim() { env -u HERDR_PANE_ID CLAIM_PANE_ID="$1" "$HERE/claim.sh" "${@:2}"; }
# The exact query attention.sh runs, so a change to one without the other fails
# here rather than silently degrading the view back to "everything is unowned".
#
# The expires_at test is load-bearing and was a real bug caught by this file:
# claims_expire() only runs on a read through the library, and this query goes
# straight to SQL — so a lapsed claim still had released_at NULL and kept
# hiding its task from the UNOWNED list forever. Exactly the "dead worker
# holds its worktree until someone notices" failure the TTL exists to prevent.
unowned() {
  sqlite3 -batch -noheader "$DB" \
    "SELECT label FROM tasks
      WHERE state IN ('running','blocked','starting')
        AND worktree NOT IN (SELECT scope FROM claims
                              WHERE released_at IS NULL AND expires_at > strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        AND repo     NOT IN (SELECT scope FROM claims
                              WHERE released_at IS NULL AND expires_at > strftime('%Y-%m-%dT%H:%M:%SZ','now'))
      ORDER BY updated_at ASC;" 2>/dev/null
}

# Two registered tasks in the SAME repo on different worktrees — the normal
# spawn-task pattern, and the case a repo-level claim would wrongly collide.
claim w:seed take "$REPO" -m seed >/dev/null 2>&1   # forces schema creation
claim w:seed drop "$REPO" >/dev/null 2>&1
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for pair in "task-a|$WT_A" "task-b|$WT_B"; do
  sqlite3 -batch "$DB" "INSERT INTO tasks(task_id,run_id,repo,worktree,label,state,created_at,updated_at)
    VALUES ('${pair%%|*}','run1','$REPO','${pair##*|}','${pair%%|*}','running','$now','$now');" 2>/dev/null
done

printf '\n== before any claim ==\n'
out=$(unowned)
case "$out" in *task-a*task-b*) ok "both spawned tasks report UNOWNED" ;; *) bad "both report UNOWNED" "$out" ;; esac

printf '\n== spawn-task.sh claims the WORKTREE on the worker behalf ==\n'
claim w:pw1 take "$WT_A" -m "implement:task-a" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && ok "worker pane claims its worktree" || bad "worker pane claims its worktree" "rc=$rc"

out=$(unowned)
case "$out" in
  *task-a*) bad "the claimed task drops off UNOWNED" "still listed: $out" ;;
  *task-b*) ok "the claimed task drops off UNOWNED, the other remains" ;;
  *)        bad "the unclaimed task still shows" "$out" ;;
esac

printf '\n== a second worker in the SAME repo is not blocked by the first ==\n'
claim w:pw2 take "$WT_B" -m "implement:task-b" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && ok "concurrent worktrees of one repo do not collide" \
              || bad "concurrent worktrees of one repo do not collide" "rc=$rc"
out=$(unowned)
[ -z "$out" ] && ok "with both claimed, UNOWNED is empty" || bad "UNOWNED is empty" "$out"

printf '\n== a dead worker returns its worktree via TTL, with no release call ==\n'
claim w:pw2 drop "$WT_B" >/dev/null 2>&1
HERDR_CLAIM_TTL_S=1 claim w:pw2 take "$WT_B" -m "implement:task-b" >/dev/null 2>&1
sleep 2
out=$(unowned)
case "$out" in *task-b*) ok "a lapsed worker claim resurfaces its task as UNOWNED" ;;
               *) bad "a lapsed worker claim resurfaces its task" "$out" ;; esac

printf '\n== summary ==\n'
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
