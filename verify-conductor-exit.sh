#!/usr/bin/env bash
# verify-conductor-exit.sh — conductor-exit.sh closes ONLY workers whose PR
# merged (as `shipped`, with the PR URL + merge sha as proof), holds the rest,
# scopes to one conductor, --all covers every worker, and --orphans picks only
# workers whose conductor pane is gone. herdr and gh are stubbed functions; the
# registry is a throwaway HERDR_RUN_STATE_DIR. Nothing live is touched.
#
#   bash verify-conductor-exit.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

CALLS=$(mktemp); export CALLS
CLOSED_PANES=$(mktemp); export CLOSED_PANES
# Live panes: the conductor COND and workers p1..p4. The orphan's conductor
# (GONE) is deliberately absent. Successful close removes that pane from the
# next authoritative list, so the postcondition is real.
herdr() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$1 $2" in
    "pane list")
      closed=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$CLOSED_PANES")
      jq -nc --argjson closed "$closed" \
        '{result:{panes:[{pane_id:"COND",agent_status:"working",terminal_id:"bC"},{pane_id:"p1",agent_status:"idle",terminal_id:"b1"},{pane_id:"p2",agent_status:"idle",terminal_id:"b2"},{pane_id:"p3",agent_status:"idle",terminal_id:"b3"},{pane_id:"p4",agent_status:"idle",terminal_id:"b4"}] | map(select(.pane_id as $p | ($closed | index($p) | not)))}}'
      ;;
    "pane close") printf '%s\n' "$3" >> "$CLOSED_PANES" ;;
    *) printf '{}\n' ;;
  esac
}
# gh pr list -R <slug> --head <branch> ... -q <jq>: answer by branch name.
# gh pr view <n> ... -q <jq>: the same PRs by number — close-done-workers.sh
# re-checks the proof against GitHub before recording `shipped`.
# GH_FAIL=1 fails every call; GH_FAIL_VIEW=1 fails only `pr view` (the
# re-check), after `pr list` already found the merged PR.
gh() {
  [ "${GH_FAIL:-0}" = 1 ] && { echo "gh: stub failure" >&2; return 1; }
  [ "${GH_FAIL_VIEW:-0}" = 1 ] && [ "$1 $2" = "pr view" ] && { echo "gh: stub failure" >&2; return 1; }
  local br="" q="" prev="" num=""
  if [ "$1 $2" = "pr view" ]; then num="${3##*/}"; fi
  for a in "$@"; do
    [ "$prev" = "--head" ] && br="$a"; [ "$prev" = "-q" ] && q="$a"; prev="$a"
  done
  if [ "$q" = ".headRefOid" ]; then
    case "$num" in
      2) proof_label=merged-work ;;
      4) proof_label=orphan-work ;;
      *) return 1 ;;
    esac
    proof_wt=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
      "SELECT worktree FROM tasks WHERE label='$proof_label' LIMIT 1;") || return 1
    git -C "$proof_wt" rev-parse HEAD
    return
  fi
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

printf '== --all: every registered worker, independent of conductor ==\n'
out=$(bash "$here/conductor-exit.sh" --all 2>&1)
printf '%s\n' "$out" | grep -q 'ship .*merged-work' && ok "--all includes live conductor's merged worker" || bad "--all omitted merged worker: $out"
printf '%s\n' "$out" | grep -q 'ship .*orphan-work' && ok "--all includes orphaned merged worker" || bad "--all omitted orphan worker: $out"
printf '%s\n' "$out" | grep -q 'HOLD .*open-pr-work' && ok "--all still holds open PRs" || bad "--all did not hold open PR: $out"
check "--all summary counts" "$(bash "$here/conductor-exit.sh" --all --summary)" "2 2"

printf '== --all and --orphans are mutually exclusive ==\n'
bash "$here/conductor-exit.sh" --all --orphans >/dev/null 2>&1
check "conflicting scopes refuse" "$?" "2"
bash "$here/conductor-exit.sh" --all --conductor=COND >/dev/null 2>&1
check "--all plus explicit conductor refuses" "$?" "2"
bash "$here/conductor-exit.sh" --conductor=COND --conductor=GONE >/dev/null 2>&1
check "repeated conductor selectors refuse" "$?" "2"

printf '== gh failing -> every task HELD (lookup failed), nothing shipped ==\n'
out=$(GH_FAIL=1 bash "$here/conductor-exit.sh" --conductor=COND 2>&1)
printf '%s\n' "$out" | grep -q 'HOLD .*merged-work.*gh lookup failed' && ok "merged-branch task held when gh fails" || bad "not held: $out"
check "summary with gh failing" "$(GH_FAIL=1 bash "$here/conductor-exit.sh" --conductor=COND --summary)" "0 3"

printf '== merged PR head lookup failure -> held before mutation ==\n'
: > "$CALLS"
out=$(GH_FAIL_VIEW=1 bash "$here/conductor-exit.sh" --conductor=COND --apply 2>&1)
check "merged task NOT completed when its PR head cannot be bound" "$(state t_merged)" "running"
grep -q 'pane close' "$CALLS" && bad "a pane was closed without a bound PR head" || ok "nothing closed"
printf '%s\n' "$out" | grep -q 'merged PR head lookup failed' \
  && ok "head lookup failure reaches the operator" || bad "head failure swallowed: $out"

printf '== close-done-workers HOLDs a dirty worktree -> conductor-exit shows the HOLD line (macOS sed) ==\n'
wt_merged=$(read_task run_t_merged t_merged | jq -r .worktree)
touch "$wt_merged/uncommitted.txt"
: > "$CALLS"
out=$(bash "$here/conductor-exit.sh" --conductor=COND --apply 2>&1)
check "dirty merged task not completed" "$(state t_merged)" "running"
printf '%s\n' "$out" | grep -q 'HOLD .*merged-work.*uncommitted' \
  && ok "dry safety gate's HOLD reason reaches the operator" || bad "HOLD line swallowed: $out"
check "summary does not call dirty merged work closable" "$(bash "$here/conductor-exit.sh" --conductor=COND --summary)" "0 3"
rm -f "$wt_merged/uncommitted.txt"

printf '== nonzero safety gate cannot authorize from a close-looking line ==\n'
bad_gate=$(mktemp)
cat > "$bad_gate" <<'SH'
#!/usr/bin/env bash
echo "close p1 merged-work"
exit 7
SH
chmod +x "$bad_gate"
out=$(HERDR_CONDUCTOR_EXIT_TEST_MODE=1 HERDR_CLOSE_DONE_SH="$bad_gate" \
  bash "$here/conductor-exit.sh" --conductor=COND 2>&1)
printf '%s\n' "$out" | grep -q 'HOLD .*merged-work.*safety gate failed (exit 7)' \
  && ok "nonzero gate output is held despite a close-looking line" || bad "nonzero gate authorized closure: $out"
check "nonzero gate summary stays fail-closed" \
  "$(HERDR_CONDUCTOR_EXIT_TEST_MODE=1 HERDR_CLOSE_DONE_SH="$bad_gate" bash "$here/conductor-exit.sh" --conductor=COND --summary)" "0 3"
rm -f "$bad_gate"

printf '== apply failure propagates after a successful dry gate ==\n'
apply_gate=$(mktemp)
cat > "$apply_gate" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' --apply '*) echo "HOLD p1 merged-work simulated apply race"; echo "closed 0, held back 1, refused 0, pane-close failed 0"; exit 0 ;;
  *) echo "close p1 merged-work" ;;
esac
SH
chmod +x "$apply_gate"
HERDR_CONDUCTOR_EXIT_TEST_MODE=1 HERDR_CLOSE_DONE_SH="$apply_gate" \
  bash "$here/conductor-exit.sh" --conductor=COND --apply >/tmp/conductor-apply-failure.out 2>&1
check "apply-time HOLD returns nonzero" "$?" "4"
grep -q 'apply did not close exactly one task' /tmp/conductor-apply-failure.out \
  && ok "apply-time HOLD reaches the operator" || bad "apply-time HOLD was hidden"
check "failed apply leaves task running" "$(state t_merged)" "running"
rm -f "$apply_gate" /tmp/conductor-apply-failure.out

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

printf '== registry query failure never becomes a successful empty summary ==\n'
bad_state=$(mktemp)
out=$(HERDR_RUN_STATE_DIR="$bad_state" bash "$here/conductor-exit.sh" --conductor=COND --summary 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ok "registry query failure returns nonzero" || bad "registry query failure returned success"
[ "$out" != "0 0" ] && ok "registry failure is not reported as an empty scope" || bad "registry failure became 0 0"
rm -f "$bad_state"

echo "-----"; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
