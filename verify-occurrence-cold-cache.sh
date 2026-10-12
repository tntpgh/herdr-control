#!/usr/bin/env bash
# verify-occurrence-cold-cache.sh — round 7 review (HIGH): recordOccurrence()
# in agent-hooks/omp-herdr-control.ts used to kick off refreshHubPythonAsync()
# and read the COLD hubPythonCache on the very same tick, one line later — on
# the FIRST call of a session (before any prior resolution), that cache read
# was always empty, so the first occurrence was logged and silently dropped.
# Fixed: a cold-cache call is queued (bounded) and flushed by the async
# resolver's own callback the instant it resolves — never a second resolver,
# never a new sync child_process on the onBeforeAgentStart path (still proven
# by check-no-sync-on-agent-start.mjs, re-run below).
#
#   bash verify-occurrence-cold-cache.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PANE="w1:p1"
BIRTH="term-abc-123"

. "$here/lib/run-registry.sh"
export HERDR_RUN_STATE_DIR="$WORK/runs"
. "$here/tests/fixtures/task-authorization.sh"
fixture_register_task run1 task1 w1 c1 "w9:p9" "cond-birth" "$PANE" "$BIRTH" /repo /wt "impl:test" >/dev/null 2>&1 || exit 1
DB="$(registry_db)"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

printf '== round 7 (HIGH): a cold-cache recordOccurrence call is queued and flushed, not dropped ==\n'
# A freshly-imported module in a NEW process has an empty hubPythonCache —
# this IS the cold-cache case, no stubbing required. recordOccurrence is
# called exactly once, immediately on import, before any prior resolution
# could possibly have happened. `timeout 20` + the script's own
# process.exit(0) (Main review follow-up): this suite must never be able
# to hang on a stuck child again, regardless of what bug might be hiding
# in whatever this exercises — belt AND suspenders over the production
# fix below, not a substitute for it.
( cd "$here" && HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  DB="$DB" PANE="$PANE" BIRTH="$BIRTH" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "coldcall1", "--tool", "bash", "--source", "test"]);
await new Promise((r) => setTimeout(r, 3000));
process.exit(0);
' ) 2>"$WORK/bun.err"
cat "$WORK/bun.err" >&2

row="$(sqlite3 -batch "$DB" "select count(*) from events where run_id='run1' and task_id='task1' and type='prompt_occ_seen' and json_extract(payload,'\$.tool_call_id')='coldcall1';" 2>/dev/null)"
[ "${row:-0}" -ge 1 ] 2>/dev/null && ok "cold-cache occurrence (call-id coldcall1) WAS persisted after the async resolve+flush" \
  || bad "cold-cache occurrence missing: rows=${row:-0} (see $WORK/bun.err above for the hook's own stderr)"

printf '== no new sync child_process reachable from onBeforeAgentStart (#273) ==\n'
( cd "$here" && timeout 20 bun agent-hooks/check-no-sync-on-agent-start.mjs >"$WORK/sync-check.out" 2>&1 )
rc=$?
[ "$rc" -eq 0 ] && ok "$(cat "$WORK/sync-check.out")" || bad "check-no-sync-on-agent-start.mjs failed: $(cat "$WORK/sync-check.out")"

printf '== round 7 follow-up (Main review): a hung prompt-occurrence.py is killed within the bounded timeout, logged and counted ==\n'
# Main review traced an EARLIER version of this case hanging the whole
# suite to a SEPARATE, pre-existing, independent bug this exposed:
# prefetchRegisteredWorktree() (module-load time, unconditional) spawned
# `bash -c read_task` with piped stdio and NO timeout at all — read_task
# resolves the SAME pinned interpreter via _registry_python, so pointing
# HERDR_HUB_PYTHON_DIRS at the slow fixture (below) made THAT prefetch
# hang too, and its dangling piped-stdout handle to a still-running
# grandchild kept bun's own event loop alive forever, independent of
# runOccurrenceAsync's own (already-bounded) kill timer. Fixed in
# production (prefetchRegisteredWorktree now uses the same bounded
# timeout + detached process-GROUP kill captureOutput already used for
# this exact class of bug). Waits 9s here — comfortably past BOTH
# mechanisms' worst case (4s timeout + up to 2s SIGTERM-then-SIGKILL
# grace each, run in parallel, not summed) — plus the outer `timeout 20`
# and explicit process.exit(0) so a regression here fails this ONE case
# instead of hanging the suite.
SLOWDIR="$(mktemp -d)"
ln -s "$here/tests/fixtures/fake-slow-python3.sh" "$SLOWDIR/python3.14"
t0=$(date +%s)
( cd "$here" && HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  HERDR_HUB_PYTHON_DIRS="$SLOWDIR" DB="$DB" PANE="$PANE" BIRTH="$BIRTH" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "hungcall1", "--tool", "bash", "--source", "test"]);
await new Promise((r) => setTimeout(r, 9000));
process.exit(0);
' ) 2>"$WORK/bun-hung.err"
t1=$(date +%s)
elapsed=$((t1 - t0))
cat "$WORK/bun-hung.err" >&2
grep -q 'timed out' "$WORK/bun-hung.err" && grep -q 'total failed this session: 1' "$WORK/bun-hung.err" \
  && ok "hung interpreter: logged ('timed out') AND counted ('total failed this session: 1')" \
  || bad "expected a 'timed out' + 'total failed this session: 1' log line, got: $(cat "$WORK/bun-hung.err")"
[ "$elapsed" -lt 19 ] && ok "returned well under the outer 20s timeout (elapsed=${elapsed}s)" \
  || bad "took too long: elapsed=${elapsed}s (the outer timeout 20 should never be what stops this)"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
