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
set_task_state run1 task1 completed || bad "running -> completed refused"
check "now completed" "$(read_task run1 task1 | jq -r .state)" "completed"

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

printf '== schema v3: agent_session column present after migration ==\n'
check "agent_session column exists" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='agent_session';")" "1"
check "schema_version is 3" \
  "$(sqlite3 "$(registry_db)" "SELECT value FROM schema_meta WHERE key='schema_version';")" "3"

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
check "one line per task" "$(all_tasks_json | wc -l | tr -d ' ')" "3"
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
