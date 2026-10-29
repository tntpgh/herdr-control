#!/usr/bin/env bash
# verify-no-progress-escalation.sh — R2's REAL quiesce-old/spawn-new hook,
# PLUS R3 (root audit of 7bb9fba): a releasable lock taken before the
# first side effect, incarnation pinning (pane_birth, not just pane_id/
# liveness), a 4-tier cross-family ladder read from $HERDR_CODEX_DEEP
# rather than an invented model, denial-vs-failure-signature separation,
# and a registry-grounded human-wait check. All exercised offline against
# fake `herdr pane`/spawn-task.sh commands (HERDR_ESC_PANE_ALIVE_CMD/
# _PANE_BIRTH_CMD/_PANE_CLOSE_CMD/_SPAWN_CMD — see lib/escalation.sh's
# header) and a real git repo for exact commit shas. Isolated registry +
# TMPDIR, both under tmp/; never touches live ~/.local/state, never calls
# a real herdr/spawn-task.sh.
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
#   H/I. the resident stall-watchdog.sh itself feeds the detector, with a
#      real git HEAD and real quiesce-before-spawn ordering (regression)
#   J. R3 #9: `denied` feeds denial_sig, NEVER tool_fail_sig — a model
#      refusal and a policy denial are told apart in the evidence itself
#   K. R3 #1: the lock is taken BEFORE the first side effect — a nested
#      concurrent attempt fired mid-hook is refused with zero extra
#      close/spawn side effects, not merely deduped after the fact
#   L. R3 #2: a recycled pane_id (birth mismatch) is treated as "already
#      gone", never actually closed — no false close of an unrelated writer
#   M. R3 #2/#3: an indeterminate pane birth (herdr unreachable) fails the
#      attempt CLOSED — nothing closed, task preserved, later retry works
#   N. R3 #5/#6: a genuine loop with an open denial carries the EXACT
#      denial forward into both the audit event and the context packet,
#      marked no_auto_retry — not merely "the classifier would still refuse"
#   O. R3 #5/#9: a repeated denial signature ALONE, with real progress
#      otherwise, never drives a loop verdict (but is still surfaced)
#   P. R3 #6: an open `input_required` excludes escalation regardless of
#      which stall-watchdog signal triggered the tick, and clears once the
#      registry shows it was acted on
#   Q. R3 #4: the exact ladder — fast/standard/deep stay in-family, frontier
#      is a verified cross-family jump read live from $HERDR_CODEX_DEEP
#   R. R3 #5: the real herdr binary is never called, proven by a PATH-wide
#      shadow that records any call, not just "we didn't observe one"
#   S. R4 fix D: a never-escalated task spawned already on a STRONGER tier
#      (e.g. implement/sonnet) is read as starting there, not assumed to
#      be on the ladder's weakest tier — escalates standard->deep, never
#      sideways fast->standard into the model it already runs
#   T. R4 fix D: a task with no recognizable job-class in its own spawn
#      record has no verifiable starting tier — escalation fails CLOSED
#      (no event, no bookkeeping, no side effect), never guesses fast
#   U. R4 residual (a): a slow close/spawn hook that outlasts the raw
#      lock TTL does NOT let a second writer in — a background renewer
#      keeps the fence fresh for the whole attempt
#   V/W. R5: first-successor discovery binds to the spawn's own
#      RECEIPT (task_id echoed back by the spawn call itself), never a
#      branch+label scan at any timestamp filter — a decoy on the same
#      branch+label is never adopted whether created at the same moment
#      as the request (V) or later, mid-loop (W)
#   X. R5: a spawn whose registry row lands but whose receipt is missing
#      or unparseable fails CLOSED — no adoption, no escalation, task
#      held for the conductor like any other hook failure
#   Y. R6 (root-audit reject of R5): a lost receipt on a spawn that
#      ACTUALLY SUCCEEDED is UNCERTAIN — a durable, restart-surviving
#      spawn journal (checked/claimed BEFORE the spawn command runs)
#      caps it at exactly ONE real attempt across this call's own retry
#      loop, every later watchdog tick, and a simulated process restart;
#      the task is marked blocked/held rather than left silently running
#      with zero or an unbounded number of real owners. Independently
#      reproduced by the reviewer against 30398f8: 6 orphaned running
#      successor rows for one task across just 2 calls.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

export WORK="$here/tmp/verify-escalation"
mkdir -p "$WORK"
export TMPDIR="$WORK/TMPDIR"; mkdir -p "$TMPDIR"          # offline, TMPDIR under tmp/
export HERDR_RUN_STATE_DIR="$WORK/runs"
mkdir -p "$HERDR_RUN_STATE_DIR"
# Specific files only, never recursive: a clean registry per run so a
# literal task/branch name reused across runs can't leak stale rows in.
rm -f "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$HERDR_RUN_STATE_DIR/registry.sqlite3-wal" "$HERDR_RUN_STATE_DIR/registry.sqlite3-shm"

export HERDR_ESCALATION_LADDER="fast standard deep frontier"
export HERDR_NO_PROGRESS_CYCLES=3
export HERDR_ESCALATION_QUIESCE_POLLS=3

PANES_DIR="$WORK/panes"; mkdir -p "$PANES_DIR"
rm -f "$PANES_DIR"/*.alive "$PANES_DIR"/*.lag "$PANES_DIR"/*.indeterminate "$PANES_DIR"/*.birth "$PANES_DIR"/*.birth-unreachable 2>/dev/null
ORDER_LOG="$WORK/order.log"; : >"$ORDER_LOG"
rm -f "$WORK/spawn-fail-count" "$WORK/nested-probe-branch" "$WORK/nested-probe-pane" "$WORK/nested-probe-fired" "$WORK/nested-probe-out.log" "$WORK/slow-close-pane" "$WORK/spawn-suppress-receipt" "$WORK/decoy-inject-branch" "$WORK/decoy-inject-task-id" "$WORK/decoy-injected"
export PANES_DIR ORDER_LOG HERE_REPO="$here"

# R3 #5 ("offline only: no live close or spawn") belt-and-suspenders: every
# code path that would touch a REAL herdr/spawn-task.sh is covered by the
# HERDR_ESC_*_CMD overrides below, set before any call. As an explicit,
# independently-checkable proof rather than just "we didn't observe one",
# shadow `herdr` on PATH for the whole run with a fake that records a
# violation marker and fails loudly — if any code path here ever falls
# through to the real default (override unset, a future regression), this
# catches it instead of silently calling out.
HERDR_SHADOW_BIN="$WORK/shadow-bin"; mkdir -p "$HERDR_SHADOW_BIN"
rm -f "$WORK/herdr-violation"
cat >"$HERDR_SHADOW_BIN/herdr" <<SH
#!/usr/bin/env bash
printf 'UNEXPECTED REAL herdr CALL: %s\\n' "\$*" >> "$WORK/herdr-violation"
exit 1
SH
export PATH="$HERDR_SHADOW_BIN:$PATH"

CTX="$WORK/ctx"
CLI="$here/no-progress-escalate.sh"
export CTX CLI

# Real config defaults (e.g. $HERDR_CODEX_DEEP) — sourced AFTER the
# test-specific overrides above, which it will not clobber (config.sh's
# own `: "${VAR:=default}"` idiom only fills in what is still unset).
source "$here/config.sh"

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

# ---- fake hook scripts (HERDR_ESC_PANE_ALIVE_CMD / _PANE_BIRTH_CMD /
# _PANE_CLOSE_CMD / _SPAWN_CMD)
cat >"$WORK/fake-pane-alive.sh" <<'SH'
#!/usr/bin/env bash
pane="$1"
[ -f "$PANES_DIR/$pane.indeterminate" ] && exit 2
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
cat >"$WORK/fake-pane-birth.sh" <<'SH'
#!/usr/bin/env bash
pane="$1"
[ -f "$PANES_DIR/$pane.birth-unreachable" ] && exit 1
f="$PANES_DIR/$pane.birth"
[ -f "$f" ] && cat "$f"
exit 0
SH
cat >"$WORK/fake-pane-close.sh" <<'SH'
#!/usr/bin/env bash
pane="$1"
printf 'close %s\n' "$pane" >> "$ORDER_LOG"
# R4 residual (a): simulate "close/spawn slow" — the close call itself
# blocks past what a naive un-renewed lock's TTL would allow.
sc="$WORK/slow-close-pane"
if [ -f "$sc" ] && [ "$(cat "$sc")" = "$pane" ]; then
  sleep "${SLOW_CLOSE_SECONDS:-0}"
fi
# Fire a nested concurrent attempt AFTER the slow close returns — late
# enough that a naive (non-renewing) lock would already have expired.
np="$WORK/nested-probe-pane"
if [ -f "$np" ] && [ "$(cat "$np")" = "$pane" ] && [ ! -f "$WORK/nested-probe-fired" ]; then
  : > "$WORK/nested-probe-fired"
  bash "$CLI" tick "$NESTED_RUN" "$NESTED_TASK" --commit-sha unused --artifact-fp "$NESTED_FP" --context-dir "$CTX" \
    > "$WORK/nested-probe-out.log" 2>&1
fi
[ -f "$PANES_DIR/$pane.lag" ] || rm -f "$PANES_DIR/$pane.alive"
exit 0
SH
cat >"$WORK/fake-spawn.sh" <<'SH'
#!/usr/bin/env bash
# <repo> <branch> <job> <agent>
set -uo pipefail
repo="$1" branch="$2" job="$3" agent="$4"
. "$HERE_REPO/lib/run-registry.sh"
# R3 case K: prove the lock is taken BEFORE this, the first real side
# effect of a spawn attempt — fire a SECOND, concurrent esc_escalate call
# for the same task from inside the first one's own hook, before this
# attempt's own spawn row is written. It must be refused by the lock with
# zero side effects of its own; this outer attempt then proceeds normally.
nb="$WORK/nested-probe-branch"
if [ -f "$nb" ] && [ "$(cat "$nb")" = "$branch" ] && [ ! -f "$WORK/nested-probe-fired" ]; then
  : > "$WORK/nested-probe-fired"
  bash "$CLI" tick "$NESTED_RUN" "$NESTED_TASK" --commit-sha unused --artifact-fp "$NESTED_FP" --context-dir "$CTX" \
    > "$WORK/nested-probe-out.log" 2>&1
fi
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
succ_birth="birth_succ_${job}_$$_${RANDOM}"
: > "$PANES_DIR/$succ_pane.alive"
printf '%s' "$succ_birth" > "$PANES_DIR/$succ_pane.birth"
now="$(_now_iso)"
registry_init
_sql "INSERT INTO tasks (task_id, run_id, worker_id, conductor_id, conductor_pane_id, conductor_pane_birth, pane_id, pane_birth, agent_session, repo, worktree, branch, trunk, project, manifest, label, state, created_at, updated_at)
  VALUES ($(_sq "$succ_task"), $(_sq "$succ_task"), '', '', '', '', $(_sq "$succ_pane"), $(_sq "$succ_birth"), '', $(_sq "$repo"), $(_sq "$repo"), $(_sq "$branch"), '', '', '', $(_sq "${job}:${branch}"), 'running', $(_sq "$now"), $(_sq "$now"));"
# Case W (R5): a decoy lands on this EXACT branch+label strictly AFTER
# the real successor's own row — the realistic "arrives right behind
# it" race a highest-rowid/latest-timestamp heuristic cannot defend
# against, only a true receipt binding can.
di="$WORK/decoy-inject-branch"
if [ -f "$di" ] && [ "$(cat "$di")" = "$branch" ] && [ ! -f "$WORK/decoy-injected" ]; then
  : > "$WORK/decoy-injected"
  decoy_task="$(cat "$WORK/decoy-inject-task-id" 2>/dev/null)"
  decoy_now="$(_now_iso)"
  _sql "INSERT INTO tasks (task_id, run_id, worker_id, conductor_id, conductor_pane_id, conductor_pane_birth, pane_id, pane_birth, agent_session, repo, worktree, branch, trunk, project, manifest, label, state, created_at, updated_at)
    VALUES ($(_sq "$decoy_task"), $(_sq "$decoy_task"), '', '', '', '', '', '', '', $(_sq "$repo"), $(_sq "$repo"), $(_sq "$branch"), '', '', '', $(_sq "${job}:${branch}"), 'running', $(_sq "$decoy_now"), $(_sq "$decoy_now"));"
fi
# R5: the receipt IS the discovery mechanism now — suppressible for the
# missing-receipt fail-closed test (case X), which still creates the row
# above (a real spawn can succeed at the registry write and still fail
# to deliver a usable receipt, e.g. truncated output).
if [ ! -f "$WORK/spawn-suppress-receipt" ]; then
  printf 'HERDR_SPAWN_RECEIPT task_id=%s run_id=%s\n' "$succ_task" "$succ_task"
fi
exit 0
SH

export HERDR_ESC_PANE_ALIVE_CMD="$WORK/fake-pane-alive.sh"
export HERDR_ESC_PANE_BIRTH_CMD="$WORK/fake-pane-birth.sh"
export HERDR_ESC_PANE_CLOSE_CMD="$WORK/fake-pane-close.sh"
export HERDR_ESC_SPAWN_CMD="$WORK/fake-spawn.sh"

seed_task() {   # task_id pane branch [pane_birth] [job]
  local task_id="$1" pane="$2" branch="$3" birth="${4:-}" job="${5:-explore}" now
  now="$(_now_iso)"
  registry_init
  _sql "INSERT INTO tasks (task_id, run_id, worker_id, conductor_id, conductor_pane_id, conductor_pane_birth, pane_id, pane_birth, agent_session, repo, worktree, branch, trunk, project, manifest, label, state, created_at, updated_at)
    VALUES ($(_sq "$task_id"), $(_sq "$task_id"), '', '', '', '', $(_sq "$pane"), $(_sq "$birth"), '', $(_sq "$REPO"), $(_sq "$REPO"), $(_sq "$branch"), '', '', '', $(_sq "${job}:${branch}"), 'running', $(_sq "$now"), $(_sq "$now"));"
  : > "$PANES_DIR/$pane.alive"
  [ -n "$birth" ] && printf '%s' "$birth" > "$PANES_DIR/$pane.birth"
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
spawn_attempts="$(grep -c -- 'spawn-fail.* esc-test-c' "$ORDER_LOG" 2>/dev/null)"
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
spawn_attempts_before="$(grep -c -- 'spawn implement esc-test-a' "$ORDER_LOG" 2>/dev/null)"
bash "$CLI" tick taskA taskA --commit-sha unused --artifact-fp fpA --context-dir "$CTX" >/dev/null
esc_n_after="$(event_count taskA taskA model_escalated)"
spawn_attempts_after="$(grep -c -- 'spawn implement esc-test-a' "$ORDER_LOG" 2>/dev/null)"
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

# R3 #9: denied is a POLICY denial, not a tool execution failure — it must
# feed denial_sig and leave tool_fail_sig empty, so a repeated denial can
# never by itself be read as "repeated_tool_failure_signature".
RUN=taskJ; TASK=taskJ; PANE=pane-J; BRANCH=esc-test-j
seed_task "$TASK" "$PANE" "$BRANCH"
bash "$here/stall-watchdog.sh" wake "$TASK" denied "fp-j" "rm -rf refused" >/dev/null 2>&1
tick_row="$(_sql "SELECT json(payload) FROM events
  WHERE run_id=$(_sq "$RUN") AND task_id=$(_sq "$TASK") AND type='no_progress_tick' ORDER BY sequence DESC LIMIT 1;" 2>/dev/null)"
tfs="$(printf '%s' "$tick_row" | jq -r '.tool_fail_sig // empty')"
dsig="$(printf '%s' "$tick_row" | jq -r '.denial_sig // empty')"
[ -n "$dsig" ] && ok "J: denied signal carries a non-empty denial_sig" || bad "J: denied -> denial_sig (got [$dsig])"
[ -z "$tfs" ] && ok "J: denied signal leaves tool_fail_sig empty (not conflated with a tool execution failure)" \
  || bad "J: denied must not feed tool_fail_sig (got [$tfs])"

# =============================================================== case K ===
# R3 #1: the serialization lock is taken BEFORE the first side effect. Fire
# a SECOND, concurrent esc_escalate attempt for the SAME task from inside
# the first attempt's own spawn hook (fake-spawn.sh's nested-probe) — it
# must be refused by the lock before touching close/spawn at all, so the
# outer attempt's own close/spawn counts stay at exactly one each.
RUN=taskK; TASK=taskK; PANE=pane-K; BRANCH=esc-test-k
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
rm -f "$WORK/nested-probe-fired" "$WORK/nested-probe-out.log"
printf '%s' "$BRANCH" > "$WORK/nested-probe-branch"
export NESTED_RUN="$RUN" NESTED_TASK="$TASK" NESTED_FP="fpK"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpK --context-dir "$CTX" >/dev/null
done
rm -f "$WORK/nested-probe-branch"
close_count="$(grep -c -- 'close pane-K' "$ORDER_LOG" 2>/dev/null)"
spawn_count="$(grep -c -- 'spawn implement esc-test-k' "$ORDER_LOG" 2>/dev/null)"
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
succ_rows="$(_sql "SELECT COUNT(*) FROM tasks WHERE branch=$(_sq "$BRANCH") AND label='implement:$BRANCH';" 2>/dev/null)"
[ -f "$WORK/nested-probe-fired" ] && ok "K: the nested concurrent attempt actually ran (test is exercising the race)" \
  || bad "K: nested probe never fired — test setup broken"
[ "${close_count:-0}" = 1 ] && ok "K: exactly one close despite a concurrent attempt mid-hook (lock held before quiesce)" \
  || bad "K: close count (got $close_count)"
[ "${spawn_count:-0}" = 1 ] && ok "K: exactly one spawn despite a concurrent attempt mid-hook" \
  || bad "K: spawn count (got $spawn_count)"
[ "${esc_n:-0}" = 1 ] && ok "K: exactly one model_escalated despite a concurrent attempt" \
  || bad "K: model_escalated count (got $esc_n)"
[ "${succ_rows:-0}" = 1 ] && ok "K: exactly one successor row despite a concurrent attempt" \
  || bad "K: successor row count (got $succ_rows)"
grep -q 'locked by a concurrent attempt' "$WORK/nested-probe-out.log" 2>/dev/null \
  && ok "K: the nested attempt was explicitly refused BY THE LOCK, not a side-effect accident" \
  || bad "K: nested attempt lock-refusal message missing: $(cat "$WORK/nested-probe-out.log" 2>/dev/null)"

# =============================================================== case L ===
# R3 #2: a recycled pane_id (the live birth no longer matches the task's
# recorded pane_birth) is treated as "that incarnation is already gone" —
# never actually closed, since whatever is running there now is NOT the
# writer this escalation was asked to quiesce.
RUN=taskL; TASK=taskL; PANE=pane-L; BRANCH=esc-test-l
seed_task "$TASK" "$PANE" "$BRANCH" "birth-L-v1"
printf '%s' "birth-L-v2" > "$PANES_DIR/$PANE.birth"   # a DIFFERENT live occupant now
: >"$ORDER_LOG"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpL --context-dir "$CTX" >/dev/null
done
close_count="$(grep -c -- 'close pane-L' "$ORDER_LOG" 2>/dev/null)"
spawn_count="$(grep -c -- 'spawn implement esc-test-l' "$ORDER_LOG" 2>/dev/null)"
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
quiesce_reason="$(_sql "SELECT json_extract(payload,'\$.reason') FROM events
  WHERE run_id=$(_sq "$RUN") AND task_id=$(_sq "$TASK") AND type='writer_quiesced' LIMIT 1;" 2>/dev/null)"
[ "${close_count:-0}" = 0 ] && ok "L: a recycled pane is never actually closed (not our writer anymore)" \
  || bad "L: close count should be 0 for a recycled pane (got $close_count)"
[ "${spawn_count:-0}" = 1 ] && ok "L: the successor still spawns once the recycled pane is recognized as gone" \
  || bad "L: spawn count (got $spawn_count)"
[ "${esc_n:-0}" = 1 ] && ok "L: escalation still completes exactly once" || bad "L: model_escalated count (got $esc_n)"
[ "$quiesce_reason" = pane_recycled_or_gone ] && ok "L: writer_quiesced records the exact recycled-pane reason" \
  || bad "L: writer_quiesced reason (got [$quiesce_reason])"

# =============================================================== case M ===
# R3 #2/#3: an INDETERMINATE pane birth (herdr itself unreachable) fails
# the attempt CLOSED — nothing closed, task preserved, no model_escalated
# — never silently read as "already gone". A later retry, once birth
# becomes verifiable again, still succeeds exactly once.
RUN=taskM; TASK=taskM; PANE=pane-M; BRANCH=esc-test-m
seed_task "$TASK" "$PANE" "$BRANCH" "birth-M-v1"
: > "$PANES_DIR/$PANE.birth-unreachable"
: >"$ORDER_LOG"
export HERDR_ESCALATION_HOOK_RETRIES=2
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpM --context-dir "$CTX" >/dev/null
done
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
failed_n="$(event_count "$RUN" "$TASK" model_escalation_hook_failed)"
close_count="$(grep -c -- 'close pane-M' "$ORDER_LOG" 2>/dev/null)"
[ "${esc_n:-0}" = 0 ] && ok "M: no model_escalated while the pane's birth is indeterminate" \
  || bad "M: model_escalated should be 0 while indeterminate (got $esc_n)"
[ "${failed_n:-0}" -ge 1 ] && ok "M: hook failure recorded while birth is indeterminate" \
  || bad "M: model_escalation_hook_failed recorded"
[ "${close_count:-0}" = 0 ] && ok "M: the pane is never closed while its birth could not be verified (fail closed)" \
  || bad "M: close count should be 0 while indeterminate (got $close_count)"
rm -f "$PANES_DIR/$PANE.birth-unreachable"
bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpM --context-dir "$CTX" >/dev/null
esc_n2="$(event_count "$RUN" "$TASK" model_escalated)"
[ "${esc_n2:-0}" = 1 ] && ok "M: a later retry succeeds exactly once once birth becomes verifiable again" \
  || bad "M: recovery retry (got $esc_n2)"
export HERDR_ESCALATION_HOOK_RETRIES=3

# =============================================================== case N ===
# R3 #5/#6: a genuine loop (real no-progress) WITH an open denial carries
# the EXACT denial forward — into the audit event AND the context packet,
# marked no_auto_retry — not merely "a classifier rerun would still refuse".
RUN=taskN; TASK=taskN; PANE=pane-N; BRANCH=esc-test-n
seed_task "$TASK" "$PANE" "$BRANCH"
append_event "$RUN" "$TASK" approval_escalated \
  '{"verdict":"deny","reason":"client PII write blocked","command":"echo secret > tracked.txt"}' >/dev/null
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpN --context-dir "$CTX" >/dev/null
done
carried_n="$(event_count "$RUN" "$TASK" denial_carried_forward)"
payload="$(escalated_payload "$RUN" "$TASK" standard)"
held_reason="$(printf '%s' "$payload" | jq -r '.held_denials[0].reason // empty')"
no_retry="$(_sql "SELECT json_extract(payload,'\$.no_auto_retry') FROM events
  WHERE run_id=$(_sq "$RUN") AND task_id=$(_sq "$TASK") AND type='denial_carried_forward' LIMIT 1;" 2>/dev/null)"
packet_file="$CTX/escalation-${TASK}-standard.md"
[ "${carried_n:-0}" = 1 ] && ok "N: denial_carried_forward written exactly once for the real escalation" \
  || bad "N: denial_carried_forward count (got $carried_n)"
[ "$held_reason" = "client PII write blocked" ] && ok "N: exact denied reason carried into model_escalated (not re-derived)" \
  || bad "N: held_denials reason (got [$held_reason])"
[ "$no_retry" = 1 ] && ok "N: denial_carried_forward marks no_auto_retry" || bad "N: no_auto_retry flag (got $no_retry)"
grep -q 'HELD' "$packet_file" 2>/dev/null && ok "N: context packet has an explicit HELD/do-not-retry section" \
  || bad "N: context packet HELD heading missing"
grep -q 'client PII write blocked' "$packet_file" 2>/dev/null \
  && ok "N: context packet states the held denial's exact reason under that section" \
  || bad "N: context packet denial text missing"

# =============================================================== case O ===
# R3 #5/#9: a repeated denial signature ALONE — even with real progress
# (changing commit/artifact each cycle) — must never drive a loop verdict;
# escalating on a denial alone would look like routing around it. The
# detector still surfaces it (held_denial) for a caller to act on
# separately, just never as the loop trigger itself.
RUN=taskO; TASK=taskO; PANE=pane-O; BRANCH=esc-test-o
seed_task "$TASK" "$PANE" "$BRANCH"
bash "$CLI" tick "$RUN" "$TASK" --commit-sha sha1 --artifact-fp fp1 --denial-sig samedenial --context-dir "$CTX" >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha sha2 --artifact-fp fp2 --denial-sig samedenial --context-dir "$CTX" >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha sha3 --artifact-fp fp3 --denial-sig samedenial --context-dir "$CTX" >/dev/null
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
[ "${esc_n:-0}" = 0 ] && ok "O: a repeated denial signature alone never drives a loop verdict" \
  || bad "O: denial-only should not escalate (got $esc_n)"
verdict="$(no_progress_detect "$RUN" "$TASK")"
held="$(printf '%s' "$verdict" | jq -r '.held_denial')"
[ "$held" = true ] && ok "O: held_denial is still surfaced in the verdict even though it never triggered the loop" \
  || bad "O: held_denial flag (got $held)"

# =============================================================== case P ===
# R3 #6: an open input_required excludes escalation regardless of WHICH
# signal triggered the tick (not just the conductor_prompt special case),
# and clears once the registry itself shows it was acted on.
RUN=taskP; TASK=taskP; PANE=pane-P; BRANCH=esc-test-p
seed_task "$TASK" "$PANE" "$BRANCH"
append_event "$RUN" "$TASK" input_required '{"prompt_id":"p1","tool":"bash"}' >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha samep --artifact-fp samep --context-dir "$CTX" >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha samep --artifact-fp samep --context-dir "$CTX" >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha samep --artifact-fp samep --context-dir "$CTX" >/dev/null
wh="$(_sql "SELECT json_extract(payload,'\$.waiting_on_human') FROM events
  WHERE run_id=$(_sq "$RUN") AND task_id=$(_sq "$TASK") AND type='no_progress_tick' ORDER BY sequence DESC LIMIT 1;" 2>/dev/null)"
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
[ "$wh" = 1 ] && ok "P: an open input_required sets waiting_on_human with no conductor_prompt signal involved" \
  || bad "P: waiting_on_human via registry alone (got $wh)"
[ "${esc_n:-0}" = 0 ] && ok "P: a pending human approval is never escalated regardless of which signal triggered the tick" \
  || bad "P: escalated despite an open input_required (got $esc_n)"
append_event "$RUN" "$TASK" owner_acted '{"prompt_id":"p1"}' >/dev/null
bash "$CLI" tick "$RUN" "$TASK" --commit-sha samep --artifact-fp samep --context-dir "$CTX" >/dev/null
wh2="$(_sql "SELECT json_extract(payload,'\$.waiting_on_human') FROM events
  WHERE run_id=$(_sq "$RUN") AND task_id=$(_sq "$TASK") AND type='no_progress_tick' ORDER BY sequence DESC LIMIT 1;" 2>/dev/null)"
esc_n2="$(event_count "$RUN" "$TASK" model_escalated)"
[ "$wh2" != 1 ] && ok "P: waiting_on_human clears once the registry shows the prompt was acted on" \
  || bad "P: waiting_on_human after owner_acted should clear (got $wh2)"
[ "${esc_n2:-0}" = 1 ] && ok "P: the same stuck window escalates once the human-wait clears" \
  || bad "P: escalation after the prompt resolved (got $esc_n2)"

# =============================================================== case Q ===
# R3 #4: the exact ladder. fast/standard/deep stay in the caller's own
# agent family (verified against model_for_agent's own table, never an
# invented name); frontier is a deliberate cross-family jump to whatever
# $HERDR_CODEX_DEEP actually resolves to right now — read live, not
# hardcoded, so it tracks PR #378 automatically once that merges.
[ "$(esc_tier_model claude standard)" = sonnet ] && ok "Q: exact standard-tier model (claude = sonnet)" \
  || bad "Q: standard model (got $(esc_tier_model claude standard))"
[ "$(esc_tier_model claude deep)" = opus ] && ok "Q: exact deep-tier model (claude = opus, not an invented 'opus-2')" \
  || bad "Q: deep model (got $(esc_tier_model claude deep))"
[ "$(esc_tier_agent claude frontier)" = codex ] && ok "Q: the frontier tier always resolves to the codex family" \
  || bad "Q: frontier agent (got $(esc_tier_agent claude frontier))"
frontier_model="$(esc_tier_model codex frontier)"
[ "$frontier_model" = "$HERDR_CODEX_DEEP" ] \
  && ok "Q: frontier-tier model is read live from \$HERDR_CODEX_DEEP (currently: $HERDR_CODEX_DEEP), never hardcoded" \
  || bad "Q: frontier model (got [$frontier_model] want [$HERDR_CODEX_DEEP])"
RUN=taskQ; TASK=taskQ; PANE=pane-Q; BRANCH=esc-test-q
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
for tier_round in 1 2 3; do
  : >"$ORDER_LOG"
  for i in 1 2 3; do
    bash "$CLI" tick "$RUN" "$TASK" --commit-sha "unused-$tier_round" --artifact-fp "fpQ-$tier_round" --context-dir "$CTX" >/dev/null
  done
done
from_frontier_payload="$(escalated_payload "$RUN" "$TASK" frontier)"
frontier_to_agent="$(printf '%s' "$from_frontier_payload" | jq -r '.to_agent // empty')"
frontier_to_model="$(printf '%s' "$from_frontier_payload" | jq -r '.to_model // empty')"
[ "$frontier_to_agent" = codex ] && ok "Q: the real end-to-end escalation to frontier records to_agent=codex" \
  || bad "Q: to_agent for frontier escalation (got [$frontier_to_agent])"
[ "$frontier_to_model" = "$HERDR_CODEX_DEEP" ] && ok "Q: the real end-to-end escalation to frontier records the live codex deep model" \
  || bad "Q: to_model for frontier escalation (got [$frontier_to_model] want [$HERDR_CODEX_DEEP])"
spawn_codex_count="$(grep -c -- 'spawn deep-review esc-test-q' "$ORDER_LOG" 2>/dev/null)"
[ "${spawn_codex_count:-0}" = 1 ] && ok "Q: the successor is spawned under the deep-review job-class, not a relabeled plan (no label collision with the deep tier)" \
  || bad "Q: spawn deep-review count (got $spawn_codex_count)"

# =============================================================== case S ===
# R4 fix D: a task that was NEVER escalated but was spawned already on a
# STRONGER tier (label="implement:branch" = standard/sonnet, not
# fast/haiku) must be read as starting on standard, not blindly assumed
# to be on the ladder's weakest tier — escalating it must move
# standard->deep (sonnet->opus), never fast->standard (which would look
# like "escalating" a sonnet worker sideways to the sonnet it already runs).
RUN=taskS; TASK=taskS; PANE=pane-S; BRANCH=esc-test-s
seed_task "$TASK" "$PANE" "$BRANCH" "" implement
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpS --context-dir "$CTX" >/dev/null
done
payload="$(escalated_payload "$RUN" "$TASK" deep)"
s_from_tier="$(printf '%s' "$payload" | jq -r '.from_tier // empty')"
s_from_model="$(printf '%s' "$payload" | jq -r '.from_model // empty')"
s_to_model="$(printf '%s' "$payload" | jq -r '.to_model // empty')"
already_standard="$(escalated_payload "$RUN" "$TASK" standard)"
[ "$s_from_tier" = standard ] && ok "S: a task spawned on implement is read as starting on standard, not fast" \
  || bad "S: from_tier for a pre-standard task (got [$s_from_tier])"
[ "$s_from_model" = sonnet ] && [ "$s_to_model" = opus ] \
  && ok "S: escalates standard->deep (sonnet->opus), not a sideways fast->standard" \
  || bad "S: from/to model (got from=[$s_from_model] to=[$s_to_model])"
[ -z "$already_standard" ] && ok "S: no fast->standard event was ever written for this task" \
  || bad "S: an unwanted standard-tier escalation exists: $already_standard"

# =============================================================== case T ===
# R4 fix D: a task whose own spawn record has NO recognizable job-class
# (a raw-command task, or one labeled with something this ladder doesn't
# map) has no verifiable starting tier — escalation must fail CLOSED
# (refuse, no event, no lock, no side effect) rather than guess fast.
RUN=taskT; TASK=taskT; PANE=pane-T; BRANCH=esc-test-t
seed_task "$TASK" "$PANE" "$BRANCH" "" probe
: >"$ORDER_LOG"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpT --context-dir "$CTX" >/dev/null
done
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
dry_n="$(event_count "$RUN" "$TASK" model_escalation_dry_run)"
failed_n="$(event_count "$RUN" "$TASK" model_escalation_hook_failed)"
[ "${esc_n:-0}" = 0 ] && ok "T: a task with an unrecognized job-class is never escalated" \
  || bad "T: model_escalated should be 0 for an unrecognized job-class (got $esc_n)"
[ "${dry_n:-0}" = 0 ] && [ "${failed_n:-0}" = 0 ] \
  && ok "T: refusal happens before ANY escalation bookkeeping (not even a hook-failed event) — a real fail-closed refusal, not a failed attempt" \
  || bad "T: unexpected escalation bookkeeping (dry=$dry_n failed=$failed_n)"
[ ! -s "$ORDER_LOG" ] && ok "T: no close/spawn side effect was ever attempted" \
  || bad "T: unexpected hook side effect: $(cat "$ORDER_LOG")"
esc_current_tier "$RUN" "$TASK" >/dev/null 2>&1
current_tier_rc=$?
[ "$current_tier_rc" -ne 0 ] && ok "T: esc_current_tier itself fails closed for an unrecognized job-class (not a silent fast default)" \
  || bad "T: esc_current_tier should fail for an unrecognized job-class (rc=$current_tier_rc)"

# =============================================================== case U ===
# R4 residual (a): the 300s lock can expire while the hook is still
# running (close/spawn slow) — that must NOT let a second writer in.
# Set a tiny TTL, make close block past it, and fire a nested concurrent
# attempt the instant close returns (already past the raw TTL). The
# background renewer must have kept the lock fresh throughout, so the
# nested attempt is STILL refused — proving renewal, not luck.
RUN=taskU; TASK=taskU; PANE=pane-U; BRANCH=esc-test-u
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
rm -f "$WORK/nested-probe-fired" "$WORK/nested-probe-out.log"
printf '%s' "$PANE" > "$WORK/nested-probe-pane"
printf '%s' "$PANE" > "$WORK/slow-close-pane"
export NESTED_RUN="$RUN" NESTED_TASK="$TASK" NESTED_FP="fpU"
export SLOW_CLOSE_SECONDS=3 HERDR_ESCALATION_LOCK_STALE_S=2
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpU --context-dir "$CTX" >/dev/null
done
unset SLOW_CLOSE_SECONDS HERDR_ESCALATION_LOCK_STALE_S
rm -f "$WORK/nested-probe-pane" "$WORK/slow-close-pane"
[ -f "$WORK/nested-probe-fired" ] && ok "U: the nested concurrent attempt actually ran after the raw TTL elapsed (test is exercising the real race)" \
  || bad "U: nested probe never fired — test setup broken"
close_count="$(grep -c -- 'close pane-U' "$ORDER_LOG" 2>/dev/null)"
spawn_count="$(grep -c -- 'spawn implement esc-test-u' "$ORDER_LOG" 2>/dev/null)"
esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
[ "${close_count:-0}" = 1 ] && ok "U: exactly one close despite the hook outlasting the raw TTL (renewal kept the lock fresh)" \
  || bad "U: close count (got $close_count)"
[ "${spawn_count:-0}" = 1 ] && ok "U: exactly one spawn — no double writer let in by expiry mid-hook" \
  || bad "U: spawn count (got $spawn_count)"
[ "${esc_n:-0}" = 1 ] && ok "U: exactly one model_escalated for the real attempt" \
  || bad "U: model_escalated count (got $esc_n)"
grep -q 'locked by a concurrent attempt' "$WORK/nested-probe-out.log" 2>/dev/null \
  && ok "U: the late nested attempt was refused by the still-fresh lock, not a side-effect accident" \
  || bad "U: nested attempt lock-refusal message missing: $(cat "$WORK/nested-probe-out.log" 2>/dev/null)"

# =============================================================== case V ===
# R5: first-successor discovery binds to the spawn's own RECEIPT, never
# a branch+label scan at any filter. Prove it against the SHARPEST case
# a timestamp filter could never exclude: a decoy whose created_at is
# forced far in the FUTURE (so `created_at >= request time` is true no
# matter what "now" ever resolves to) — not relying on wall-clock luck
# to land in the same second.
RUN=taskV; TASK=taskV; PANE=pane-V; BRANCH=esc-test-v; DECOY=taskV_decoy
seed_task "$DECOY" "pane-V-decoy" "$BRANCH" "" implement
_sql "UPDATE tasks SET created_at='2099-01-01T00:00:00Z' WHERE task_id=$(_sq "$DECOY");" >/dev/null
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpV --context-dir "$CTX" >/dev/null
done
v_payload="$(escalated_payload "$RUN" "$TASK" standard)"
v_successor="$(printf '%s' "$v_payload" | jq -r '.successor_task_id // empty')"
v_spawn_count="$(grep -c -- 'spawn implement esc-test-v' "$ORDER_LOG" 2>/dev/null)"
[ -n "$v_successor" ] && [ "$v_successor" != "$DECOY" ] && ok "V: a decoy no timestamp filter could ever exclude (created_at forced to the future) is still never adopted" \
  || bad "V: successor_task_id wrongly resolved to the decoy (got [$v_successor] decoy=[$DECOY])"
[ "${v_spawn_count:-0}" = 1 ] && ok "V: a genuinely new successor was spawned and its own receipt was what resolved it" \
  || bad "V: spawn count for the real attempt (got $v_spawn_count)"

# =============================================================== case W ===
# R5: a decoy injected from INSIDE the real attempt's own spawn call,
# immediately before the real successor's own row — the most realistic
# "concurrent, strictly after the request" scenario there is, not a
# wall-clock guess about ordering between separate ticks.
RUN=taskW; TASK=taskW; PANE=pane-W; BRANCH=esc-test-w; DECOY=taskW_decoy
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
printf '%s' "$BRANCH" > "$WORK/decoy-inject-branch"
printf '%s' "$DECOY" > "$WORK/decoy-inject-task-id"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpW --context-dir "$CTX" >/dev/null
done
rm -f "$WORK/decoy-inject-branch" "$WORK/decoy-inject-task-id"
w_payload="$(escalated_payload "$RUN" "$TASK" standard)"
w_successor="$(printf '%s' "$w_payload" | jq -r '.successor_task_id // empty')"
w_spawn_count="$(grep -c -- 'spawn implement esc-test-w' "$ORDER_LOG" 2>/dev/null)"
w_decoy_rows="$(_sql "SELECT COUNT(*) FROM tasks WHERE task_id=$(_sq "$DECOY");" 2>/dev/null)"
[ -f "$WORK/decoy-injected" ] && [ "${w_decoy_rows:-0}" = 1 ] && ok "W: the decoy actually landed mid-spawn (test is exercising the real race, not a no-op)" \
  || bad "W: decoy injection never happened — test setup broken"
[ -n "$w_successor" ] && [ "$w_successor" != "$DECOY" ] && ok "W: a decoy injected strictly during the real attempt's own spawn is never adopted" \
  || bad "W: successor_task_id wrongly resolved to the decoy (got [$w_successor] decoy=[$DECOY])"
[ "${w_spawn_count:-0}" = 1 ] && ok "W: a genuinely new successor was spawned despite the concurrent decoy" \
  || bad "W: spawn count for the real attempt (got $w_spawn_count)"

# =============================================================== case X ===
# R5: a spawn that writes its registry row but delivers no usable
# receipt (truncated output, a non-conforming HERDR_ESC_SPAWN_CMD) must
# fail CLOSED — no adoption via any fallback lookup, no model_escalated,
# the task held for the conductor exactly like any other hook failure.
# R6: strengthened to prove the retry-within-call dimension of the
# duplicate-writer bug root-audit found in 30398f8 — a suppressed
# receipt must cap at exactly ONE real spawn attempt across this single
# esc_escalate call's own bound retries, and the original task must be
# explicitly marked blocked/held rather than left silently running with
# an unverifiable owner.
RUN=taskX; TASK=taskX; PANE=pane-X; BRANCH=esc-test-x
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
: > "$WORK/spawn-suppress-receipt"
for i in 1 2 3; do
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpX --context-dir "$CTX" >/dev/null
done
rm -f "$WORK/spawn-suppress-receipt"
x_esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
x_failed_n="$(event_count "$RUN" "$TASK" model_escalation_hook_failed)"
x_pinned="$(task_last_event_payload "$RUN" "$TASK" writer_successor_pinned 2>/dev/null)"
x_spawn_count="$(grep -c -- 'spawn implement esc-test-x' "$ORDER_LOG" 2>/dev/null)"
x_state="$(_sql "SELECT state FROM tasks WHERE task_id=$(_sq "$TASK");" 2>/dev/null)"
[ "${x_esc_n:-0}" = 0 ] && ok "X: a spawn with no usable receipt never escalates" \
  || bad "X: model_escalated should be 0 with a suppressed receipt (got $x_esc_n)"
[ "${x_failed_n:-0}" = 1 ] && ok "X: the hook-failed path fires — task held for the conductor, same as any other hook failure" \
  || bad "X: model_escalation_hook_failed count (got $x_failed_n)"
[ -z "$x_pinned" ] && ok "X: no successor was ever pinned — the orphaned registry row is never silently adopted" \
  || bad "X: a successor was wrongly pinned despite the suppressed receipt: $x_pinned"
[ "${x_spawn_count:-0}" = 1 ] && ok "X: R6 — exactly ONE real spawn attempt across this call's own retry loop (30398f8 spawned 3)" \
  || bad "X: R6 spawn count within one call (got $x_spawn_count, want 1)"
[ "$x_state" = blocked ] && ok "X: R6 — the task is explicitly marked blocked/held, not silently left running with an unverifiable writer" \
  || bad "X: R6 task state (got [$x_state], want blocked)"

# =============================================================== case Y ===
# R6 (root-audit reject of R5/30398f8): a lost receipt on a spawn that
# ACTUALLY SUCCEEDED is UNCERTAIN, not a plain retryable failure — the
# fake spawn hook below writes a genuinely new, distinct task row on
# every call (exactly case X's own setup) but never emits a receipt.
# Independently reproduced by the reviewer: 6 real, untracked, running
# successor rows for one task across just 2 esc_escalate calls, with the
# old writer's pane already closed before any of them could ever be
# confirmed. This case proves the fix caps it at exactly ONE real spawn
# across THREE dimensions in a single run:
#   - retry-within-call: the first triggering tick's own esc_escalate
#     call retries up to the configured bound internally.
#   - a later, separate tick: no_progress_detect's window stays "loop"
#     on every following tick (commit_sha/artifact_fp unchanged), so
#     ticks 4-6 each independently re-enter esc_escalate — nothing in
#     no-progress-escalate.sh's cmd_tick gates on the task's state
#     before calling it, and esc_already_escalated only ever gates on a
#     real model_escalated event, which never lands here.
#   - a simulated restart: every `bash "$CLI" tick ...` invocation in
#     this harness IS already an independent process — a fresh bash
#     interpreter with zero shared in-process memory with any prior
#     tick, only the SQLite registry persisting between them — so ticks
#     4-6 exercise "survives a restart" exactly as rigorously as this
#     architecture allows, not merely "survives a retry".
RUN=taskY; TASK=taskY; PANE=pane-Y; BRANCH=esc-test-y
seed_task "$TASK" "$PANE" "$BRANCH"
: >"$ORDER_LOG"
: > "$WORK/spawn-suppress-receipt"
for i in 1 2 3; do                       # ticks 1-2 fill the window; tick 3 triggers escalate (retry-within-call)
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpY --context-dir "$CTX" >/dev/null
done
for i in 1 2 3; do                       # 3 MORE, fully separate processes: later ticks + simulated restart
  bash "$CLI" tick "$RUN" "$TASK" --commit-sha unused --artifact-fp fpY --context-dir "$CTX" >/dev/null
done
rm -f "$WORK/spawn-suppress-receipt"
y_rows="$(_sql "SELECT COUNT(*) FROM tasks WHERE branch=$(_sq "$BRANCH") AND label=$(_sq "implement:$BRANCH");" 2>/dev/null)"
y_spawn_count="$(grep -c -- 'spawn implement esc-test-y' "$ORDER_LOG" 2>/dev/null)"
y_close_count="$(grep -c -- 'close pane-Y' "$ORDER_LOG" 2>/dev/null)"
y_esc_n="$(event_count "$RUN" "$TASK" model_escalated)"
y_failed_n="$(event_count "$RUN" "$TASK" model_escalation_hook_failed)"
y_state="$(_sql "SELECT state FROM tasks WHERE task_id=$(_sq "$TASK");" 2>/dev/null)"
[ "${y_spawn_count:-0}" = 1 ] && ok "Y: R6 — exactly ONE real spawn attempt across retry-within-call + later ticks + simulated restart" \
  || bad "Y: R6 spawn count (got $y_spawn_count, want 1 — this is the exact bug 30398f8 was rejected for)"
[ "${y_rows:-0}" = 1 ] && ok "Y: R6 — exactly one successor row exists in the registry, not an unbounded pile of orphans" \
  || bad "Y: R6 successor row count (got $y_rows, want 1)"
[ "${y_close_count:-0}" = 1 ] && ok "Y: R6 — the old writer was closed exactly once, never re-triggered by a later tick" \
  || bad "Y: R6 close count (got $y_close_count, want 1)"
[ "${y_esc_n:-0}" = 0 ] && ok "Y: R6 — never actually escalates on an uncertain receipt (the audit trail stays honest)" \
  || bad "Y: R6 model_escalated should be 0 (got $y_esc_n)"
[ "${y_failed_n:-0}" = 4 ] && ok "Y: R6 — all 4 independent re-entries (1 retry-within-call + 3 later ticks) each record their own hook-failed audit event" \
  || bad "Y: R6 model_escalation_hook_failed count (got $y_failed_n, want 4)"
[ "$y_state" = blocked ] && ok "Y: R6 — the original task is explicitly marked blocked/held, not silently left running with zero known owners" \
  || bad "Y: R6 task state (got [$y_state], want blocked)"

# =============================================================== case R ===
[ ! -f "$WORK/herdr-violation" ] && ok "R: no code path ever called the real herdr binary across the whole suite (PATH-shadow proof)" \
  || bad "R: real herdr was invoked: $(cat "$WORK/herdr-violation" 2>/dev/null)"
printf '%s passed, %s failed\n' "$pass" "$fail"
# WORK lives under tmp/ (gitignored) — left in place rather than recursively
# removed; rerunning resets the registry/order-log/pane state it depends on.
[ "$fail" -eq 0 ]
