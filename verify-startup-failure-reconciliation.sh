#!/usr/bin/env bash
# verify-startup-failure-reconciliation.sh — proves spawn-task.sh fails the
# registry task (never leaves it at "starting"/"running", and never prints
# HERDR_SPAWN_RECEIPT) when the bound omp launcher dies, produces no
# readiness output, or produces readiness output with no live agent process
# behind it — and that an unmanaged literal-command spawn is never held to
# that omp-shaped wait.
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
# (unmanaged, which has no readiness check to defer behind). And the
# `--brief` kickoff's delivery failure used to be a printed warning while
# the task stayed `running`; it is now `launch_failed` like every other
# startup defect, and `HERDR_SPAWN_RECEIPT`'s `verified=` value now
# distinguishes `launcher-verified-ready` (no `--brief` requested) from
# `brief-delivered` (requested and confirmed delivered) rather than always
# reading `agent-process-live` regardless of whether a brief ever reached
# the worker.
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
# `herdr`/`set_task_state`/`append_event` — this worker's sandbox cannot
# authenticate as a conductor-eligible pane for a real, non-dry-run MANAGED
# spawn (`pane_is_conductor_eligible`, lib/pane-guard.sh:144; the SAME known
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
  run_id=r1 task_id=t1 pane=p1 managed=1 label=impl:t1 HERDR_SOURCE=spawn-task
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '^state:running$' "$capture" && ! grep -q '^state:launch_failed$' "$capture" \
   && grep -q '^report-agent:called$' "$capture"; then
  ok "healthy: rc=0, set_task_state running, never launch_failed, working stamped once verified"
else
  bad "healthy: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, managed, bound launcher dies at startup: launch_failed, never reaches running, working never stamped ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in
    "pane wait-output") printf 'omp-herdr-bound: only the bound Herdr worker overlay is allowed\n'; return 0 ;;
    "pane report-agent") echo "report-agent:called" >> "$capture" ;;
  esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  pane_is_agent() { [ "${AGENT_LIVE:-1}" = 1 ]; }
  run_id=r1 task_id=t1 pane=p1 managed=1
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" != 0 ] && grep -q '^state:launch_failed$' "$capture" && ! grep -q '^state:running$' "$capture" \
   && grep -q 'event:spawn_startup_failed' "$capture" && grep -q 'bound launcher refused' "$capture" \
   && ! grep -q 'report-agent:called' "$capture"; then
  ok "dead launcher: rc=$rc, set_task_state launch_failed (never running), reason recorded, working never stamped"
else
  bad "dead launcher: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, managed, no readiness output (stall or vanished pane): launch_failed, never reaches running, working never stamped ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in
    "pane wait-output") return 1 ;;
    "pane report-agent") echo "report-agent:called" >> "$capture" ;;
  esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  pane_is_agent() { [ "${AGENT_LIVE:-1}" = 1 ]; }
  run_id=r1 task_id=t1 pane=p1 managed=1
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" != 0 ] && grep -q '^state:launch_failed$' "$capture" && ! grep -q '^state:running$' "$capture" \
   && grep -q 'event:spawn_startup_failed' "$capture" && ! grep -q 'report-agent:called' "$capture"; then
  ok "no readiness output (stall/vanish): rc=$rc, set_task_state launch_failed (never running), reason recorded, working never stamped"
else
  bad "no readiness output: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, managed, readiness output but NO live agent process (bare shell): launch_failed, never reaches running, working never stamped ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in
    "pane wait-output") printf 'Model scope: write\n'; return 0 ;;
    "pane report-agent") echo "report-agent:called" >> "$capture" ;;
  esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  pane_is_agent() { [ "${AGENT_LIVE:-1}" = 1 ]; }
  AGENT_LIVE=0
  run_id=r1 task_id=t1 pane=p1 managed=1
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" != 0 ] && grep -q '^state:launch_failed$' "$capture" && ! grep -q '^state:running$' "$capture" \
   && grep -q 'event:spawn_startup_failed' "$capture" && grep -qi 'not a recognized agent' "$capture" \
   && ! grep -q 'report-agent:called' "$capture"; then
  ok "readiness ok but dead pane: rc=$rc, launch_failed (never running), reason recorded, working never stamped — this is the wB6:p2 shape"
else
  bad "readiness ok but dead pane: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, UNMANAGED: never calls herdr or pane_is_agent, goes straight to running, no receipt ==\n'
capture=$(mktemp)
(
  herdr() { echo "UNEXPECTED herdr call: $*" >> "$capture"; return 1; }
  pane_is_agent() { echo "UNEXPECTED pane_is_agent call" >> "$capture"; return 1; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  run_id=r1 task_id=t1 pane=p1 managed=0
  eval "$block_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '^state:running$' "$capture" && ! grep -q 'UNEXPECTED' "$capture" \
   && ! grep -q 'HERDR_SPAWN_RECEIPT' "$capture"; then
  ok "unmanaged: rc=0, reaches running directly, never calls herdr/pane_is_agent, no receipt (no omp-shaped wait to fail)"
else
  bad "unmanaged: rc=$rc capture=$(cat "$capture")"
fi

block2_src="$(awk '/^kickoff_note="none \(no --brief/,/^bgtag="background"/' "$here/spawn-task.sh" | sed '$d')"
case "$block2_src" in
  *'HERDR_SPAWN_RECEIPT'*'spawn_verified'*) ;;
  *) echo "FATAL: extraction markers no longer bracket spawn-task.sh's kickoff/receipt block — re-anchor this test" >&2; exit 2 ;;
esac
stub2_dir=$(mktemp -d)
cat > "$stub2_dir/send-to-agent.sh" <<'STUB'
#!/usr/bin/env bash
exit "${FAKE_STA_RC:-0}"
STUB
chmod +x "$stub2_dir/send-to-agent.sh"

printf '== extracted kickoff/receipt block, managed, no --brief requested: receipt verified=launcher-verified-ready, no send-to-agent call ==\n'
capture=$(mktemp)
(
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  run_id=r1 task_id=t1 pane=p1 managed=1 brief_file="" orchestrator_closes=0 here="$stub2_dir"
  eval "$block2_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '^HERDR_SPAWN_RECEIPT run_id=r1 task_id=t1 pane=p1 verified=launcher-verified-ready$' "$capture" \
   && ! grep -q '^state:' "$capture"; then
  ok "no --brief: receipt verified=launcher-verified-ready, no state transition, no send-to-agent call"
else
  bad "no --brief: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted kickoff/receipt block, managed, --brief delivered: receipt verified=brief-delivered ==\n'
capture=$(mktemp)
(
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  export FAKE_STA_RC=0
  run_id=r1 task_id=t1 pane=p1 managed=1 brief_file=/tmp/fake-brief orchestrator_closes=0 here="$stub2_dir"
  eval "$block2_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q '^HERDR_SPAWN_RECEIPT run_id=r1 task_id=t1 pane=p1 verified=brief-delivered$' "$capture" \
   && ! grep -q '^state:launch_failed$' "$capture"; then
  ok "--brief delivered: receipt verified=brief-delivered"
else
  bad "--brief delivered: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted kickoff/receipt block, managed, --brief delivery FAILS: launch_failed, exit nonzero, no receipt — the live script treated this as a soft warning (conductor audit, 2026-10-29) ==\n'
capture=$(mktemp)
(
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  export FAKE_STA_RC=1
  run_id=r1 task_id=t1 pane=p1 managed=1 brief_file=/tmp/fake-brief orchestrator_closes=0 here="$stub2_dir"
  eval "$block2_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" != 0 ] && grep -q '^state:launch_failed$' "$capture" && grep -q 'event:spawn_startup_failed' "$capture" \
   && grep -qi 'brief_undelivered' "$capture" && ! grep -q 'HERDR_SPAWN_RECEIPT' "$capture"; then
  ok "--brief delivery fails: launch_failed, exit nonzero, no success receipt — nobody told the worker what to do"
else
  bad "--brief delivery fails: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted kickoff/receipt block, UNMANAGED: never attempts kickoff, no receipt, regardless of --brief ==\n'
capture=$(mktemp)
(
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  export FAKE_STA_RC=1
  run_id=r1 task_id=t1 pane=p1 managed=0 brief_file=/tmp/fake-brief orchestrator_closes=0 here="$stub2_dir"
  eval "$block2_src"
) >>"$capture" 2>&1
rc=$?
if [ "$rc" = 0 ] && [ ! -s "$capture" ]; then
  ok "unmanaged: kickoff/receipt block is a complete no-op regardless of --brief"
else
  bad "unmanaged: rc=$rc capture=$(cat "$capture")"
fi



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

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo PASS; exit 0; else echo FAIL; exit 1; fi
