#!/usr/bin/env bash
# verify-no-progress-escalation.sh — deterministic simulation of
# lib/escalation.sh + no-progress-escalate.sh against an isolated registry
# (own HERDR_RUN_STATE_DIR under mktemp -d; never touches live
# ~/.local/state). Covers BRIEF #5's five cases:
#   1. 3 identical-evidence ticks -> exactly one escalation
#   2. the ladder's cap: one escalation per tier, never past the ceiling
#   3. a recorded denial survives an escalation untouched
#   4. a human-wait tick is never escalated, even with matching evidence
#   5. a re-tick after escalation is idempotent (no duplicate event)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$here/tmp/verify-escalation"
mkdir -p "$WORK"
export HERDR_RUN_STATE_DIR="$WORK/runs"
mkdir -p "$HERDR_RUN_STATE_DIR"
# Specific files only, never recursive: a clean registry per run so earlier
# runs' state (run_id/task_id are reused literals) can't leak into this
# run's counts.
rm -f "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$HERDR_RUN_STATE_DIR/registry.sqlite3-wal" "$HERDR_RUN_STATE_DIR/registry.sqlite3-shm"
export HERDR_ESCALATION_LADDER="fast standard deep"
export HERDR_NO_PROGRESS_CYCLES=3
CTX="$WORK/ctx"
CLI="$here/no-progress-escalate.sh"

. "$here/lib/escalation.sh"

pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

escalated_count() {  # run_id task_id tier -> count of model_escalated events landing on tier
  registry_init >/dev/null 2>&1
  _sql "SELECT COUNT(*) FROM events WHERE run_id=$(_sq "$1") AND task_id=$(_sq "$2")
    AND type='model_escalated' AND json_extract(payload,'\$.to_tier')=$(_sq "$3");" 2>/dev/null
}

# ---- case 1: 3 identical ticks -> exactly one escalation (fast -> standard)
RUN=run1; TASK=task1
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha abc123 --artifact-fp fpA --context-dir "$CTX" >/dev/null
done
n="$(escalated_count "$RUN" "$TASK" standard)"
[ "${n:-0}" = 1 ] && ok "3 identical ticks escalate exactly once" || bad "3 identical ticks escalate exactly once (got $n)"
[ -f "$CTX/escalation-${TASK}-standard.md" ] && ok "context packet written" || bad "context packet written"

# fewer than the window should not escalate yet
RUN=run1b; TASK=task1b
bash "$CLI" tick "$RUN" "$TASK" --commit-sha x --artifact-fp y --context-dir "$CTX" >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha x --artifact-fp y --context-dir "$CTX" >/dev/null
n="$(escalated_count "$RUN" "$TASK" standard)"
[ "${n:-0}" = 0 ] && ok "2 ticks (below window) do not escalate" || bad "2 ticks (below window) do not escalate (got $n)"

# ---- case 2: cap — walk the whole ladder, never past the ceiling, one per tier
RUN=run2; TASK=task2
for i in 1 2 3 4 5 6 7 8 9; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha stuck --artifact-fp stuck --context-dir "$CTX" >/dev/null
done
n_std="$(escalated_count "$RUN" "$TASK" standard)"
n_deep="$(escalated_count "$RUN" "$TASK" deep)"
[ "${n_std:-0}" = 1 ] && ok "cap: exactly one escalation to standard across 9 ticks" || bad "cap: standard escalations (got $n_std)"
[ "${n_deep:-0}" = 1 ] && ok "cap: exactly one escalation to deep across 9 ticks" || bad "cap: deep escalations (got $n_deep)"
total="$(registry_init >/dev/null 2>&1; _sql "SELECT COUNT(*) FROM events WHERE run_id=$(_sq "$RUN") AND task_id=$(_sq "$TASK") AND type='model_escalated';" 2>/dev/null)"
[ "${total:-0}" = 2 ] && ok "cap: no escalation past the ladder ceiling (deep)" || bad "cap: total escalations should stop at 2, got $total"

# ---- case 3: a recorded denial is never touched by an escalation
RUN=run3; TASK=task3
registry_init >/dev/null 2>&1
append_event "$RUN" "$TASK" approval_escalated '{"verdict":"deny","reason":"rm -rf refused"}' >/dev/null
before="$(esc_open_denials "$RUN" "$TASK")"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha d1 --artifact-fp d1 --context-dir "$CTX" >/dev/null
done
after="$(esc_open_denials "$RUN" "$TASK")"
[ "$before" = 1 ] && [ "$after" = 1 ] && ok "denial survives escalation (still recorded, not cleared)" \
  || bad "denial survives escalation (before=$before after=$after)"
esc_n="$(escalated_count "$RUN" "$TASK" standard)"
[ "${esc_n:-0}" = 1 ] && ok "escalation still happened alongside the surviving denial" || bad "escalation alongside denial (got $esc_n)"

# ---- case 4: human-wait is not a loop, even with otherwise-matching evidence
RUN=run4; TASK=task4
bash "$CLI" tick "$RUN" "$TASK" --commit-sha same --artifact-fp same --context-dir "$CTX" >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha same --artifact-fp same --context-dir "$CTX" >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha same --artifact-fp same --waiting-on-human --context-dir "$CTX" >/dev/null
n="$(escalated_count "$RUN" "$TASK" standard)"
[ "${n:-0}" = 0 ] && ok "human-wait tick is not escalated" || bad "human-wait tick is not escalated (got $n)"
verdict="$(bash "$CLI" detect "$RUN" "$TASK")"
reason="$(printf '%s' "$verdict" | jq -r .reason)"
[ "$reason" = human_wait ] && ok "detect reports human_wait reason" || bad "detect reports human_wait reason (got $reason)"

# ---- case 5: idempotent re-tick — escalating once more at the SAME tier
# evidence does not duplicate the model_escalated event
RUN=run5; TASK=task5
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha same5 --artifact-fp same5 --context-dir "$CTX" >/dev/null
done
n1="$(escalated_count "$RUN" "$TASK" standard)"
bash "$CLI" tick "$RUN" "$TASK" --commit-sha same5 --artifact-fp same5 --context-dir "$CTX" >/dev/null
n2="$(escalated_count "$RUN" "$TASK" standard)"
[ "$n1" = 1 ] && [ "$n2" = 1 ] && ok "idempotent re-tick: no duplicate escalation" \
  || bad "idempotent re-tick (n1=$n1 n2=$n2)"

# ---- dry-run: audit event + packet, but handoff hook never invoked
RUN=run6; TASK=task6
HOOK_LOG="$WORK/hook.log"; export HOOK_LOG; : >"$HOOK_LOG"
export HERDR_ESCALATION_HANDOFF_CMD="$WORK/fake-hook.sh"
cat >"$WORK/fake-hook.sh" <<'SH'
#!/usr/bin/env bash
printf 'called %s\n' "$*" >> "$HOOK_LOG"
SH
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha dr --artifact-fp dr --dry-run --context-dir "$CTX" >/dev/null
done
n="$(escalated_count "$RUN" "$TASK" standard)"
[ "${n:-0}" = 1 ] && ok "dry-run still records the audit event" || bad "dry-run audit event (got $n)"
[ ! -s "$HOOK_LOG" ] && ok "dry-run never invokes the handoff hook" || bad "dry-run invoked handoff hook: $(cat "$HOOK_LOG" 2>/dev/null)"

# ---- live (non-dry-run) handoff hook IS invoked exactly once per escalation
RUN=run7; TASK=task7
: > "$HOOK_LOG"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha live --artifact-fp live --context-dir "$CTX" >/dev/null
done
calls="$(wc -l < "$HOOK_LOG" | tr -d ' ')"
[ "${calls:-0}" = 1 ] && ok "live escalation invokes the handoff hook exactly once" \
  || bad "live escalation handoff hook calls (got $calls)"

printf '%s passed, %s failed\n' "$pass" "$fail"
# WORK lives under tmp/ (gitignored) — left in place rather than recursively
# removed; rerunning just overwrites the same registry/context files.
[ "$fail" -eq 0 ]
