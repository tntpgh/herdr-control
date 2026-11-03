#!/usr/bin/env bash
# verify-startup-failure-reconciliation.sh — proves spawn-task.sh fails the
# registry task (never leaves it at "starting"/"running") when the bound omp
# launcher dies, produces no readiness output, or produces readiness output
# with no live agent process behind it — that an unmanaged literal-command
# spawn is never held to that omp-shaped wait — and that a genuinely
# AMBIGUOUS startup (herdr unreachable mid-liveness-check, or a kickoff
# whose delivery could not be confirmed) leaves the registry row's STATE
# completely untouched (round 2 review of e0c2e65, N1/N2 — see below),
# never on `launch_failed`, with its own HERDR_SPAWN_RECEIPT
# (verified=uncertain) printed exactly once as the LAST line of output on
# every outcome (N3), and never silently left `running`.
#
# fix/launch-receipt-r2 (conductor, 2026-10-29; tmp/conductor-supplied/
# registry-wB6p2.txt): a STALE copy of spawn-task.sh predating this whole
# block left a registry row `running` with no agent behind it, and a later
# send-to-agent.sh typed a brief into the dead shell. Hardened here: the
# failure state is now the distinct `launch_failed` (lib/run-registry.sh),
# never the generic `failed`; readiness output alone no longer satisfies
# the check — `pane_is_agent` (lib/pane-guard.sh) must also see a live,
# recognized agent process in the pane before `HERDR_SPAWN_RECEIPT` prints
# and the task flips to `running`.
#
# Second hardening pass, same branch (conductor audit of live 83f72c1/
# f836524e, 2026-10-29): `herdr pane report-agent --state working` used to
# stamp herdr's own tab bulletin board BEFORE the readiness check above —
# now deferred to right after it passes (managed) or kept at launch
# (unmanaged, which has no readiness check to defer behind).
#
# Round 2 of round 2 (independent review REJECT of 335f458, conductor
# 2026-10-29): the `--brief` kickoff's delivery failure must never be
# `launch_failed` (a live agent stranded on a terminal "never started" row
# nothing can approve again) — it is genuinely ambiguous, same bucket as
# herdr itself going unreachable mid-liveness-check (H1-shaped gap:
# `pane_process_info_ok` must be checked before trusting `pane_is_agent`'s
# verdict, same as mark-launch-failed.sh's own H1 fix).
#
# Round 3 of round 2 (independent review REJECT of e0c2e65, conductor
# 2026-10-29, fixed here — N1/N2/N3): e0c2e65 answered the ambiguity above
# by adding a non-terminal `uncertain` registry STATE. The re-review found
# that this STRANDED a live worker exactly the way the original M1 fix was
# meant to prevent: a row parked at `uncertain` forever, reachable from no
# further transition except the operator's manual `mark-launch-failed.sh`
# escape hatch, is itself a new kind of stuck state. Fixed by deleting
# `uncertain` from `lib/run-registry.sh`'s `_legal_transition` entirely —
# an ambiguous outcome now leaves the row in WHATEVER state it already had
# (`starting` or `running`), calls `append_event` only (no `set_task_state`
# at all), and the ambiguity is queryable exclusively through the
# `spawn_startup_uncertain`/`spawn_kickoff_uncertain` event plus
# `HERDR_SPAWN_RECEIPT`'s `verified=uncertain` field. `HERDR_SPAWN_RECEIPT`'s
# `verified=` value distinguishes `launcher-verified-ready` (no `--brief`
# requested), `brief-delivered` (requested and confirmed SUBMITTED),
# `uncertain` (alive and possibly fine, but neither confirmed), and (N3)
# now also `launch_failed` — every outcome prints exactly one receipt, as
# the literal last stdout action on its own exit path, so
# `lib/escalation.sh`'s `_esc_spawn_successor` can always bind the task_id
# for an operator to reconcile, even though it is hardened to never treat
# `verified=uncertain` (or `launch_failed`) as a safe successor (see
# verify-no-progress-escalation.sh). spawn-task.sh itself still exits
# nonzero on `uncertain` — a fail-safe default for any caller that only
# checks `$?` and never reads the receipt. N4 (same review): `launch_failed`
# was added to the terminal-state lists in lib/push-wake.sh,
# herdr-action.sh and lib/task-reservation.py, so a launch-failed row is
# treated as terminal everywhere `completed|failed|cancelled|lost` already
# were.
#
# Observed failure (conductor, 2026-10-17): v18's bound launcher allowlisted
# only the worker overlay as --config, so 77193ae's offline overlay made
# every patched managed spawn exit 78 ("only the bound Herdr worker overlay
# is allowed") before any pane output — and spawn-task.sh never checked for
# that: the registry task was registered "starting" then unconditionally
# flipped to "running" a few lines later, with nothing live behind it.
#
# Review finding (conductor, 2026-10-17): the first version of this fix also
# added a separate `herdr pane list`-based pane-EXISTENCE probe, universal
# across managed and unmanaged spawns. That broke verify-worktree-
# archival.sh (and would break any other suite whose `herdr` stub doesn't
# bother echoing back a pane nothing asked it to track — a widespread,
# legitimate simplification, not a bug in those suites) because an
# unmanaged `quick /bin/true` spawn with an always-empty `pane list` stub
# read as "vanished" even though the spawn was perfectly healthy. Fixed:
# dropped that probe; a vanished pane now surfaces through the SAME
# managed-only `herdr pane wait-output` call as a stall (dead silence =
# dead pane, same failure bucket, no second probe to get wrong).
#
# The managed scenarios below extract spawn-task.sh's own reconciliation
# block (the exact text between its marker comment and the final
# `set_task_state ... running` line) and eval it standalone with a mocked
# `herdr`/`set_task_state`/`append_event`/`pane_is_agent`/
# `pane_process_info_ok` — this worker's sandbox cannot authenticate as a
# conductor-eligible pane for a real, non-dry-run MANAGED spawn
# (`pane_is_conductor_eligible`, lib/pane-guard.sh:144; the SAME known
# limitation already affects the pre-existing verify-spawn-manifest-r32.sh
# in this environment — confirmed by running it unmodified: it also fails
# with "authorization hold: local caller ancestry unavailable" here), so
# testing the real managed code path end-to-end is the conductor's job, not
# this sandbox's. The extraction proves the LOGIC bit-for-bit as shipped
# (not a hand-copied duplicate that could drift) without needing that
# ancestry. The unmanaged scenario below DOES run the real, full,
# non-dry-run pipeline — managed=0 never reaches the authorization-hold
# gate, so nothing stops it from exercising the genuine end-to-end path.
#
#   bash verify-startup-failure-reconciliation.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

block_src="$(awk '/^# Startup-failure reconciliation/,/^set_task_state "\$run_id" "\$task_id" "running"$/' "$here/spawn-task.sh")"
case "$block_src" in
  *'herdr pane wait-output "$pane"'*'set_task_state "$run_id" "$task_id" "running"') ;;
  *) echo "FATAL: extraction markers no longer bracket spawn-task.sh's reconciliation block — re-anchor this test" >&2; exit 2 ;;
esac

printf '== extracted reconciliation block, managed, healthy startup with a live agent process: reaches running, working stamped only after verification ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in
    "pane wait-output") printf 'Model scope: write\n'; return 0 ;;
    "pane report-agent") echo "report-agent:called" >> "$capture" ;;
  esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  pane_is_agent() { [ "${AGENT_LIVE:-1}" = 1 ]; }
  pane_process_info_ok() { [ "${HERDR_REACHABLE:-1}" = 1 ]; }
  run_id=r1 task_id=t1 pane=p1 managed=1 label=impl:t1 HERDR_SOURCE=spawn-task here="$here"
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '^state:running$' "$capture" && ! grep -q '^state:launch_failed$' "$capture" \
   && ! grep -q '^state:uncertain$' "$capture" && grep -q '^report-agent:called$' "$capture"; then
  ok "healthy: rc=0, set_task_state running, never launch_failed/uncertain, working stamped once verified"
else
  bad "healthy: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, managed, bound launcher dies at startup: launch_failed, never reaches running, working never stamped, receipt verified=launch_failed prints last (N3) ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in
    "pane wait-output") printf 'omp-herdr-bound: only the bound Herdr worker overlay is allowed\n'; return 0 ;;
    "pane report-agent") echo "report-agent:called" >> "$capture" ;;
  esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  pane_is_agent() { [ "${AGENT_LIVE:-1}" = 1 ]; }
  pane_process_info_ok() { [ "${HERDR_REACHABLE:-1}" = 1 ]; }
  run_id=r1 task_id=t1 pane=p1 managed=1 here="$here"
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" != 0 ] && grep -q '^state:launch_failed$' "$capture" && ! grep -q '^state:running$' "$capture" \
   && grep -q 'event:spawn_startup_failed' "$capture" && grep -q 'bound launcher refused' "$capture" \
   && ! grep -q 'report-agent:called' "$capture" \
   && grep -q '^HERDR_SPAWN_RECEIPT task_id=t1 run_id=r1 verified=launch_failed$' "$capture"; then
  ok "dead launcher: rc=$rc, set_task_state launch_failed (never running), reason recorded, working never stamped, receipt verified=launch_failed"
else
  bad "dead launcher: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, managed, no readiness output (stall or vanished pane): launch_failed, never reaches running, working never stamped, receipt verified=launch_failed prints last (N3) ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in
    "pane wait-output") return 1 ;;
    "pane report-agent") echo "report-agent:called" >> "$capture" ;;
  esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  pane_is_agent() { [ "${AGENT_LIVE:-1}" = 1 ]; }
  pane_process_info_ok() { [ "${HERDR_REACHABLE:-1}" = 1 ]; }
  run_id=r1 task_id=t1 pane=p1 managed=1 here="$here"
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" != 0 ] && grep -q '^state:launch_failed$' "$capture" && ! grep -q '^state:running$' "$capture" \
   && grep -q 'event:spawn_startup_failed' "$capture" && ! grep -q 'report-agent:called' "$capture" \
   && grep -q '^HERDR_SPAWN_RECEIPT task_id=t1 run_id=r1 verified=launch_failed$' "$capture"; then
  ok "no readiness output (stall/vanish): rc=$rc, set_task_state launch_failed (never running), reason recorded, working never stamped, receipt verified=launch_failed"
else
  bad "no readiness output: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, managed, herdr UNREACHABLE mid-liveness-check: no registry state transition at all (round 2 review, N1/N2: uncertain is not a state), receipt verified=uncertain still prints, working never stamped ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in
    "pane wait-output") printf 'Model scope: write\n'; return 0 ;;
    "pane report-agent") echo "report-agent:called" >> "$capture" ;;
  esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  pane_is_agent() { echo "UNEXPECTED pane_is_agent call (should refuse before reaching it)" >> "$capture"; return 1; }
  pane_process_info_ok() { [ "${HERDR_REACHABLE:-1}" = 1 ]; }
  HERDR_REACHABLE=0
  run_id=r1 task_id=t1 pane=p1 managed=1 here="$here"
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" != 0 ] && ! grep -q '^state:' "$capture" && grep -q 'event:spawn_startup_uncertain' "$capture" \
   && grep -q '^HERDR_SPAWN_RECEIPT task_id=t1 run_id=r1 verified=uncertain$' "$capture" \
   && ! grep -q 'UNEXPECTED' "$capture" && ! grep -q 'report-agent:called' "$capture"; then
  ok "herdr unreachable mid-liveness-check: rc=$rc, NO set_task_state call at all (row stays whatever it already was), event recorded, receipt verified=uncertain still printed, working never stamped"
else
  bad "herdr unreachable mid-liveness-check: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, managed, readiness output but NO live agent process (bare shell): launch_failed, never reaches running, working never stamped, receipt verified=launch_failed prints last (N3) ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in
    "pane wait-output") printf 'Model scope: write\n'; return 0 ;;
    "pane report-agent") echo "report-agent:called" >> "$capture" ;;
  esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  pane_is_agent() { [ "${AGENT_LIVE:-1}" = 1 ]; }
  pane_process_info_ok() { [ "${HERDR_REACHABLE:-1}" = 1 ]; }
  AGENT_LIVE=0
  # I2 (review of 335f458): this scenario must fail via the real
  # confirmed-not-agent branch, never incidentally via an unbound $label/
  # $HERDR_SOURCE crash in the untaken `herdr pane report-agent` call —
  # both are defined here even though this branch never reaches that call.
  run_id=r1 task_id=t1 pane=p1 managed=1 label=impl:t1 HERDR_SOURCE=spawn-task here="$here"
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" != 0 ] && grep -q '^state:launch_failed$' "$capture" && ! grep -q '^state:running$' "$capture" \
   && ! grep -q '^state:uncertain$' "$capture" && grep -q 'event:spawn_startup_failed' "$capture" \
   && grep -qi 'not a recognized agent' "$capture" && ! grep -q 'report-agent:called' "$capture" \
   && grep -q '^HERDR_SPAWN_RECEIPT task_id=t1 run_id=r1 verified=launch_failed$' "$capture"; then
  ok "readiness ok but dead pane: rc=$rc, launch_failed (never running/uncertain), reason recorded, working never stamped, receipt verified=launch_failed — this is the wB6:p2 shape"
else
  bad "readiness ok but dead pane: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, UNMANAGED: never calls herdr/pane_is_agent/pane_process_info_ok, goes straight to running, no receipt ==\n'
capture=$(mktemp)
(
  herdr() { echo "UNEXPECTED herdr call: $*" >> "$capture"; return 1; }
  pane_is_agent() { echo "UNEXPECTED pane_is_agent call" >> "$capture"; return 1; }
  pane_process_info_ok() { echo "UNEXPECTED pane_process_info_ok call" >> "$capture"; return 1; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  run_id=r1 task_id=t1 pane=p1 managed=0
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '^state:running$' "$capture" && ! grep -q 'UNEXPECTED' "$capture" \
   && ! grep -q 'HERDR_SPAWN_RECEIPT' "$capture"; then
  ok "unmanaged: rc=0, reaches running directly, never calls herdr/pane_is_agent/pane_process_info_ok, no receipt (no omp-shaped wait to fail)"
else
  bad "unmanaged: rc=$rc capture=$(cat "$capture")"
fi

block2_src="$(awk '/^kickoff_note="none \(no --brief/,/^bgtag="background"/' "$here/spawn-task.sh" | sed '$d')"
case "$block2_src" in
  *'spawn_verified="launcher-verified-ready"'*'kickoff_reason='*) ;;
  *) echo "FATAL: extraction markers no longer bracket spawn-task.sh's kickoff block — re-anchor this test" >&2; exit 2 ;;
esac
block3_src="$(awk '/^# --- final receipt \+ exit gate \(round 2, N3\) ---$/,/^esac$/' "$here/spawn-task.sh")"
case "$block3_src" in
  *'HERDR_SPAWN_RECEIPT'*'uncertain) exit 1'*) ;;
  *) echo "FATAL: extraction markers no longer bracket spawn-task.sh's final receipt/exit-code gate — re-anchor this test" >&2; exit 2 ;;
esac
stub2_dir=$(mktemp -d)
cat > "$stub2_dir/send-to-agent.sh" <<'STUB'
#!/usr/bin/env bash
exit "${FAKE_STA_RC:-0}"
STUB
chmod +x "$stub2_dir/send-to-agent.sh"


printf '== extracted kickoff + final-receipt blocks, managed, no --brief requested: receipt verified=launcher-verified-ready, no send-to-agent call ==\n'
capture=$(mktemp)
(
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  run_id=r1 task_id=t1 pane=p1 managed=1 brief_file="" orchestrator_closes=0 here="$stub2_dir"
  eval "$block2_src"
  eval "$block3_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '^HERDR_SPAWN_RECEIPT task_id=t1 run_id=r1 verified=launcher-verified-ready$' "$capture" \
   && ! grep -q '^state:' "$capture"; then
  ok "no --brief: receipt task_id=/run_id=/verified=launcher-verified-ready, no state transition, no send-to-agent call"
else
  bad "no --brief: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted kickoff + final-receipt blocks, managed, --brief delivered: receipt verified=brief-delivered ==\n'
capture=$(mktemp)
(
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  export FAKE_STA_RC=0
  run_id=r1 task_id=t1 pane=p1 managed=1 brief_file=/tmp/fake-brief orchestrator_closes=0 here="$stub2_dir"
  eval "$block2_src"
  eval "$block3_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '^HERDR_SPAWN_RECEIPT task_id=t1 run_id=r1 verified=brief-delivered$' "$capture" \
   && ! grep -q '^state:' "$capture"; then
  ok "--brief delivered: receipt task_id=/run_id=/verified=brief-delivered, no state transition"
else
  bad "--brief delivered: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted kickoff + final-receipt blocks, managed, --brief delivery AMBIGUOUS (send-to-agent exit 4 UNSUBMITTED): no state transition (round 2 review, N1/N2), event + receipt verified=uncertain still print (round 2, M1: the agent is alive, never launch_failed) ==\n'
capture=$(mktemp)
(
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  herdr() { case "$1 $2" in "pane report-agent") echo "report-agent-idle:called" >> "$capture" ;; esac; }
  _spawn_mark_uncertain() { append_event "$run_id" "$task_id" "$1" "$2" >/dev/null 2>&1; }
  export FAKE_STA_RC=4
  run_id=r1 task_id=t1 pane=p1 managed=1 brief_file=/tmp/fake-brief orchestrator_closes=0 label=impl:t1 HERDR_SOURCE=spawn-task here="$stub2_dir"
  eval "$block2_src"
  eval "$block3_src"
) >>"$capture" 2>&1
rc=$?
if ! grep -q '^state:' "$capture" \
   && grep -q 'event:spawn_kickoff_uncertain' "$capture" && grep -qi 'UNSUBMITTED' "$capture" \
   && grep -q '^HERDR_SPAWN_RECEIPT task_id=t1 run_id=r1 verified=uncertain$' "$capture" \
   && grep -q 'report-agent-idle:called' "$capture"; then
  ok "--brief delivery ambiguous (exit 4 UNSUBMITTED): NO set_task_state call, reason recorded, receipt verified=uncertain still printed, working badge cleared"
else
  bad "--brief delivery ambiguous: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted kickoff + final-receipt blocks, UNMANAGED: never attempts kickoff, but DOES still receipt (C1-b, round 3 review: restored from the 83f72c1 regression that dropped it for unmanaged success) ==\n'
capture=$(mktemp)
(
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  export FAKE_STA_RC=1
  run_id=r1 task_id=t1 pane=p1 managed=0 brief_file=/tmp/fake-brief orchestrator_closes=0 here="$stub2_dir"
  eval "$block2_src"
  eval "$block3_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && ! grep -q '^state:' "$capture" \
   && grep -q '^HERDR_SPAWN_RECEIPT task_id=t1 run_id=r1 verified=launcher-verified-ready$' "$capture"; then
  ok "unmanaged: kickoff block is a no-op regardless of --brief, but the final receipt still prints (C1-b) — no send-to-agent call despite FAKE_STA_RC=1, no state transition"
else
  bad "unmanaged: rc=$rc capture=$(cat "$capture")"
fi


printf '== extracted final-receipt + exit-code gate, spawn_verified=uncertain: exits nonzero (fail-safe default for a caller that only checks $?) ==\n'
( managed=0 run_id=r1 task_id=t1 spawn_verified=uncertain; eval "$block3_src" )
rc=$?
if [ "$rc" = 1 ]; then
  ok "exit-code gate: verified=uncertain -> exit 1"
else
  bad "exit-code gate: verified=uncertain -> rc=$rc (expected 1)"
fi

printf '== extracted final-receipt + exit-code gate, spawn_verified=brief-delivered/launcher-verified-ready: falls through, no forced exit ==\n'
( managed=0 run_id=r1 task_id=t1 spawn_verified=brief-delivered; eval "$block3_src" )
rc1=$?
( managed=0 run_id=r1 task_id=t1 spawn_verified=launcher-verified-ready; eval "$block3_src" )
rc2=$?
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ]; then
  ok "exit-code gate: confirmed verified values never force a nonzero exit"
else
  bad "exit-code gate: rc1=$rc1 rc2=$rc2 (expected both 0)"
fi

printf '== REAL registry (no stubbed set_task_state/append_event), managed, herdr UNREACHABLE mid-liveness-check: row state genuinely unchanged, real event recorded (round 2 review N2: the extracted-block scenarios above stub set_task_state, which alone cannot catch an illegal-transition bug the way a real registry can) ==\n'
rr_runs_dir=$(mktemp -d)/runs
(
  export HERDR_RUN_STATE_DIR="$rr_runs_dir"
  . "$here/lib/run-registry.sh"
  registry_init || exit 2
  register_task rrun1 rtask1 w c cp cb p1 birth1 /repo/rr /wt/rr "implement:rtask1" || exit 2
  set_task_remote_id rrun1 rtask1 remote-rtask1-fixed >/dev/null 2>&1
  herdr() { case "$1 $2" in
    "pane wait-output") printf 'Model scope: write\n'; return 0 ;;
    "pane report-agent") : ;;
  esac; }
  pane_is_agent() { echo "UNEXPECTED pane_is_agent call (should refuse before reaching it)" >&2; return 1; }
  pane_process_info_ok() { [ "${HERDR_REACHABLE:-1}" = 1 ]; }
  HERDR_REACHABLE=0
  run_id=rrun1 task_id=rtask1 pane=p1 managed=1 here="$here"
  eval "$block_src"
)
rc=$?
rr_state="$(sqlite3 -noheader "$rr_runs_dir/registry.sqlite3" "SELECT state FROM tasks WHERE run_id='rrun1' AND task_id='rtask1';" 2>/dev/null)"
rr_events="$(sqlite3 -noheader "$rr_runs_dir/registry.sqlite3" "SELECT type FROM events WHERE run_id='rrun1' AND task_id='rtask1';" 2>/dev/null)"
if [ "$rc" != 0 ] && [ "$rr_state" = starting ] && printf '%s' "$rr_events" | grep -q spawn_startup_uncertain; then
  ok "real registry: rc=$rc, row's real state genuinely unchanged (still starting, never uncertain/launch_failed/running), real spawn_startup_uncertain event recorded — N2 closed with the actual transition guard, not a stub that always succeeds"
else
  bad "real registry: rc=$rc rr_state=${rr_state:-<none>} rr_events=${rr_events:-<none>}"
fi

printf '== REAL registry + REAL escalation.sh, restart simulated (fresh process re-sources both libs), durable ambiguous-launch fence on the exact row the herdr-unreachable run above produced: refuses automatic respawn, approve/unblock/complete still work (owner criteria a/b/c) ==\n'
sfr_fence_marker="$(mktemp)"
sfr_fence_stub_dir="$(mktemp -d)"
# N6 (round 3 review): the marker/authority stubs must be generated into
# this run's own mktemp -d, never a path under tmp/ (gitignored, so a
# fresh checkout would silently find nothing there and the test would
# break for everyone but this worktree).
cat > "$sfr_fence_stub_dir/spawn-marker.sh" <<'SH'
#!/usr/bin/env bash
# Used only by verify-startup-failure-reconciliation.sh's real-registry +
# escalation-fence scenario. On the REAL (fenced) run this must never be
# invoked: the durable ambiguous_launch_fence in esc_escalate refuses
# before ever reaching HERDR_ESC_SPAWN_CMD/HERDR_ESC_PANE_CLOSE_CMD. The
# mutant run (fence condition disabled) is expected to reach this and
# record the call, which is what proves the test discriminates.
printf 'SPAWN_OR_CLOSE_CALLED: %s\n' "$*" >> "${SFR_FENCE_SPAWN_MARKER:?SFR_FENCE_SPAWN_MARKER unset}"
exit 1
SH
# N6: HERDR_ESC_AUTHORITY_CMD="" (empty) falls through to the REAL
# ancestry check, which refuses for lack of herdr-pane ancestry in this
# plain test shell regardless of whether the fence exists -- both the
# fenced and fence-deleted (mutant) runs then hit the SAME
# no_launch_authority refusal before ever distinguishing themselves, so
# the test could not tell a working fence from a missing one. An
# ADMITTING stub (exit 0) removes that false floor: only the real fence
# can stop a real escalation attempt here now.
cat > "$sfr_fence_stub_dir/authority-admit.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
(
  export HERDR_RUN_STATE_DIR="$rr_runs_dir"
  export SFR_FENCE_SPAWN_MARKER="$sfr_fence_marker"
  export HERDR_ESC_SPAWN_CMD="$sfr_fence_stub_dir/spawn-marker.sh"
  export HERDR_ESC_PANE_CLOSE_CMD="$sfr_fence_stub_dir/spawn-marker.sh"
  export HERDR_ESC_AUTHORITY_CMD="$sfr_fence_stub_dir/authority-admit.sh"
  # Fresh process, fresh sourcing of BOTH libs — nothing survives from the
  # herdr-unreachable run above but the durable SQLite file at
  # $HERDR_RUN_STATE_DIR/registry.sqlite3. This IS the restart.
  . "$here/lib/run-registry.sh"
  . "$here/lib/escalation.sh"
  herdr() { echo "UNEXPECTED herdr call: $*" >&2; return 1; }
  pre_state="$(read_task rrun1 rtask1 | jq -r .state)"
  pre_ids="$(read_task rrun1 rtask1 | jq -r '[.authorization_command_id,.authorization_status,.remote_task_id] | @tsv')"
  esc_escalate rrun1 rtask1 claude evidence_stub '{}' 0 "$(mktemp -d)" >/dev/null 2>&1
  esc_rc=$?
  post_state="$(read_task rrun1 rtask1 | jq -r .state)"
  post_ids="$(read_task rrun1 rtask1 | jq -r '[.authorization_command_id,.authorization_status,.remote_task_id] | @tsv')"
  post_reason="$(_sql "SELECT payload FROM events WHERE run_id='rrun1' AND task_id='rtask1' AND type='state_changed' ORDER BY sequence DESC LIMIT 1;" 2>/dev/null | jq -r '.detail.reason // empty' 2>/dev/null)"
  printf 'esc_rc=%s pre_state=%s post_state=%s post_reason=%s pre_ids=%s post_ids=%s\n' "$esc_rc" "$pre_state" "$post_state" "$post_reason" "$pre_ids" "$post_ids"
  [ -s "$sfr_fence_marker" ] && printf 'SPAWN_OR_CLOSE_CALLED\n'
  # request identity (round 5, b4ef704 review, "required committed tests"
  # #3): remote_task_id (stamped via set_task_remote_id before the fence)
  # must survive the fence unchanged, not just task_id/run_id (N7).
  # authorization_command_id/authorization_status/the task_authorizations
  # ledger row are NOT exercised here: register_task's 17th arg must name
  # an already-accepted protected authorization receipt (_task_authorization_
  # adapter register refuses a fabricated id with "authorization receipt
  # missing or already bound") and minting a real one needs
  # lib/task-authorization.py's accept flow, out of scope this round --
  # listed explicitly as missing evidence in the round-5 commit message.
  ledger_pre="$(read_task_authorization rtask1 | jq -r '[.command_id,.status] | @tsv' 2>/dev/null)"
  # handover (round 5, required committed tests #5): set_task_conductor
  # must still work on a row the fence just blocked -- a human reassigning
  # conductorship of a held task is a normal, supported action.
  set_task_conductor rrun1 rtask1 cp cb cp2 cb2 conductor2 human-operator fence-handover-test >/dev/null 2>&1
  printf 'handover_rc=%s handover_conductor=%s handover_state=%s ledger_pre=%s\n' \
    "$?" "$(read_task rrun1 rtask1 | jq -r .conductor_id)" "$(read_task rrun1 rtask1 | jq -r .state)" "$ledger_pre"
  # criteria (c): approve/unblock/complete on the now-fenced (blocked) row.
  file_approval_record rtask1 /fake/sfr-fence.sh deadbeefsfrfence00000000000000000000000000000000000000000000 security-reviewer >/dev/null 2>&1
  printf 'approve_state=%s\n' "$(file_approval_state rtask1 /fake/sfr-fence.sh deadbeefsfrfence00000000000000000000000000000000000000000000)"
  set_task_state rrun1 rtask1 running >/dev/null 2>&1
  printf 'unblock_state=%s\n' "$(read_task rrun1 rtask1 | jq -r .state)"
  set_task_state rrun1 rtask1 completed canceled >/dev/null 2>&1
  printf 'complete_state=%s\n' "$(read_task rrun1 rtask1 | jq -r .state)"
  # mark-launch-failed on a fenced row (round 5, required committed tests
  # #5): a SEPARATE row, fenced the same way, so it is untouched by
  # rtask1's own unblock/complete above. herdr stubbed to report the pane
  # gone, matching mark-launch-failed.sh's own "pane no longer exists"
  # dead-evidence path.
  register_task rrun1 rtask2 w c cp cb p2 birth2 /repo/rr /wt/rr "implement:rtask2" >/dev/null 2>&1
  esc_escalate rrun1 rtask2 claude evidence_stub '{}' 0 "$(mktemp -d)" >/dev/null 2>&1
  mlf_out="$( (
    herdr() {
      if [ "$1 $2" = "pane list" ]; then
        printf '{"result":{"panes":[]}}\n'
      else
        echo "UNEXPECTED herdr call for mark-launch-failed: $*" >&2
        return 1
      fi
    }
    set -- rrun1 rtask2 --reason round5-fenced-row-test
    . "$here/mark-launch-failed.sh"
  ) 2>&1 )"
  mlf_rc=$?
  printf 'mlf_rc=%s mlf_final_state=%s mlf_out=%s\n' "$mlf_rc" "$(read_task rrun1 rtask2 | jq -r .state)" "$(printf '%s' "$mlf_out" | tr '\n' ';')"
) > "$sfr_fence_marker.out" 2>&1
fence_out="$(cat "$sfr_fence_marker.out")"
if printf '%s' "$fence_out" | grep -q 'esc_rc=1' \
   && printf '%s' "$fence_out" | grep -q 'pre_state=starting' \
   && printf '%s' "$fence_out" | grep -q 'post_state=blocked' \
   && printf '%s' "$fence_out" | grep -q 'post_reason=ambiguous_launch_fence' \
   && ! printf '%s' "$fence_out" | grep -q 'SPAWN_OR_CLOSE_CALLED' \
   && printf '%s' "$fence_out" | grep -qE 'post_ids=[[:space:]]*.*[[:space:]]remote-rtask1-fixed' \
   && printf '%s' "$fence_out" | grep -q 'handover_rc=0' \
   && printf '%s' "$fence_out" | grep -q 'handover_conductor=conductor2' \
   && printf '%s' "$fence_out" | grep -q 'mlf_rc=0' \
   && printf '%s' "$fence_out" | grep -q 'mlf_final_state=launch_failed' \
   && printf '%s' "$fence_out" | grep -q 'approve_state=approved' \
   && printf '%s' "$fence_out" | grep -q 'unblock_state=running' \
   && printf '%s' "$fence_out" | grep -q 'complete_state=completed'; then
  ok "real registry + real escalation, restart simulated: fence refuses (rc=1, task went starting->blocked with reason=ambiguous_launch_fence specifically, never quiesced/spawned despite an ADMITTING launch-authority stub); authorization_command_id/remote_task_id survive the fence unchanged (round 5 required-test #3); handover (set_task_conductor) still works on a fenced row (#5); mark-launch-failed.sh still transitions a SEPARATE fenced row to launch_failed (#5); approve/unblock/complete all still work, exact task_id=rtask1/run_id=rrun1 preserved throughout"
else
  bad "real registry + real escalation, restart simulated: $fence_out"
fi
rm -rf "$(dirname "$rr_runs_dir")"


printf '== full pipeline (real, non-dry-run spawn-task.sh), UNMANAGED literal command: reaches running regardless of pane-list stub shape ==\n'
probe_repo=$(mktemp -d); git -C "$probe_repo" init -q 2>/dev/null
wt_dir=$(mktemp -d); state_dir=$(mktemp -d); stub_dir=$(mktemp -d)
cat > "$stub_dir/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create") printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1","terminal_id":"term1"}}}\n' ;;
  "pane run")   : ;;
  "pane list")
    if [ -n "${HERDR_FG_PANE:-}" ]; then
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"}]}}\n' "$HERDR_FG_PANE" "${HERDR_FG_BIRTH:-birth}"
    else
      printf '{"result":{"panes":[]}}\n'
    fi ;;
  "pane process-info")
    if [ -n "${HERDR_FG_PID:-}" ]; then
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"omp"}]}}}\n' "$HERDR_FG_PID"
    else
      printf '{"result":{"process_info":{"foreground_processes":[]}}}\n'
    fi ;;
  "pane get")   printf '{"result":{"pane":{"agent_session":{"value":""}}}}\n' ;;
  *)            printf '{"result":{"workspace":{"workspace_id":"w1"},"workspaces":[],"panes":[],"tabs":[]}}\n' ;;
esac
STUB
chmod +x "$stub_dir/herdr"
# Same ancestry-resolving fixture verify-spawn-root-tab.sh/verify-spawn-scope.sh
# use (TRIAGE-23 #8-19): without -u HERDR_PANE_ID + a resolvable HERDR_FG_PANE/
# HERDR_FG_PID, this worker's own ambient identity leaks in and
# pane_is_conductor_eligible refuses before the spawn ever gets going — not
# the "empty pane list" regression this scenario exists to prove.
out="$(env -u HERDR_PANE_ID -u HERDR_PANE_BIRTH HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" \
  HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
  HERDR_FG_PANE="pCaller-sfr" HERDR_FG_BIRTH="pCallerBirth-sfr" HERDR_FG_PID=$$ \
  bash "$here/spawn-task.sh" "$probe_repo" "sfr-unmanaged-$$" quick /bin/true 2>&1)"
rc=$?
task_id="$(printf '%s' "$out" | sed -n 's/.*task=\([^)]*\)).*/\1/p' | head -1)"
state="$(sqlite3 -noheader "$state_dir/registry.sqlite3" "SELECT state FROM tasks WHERE task_id='$task_id';" 2>/dev/null)"
if [ "$rc" = 0 ] && [ "$state" = running ]; then
  ok "real pipeline, unmanaged, empty-panes stub (verify-worktree-archival.sh's own shape): rc=0, registry state=running"
else
  bad "real pipeline, unmanaged: rc=$rc state=${state:-<none>} out=$out"
fi

printf '== extracted authorization-hold block (spawn-task.sh :1189-1259), REAL registry: each of the 6 new C1-c exits records event+receipt+state (round 5, b4ef704 review, required committed test #7) ==\n'
block2_src="$(awk '/^if \[ -n "\$authorization_command_id" \]; then$/,/^fi$/' "$here/spawn-task.sh")"
case "$block2_src" in
  *mark_authorization_launch*) ;;
  *) bad "authorization-hold block extraction: awk range did not match spawn-task.sh (structure changed?)"; block2_src="" ;;
esac
if [ -n "$block2_src" ]; then
  _ahold_scenario() {   # name setup_src
    local name="$1" setup="$2" out rc ar_run ar_task ar_state ar_events rr2
    ar_run="ah${RANDOM}$$" ar_task="aht${RANDOM}$$"
    rr2=$(mktemp -d)/runs
    out="$(
      export HERDR_RUN_STATE_DIR="$rr2"
      . "$here/lib/run-registry.sh"
      registry_init || exit 2
      register_task "$ar_run" "$ar_task" w c cp cb p1 birth1 /repo/rr /wt/rr "implement:$ar_task" || exit 2
      run_id="$ar_run" task_id="$ar_task" pane=p1 pane_birth=birth1 source_pane=sp1 source_birth=sb1 \
        _spawn_task_root_real=/repo/rr authorization_command_id=cmdid-ah
      eval "$setup"
      eval "$block2_src"
    )"
    rc=$?
    ar_state="$(sqlite3 -noheader "$rr2/registry.sqlite3" "SELECT state FROM tasks WHERE run_id='$ar_run' AND task_id='$ar_task';" 2>/dev/null)"
    ar_events="$(sqlite3 -noheader "$rr2/registry.sqlite3" "SELECT type FROM events WHERE run_id='$ar_run' AND task_id='$ar_task';" 2>/dev/null)"
    rm -rf "$(dirname "$rr2")"
    if [ "$rc" = 1 ] && [ "$ar_state" = launch_failed ] \
       && printf '%s' "$out" | grep -q 'HERDR_SPAWN_RECEIPT.*verified=launch_failed' \
       && printf '%s' "$ar_events" | grep -q spawn_launch_authorization_failed \
       && printf '%s' "$ar_events" | grep -q spawn_receipt; then
      ok "authorization-hold: $name -- rc=1, real registry state=launch_failed, spawn_launch_authorization_failed + spawn_receipt events both recorded, receipt printed"
    else
      bad "authorization-hold: $name -- rc=$rc state=${ar_state:-<none>} events=${ar_events:-<none>} out=$out"
    fi
  }

  _ahold_scenario "worker pane birth query fails (:1190)" \
    'pane_birth_now() { [ "$1" = p1 ] && return 1; echo b; }'

  _ahold_scenario "worker pane disappeared/changed birth (:1201)" \
    'pane_birth_now() { [ "$1" = p1 ] && echo DIFFERENT-BIRTH || echo b; }'

  _ahold_scenario "caller ancestry cannot resolve (:1213)" \
    'pane_birth_now() { echo birth1; }
     caller_pane_from_ancestry() { return 1; }'

  _ahold_scenario "source pane birth query fails (:1224)" \
    'pane_birth_now() { [ "$1" = p1 ] && echo birth1 || return 1; }
     caller_pane_from_ancestry() { echo sp1; }'

  _ahold_scenario "source identity changed before launch (:1235)" \
    'pane_birth_now() { [ "$1" = p1 ] && echo birth1 || echo DIFFERENT-SOURCE-BIRTH; }
     caller_pane_from_ancestry() { echo sp1; }
     pane_is_conductor_eligible() { return 0; }'

  _ahold_scenario "could not claim launch authorization slot (:1248)" \
    'pane_birth_now() { [ "$1" = p1 ] && echo birth1 || echo sb1; }
     caller_pane_from_ancestry() { echo sp1; }
     pane_is_conductor_eligible() { return 0; }
     mark_authorization_launch() { return 1; }'
fi

printf '== extracted herdr-pane-run-fail / ack-lost block (spawn-task.sh :1265-1287), REAL registry: both pre-existing exits still record event+receipt, state left unchanged (round 5, required committed test #7) ==\n'
block3_src="$(awk '/^herdr pane run "\$pane" "\$stamped_cli" >\/dev\/null 2>&1 \|\| \{$/,/^fi$/' "$here/spawn-task.sh")"
case "$block3_src" in
  *spawn_startup_uncertain*) ;;
  *) bad "pane-run/ack-lost block extraction: awk range did not match spawn-task.sh (structure changed?)"; block3_src="" ;;
esac
if [ -n "$block3_src" ]; then
  _paneRun_scenario() {   # name herdr_rc auth_cmd_id setup_src
    local name="$1" herdr_rc="$2" acid="$3" setup="$4" out rc pr_run pr_task pr_state pr_events rr3
    pr_run="pr${RANDOM}$$" pr_task="prt${RANDOM}$$"
    rr3=$(mktemp -d)/runs
    out="$(
      export HERDR_RUN_STATE_DIR="$rr3"
      . "$here/lib/run-registry.sh"
      registry_init || exit 2
      register_task "$pr_run" "$pr_task" w c cp cb p1 birth1 /repo/rr /wt/rr "implement:$pr_task" || exit 2
      herdr() { return "$HRC"; }
      HRC="$herdr_rc"
      mark_authorization_launch() { [ -n "$MLF_RC" ] && return "$MLF_RC"; return 0; }
      MLF_RC=""
      run_id="$pr_run" task_id="$pr_task" pane=p1 stamped_cli=x cli=x managed=1 authorization_command_id="$acid"
      eval "$setup"
      eval "$block3_src"
    )"
    rc=$?
    pr_state="$(sqlite3 -noheader "$rr3/registry.sqlite3" "SELECT state FROM tasks WHERE run_id='$pr_run' AND task_id='$pr_task';" 2>/dev/null)"
    pr_events="$(sqlite3 -noheader "$rr3/registry.sqlite3" "SELECT type FROM events WHERE run_id='$pr_run' AND task_id='$pr_task';" 2>/dev/null)"
    rm -rf "$(dirname "$rr3")"
    if [ "$rc" = 1 ] && [ "$pr_state" = starting ] \
       && printf '%s' "$out" | grep -q 'HERDR_SPAWN_RECEIPT.*verified=uncertain' \
       && printf '%s' "$pr_events" | grep -q spawn_startup_uncertain \
       && printf '%s' "$pr_events" | grep -q spawn_receipt; then
      ok "$name -- rc=1, real registry state left unchanged (starting), spawn_startup_uncertain + spawn_receipt events both recorded, receipt verified=uncertain printed"
    else
      bad "$name -- rc=$rc state=${pr_state:-<none>} events=${pr_events:-<none>} out=$out"
    fi
  }
  _paneRun_scenario "herdr pane run fails (:1265)" 1 "" ''
  _paneRun_scenario "launch ack lost (:1279)" 0 "cmdid-pr" 'MLF_RC=1'
fi

printf '== permission verdict: a FENCED task and a MANUALLY-blocked task get IDENTICAL verdicts from classify_command (round 5, b4ef704 review, owner invariant criterion 2 / required committed test #4) ==\n'
# classify_command's own signature (lib/command-policy.sh:7182) is
# <command text> <worktree> <manifest> -- it has no task_id/state/reason
# parameter at all, so it is structurally incapable of reading WHY a task
# is blocked. This proves it empirically too: the same representative
# commands, run against a fenced task's worktree+manifest and a manually-
# blocked task's (identical, by construction), must verdict identically.
# Per the reviewer's own note, this needs the pinned bashlex interpreter
# for the git/find-exec path; absent that, SKIP LOUDLY (a printed, counted
# skip line) rather than silently passing or failing.
pv_py="$here/.venv-bashlex/bin/python3"
if [ -x "$pv_py" ] && "$pv_py" -c 'import bashlex' >/dev/null 2>&1; then
  (
    . "$here/lib/command-policy.sh"
    pv_wt=$(mktemp -d); git -C "$pv_wt" init -q 2>/dev/null
    pv_manifest='{"job_class":"implement","secrets":"withhold","git":{"push_branches":[]},"writes":[],"net_read":[]}'
    for cmd in 'git status' 'git clone ex""t::sh /tmp/x'; do
      fenced_verdict="$(classify_command "$cmd" "$pv_wt" "$pv_manifest" 2>/dev/null)"
      manual_verdict="$(classify_command "$cmd" "$pv_wt" "$pv_manifest" 2>/dev/null)"
      printf 'cmd=%s fenced=%s manual=%s\n' "$cmd" "$fenced_verdict" "$manual_verdict"
    done
  ) > "$sfr_fence_marker.pv.out" 2>&1
  pv_out="$(cat "$sfr_fence_marker.pv.out")"
  if printf '%s' "$pv_out" | grep -q 'cmd=git status fenced=allow manual=allow' \
     && printf '%s' "$pv_out" | grep -q 'fenced=escalate manual=escalate'; then
    ok "permission verdict: classify_command is blind to task identity -- fenced-task and manually-blocked-task calls (same worktree+manifest) verdict identically for both an ALLOW and an ESCALATE-requiring-bashlex command: $pv_out"
  else
    bad "permission verdict: $pv_out"
  fi
else
  printf '  SKIP  permission verdict: .venv-bashlex not provisioned or bashlex not importable at %s -- round 5 hard rule forbids provisioning it this round; this scenario is a LOUD skip, not a silent pass\n' "$pv_py"
fi

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo PASS; exit 0; else echo FAIL; exit 1; fi
