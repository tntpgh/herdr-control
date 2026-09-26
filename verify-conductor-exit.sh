#!/usr/bin/env bash
# verify-conductor-exit.sh — conductor-exit.sh closes ONLY workers whose PR
# merged (as `shipped`, with the PR URL + merge sha as proof), holds the rest,
# scopes to one conductor, and --orphans picks only workers whose conductor
# pane is gone. herdr and gh are stubbed functions; the registry is a
# throwaway HERDR_RUN_STATE_DIR. Nothing live is touched.
#
#   bash verify-conductor-exit.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

CALLS=$(mktemp); export CALLS
# Live panes: the conductor COND and workers p1..p4. The orphan's conductor
# (GONE) is deliberately absent.
herdr() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$1 $2" in
    "pane list") printf '{"result":{"panes":[{"pane_id":"COND","agent_status":"working","terminal_id":"bC"},{"pane_id":"p1","agent_status":"idle","terminal_id":"b1"},{"pane_id":"p2","agent_status":"idle","terminal_id":"b2"},{"pane_id":"p3","agent_status":"idle","terminal_id":"b3"},{"pane_id":"p4","agent_status":"idle","terminal_id":"b4"}]}}\n' ;;
    *) printf '{}\n' ;;
  esac
}
# gh pr list -R <slug> --head <branch> ... -q <jq>: answer by branch name.
# gh pr view <n> ... -q <jq>: the same PRs by number — close-done-workers.sh
# re-checks the proof against GitHub before recording `shipped`.
# GH_FAIL=1 fails every call.
gh() {
  [ "${GH_FAIL:-0}" = 1 ] && { echo "gh: stub failure" >&2; return 1; }
  local br="" q="" prev="" num=""
  [ "$1 $2" = "pr view" ] && num="$3"
  for a in "$@"; do
    [ "$prev" = "--head" ] && br="$a"; [ "$prev" = "-q" ] && q="$a"; prev="$a"
  done
  local json='[]'
  local all='[{"state":"CLOSED","url":"https://github.com/o/r/pull/1","mergeCommit":null},{"state":"MERGED","url":"https://github.com/o/r/pull/2","mergeCommit":{"oid":"abcdef0123456789abcdef0123456789abcdef01"}},{"state":"OPEN","url":"https://github.com/o/r/pull/3","mergeCommit":null},{"state":"MERGED","url":"https://github.com/o/r/pull/4","mergeCommit":{"oid":"1111111122222222333333334444444455555555"}}]'
  if [ -n "$num" ]; then
    printf '%s' "$all" | jq -e --arg n "/pull/$num" '.[] | select(.url|endswith($n))' >/dev/null || return 1
    printf '%s' "$all" | jq -c --arg n "/pull/$num" '.[] | select(.url|endswith($n))' | jq -r "$q"
    return
  fi
  case "$br" in
    feat/merged) json=$(printf '%s' "$all" | jq -c '[.[0], .[1]]') ;;
    feat/open)   json=$(printf '%s' "$all" | jq -c '[.[2]]') ;;
    feat/orphan) json=$(printf '%s' "$all" | jq -c '[.[3]]') ;;
  esac
  printf '%s' "$json" | jq -r "$q"
}
export -f herdr gh

export HERDR_RUN_STATE_DIR="$(mktemp -d)/runs"
. "$here/lib/run-registry.sh"

# A clean worktree on <branch> whose upstream is itself, with an origin URL
# that parses to o/r: nothing unpushed, so close-done-workers' safety checks pass.
mkwt() {
  local wt; wt=$(mktemp -d)/wt
  git init -q -b "$1" "$wt"
  git -C "$wt" -c user.email=someone@example.com -c user.name=t commit -q --allow-empty -m init
  git -C "$wt" remote add origin "https://github.com/o/r.git"
  git -C "$wt" update-ref "refs/remotes/origin/$1" "$(git -C "$wt" rev-parse HEAD)"
  git -C "$wt" branch -q --set-upstream-to="origin/$1" "$1"
  printf '%s' "$wt"
}
reg() {  # task pane birth conductor branch label
  local wt; wt=$(mkwt "$5")
  register_task "run_$1" "$1" w c "$4" bc "$2" "$3" "$wt" "$wt" "$6" >/dev/null 2>&1 || bad "register $1"
  set_task_state "run_$1" "$1" running >/dev/null 2>&1 || bad "$1 -> running"
}
reg t_merged p1 b1 COND feat/merged "merged-work"
reg t_open   p2 b2 COND feat/open   "open-pr-work"
reg t_nopr   p3 b3 COND feat/nopr   "no-pr-work"
reg t_orphan p4 b4 GONE feat/orphan "orphan-work"
state() { read_task "run_$1" "$1" | jq -r .state; }

printf '== dry-run: merged -> ship, open/no-PR -> HOLD, nothing changes ==\n'
: > "$CALLS"
out=$(bash "$here/conductor-exit.sh" --conductor=COND 2>&1)
printf '%s\n' "$out" | grep -q 'ship .*merged-work.*pull/2 abcdef01' && ok "merged PR shows ship with URL + 8-char sha (the MERGED one, not the older CLOSED PR)" || bad "ship line wrong: $out"
printf '%s\n' "$out" | grep -q 'HOLD .*open-pr-work.*PR still open' && ok "open PR held" || bad "open PR not held: $out"
printf '%s\n' "$out" | grep -q 'HOLD .*no-pr-work.*no PR' && ok "no-PR task held" || bad "no-PR task not held: $out"
printf '%s\n' "$out" | grep -q 'orphan-work' && bad "another conductor's task leaked into this scope" || ok "scoped to COND only"
grep -q 'pane close' "$CALLS" && bad "dry-run closed a pane" || ok "dry-run closed nothing"
check "merged task still running after dry-run" "$(state t_merged)" "running"

printf '== --summary: one "<closable> <held>" line ==\n'
check "summary counts" "$(bash "$here/conductor-exit.sh" --conductor=COND --summary)" "1 2"

printf '== gh failing -> every task HELD (lookup failed), nothing shipped ==\n'
out=$(GH_FAIL=1 bash "$here/conductor-exit.sh" --conductor=COND 2>&1)
printf '%s\n' "$out" | grep -q 'HOLD .*merged-work.*gh lookup failed' && ok "merged-branch task held when gh fails" || bad "not held: $out"
check "summary with gh failing" "$(GH_FAIL=1 bash "$here/conductor-exit.sh" --conductor=COND --summary)" "0 3"

printf '== --apply: only the merged task closes, as shipped with its proof ==\n'
: > "$CALLS"
bash "$here/conductor-exit.sh" --conductor=COND --apply >/dev/null 2>&1
check "merged task completed" "$(state t_merged)" "completed"
check "open-PR task untouched" "$(state t_open)" "running"
check "no-PR task untouched" "$(state t_nopr)" "running"
grep -q 'pane close p1' "$CALLS" && ok "pane p1 closed" || bad "p1 not closed: $(cat "$CALLS")"
grep -q 'pane close p2\|pane close p3' "$CALLS" && bad "a held pane was closed" || ok "held panes left open"
ev=$(_sql "SELECT payload FROM events WHERE task_id='t_merged' AND type='state_changed' ORDER BY sequence DESC LIMIT 1;")
printf '%s' "$ev" | jq -e '.reason=="shipped" and (.proof|test("pull/2 abcdef01"))' >/dev/null \
  && ok "registry records reason=shipped with the PR proof" || bad "registry event: $ev"

printf '== --orphans: only workers whose conductor pane is gone ==\n'
out=$(bash "$here/conductor-exit.sh" --orphans 2>&1)
printf '%s\n' "$out" | grep -q 'ship .*orphan-work' && ok "orphan (conductor GONE) found" || bad "orphan missing: $out"
printf '%s\n' "$out" | grep -q 'open-pr-work\|no-pr-work' && bad "live conductor's workers treated as orphans" || ok "live conductor's workers excluded"

printf '== --orphans with an empty herdr pane list -> refuse (exit 3), close nothing ==\n'
herdr() { printf '%s\n' "$*" >> "$CALLS"; printf '{}\n'; }; export -f herdr
: > "$CALLS"
bash "$here/conductor-exit.sh" --orphans --apply >/dev/null 2>&1; check "exit 3 when herdr lists no panes" "$?" "3"
grep -q 'pane close' "$CALLS" && bad "closed a pane with no pane list" || ok "nothing closed without a pane list"

printf '== no conductor at all -> usage error, not "every task" ==\n'
HERDR_PANE_ID= bash "$here/conductor-exit.sh" >/dev/null 2>&1; check "exit 2 without a conductor" "$?" "2"

echo "-----"; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
