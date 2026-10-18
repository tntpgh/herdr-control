#!/usr/bin/env bash
# verify-startup-failure-reconciliation.sh — proves spawn-task.sh fails the
# registry task (never leaves it at "starting"/"running") when the bound
# omp launcher dies or produces no readiness output before any pane output,
# and that an unmanaged literal-command spawn is never held to that
# omp-shaped wait.
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

printf '== extracted reconciliation block, managed, healthy startup: reaches running ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in "pane wait-output") printf 'Model scope: write\n'; return 0 ;; esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  run_id=r1 task_id=t1 pane=p1 managed=1
  eval "$block_src"
)
rc=$?
if [ "$rc" = 0 ] && grep -q '^state:running$' "$capture" && ! grep -q '^state:failed$' "$capture"; then
  ok "healthy: rc=0, set_task_state running, never failed"
else
  bad "healthy: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, managed, bound launcher dies at startup: fails with a reason, never reaches running ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in "pane wait-output") printf 'omp-herdr-bound: only the bound Herdr worker overlay is allowed\n'; return 0 ;; esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  run_id=r1 task_id=t1 pane=p1 managed=1
  eval "$block_src"
)
rc=$?
if [ "$rc" != 0 ] && grep -q '^state:failed$' "$capture" && ! grep -q '^state:running$' "$capture" \
   && grep -q 'event:spawn_startup_failed' "$capture" && grep -q 'bound launcher refused' "$capture"; then
  ok "dead launcher: rc=$rc, set_task_state failed (never running), reason recorded"
else
  bad "dead launcher: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, managed, no readiness output (stall or vanished pane): fails with a reason, never reaches running ==\n'
capture=$(mktemp)
(
  herdr() { case "$1 $2" in "pane wait-output") return 1 ;; esac; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  run_id=r1 task_id=t1 pane=p1 managed=1
  eval "$block_src"
)
rc=$?
if [ "$rc" != 0 ] && grep -q '^state:failed$' "$capture" && ! grep -q '^state:running$' "$capture" \
   && grep -q 'event:spawn_startup_failed' "$capture"; then
  ok "no readiness output (stall/vanish): rc=$rc, set_task_state failed (never running), reason recorded"
else
  bad "no readiness output: rc=$rc capture=$(cat "$capture")"
fi

printf '== extracted reconciliation block, UNMANAGED: never calls herdr at all, goes straight to running ==\n'
capture=$(mktemp)
(
  herdr() { echo "UNEXPECTED herdr call: $*" >> "$capture"; return 1; }
  set_task_state() { printf 'state:%s\n' "$3" >> "$capture"; }
  append_event() { printf 'event:%s payload:%s\n' "$3" "$4" >> "$capture"; }
  run_id=r1 task_id=t1 pane=p1 managed=0
  eval "$block_src"
)
rc=$?
if [ "$rc" = 0 ] && grep -q '^state:running$' "$capture" && ! grep -q 'UNEXPECTED herdr call' "$capture"; then
  ok "unmanaged: rc=0, reaches running directly, never calls herdr (no omp-shaped wait to fail)"
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
  "pane list")  printf '{"result":{"panes":[]}}\n' ;;
  "pane get")   printf '{"result":{"pane":{"agent_session":{"value":""}}}}\n' ;;
  *)            printf '{"result":{"workspace":{"workspace_id":"w1"},"workspaces":[],"panes":[],"tabs":[]}}\n' ;;
esac
STUB
chmod +x "$stub_dir/herdr"
out="$(env HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
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
