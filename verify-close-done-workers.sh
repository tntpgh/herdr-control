#!/usr/bin/env bash
# verify-close-done-workers.sh — proves the --apply closure-reason gate added
# for project-contract-plan.md item 1: --apply refuses without --reason (and
# --reason=shipped refuses without --proof) BEFORE ever asking herdr for a
# pane list, and a valid reason both closes the pane and writes the reason
# into the registry's completed transition.
#
# herdr is stubbed as an exported bash function — never the real binary — so
# this can never touch a live pane. Runs entirely against a throwaway
# HERDR_RUN_STATE_DIR.
#
#   bash verify-close-done-workers.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

CALLS=$(mktemp)
export CALLS
herdr() {
  printf '%s\n' "$1 $2" >> "$CALLS"
  case "$1 $2" in
    "pane list")  printf '{"result":{"panes":[{"pane_id":"pX","agent_status":"idle","terminal_id":"birthX"},{"pane_id":"pY","agent_status":"idle","terminal_id":"birthY"},{"pane_id":"pZ","agent_status":"idle","terminal_id":"birthZ"},{"pane_id":"pR","agent_status":"idle","terminal_id":"birthR-live"},{"pane_id":"pC","agent_status":"idle","terminal_id":"cbirthC"},{"pane_id":"pS1","agent_status":"idle","terminal_id":"birthS1"},{"pane_id":"pS2","agent_status":"idle","terminal_id":"birthS2"}]}}\n' ;;
    "pane close") : ;;
    *) printf '{}\n' ;;
  esac
}
export -f herdr
# gh stub (exported: close-done-workers.sh runs as its own bash): `gh pr view
# <n> -R <slug> … -q <jq>` answers from GH_PRS ("<slug>#<n> <STATE> <oid|->").
export GH_PRS="org/repo#2 MERGED abc1234000000000000000000000000000000000
org/repo#5 OPEN -"
gh() {
  local n="" slug="" q="" prev="" a key st oid
  [ "$1 $2" = "pr view" ] && n="$3"
  for a in "$@"; do [ "$prev" = -R ] && slug="$a"; [ "$prev" = -q ] && q="$a"; prev="$a"; done
  while read -r key st oid; do
    [ "$key" = "$slug#$n" ] || continue
    jq -nc --arg s "$st" --arg u "https://github.com/$slug/pull/$n" --arg o "$oid" \
      '{state:$s, url:$u, mergeCommit:(if $o=="-" then null else {oid:$o} end)}' | jq -r "$q"
    return 0
  done <<<"$GH_PRS"
  echo "GraphQL: Could not resolve to a PullRequest" >&2; return 1
}
export -f gh

export HERDR_RUN_STATE_DIR="$(mktemp -d)/runs"

# herdr-action.sh env overrides for the supersede-on-close tests below: a
# throwaway forms dir (never $HOME/.local/state/herdr) and a no-op send
# stub, so HERDR_PANE_ID=pC's conductor-authority supersede calls never
# touch a real pane or the real Slack bridge.
export HERDR_STATE_ROOT="$(mktemp -d)"
mkdir -p "$HERDR_STATE_ROOT/forms"
HA_SEND_STUB="$(mktemp -d)/send"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HA_SEND_STUB"
chmod +x "$HA_SEND_STUB"
export HERDR_ACTION_SEND="$HA_SEND_STUB"

. "$here/lib/run-registry.sh"
# A registered, running task whose worktree does not exist on disk: the
# script's own "held" logic (`[ -d "$wt" ]`) short-circuits to "closable"
# without needing real git plumbing — exactly the fixture this suite needs,
# not a claim about what a real worktree check does (that is unchanged code).
register_task run1 task1 w c cp cb pX birthX /repo/x /does/not/exist "closable" \
  || bad "register_task failed"
set_task_state run1 task1 running || bad "-> running failed (setup)"

printf '== --apply with no --reason: refused before any herdr call, nothing written ==\n'
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply >/tmp/cdw-out-$$.log 2>&1; then
  bad "--apply with no --reason was ACCEPTED"
else
  ok "--apply with no --reason refused"
fi
check "no herdr RPC was ever made" "$(wc -l < "$CALLS" | tr -d ' ')" "0"
check "task state untouched" "$(read_task run1 task1 | jq -r .state)" "running"

printf '== --task= (empty) is refused, never treated as "no filter" — the empty-task-closes-everything bug (2026-09-30) ==\n'
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply --reason=no-follow-on --task= >/tmp/cdw-out1b-$$.log 2>&1; then
  bad "--task= (empty) was ACCEPTED and ran as an unfiltered batch"
else
  ok "--task= (empty) refused"
fi
check "no herdr RPC was ever made" "$(wc -l < "$CALLS" | tr -d ' ')" "0"
check "task1 untouched by the refused empty --task=" "$(read_task run1 task1 | jq -r .state)" "running"
grep -q 'given but empty' /tmp/cdw-out1b-$$.log && ok "refusal names the empty --task" || bad "refusal text: $(cat /tmp/cdw-out1b-$$.log)"

printf '== --task="   " (whitespace-only) is refused the same way ==\n'
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply --reason=no-follow-on --task="   " >/tmp/cdw-out1c-$$.log 2>&1; then
  bad "--task=\"   \" (whitespace-only) was ACCEPTED"
else
  ok "--task=\"   \" (whitespace-only) refused"
fi
check "no herdr RPC was ever made" "$(wc -l < "$CALLS" | tr -d ' ')" "0"
check "task1 untouched by the refused whitespace --task=" "$(read_task run1 task1 | jq -r .state)" "running"

printf '== a dry run (no --apply) with --task= empty is refused too, not silently scanning everything ==\n'
: > "$CALLS"
if bash "$here/close-done-workers.sh" --task= >/tmp/cdw-out1d-$$.log 2>&1; then
  bad "dry-run with --task= (empty) was ACCEPTED"
else
  ok "dry-run with --task= (empty) refused"
fi
check "no herdr RPC was ever made" "$(wc -l < "$CALLS" | tr -d ' ')" "0"

printf '== --apply --reason=shipped with no --proof: refused before any herdr call ==\n'
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply --reason=shipped >/tmp/cdw-out2-$$.log 2>&1; then
  bad "--reason=shipped with no --proof was ACCEPTED"
else
  ok "--reason=shipped with no --proof refused"
fi
check "no herdr RPC was ever made" "$(wc -l < "$CALLS" | tr -d ' ')" "0"

printf '== dry-run (no --apply) needs no reason and writes nothing ==\n'
: > "$CALLS"
bash "$here/close-done-workers.sh" >/tmp/cdw-out3-$$.log 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "dry-run exits 0 with no --reason" || bad "dry-run exit $rc: $(cat /tmp/cdw-out3-$$.log)"
grep -q "close  pX" /tmp/cdw-out3-$$.log && ok "dry-run reports the pane as closable" || bad "dry-run output: $(cat /tmp/cdw-out3-$$.log)"
check "task state untouched by a dry-run" "$(read_task run1 task1 | jq -r .state)" "running"

printf '== --apply --reason=no-follow-on: closes the pane, reason lands in the registry ==\n'
: > "$CALLS"
bash "$here/close-done-workers.sh" --apply --reason=no-follow-on >/tmp/cdw-out4-$$.log 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "apply with a valid reason exits 0" || bad "exit $rc: $(cat /tmp/cdw-out4-$$.log)"
grep -q "^pane close$" "$CALLS" && ok "herdr pane close was called" || bad "no pane close RPC: $(cat "$CALLS")"
check "task marked completed" "$(read_task run1 task1 | jq -r .state)" "completed"
check "reason recorded on the state_changed event" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.reason') FROM events WHERE task_id='task1' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';")" \
  "no-follow-on"

printf '== --reason=shipped with NO --pane/--task: refused (one proof cannot cover a whole batch) ==\n'
register_task run2 task2 w c cp cb pY birthY /repo/y /does/not/exist "closable-2" || bad "register task2 failed"
set_task_state run2 task2 running || bad "task2 -> running failed (setup)"
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply --reason=shipped \
    --proof="https://github.com/org/repo/pull/2 abc1234" >/tmp/cdw-out5-$$.log 2>&1; then
  bad "shipped with no --pane/--task scoping was ACCEPTED"
else
  ok "shipped with no --pane/--task scoping refused"
fi
check "no herdr RPC was ever made" "$(wc -l < "$CALLS" | tr -d ' ')" "0"
check "task2 untouched" "$(read_task run2 task2 | jq -r .state)" "running"

printf '== --reason=shipped --task=<id>: closes ONLY that task, others in the batch untouched ==\n'
register_task run3 task3 w c cp cb pZ birthZ /repo/z /does/not/exist "closable-3" || bad "register task3 failed"
set_task_state run3 task3 running || bad "task3 -> running failed (setup)"
: > "$CALLS"
bash "$here/close-done-workers.sh" --apply --reason=shipped --task=task2 \
  --proof="https://github.com/org/repo/pull/2 abc1234" >/tmp/cdw-out6-$$.log 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "scoped shipped apply exits 0" || bad "exit $rc: $(cat /tmp/cdw-out6-$$.log)"
check "task2 (named by --task=) is completed" "$(read_task run2 task2 | jq -r .state)" "completed"
check "task3 (NOT named) stays running — one proof scoped to one task" \
  "$(read_task run3 task3 | jq -r .state)" "running"
check "task2's proof is exactly what was passed" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.proof') FROM events WHERE task_id='task2' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';")" \
  "https://github.com/org/repo/pull/2 abc1234"

printf '== --reason=shipped citing an OPEN PR head sha: refused, says why, nothing closed ==\n'
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply --reason=shipped --task=task3 \
    --proof="https://github.com/org/repo/pull/5 eb55756" >/tmp/cdw-out6b-$$.log 2>&1; then
  bad "shipped ACCEPTED with an open PR's head sha"
else
  ok "shipped refused with an open PR's head sha"
fi
grep -q "PR not merged (state OPEN)" /tmp/cdw-out6b-$$.log && ok "refusal names the open PR" || bad "refusal text: $(cat /tmp/cdw-out6b-$$.log)"
check "no herdr RPC was ever made" "$(wc -l < "$CALLS" | tr -d ' ')" "0"
check "task3 untouched" "$(read_task run3 task3 | jq -r .state)" "running"

printf '== --reason=shipped --pane=<id> with a PROOF.md that is still empty: refused via the same worktree-aware check ==\n'
wt3=$(mktemp -d)/wt3
git init -q -b main "$wt3"
git -C "$wt3" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$wt3/.handoffs"
printf '*\n' > "$wt3/.handoffs/.gitignore"
# A clean, upstream-tracked, self-ignoring repo so this fixture exercises
# ONLY the closure-reason/proof gate, not close-done-workers.sh's separate
# (and unchanged) "uncommitted file"/"no unpushed commits" hold checks.
git -C "$wt3" remote add origin "$wt3-origin-placeholder" 2>/dev/null
git -C "$wt3" update-ref refs/remotes/origin/main "$(git -C "$wt3" rev-parse HEAD)"
git -C "$wt3" branch --set-upstream-to=origin/main main >/dev/null
sqlite3 "$(registry_db)" "UPDATE tasks SET worktree=$(_sq "$wt3") WHERE task_id='task3';"
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply --reason=shipped --pane=pZ \
    --proof=".handoffs/PROOF.md#check" >/tmp/cdw-out7-$$.log 2>&1; then
  bad "shipped accepted against an EMPTY PROOF.md via close-done-workers"
else
  ok "shipped refused: the selected task's PROOF.md exists but is empty"
fi
check "no herdr pane-close mutation for the refused proof (a pane-list read to resolve pane_birth is expected)" "$(grep -c '^pane close$' "$CALLS")" "0"
printf 'verified: ran the check, output attached\n' > "$wt3/.handoffs/PROOF.md"
bash "$here/close-done-workers.sh" --apply --reason=shipped --pane=pZ \
  --proof=".handoffs/PROOF.md#check" >/tmp/cdw-out8-$$.log 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "shipped accepted once PROOF.md actually holds something" || bad "exit $rc: $(cat /tmp/cdw-out8-$$.log)"
check "task3 now completed" "$(read_task run3 task3 | jq -r .state)" "completed"

printf '== --pane=<id> whose pane_id was RECYCLED: a stale running row sharing that id is never matched (item 1) ==\n'
# Simulates herdr reissuing a closed pane's id to a brand-new occupant while a
# PREVIOUS registration for that same numeric id never got cleaned up. The
# live occupant is pR with terminal_id "birthR-live" per the herdr stub
# above; the stale row below deliberately carries a DIFFERENT (old)
# pane_birth for the same pane_id, and a non-empty PROOF.md that must never
# be read — if it is, the bug is still present.
stale_wt=$(mktemp -d)
mkdir -p "$stale_wt/.handoffs"
printf 'this belongs to the STALE, recycled-away task — must never be read\n' > "$stale_wt/.handoffs/PROOF.md"
register_task runR taskR-stale w c cp cb pR birthR-old "$stale_wt" "$stale_wt" "stale-recycled" \
  || bad "register taskR-stale failed"
set_task_state runR taskR-stale running || bad "taskR-stale -> running failed (setup)"

live_wt=$(mktemp -d)/wt-live
git init -q -b main "$live_wt"
git -C "$live_wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$live_wt/.handoffs"
printf '*\n' > "$live_wt/.handoffs/.gitignore"
git -C "$live_wt" remote add origin "$live_wt-origin-placeholder" 2>/dev/null
git -C "$live_wt" update-ref refs/remotes/origin/main "$(git -C "$live_wt" rev-parse HEAD)"
git -C "$live_wt" branch --set-upstream-to=origin/main main >/dev/null
register_task runR2 taskR-live w c cp cb pR birthR-live "$live_wt" "$live_wt" "current-live" \
  || bad "register taskR-live failed"
set_task_state runR2 taskR-live running || bad "taskR-live -> running failed (setup)"

: > "$CALLS"
bash "$here/close-done-workers.sh" --pane=pR >/tmp/cdw-out9-$$.log 2>&1
grep -q "current-live" /tmp/cdw-out9-$$.log \
  && ok "dry-run scoped to pR reports the LIVE task" \
  || bad "dry-run output missing the live task: $(cat /tmp/cdw-out9-$$.log)"
grep -q "stale-recycled" /tmp/cdw-out9-$$.log \
  && bad "dry-run scoped to pR ALSO matched the stale recycled row: $(cat /tmp/cdw-out9-$$.log)" \
  || ok "dry-run scoped to pR did not match the stale recycled row"

printf '== proof-worktree lookup for --pane=pR resolves to the LIVE task, never the stale one ==\n'
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply --reason=shipped --pane=pR \
    --proof=".handoffs/PROOF.md#check" >/tmp/cdw-out10-$$.log 2>&1; then
  bad "shipped accepted against pR — proof check must have read the STALE task's non-empty PROOF.md instead of the live task's empty one"
else
  ok "shipped refused: proof-worktree lookup scoped to the LIVE task's (empty) PROOF.md, not the stale task's"
fi
check "taskR-live untouched by the refused proof" "$(read_task runR2 taskR-live | jq -r .state)" "running"
check "taskR-stale untouched by the refused proof" "$(read_task runR taskR-stale | jq -r .state)" "running"

printf '== once the LIVE task'"'"'s own PROOF.md holds something, --apply --pane=pR settles ONLY it ==\n'
printf 'verified: ran the check, output attached\n' > "$live_wt/.handoffs/PROOF.md"
bash "$here/close-done-workers.sh" --apply --reason=shipped --pane=pR \
  --proof=".handoffs/PROOF.md#check" >/tmp/cdw-out11-$$.log 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "shipped accepted once the LIVE task's PROOF.md holds something" || bad "exit $rc: $(cat /tmp/cdw-out11-$$.log)"
check "taskR-live (the exact live task) is completed" "$(read_task runR2 taskR-live | jq -r .state)" "completed"
check "taskR-stale (the recycled-away row) is NEVER touched" "$(read_task runR taskR-stale | jq -r .state)" "running"

printf '== --reason=shipped --pane=<GONE id> matching TWO stale running rows: refused, never guesses which one (item 1, follow-up) ==\n'
# pG is never present in the herdr stub'"'"'s pane list — a genuinely GONE
# pane, not merely recycled. Two independent stale registrations share it
# (e.g. a pane assigned, abandoned, and reassigned to another task that
# also never got cleaned up) — nothing here disambiguates which one a
# single proof is evidence for.
gone_wt1=$(mktemp -d)/wt-gone-a
git init -q -b main "$gone_wt1"
git -C "$gone_wt1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$gone_wt1/.handoffs"
printf '*\n' > "$gone_wt1/.handoffs/.gitignore"
git -C "$gone_wt1" remote add origin "$gone_wt1-origin-placeholder" 2>/dev/null
git -C "$gone_wt1" update-ref refs/remotes/origin/main "$(git -C "$gone_wt1" rev-parse HEAD)"
git -C "$gone_wt1" branch --set-upstream-to=origin/main main >/dev/null
printf 'row A worktree — has content, must not be trusted as THE proof\n' > "$gone_wt1/.handoffs/PROOF.md"
register_task runG taskG-a w c cp cb pG birthG-a "$gone_wt1" "$gone_wt1" "gone-stale-a" \
  || bad "register taskG-a failed"
set_task_state runG taskG-a running || bad "taskG-a -> running failed (setup)"
gone_wt2=$(mktemp -d)/wt-gone-b
git init -q -b main "$gone_wt2"
git -C "$gone_wt2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$gone_wt2/.handoffs"
printf '*\n' > "$gone_wt2/.handoffs/.gitignore"
git -C "$gone_wt2" remote add origin "$gone_wt2-origin-placeholder" 2>/dev/null
git -C "$gone_wt2" update-ref refs/remotes/origin/main "$(git -C "$gone_wt2" rev-parse HEAD)"
git -C "$gone_wt2" branch --set-upstream-to=origin/main main >/dev/null
: > "$gone_wt2/.handoffs/PROOF.md"
register_task runG2 taskG-b w c cp cb pG birthG-b "$gone_wt2" "$gone_wt2" "gone-stale-b" \
  || bad "register taskG-b failed"
set_task_state runG2 taskG-b running || bad "taskG-b -> running failed (setup)"
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply --reason=shipped --pane=pG \
    --proof=".handoffs/PROOF.md#check" >/tmp/cdw-out12-$$.log 2>&1; then
  bad "shipped ACCEPTED against an ambiguous (2-row) gone-pane scope: $(cat /tmp/cdw-out12-$$.log)"
else
  ok "shipped refused: ambiguous gone-pane scope matched more than one task"
fi
grep -qi 'refus' /tmp/cdw-out12-$$.log && ok "refusal reason is explicit in the output" \
  || bad "no refusal message: $(cat /tmp/cdw-out12-$$.log)"
check "taskG-a untouched (not completed, not cancelled)" "$(read_task runG taskG-a | jq -r .state)" "running"
check "taskG-b untouched (not completed, not cancelled)" "$(read_task runG2 taskG-b | jq -r .state)" "running"
grep -q '^pane close$' "$CALLS" && bad "a pane was closed despite the refusal" || ok "no pane was closed for the ambiguous scope"

printf '== a completed transition the registry refuses prints REFUSED and never falls back to cancelled (item 1, follow-up) ==\n'
register_task runL taskL w c cp cb pL birthL "/does/not/exist" "/does/not/exist" "buried" || bad "register taskL failed"
set_task_state runL taskL running || bad "taskL -> running failed (setup)"
set_task_state runL taskL lost || bad "taskL -> lost failed (setup)"
: > "$CALLS"
if bash "$here/close-done-workers.sh" --apply --include-lost --reason=no-follow-on --task=taskL \
    >/tmp/cdw-out13-$$.log 2>&1; then
  bad "apply against an illegal (lost->completed) transition exited 0: $(cat /tmp/cdw-out13-$$.log)"
else
  ok "apply exits nonzero when the registry refuses the completed transition"
fi
grep -q 'REFUSED' /tmp/cdw-out13-$$.log \
  && ok "REFUSED is printed for the row the registry refused" \
  || bad "no REFUSED line: $(cat /tmp/cdw-out13-$$.log)"
check "taskL is still lost, NOT silently cancelled" "$(read_task runL taskL | jq -r .state)" "lost"
grep -q '^pane close$' "$CALLS" && bad "the pane was closed despite the refused transition" \
  || ok "the pane was left open, not closed, after the refusal"

printf '== no upstream: held only when commits exist on no remote ==\n'
nu_wt=$(mktemp -d)/wt-nu
git init -q -b main "$nu_wt"
git -C "$nu_wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$nu_wt/.handoffs"; printf '*\n' > "$nu_wt/.handoffs/.gitignore"
git -C "$nu_wt" update-ref refs/remotes/origin/main "$(git -C "$nu_wt" rev-parse HEAD)"
git -C "$nu_wt" switch -q -c review/pr-x          # a review branch on an already-pushed commit, no upstream
register_task runN taskN w c cp cb pY birthY "$nu_wt" "$nu_wt" "review:review/pr-x" || bad "register taskN failed"
set_task_state runN taskN running || bad "taskN -> running failed (setup)"
out=$(bash "$here/close-done-workers.sh" --task=taskN 2>&1)
printf '%s' "$out" | grep -q '^  close  pY' && ok "a no-upstream branch with nothing unique is closable" || bad "held a branch with nothing to lose: $out"
git -C "$nu_wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "local only"
out=$(bash "$here/close-done-workers.sh" --task=taskN 2>&1)
printf '%s' "$out" | grep -q 'HOLD.*1 commit(s) exist only here' && ok "a no-upstream branch with a local-only commit is still held" || bad "local-only commit not held: $out"

printf '== no upstream AND no remote-tracking ref at all: closable when nothing exists beyond the task'"'"'s own recorded trunk ==\n'
rt_wt=$(mktemp -d)/wt-trunk
git init -q -b main "$rt_wt"
git -C "$rt_wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$rt_wt/.handoffs"; printf '*\n' > "$rt_wt/.handoffs/.gitignore"
git -C "$rt_wt" switch -q -c remote/research-1   # no refs/remotes/origin/* at all -- a research task never fetches/pushes
register_task runT1 taskT1 w c cp cb pT1 birthT1 "$rt_wt" "$rt_wt" "research:remote/research-1" remote/research-1 main \
  || bad "register taskT1 failed"
set_task_state runT1 taskT1 running || bad "taskT1 -> running failed (setup)"
out=$(bash "$here/close-done-workers.sh" --task=taskT1 2>&1)
printf '%s' "$out" | grep -q '^  close  pT1' && ok "a branch with no remote tracking but zero commits beyond its recorded trunk is closable" || bad "held a research branch with nothing to lose: $out"
git -C "$rt_wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "research wrote something it should not have"
out=$(bash "$here/close-done-workers.sh" --task=taskT1 2>&1)
printf '%s' "$out" | grep -q 'HOLD.*1 commit(s) exist only here' && ok "a commit beyond trunk is still held -- trunk-awareness does not weaken the gate" || bad "commit beyond trunk not held: $out"

printf '== --task=<id> whose registered pane_birth does NOT match the LIVE occupant of that pane_id: HOLD, never closed (F1) ==\n'
# F1 (security review round 2, 2026-10-04): unlike --pane=<id> (which has
# always filtered on a live-birth match), --task=<id> mode used to trust
# pane_id ALONE -- a stale row recorded against a pane_id herdr has since
# reissued to a brand-new, unrelated live occupant (pX, terminal_id
# "birthX" per the herdr stub above) was treated as closable/idle just
# because that OTHER occupant happens to report idle right now.
register_task runRec taskRecycled w c cp cb pX birthX-OLD /repo/rec /does/not/exist "recycled-via-task" \
  || bad "register taskRecycled failed"
set_task_state runRec taskRecycled running || bad "taskRecycled -> running failed (setup)"
out=$(bash "$here/close-done-workers.sh" --task=taskRecycled 2>&1)
printf '%s' "$out" | grep -q 'HOLD.*pane_id recycled to a different session' \
  && ok "F1: --task mode holds a row whose pane_birth does not match the pane's LIVE occupant" \
  || bad "F1: recycled pane_id was not held via --task mode: $out"
check "taskRecycled untouched" "$(read_task runRec taskRecycled | jq -r .state)" "running"

printf '== herdr pane list unavailable/unparseable: every row HOLDs, none fall through to closable (F2) ==\n'
# F2 (security review round 2, 2026-10-04): a failed/garbled `herdr pane
# list` used to make pane_status() print nothing (jq's own stderr-only
# failure), st="", which matched NEITHER case arm below and fell through
# to CLOSABLE -- the opposite of fail-closed for a check that exists to
# gate on whether a pane is still in use.
old_herdr_fn="$(declare -f herdr)"
herdr() { printf '%s\n' "$1 $2" >> "$CALLS"; printf 'not valid json\n'; }
export -f herdr
register_task runNL taskNoList w c cp cb pNL birthNL /repo/nl /does/not/exist "no-pane-list" \
  || bad "register taskNoList failed"
set_task_state runNL taskNoList running || bad "taskNoList -> running failed (setup)"
out=$(bash "$here/close-done-workers.sh" --task=taskNoList 2>&1)
printf '%s' "$out" | grep -q 'HOLD.*pane list is unavailable or unparseable' \
  && ok "F2: an unparseable herdr pane list holds every row instead of treating it as closable" \
  || bad "F2: unparseable pane list did not hold the row: $out"
check "taskNoList untouched" "$(read_task runNL taskNoList | jq -r .state)" "running"
eval "$old_herdr_fn"
export -f herdr

printf '== --apply supersedes a closed task'"'"'s pending action requests, leaves approved alone, and retires the pinned hub form ==\n'
register_task runSup taskSup w c pC cbirthC pS1 birthS1 /repo/sup /does/not/exist "sup-task" \
  || bad "register taskSup failed"
set_task_state runSup taskSup running || bad "taskSup -> running failed (setup)"
db="$(registry_db)"
sqlite3 "$db" "INSERT INTO action_requests
    (request_id, run_id, task_id, tool, action_sha256, command, verdict, reason, route, grant_kind, status, created_at)
  VALUES
    ('req_sup_p1','runSup','taskSup','bash','sha_p1','echo p1','escalate','probe','conductor','once','pending',$(date -u +%s)),
    ('req_sup_p2','runSup','taskSup','bash','sha_p2','echo p2','escalate','probe','conductor','once','pending',$(date -u +%s)),
    ('req_sup_a1','runSup','taskSup','bash','sha_a1','echo a1','escalate','probe','conductor','once','approved',$(date -u +%s));"
mkdir -p "$HERDR_STATE_ROOT/forms"
printf '{"status":"open","form_path":"dummy-sup1"}' > "$HERDR_STATE_ROOT/forms/form_sup1.json"
sqlite3 "$db" "UPDATE action_requests SET form_record='form_sup1' WHERE request_id='req_sup_p1';"

: > "$CALLS"
out=$(bash "$here/close-done-workers.sh" --task=taskSup 2>&1)
printf '%s' "$out" | grep -q 'would supersede 2 pending request(s)' \
  && ok "dry run lists would-supersede count for a task with 2 pending requests" || bad "dry run count missing: $out"
check "dry run: req_sup_p1 still pending" "$(sqlite3 "$db" "SELECT status FROM action_requests WHERE request_id='req_sup_p1';")" "pending"
check "dry run: req_sup_p2 still pending" "$(sqlite3 "$db" "SELECT status FROM action_requests WHERE request_id='req_sup_p2';")" "pending"
check "dry run: req_sup_a1 still approved" "$(sqlite3 "$db" "SELECT status FROM action_requests WHERE request_id='req_sup_a1';")" "approved"
check "dry run: taskSup still running" "$(read_task runSup taskSup | jq -r .state)" "running"
check "dry run: pinned form still open" "$(jq -r .status "$HERDR_STATE_ROOT/forms/form_sup1.json")" "open"

HERDR_PANE_ID=pC bash "$here/close-done-workers.sh" --apply --reason=no-follow-on --task=taskSup \
  >/tmp/cdw-sup-apply-$$.log 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "apply with pending requests exits 0" || bad "apply exit $rc: $(cat /tmp/cdw-sup-apply-$$.log)"
check "req_sup_p1 superseded" "$(sqlite3 "$db" "SELECT status FROM action_requests WHERE request_id='req_sup_p1';")" "superseded"
check "req_sup_p2 superseded" "$(sqlite3 "$db" "SELECT status FROM action_requests WHERE request_id='req_sup_p2';")" "superseded"
check "req_sup_a1 (already approved) untouched by the supersede sweep" \
  "$(sqlite3 "$db" "SELECT status FROM action_requests WHERE request_id='req_sup_a1';")" "approved"
check "taskSup closed" "$(read_task runSup taskSup | jq -r .state)" "completed"
check "the pinned hub form was retired exactly as a manual supersede does" \
  "$(jq -r .status "$HERDR_STATE_ROOT/forms/form_sup1.json")" "withdrawn"
grep -q 'supersede-failed' /tmp/cdw-sup-apply-$$.log && bad "unexpected supersede-failed: $(cat /tmp/cdw-sup-apply-$$.log)" \
  || ok "no supersede-failed reported for a live conductor"

printf '== a held-back task'"'"'s pending action requests are left untouched ==\n'
held_wt=$(mktemp -d)/wt-held
git init -q -b main "$held_wt"
git -C "$held_wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$held_wt/.handoffs"; printf '*\n' > "$held_wt/.handoffs/.gitignore"
printf 'dirty\n' > "$held_wt/dirty.txt"        # uncommitted -> held, never closable
register_task runHeld taskHeld w c pC cbirthC pS2 birthS2 /repo/held "$held_wt" "held-task" \
  || bad "register taskHeld failed"
set_task_state runHeld taskHeld running || bad "taskHeld -> running failed (setup)"
sqlite3 "$db" "INSERT INTO action_requests
    (request_id, run_id, task_id, tool, action_sha256, command, verdict, reason, route, grant_kind, status, created_at)
  VALUES ('req_held_p1','runHeld','taskHeld','bash','sha_held_p1','echo held','escalate','probe','conductor','once','pending',$(date -u +%s));"
out=$(HERDR_PANE_ID=pC bash "$here/close-done-workers.sh" --apply --reason=no-follow-on --task=taskHeld 2>&1)
printf '%s' "$out" | grep -q 'HOLD' && ok "dirty worktree is held, not closed" || bad "held task was not held: $out"
check "req_held_p1 still pending -- a held task's requests are never touched" \
  "$(sqlite3 "$db" "SELECT status FROM action_requests WHERE request_id='req_held_p1';")" "pending"
check "taskHeld untouched" "$(read_task runHeld taskHeld | jq -r .state)" "running"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
