#!/usr/bin/env bash
# verify-occurrence-cold-cache.sh — round 7 review (HIGH): recordOccurrence()
# in agent-hooks/omp-herdr-control.ts used to kick off refreshHubPythonAsync()
# and read the COLD hubPythonCache on the very same tick, one line later — on
# the FIRST call of a session (before any prior resolution), that cache read
# was always empty, so the first occurrence was logged and silently dropped.
#
# Round 8 review (REQUEST CHANGES at 6be6924, 5 findings against the round 7
# fix) collapsed the warm-sync / cold-queue split into ONE ordered async
# path. This file now covers all five:
#   1. persist-before-notify   — exercised indirectly: recordOccurrence's
#      returned promise only resolves once the write has genuinely been
#      attempted, which is what lets onApprovalRequested await it before
#      notifying (see agent-hooks/omp-herdr-control.ts).
#   2+3. group-kill + real fixture — case "hung interpreter" below.
#   4. one ordered path (no overtake) — case "no overtake" below.
#   5. count exactly once — case "count once" below.
#
#   bash verify-occurrence-cold-cache.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
ORPHANS=""
cleanup() {
  for pid in $ORPHANS; do kill -9 "$pid" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

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

seen_rowid() {
  sqlite3 -batch "$DB" "select rowid from events where run_id='run1' and task_id='task1' and type='prompt_occ_seen' and json_extract(payload,'\$.tool_call_id')='$1' order by rowid limit 1;" 2>/dev/null
}
seen_count() {
  sqlite3 -batch "$DB" "select count(*) from events where run_id='run1' and task_id='task1' and type='prompt_occ_seen' and json_extract(payload,'\$.tool_call_id')='$1';" 2>/dev/null
}

printf '== round 7 (HIGH): a cold-cache recordOccurrence call is queued and flushed, not dropped ==\n'
# A freshly-imported module in a NEW process has an empty hubPythonCache —
# this IS the cold-cache case, no stubbing required. recordOccurrence now
# returns a Promise that resolves once the write has genuinely been
# attempted, so this awaits it directly instead of a blind sleep. Outer
# `timeout 20` is the never-hang-a-suite safety net, not a substitute for
# the production fix.
( cd "$here" && HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  DB="$DB" PANE="$PANE" BIRTH="$BIRTH" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
await mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "coldcall1", "--tool", "bash", "--source", "test"]);
' ) 2>"$WORK/bun.err"
cat "$WORK/bun.err" >&2

row="$(seen_count coldcall1)"
[ "${row:-0}" -ge 1 ] 2>/dev/null && ok "cold-cache occurrence (call-id coldcall1) WAS persisted after the async resolve+flush" \
  || bad "cold-cache occurrence missing: rows=${row:-0} (see $WORK/bun.err above for the hook's own stderr)"

printf '== no new sync child_process reachable from onBeforeAgentStart (#273) ==\n'
( cd "$here" && timeout 20 bun agent-hooks/check-no-sync-on-agent-start.mjs >"$WORK/sync-check.out" 2>&1 )
rc=$?
[ "$rc" -eq 0 ] && ok "$(cat "$WORK/sync-check.out")" || bad "check-no-sync-on-agent-start.mjs failed: $(cat "$WORK/sync-check.out")"

printf '== round 8 (findings 2,3): a hung interpreter is killed by its WHOLE process group, and the queue still makes progress ==\n'
# fake-slow-python3.sh now backgrounds a REAL grandchild (sleep 864017,
# not `exec sleep` replacing its own image) so a plain child.kill() could
# never reach it — only killGroup()'s process-GROUP signal can. Two
# occurrences are queued back to back (neither awaited individually) so
# the SAME drain loop has to survive killing the first before it can even
# attempt the second — proving forward progress, not just a single kill.
SLOWDIR="$(mktemp -d)"
ln -s "$here/tests/fixtures/fake-slow-python3.sh" "$SLOWDIR/python3.14"
t0=$(date +%s)
( cd "$here" && HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  HERDR_HUB_PYTHON_DIRS="$SLOWDIR" DB="$DB" PANE="$PANE" BIRTH="$BIRTH" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const p1 = mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "hungcall1", "--tool", "bash", "--source", "test"]);
const p2 = mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "hungcall2", "--tool", "bash", "--source", "test"]);
await p1;
await p2;
' ) 2>"$WORK/bun-hung.err"
t1=$(date +%s)
elapsed=$((t1 - t0))
cat "$WORK/bun-hung.err" >&2
timeouts="$(grep -c 'timed out' "$WORK/bun-hung.err")"
[ "$timeouts" -eq 2 ] && grep -q 'total failed this session: 2' "$WORK/bun-hung.err" \
  && ok "both queued occurrences against the hung interpreter were killed and counted (2 timeouts, final count 2)" \
  || bad "expected 2 'timed out' lines and a final 'total failed this session: 2', got $timeouts timeout(s): $(cat "$WORK/bun-hung.err")"
[ "$elapsed" -lt 19 ] && ok "returned well under the outer 20s timeout (elapsed=${elapsed}s)" \
  || bad "took too long: elapsed=${elapsed}s (the outer timeout 20 should never be what stops this)"
leftover="$(pgrep -f 'sleep 864017' 2>/dev/null || true)"
if [ -z "$leftover" ]; then
  ok "no orphaned grandchild (sleep 864017) survived the kill — the WHOLE process group was reached"
else
  ORPHANS="$ORPHANS $leftover"
  bad "an orphaned grandchild survived the kill (pid(s): $leftover) — only the direct child was signalled, not its process group"
fi

printf '== round 8 (finding 4): a queued occurrence cannot be overtaken by one queued after it ==\n'
# fake-delayed-python3.sh passes the floor probe instantly (so
# hubPythonCache becomes warm fast) but, for a real invocation whose args
# include the marker "overtaketest1", delays 1s before delegating to a
# genuine python3 — widening the window between "cache is warm" and "the
# occurrence that triggered the resolve has actually finished persisting"
# that the pre-round-8 warm-sync short-circuit could fall into. The SECOND
# call below is queued while the first is still draining (occurrenceDrainInFlight
# true) and must not be attempted ahead of it.
OVERTAKEDIR="$(mktemp -d)"
ln -s "$here/tests/fixtures/fake-delayed-python3.sh" "$OVERTAKEDIR/python3.14"
( cd "$here" && HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  HERDR_HUB_PYTHON_DIRS="$OVERTAKEDIR" DB="$DB" PANE="$PANE" BIRTH="$BIRTH" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const p1 = mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "overtaketest1", "--tool", "bash", "--source", "test"]);
await new Promise((r) => setTimeout(r, 150));
const p2 = mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "overtaketest2", "--tool", "bash", "--source", "test"]);
await p1;
await p2;
' ) 2>"$WORK/bun-overtake.err"
cat "$WORK/bun-overtake.err" >&2
r1="$(seen_rowid overtaketest1)"
r2="$(seen_rowid overtaketest2)"
if [ -n "$r1" ] && [ -n "$r2" ] && [ "$r1" -lt "$r2" ] 2>/dev/null; then
  ok "overtaketest1 (queued first, deliberately slow) persisted strictly before overtaketest2 (queued 150ms later): rowid $r1 < $r2"
else
  bad "arrival order violated or a row is missing: overtaketest1 rowid=${r1:-missing}, overtaketest2 rowid=${r2:-missing}"
fi

printf '== round 8 (finding 5): a spawn failure that fires BOTH error and close is counted exactly once ==\n'
# Warm up hubPythonCache against a genuinely working interpreter (real
# delegation, no delay), then remove its execute bit on the SAME cached
# path: exec() then fails inside the already-forked child (EACCES), which
# is the spawn failure shape Node/Bun fire BOTH 'error' AND 'close' for —
# the shared `settled` guard inside runOccurrenceAsync must make sure only
# ONE of those increments pendingOccurrenceFailed, not two.
COUNTDIR="$(mktemp -d)"
cp "$here/tests/fixtures/fake-delayed-python3.sh" "$COUNTDIR/python3.14"
chmod +x "$COUNTDIR/python3.14"
( cd "$here" && HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  HERDR_HUB_PYTHON_DIRS="$COUNTDIR" DB="$DB" PANE="$PANE" BIRTH="$BIRTH" COUNTPY="$COUNTDIR/python3.14" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
await mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "warmupcall", "--tool", "bash", "--source", "test"]);
const { chmodSync } = await import("node:fs");
chmodSync(process.env.COUNTPY, 0o644);
await mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "eaccescall", "--tool", "bash", "--source", "test"]);
' ) 2>"$WORK/bun-count.err"
cat "$WORK/bun-count.err" >&2
failcount="$(grep -c 'total failed this session' "$WORK/bun-count.err")"
[ "$failcount" -eq 1 ] && grep -q 'total failed this session: 1' "$WORK/bun-count.err" \
  && ok "the EACCES spawn failure was logged/counted exactly once (not double-counted by error+close)" \
  || bad "expected exactly one failure log line reading 'total failed this session: 1', got $failcount line(s): $(cat "$WORK/bun-count.err")"
[ "$(seen_count warmupcall)" -ge 1 ] 2>/dev/null && ok "warmup occurrence persisted normally before the sabotage" \
  || bad "warmup occurrence did not persist — the sabotage setup itself is broken, not just the count"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
