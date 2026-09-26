#!/usr/bin/env bash
# verify-run-registry.sh — prove the SQLite registry actually delivers the four
# properties the file layout could not (docs/control-plane-design.md,
# correction 4), plus the transition and injection guards.
#
# Runs entirely against a throwaway HERDR_RUN_STATE_DIR under $TMPDIR — it never
# touches ~/.local/state/herdr. Exit 0 = every case passed.
#
#   bash verify-run-registry.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
export HERDR_RUN_STATE_DIR="$(mktemp -d)/runs"
trap 'rm -rf "$(dirname "$HERDR_RUN_STATE_DIR")"' EXIT

. "$here/lib/run-registry.sh"

# gh is a function stub, never the real binary: `gh pr view <n> -R <slug>
# --json … -q <jq>` answers from GH_PRS ("<slug>#<n> <STATE> <merge oid|->"
# per line); GH_FAIL=1 makes every call fail the way a network/auth error does.
GH_PRS="tntpgh/herdr-control#69 MERGED abc1234def567890abc1234def567890abc12345" GH_FAIL=0
gh() {
  [ "$GH_FAIL" = 1 ] && { echo "gh: stub failure" >&2; return 1; }
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

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

printf '== init + register ==\n'
registry_init || bad "registry_init returned non-zero"
[ -f "$(registry_db)" ] && ok "database created at $(registry_db)" || bad "no database file"

check "journal_mode is WAL" \
  "$(sqlite3 "$(registry_db)" 'PRAGMA journal_mode;')" "wal"

register_task run1 task1 worker1 cond1 wpane1 wbirth1 pane1 birth1 /repo/a /wt/a "impl:branch-a" \
  || bad "register_task failed"
check "task readable"        "$(read_task run1 task1 | jq -r .task_id)" "task1"
check "state starts starting" "$(read_task run1 task1 | jq -r .state)" "starting"
check "pane_birth recorded"  "$(read_task run1 task1 | jq -r .pane_birth)" "birth1"

printf '== duplicate task_id must FAIL, not silently overwrite ==\n'
if register_task run1 task1 wX cX cpX cbX paneX birthX /repo/z /wt/z "other" 2>/dev/null; then
  bad "duplicate task_id was accepted"
else
  ok "duplicate task_id refused"
fi
check "original registration intact" "$(read_task run1 task1 | jq -r .pane_birth)" "birth1"

printf '== task_for_pane reverse lookup ==\n'
check "task_for_pane finds it" "$(task_for_pane pane1 | jq -r .task_id)" "task1"
check "unknown pane -> empty"  "$(task_for_pane nope)" ""

printf '== SQL injection via a task label (spawn-task.sh shipped this class once) ==\n'
evil="x'); DROP TABLE tasks; --"
register_task run1 taskEvil w c cp cb paneEvil birthEvil /repo/e /wt/e "$evil" \
  || bad "register with quote-bearing label failed"
check "tasks table survived"   "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM tasks;")" "2"
check "label stored verbatim"  "$(read_task run1 taskEvil | jq -r .label)" "$evil"

printf '== lifecycle transitions ==\n'
set_task_state run1 task1 running || bad "starting -> running refused"
check "now running" "$(read_task run1 task1 | jq -r .state)" "running"
set_task_state run1 task1 blocked || bad "running -> blocked refused"
set_task_state run1 task1 running || bad "blocked -> running refused"

printf '== closure-reason gate on completed (project-contract-plan item 1) ==\n'
if set_task_state run1 task1 completed 2>/dev/null; then
  bad "completed with no closure reason was ACCEPTED"
else
  ok "completed with no closure reason refused"
fi
check "state unchanged after refusal" "$(read_task run1 task1 | jq -r .state)" "running"
check "no state_changed(completed) event written" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='task1' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';")" \
  "0"
if set_task_state run1 task1 completed "not-a-real-reason" 2>/dev/null; then
  bad "completed with a garbage closure reason was ACCEPTED"
else
  ok "completed with a garbage closure reason refused"
fi
if set_task_state run1 task1 completed shipped 2>/dev/null; then
  bad "shipped with no proof was ACCEPTED"
else
  ok "shipped with no proof refused"
fi
if set_task_state run1 task1 completed shipped "not a real proof" 2>/dev/null; then
  bad "shipped with a malformed proof (no URL, no sha, no PROOF.md) was ACCEPTED"
else
  ok "shipped with a malformed proof refused"
fi
check "state still unchanged after every refusal" "$(read_task run1 task1 | jq -r .state)" "running"
set_task_state run1 task1 completed "handed_off_to:reviewer" \
  || bad "handed_off_to needs no proof and was refused"
check "handed_off_to closes without proof" "$(read_task run1 task1 | jq -r .state)" "completed"

printf '== shipped WITH a valid proof: accepted, event carries both ==\n'
register_task runShip taskShip w c cp cb paneShip birthShip /repo/s /wt/s "ship" \
  || bad "register taskShip failed"
set_task_state runShip taskShip running || bad "taskShip -> running failed (setup)"
set_task_state runShip taskShip completed shipped \
  "https://github.com/tntpgh/herdr-control/pull/69 abc1234" \
  || bad "shipped with a valid PR+sha proof refused"
check "now completed" "$(read_task runShip taskShip | jq -r .state)" "completed"
check "event carries the reason" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.reason') FROM events WHERE task_id='taskShip' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';")" \
  "shipped"
check "event carries the proof" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.proof') FROM events WHERE task_id='taskShip' AND type='state_changed' AND json_extract(payload,'\$.state')='completed';")" \
  "https://github.com/tntpgh/herdr-control/pull/69 abc1234"
set_task_state runShip taskShip completed || bad "idempotent re-assert with no reason refused"
ok "idempotent re-assert of an already-completed task needs no reason"

printf '== _valid_proof_ref: a PROOF.md reference is checked against the REAL file ==\n'
wtreal=$(mktemp -d)/wt-real; mkdir -p "$wtreal/.handoffs"
if _valid_proof_ref ".handoffs/PROOF.md#x" "$wtreal" 2>/dev/null; then
  bad "an EMPTY PROOF.md counted as proof"
else
  ok "an empty real PROOF.md is refused"
fi
printf 'verified: ran X, 5/5 passed\n' > "$wtreal/.handoffs/PROOF.md"
_valid_proof_ref ".handoffs/PROOF.md#x" "$wtreal" \
  && ok "a non-empty real PROOF.md is accepted" || bad "a real, non-empty PROOF.md refused"
_valid_proof_ref ".handoffs/PROOF.md#x" "" \
  && ok "no worktree on record falls back to the name-shape check" \
  || bad "no-worktree fallback refused a PROOF.md-shaped proof"
if _valid_proof_ref ".handoffs/PROOF.md#x" "/no/such/worktree" 2>/dev/null; then
  bad "a nonexistent worktree path was accepted"
else
  ok "a worktree that doesn't exist on disk is refused (no PROOF.md to check)"
fi

printf '== proof shape: a PROOF.md section reference is checked via set_task_state'"'"'s own worktree lookup ==\n'
wtPf=$(mktemp -d)/wt-pf; mkdir -p "$wtPf/.handoffs"
register_task runPf taskPf w c cp cb panePf birthPf /repo/p "$wtPf" "pf" || bad "register taskPf failed"
set_task_state runPf taskPf running || bad "taskPf -> running failed (setup)"
if set_task_state runPf taskPf completed shipped ".handoffs/PROOF.md#verify-run-registry" 2>/dev/null; then
  bad "shipped accepted against an EMPTY PROOF.md (via set_task_state's own worktree lookup)"
else
  ok "shipped refused: the task's real PROOF.md exists but is empty"
fi
check "state unchanged by the refusal" "$(read_task runPf taskPf | jq -r .state)" "running"
printf 'verified: ran verify-run-registry.sh itself, all green\n' > "$wtPf/.handoffs/PROOF.md"
set_task_state runPf taskPf completed shipped ".handoffs/PROOF.md#verify-run-registry" \
  || bad "shipped refused with a real, non-empty PROOF.md"
check "PROOF.md-referencing proof accepted once the file actually holds something" \
  "$(read_task runPf taskPf | jq -r .state)" "completed"

printf '== a GitHub PR proof must name a MERGED PR and its merge commit (notepad item vi) ==\n'
# Live shape that got through: `…/pull/154 eb55756` while #154 was OPEN and
# eb55756 was its HEAD. #153's stub oid starts with its real merge sha (f1579a62).
GH_PRS="tntpgh/herdr-control#154 OPEN -
tntpgh/herdr-control#153 MERGED f1579a62aaaabbbbccccddddeeeeffff00001111
tntpgh/herdr-control#150 CLOSED -"
pr154="https://github.com/tntpgh/herdr-control/pull/154"
pr153="https://github.com/tntpgh/herdr-control/pull/153"
if _valid_proof_ref "$pr154 eb55756"; then
  bad "head sha on an OPEN PR accepted as shipped proof"
else
  ok "head sha on an OPEN PR refused"
fi
case "$_PROOF_REF_WHY" in "PR not merged (state OPEN)"*) ok "why names the open state" ;; *) bad "why: $_PROOF_REF_WHY" ;; esac
if _valid_proof_ref "HTTPS://GitHub.COM/tntpgh/herdr-control/pull/154/files eb55756"; then
  bad "an upper-case host / sub-path dodged the PR check"
else
  ok "upper-case host and /files sub-path still go through the PR check"
fi
_valid_proof_ref "$pr153 f1579a6" && ok "short merge sha on a MERGED PR accepted" || bad "merged PR + merge sha refused: $_PROOF_REF_WHY"
_valid_proof_ref "$pr153 F1579A62AAAABBBBCCCCDDDDEEEEFFFF00001111" \
  && ok "full merge sha accepted, case-insensitively" || bad "full merge sha refused: $_PROOF_REF_WHY"
if _valid_proof_ref "$pr153 eb55756"; then
  bad "a sha that is not the merge commit accepted on a MERGED PR"
else
  ok "a non-merge sha on a MERGED PR refused"
fi
if _valid_proof_ref "https://github.com/tntpgh/herdr-control/pull/150 abc1234"; then
  bad "a CLOSED-unmerged PR accepted"
else
  ok "a CLOSED-unmerged PR refused"
fi
if _valid_proof_ref "https://github.com/tntpgh/herdr-control/pull/x154 eb55756"; then
  bad "a malformed github pull URL fell back to the shape check"
else
  ok "a github pull URL that does not parse is refused, not shape-checked"
fi
GH_FAIL=1
if _valid_proof_ref "$pr153 f1579a6"; then
  bad "gh FAILING let a shipped PR proof through"
else
  ok "gh failing -> PR proof not accepted"
fi
case "$_PROOF_REF_WHY" in "could not confirm"*) ok "why says the check could not run" ;; *) bad "why: $_PROOF_REF_WHY" ;; esac
_valid_proof_ref ".handoffs/PROOF.md#x" "" \
  && ok "PROOF.md reference unchanged (never asks gh)" || bad "PROOF.md ref refused while gh fails"
_valid_proof_ref "https://example.com/pr/1 abc1234" \
  && ok "non-GitHub URL proof unchanged (shape check only)" || bad "non-PR URL refused while gh fails"
GH_FAIL=0
if ( unset -f gh; PATH=/usr/bin:/bin; _valid_proof_ref "$pr153 f1579a6" ); then
  bad "gh NOT INSTALLED let a shipped PR proof through"
else
  ok "gh absent from PATH -> PR proof not accepted"
fi
register_task runOpen taskOpen w c cp cb paneOpen birthOpen /repo/o /wt/o "open-pr" || bad "register taskOpen failed"
set_task_state runOpen taskOpen running || bad "taskOpen -> running failed (setup)"
err=$(set_task_state runOpen taskOpen completed shipped "$pr154 eb55756" 2>&1) \
  && bad "set_task_state recorded shipped for an OPEN PR" || ok "set_task_state refuses shipped for an OPEN PR's head sha"
check "state unchanged by the refusal" "$(read_task runOpen taskOpen | jq -r .state)" "running"
case "$err" in *"PR not merged (state OPEN)"*) ok "refusal names why" ;; *) bad "refusal text: $err" ;; esac
set_task_state runOpen taskOpen completed shipped "$pr153 f1579a62" \
  || bad "set_task_state refused a merged PR's merge sha"
check "merged PR + merge sha completes the task" "$(read_task runOpen taskOpen | jq -r .state)" "completed"


# The gap correction 2 named: "nothing stops completed -> running".
if set_task_state run1 task1 running 2>/dev/null; then
  bad "illegal completed -> running was ACCEPTED"
else
  ok "illegal completed -> running refused"
fi
check "state unchanged after refusal" "$(read_task run1 task1 | jq -r .state)" "completed"
set_task_state run1 task1 completed || bad "idempotent re-assert of same state refused"
ok "idempotent same-state re-assert allowed"

printf '== set_task_state compare-and-swap under CONCURRENT racing sweeps ==\n'
# Sol's finding (2026-08-09 incident): the old set_task_state read `cur`
# outside its transaction with no WHERE-guard on the write, so two
# reconcile sweeps racing (a herdr-restart storm firing SessionStart AND
# the interval hook back to back) both read the SAME cur, both passed the
# legality check, and both committed — a duplicate state_changed (and, on
# the real incident, a triplicate lost_detected) for one transition.
register_task runCAS taskCAS w c cp cb paneCAS birthCAS /repo/cas /wt/cas "cas" \
  || bad "register taskCAS failed"
set_task_state runCAS taskCAS running || bad "starting -> running refused (cas setup)"
n_racers=15
for i in $(seq 1 "$n_racers"); do
  ( set_task_state runCAS taskCAS blocked >/dev/null 2>&1 ) &
done
wait
check "final state is blocked, not stuck mid-race" "$(read_task runCAS taskCAS | jq -r .state)" "blocked"
dup_events=$(sqlite3 "$(registry_db)" \
  "SELECT count(*) FROM events WHERE task_id='taskCAS' AND type='state_changed' AND payload LIKE '%\"state\":\"blocked\"%';")
check "exactly ONE state_changed event, not $n_racers duplicates" "$dup_events" "1"

printf '== set_task_agent_session: best-effort capture, never overwrites once set ==\n'
check "starts empty" "$(read_task runCAS taskCAS | jq -r .agent_session)" ""
set_task_agent_session runCAS taskCAS "sess-abc"
check "captured" "$(read_task runCAS taskCAS | jq -r .agent_session)" "sess-abc"
set_task_agent_session runCAS taskCAS "sess-xyz"
check "does not clobber an already-recorded session" "$(read_task runCAS taskCAS | jq -r .agent_session)" "sess-abc"
set_task_agent_session runCAS taskCAS ""
check "empty value is a no-op, not a blank overwrite" "$(read_task runCAS taskCAS | jq -r .agent_session)" "sess-abc"

printf '== rebaseline_pane_birth: corrects identity WITHOUT touching state or the state machine ==\n'
rebaseline_pane_birth runCAS taskCAS "birthCAS-v2" "test" || bad "rebaseline_pane_birth failed"
check "pane_birth updated" "$(read_task runCAS taskCAS | jq -r .pane_birth)" "birthCAS-v2"
check "state untouched by a rebaseline" "$(read_task runCAS taskCAS | jq -r .state)" "blocked"
check "pane_birth_rebaselined event logged" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='taskCAS' AND type='pane_birth_rebaselined';")" "1"
rebaseline_pane_birth runCAS taskCAS "birthCAS-v2" "no-op" || bad "no-op rebaseline (same value) should still return success"
check "re-rebaselining to the SAME value logs no extra event" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='taskCAS' AND type='pane_birth_rebaselined';")" "1"
if rebaseline_pane_birth runCAS taskNope "x" "y" 2>/dev/null; then
  bad "rebaseline_pane_birth accepted a nonexistent task"
else
  ok "rebaseline_pane_birth refuses a nonexistent task"
fi

printf '== schema v3/v4: agent_session and branch/trunk columns present after migration ==\n'
check "agent_session column exists" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='agent_session';")" "1"
check "branch column exists (#3b ownership grant)" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='branch';")" "1"
check "trunk column exists (#3b ownership grant)" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='trunk';")" "1"
check "schema_version is 5 (v5 adds tasks.project and tasks.manifest)" \
  "$(sqlite3 "$(registry_db)" "SELECT value FROM schema_meta WHERE key='schema_version';")" "5"
check "project column exists (project-contract-plan.md #2)" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='project';")" "1"
check "manifest column exists (task-scoped approval)" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='manifest';")" "1"

printf '== event dedup on an explicit event_id (at-least-once retry safety) ==\n'
before=$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events;")
append_event run1 task1 retry_test '{"n":1}' stable-id-1
append_event run1 task1 retry_test '{"n":1}' stable-id-1
append_event run1 task1 retry_test '{"n":1}' stable-id-1
after=$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events;")
check "3 identical appends -> 1 row" "$(( after - before ))" "1"

printf '== monotonic sequence under CONCURRENT writers (the count-then-append bug) ==\n'
# The old implementation computed `sequence` as `grep -c` of the file plus one.
# Twenty writers racing that produce colliding sequences and nobody notices.
n_writers=20
for i in $(seq 1 "$n_writers"); do
  ( append_event run1 task1 concurrent "{\"i\":$i}" >/dev/null 2>&1 ) &
done
wait
rows=$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE type='concurrent';")
uniq_seqs=$(sqlite3 "$(registry_db)" "SELECT count(DISTINCT sequence) FROM events WHERE type='concurrent';")
check "all $n_writers concurrent events landed" "$rows" "$n_writers"
check "every sequence is unique"                "$uniq_seqs" "$n_writers"

printf '== all_tasks_json ==\n'
check "one line per task" "$(all_tasks_json | wc -l | tr -d ' ')" "6"
all_tasks_json | while IFS= read -r l; do
  printf '%s' "$l" | jq -e . >/dev/null 2>&1 || { printf '  FAIL  non-JSON row\n'; exit 1; }
done || bad "all_tasks_json emitted a non-JSON row"
ok "every row parses as JSON"

printf '== checkpoints ==\n'
check "absent checkpoint -> {}" "$(read_checkpoint condX)" "{}"
write_checkpoint condX '{"run1/task1":{"state":"completed","updated_at":"t"}}' || bad "write_checkpoint failed"
check "checkpoint round-trips" \
  "$(read_checkpoint condX | jq -r '."run1/task1".state')" "completed"
age=$(checkpoint_age_s condX)
if [ "$age" -ge 0 ] && [ "$age" -lt 60 ]; then ok "checkpoint_age_s fresh ($age s)"; else bad "checkpoint_age_s=$age"; fi
never=$(checkpoint_age_s cond_never_written)
if [ "$never" -gt 1000000 ]; then ok "never-written checkpoint reads as ancient"; else bad "never-written age=$never"; fi
# Corrupt input must not poison the store.
write_checkpoint condY 'not json at all'
check "invalid checkpoint json coerced to {}" "$(read_checkpoint condY)" "{}"

printf '== event-stream cursor (the half the file layout could not do) ==\n'
seen=$(events_since condCursor | wc -l | tr -d ' ')
[ "$seen" -gt 0 ] && ok "events_since returns a backlog ($seen events)" || bad "events_since empty"
top=$(sqlite3 "$(registry_db)" "SELECT MAX(sequence) FROM events;")
advance_event_cursor condCursor "$top" || bad "advance_event_cursor failed"
check "cursor consumed the backlog" "$(events_since condCursor | wc -l | tr -d ' ')" "0"
append_event run1 task1 after_cursor '{}'
check "new event appears past the cursor" "$(events_since condCursor | wc -l | tr -d ' ')" "1"
# A consumer that crashed must be able to see events again: not advancing means
# not consuming.
check "not advancing replays" "$(events_since condCursor | wc -l | tr -d ' ')" "1"

printf '== events_since carries task ownership (join, not a second query per event) ==\n'
[ "$(events_since condCursor | tail -1 | jq -r 'has("task_conductor_id") and has("label") and has("repo")')" = "true" ] \
  && ok "event rows carry task_conductor_id/label/repo for ownership scoping" \
  || bad "events_since join fields missing: $(events_since condCursor | tail -1)"

printf '== deferred ack: clock and acknowledgment are separate facts ==\n'
# ack_reconcile commits the delivered report: task_states + cursor together.
ack_reconcile condDefer '{"r/t":{"state":"blocked","updated_at":"u1"}}' 7 || bad "ack_reconcile failed"
check "ack committed task_states" "$(read_checkpoint condDefer | jq -r '."r/t".state')" "blocked"
check "ack committed cursor" \
  "$(sqlite3 "$(registry_db)" "SELECT last_event_seq FROM checkpoints WHERE conductor_id='condDefer';")" "7"
# touch_checkpoint_clock is what an UNDELIVERED prepare writes: the throttle
# clock must advance, the acknowledgment must not.
touch_checkpoint_clock condDefer || bad "touch_checkpoint_clock failed"
check "clock touch preserves the cursor" \
  "$(sqlite3 "$(registry_db)" "SELECT last_event_seq FROM checkpoints WHERE conductor_id='condDefer';")" "7"
check "clock touch preserves task_states" "$(read_checkpoint condDefer | jq -r '."r/t".state')" "blocked"
age_t=$(checkpoint_age_s condDefer)
if [ "$age_t" -ge 0 ] && [ "$age_t" -lt 60 ]; then ok "throttle clock fresh after touch ($age_t s)"; else bad "clock stale after touch: $age_t"; fi
# A replayed/stale ack (at-least-once retry) must never move the cursor
# backward and resurrect consumed events.
ack_reconcile condDefer '{"r/t":{"state":"completed","updated_at":"u2"}}' 3 || bad "replayed ack errored"
check "stale ack cannot move the cursor backward" \
  "$(sqlite3 "$(registry_db)" "SELECT last_event_seq FROM checkpoints WHERE conductor_id='condDefer';")" "7"
check "task_states follow delivery order (last writer)" "$(read_checkpoint condDefer | jq -r '."r/t".state')" "completed"
ack_reconcile condDefer '{}' 'notanumber' && bad "non-numeric sequence accepted" || ok "non-numeric sequence refused"

printf '== task_for_worktree: completion evidence outlives the pane ==\n'
register_task runW taskW w c cp cb paneW bW /repo/w /wt/target "wt-task" || bad "register taskW failed"
check "found by worktree path" "$(task_for_worktree /wt/target | jq -r .task_id)" "taskW"
check "unknown worktree is empty, not an error" "$(task_for_worktree /wt/nowhere)" ""

printf '== approval lifecycle: decided / attempted / confirmed are DISTINCT ==\n'
approval_decided appr1 pane1 promptA 2 "Yes" human/thurbs operator allow "rm -i x" run1 task1 \
  || bad "approval_decided failed"
q() { sqlite3 "$(registry_db)" "SELECT COALESCE($1,'') FROM approvals WHERE approval_id='appr1';"; }
[ -n "$(q decided_at)" ] && ok "decided_at recorded" || bad "decided_at empty"
check "attempted_at still empty (decision != delivery)" "$(q attempted_at)" ""
check "confirmed_at still empty"                        "$(q confirmed_at)" ""
approval_attempted appr1
[ -n "$(q attempted_at)" ] && ok "attempted_at recorded" || bad "attempted_at empty"
check "confirmed still empty after attempt" "$(q confirmed_at)" ""
approval_confirmed appr1 submitted "composer cleared"
check "outcome recorded" "$(q outcome)" "submitted"
[ -n "$(q confirmed_at)" ] && ok "confirmed_at recorded" || bad "confirmed_at empty"
check "policy verdict retained" "$(q policy_verdict)" "allow"

printf '== prune only touches OLD terminal tasks ==\n'
register_task run2 taskOld w c cp cb paneOld birthOld /repo/o /wt/o "old" || bad "register taskOld failed"
set_task_state run2 taskOld failed || bad "-> failed refused"
# Backdate it past the retention window.
sqlite3 "$(registry_db)" "UPDATE tasks SET updated_at=datetime('now','-30 days') WHERE task_id='taskOld';"
prune_completed_tasks 14 || bad "prune returned non-zero"
check "old terminal task pruned"      "$(read_task run2 taskOld)" ""
check "recent completed task KEPT"    "$(read_task run1 task1 | jq -r .task_id)" "task1"
check "non-terminal task KEPT"        "$(read_task run1 taskEvil | jq -r .state)" "starting"
if prune_completed_tasks abc 2>/dev/null; then bad "prune accepted a non-integer"; else ok "prune rejects a non-integer day count"; fi

printf '== #3b ownership grant: branch/trunk stored and read back; empty by default ==\n'
check "task1 has no grant (11-arg caller)" "$(read_task run1 task1 | jq -r '.branch + "|" + .trunk')" "|"
register_task runGrant taskGrant w c cp cb paneGrant birthGrant /repo/g /wt/g "impl:grant" "feat/x" "main" \
  || bad "register_task with branch/trunk failed"
check "branch recorded" "$(read_task runGrant taskGrant | jq -r .branch)" "feat/x"
check "trunk recorded"  "$(read_task runGrant taskGrant | jq -r .trunk)" "main"

printf '== task_for_pane breaks an updated_at TIE deterministically (rowid, not scan order) ==\n'
register_task runTie1 taskTie1 w c cp cb paneTie birthTie1 /repo/t /wt/t1 "first" || bad "register taskTie1 failed"
register_task runTie2 taskTie2 w c cp cb paneTie birthTie2 /repo/t /wt/t2 "second" || bad "register taskTie2 failed"
# Force an identical updated_at — the real failure mode this fixes: two
# registrations on the same pane inside one wall-clock second, which
# _now_iso's second granularity cannot tell apart on its own.
same_ts=$(sqlite3 "$(registry_db)" "SELECT updated_at FROM tasks WHERE task_id='taskTie1';")
sqlite3 "$(registry_db)" "UPDATE tasks SET updated_at='$same_ts' WHERE task_id IN ('taskTie1','taskTie2');"
check "the LATER-registered task wins a tie, not scan order" \
  "$(task_for_pane paneTie | jq -r .task_id)" "taskTie2"

printf '== legacy file import ==\n'
legacy_root="$(mktemp -d)/runs"
mkdir -p "$legacy_root/oldrun/tasks" "$legacy_root/checkpoints"
cat > "$legacy_root/oldrun/tasks/oldtask.json" <<'JSON'
{"schema":1,"run_id":"oldrun","task_id":"oldtask","worker_id":"w","conductor_id":"c",
 "conductor_pane_id":"cp","conductor_pane_birth":"cb","pane_id":"p9","pane_birth":"b9",
 "repo":"/r","worktree":"/w","label":"legacy:job","state":"running",
 "created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-01T00:00:00Z"}
JSON
printf '{"event_id":"oldrun_1","run_id":"oldrun","task_id":"oldtask","sequence":1,"type":"registered","occurred_at":"2026-07-01T00:00:00Z","payload":{}}\n' \
  > "$legacy_root/oldrun/events.jsonl"
printf '{"oldrun/oldtask":{"state":"running","updated_at":"2026-07-01T00:00:00Z"}}\n' \
  > "$legacy_root/checkpoints/condLegacy.json"
(
  export HERDR_RUN_STATE_DIR="$legacy_root"
  _HERDR_REGISTRY_READY=0
  registry_init >/dev/null 2>&1
  imported=$(read_task oldrun oldtask | jq -r '.task_id // empty')
  [ "$imported" = "oldtask" ] || { printf '  FAIL  legacy task not imported\n'; exit 1; }
  [ "$(read_task oldrun oldtask | jq -r .pane_birth)" = "b9" ] || { printf '  FAIL  legacy pane_birth lost (recycled-pane protection would silently stop)\n'; exit 1; }
  [ "$(read_checkpoint condLegacy | jq -r '."oldrun/oldtask".state')" = "running" ] || { printf '  FAIL  legacy checkpoint not imported\n'; exit 1; }
  [ -f "$legacy_root/oldrun/tasks/oldtask.json" ] || { printf '  FAIL  legacy file was deleted (import must be non-destructive)\n'; exit 1; }
  # Re-running must not duplicate.
  _HERDR_REGISTRY_READY=0
  registry_init >/dev/null 2>&1
  n=$(sqlite3 "$legacy_root/registry.sqlite3" "SELECT count(*) FROM tasks WHERE task_id='oldtask';")
  [ "$n" = "1" ] || { printf '  FAIL  re-import duplicated the task (%s rows)\n' "$n"; exit 1; }
  printf '  ok    legacy tasks, events and checkpoints imported once, non-destructively\n'
) || bad "legacy import"
[ -d "$(dirname "$legacy_root")" ] && rm -rf "$(dirname "$legacy_root")"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
