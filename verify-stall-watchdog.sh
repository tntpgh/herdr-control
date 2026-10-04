#!/usr/bin/env bash
# verify-stall-watchdog.sh — .handoffs/SPEC.md (feat/stall-watchdog).
# Hermetic: no live herdr, no live panes, no network, no real registry.
#
# Section A (bash, stub-herdr pattern from verify-project-wake.sh):
#   stall-watchdog.sh's own dedupe / owner-resolution / escalation ladder /
#   ack-stops-repeat, against a real scratch registry.
# Section B (python, imported-module pattern from verify-projects-status.sh):
#   hub.py's pure stall_watchdog_candidates() over all four signals, the
#   supplemental _stall_denied_and_delivered() query against a real scratch
#   registry, and _stall_watchdog_tick()'s own on/off switch — proof that
#   disabling the rule (STALL_WATCHDOG_SCRIPT unset) leaves the SAME
#   scenario silent, by in-memory monkeypatch, never git checkout/stash.
#
#   bash verify-stall-watchdog.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
_lc() { wc -l < "$1" 2>/dev/null | tr -d ' '; }   # BSD wc pads its count with spaces

# ═══════════════════════ Section A — stall-watchdog.sh ═══════════════════════
WORK="$(mktemp -d)"
export HERDR_RUN_STATE_DIR="$WORK/runs"
export SENT="$WORK/sent.log"
export NOTIFIED="$WORK/notified.log"
: > "$SENT"; : > "$NOTIFIED"

COND="w9:p1"; CONDB="w9term"
export COND CONDB
CM="$WORK/cond.txt"
export CM
printf ' $ \n ready\n' > "$CM"

herdr() {
  case "$1 $2" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"}]}}\n' "$COND" "$CONDB" ;;
    "pane read")
      cat "$CM" 2>/dev/null ;;
    "pane send-text")
      printf 'send-text %s\n' "$3" >> "$SENT"
      printf '%s' "$4" > "$WORK/wake_pending.txt" ;;
    "pane send-keys")
      printf 'send-keys %s %s\n' "$3" "$4" >> "$SENT"
      if [ "$4" = "Enter" ]; then
        { printf ' %s\n' "$(cat "$WORK/wake_pending.txt" 2>/dev/null)"
          printf '\n submitted\n $ \n ready\n'; } > "$CM"
      fi
      ;;
    *) return 0 ;;
  esac
}
export -f herdr

# A fake herdr-notify.sh: logs the class/pane/message it was called with,
# standing in for the "real alert path" (slack-bridge/herdr-notify.sh) so
# this suite never touches a Slack token.
NOTIFY_STUB="$WORK/herdr-notify-stub.sh"
cat > "$NOTIFY_STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NOTIFIED"
EOF
chmod +x "$NOTIFY_STUB"
export HERDR_STALL_WATCHDOG_NOTIFY="$NOTIFY_STUB"

. "$here/lib/run-registry.sh"
registry_init
_q() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$1" 2>/dev/null; }

echo "== A1: a reachable conductor — first wake sends once and records stall_wake =="
register_task runA taskA workerA condA "$COND" "$CONDB" paneA paneAbirth repo/x "$WORK/wtA" labelA >/dev/null
bash "$here/stall-watchdog.sh" wake taskA artifact "tmp/commit-msg.txt:1000" "ready 20m" "tmp/commit-msg.txt"
n_sent=$(grep -c "send-text $COND" "$SENT" || true)
[ "$n_sent" = "1" ] && ok "one send-text to the recorded conductor pane" || bad "expected 1 send-text, got $n_sent"
n_wake=$(_q "SELECT count(*) FROM events WHERE type='stall_wake' AND task_id='taskA';")
[ "$n_wake" = "1" ] && ok "one stall_wake claimed" || bad "expected 1 stall_wake event, got $n_wake"

echo "== A2: the identical fingerprint again, inside the owner's window — no repeat =="
: > "$SENT"; : > "$NOTIFIED"
bash "$here/stall-watchdog.sh" wake taskA artifact "tmp/commit-msg.txt:1000" "ready 20m" "tmp/commit-msg.txt"
[ "$(_lc "$SENT")" = "0" ] && ok "no second send for the unchanged fingerprint" || bad "sent again: $(cat "$SENT")"
[ "$(_lc "$NOTIFIED")" = "0" ] && ok "no escalation yet (still inside the owner's window)" || bad "escalated too early"

echo "== A3: acknowledged — stays silent even once the escalate window has passed =="
bash "$here/stall-ack.sh" taskA artifact >/dev/null
: > "$SENT"; : > "$NOTIFIED"
HERDR_STALL_WATCHDOG_ESCALATE_S=0 bash "$here/stall-watchdog.sh" wake taskA artifact "tmp/commit-msg.txt:1000" "ready 20m" "tmp/commit-msg.txt"
[ "$(_lc "$SENT")" = "0" ] && ok "acked: no re-wake" || bad "re-woke after ack"
[ "$(_lc "$NOTIFIED")" = "0" ] && ok "acked: no escalation — 'an acknowledged wake stops repeating'" || bad "escalated after ack"

echo "== A4: a genuinely NEW fingerprint (the artifact was rewritten) re-arms =="
: > "$SENT"
bash "$here/stall-watchdog.sh" wake taskA artifact "tmp/commit-msg.txt:2000" "ready 5m" "tmp/commit-msg.txt"
n_sent4=$(grep -c "send-text $COND" "$SENT" || true)
[ "$n_sent4" = "1" ] && ok "a new fingerprint for the same (task,signal) gets its own wake" || bad "expected 1 send, got $n_sent4"

echo "== A5: NOT acked, past the escalate window — escalates exactly once =="
: > "$SENT"; : > "$NOTIFIED"
HERDR_STALL_WATCHDOG_ESCALATE_S=0 bash "$here/stall-watchdog.sh" wake taskA artifact "tmp/commit-msg.txt:2000" "ready 5m" "tmp/commit-msg.txt"
n_notified=$(_lc "$NOTIFIED")
[ "$n_notified" = "1" ] && ok "exactly one real alert past the escalate window" || bad "expected 1 alert, got $n_notified"
grep -q "taskA" "$NOTIFIED" && grep -q "artifact" "$NOTIFIED" && grep -q "tmp/commit-msg.txt" "$NOTIFIED" \
  && ok "the alert names the task, the signal, and the exact artifact path" \
  || bad "alert text missing task/signal/artifact: $(cat "$NOTIFIED")"
: > "$NOTIFIED"
HERDR_STALL_WATCHDOG_ESCALATE_S=0 bash "$here/stall-watchdog.sh" wake taskA artifact "tmp/commit-msg.txt:2000" "ready 5m" "tmp/commit-msg.txt"
[ "$(_lc "$NOTIFIED")" = "0" ] && ok "no second escalation for the same fingerprint" || bad "escalated twice"

echo "== A6: owner UNKNOWN (no conductor pane recorded) — escalates immediately, never waits =="
register_task runB taskB workerB "" "" "" paneB paneBbirth repo/y "$WORK/wtB" labelB >/dev/null
: > "$SENT"; : > "$NOTIFIED"
bash "$here/stall-watchdog.sh" wake taskB handoff taskB-closed "closed handed_off_to:conductor"
[ "$(_lc "$SENT")" = "0" ] && ok "unknown owner: never attempts a wake (no pane to send to)" || bad "sent to no one: $(cat "$SENT")"
n_notB=$(_lc "$NOTIFIED")
[ "$n_notB" = "1" ] && ok "unknown owner: escalates on the same call — 'wake only' has nothing to wake" \
  || bad "expected 1 escalation for an unknown owner, got $n_notB"
grep -qi "unknown or unreachable" "$NOTIFIED" && ok "the escalation names why (no conductor configured)" \
  || bad "escalation text does not explain the unknown-owner reason"

echo "== A7: owner DEAD (registered conductor birth disagrees with the live one) — escalates too =="
register_task runC taskC workerC condC "$COND" "a-stale-birth-not-$CONDB" paneC paneCbirth repo/z "$WORK/wtC" labelC >/dev/null
: > "$SENT"; : > "$NOTIFIED"
bash "$here/stall-watchdog.sh" wake taskC denied approvalX "a deny was never followed up"
[ "$(_lc "$SENT")" = "0" ] && ok "recycled conductor pane: never sends into the wrong occupant" || bad "sent to a recycled pane"
[ "$(_lc "$NOTIFIED")" = "1" ] && ok "recycled conductor pane: escalates instead" || bad "did not escalate for a dead owner"

echo
echo "===== Section A ====="
printf 'passed=%d failed=%d\n' "$pass" "$fail"

# ═══════════════════════ Section B — hub.py detector ═════════════════════════
if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 not found — cannot exercise hub.py's stall_watchdog_candidates"
else
  PYFILE="$WORK/check_stall_watchdog.py"
  cat > "$PYFILE" <<'PYEOF'
import sys, json, importlib.util, os, sqlite3, subprocess

here = sys.argv[1]
spec = importlib.util.spec_from_file_location("hub", os.path.join(here, "hub.py"))
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)

results = {}
NOW = 1_767_300_000.0  # 2026-01-01T20:40:00Z — well after base_task()'s default
                       # updated_at (2026-01-01T00:00:00Z) by more than THRESH,
                       # so signal 1's real wall-clock comparison (now - since)
                       # actually lands positive instead of a 1970-epoch NOW
                       # racing a 2026 updated_at.
THRESH = 600.0

def base_task(**over):
    t = {"task_id": "t1", "run_id": "r1", "label": "widget", "pane_id": "p1",
         "conductor_pane_id": "c1", "conductor_pane_birth": "cb1",
         "worktree": "/nope", "state": "stalled", "stored_state": "stalled",
         "closure_reason": None, "updated_at": "2026-01-01T00:00:00Z"}
    t.update(over)
    return t

# ---- signal 1: handoff ------------------------------------------------------
t = base_task(state="completed", stored_state="completed", closure_reason="handed_off_to:conductor")
cands = hub.stall_watchdog_candidates([t], now=NOW, threshold_s=THRESH)
results["handoff_fires_on_terminal_handed_off_task"] = (
    len(cands) == 1 and cands[0]["signal"] == "handoff" and cands[0]["task_id"] == "t1")

# A plain completion (no handed_off_to:conductor reason) never fires signal 1.
t2 = base_task(state="completed", stored_state="completed", closure_reason="shipped")
results["handoff_silent_on_a_shipped_close"] = hub.stall_watchdog_candidates([t2], now=NOW, threshold_s=THRESH) == []

# ---- signal 2: artifact (injectable stat_fn — no real filesystem needed) ---
mtimes = {"/wt/tmp/commit-msg.txt": NOW - THRESH - 1}
t3 = base_task(state="ready_review", stored_state="running", worktree="/wt")
cands = hub.stall_watchdog_candidates([t3], now=NOW, threshold_s=THRESH,
                                      stat_fn=lambda p: mtimes.get(p))
results["artifact_fires_once_idle_past_threshold"] = any(
    c["signal"] == "artifact" and c["artifact"] == "tmp/commit-msg.txt" for c in cands)

# Just UNDER the threshold: not yet.
mtimes_fresh = {"/wt/tmp/commit-msg.txt": NOW - THRESH + 10}
cands = hub.stall_watchdog_candidates([t3], now=NOW, threshold_s=THRESH,
                                      stat_fn=lambda p: mtimes_fresh.get(p))
results["artifact_silent_before_threshold"] = cands == []

# A task still RUNNING (derived state, not just stored) never fires signal 2 —
# the worker might still be about to overwrite the very file being judged.
t4 = base_task(state="running", stored_state="running", worktree="/wt")
cands = hub.stall_watchdog_candidates([t4], now=NOW, threshold_s=THRESH,
                                      stat_fn=lambda p: mtimes.get(p))
results["artifact_silent_while_task_is_running"] = cands == []

# ---- signal 3: denied -------------------------------------------------------
t5 = base_task(state="stalled")
cands = hub.stall_watchdog_candidates(
    [t5], now=NOW, threshold_s=THRESH,
    denied={"t1": {"epoch": NOW - THRESH - 5, "fingerprint": "appr_1"}})
results["denied_fires_when_idle_after_a_deny"] = any(c["signal"] == "denied" for c in cands)
# A task that resumed working after the deny (state != stalled) never fires.
t5b = base_task(state="running")
cands = hub.stall_watchdog_candidates(
    [t5b], now=NOW, threshold_s=THRESH,
    denied={"t1": {"epoch": NOW - THRESH - 5, "fingerprint": "appr_1"}})
results["denied_silent_once_worker_resumed"] = cands == []

# ---- signal 4: unprocessed ---------------------------------------------------
t6 = base_task(state="stalled")
cands = hub.stall_watchdog_candidates(
    [t6], now=NOW, threshold_s=THRESH,
    delivered={"t1": {"epoch": NOW - THRESH - 5, "fingerprint": "42"}})
results["unprocessed_fires_when_idle_after_delivery"] = any(c["signal"] == "unprocessed" for c in cands)

# ---- _stall_denied_and_delivered(): real scratch registry -------------------
db_dir = os.path.join(os.environ["WORK"], "runs2")
os.makedirs(db_dir, exist_ok=True)
hub.REGISTRY = __import__("pathlib").Path(db_dir) / "registry.sqlite3"
# Reuses the bash half's run-registry.sh to build a REAL schema, so this is
# not a hand-rolled table shape that could drift from the real one.
subprocess.run(
    ["bash", "-c",
     f". '{here}/lib/run-registry.sh'; HERDR_RUN_STATE_DIR='{db_dir}' registry_init"],
    check=True)
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO approvals (approval_id, task_id, policy_verdict, choice_text, decided_at) "
             "VALUES ('appr_x','dtask','deny','2. Deny','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('ev1','drun','dtask','message_delivered','2026-01-01T00:00:00Z','{}')")
conn.commit(); conn.close()
denied, delivered = hub._stall_denied_and_delivered()
results["denied_query_finds_the_real_deny_row"] = denied.get("dtask", {}).get("fingerprint") == "appr_x"
results["delivered_query_finds_an_unprocessed_message"] = "dtask" in delivered

# A later event from the SAME task (real worker activity) clears "unprocessed".
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('ev2','drun','dtask','worker_progress','2026-01-01T00:05:00Z','{}')")
conn.commit(); conn.close()
_, delivered2 = hub._stall_denied_and_delivered()
results["delivered_cleared_once_the_worker_did_something"] = "dtask" not in delivered2

# ---- _stall_watchdog_tick(): the in-memory on/off switch --------------------
calls = []
real_run = hub.subprocess.run
def fake_run(argv, **kw):
    calls.append(argv)
    class R: returncode = 0
    return R()
hub.subprocess.run = fake_run

class FakeCache:
    def __init__(self, data): self._data = data
    def get(self): return self._data

fake_herdr = {"tasks": [base_task(state="completed", stored_state="completed",
                                  closure_reason="handed_off_to:conductor",
                                  updated_at="2020-01-01T00:00:00Z")]}
hub.CACHES["herdr"] = FakeCache(fake_herdr)

# "removed" — the in-memory equivalent of the rule not existing: point the
# script path at nothing and confirm the exact same scenario stays silent.
real_script = hub.STALL_WATCHDOG_SCRIPT
hub.STALL_WATCHDOG_SCRIPT = __import__("pathlib").Path("/does/not/exist")
hub._stall_watchdog_tick()
results["rule_removed_stays_silent_on_a_real_candidate"] = calls == []

# restored — the same scenario now fires.
hub.STALL_WATCHDOG_SCRIPT = real_script
hub._stall_watchdog_tick()
results["rule_restored_fires_on_the_same_candidate"] = (
    len(calls) == 1 and calls[0][2] == "wake" and calls[0][3] == "t1" and calls[0][4] == "handoff")

hub.subprocess.run = real_run

print(json.dumps(results))
PYEOF
  export WORK
  if ! py_out="$(python3 "$PYFILE" "$here")"; then
    bad "hub.py check block crashed — every stall_watchdog_candidates case is unverified"
    py_out='{}'
  fi
  echo "$py_out" | python3 -c "
import json, sys
r = json.loads(sys.stdin.read().strip().splitlines()[-1])
for k, v in r.items():
    print((\"ok\" if v else \"FAIL\") + \"\t\" + k)
" | while IFS=$'\t' read -r st name; do
    if [ "$st" = ok ]; then printf '  ok    %s\n' "$name"; else printf '  FAIL  %s\n' "$name"; fi
  done
  extra_pass=$(echo "$py_out" | python3 -c "import json,sys; r=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(sum(1 for v in r.values() if v))")
  extra_fail=$(echo "$py_out" | python3 -c "import json,sys; r=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(sum(1 for v in r.values() if not v))")
  pass=$((pass + extra_pass)); fail=$((fail + extra_fail))
fi

rm -rf "$WORK"
echo
echo "===== VERIFY ====="
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
