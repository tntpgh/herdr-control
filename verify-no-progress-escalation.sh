#!/usr/bin/env bash
# verify-no-progress-escalation.sh — BRIEF-R2: the REAL quiesce-old/
# spawn-new hook, exercised offline against fake `herdr pane`/spawn-task.sh
# commands (HERDR_ESC_PANE_ALIVE_CMD/HERDR_ESC_PANE_CLOSE_CMD/
# HERDR_ESC_SPAWN_CMD — see lib/escalation.sh's header) and a real git repo
# for exact commit shas. Isolated registry + TMPDIR, both under tmp/; never
# touches live ~/.local/state, never calls a real herdr/spawn-task.sh.
#
#   A. success path: exact commit sha + exact model names (haiku->sonnet),
#      quiesce-before-spawn ordering, model_escalated only after both
#   B. failure then retry then success within the bound: exactly one close,
#      exactly `bound` spawn attempts, exactly one successor task row
#   C. retries exhausted: no model_escalated, tier NOT consumed, a later
#      call (transient failure cleared) still succeeds exactly once
#   D. dry run: no quiesce, no spawn, no model_escalated, tier NOT consumed
#      — a real tick right after still escalates normally
#   E. human-wait is still never a loop (regression from R1)
#   F. denial enforcement: the REAL command-policy classifier still refuses
#      the denied command after the handoff — not just an unchanged count
#   G. idempotent re-tick after a completed escalation: no double-spawn,
#      no second model_escalated
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

export WORK="$here/tmp/verify-escalation"
mkdir -p "$WORK"
export TMPDIR="$WORK/TMPDIR"; mkdir -p "$TMPDIR"          # BRIEF-R2 #6: offline, TMPDIR under tmp/
export HERDR_RUN_STATE_DIR="$WORK/runs"
mkdir -p "$HERDR_RUN_STATE_DIR"
# Specific files only, never recursive: a clean registry per run so a
# literal task/branch name reused across runs can't leak stale rows in.
rm -f "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$HERDR_RUN_STATE_DIR/registry.sqlite3-wal" "$HERDR_RUN_STATE_DIR/registry.sqlite3-shm"

export HERDR_ESCALATION_LADDER="fast standard deep"
export HERDR_NO_PROGRESS_CYCLES=3
export HERDR_ESCALATION_QUIESCE_POLLS=3

PANES_DIR="$WORK/panes"; mkdir -p "$PANES_DIR"
rm -f "$PANES_DIR"/*.alive "$PANES_DIR"/*.lag 2>/dev/null
ORDER_LOG="$WORK/order.log"; : >"$ORDER_LOG"
rm -f "$WORK/spawn-fail-count"
export PANES_DIR ORDER_LOG HERE_REPO="$here"

CTX="$WORK/ctx"
CLI="$here/no-progress-escalate.sh"

. "$here/lib/escalation.sh"

pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# ---- a real git repo, so commit_sha assertions are exact, not synthetic ----
REPO="$WORK/fake-worktree"
if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name "verify-no-progress-escalation"
  printf 'seed\n' > "$REPO/seed.txt"
  git -C "$REPO" add seed.txt
  git -C "$REPO" commit -q -m seed
fi
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# ---- fake hook scripts (HERDR_ESC_PANE_ALIVE_CMD / _CLOSE_CMD / _SPAWN_CMD)
cat >"$WORK/fake-pane-alive.sh" <<'SH'
#!/usr/bin/env bash
pane="$1"
f="$PANES_DIR/$pane.alive"
[ -f "$f" ] || exit 1
lag="$PANES_DIR/$pane.lag"
if [ -f "$lag" ]; then
  n="$(cat "$lag")"
  if [ "${n:-0}" -gt 0 ]; then
    printf '%s' "$((n-1))" > "$lag"
    exit 0
  fi
  rm -f "$f" "$lag"
  exit 1
fi
exit 0
SH
cat >"$WORK/fake-pane-close.sh" <<'SH'
#!/usr/bin/env bash
pane="$1"
printf 'close %s\n' "$pane" >> "$ORDER_LOG"
[ -f "$PANES_DIR/$pane.lag" ] || rm -f "$PANES_DIR/$pane.alive"
exit 0
SH
cat >"$WORK/fake-spawn.sh" <<'SH'
#!/usr/bin/env bash
# <repo> <branch> <job> <agent>
set -uo pipefail
repo="$1" branch="$2" job="$3" agent="$4"
. "$HERE_REPO/lib/run-registry.sh"
fail_f="$WORK/spawn-fail-count"
if [ -f "$fail_f" ]; then
  n="$(cat "$fail_f")"
  if [ "${n:-0}" -gt 0 ]; then
    printf '%s' "$((n-1))" > "$fail_f"
    printf 'spawn-fail %s %s\n' "$job" "$branch" >> "$ORDER_LOG"
    exit 1
  fi
fi
printf 'spawn %s %s\n' "$job" "$branch" >> "$ORDER_LOG"
succ_task="task_succ_${job}_$$_${RANDOM}"
succ_pane="pane_succ_${job}_$$_${RANDOM}"
: > "$PANES_DIR/$succ_pane.alive"
now="$(_now_iso)"
registry_init
_sql "INSERT INTO tasks (task_id, run_id, worker_id, conductor_id, conductor_pane_id, conductor_pane_birth, pane_id, pane_birth, agent_session, repo, worktree, branch, trunk, project, manifest, label, state, created_at, updated_at)
  VALUES ($(_sq "$succ_task"), $(_sq "$succ_task"), '', '', '', '', $(_sq "$succ_pane"), '', '', $(_sq "$repo"), $(_sq "$repo"), $(_sq "$branch"), '', '', '', $(_sq "${job}:${branch}"), 'running', $(_sq "$now"), $(_sq "$now"));"
exit 0
SH

export HERDR_ESC_PANE_ALIVE_CMD="$WORK/fake-pane-alive.sh"
export HERDR_ESC_PANE_CLOSE_CMD="$WORK/fake-pane-close.sh"
export HERDR_ESC_SPAWN_CMD="$WORK/fake-spawn.sh"

seed_task() {   # task_id pane branch
  local task_id="$1" pane="$2" branch="$3" now
  now="$(_now_iso)"
  registry_init
  _sql "INSERT INTO tasks (task_id, run_id, worker_id, conductor_id, conductor_pane_id, conductor_pane_birth, pane_id, pane_birth, agent_session, repo, worktree, branch, trunk, project, manifest, label, state, created_at, updated_at)
    VALUES ($(_sq "$task_id"), $(_sq "$task_id"), '', '', '', '', $(_sq "$pane"), '', '', $(_sq "$REPO"), $(_sq "$REPO"), $(_sq "$branch"), '', '', '', $(_sq "explore:$branch"), 'running', $(_sq "$now"), $(_sq "$now"));"
  : > "$PANES_DIR/$pane.alive"
}
escalated_payload() {   # run_id task_id tier -> payload json (empty if none)
  _sql "SELECT payload FROM events WHERE run_id=$(_sq "$1") AND task_id=$(_sq "$2")
    AND type='model_escalated' AND json_extract(payload,'\$.to_tier')=$(_sq "$3") LIMIT 1;" 2>/dev/null
}
event_count() {   # run_id task_id type -> n
  _sql "SELECT COUNT(*) FROM events WHERE run_id=$(_sq "$1") AND task_id=$(_sq "$2") AND type=$(_sq "$3");" 2>/dev/null
}
order_index() {   # pattern -> 1-based line number of first match, or empty
  grep -n -m1 -- "$1" "$ORDER_LOG" | cut -d: -f1
}

# =============================================================== case A ===
RUN=taskA; TASK=taskA; PANE=pane-A; BRANCH=esc-test-a
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha "$HEAD_SHA" --artifact-fp fpA --context-dir "$CTX" >/dev/null
done
payload="$(escalated_payload "$RUN" "$TASK" standard)"
to_model="$(printf '%s' "$payload" | jq -r '.to_model // empty')"
from_model="$(printf '%s' "$payload" | jq -r '.from_model // empty')"
got_sha="$(printf '%s' "$payload" | jq -r '.evidence.window[0].commit_sha // empty')"
successor="$(printf '%s' "$payload" | jq -r '.successor_task_id // empty')"
[ -n "$payload" ] && ok "A: model_escalated recorded after a real 3-tick loop" || bad "A: model_escalated recorded"
[ "$from_model" = haiku ] && ok "A: exact from_model (claude fast = haiku)" || bad "A: from_model (got $from_model)"
[ "$to_model" = sonnet ] && ok "A: exact to_model (claude standard = sonnet)" || bad "A: to_model (got $to_model)"
[ "$got_sha" = "$HEAD_SHA" ] && ok "A: exact commit sha recorded in evidence" || bad "A: commit sha (got $got_sha want $HEAD_SHA)"
_esc_pane_alive "$PANE" && bad "A: old pane still alive after escalation" || ok "A: old pane verified stopped"
[ -n "$successor" ] && ok "A: successor task_id recorded" || bad "A: successor task_id recorded"
ci="$(order_index 'close pane-A')"; si="$(order_index 'spawn implement esc-test-a')"
[ -n "$ci" ] && [ -n "$si" ] && [ "$ci" -lt "$si" ] && ok "A: quiesce (close) happens before spawn" \
  || bad "A: quiesce-before-spawn ordering (close@$ci spawn@$si)"

# =============================================================== case B ===
RUN=taskB; TASK=taskB; PANE=pane-B; BRANCH=esc-test-b
seed_task "$TASK" "$PANE" "$BRANCH"
printf '2' > "$WORK/spawn-fail-count"   # fail twice, succeed on the 3rd (== HERDR_ESCALATION_HOOK_RETRIES default bound)
: >"$ORDER_LOG"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpB --context-dir "$CTX" >/dev/null
done
spawn_attempts="$(grep -c -- 'spawn.* esc-test-b' "$ORDER_LOG" 2>/dev/null)"
close_count="$(grep -c -- 'close pane-B' "$ORDER_LOG" 2>/dev/null)"
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
succ_rows="$(_sql "SELECT COUNT(*) FROM tasks WHERE branch=$(_sq "$BRANCH") AND label='implement:$BRANCH';" 2>/dev/null)"
[ "${spawn_attempts:-0}" = 3 ] && ok "B: retried exactly 3 times (2 failures + 1 success)" || bad "B: spawn attempts (got $spawn_attempts)"
[ "${close_count:-0}" = 1 ] && ok "B: pane closed exactly once across all retries (idempotent quiesce)" || bad "B: close count (got $close_count)"
[ "${esc_n:-0}" = 1 ] && ok "B: exactly one model_escalated after failure+retry+success" || bad "B: model_escalated count (got $esc_n)"
[ "${succ_rows:-0}" = 1 ] && ok "B: exactly one successor task row (no double-spawn)" || bad "B: successor row count (got $succ_rows)"

# =============================================================== case C ===
RUN=taskC; TASK=taskC; PANE=pane-C; BRANCH=esc-test-c
seed_task "$TASK" "$PANE" "$BRANCH"
printf '999' > "$WORK/spawn-fail-count"   # always fails
export HERDR_ESCALATION_HOOK_RETRIES=2
: >"$ORDER_LOG"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpC --context-dir "$CTX" >/dev/null
done
spawn_attempts="$(grep -c -- 'spawn-fail.* esc-test-c' "$ORDER_LOG" 2>/dev/null || echo 0)"
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
failed_n="$(event_count "$RUN" "$TASK" model_escalation_hook_failed)"
[ "${spawn_attempts:-0}" = 2 ] && ok "C: stopped retrying at the configured bound (2)" || bad "C: spawn attempts at bound (got $spawn_attempts)"
[ "${esc_n:-0}" = 0 ] && ok "C: no model_escalated when the hook never succeeds" || bad "C: model_escalated should be 0 (got $esc_n)"
[ "${failed_n:-0}" -ge 1 ] && ok "C: hook failure recorded in the audit trail" || bad "C: model_escalation_hook_failed recorded"
esc_already_escalated "$RUN" "$TASK" standard && bad "C: tier must NOT be consumed by a failed attempt" || ok "C: tier not consumed — still retryable"
# the transient failure clears; the NEXT call (another external tick) must
# still succeed, exactly once, proving the bound only limited ONE call.
: > "$WORK/spawn-fail-count"
bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpC --context-dir "$CTX" >/dev/null
esc_n2="$(event_count "$RUN" "$TASK" model_escalated)"
[ "${esc_n2:-0}" = 1 ] && ok "C: a later retry succeeds exactly once after the transient failure clears" || bad "C: recovery retry (got $esc_n2)"
export HERDR_ESCALATION_HOOK_RETRIES=3

# =============================================================== case D ===
RUN=taskD; TASK=taskD; PANE=pane-D; BRANCH=esc-test-d
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpD --dry-run --context-dir "$CTX" >/dev/null
done
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
dry_n="$(event_count "$RUN" "$TASK" model_escalation_dry_run)"
[ "${esc_n:-0}" = 0 ] && ok "D: dry run never writes model_escalated" || bad "D: dry run model_escalated (got $esc_n)"
[ "${dry_n:-0}" = 1 ] && ok "D: dry run records its own audit event once the loop window is full" || bad "D: dry run audit events (got $dry_n)"
[ ! -s "$ORDER_LOG" ] && ok "D: dry run never quiesces or spawns" || bad "D: dry run touched the hook: $(cat "$ORDER_LOG")"
_esc_pane_alive "$PANE" && ok "D: dry run leaves the old pane running" || bad "D: dry run must not close the pane"
# a REAL tick right after must still escalate — the dry runs consumed nothing
bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpD --context-dir "$CTX" >/dev/null
esc_n2="$(event_count "$RUN" "$TASK" model_escalated)"
[ "${esc_n2:-0}" = 1 ] && ok "D: the real escalation still happens after dry runs (tier not consumed)" || bad "D: post-dry-run real escalation (got $esc_n2)"

# =============================================================== case E ===
RUN=taskE; TASK=taskE; PANE=pane-E; BRANCH=esc-test-e
seed_task "$TASK" "$PANE" "$BRANCH"
bash "$CLI" tick "$RUN" "$TASK" --commit-sha same --artifact-fp same --context-dir "$CTX" >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha same --artifact-fp same --context-dir "$CTX" >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha same --artifact-fp same --waiting-on-human --context-dir "$CTX" >/dev/null
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
[ "${esc_n:-0}" = 0 ] && ok "E: human-wait tick is never escalated" || bad "E: human-wait escalated (got $esc_n)"

# =============================================================== case F ===
. "$here/lib/command-policy.sh"
DENIED_CMD='cat ~/.ssh/id_rsa'
reason_before="$(conductor_reserved_reason "$DENIED_CMD")"
verdict_before="$(classify_command "$DENIED_CMD")"
[ -n "$reason_before" ] && [ "$verdict_before" != allow ] && ok "F: denied command is refused before any escalation" \
  || bad "F: baseline refusal (reason=[$reason_before] verdict=[$verdict_before])"

RUN=taskF; TASK=taskF; PANE=pane-F; BRANCH=esc-test-f
seed_task "$TASK" "$PANE" "$BRANCH"
append_event "$RUN" "$TASK" approval_escalated '{"verdict":"deny","reason":"credential-value access remains human-only"}' >/dev/null
denials_before="$(esc_open_denials "$RUN" "$TASK")"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpF --context-dir "$CTX" >/dev/null
done
denials_after="$(esc_open_denials "$RUN" "$TASK")"
successor="$(printf '%s' "$(escalated_payload "$RUN" "$TASK" standard)" | jq -r '.successor_task_id // empty')"
succ_worktree="$(_sql "SELECT worktree FROM tasks WHERE task_id=$(_sq "$successor");" 2>/dev/null)"
succ_manifest="$(_sql "SELECT manifest FROM tasks WHERE task_id=$(_sq "$successor");" 2>/dev/null)"
reason_after="$(conductor_reserved_reason "$DENIED_CMD")"
verdict_after="$(classify_command "$DENIED_CMD" "$succ_worktree" "$succ_manifest")"
[ "$denials_before" = 1 ] && [ "$denials_after" = 1 ] && ok "F: recorded denial count survives the handoff" \
  || bad "F: denial count (before=$denials_before after=$denials_after)"
[ -n "$successor" ] && ok "F: a real successor exists to evaluate" || bad "F: successor exists"
[ -n "$reason_after" ] && [ "$verdict_after" != allow ] && [ "$reason_after" = "$reason_before" ] \
  && ok "F: the SAME classifier still refuses the denied command for the successor (enforced, not just counted)" \
  || bad "F: successor still refused (reason=[$reason_after] verdict=[$verdict_after])"

# =============================================================== case G ===
# idempotent re-tick after a completed escalation (reuses case A's task)
esc_n_before="$(event_count taskA taskA model_escalated)"
spawn_attempts_before="$(grep -c -- 'spawn implement esc-test-a' "$ORDER_LOG" 2>/dev/null || echo 0)"
bash "$CLI" tick taskA taskA --commit-sha unused --artifact-fp fpA --context-dir "$CTX" >/dev/null
esc_n_after="$(event_count taskA taskA model_escalated)"
spawn_attempts_after="$(grep -c -- 'spawn implement esc-test-a' "$ORDER_LOG" 2>/dev/null || echo 0)"
[ "$esc_n_before" = "$esc_n_after" ] && [ "$spawn_attempts_before" = "$spawn_attempts_after" ] \
  && ok "G: idempotent re-tick after completion — no duplicate escalation or spawn" \
  || bad "G: idempotent re-tick (esc $esc_n_before->$esc_n_after spawns $spawn_attempts_before->$spawn_attempts_after)"

# =============================================================== case H ===
# BRIEF-R2 #1: the RESIDENT stall watchdog itself feeds the detector — not
# just the standalone CLI exercised above. Drive real `stall-watchdog.sh
# wake` calls (its own send/notify hooks faked so this stays fully
# offline) and prove end-to-end: real git commit sha, real escalation,
# real quiesce-before-spawn ordering, all via the actual resident entrypoint.
cat >"$WORK/fake-notify.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$WORK/fake-send.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
export HERDR_STALL_WATCHDOG_SEND="$WORK/fake-send.sh"
export HERDR_STALL_WATCHDOG_NOTIFY="$WORK/fake-notify.sh"

RUN=taskH; TASK=taskH; PANE=pane-H; BRANCH=esc-test-h
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
for i in 1 2 3; do
  bash "$here/stall-watchdog.sh" wake "$TASK" artifact "fp-h-same" "stuck" >/dev/null 2>&1
done
tick_n="$(event_count "$RUN" "$TASK" no_progress_tick)"
tick_shas="$(_sql "SELECT DISTINCT json_extract(payload,'\$.commit_sha') FROM events
  WHERE run_id=$(_sq "$RUN") AND task_id=$(_sq "$TASK") AND type='no_progress_tick';" 2>/dev/null)"
[ "${tick_n:-0}" = 3 ] && ok "H: the resident stall-watchdog.sh records one tick per real wake cycle" \
  || bad "H: ticks recorded via stall-watchdog.sh (got $tick_n)"
[ "$tick_shas" = "$HEAD_SHA" ] && ok "H: stall-watchdog.sh derives the REAL git HEAD as commit_sha, no placeholder" \
  || bad "H: real commit sha via stall-watchdog.sh (got [$tick_shas] want [$HEAD_SHA])"
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
[ "${esc_n:-0}" = 1 ] && ok "H: a real no-progress loop through stall-watchdog.sh escalates" \
  || bad "H: escalation via stall-watchdog.sh (got $esc_n)"
ci="$(order_index 'close pane-H')"; si="$(order_index 'spawn implement esc-test-h')"
[ -n "$ci" ] && [ -n "$si" ] && [ "$ci" -lt "$si" ] \
  && ok "H: quiesce-before-spawn ordering holds through the real watchdog path too" \
  || bad "H: ordering via stall-watchdog.sh (close@$ci spawn@$si)"

# conductor_prompt is the one stall-watchdog signal that means "waiting on
# the conductor/human" — must set waiting_on_human, never escalate alone.
RUN=taskI; TASK=taskI; PANE=pane-I; BRANCH=esc-test-i
seed_task "$TASK" "$PANE" "$BRANCH"
bash "$here/stall-watchdog.sh" wake "$TASK" conductor_prompt "fp-i" "needs a decision" >/dev/null 2>&1
wh="$(_sql "SELECT json_extract(payload,'\$.waiting_on_human') FROM events
  WHERE run_id=$(_sq "$RUN") AND task_id=$(_sq "$TASK") AND type='no_progress_tick' ORDER BY sequence DESC LIMIT 1;" 2>/dev/null)"
[ "$wh" = 1 ] && ok "I: conductor_prompt signal maps to waiting_on_human" || bad "I: conductor_prompt -> waiting_on_human (got $wh)"

# denied is the one signal that carries a tool-failure signature.
RUN=taskJ; TASK=taskJ; PANE=pane-J; BRANCH=esc-test-j
seed_task "$TASK" "$PANE" "$BRANCH"
bash "$here/stall-watchdog.sh" wake "$TASK" denied "fp-j" "rm -rf refused" >/dev/null 2>&1
tfs="$(_sql "SELECT json_extract(payload,'\$.tool_fail_sig') FROM events
  WHERE run_id=$(_sq "$RUN") AND task_id=$(_sq "$TASK") AND type='no_progress_tick' ORDER BY sequence DESC LIMIT 1;" 2>/dev/null)"
[ -n "$tfs" ] && ok "J: denied signal carries a non-empty tool_fail_sig" || bad "J: denied -> tool_fail_sig (got [$tfs])"

printf '%s passed, %s failed\n' "$pass" "$fail"
# WORK lives under tmp/ (gitignored) — left in place rather than recursively
# removed; rerunning resets the registry/order-log/pane state it depends on.
[ "$fail" -eq 0 ]
