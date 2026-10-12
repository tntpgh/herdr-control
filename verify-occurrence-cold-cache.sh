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

# Round 9 followup (Main/reviewer): the cases below drive the REAL
# tool_approval_requested handler (not a direct recordOccurrence call) to
# prove the fail-closed persisted gate actually suppresses (or, for the
# positive case, actually sends) the human notification — a helper-return
# assertion alone never exercised onApprovalRequested's own branch. ROOT
# resolves to this shim (agent-hooks/omp-notify.sh stubbed to a file instead
# of the real script, which would leave the machine) while
# lib/prompt-occurrence.py and launchd/resolve-hub-python.sh stay the real,
# self-contained files via symlink — same recipe as verify-omp-hooks.sh's
# shim, reused here rather than reinvented.
NOTIFYSHIM="$WORK/notifyshim"
mkdir -p "$NOTIFYSHIM/agent-hooks" "$NOTIFYSHIM/lib" "$NOTIFYSHIM/launchd"
cat > "$NOTIFYSHIM/agent-hooks/omp-notify.sh" <<'EOS'
#!/usr/bin/env bash
cat > "$NOTIFY_REC"
EOS
chmod +x "$NOTIFYSHIM/agent-hooks/omp-notify.sh"
ln -sf "$here/lib/prompt-occurrence.py" "$NOTIFYSHIM/lib/prompt-occurrence.py"
ln -sf "$here/launchd/resolve-hub-python.sh" "$NOTIFYSHIM/launchd/resolve-hub-python.sh"

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
const persisted = await mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "coldcall1", "--tool", "bash", "--source", "test"]);
console.log("PERSISTED=" + persisted);
' ) >"$WORK/bun.out" 2>"$WORK/bun.err"
cat "$WORK/bun.err" >&2

row="$(seen_count coldcall1)"
[ "${row:-0}" -ge 1 ] 2>/dev/null && ok "cold-cache occurrence (call-id coldcall1) WAS persisted after the async resolve+flush" \
  || bad "cold-cache occurrence missing: rows=${row:-0} (see $WORK/bun.err above for the hook's own stderr)"
grep -q '^PERSISTED=true$' "$WORK/bun.out" \
  && ok "recordOccurrence resolved persisted=true after a real durable write (round 9, finding 1: this is what gates the notification)" \
  || bad "expected PERSISTED=true in stdout, got: $(cat "$WORK/bun.out")"

printf '== round 9 followup: the REAL tool_approval_requested handler notifies with the command after a genuine persist ==\n'
NOTIFY_REC="$WORK/notify-positive.json"; rm -f "$NOTIFY_REC"
( cd "$here" && HERDR_CONTROL_DIR="$NOTIFYSHIM" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  NOTIFY_REC="$NOTIFY_REC" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "positivecall1", input: { command: "git push --force" }, reason: "destructive" });
await new Promise((r) => setTimeout(r, 1500));
' ) 2>"$WORK/bun-positive.err"
cat "$WORK/bun-positive.err" >&2
if [ -s "$NOTIFY_REC" ]; then
  jq -e '.command == "git push --force"' "$NOTIFY_REC" >/dev/null 2>&1 \
    && ok "round 9 followup: the real handler notified with the command after a genuine persist" \
    || bad "notify fired but command field missing/wrong: $(cat "$NOTIFY_REC")"
else
  bad "the real handler never notified at all: $(cat "$WORK/bun-positive.err")"
fi
[ "$(seen_count positivecall1)" -ge 1 ] 2>/dev/null \
  && ok "the handler's own occurrence was durably persisted before it notified" \
  || bad "no persisted row for positivecall1 despite a notification being expected"

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
console.log("PERSISTED1=" + (await p1));
console.log("PERSISTED2=" + (await p2));
' ) >"$WORK/bun-hung.out" 2>"$WORK/bun-hung.err"
t1=$(date +%s)
elapsed=$((t1 - t0))
cat "$WORK/bun-hung.err" >&2
timeouts="$(grep -c 'timed out' "$WORK/bun-hung.err")"
[ "$timeouts" -eq 2 ] && grep -q 'total failed this session: 2' "$WORK/bun-hung.err" \
  && ok "both queued occurrences against the hung interpreter were killed and counted (2 timeouts, final count 2)" \
  || bad "expected 2 'timed out' lines and a final 'total failed this session: 2', got $timeouts timeout(s): $(cat "$WORK/bun-hung.err")"
grep -q '^PERSISTED1=false$' "$WORK/bun-hung.out" && grep -q '^PERSISTED2=false$' "$WORK/bun-hung.out" \
  && ok "round 9 (BLOCK): both timed-out occurrences resolved persisted=false — the approval handler would suppress their notification" \
  || bad "expected PERSISTED1=false and PERSISTED2=false in stdout, got: $(cat "$WORK/bun-hung.out")"
[ "$elapsed" -lt 19 ] && ok "returned well under the outer 20s timeout (elapsed=${elapsed}s)" \
  || bad "took too long: elapsed=${elapsed}s (the outer timeout 20 should never be what stops this)"
leftover="$(pgrep -f 'sleep 864017' 2>/dev/null || true)"
if [ -z "$leftover" ]; then
  ok "no orphaned grandchild (sleep 864017) survived the kill — the WHOLE process group was reached"
else
  ORPHANS="$ORPHANS $leftover"
  bad "an orphaned grandchild survived the kill (pid(s): $leftover) — only the direct child was signalled, not its process group"
fi

printf '== round 9 followup: the REAL handler sends NO notification when the occurrence persist times out ==\n'
NOTIFY_REC="$WORK/notify-timeout.json"; rm -f "$NOTIFY_REC"
( cd "$here" && HERDR_CONTROL_DIR="$NOTIFYSHIM" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  HERDR_HUB_PYTHON_DIRS="$SLOWDIR" NOTIFY_REC="$NOTIFY_REC" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "timeoutHandlerCall", input: { command: "git push --force" }, reason: "destructive" });
await new Promise((r) => setTimeout(r, 4500));
' ) 2>"$WORK/bun-timeout-handler.err"
cat "$WORK/bun-timeout-handler.err" >&2
if [ -e "$NOTIFY_REC" ]; then
  bad "the real handler notified despite the persist timing out: $(cat "$NOTIFY_REC")"
else
  ok "round 9 followup: no notification was sent when the real handler's persist attempt timed out"
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

printf '== round 8 (finding 5) / round 9 (BLOCK, EACCES boundary): a spawn failure that fires BOTH error and close is counted exactly once, and resolves persisted=false ==\n'
# Warm up hubPythonCache against a genuinely working interpreter (real
# delegation, no delay), then remove its execute bit on the SAME cached
# path: exec() then fails inside the already-forked child (EACCES), which
# is the spawn failure shape Node/Bun fire BOTH 'error' AND 'close' for —
# the shared `settled` guard inside runOccurrenceAsync must make sure only
# ONE of those increments pendingOccurrenceFailed, not two. Round 9: this
# EACCES failure must also resolve persisted=false, not just void — the
# one thing the approval handler now gates its notification on.
COUNTDIR="$(mktemp -d)"
cp "$here/tests/fixtures/fake-delayed-python3.sh" "$COUNTDIR/python3.14"
chmod +x "$COUNTDIR/python3.14"
( cd "$here" && HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  HERDR_HUB_PYTHON_DIRS="$COUNTDIR" DB="$DB" PANE="$PANE" BIRTH="$BIRTH" COUNTPY="$COUNTDIR/python3.14" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const warmupPersisted = await mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "warmupcall", "--tool", "bash", "--source", "test"]);
const { chmodSync } = await import("node:fs");
chmodSync(process.env.COUNTPY, 0o644);
const eaccesPersisted = await mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "eaccescall", "--tool", "bash", "--source", "test"]);
console.log("WARMUP_PERSISTED=" + warmupPersisted);
console.log("EACCES_PERSISTED=" + eaccesPersisted);
' ) >"$WORK/bun-count.out" 2>"$WORK/bun-count.err"
cat "$WORK/bun-count.err" >&2
failcount="$(grep -c 'total failed this session' "$WORK/bun-count.err")"
[ "$failcount" -eq 1 ] && grep -q 'total failed this session: 1' "$WORK/bun-count.err" \
  && ok "the EACCES spawn failure was logged/counted exactly once (not double-counted by error+close)" \
  || bad "expected exactly one failure log line reading 'total failed this session: 1', got $failcount line(s): $(cat "$WORK/bun-count.err")"
[ "$(seen_count warmupcall)" -ge 1 ] 2>/dev/null && ok "warmup occurrence persisted normally before the sabotage" \
  || bad "warmup occurrence did not persist — the sabotage setup itself is broken, not just the count"
grep -q '^WARMUP_PERSISTED=true$' "$WORK/bun-count.out" && grep -q '^EACCES_PERSISTED=false$' "$WORK/bun-count.out" \
  && ok "round 9 (BLOCK): warmup resolved persisted=true, the EACCES failure resolved persisted=false — notification correctly gated" \
  || bad "expected WARMUP_PERSISTED=true and EACCES_PERSISTED=false in stdout, got: $(cat "$WORK/bun-count.out")"

printf '== round 9 followup: the REAL handler sends NO notification when the persist attempt hits EACCES ==\n'
EACCESDIR="$(mktemp -d)"
cp "$here/tests/fixtures/fake-delayed-python3.sh" "$EACCESDIR/python3.14"
chmod +x "$EACCESDIR/python3.14"
NOTIFY_REC="$WORK/notify-eacces.json"; rm -f "$NOTIFY_REC"
( cd "$here" && HERDR_CONTROL_DIR="$NOTIFYSHIM" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  HERDR_HUB_PYTHON_DIRS="$EACCESDIR" EACCESPY="$EACCESDIR/python3.14" NOTIFY_REC="$NOTIFY_REC" DB="$DB" PANE="$PANE" BIRTH="$BIRTH" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
// Warm hubPythonCache against a genuinely working interpreter first, exactly
// like the direct-call EACCES case above, then revoke exec on the SAME
// cached path so the handlers own persist attempt is what hits EACCES.
await mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "eaccesWarmup", "--tool", "bash", "--source", "test"]);
const { chmodSync } = await import("node:fs");
chmodSync(process.env.EACCESPY, 0o644);
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "eaccesHandlerCall", input: { command: "git push --force" }, reason: "destructive" });
await new Promise((r) => setTimeout(r, 1500));
' ) 2>"$WORK/bun-eacces-handler.err"
cat "$WORK/bun-eacces-handler.err" >&2
if [ -e "$NOTIFY_REC" ]; then
  bad "the real handler notified despite the persist hitting EACCES: $(cat "$NOTIFY_REC")"
else
  ok "round 9 followup: no notification was sent when the real handler's persist attempt hit EACCES"
fi

printf '== round 9 (BLOCK): a queue eviction resolves the evicted occurrence persisted=false ==\n'
# An interpreter search path with NO candidates at all: the resolver never
# succeeds, so nothing ever drains and every recordOccurrence call just
# piles onto the queue — letting this force a real eviction deterministically.
# The 51st push (MAX_PENDING_OCCURRENCES is 50) evicts the OLDEST (the
# very first one pushed) from the front; the trigger call itself is never
# awaited since it can never resolve in this scenario (no interpreter will
# ever be found).
EMPTYDIR="$(mktemp -d)"
( cd "$here" && HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  HERDR_HUB_PYTHON_DIRS="$EMPTYDIR" DB="$DB" PANE="$PANE" BIRTH="$BIRTH" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const first = mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "evictedcall", "--tool", "bash", "--source", "test"]);
for (let i = 0; i < 49; i++) {
  mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
    "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
    "--call-id", "filler" + i, "--tool", "bash", "--source", "test"]);
}
mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "triggerevict", "--tool", "bash", "--source", "test"]);
console.log("EVICTED_PERSISTED=" + (await first));
' ) >"$WORK/bun-evict.out" 2>"$WORK/bun-evict.err"
cat "$WORK/bun-evict.err" >&2
grep -q 'pending-queue cap' "$WORK/bun-evict.err" \
  && ok "a truthful eviction log line was printed" \
  || bad "expected a 'pending-queue cap' log line, got: $(cat "$WORK/bun-evict.err")"
grep -q '^EVICTED_PERSISTED=false$' "$WORK/bun-evict.out" \
  && ok "round 9 (BLOCK): the evicted occurrence resolved persisted=false — notification correctly suppressed" \
  || bad "expected EVICTED_PERSISTED=false in stdout, got: $(cat "$WORK/bun-evict.out")"

printf '== round 9 followup: the REAL handler sends NO notification when its own occurrence is evicted from the queue ==\n'
NOTIFY_REC="$WORK/notify-evict.json"; rm -f "$NOTIFY_REC"
( cd "$here" && HERDR_CONTROL_DIR="$NOTIFYSHIM" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  HERDR_HUB_PYTHON_DIRS="$EMPTYDIR" DB="$DB" PANE="$PANE" BIRTH="$BIRTH" NOTIFY_REC="$NOTIFY_REC" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
// The handlers own occurrence is pushed FIRST, so it is the oldest in the
// FIFO queue and the one the 51st push below evicts.
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "evictedHandlerCall", input: { command: "git push --force" }, reason: "destructive" });
for (let i = 0; i < 50; i++) {
  mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
    "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
    "--call-id", "evictfiller" + i, "--tool", "bash", "--source", "test"]);
}
await new Promise((r) => setTimeout(r, 500));
' ) 2>"$WORK/bun-evict-handler.err"
cat "$WORK/bun-evict-handler.err" >&2
if [ -e "$NOTIFY_REC" ]; then
  bad "the real handler notified despite its own occurrence being evicted: $(cat "$NOTIFY_REC")"
else
  ok "round 9 followup: no notification was sent when the real handler's own occurrence was evicted"
fi

printf '== round 9 (BLOCK): prompt-occurrence.py exiting 0 with a JSON error resolves persisted=false ==\n'
# A malformed --input-json makes prompt-occurrence.py itself print
# {"error": "malformed --input-json: ..."} and exit 0 (lib/prompt-occurrence.py
# main(), the `seen` branch) — the exact "attempt succeeded, persist did
# not" shape this whole round exists to close. No fixture interpreter
# needed: the real system python3 the earlier cases already resolve
# through is enough, since the failure is prompt-occurrence.py's own.
( cd "$here" && HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  DB="$DB" PANE="$PANE" BIRTH="$BIRTH" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const persisted = await mod.recordOccurrence(["seen", "--db", process.env.DB, "--run", "run1", "--task", "task1",
  "--pane", process.env.PANE, "--birth", process.env.BIRTH, "--session", "native-sess-1",
  "--call-id", "jsonerrcall", "--tool", "bash", "--input-json", "{this is not json", "--source", "test"]);
console.log("PERSISTED=" + persisted);
' ) >"$WORK/bun-jsonerr.out" 2>"$WORK/bun-jsonerr.err"
cat "$WORK/bun-jsonerr.err" >&2
grep -q 'was not a success' "$WORK/bun-jsonerr.err" \
  && ok "a truthful 'exited 0 but its response was not a success' log line was printed" \
  || bad "expected a 'was not a success' log line, got: $(cat "$WORK/bun-jsonerr.err")"
grep -q '^PERSISTED=false$' "$WORK/bun-jsonerr.out" \
  && ok "round 9 (BLOCK): an exit-0 JSON error resolved persisted=false — notification correctly suppressed" \
  || bad "expected PERSISTED=false in stdout, got: $(cat "$WORK/bun-jsonerr.out")"
[ "$(seen_count jsonerrcall)" -eq 0 ] 2>/dev/null && ok "no row was ever written for the malformed-input call" \
  || bad "a row exists for jsonerrcall despite the malformed --input-json — should never have been written"

printf '== round 9 followup: the REAL handler sends NO notification when prompt-occurrence.py exits 0 with a JSON error ==\n'
# JSON.stringify(input) inside the real handler can never produce malformed
# JSON the way the direct-call case above does, so this reaches the same
# exit-0-with-{"error":...} shape a different way: REGISTRY_DB is a path
# UNDER this run's state dir, and making that exact path a directory (not a
# file) makes prompt-occurrence.py's own sqlite3.connect() raise — caught by
# its generic `except Exception as exc: out = {"error": str(exc)}`, exit 0.
JSONERRSTATE="$(mktemp -d)"
mkdir -p "$JSONERRSTATE/registry.sqlite3"
NOTIFY_REC="$WORK/notify-jsonerr.json"; rm -f "$NOTIFY_REC"
( cd "$here" && HERDR_CONTROL_DIR="$NOTIFYSHIM" HERDR_RUN_STATE_DIR="$JSONERRSTATE" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  NOTIFY_REC="$NOTIFY_REC" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "jsonerrHandlerCall", input: { command: "git push --force" }, reason: "destructive" });
await new Promise((r) => setTimeout(r, 1500));
' ) 2>"$WORK/bun-jsonerr-handler.err"
cat "$WORK/bun-jsonerr-handler.err" >&2
grep -q 'was not a success' "$WORK/bun-jsonerr-handler.err" \
  && ok "a truthful 'exited 0 but its response was not a success' log line was printed for the real handler's own attempt" \
  || bad "expected a 'was not a success' log line, got: $(cat "$WORK/bun-jsonerr-handler.err")"
if [ -e "$NOTIFY_REC" ]; then
  bad "the real handler notified despite prompt-occurrence.py exiting 0 with a JSON error: $(cat "$NOTIFY_REC")"
else
  ok "round 9 followup: no notification was sent when the real handler's persist attempt exited 0 with a JSON error"
fi

printf '== round 10 followup: the REAL handler sends NO notification for a mismatch replay (same occurrence, changed command) ==\n'
# record_seen (lib/prompt-occurrence.py:198-217) writes "mismatch", not
# "seen"/"enriched"/"duplicate", when the SAME occurrence identity arrives
# again with a DIFFERENT tool/input digest than whatever was recorded
# first — parsePersistedResponse must read this as persisted=false for the
# `seen` call, not just a non-empty occ_key with no error. Same toolCallId
# both times (a real repeat firing of tool_approval_requested for one
# still-open prompt, per the cache comment above onApprovalRequested) with
# a different command the second time. omp-notify.sh (the shared
# NOTIFYSHIM stub) overwrites its record file per call, which is enough
# here: a wrongly-sent second notification would overwrite "ls" with
# "rm -rf /", so the content check below still catches it.
NOTIFY_REC="$WORK/notify-mismatch.json"; rm -f "$NOTIFY_REC"
( cd "$here" && HERDR_CONTROL_DIR="$NOTIFYSHIM" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  NOTIFY_REC="$NOTIFY_REC" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "mismatchcall1", input: { command: "ls" }, reason: "first" });
await new Promise((r) => setTimeout(r, 1500));
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "mismatchcall1", input: { command: "rm -rf /" }, reason: "second" });
await new Promise((r) => setTimeout(r, 1500));
' ) 2>"$WORK/bun-mismatch.err"
cat "$WORK/bun-mismatch.err" >&2
if [ -s "$NOTIFY_REC" ] && jq -e '.command == "ls"' "$NOTIFY_REC" >/dev/null 2>&1; then
  ok "round 10 followup: the one notification on record is the first, genuine 'seen' write — the mismatch replay sent none"
else
  bad "expected the one notify file to hold 'ls' only, got: $(cat "$NOTIFY_REC" 2>/dev/null)"
fi

printf '== round 10 followup: the REAL handler sends NO notification for a malformed partial success ({"occ_key":"x"}, exit 0) ==\n'
# A fixture prompt-occurrence.py standing in for a buggy/future response
# shape: occ_key present, no error key, but no `written` field at all.
# parsePersistedResponse must still read this as persisted=false for the
# `seen` call, not accept on occ_key alone.
MALFORMEDSHIM="$WORK/malformedshim"
mkdir -p "$MALFORMEDSHIM/agent-hooks" "$MALFORMEDSHIM/lib" "$MALFORMEDSHIM/launchd"
cat > "$MALFORMEDSHIM/agent-hooks/omp-notify.sh" <<'EOS'
#!/usr/bin/env bash
cat > "$NOTIFY_REC"
EOS
chmod +x "$MALFORMEDSHIM/agent-hooks/omp-notify.sh"
cat > "$MALFORMEDSHIM/lib/prompt-occurrence.py" <<'EOS'
#!/usr/bin/env python3
import json
print(json.dumps({"occ_key": "x"}))
EOS
ln -sf "$here/launchd/resolve-hub-python.sh" "$MALFORMEDSHIM/launchd/resolve-hub-python.sh"
NOTIFY_REC="$WORK/notify-malformed.json"; rm -f "$NOTIFY_REC"
( cd "$here" && HERDR_CONTROL_DIR="$MALFORMEDSHIM" HERDR_RUN_STATE_DIR="$WORK/runs" HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$PANE" \
  NOTIFY_REC="$NOTIFY_REC" \
  timeout 20 bun -e '
const mod = await import(process.cwd() + "/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_approval_requested"]({ toolName: "bash", toolCallId: "malformedcall1", input: { command: "git push --force" }, reason: "destructive" });
await new Promise((r) => setTimeout(r, 1500));
' ) 2>"$WORK/bun-malformed.err"
cat "$WORK/bun-malformed.err" >&2
grep -q 'was not a success' "$WORK/bun-malformed.err" \
  && ok "a truthful 'exited 0 but its response was not a success' log line was printed for the malformed partial success" \
  || bad "expected a 'was not a success' log line, got: $(cat "$WORK/bun-malformed.err")"
if [ -e "$NOTIFY_REC" ]; then
  bad "the real handler notified despite a malformed partial success (no written field): $(cat "$NOTIFY_REC")"
else
  ok "round 10 followup: no notification was sent for a malformed partial success"
fi

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
