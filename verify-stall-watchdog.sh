#!/usr/bin/env bash
# verify-stall-watchdog.sh — .handoffs/SPEC.md (feat/stall-watchdog).
# Hermetic: no live herdr, no live panes, no network, no real registry.
#
# Section A (bash, stub-herdr pattern from verify-project-wake.sh):
#   stall-watchdog.sh's own dedupe / owner-resolution / escalation ladder /
#   ack-stops-repeat, against a real scratch registry.
# Section B (python, imported-module pattern from verify-projects-status.sh):
#   hub.py's pure stall_watchdog_candidates() over all five signals, the
#   supplemental _stall_task_signals() query against a real scratch
#   registry, and _stall_watchdog_tick()'s own on/off switch — proof that
#   disabling the rule (STALL_WATCHDOG_SCRIPT unset) leaves the SAME
#   scenario silent, by in-memory monkeypatch, never git checkout/stash.
# Section C (python, DESIGN-228 §7 R1–R29): signal 5's request/answer fold
#   on the REAL path — `_stall_watchdog_tick` → `_stall_task_signals` →
#   `stall_watchdog_candidates` → the fold, on 15s ticks against a scratch
#   registry per scenario, with the real writers (register_task,
#   set_task_state, append_event, send-to-agent.sh, stall-watchdog.sh wake,
#   stall-ack.sh, herdr-action.sh) run under a stub `herdr` and a `date`
#   pinned to the simulated clock. Same-signature reverts fail by outcome.
#
#   bash verify-stall-watchdog.sh
#   VSW_SECTIONS=C SC_ONLY=R6a,R23b bash verify-stall-watchdog.sh   # a subset
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
_lc() { wc -l < "$1" 2>/dev/null | tr -d ' '; }   # BSD wc pads its count with spaces
_on() { [[ "${VSW_SECTIONS:-ABC}" == *"$1"* ]]; }
# A python section's JSON result line (the LAST stdout line) as ok/FAIL rows.
_tally() {
  local st name
  while IFS=$'\t' read -r st name; do
    [ -n "$name" ] || continue
    if [ "$st" = ok ]; then ok "$name"; else bad "$name"; fi
  done < <(printf '%s' "$1" | python3 -c '
import json, sys
lines = sys.stdin.read().strip().splitlines()
for k, v in (json.loads(lines[-1]) if lines else {}).items():
    print(("ok" if v else "FAIL") + "\t" + k)
')
}

# ═══════════════════════ Section A — stall-watchdog.sh ═══════════════════════
WORK="$(mktemp -d)"
export WORK
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
      [ -e "$WORK/herdr_down" ] && return 1
      [ -e "$WORK/cond_pane_gone" ] && return 1
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    "pane list")
      [ -e "$WORK/herdr_down" ] && return 1
      if [ -e "$WORK/cond_pane_gone" ]; then
        printf '{"result":{"panes":[]}}\n'
      else
        printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"}]}}\n' "$COND" "$CONDB"
      fi ;;
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

if _on A; then
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

echo "== A8 (review H2): the owner acted (messaged the worker) but never ran stall-ack — must not escalate =="
register_task runD taskD workerD condD "$COND" "$CONDB" paneD paneDbirth repo/d "$WORK/wtD" labelD >/dev/null
: > "$SENT"; : > "$NOTIFIED"
bash "$here/stall-watchdog.sh" wake taskD artifact "tmp/REVIEW.md:7" "ready" "tmp/REVIEW.md"
sleep 1.2
_sql_runD() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$1" 2>/dev/null; }
_sql_runD "INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload)
  VALUES ('ev_ownerD','runD','taskD','owner_acted','$(date -u +%Y-%m-%dT%H:%M:%SZ)','{}');"
: > "$SENT"; : > "$NOTIFIED"
HERDR_STALL_WATCHDOG_ESCALATE_S=0 bash "$here/stall-watchdog.sh" wake taskD artifact "tmp/REVIEW.md:7" "ready" "tmp/REVIEW.md"
[ "$(_lc "$NOTIFIED")" = "0" ] && ok "H2: owner_acted after the wake counts as handled — no escalation without stall-ack" \
  || bad "H2 REGRESSION: escalated despite owner_acted — $(cat "$NOTIFIED")"

echo "== A9 (review H3): an ack survives the conductor pane later going away — no re-escalation =="
register_task runE taskE workerE condE "$COND" "$CONDB" paneE paneEbirth repo/e "$WORK/wtE" labelE >/dev/null
: > "$SENT"; : > "$NOTIFIED"
bash "$here/stall-watchdog.sh" wake taskE artifact "tmp/commit-msg.txt:999" "ready" "tmp/commit-msg.txt"
first_sentE=$(grep -c "send-text $COND" "$SENT" || true)
sleep 1.2
bash "$here/stall-ack.sh" taskE artifact >/dev/null
touch "$WORK/cond_pane_gone"
: > "$SENT"; : > "$NOTIFIED"
HERDR_STALL_WATCHDOG_ESCALATE_S=0 bash "$here/stall-watchdog.sh" wake taskE artifact "tmp/commit-msg.txt:999" "ready" "tmp/commit-msg.txt"
rm -f "$WORK/cond_pane_gone"
[ "$first_sentE" = "1" ] && [ "$(_lc "$NOTIFIED")" = "0" ] && ok "H3: acked wake stays silent even once the conductor pane is gone" \
  || bad "H3 REGRESSION: first_sent=$first_sentE notified=$(_lc "$NOTIFIED") — acked wake re-escalated after the pane vanished"

echo "== A10 (review H3): a transient herdr outage on first sighting must SKIP, not escalate =="
register_task runF taskF workerF condF "$COND" "$CONDB" paneF paneFbirth repo/f "$WORK/wtF" labelF >/dev/null
: > "$SENT"; : > "$NOTIFIED"
touch "$WORK/herdr_down"
bash "$here/stall-watchdog.sh" wake taskF handoff fpF "closed handed_off_to:conductor"
a1=$(_lc "$NOTIFIED"); s1=$(_lc "$SENT")
rm -f "$WORK/herdr_down"
bash "$here/stall-watchdog.sh" wake taskF handoff fpF "closed handed_off_to:conductor"
[ "$a1" = "0" ] && [ "$s1" = "0" ] && [ "$(grep -c "send-text $COND" "$SENT" || true)" = "1" ] \
  && ok "H3: herdr-unreachable on first sighting skips silently, then wakes normally once herdr recovers" \
  || bad "H3 REGRESSION: while-down alerts=$a1 sends=$s1; after recovery sends=$(grep -c "send-text $COND" "$SENT" || true)"

echo "== A11 (review N4): an unsubmitted (typed) send is never retried into the composer =="
register_task runG taskG workerG condG "$COND" "$CONDB" paneG paneGbirth repo/g "$WORK/wtG" labelG >/dev/null
UNSUB_STUB="$WORK/unsub-send-stub.sh"
cat > "$UNSUB_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'send-text %s\n' "$1" >> "$SENT"
echo "UNSUBMITTED: $1 composer looked unchanged after 6 Enters — the text was delivered but NOT submitted; finish it by hand." >&2
exit 4
EOF
chmod +x "$UNSUB_STUB"
: > "$SENT"; : > "$NOTIFIED"
HERDR_STALL_WATCHDOG_SEND="$UNSUB_STUB" bash "$here/stall-watchdog.sh" wake taskG artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
HERDR_STALL_WATCHDOG_SEND="$UNSUB_STUB" bash "$here/stall-watchdog.sh" wake taskG artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
HERDR_STALL_WATCHDOG_SEND="$UNSUB_STUB" bash "$here/stall-watchdog.sh" wake taskG artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
n_sentG=$(grep -c "send-text $COND" "$SENT" || true)
[ "$n_sentG" = "1" ] && ok "N4: an UNSUBMITTED (already-typed) send is never retried — 1 send-text across 3 ticks" \
  || bad "N4 REGRESSION: expected 1 send-text total across 3 ticks, got $n_sentG"

echo
echo "===== Section A ====="
printf 'passed=%d failed=%d\n' "$pass" "$fail"
fi

# ═══════════════════════ Section B — hub.py detector ═════════════════════════
if ! _on B; then
  :
elif ! command -v python3 >/dev/null 2>&1; then
  bad "python3 not found — cannot exercise hub.py's stall_watchdog_candidates"
else
  PYFILE="$WORK/check_stall_watchdog.py"
  cat > "$PYFILE" <<'PYEOF'
import sys, json, importlib.util, os, sqlite3, subprocess, time, textwrap, inspect

here = sys.argv[1]
spec = importlib.util.spec_from_file_location("hub", os.path.join(here, "hub.py"))
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)
# Nothing below may ever reach the operator's live registry (hub.REGISTRY's
# default): point it at a path that does not exist until the scratch
# registry further down is built.
hub.REGISTRY = __import__("pathlib").Path(os.environ["WORK"]) / "no-registry-yet" / "registry.sqlite3"

results = {}
NOW = 1_767_300_000.0  # 2026-01-01T20:40:00Z — well after base_task()'s default
                       # updated_at (2026-01-01T00:00:00Z) by more than THRESH,
                       # so signal 1's real wall-clock comparison (now - since)
                       # actually lands positive instead of a 1970-epoch NOW
                       # racing a 2026 updated_at.
THRESH = 600.0
BOOT = NOW - 100_000.0   # review H1: every evidence epoch below is constructed
                        # relative to NOW, comfortably after this fixed boot
                        # floor, so passing it explicitly isolates every
                        # existing case from H1's OWN dedicated tests further
                        # down (which move it instead of the evidence).

def base_task(**over):
    t = {"task_id": "t1", "run_id": "r1", "label": "widget", "pane_id": "p1",
         "pane_birth": "pb1", "conductor_pane_id": "c1", "conductor_pane_birth": "cb1",
         "worktree": "/nope", "state": "stalled", "stored_state": "stalled",
         "closure_reason": None, "updated_at": "2026-01-01T00:00:00Z"}
    t.update(over)
    return t

def cw(now_epoch, reason=None, is_last=True, mtime=None):   # stub live_done_fn:
    return lambda worktree: (now_epoch, reason, is_last, mtime)  # constant (epoch, reason, is_last, mtime)

# DESIGN-228: `occurrence_fn` defaults to the registry fold
# (`_stall_cprompt_sight`) — every fixture below that only cares about
# fingerprint/pane-shape behavior (not answer state) passes a NEW, unanswered
# occurrence instead, so it never touches a registry at all. The fold itself
# is exercised for real in Section C.
NEW_OCC = lambda tid, req, now: {"gen": 1, "first_seen": 0.0, "answered": False}

def _safe_candidates(label, *a, **kw):
    """Review L1 (d): isolate a crash in ONE `stall_watchdog_candidates`
    call (e.g. a `replied=`-shape mutation) to its OWN result key, so it
    never takes the rest of Section B down with it -- same reasoning as
    `_run_mutant` below, generalized to calls outside that loop.

    Review L1 (r7): records the crash as the BOOLEAN `False`, never a
    message string -- a non-empty string is truthy, so the bash runner's
    own `sum(1 for v in r.values() if v)` counted every crash as `ok`.
    The diagnostic still prints, to stderr, where it helps debugging
    without being read as a passing result."""
    try:
        return hub.stall_watchdog_candidates(*a, **kw)
    except Exception as exc:
        results[f"{label}_CRASHED"] = False
        print(f"{label}_CRASHED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return []


def _safe_signals3(label, **kw):
    """Review L1 (d): isolate a `_stall_task_signals` arity/shape change
    to the ONE call site that unpacks it, instead of raising out of this
    whole inline script -- round-2's M3 failure mode, reopened by r3's own
    L1 (reverting the arity fix crashed with 0 keys surviving).

    Review L1 (r7): records `False`, not a truthy string -- see
    `_safe_candidates`."""
    try:
        denied_, delivered_, owner_acted_ = hub._stall_task_signals(**kw)
        return denied_, delivered_, owner_acted_
    except Exception as exc:
        results[f"{label}_CRASHED"] = False
        print(f"{label}_CRASHED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return {}, {}, {}


def _safe_tick(label):
    """Review L1: `_stall_watchdog_tick()` itself was called unwrapped --
    a shape change anywhere in its own call graph (`_stall_task_signals`,
    `stall_watchdog_candidates`, `_sw_resolved_keys`) would crash the rest
    of Section B along with it. Same isolation as `_safe_candidates`."""
    try:
        hub._stall_watchdog_tick()
    except Exception as exc:
        results[f"{label}_CRASHED"] = False
        print(f"{label}_CRASHED: {type(exc).__name__}: {exc}", file=sys.stderr)


# ---- signal 1: handoff (review N1/N2: live bus ONLY, IDLE_STATES ONLY) ------
t_live = base_task(state="ready_review", stored_state="running", closure_reason=None, worktree="/wt-live")
cands = hub.stall_watchdog_candidates(
    [t_live], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(NOW - THRESH - 30, "handed_off_to:conductor"))
results["handoff_fires_from_the_live_bus_while_idle"] = any(c["signal"] == "handoff" for c in cands)

# review N1/N2: the SAME live-bus evidence on a task the conductor has
# since CLOSED (`completed`) must never fire — closing it IS the action
# owed, and this is exactly how the old registry-path branch double-fired
# on the close itself.
t_closed = base_task(state="completed", stored_state="completed", closure_reason="handed_off_to:conductor",
                     worktree="/wt-live")
cands = hub.stall_watchdog_candidates(
    [t_closed], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(NOW - THRESH - 30, "handed_off_to:conductor"))
results["N1_N2_handoff_silent_once_the_task_is_completed"] = cands == []

# A plain completion (no handed_off_to:conductor reason on the live bus)
# never fires signal 1.
t2 = base_task(state="ready_review", stored_state="running", worktree="/wt-live")
cands = hub.stall_watchdog_candidates(
    [t2], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(NOW - THRESH - 30, "shipped"))
results["handoff_silent_on_a_shipped_close"] = cands == []

# ---- review H5: handoff variants other than the exact literal must ALSO fire -
for reason in ("handed_off_to:conductor", "handed_off_to: conductor", "handed_off_to:w4P:p1",
               "handed_off_to:conductor-merge", "handed_off_to:Main", "handed_off_to:review"):
    th = base_task(state="ready_review", stored_state="running", worktree="/wt-live")
    cands = hub.stall_watchdog_candidates(
        [th], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
        live_done_fn=cw(NOW - THRESH - 30, reason))
    results[f"H5_handoff_fires_for[{reason}]"] = any(c["signal"] == "handoff" for c in cands)
# A reason that merely CONTAINS the word is not a handoff.
th2 = base_task(state="ready_review", stored_state="running", worktree="/wt-live")
cands = hub.stall_watchdog_candidates(
    [th2], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(NOW - THRESH - 30, "shipped, handed_off_to is a misnomer"))
results["H5_handoff_silent_on_a_reason_that_only_mentions_the_word"] = cands == []

# ---- review H5: incident 1's exact shape — pane still alive, registry row
# never promoted to `completed` (derives ready_review, closure_reason=None),
# but the worker's OWN worktree bus already has the handoff written.
results["H5_incident1_live_bus_shape_fires"] = results["handoff_fires_from_the_live_bus_while_idle"]
# Still `running` (genuinely active, not idle) -> never consult the live bus.
t_live_running = base_task(state="running", stored_state="running", closure_reason=None, worktree="/wt-live")
cands = hub.stall_watchdog_candidates(
    [t_live_running], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(NOW - THRESH - 30, "handed_off_to:conductor"))
results["H5_live_bus_never_consulted_while_genuinely_running"] = cands == []

# ---- review H1: a deploy must never wake on evidence OLDER than the watchdog
# itself existing to watch it.
t_old = base_task(state="ready_review", stored_state="running", worktree="/wt-live")
cands = hub.stall_watchdog_candidates(
    [t_old], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(BOOT - 10, "handed_off_to:conductor"))
results["H1_boot_epoch_floor_silences_pre_existing_evidence"] = cands == []

# ---- SPEC.md item 1: a re-used worktree's round-N `_done` line must not
# fire for round N+1's task. created_at floors evidence the same way boot
# does -- a task registered AT T with live-bus evidence from BEFORE T
# (round N's own close) is silent; the identical shape with evidence AFTER
# T (this round's own close) still fires.
t_reused_before = base_task(state="ready_review", stored_state="running", worktree="/wt-live",
                            created_at="2026-01-01T19:00:00Z")   # T
cands = hub.stall_watchdog_candidates(
    [t_reused_before], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(hub._iso_epoch("2026-01-01T18:59:59Z"), "handed_off_to:conductor"))  # T-1
results["item1_handoff_silent_on_a_prior_rounds_done_line_predating_this_task"] = cands == []
t_reused_after = base_task(state="ready_review", stored_state="running", worktree="/wt-live",
                           created_at="2026-01-01T19:00:00Z")   # T
cands = hub.stall_watchdog_candidates(
    [t_reused_after], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(hub._iso_epoch("2026-01-01T19:00:01Z"), "handed_off_to:conductor"))  # T+1
results["item1_handoff_still_fires_on_this_rounds_own_done_line"] = any(
    c["signal"] == "handoff" for c in cands)

# ---- review r6 M1: clock skew -- the worker's own `ts` stamped 4h early
# must not drop a handoff that genuinely landed after this round's own
# registration. `_live_done_info` now also reports done_is_last/mtime; the
# task_start floor accepts the APPEND time (mtime, only when the `_done`
# line is the file's own last line) as an alternative to the worker-written
# `ts` -- a real -4h/mtime-pr-223-r3-shaped skew on this machine.
T_SKEW = hub._iso_epoch("2026-01-01T19:00:00Z")           # task registered at T
t_skew = base_task(state="ready_review", stored_state="running", worktree="/wt-live",
                   created_at="2026-01-01T19:00:00Z")
cands = hub.stall_watchdog_candidates(
    [t_skew], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(T_SKEW + 1800 - 4 * 3600, "handed_off_to:conductor",
                   is_last=True, mtime=T_SKEW + 1800))     # ts=T-3h30m, appended at T+30m
results["M1_skewed_ts_still_fires_when_the_append_mtime_is_after_task_start"] = any(
    c["signal"] == "handoff" for c in cands)
# Same skewed ts, but the `_done` line is NOT the file's last line (some
# later non-done write set the mtime) -- the mtime cannot be trusted to
# date the append, so it must not be used to clear the floor.
cands = hub.stall_watchdog_candidates(
    [t_skew], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    live_done_fn=cw(T_SKEW + 1800 - 4 * 3600, "handed_off_to:conductor",
                   is_last=False, mtime=T_SKEW + 1800))
results["M1_mtime_ignored_when_the_done_line_is_not_the_files_last_line"] = cands == []

# ---- signal 2: artifact (injectable stat_fn — no real filesystem needed) ----
# stat_fn now returns (size, mtime): review H1's empty-file / owner-action gates.
mtimes = {"/wt/tmp/commit-msg.txt": (400, NOW - THRESH - 1)}
t3 = base_task(state="ready_review", stored_state="running", worktree="/wt")
cands = hub.stall_watchdog_candidates([t3], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                                      stat_fn=lambda p: mtimes.get(p, (0, None)))
results["artifact_fires_once_idle_past_threshold"] = any(
    c["signal"] == "artifact" and c["artifact"] == "tmp/commit-msg.txt" for c in cands)

# Just UNDER the threshold: not yet.
mtimes_fresh = {"/wt/tmp/commit-msg.txt": (400, NOW - THRESH + 10)}
cands = hub.stall_watchdog_candidates([t3], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                                      stat_fn=lambda p: mtimes_fresh.get(p, (0, None)))
results["artifact_silent_before_threshold"] = cands == []

# A task still RUNNING (derived state, not just stored) never fires signal 2 —
# the worker might still be about to overwrite the very file being judged.
t4 = base_task(state="running", stored_state="running", worktree="/wt")
cands = hub.stall_watchdog_candidates([t4], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                                      stat_fn=lambda p: mtimes.get(p, (0, None)))
results["artifact_silent_while_task_is_running"] = cands == []

# ---- review N1: the NORMAL way a conductor handles a task — read the
# artifact, close it — must never wake 10 minutes later. Same qualifying
# artifact as above, task now `completed`.
t_done = base_task(state="completed", stored_state="completed", closure_reason="shipped", worktree="/wt")
cands = hub.stall_watchdog_candidates([t_done], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                                      stat_fn=lambda p: mtimes.get(p, (0, None)))
results["N1_artifact_silent_once_the_task_is_completed"] = cands == []

# ---- review H1: the 0-byte PROOF.md spawn-task.sh creates in EVERY worktree
# must never fire, independent of the N1 completed-state gate above (this
# fixture stays `ready_review` to isolate the size check itself).
mtimes_empty = {"/wt/.handoffs/PROOF.md": (0, NOW - THRESH - 1)}
t3b = base_task(state="ready_review", stored_state="running", worktree="/wt")
cands = hub.stall_watchdog_candidates([t3b], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                                      stat_fn=lambda p: mtimes_empty.get(p, (0, None)))
results["H1_empty_artifact_never_fires"] = cands == []

# ---- review H1: newer than the conductor's OWN last action on the task —
# the owner already acted AFTER the artifact was written, so it must not fire.
cands = hub.stall_watchdog_candidates(
    [t3], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    stat_fn=lambda p: mtimes.get(p, (0, None)),
    owner_acted={"t1": NOW - THRESH + 100})   # acted AFTER the file's mtime
results["H1_artifact_silent_once_owner_already_acted"] = cands == []
# Owner acted BEFORE the artifact was (re)written: still fires.
cands = hub.stall_watchdog_candidates(
    [t3], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    stat_fn=lambda p: mtimes.get(p, (0, None)),
    owner_acted={"t1": NOW - THRESH - 1000})  # acted BEFORE the file's mtime
results["artifact_still_fires_when_owner_action_predates_the_file"] = any(
    c["signal"] == "artifact" for c in cands)

# ---- review L4 (opportunistic, fixed alongside H1): at most ONE artifact
# candidate per task, even with several qualifying files.
mtimes_multi = {"/wtm/tmp/commit-msg.txt": (10, NOW - THRESH - 500),
               "/wtm/tmp/REVIEW.md": (10, NOW - THRESH - 50),
               "/wtm/.handoffs/PROOF.md": (10, NOW - THRESH - 5)}
t3c = base_task(state="ready_review", stored_state="running", worktree="/wtm")
cands = hub.stall_watchdog_candidates([t3c], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                                      stat_fn=lambda p: mtimes_multi.get(p, (0, None)))
results["at_most_one_artifact_candidate_per_task"] = (
    sum(1 for c in cands if c["signal"] == "artifact") == 1)

# ---- review M2 (r4): debounce on the newest write. The old per-file
# threshold gate picked the newest artifact that had ALREADY aged past
# threshold -- so an older artifact (commit-msg.txt) could fire its OWN
# wake while a genuinely newer one (PROOF.md) was still too fresh to
# qualify, then fire AGAIN with a different fingerprint the moment
# PROOF.md itself aged past threshold: two wakes for one handoff. The fix
# picks the newest-by-mtime qualifier FIRST and gates threshold only on
# that single pick, so the older file is never its own candidate while a
# newer one exists.
mtimes_debounce = {"/wtd/tmp/commit-msg.txt": (10, NOW - THRESH - 50),   # already past threshold
                   "/wtd/.handoffs/PROOF.md": (10, NOW - THRESH + 10)}  # newer, NOT yet past threshold
t3d = base_task(state="ready_review", stored_state="running", worktree="/wtd")
cands = hub.stall_watchdog_candidates([t3d], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                                      stat_fn=lambda p: mtimes_debounce.get(p, (0, None)))
results["M2_r4_newer_not_yet_stale_artifact_suppresses_the_older_ones_wake"] = cands == []

# ---- SPEC.md item 2: round N+1's task must not qualify on round N's own
# PROOF.md left behind in the re-used worktree. A task registered at T with
# an artifact mtime from BEFORE T is silent; the identical shape with an
# mtime AFTER T still fires -- same created_at floor as item 1, this time
# on signal 2.
mtimes_item2_before = {"/wti/.handoffs/PROOF.md": (10, hub._iso_epoch("2026-01-01T18:59:59Z"))}  # T-1
t_item2_before = base_task(state="ready_review", stored_state="running", worktree="/wti",
                           created_at="2026-01-01T19:00:00Z")   # T
cands = hub.stall_watchdog_candidates([t_item2_before], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                                      stat_fn=lambda p: mtimes_item2_before.get(p, (0, None)))
results["item2_artifact_silent_on_a_prior_rounds_file_predating_this_task"] = cands == []
mtimes_item2_after = {"/wti/.handoffs/PROOF.md": (10, hub._iso_epoch("2026-01-01T19:00:01Z"))}  # T+1
t_item2_after = base_task(state="ready_review", stored_state="running", worktree="/wti",
                          created_at="2026-01-01T19:00:00Z")   # T
cands = hub.stall_watchdog_candidates([t_item2_after], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                                      stat_fn=lambda p: mtimes_item2_after.get(p, (0, None)))
results["item2_artifact_still_fires_on_this_rounds_own_file"] = any(
    c["signal"] == "artifact" for c in cands)

# ---- signal 3: denied --------------------------------------------------------
t5 = base_task(state="stalled")
cands = hub.stall_watchdog_candidates(
    [t5], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    denied={"t1": {"epoch": NOW - THRESH - 5, "fingerprint": "appr_1"}})
results["denied_fires_when_idle_after_a_deny"] = any(c["signal"] == "denied" for c in cands)
# A task that resumed working after the deny (state != stalled) never fires.
t5b = base_task(state="running")
cands = hub.stall_watchdog_candidates(
    [t5b], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    denied={"t1": {"epoch": NOW - THRESH - 5, "fingerprint": "appr_1"}})
results["denied_silent_once_worker_resumed"] = cands == []

# ---- signal 4: unprocessed ---------------------------------------------------
t6 = base_task(state="stalled")
cands = hub.stall_watchdog_candidates(
    [t6], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    delivered={"t1": {"epoch": NOW - THRESH - 5, "fingerprint": "42"}})
results["unprocessed_fires_when_idle_after_delivery"] = any(c["signal"] == "unprocessed" for c in cands)

# ---- review M1/N3: incident 2's shape against a REALISTIC omp pane. The
# composer box (`╭...╮` top border) sits BELOW the agent's own last output
# line — the literal last row of a real `herdr pane read` is the box, never
# the CONDUCTOR: line (review N3; `lib/prompt-parse.sh:355-361`,
# `verify-typing-guard.sh:156-172`). review M-b: also requires the live
# pane's birth to still match what this task registered.
CHROME = ("an earlier line of agent output\n"
         "CONDUCTOR: approve request ar_7 or tell me why not\n"
         "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 42% \u2500\u2500\u256e\n"
         "\u2502 >                                          \u2502\n"
         "\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n")
CHROME_NO_PROMPT = ("an earlier line of agent output\n"
                    "ready\n"
                    "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 42% \u2500\u2500\u256e\n"
                    "\u2502 >                                          \u2502\n"
                    "\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n")
t7 = base_task(state="stalled", stored_state="stalled", pane_id="p1", pane_birth="pb1",
               updated_at="2026-01-01T00:00:00Z")
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
results["N3_conductor_prompt_fires_against_realistic_omp_chrome"] = any(
    c["signal"] == "conductor_prompt" for c in cands)
# The naive "literal last row" check this replaces would see the composer's
# own closing border as the last line and never match — proven directly.
results["N3_last_row_of_raw_chrome_is_not_the_conductor_line"] = (
    not hub._cp.ANSI_RE.sub("", CHROME).splitlines()[-2].strip().startswith("CONDUCTOR:"))
# Ordinary scrollback with no such line never fires it.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_NO_PROMPT, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
results["M1_silent_without_a_conductor_line"] = cands == []
# A task state outside (stalled, ready_review) never reads the pane at all —
# review N1/M-b's state-allowlist (`lost`/`cancelled`/`gone` used to be
# included via `state != "completed"`).
t7_gone = base_task(state="gone", stored_state="gone", pane_id="p1", pane_birth="pb1",
                    updated_at="2026-01-01T00:00:00Z")
cands = hub.stall_watchdog_candidates(
    [t7_gone], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
results["Mb_conductor_prompt_silent_outside_idle_states"] = cands == []
# review M-b: the live pane's birth no longer matches what this task
# registered (herdr recycled the pane id to an unrelated task) -> silent,
# even with a real CONDUCTOR: line sitting there.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "some-other-birth", occurrence_fn=NEW_OCC)
results["Mb_conductor_prompt_silent_on_a_recycled_pane"] = cands == []
# Live birth unknown (LIVE disconnected, or herdr never answered) -> fails
# closed, same reasoning.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: None, occurrence_fn=NEW_OCC)
results["Mb_conductor_prompt_silent_when_birth_cannot_be_confirmed"] = cands == []

# ---- review H1 (r4): the hard-coded 20-row read window drops the exact
# request this signal exists to catch, in a REAL 46-column omp pane: a
# wrapped request plus omp's own recap block fills the usable output rows
# above the composer, so the `CONDUCTOR:` row itself scrolls out of a
# 20-row tail. Built from the real word-wrap (textwrap, width=46 -- the
# live review's own pane width) over enough filler scrollback that the
# dump exceeds both the old and the new window, then SLICED exactly the
# way `herdr pane read --lines N` slices a live pane (the last N rows) --
# not a hand-cut fixture -- so this reads hub._pane_last_output's OWN
# configured window size rather than asserting a bare number.
PANE_WIDTH_46 = 46
_h1_filler = [f"an earlier line of agent output {i}" for i in range(60)]
_h1_request = textwrap.wrap(
    "CONDUCTOR: the migration touches the production billing table and a "
    "wrong write cannot be rolled back automatically once it runs against "
    "real customer rows, so please confirm the maintenance window and the "
    "rollback plan before I actually execute it against the live database "
    "tonight, and I want explicit confirmation rather than silence because "
    "the webhook already retried three times and a fourth attempt during "
    "the window could double-charge every customer in the affected cohort",
    width=PANE_WIDTH_46)
_h1_recap = textwrap.wrap(
    "Recap: schema diff reviewed, dry run against the staging clone came "
    "back clean, and the rollback script is written and tested -- only "
    "your go-ahead for the maintenance window is pending now, along with "
    "sign-off from whoever owns the billing on-call rotation this week "
    "since the rollback also touches their alerting thresholds",
    width=PANE_WIDTH_46)
_h1_chrome = ["\u256d" + "\u2500" * 44 + "\u256e",
             "\u2502" + " " * 44 + "\u2502",
             "\u2570" + "\u2500" * 44 + "\u256f"]
_h1_tail = _h1_request + [""] + _h1_recap + _h1_chrome
_h1_full = _h1_filler + _h1_tail
_h1_default_lines = inspect.signature(hub._pane_last_output).parameters["lines"].default
results["H1_fixture_tail_exceeds_the_old_20row_budget"] = len(_h1_tail) > 20
results["H1_fixture_tail_fits_within_the_new_window"] = len(_h1_tail) <= _h1_default_lines
_h1_window_default = "\n".join(_h1_full[-_h1_default_lines:])
_h1_window_20 = "\n".join(_h1_full[-20:])
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: _h1_window_default, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
results["H1_46col_wrapped_request_plus_recap_fires_in_the_real_window"] = any(
    c["signal"] == "conductor_prompt" for c in cands)
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: _h1_window_20, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
results["H1_the_old_20row_window_would_have_missed_it"] = not any(
    c["signal"] == "conductor_prompt" for c in cands)

# ---- review M2 (r5): `--source visible` caps at the pane's LIVE SCREEN
# HEIGHT, never at `--lines` -- measured live: 29-35 rows on every
# 46-column w5B pane for BOTH `--lines 60` and `--lines 200`, so the
# window the H1 fixture above exercises can never actually arrive on a
# real narrow/short pane. `--source recent` returns exactly `--lines`
# rows regardless of screen height (measured live: 60 of 60, 200 of 200
# on the same panes). Captured via a real subprocess.run monkeypatch, not
# a source-text grep, so this proves the actual call hub.py makes.
_m2_calls = []
_m2_real_run = hub.subprocess.run
def _m2_fake_run(argv, **kw):
    _m2_calls.append(argv)
    class _R:
        stdout = "ok\n"
    return _R()
hub.subprocess.run = _m2_fake_run
hub._pane_last_output("somepane", lines=60)
hub.subprocess.run = _m2_real_run
_m2_argv = _m2_calls[0]
_m2_src_idx = _m2_argv.index("--source")
results["M2_pane_read_uses_a_source_with_no_screen_height_cap"] = (
    _m2_argv[_m2_src_idx + 1] == "recent")

# ---- review M1 (r3): the last-non-blank-row check above was itself still
# too narrow — silent the moment the request wraps across terminal columns,
# the moment the worker's own recap/status block follows it, or the moment
# the worker bolds the marker. All three are the SAME real omp shape: a
# markdown message, written as one paragraph, that a terminal of any width
# renders as however many physical rows it takes.
CHROME_WRAPPED = ("an earlier line of agent output\n"
                  "CONDUCTOR: please confirm the rollback plan before I proceed because the change touches\n"
                  "the production webhook handler and a wrong call cannot be undone once it ships\n"
                  "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 42% \u2500\u2500\u256e\n"
                  "\u2502 >                                          \u2502\n"
                  "\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n")
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_WRAPPED, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
results["M1_fires_when_the_request_wraps_across_terminal_rows"] = any(
    c["signal"] == "conductor_prompt" for c in cands)
# The continuation row, joined on, is part of what gets hashed/shown.
results["M1_wrapped_detail_includes_the_continuation_row"] = any(
    c["signal"] == "conductor_prompt" and "undone once it ships" in c["detail"] for c in cands)

# Real omp panes put a status/recap block below the request — its own
# markdown paragraph, separated by a blank row — not the worker's last word.
CHROME_RECAP_A = ("an earlier line of agent output\n"
                  "CONDUCTOR: approve request ar_9 or tell me why not\n"
                  "\n"
                  "Recap: static review is done; only the test run is pending your reply.\n"
                  "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 42% \u2500\u2500\u256e\n"
                  "\u2502 >                                          \u2502\n"
                  "\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n")
CHROME_RECAP_B = CHROME_RECAP_A.replace(
    "Recap: static review is done; only the test run is pending your reply.",
    "Recap: review done, tests queued, waiting on your call.")
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_RECAP_A, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
results["M1_fires_when_a_recap_block_follows_the_request"] = any(
    c["signal"] == "conductor_prompt" for c in cands)
fp_recap_a = next((c["fingerprint"] for c in cands if c["signal"] == "conductor_prompt"), None)
# A re-render/scroll that only changes the trailing recap text (same
# request, same blank-line boundary) must NOT re-arm the claim.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_RECAP_B, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
fp_recap_b = next((c["fingerprint"] for c in cands if c["signal"] == "conductor_prompt"), None)
results["M1_a_rerendered_recap_is_not_a_new_fingerprint"] = fp_recap_a == fp_recap_b

# ---- review L1 (r4): the fingerprint must survive a pane RESIZE, not
# just a re-render with identical wrapping. Two wraps of the IDENTICAL
# request text, broken at different columns, must mint the SAME
# fingerprint -- the live review measured the old code breaking this (a
# long path wrapped differently at each width it was resized to).
#
# Review M1 (r5): word-wrap (textwrap) only ever breaks AT A SPACE, so
# rejoining word-wrapped continuation rows with " " reconstructs the exact
# original string no matter where the wrap fell -- raw-line hashing
# (8a0095e) passed this fixture too, so it could never actually FAIL on a
# revert. A real terminal hard-wraps mid-token the instant a long path or
# URL exceeds the column, which textwrap never does; this fixture
# character-wraps a long path instead, so the two widths split it at
# DIFFERENT characters and the raw join reconstructs two DIFFERENT
# strings -- proven directly below -- while only whitespace-stripped
# normalization (what head actually ships) reconstructs the identical one.
_L1_REQUEST = ("CONDUCTOR: run /Users/thurbs/.herdr/worktrees/herdr-control/fix/"
              "stall-watchdog-m1/tmp/r2_probe.py and keep its output in tmp/r2_probe.out")
def _l1_char_wrap(s, width):
    return [s[i:i + width] for i in range(0, len(s), width)]
def _l1_chrome_at(width):
    lines = _l1_char_wrap(_L1_REQUEST, width)
    return ("an earlier line of agent output\n" + "\n".join(lines) + "\n"
            "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 42% \u2500\u2500\u256e\n"
            "\u2502 >                                          \u2502\n"
            "\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n")
_l1_joined_46 = " ".join(l.strip() for l in _l1_char_wrap(_L1_REQUEST, 46))
_l1_joined_70 = " ".join(l.strip() for l in _l1_char_wrap(_L1_REQUEST, 70))
results["M1_fixture_would_hash_differently_raw_at_the_two_widths"] = (
    hub.hashlib.sha256(_l1_joined_46.encode()).hexdigest()
    != hub.hashlib.sha256(_l1_joined_70.encode()).hexdigest())
cands_46 = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: _l1_chrome_at(46), pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
cands_70 = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: _l1_chrome_at(70), pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
fp_46 = next((c["fingerprint"] for c in cands_46 if c["signal"] == "conductor_prompt"), None)
fp_70 = next((c["fingerprint"] for c in cands_70 if c["signal"] == "conductor_prompt"), None)
results["L1_fingerprint_stable_across_a_resize_and_rewrap"] = (
    fp_46 is not None and fp_46 == fp_70)

CHROME_BOLD = ("an earlier line of agent output\n"
              "**CONDUCTOR:** approve request ar_11 or tell me why not\n"
              "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 42% \u2500\u2500\u256e\n"
              "\u2502 >                                          \u2502\n"
              "\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n")
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_BOLD, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
results["M1_fires_on_a_bold_markdown_conductor_marker"] = any(
    c["signal"] == "conductor_prompt" for c in cands)

# ---- review H1 (r5): "already answered" is no longer inferred from pane
# SHAPE -- r4's guard dropped the result the moment a SECOND, non-recap
# paragraph followed the request, and round-2 review found it ate the
# round-1 live incident's own shape (a trailing paragraph, then omp's own
# recap) plus six other ordinary shapes a worker writes while STILL
# waiting. Every one of F1-F7 below must FIRE: none of them is an actual
# reply, so the fix must never treat them as "answered".
_H1R5_REQ = ("**CONDUCTOR: run `/Users/thurbs/.herdr/worktrees/herdr-control/fix/"
            "stall-watchdog-m1/tmp/r2_probe.py` and keep its output in tmp/r2_probe.out; "
            "it is read-only and uses only herdr pane list and pane read.**")
_H1R5_TRAIL = "I'll wait here and keep working on the migration script while that's pending."
_H1R5_OMP_RECAP = ("\u203b recap: static review done; waiting on the conductor to run the "
                   "probe script before writing the verdict. (disable recaps in /config)")

def _h1r5_pane(paragraphs, width=46):
    """One agent-output line, then each paragraph (word-wrapped at `width`,
    or a literal list of rows) separated by a blank row, then the omp
    composer -- the same shape every CHROME_* fixture above hand-built,
    generalized so F1-F7 do not need seven more hand-wrapped literals."""
    rows = ["an earlier line of agent output"]
    for p in paragraphs:
        rows.append("")
        rows.extend(p if isinstance(p, list) else (textwrap.wrap(p, width=width) or [p]))
    return ("\n".join(rows) + "\n"
            "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 42% \u2500\u2500\u256e\n"
            "\u2502 >                                          \u2502\n"
            "\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n")

_H1R5_CASES = [
    ("F1_r1_live_shape_bold_wrapped_request_plus_trailing_para_plus_omp_recap_FIRES",
     [_H1R5_REQ, _H1R5_TRAIL, _H1R5_OMP_RECAP]),
    ("F2_request_plus_one_plain_trailing_sentence_FIRES",
     ["CONDUCTOR: run /abs/tmp/x.sh", "I'll wait for the output before going on."]),
    ("F3_request_plus_an_indented_command_block_FIRES",
     ["CONDUCTOR: please run this for me:", ["    bash /abs/tmp/x.sh"]]),
    ("F4_request_plus_an_evidence_list_FIRES",
     ["CONDUCTOR: approve ar_7 or tell me why not.", ["Evidence:", "- tests 76/0", "- probe rc=0"]]),
    ("F5_request_plus_a_2paragraph_omp_recap_FIRES",
     [_H1R5_REQ, "\u203b recap: waiting on the conductor.", "Next: write REVIEW.md."]),
    ("F6_request_plus_Recap_colon_outside_bold_FIRES",
     ["CONDUCTOR: run /abs/tmp/x.sh", "**Recap**: waiting on you."]),
    ("F7_request_plus_a_Status_line_FIRES",
     ["CONDUCTOR: run /abs/tmp/x.sh", "Status: blocked on the run above."]),
]
for _h1r5_key, _h1r5_paras in _H1R5_CASES:
    _h1r5_text = _h1r5_pane(_h1r5_paras)
    cands = hub.stall_watchdog_candidates(
        [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
        pane_read_fn=lambda pane, _t=_h1r5_text: _t, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
    results[_h1r5_key] = any(c["signal"] == "conductor_prompt" for c in cands)

# ---- mutation harness: each revert variant is installed, exercised and
# restored in its own try/except/finally -- review M3: `next()` without a
# default used to raise StopIteration here and crash this ENTIRE inline
# script, which the bash harness below (`if ! py_out=...`) then reports as
# ONE "crashed" FAIL while silently dropping every other Section B result.
# Isolating each mutant means one exception can take down only its own
# result key, never the mutants -- or anything else -- around it.
def _naive_last_request(text):
    """pre-#228: literal last non-blank row, no markdown strip, no
    continuation join, no answered-guard."""
    if not text:
        return None
    for line in reversed(hub._cp.agent_output_lines(text)):
        line = hub._cp.ANSI_RE.sub("", line).strip()
        if not line:
            continue
        if not line.startswith("CONDUCTOR:"):
            return None
        return {"line": line, "fp": hub._cp.fingerprint(line), "ctx": "?", "tail": 0}
    return None

real_last_request = hub._cp.last_request

def _run_mutant(mut_name, mut_fn, checks):
    """checks: [(result_key, pane_text, expect_fire)]. Installs mut_fn,
    runs every check against it, restores the real function even if a
    check raises -- and records a crash as its OWN result instead of
    letting it propagate and take the rest of Section B with it."""
    hub._cp.last_request = mut_fn
    try:
        for result_key, pane_text, expect_fire in checks:
            try:
                cands = hub.stall_watchdog_candidates(
                    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                    pane_read_fn=lambda pane: pane_text, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
                fired = any(c["signal"] == "conductor_prompt" for c in cands)
                results[result_key] = (fired == expect_fire)
            except Exception:
                results[f"{mut_name}:{result_key}_CRASHED"] = False
    finally:
        hub._cp.last_request = real_last_request

# The plain one-row case predates this review round's fix and must survive
# every revert too -- proof each mutation targets only what it claims to.
_run_mutant("REVERT_full_naive", _naive_last_request, [
    ("REVERT_M1_wrap_fix_caught_on_revert", CHROME_WRAPPED, False),
    ("REVERT_M1_recap_fix_caught_on_revert", CHROME_RECAP_A, False),
    ("REVERT_M1_bold_fix_caught_on_revert", CHROME_BOLD, False),
    ("REVERT_M1_plain_case_unaffected_by_the_revert", CHROME, True),
])

cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_WRAPPED, pane_birth_fn=lambda pane: "pb1", occurrence_fn=NEW_OCC)
results["REVERT_M1_restored_fix_fires_again"] = any(
    c["signal"] == "conductor_prompt" for c in cands)

# ---- _stall_task_signals(): real scratch registry ----------------------------
db_dir = os.path.join(os.environ["WORK"], "runs2")
os.makedirs(db_dir, exist_ok=True)
hub.REGISTRY = __import__("pathlib").Path(db_dir) / "registry.sqlite3"
# Reuses the bash half's run-registry.sh to build a REAL schema, so this is
# not a hand-rolled table shape that could drift from the real one.
subprocess.run(
    ["bash", "-c",
     f". '{here}/lib/run-registry.sh'; HERDR_RUN_STATE_DIR='{db_dir}' registry_init"],
    check=True)
# review M-c(2): the registry queries below are now windowed to
# `now - threshold_s*8`. Every fixture in this section uses literal
# "2026-01-01T0X:..." timestamps spanning ~3h — REG_NOW/REG_THRESH keep
# all of them inside the window while still excluding a deliberately
# ancient ("2020-01-01") row later on.
REG_NOW = hub._iso_epoch("2026-01-01T03:00:00Z")
REG_THRESH = 100_000.0
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
# review M2: a policy refusal is `approval_escalated` — the real signal a
# deny-class prompt produces (herdr-select.sh `_refuse_non_human`).
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('esc1','drun','dtask','approval_escalated','2026-01-01T00:00:00Z',"
             "'{\"verdict\":\"deny\",\"reason\":\"reserved\"}')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('ev1','drun','dtask','message_delivered','2026-01-01T00:00:00Z','{}')")
conn.commit(); conn.close()
denied, delivered, owner_acted = _safe_signals3("sig_dtask", now=REG_NOW, threshold_s=REG_THRESH)
results["M2_denied_query_finds_the_approval_escalated_row"] = denied.get("dtask", {}).get("fingerprint") == "esc1"
results["delivered_query_finds_an_unprocessed_message"] = "dtask" in delivered

# review M-c(2): a WAY-older approval_escalated row, with no later worker
# activity, falls outside the window and must not populate `denied` —
# proof the bound is real, not just "still works for recent rows".
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask_old','drun','stalled','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('esc_old','drun','dtask_old','approval_escalated','2020-01-01T00:00:00Z','{}')")
conn.commit(); conn.close()
denied_old, _, _ = _safe_signals3("sig_mc2", now=REG_NOW, threshold_s=REG_THRESH)
results["Mc2_a_window_bounded_scan_excludes_ancient_rows"] = "dtask_old" not in denied_old

# review M2: a HUMAN pressing Approve on a deny-CLASSIFIED prompt (policy_verdict
# stayed 'deny', the human's own choice was Approve) must NEVER read as "denied".
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask2','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO approvals (approval_id, task_id, authority, policy_verdict, choice_text, decided_at) "
             "VALUES ('appr_human_ok','dtask2','human','deny','Approve','2026-01-01T00:00:00Z')")
conn.commit(); conn.close()
denied2, _, _ = _safe_signals3("sig_m2human", now=REG_NOW, threshold_s=REG_THRESH)
results["M2_human_approve_on_a_deny_classified_prompt_never_fires_denied"] = "dtask2" not in denied2

# A human's OWN declining choice (independent of policy_verdict) is still the
# same real signal from the other path.
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask3','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO approvals (approval_id, task_id, authority, policy_verdict, choice_text, decided_at) "
             "VALUES ('appr_deny3','dtask3','human','allow','2. Deny','2026-01-01T00:00:00Z')")
conn.commit(); conn.close()
denied3, _, _ = _safe_signals3("sig_m2decline", now=REG_NOW, threshold_s=REG_THRESH)
results["M2_a_humans_own_decline_still_fires_denied"] = denied3.get("dtask3", {}).get("fingerprint") == "appr_deny3"

# review H4: herdr-deliver.sh's REAL ordering — send-to-agent.sh's
# message_delivered, THEN herdr-deliver.sh's own brief_delivered — must NOT
# read as "the worker did something". A genuine worker signal
# (input_required) DOES clear it.
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('t_deliver','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'),"
             "('t_worker_acted','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) VALUES "
             "('d1','drun','t_deliver','message_delivered','2026-01-01T01:00:00Z','{}'),"
             "('d2','drun','t_deliver','brief_delivered','2026-01-01T01:00:00Z','{}'),"
             "('w1','drun','t_worker_acted','message_delivered','2026-01-01T01:00:00Z','{}'),"
             "('w2','drun','t_worker_acted','input_required','2026-01-01T01:00:05Z','{}')")
conn.commit(); conn.close()
_, delivered4, _ = _safe_signals3("sig_h4", now=REG_NOW, threshold_s=REG_THRESH)
results["H4_herdr_deliver_ordering_still_reads_as_unprocessed"] = "t_deliver" in delivered4
results["H4_genuine_worker_activity_clears_unprocessed"] = "t_worker_acted" not in delivered4

# review H1: owner_acted is populated from the real owner-activity types.
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('t_owner','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('oa1','drun','t_owner','owner_acted','2026-01-01T02:00:00Z','{}')")
conn.commit(); conn.close()
_, _, owner_acted2 = _safe_signals3("sig_owner", now=REG_NOW, threshold_s=REG_THRESH)
results["owner_acted_populated_from_owner_acted_events"] = "t_owner" in owner_acted2

# round-3 R3: `action_decided` was removed from owner-activity entirely --
# a conductor's `herdr-action.sh supersede` must NOT ack a wake, exactly
# as on origin/main (the round-1 item-4 addition and the round-2 Q2
# textual-match carve-out are both reverted).
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('t_supersede','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('ad1','drun','t_supersede','action_decided','2026-01-01T02:00:00Z',"
             "'{\"decision\":\"superseded\"}')")
conn.commit(); conn.close()
_, _, owner_acted3 = _safe_signals3("sig_supersede", now=REG_NOW, threshold_s=REG_THRESH)
results["R3_supersede_after_a_wake_does_not_ack_it_matches_main"] = "t_supersede" not in owner_acted3

# A later event from the SAME task (real worker activity) clears "unprocessed".
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('ev2','drun','dtask','input_required','2026-01-01T00:05:00Z','{}')")
conn.commit(); conn.close()
_, delivered5, _ = _safe_signals3("sig_cleared", now=REG_NOW, threshold_s=REG_THRESH)
results["delivered_cleared_once_the_worker_did_something"] = "dtask" not in delivered5

# ---- review M-a: the boot floor persists across a restart --------------------
hub._STALL_BOOT_EPOCH_CACHE.clear()
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('stall_watchdog_epoch','','','stall_watchdog_epoch','2026-01-01T00:00:00Z','{}')")
conn.commit(); conn.close()
persisted = hub._stall_boot_epoch()
results["Ma_boot_epoch_persists_across_a_restart"] = abs(persisted - hub._iso_epoch("2026-01-01T00:00:00Z")) < 1
# A second call must not re-floor to "now" either (cached, not re-queried).
results["Ma_boot_epoch_stays_cached_on_a_second_call"] = hub._stall_boot_epoch() == persisted

# ---- review M-c(1): an escalated/unowned claim is resolved without an ack ---
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('stall_dtaskX_denied_esc_escalate','drun','dtaskX','stall_escalate_claim',"
             "'2026-01-01T00:00:00Z','{}')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('stall_dtaskY_denied_esc_unowned','drun','dtaskY','stall_wake_unowned',"
             "'2026-01-01T00:00:00Z','{}')")
conn.commit(); conn.close()
ro = sqlite3.connect(f"file:{hub.REGISTRY}?mode=ro", uri=True)
resolved_keys = hub._sw_resolved_keys(ro)
ro.close()
results["Mc1_escalated_key_resolved_without_an_ack"] = "stall_dtaskX_denied_esc" in resolved_keys
results["Mc1_unowned_key_resolved_without_an_ack"] = "stall_dtaskY_denied_esc" in resolved_keys

# ---- _stall_watchdog_tick(): the in-memory on/off switch ---------------------
# Isolated from the boot_epoch floor (its own dedicated tests are above):
# this block is testing dispatch wiring, not H1's storm guard. `now` inside
# _stall_watchdog_tick is real wall-clock time (not injectable), so this
# fixture uses a REAL recent timestamp — just past threshold, well inside
# the M-c(2) window — rather than a fixed literal.
hub._STALL_BOOT_EPOCH_CACHE[:] = [0.0]
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

TICK_TS = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 700))
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('tick1','tickrun','stalled',?,?)", (TICK_TS, TICK_TS))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('tick_esc','tickrun','tick1','approval_escalated',?,'{}')", (TICK_TS,))
conn.commit()
tick_seq = conn.execute("SELECT sequence FROM events WHERE event_id='tick_esc'").fetchone()[0]
conn.close()
fake_herdr = {"tasks": [base_task(task_id="tick1", run_id="tickrun", state="stalled", stored_state="stalled",
                                  pane_id="tickpane", pane_birth="tickbirth", updated_at=TICK_TS)]}
hub.CACHES["herdr"] = FakeCache(fake_herdr)

# "removed" — the in-memory equivalent of the rule not existing: point the
# script path at nothing and confirm the exact same scenario stays silent.
real_script = hub.STALL_WATCHDOG_SCRIPT
hub.STALL_WATCHDOG_SCRIPT = __import__("pathlib").Path("/does/not/exist")
_safe_tick("tick_rule_removed")
results["rule_removed_stays_silent_on_a_real_candidate"] = calls == []

# restored — the same scenario now fires.
hub.STALL_WATCHDOG_SCRIPT = real_script
_safe_tick("tick_rule_restored")
results["rule_restored_fires_on_the_same_candidate"] = (
    len(calls) == 1 and calls[0][2] == "wake" and calls[0][3] == "tick1" and calls[0][4] == "denied")

# review M4: an already claimed+acked key must not be re-dispatched.
claim_key = f"stall_tick1_denied_{hub._sw_digest(f'esc{tick_seq}')}"
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES (?,'tickrun','tick1','stall_wake',?,'{\"signal\":\"denied\"}')",
             (claim_key, TICK_TS))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('tick_ack','tickrun','tick1','stall_acked',?,'{\"signal\":\"denied\"}')",
             (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 600)),))
conn.commit(); conn.close()
calls.clear()
_safe_tick("tick_m4_dedupe")
results["M4_already_claimed_and_acked_key_is_never_redispatched"] = calls == []

hub.subprocess.run = real_run

print(json.dumps(results))
PYEOF
  export WORK
  if ! py_out="$(python3 "$PYFILE" "$here")"; then
    bad "hub.py check block crashed — every stall_watchdog_candidates case is unverified"
    py_out='{}'
  fi
  _tally "$py_out"
fi

# ═══════════════ Section C — DESIGN-228 §7 regressions (R1–R29) ═══════════════
# Every scenario is its own scratch registry under $WORK/c/<name>, driven on
# a simulated clock: hub ticks every 15s through the REAL
# `_stall_watchdog_tick` (its `time`, herdr cache and pane subscription are
# the only things replaced), and every row is written by the real writer —
# register_task / set_task_state / append_event (lib/run-registry.sh),
# send-to-agent.sh, stall-watchdog.sh wake, stall-ack.sh, herdr-action.sh —
# under a stub `herdr` and a `date` pinned to the simulated second.
# Assertions read only outcomes (registry rows, candidates, Slack log), so a
# same-signature revert of hub.py fails by result, not by a crash.
if ! _on C; then
  :
elif ! command -v python3 >/dev/null 2>&1; then
  bad "python3 not found — cannot exercise the DESIGN-228 regressions"
else
  SCFILE="$WORK/check_stall_requests.py"
  cat > "$SCFILE" <<'PYEOF'
import calendar, hashlib, importlib.util, json, os, re, sqlite3, subprocess, sys, textwrap, time, traceback
from pathlib import Path

HERE = Path(sys.argv[1])
WORKC = Path(os.environ["WORK"]) / "c"
ONLY = {s for s in os.environ.get("SC_ONLY", "").split(",") if s}
REAL_RUN = subprocess.run
BASE = 1772323200.0          # 2026-03-01T00:00:00Z: the deploy tick
TICK = 15.0
THRESH = 600.0
FS = BASE + 120              # the first tick that sights a request shown at BASE+118
os.environ["HERDR_STALL_WATCHDOG_THRESHOLD_S"] = "600"
os.environ["HERDR_ATTENTION_INTERVAL_S"] = "15"
results = {}

def isoz(t): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))

def epoch(s):
    try:
        return float(calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")))
    except (TypeError, ValueError):
        return None

def sha16(s): return hashlib.sha256(s.encode()).hexdigest()[:16]

def jload(s):
    try:
        v = json.loads(s or "{}")
    except ValueError:
        return {}
    return v if isinstance(v, dict) else {}

def gen_of(fp):
    m = re.search(r"\|g(\d+)$", fp or "")
    return int(m.group(1)) if m else 1

# ---- the pane: blocks rendered at a width, under omp's composer box ---------
BOX_TOP = "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 41% \u2500\u2500\u256e"
BOX_MID = "\u2502 > "
BOX_BOT = "\u2570" + "\u2500" * 30 + "\u256f"

def P(s): return ("p", s)                 # a prose paragraph (wraps)
def RQ(s): return ("r", s)                # a CONDUCTOR: request (wraps)
def RC(s): return ("x", s)                # an omp `※` recap (wraps)
def TL(*rows): return ("t", list(rows))   # tool rows (truncated at the width)

def render(blocks, width):
    rows = []
    for kind, val in blocks:
        if rows:
            rows.append("")
        if kind == "p":
            rows += textwrap.wrap(val, width)
        elif kind == "r":
            rows += textwrap.wrap("CONDUCTOR: " + val, width)
        elif kind == "x":
            rows += textwrap.wrap("\u203b " + val, width, subsequent_indent="  ")
        else:
            rows += [r[:width] for r in val]
    return rows

FILL = P("Earlier output that scrolled past while building, linting and type checking the parser refactor branch.")
IDLE = P("Working through the parser refactor; nothing is pending on anyone right now.")
CTX_A = P("The parser refactor is done and the unit suite passes locally; the release script still needs the operator token.")
CTX_B = P("I retried with the cached token and it was rejected again, so this still needs you before I can continue.")
CTX_C = P("Separately, the migration dry run warned about the legacy index on the events table.")
REQ_A = RQ("run /Users/op/Code/sc/tmp/release-parser.sh (sha256 3f2a9c1d) - it reads the operator token and tags v1.4.2")
REQ_A2 = RQ("run /Users/op/Code/sc/tmp/retag.sh (sha256 77be01aa) to move the v1.4.2 tag onto the fixed commit")
REQ_B = RQ("may I drop the legacy events index before the migration, or must it stay for the old reader?")
A1 = P("Got it - running the release script now.")
A2 = P("The release script finished: 42 checks green and tag v1.4.2 is pushed.")
A3 = P("Updated the changelog entry for v1.4.2.")
A4 = P("Cleaned up the temporary build directory.")
X1 = P("Staged the release notes draft under docs/release/v1.4.2.md for review.")
X2 = P("Left the old tag in place until the new one is confirmed.")
STALE = P("Thinking...")
SPINNER = P("\U000F12B7 Working\u2026")   # r2 L2: a lone omp spinner row —
# the furniture conductor_prompt.py's `spinner` kind excludes from P.
JOB = P("Background job 7 finished: lint passed with 0 warnings.")
NARR = P("Noted the lint result; still waiting on the release script.")
STILL = P("Still blocked: that reply was about the release script, not the index question.")
REASK_B = P("I am still blocked on the index question, so I am asking it again as a new line.")
LISTED = P("Listed tmp/: release-parser.sh is there and executable.")
RECAP = RC("Recap: parser refactor done, the release script is waiting on the operator token, next step is tagging v1.4.2 once it runs.")
TOOLBOX = TL("\u256d\u2500 bash: ls -la tmp/ \u2500\u256e", "\u2502 release-parser.sh  retag.sh \u2502",
             "\u2570" + "\u2500" * 28 + "\u256f")
PREVIEW = TL("\u256d\u2500 preview: release-parser.sh " + "\u2500" * 60 + "\u256e",
             "\u2502 #!/usr/bin/env bash; set -euo pipefail; token=$(cat ~/.release-token); git tag v1.4.2 && git push \u2502",
             "\u2570" + "\u2500" * 90 + "\u256f")
TREE = TL("\u251c read hub.py (5655 lines): stall_watchdog_candidates, _stall_cprompt_fold, _stall_cprompt_sight",
          "\u2502   matched 14 lines across the signal-5 fold and the tick dispatcher in hub.py",
          "\u2514 grep -n conductor_prompt lib/*.py lib/*.sh: 9 matches in 4 files")

def ask(*below, ctx=CTX_A, req=REQ_A):
    return [FILL, ctx, req, *below]

# The stub herdr and the pinned clock every real bash writer runs under.
SIM_SH = r"""
herdr() {
  local p n
  case "$1 $2" in
    "pane list") cat "$SIMD/panes.json" ;;
    "pane process-info")
      p="$3"; [ "$p" = --pane ] && p="$4"
      grep -qF "\"pane_id\":\"$p\"" "$SIMD/panes.json" || return 1
      printf '%s\n' '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}' ;;
    "pane read")
      p="$3"; n=60; shift 3
      while [ $# -gt 0 ]; do
        case "$1" in --lines) n="$2"; shift 2 ;; *) shift ;; esac
      done
      grep -qF "\"pane_id\":\"$p\"" "$SIMD/panes.json" || return 1
      { cat "$SIMD/text/$p" 2>/dev/null
        cat "$SIMD/box_top"
        printf '%s%s\n' "$(cat "$SIMD/box_mid")" "$(cat "$SIMD/composer/$p" 2>/dev/null)"
        cat "$SIMD/box_bot"; } | tail -n "$n" ;;
    "pane send-text")
      printf 'send-text %s\n' "$3" >> "$SIMD/sent.log"
      printf '%s' "$4" > "$SIMD/composer/$3" ;;
    "pane send-keys")
      printf 'send-keys %s %s\n' "$3" "$4" >> "$SIMD/sent.log"
      if [ "$4" = Enter ] && [ -s "$SIMD/composer/$3" ]; then
        printf '%s\t%s\n' "$3" "$(tr '\n' ' ' < "$SIMD/composer/$3")" >> "$SIMD/submitted.log"
        : > "$SIMD/composer/$3"
      fi ;;
    *) return 0 ;;
  esac
}
date() {
  if [ -n "${SIM_NOW:-}" ]; then
    case "$*" in
      "+%s"|"-u +%s") printf '%s\n' "$SIM_NOW"; return 0 ;;
      "-u +%Y-%m-%dT%H:%M:%SZ"|"-u +%Y%m%dT%H%M%SZ")
        command date -u -r "$SIM_NOW" "$2" 2>/dev/null || command date -u -d "@$SIM_NOW" "$2"
        return ;;
    esac
  fi
  command date "$@"
}
export -f herdr date
"""

class _R:
    def __init__(self, out=""):
        self.returncode, self.stdout, self.stderr = 0, out, ""

class SimTime:
    """hub's `time` module with only `time()` replaced by the simulated clock."""
    def __init__(self, w): self._w = w
    def time(self): return self._w.now
    def __getattr__(self, name): return getattr(time, name)

class FakeCache:
    ttl = 5
    def __init__(self, w): self._w = w
    def get(self): return {"tasks": self._w.task_dicts()}

CUR = []

def hub_subprocess_run(argv, *a, **kw):
    """hub's only process boundary: its pane read and its stall-watchdog.sh
    dispatch. Everything this harness itself runs uses REAL_RUN."""
    if list(argv)[:1] == ["git"]:
        return REAL_RUN(argv, *a, **kw)  # hub's import-time version probe (`git describe`): read-only
    if not CUR:
        return _R()                  # hub import, before any world: never a real herdr
    w, argv = CUR[0], list(argv)
    if argv[:3] == ["herdr", "pane", "read"]:
        n = int(argv[argv.index("--lines") + 1]) if "--lines" in argv else 60
        return _R(w.read(argv[3], n))
    at = next((i for i, a in enumerate(argv) if str(a).endswith("stall-watchdog.sh")), None)
    if at is not None and argv[at + 1:at + 2] == ["wake"]:
        w.dispatch([str(a) for a in argv[at + 2:]])
        return _R()
    w.errors.append(f"unexpected subprocess from hub: {argv[:4]}")
    return _R()

subprocess.run = hub_subprocess_run


class World:
    def __init__(self, name, start=BASE - 600, fresh=False):
        self.name, self.fresh = name, fresh
        self.dir = WORKC / name
        self.dir.mkdir(parents=True)     # one fresh dir per world; $WORK's own cleanup removes it
        self.simd = self.dir / "sim"
        for sub in ("runs", "state", "hstate", "wt", "sim/text", "sim/composer"):
            (self.dir / sub).mkdir(parents=True, exist_ok=True)
        (self.simd / "sim.sh").write_text(SIM_SH)
        (self.simd / "box_top").write_text(BOX_TOP + "\n")
        (self.simd / "box_mid").write_text(BOX_MID)
        (self.simd / "box_bot").write_text(BOX_BOT + "\n")
        notify = self.simd / "notify.sh"
        notify.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$SIMD/notified.log\"\n")
        notify.chmod(0o755)
        self.registry = self.dir / "runs" / "registry.sqlite3"
        self.run = f"run_{name}"
        self.now, self.next_tick = float(start), BASE
        self.panes, self.tasks = {}, {}
        self.cands, self.errors, self.lasterr = [], [], {}
        self.hook = None
        self._write_panes()
        self.lib("registry_init")
        self.hub = self._load()

    # -- processes ------------------------------------------------------------
    def env(self, **extra):
        e = {k: v for k, v in os.environ.items() if not k.startswith("BASH_FUNC_")}
        for k in ("HERDR_STALL_WATCHDOG_ESCALATE_S", "HERDR_STALL_WATCHDOG_SEND", "HERDR_ACTION_SEND"):
            e.pop(k, None)
        e.update(HERDR_RUN_STATE_DIR=str(self.dir / "runs"), HERDR_RUN_REGISTRY=str(self.registry),
                 HERDR_STATE_ROOT=str(self.dir / "state"), HERDR_STATE_DIR=str(self.dir / "hstate"),
                 SIMD=str(self.simd), SIM_SH=str(self.simd / "sim.sh"), SC_HERE=str(HERE),
                 SIM_NOW=str(int(self.now)), HERDR_PANE_ID="",
                 HERDR_STALL_WATCHDOG_NOTIFY=str(self.simd / "notify.sh"),
                 HERDR_ACTION_NOTIFY=str(self.simd / "notify.sh"),
                 HERDR_STALL_WATCHDOG_THRESHOLD_S=str(int(THRESH)))
        e.update({k: str(v) for k, v in extra.items()})
        return e

    def lib(self, fn, *args, src=("lib/run-registry.sh",)):
        pre = "".join(f'. "$SC_HERE/{s}"; ' for s in src)
        r = REAL_RUN(["bash", "-c", '. "$SIM_SH"; ' + pre + '"$@"', "_", fn, *map(str, args)],
                     env=self.env(), capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            self.errors.append(f"{fn} rc={r.returncode} @{int(self.now - BASE)}: {r.stderr.strip()[-300:]}")
        return r.stdout.strip()

    def script(self, rel, *args, **extra):
        r = REAL_RUN(["bash", "-c", '. "$SIM_SH"; exec bash "$@"', "_", str(HERE / rel), *map(str, args)],
                     env=self.env(**extra), capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            self.errors.append(f"{rel} {list(args[:1])} rc={r.returncode} @{int(self.now - BASE)}: "
                               f"{(r.stderr or r.stdout).strip()[-300:]}")
        return r

    # -- the hub ----------------------------------------------------------------
    def _load(self):
        os.environ.update(HERDR_RUN_REGISTRY=str(self.registry), HERDR_STATE_ROOT=str(self.dir / "state"))
        spec = importlib.util.spec_from_file_location(f"hub_{self.name}", str(HERE / "hub.py"))
        hub = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hub)
        hub.REGISTRY = self.registry
        hub.time = SimTime(self)
        hub.CACHES["herdr"] = FakeCache(self)
        hub.pane_statuses = lambda: {p: {"birth": v["birth"], "agent_status": "idle"}
                                     for p, v in self.panes.items() if v["alive"]}
        real_candidates = hub.stall_watchdog_candidates

        def recording(*a, **kw):
            out = real_candidates(*a, **kw)
            self.cands += [(self.now, c) for c in out if c.get("signal") == "conductor_prompt"]
            return out
        hub.stall_watchdog_candidates = recording
        if hasattr(hub, "_stall_cprompt_put"):
            real_put = hub._stall_cprompt_put

            def put(conn, event_id, *a, **kw):
                # R22: a reply that lands between this tick's fold read and its
                # own claim write, so the claim is sequenced after the reply.
                if self.hook and event_id.startswith("stall_request_claim_"):
                    hook, self.hook = self.hook, None
                    hook()
                return real_put(conn, event_id, *a, **kw)
            hub._stall_cprompt_put = put
        return hub

    def task_dicts(self):
        con = sqlite3.connect(str(self.registry))
        try:
            rows = {r[0]: r for r in con.execute(
                "SELECT task_id, run_id, pane_id, pane_birth, conductor_pane_id, conductor_pane_birth, "
                "worktree, label, updated_at FROM tasks")}
        finally:
            con.close()
        out = []
        for tid, meta in self.tasks.items():
            r = rows[tid]
            out.append({"task_id": tid, "run_id": r[1], "pane_id": r[2], "pane_birth": r[3],
                        "conductor_pane_id": r[4], "conductor_pane_birth": r[5], "worktree": r[6],
                        "label": r[7], "updated_at": r[8], "state": meta["state"],
                        "stored_state": "running", "closure_reason": None})
        return out

    def tick(self):
        CUR[:] = [self]
        if self.fresh:
            self.hub = self._load()      # R11: nothing in-process survives a tick
        self.hub.STALL_WATCHDOG_STATE["last_error"] = None
        try:
            self.hub._stall_watchdog_tick()
        except Exception as exc:
            self.errors.append(f"tick @{int(self.now - BASE)}: {type(exc).__name__}: {exc}")
        self.lasterr[self.now] = self.hub.STALL_WATCHDOG_STATE.get("last_error")

    def run_to(self, t, ticking=True):
        while self.next_tick <= t:
            self.now = float(self.next_tick)
            if ticking:
                self.tick()
            self.next_tick += TICK
        self.now = float(t)

    def dispatch(self, args):
        task, signal, fp = args[0], args[1], args[2]
        if not self._wake_noop(task, f"stall_{task}_{signal}_{sha16(fp)}"):
            self.script("stall-watchdog.sh", "wake", *args)

    def _wake_noop(self, task, key):
        """cmd_wake's own no-op branch (claimed, inside the owner window,
        delivery confirmed), skipped for speed; every other call is real."""
        row = self.q("SELECT occurred_at FROM events WHERE event_id=?", (key,))
        if not row or self.now - epoch(row[0][0]) >= 2 * THRESH:
            return False
        return bool(self.q("SELECT 1 FROM events WHERE task_id=? AND type='stall_wake_result' "
                           "AND json_extract(payload,'$.key')=? AND json_extract(payload,'$.exit_code')=0",
                           (task, key)))

    # -- panes and tasks ----------------------------------------------------------
    def _write_panes(self):
        live = [{"pane_id": p, "terminal_id": v["birth"]} for p, v in self.panes.items() if v["alive"]]
        (self.simd / "panes.json").write_text(json.dumps({"result": {"panes": live}}, separators=(",", ":")) + "\n")

    def _rows(self, pane):
        v = self.panes[pane]
        return render(v["blocks"], v["width"])

    def _write_text(self, pane):
        rows = self._rows(pane)
        (self.simd / "text" / pane).write_text("\n".join(rows) + "\n" if rows else "")

    def add_task(self, key="a", cond_alive=True, state="stalled"):
        tid, pane, cpane = f"t_{self.name}_{key}", f"wk_{self.name}_{key}", f"cd_{self.name}_{key}"
        wt = self.dir / "wt" / key
        wt.mkdir(parents=True, exist_ok=True)
        self.panes[pane] = {"birth": f"b_{pane}", "alive": True, "blocks": [], "width": 120}
        self.panes[cpane] = {"birth": f"b_{cpane}", "alive": cond_alive, "blocks": [], "width": 120}
        self._write_panes()
        self._write_text(pane)
        self._write_text(cpane)
        self.lib("register_task", self.run, tid, f"worker_{key}", "conductor_sc", cpane, f"b_{cpane}",
                 pane, f"b_{pane}", "repo/sc", str(wt), f"label-{key}")
        self.edge(tid, "running")
        self.tasks[tid] = {"pane": pane, "cond": cpane, "state": state}
        return tid

    def show(self, tid, blocks, width=None):
        pane = self.tasks[tid]["pane"]
        self.panes[pane]["blocks"] = list(blocks)
        if width:
            self.panes[pane]["width"] = width
        self._write_text(pane)

    def read(self, pane, lines=60):
        v = self.panes.get(pane)
        if not v or not v["alive"] or v.get("unreadable"):    # R13e: birth-matched, every read empty
            return ""
        rows = (self._rows(pane) + [BOX_TOP, BOX_MID, BOX_BOT])[-lines:]
        return "\n".join(rows) + "\n"

    # -- the real writers -------------------------------------------------------------
    def reply(self, tid, text="Go ahead - the operator token is in place now.", sender="conductor", flags=()):
        frm = self.tasks[tid]["cond"] if sender == "conductor" else sender
        return self.script("send-to-agent.sh", self.tasks[tid]["pane"], *flags, text, HERDR_PANE_ID=frm)

    def approval(self, tid):
        self.lib("append_event", self.run, tid, "approval_reviewed",
                 json.dumps({"approval_id": f"sc_{int(self.now)}", "reason": "reviewed",
                             "category": "local-read", "reviewer": self.tasks[tid]["cond"]}))

    def edge(self, tid, state):
        self.lib("set_task_state", self.run, tid, state)

    def ack(self, tid):
        self.script("stall-ack.sh", tid, "conductor_prompt")

    def old_delivery(self, tid):
        """A `message_delivered` with no `req`: pre-deploy, or a failed read."""
        self.lib("append_event", self.run, tid, "message_delivered",
                 json.dumps({"pane": self.tasks[tid]["pane"], "from": self.tasks[tid]["cond"]}))

    def sql(self, script):
        con = sqlite3.connect(str(self.registry))
        try:
            con.executescript(script)
        finally:
            con.close()

    def q(self, stmt, args=()):
        con = sqlite3.connect(str(self.registry))
        try:
            return con.execute(stmt, args).fetchall()
        finally:
            con.close()

    # -- observables ------------------------------------------------------------------
    def rows(self, tid, typ):
        return [(eid, epoch(at), jload(pl), seq) for seq, eid, at, pl in self.q(
            "SELECT sequence, event_id, occurred_at, payload FROM events WHERE task_id=? AND type=? "
            "ORDER BY sequence", (tid, typ))]

    def claims(self, tid):
        out = []
        for eid, at, p, _ in self.rows(tid, "stall_request_claim"):
            g = p.get("gen")
            if not isinstance(g, int):
                m = re.search(r"_g(\d+)$", eid)
                g = int(m.group(1)) if m else 1
            out.append((g, at, p))
        return out

    def gens(self, tid):
        return {g for g, _, _ in self.claims(tid)}

    def floors(self, tid):
        out = []
        for eid, *_ in self.rows(tid, "stall_request_floor"):
            m = re.search(r"_g(\d+)_p(\d+)$", eid)
            if m:
                out.append((int(m.group(1)), int(m.group(2))))
        return out

    def cp_events(self, tid):
        """[(type, epoch, gen)] of this task's signal-5 ladder rows."""
        keys = {}
        for g, _, p in self.claims(tid):
            if p.get("fp"):
                keys[f"stall_{tid}_conductor_prompt_{sha16(p['fp'] + '|g' + str(g))}"] = g
        out = []
        for typ in ("stall_wake", "stall_escalate_claim", "stall_wake_unowned"):
            for eid, at, p, _ in self.rows(tid, typ):
                if p.get("signal") != "conductor_prompt":
                    continue
                g = gen_of(p["fingerprint"]) if "fingerprint" in p else \
                    keys.get(re.sub(r"_(escalate|unowned)$", "", eid), 1)
                out.append((typ, at, g))
        return out

    def wakes(self, tid):
        return [e for e in self.cp_events(tid) if e[0] in ("stall_wake", "stall_wake_unowned")]

    def first_seen(self, tid, gen):
        at = [a for g, a, _ in self.claims(tid) if g == gen]
        return min(at) if at else None

    def woke(self, tid, gen, fs=None):
        """Occurrence `gen` was woken on the tick its threshold elapsed."""
        fs = self.first_seen(tid, gen) if fs is None else fs
        return fs is not None and any(
            g == gen and fs + THRESH <= at < fs + THRESH + TICK for _, at, g in self.wakes(tid))

    def cands_for(self, tid, after=float("-inf")):
        return [(t, c) for t, c in self.cands if c["task_id"] == tid and t > after]

    def silent(self, tid, after=float("-inf")):
        return not self.cands_for(tid, after) and not [e for e in self.cp_events(tid) if e[1] > after]

    def slack(self, tid):
        f = self.simd / "notified.log"
        return [ln for ln in (f.read_text().splitlines() if f.exists() else [])
                if tid in ln and "conductor_prompt" in ln]

    def dump(self, tid):
        rel = lambda x: None if x is None else int(x - BASE)
        return json.dumps({
            "claims": [(g, rel(a), p.get("ctx"), p.get("tail")) for g, a, p in self.claims(tid)] if tid else None,
            "floors": self.floors(tid) if tid else None,
            "ladder": [(t, rel(a), g) for t, a, g in self.cp_events(tid)] if tid else None,
            "cands": [(rel(t), c["fingerprint"][-4:]) for t, c in self.cands_for(tid)][:6] if tid else None,
            "deliveries": [(rel(a), p.get("req")) for _, a, p, _ in self.rows(tid, "message_delivered")] if tid else None,
            "seeds": [(rel(a), p) for _, a, p, _ in self.rows(tid, "stall_request_seed")] if tid else None,
            "last_error": sorted({v for v in self.lasterr.values() if v}),
            "errors": self.errors[:5]})


def check(key, cond, w=None, tid=None):
    """A key passes only on its own outcome AND a run with no writer error."""
    good = bool(cond) and not (w is not None and w.errors)
    results[key] = good
    if not good and w is not None:
        print(f"--- {key} (t = s after deploy): {w.dump(tid)}", file=sys.stderr)


def std(name, fresh=False, state="stalled", cond_alive=True):
    w = World(name, fresh=fresh)
    t = w.add_task("a", cond_alive=cond_alive, state=state)
    w.show(t, [FILL, IDLE])
    return w, t


SCEN = []

def scen(rid):
    def deco(fn):
        SCEN.append((rid, fn))
        return fn
    return deco


# ---- shared shapes ------------------------------------------------------------------
def answered_by_capture(name, below=(A1, A2), fresh=False, state="stalled"):
    """S1: sighted (claim g1 at FS), the conductor replies through
    send-to-agent.sh at FS+101, the answer turn renders `below`."""
    w, t = std(name, fresh=fresh, state=state)
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 221); w.reply(t)
    w.run_to(BASE + 226); w.show(t, ask(*below))
    return w, t

def r1_world(name, fresh=False):
    w, t = answered_by_capture(name, fresh=fresh)
    w.run_to(FS + 2400)
    return w, t

def r4_world(name, fresh=False):
    w, t = answered_by_capture(name, fresh=fresh)
    w.run_to(BASE + 496); w.edge(t, "blocked")
    w.run_to(BASE + 501); w.approval(t); w.edge(t, "running")
    w.run_to(FS + 2400)
    return w, t

def r5_world(name, fresh=False):
    w, t = answered_by_capture(name, fresh=fresh, state="ready_review")
    w.run_to(FS + 2400)
    return w, t

def r6bi_world(name, fresh=False):
    w, t = answered_by_capture(name, fresh=fresh)
    w.run_to(BASE + 898); w.show(t, [FILL, CTX_A, REQ_A, A1, A2, CTX_A, REQ_A])
    w.run_to(BASE + 900 + 2400)
    return w, t

def typed_then_woken(name, below=(A1, A2), cond_alive=True):
    """Sighted at FS; `below` typed by a human (output, no row); woken at FS+600."""
    w, t = std(name, cond_alive=cond_alive)
    w.run_to(BASE + 118); w.show(t, ask())
    if below:
        w.run_to(BASE + 200); w.show(t, ask(*below))
    w.run_to(FS + THRESH)
    return w, t

def predeploy_answered(name, cond_alive):
    """A line answered an hour before the deploy, by a delivery with no `req`."""
    w = World(name, start=BASE - 4000)
    t = w.add_task("a", cond_alive=cond_alive)
    w.run_to(BASE - 3000); w.show(t, ask())
    w.run_to(BASE - 2900); w.old_delivery(t)
    w.run_to(BASE - 2890); w.show(t, ask(A1, A2))
    return w, t


# ---- R1–R29 -------------------------------------------------------------------------
@scen("R1")
def _():
    w, t = r1_world("r1")
    check("R1_captured_reply_after_the_first_sighting_is_silent", w.silent(t), w, t)

@scen("R2")
def _():
    w, t = std("r2")
    w.run_to(BASE + 121); w.show(t, ask())
    w.run_to(BASE + 127); w.reply(t)
    w.run_to(BASE + 130); w.show(t, ask(A1))
    w.run_to(BASE + 135 + 2400)
    check("R2_reply_6s_before_any_tick_is_silent_with_floor_g1_and_no_claim_g2",
          w.silent(t) and any(g == 1 for g, _ in w.floors(t)) and not any(g >= 2 for g in w.gens(t)), w, t)

@scen("R3")
def _():
    w, t = std("r3")
    w.run_to(BASE + 121); w.show(t, ask())
    w.run_to(BASE + 171, ticking=False); w.reply(t)            # the hub is down BASE+121..420
    w.run_to(BASE + 180, ticking=False); w.show(t, ask(A1, A2))
    w.run_to(BASE + 420, ticking=False)
    w.run_to(BASE + 420 + 2400)
    check("R3_reply_while_the_hub_is_down_is_silent", w.silent(t), w, t)

@scen("R4")
def _():
    w, t = r4_world("r4")
    moved = epoch(w.q("SELECT updated_at FROM tasks WHERE task_id=?", (t,))[0][0]) == BASE + 501
    check("R4_answered_then_an_approval_moves_updated_at_past_the_reply_is_silent", moved and w.silent(t), w, t)

@scen("R5")
def _():
    w, t = r5_world("r5")
    check("R5_answered_ready_review_with_the_line_visible_is_silent_with_floor_g1",
          w.silent(t) and any(g == 1 for g, _ in w.floors(t)), w, t)

@scen("R6a")
def _():
    w, t = answered_by_capture("r6a", below=(A1,))
    w.run_to(BASE + 898); w.show(t, [FILL, CTX_A, REQ_A, A1, CTX_B, REQ_A, JOB])
    w.run_to(BASE + 900 + 2400)
    check("R6a_same_F_new_readable_C_after_an_answer_claims_g2_and_wakes", w.woke(t, 2), w, t)

@scen("R6b")
def _():
    w, t = r6bi_world("r6bi")
    check("R6b_i_same_F_and_C_with_P_below_post_claims_g2_and_wakes_as_g2", w.woke(t, 2), w, t)
    w, t = std("r6bii")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 221); w.reply(t)
    w.run_to(BASE + 223); w.show(t, [FILL, CTX_A, REQ_A, A1, A2, CTX_A, REQ_A])
    w.run_to(BASE + 255 + 2400)
    # "no post" is O's (g1's): g2 may floor after its own escalation retires it.
    check("R6b_ii_same_F_and_C_no_post_P_not_above_pre_claims_g2_and_wakes_as_g2",
          w.woke(t, 2) and not any(g == 1 for g, _ in w.floors(t)), w, t)

@scen("R6c")
def _():
    w, t = r1_world("r6c")
    check("R6c_an_answered_line_unchanged_for_40m_is_silent_with_exactly_one_floor_row",
          w.silent(t) and len(w.floors(t)) == 1, w, t)

@scen("R7")
def _():
    w, t = std("r7")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 200); w.show(t, ask(A1, A2))                         # A typed-answered: no row
    w.run_to(BASE + 298); w.show(t, ask(A1, A2, CTX_C, REQ_B))          # B, before A's threshold
    w.run_to(BASE + 361); w.reply(t)                                     # captures B
    w.run_to(BASE + 366); w.show(t, ask(A1, A2, CTX_C, REQ_B, A3))
    w.run_to(BASE + 300 + 2400)
    check("R7_A_typed_answered_then_B_answered_by_capture_both_silent", w.silent(t), w, t)

@scen("R8")
def _():
    w, t = std("r8")
    w.run_to(BASE + 121); w.show(t, ask())
    w.run_to(BASE + 127); w.reply(t)                                     # captures A
    w.run_to(BASE + 129); w.show(t, ask(A1))
    w.run_to(BASE + 132); w.show(t, ask(A1, CTX_C, REQ_B))              # B appears
    w.run_to(BASE + 135 + 2400)
    check("R8_reply_captures_A_then_B_appears_and_wakes",
          w.woke(t, 1, fs=BASE + 135) and len(w.wakes(t)) == 1, w, t)

@scen("R8b")
def _():
    def base(name):
        w, t = std(name)
        w.run_to(BASE + 118); w.show(t, ask())
        w.run_to(BASE + 198); w.show(t, ask(CTX_C, REQ_B))              # B visible, A unanswered
        w.run_to(BASE + 261); w.reply(t)                                 # about A; binds B
        w.run_to(BASE + 266); w.show(t, ask(CTX_C, REQ_B, STILL))
        return w, t
    w, t = base("r8bi")
    w.run_to(BASE + 210 + 2400)
    check("R8b_i_reply_about_A_while_B_visible_is_silent_the_documented_residual", w.silent(t), w, t)
    w, t = base("r8bii")
    w.run_to(BASE + 398); w.show(t, ask(CTX_C, REQ_B, STILL, REASK_B, REQ_B))
    w.run_to(BASE + 405 + 2400)
    check("R8b_ii_the_worker_reasks_B_per_worker_rules_and_it_wakes", w.woke(t, 2), w, t)

@scen("R9")
def _():
    # Live omp captures, taken read-only by the conductor from this PR's own
    # fix worker (2026-10-05). herdr never resizes a background tab's PTY, so
    # every capture is at the pane's native 153 columns, not the design's
    # 46/120; narrow-width wrapping stays covered by R14/R17. Two request
    # turns, each unanswered (with its `※` recap rendered) and then after a
    # delivered one-paragraph answer, each in three herdr reads.
    states = {"a": "a-unanswered", "b": "b-answered", "c": "c-turn2-unanswered", "d": "d-turn2-answered"}
    reads = ("recent", "recent-unwrapped", "visible")
    fx = {(s, v): HERE / "tests" / "fixtures" / f"omp-w153-{n}-{v}.txt" for s, n in states.items() for v in reads}
    missing = [str(p.relative_to(HERE)) for p in fx.values() if not p.exists()]
    check("R9_live_fixtures_present", not missing)
    if missing:
        print(f"--- R9: missing live fixtures {missing}", file=sys.stderr)
        return
    cp = World("r9probe").hub._cp
    text = {k: p.read_text() for k, p in fx.items()}
    req = {k: cp.last_request(s) for k, s in text.items()}
    turns = (("1", "a", "b", "CONDUCTOR: R9 fixture turn 1 \u2014 please answer with one paragraph.",
              "Spec read; turn 1 is a fixture-capture turn, so doing nothing else."),
             ("2", "c", "d", "CONDUCTOR: R9 fixture turn 2 \u2014 please answer with one paragraph.",
              "Answer received; ending turn 2 as the brief specifies."))
    for turn, ua, an, line, above in turns:
        f, c = cp.fingerprint(line), sha16(re.sub(r"\s+", "", above))
        fc = all(req[(s, v)] and req[(s, v)]["fp"] == f and req[(s, v)]["ctx"] == c
                 for s in (ua, an) for v in reads)
        check(f"R9_turn{turn}_every_read_of_both_captures_resolves_to_the_same_F_and_readable_C", fc)
        if not fc:
            print(f"--- R9 turn {turn}: {[(s, v, req[(s, v)]) for s in (ua, an) for v in reads]}", file=sys.stderr)
            continue
        p = {s: {req[(s, v)]["tail"] for v in reads} for s in (ua, an)}
        rises = p[ua] == {0} and len(p[an]) == 1 and min(p[an]) > 0      # the §1 rule-3 premise
        check(f"R9_turn{turn}_P_is_0_with_the_recap_rendered_and_rises_after_a_one_paragraph_answer_at_153_cols", rises)
        if not rises:
            print(f"--- R9 turn {turn}: P = {p}", file=sys.stderr)
        for mode in ("i", "ii"):
            w, t = std(f"r9_{turn}{mode}")
            w.run_to(BASE + 118); w.show(t, [("t", cp.agent_output_lines(text[(ua, "recent")]))], width=10 ** 6)
            if mode == "i":
                w.run_to(BASE + 221); w.reply(t)
            w.run_to(BASE + 226); w.show(t, [("t", cp.agent_output_lines(text[(an, "recent")]))], width=10 ** 6)
            w.run_to(FS + 2400)
            if mode == "i":
                check(f"R9_i_turn{turn}_answered_live_capture_pair_mints_no_g2",
                      w.silent(t) and w.gens(t) == {1} and any(g == 1 for g, _ in w.floors(t)), w, t)
            else:
                check(f"R9_ii_turn{turn}_unanswered_live_capture_pair_is_one_occurrence_waking_at_first_seen_plus_600",
                      w.gens(t) == {1} and w.woke(t, 1, fs=FS), w, t)

@scen("R10")
def _():
    w, t = std("r10")
    w.run_to(BASE + 118); w.show(t, [FILL, CTX_A, TOOLBOX, REQ_A, PREVIEW])   # C = '?' (a box above)
    w.run_to(BASE + 298); w.show(t, [FILL, CTX_A, LISTED, REQ_A, PREVIEW])   # C readable, P unchanged
    w.run_to(FS + 2400)
    gens = w.gens(t) | {g for _, _, g in w.cp_events(t)}
    check("R10_first_sighting_C_unknown_then_readable_is_one_occurrence_and_one_ladder",
          gens == {1} and w.woke(t, 1, fs=FS) and len([e for e in w.cp_events(t) if e[0] == "stall_wake"]) == 1, w, t)

@scen("R11")
def _():
    def outcome(w, t):
        return (w.silent(t), sorted((g, int(a - BASE)) for g, a, _ in w.claims(t)), sorted(w.floors(t)),
                sorted((typ, int(a - BASE), g) for typ, a, g in w.cp_events(t)))
    for rid, mk, want in (("R1", r1_world, "silent"), ("R4", r4_world, "silent"),
                          ("R5", r5_world, "silent"), ("R6b", r6bi_world, "g2")):
        kept = mk(f"r11_{rid.lower()}_kept")
        fresh = mk(f"r11_{rid.lower()}_fresh", fresh=True)
        good = fresh[0].silent(fresh[1]) if want == "silent" else fresh[0].woke(fresh[1], 2)
        check(f"R11_{rid}_a_fresh_module_between_ticks_gives_identical_outcomes",
              good and outcome(*kept) == outcome(*fresh) and not kept[0].errors, fresh[0], fresh[1])

@scen("R12")
def _():
    w, t = std("r12")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(FS + 3 * THRESH + 60)
    wk = [a for typ, a, _ in w.cp_events(t) if typ == "stall_wake"]
    es = [a for typ, a, _ in w.cp_events(t) if typ == "stall_escalate_claim"]
    check("R12_unanswered_wakes_at_first_seen_plus_600_and_escalates_at_2x",
          w.woke(t, 1) and len(wk) == 1 and len(es) == 1 and wk[0] + 2 * THRESH <= es[0] < wk[0] + 2 * THRESH + TICK,
          w, t)

@scen("R13")
def _():
    # (a) the registry refuses the claim row.
    w, t = std("r13a")
    w.run_to(BASE + 118); w.show(t, ask())
    w.sql("CREATE TRIGGER sc_refuse_claim BEFORE INSERT ON events WHEN NEW.type='stall_request_claim' "
          "BEGIN SELECT RAISE(ABORT, 'sc: registry not writable'); END;")
    w.run_to(BASE + 120)
    refused = not w.claims(t) and not w.cands_for(t) and bool(w.lasterr.get(BASE + 120))
    w.sql("DROP TRIGGER sc_refuse_claim")
    w.run_to(BASE + 135 + THRESH + 30)
    check("R13a_an_unconfirmed_claim_skips_the_candidate_and_sets_last_error",
          refused and w.first_seen(t, 1) == BASE + 135 and w.woke(t, 1), w, t)
    # (b) the cprompt epoch's INSERT and read-back fail on the deploy tick.
    w = World("r13b")
    t = w.add_task("a")
    w.show(t, ask(A1, A2))
    w.sql("CREATE TRIGGER sc_refuse_epoch BEFORE INSERT ON events "
          "WHEN NEW.event_id='stall_watchdog_epoch_cprompt' BEGIN SELECT RAISE(ABORT, 'sc: no epoch'); END;")
    w.run_to(BASE)
    skipped = (not w.rows(t, "stall_request_seed") and not w.claims(t) and not w.cands_for(t)
               and bool(w.lasterr.get(BASE)))
    w.sql("DROP TRIGGER sc_refuse_epoch")
    w.run_to(BASE + 15)
    ep = w.q("SELECT occurred_at FROM events WHERE event_id='stall_watchdog_epoch_cprompt'")
    check("R13b_an_unconfirmed_epoch_skips_signal_5_and_is_not_cached_so_the_next_tick_retries",
          skipped and bool(ep) and epoch(ep[0][0]) == BASE + 15 and bool(w.rows(t, "stall_request_seed")), w, t)
    # (c) the epoch INSERT lands but its read-back fails; the next tick confirms it.
    w, t = predeploy_answered("r13c", cond_alive=False)
    w.sql("CREATE TRIGGER sc_hide_epoch AFTER INSERT ON events WHEN NEW.event_id='stall_watchdog_epoch_cprompt' "
          "BEGIN UPDATE events SET event_id='sc_hidden_epoch' WHERE sequence=NEW.sequence; END;")
    w.run_to(BASE)
    seeded_early = bool(w.rows(t, "stall_request_seed"))
    w.sql("DROP TRIGGER sc_hide_epoch; "
          "UPDATE events SET event_id='stall_watchdog_epoch_cprompt' WHERE event_id='sc_hidden_epoch';")
    w.run_to(BASE + 2400)
    seeds = w.rows(t, "stall_request_seed")
    marker = w.q("SELECT 1 FROM events WHERE event_id='stall_watchdog_epoch_cprompt_seeded'")
    check("R13c_a_minted_but_unconfirmed_epoch_is_seeded_on_the_confirming_tick_and_R20_stays_silent",
          not seeded_early and len(seeds) == 1 and seeds[0][1] == BASE + 15 and bool(marker)
          and w.silent(t) and not w.slack(t), w, t)
    # (d) tick 1 seeds A and fails on B; A then writes a new F; tick 2 seeds only B.
    w = World("r13d", start=BASE - 4000)
    ta, tb = w.add_task("a"), w.add_task("b")
    w.run_to(BASE - 3000); w.show(ta, ask()); w.show(tb, ask(ctx=CTX_C, req=REQ_B))
    w.run_to(BASE - 2900); w.old_delivery(ta); w.old_delivery(tb)
    w.run_to(BASE - 2890); w.show(ta, ask(A1)); w.show(tb, ask(A1, ctx=CTX_C, req=REQ_B))
    w.sql(f"CREATE TRIGGER sc_refuse_seed_b BEFORE INSERT ON events WHEN NEW.type='stall_request_seed' "
          f"AND NEW.task_id='{tb}' BEGIN SELECT RAISE(ABORT, 'sc: seed B refused'); END;")
    w.run_to(BASE)
    w.sql("DROP TRIGGER sc_refuse_seed_b")
    w.run_to(BASE + 5); w.show(ta, ask(A1, CTX_B, REQ_A2))
    w.run_to(BASE + 15 + THRESH + 30)
    sa, sb = w.rows(ta, "stall_request_seed"), w.rows(tb, "stall_request_seed")
    check("R13d_the_retry_tick_seeds_only_the_unconfirmed_task_and_A_new_F_wakes_at_first_seen_plus_600",
          len(sa) == 1 and sa[0][1] == BASE and len(sb) == 1 and sb[0][1] == BASE + 15
          and w.woke(ta, 1, fs=BASE + 15) and w.silent(tb), w, ta)
    # (e) one birth-matched pane reads empty on every tick: the seed gives up
    # past 60s, visibly, so a task registered later is never seeded (r3 L2).
    w = World("r13e")
    ta = w.add_task("a")
    w.show(ta, ask())
    w.panes[w.tasks[ta]["pane"]]["unreadable"] = True
    w.run_to(BASE + 60)
    marker = lambda: w.q("SELECT payload FROM events WHERE event_id='stall_watchdog_epoch_cprompt_seeded'")
    open_at_60 = not marker()
    w.run_to(BASE + 75)
    mk = marker()
    gave_up = open_at_60 and bool(mk) and jload(mk[0][0]).get("complete") is False and bool(w.lasterr.get(BASE + 75))
    w.run_to(BASE + 118)
    tb = w.add_task("b"); w.show(tb, ask(ctx=CTX_C, req=REQ_B))
    w.run_to(FS + THRESH + 60)
    check("R13e_an_unreadable_pane_ends_the_seed_at_60s_visibly_and_a_task_registered_later_wakes_at_first_seen_plus_600",
          gave_up and not w.rows(tb, "stall_request_seed") and w.woke(tb, 1, fs=FS), w, tb)

@scen("R14")
def _():
    w, t = std("r14")
    long_req = RQ("run /Users/op/Code/sc/tmp/release-parser.sh (sha256 3f2a9c1d) - it reads the operator "
                  "token, tags v1.4.2 and pushes the tag to origin")
    w.run_to(BASE + 118); w.show(t, [FILL, CTX_A, RECAP, long_req, PREVIEW, NARR], width=46)
    w.run_to(BASE + 125)
    w.reply(t, "[HERDR-DENIED] the policy refused rm -rf build/ - change approach.",
            sender="sc:select", flags=("--not-an-answer",))
    flagged = w.rows(t, "message_delivered")
    w.run_to(BASE + 128); w.reply(t)
    delivered = w.rows(t, "message_delivered")
    cl = w.claims(t)
    want = {k: cl[0][2].get(k) for k in ("fp", "ctx", "tail")} if cl else {}
    got = delivered[-1][2].get("req") if len(delivered) == 2 else None
    check("R14_send_to_agent_capture_equals_the_hub_F_C_P_on_the_same_pane_text",
          bool(want.get("fp")) and got == want and want["ctx"] != "?" and want["tail"] == 2, w, t)
    check("R14_a_not_an_answer_send_records_the_delivery_without_req",
          len(flagged) == 1 and "req" not in flagged[0][2] and flagged[0][2].get("pane") == w.tasks[t]["pane"], w, t)

@scen("R15")
def _():
    w, t = std("r15")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 200); w.old_delivery(t)
    w.run_to(FS + THRESH + 60)
    check("R15_message_delivered_without_req_is_not_an_answer_and_wakes", w.woke(t, 1), w, t)

@scen("R16")
def _():
    w, t = std("r16")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 200); w.show(t, ask(RECAP))
    w.run_to(FS + THRESH + 60)
    check("R16_a_wrapped_recap_after_the_first_sighting_of_an_unanswered_request_still_wakes",
          w.woke(t, 1), w, t)

@scen("R17")
def _():
    w, t = std("r17i")
    w.run_to(BASE + 118); w.show(t, ask(PREVIEW), width=46)
    w.run_to(BASE + 298); w.show(t, ask(PREVIEW), width=120)
    w.run_to(FS + THRESH + 60)
    check("R17_i_unanswered_resized_46_to_120_wakes_on_the_original_clock",
          w.gens(t) == {1} and w.woke(t, 1, fs=FS), w, t)
    w, t = std("r17ii")
    w.run_to(BASE + 118); w.show(t, ask(), width=46)
    w.run_to(BASE + 221); w.reply(t)
    w.run_to(BASE + 226); w.show(t, ask(A1, A2, PREVIEW), width=46)
    w.run_to(BASE + 498); w.show(t, ask(A1, A2, PREVIEW), width=120)
    w.run_to(FS + 2400)
    check("R17_ii_answered_resized_46_to_120_mints_no_g2", w.silent(t) and w.gens(t) == {1}, w, t)
    w, t = std("r17iii")
    w.run_to(BASE + 118); w.show(t, [FILL, CTX_A, TREE, REQ_A], width=46)
    w.run_to(BASE + 221); w.reply(t)
    w.run_to(BASE + 226); w.show(t, [FILL, CTX_A, TREE, REQ_A, A1, A2], width=46)
    w.run_to(BASE + 498); w.show(t, [FILL, CTX_A, TREE, REQ_A, A1, A2], width=120)
    w.run_to(FS + 2400)
    cl = w.claims(t)
    check("R17_iii_answered_with_a_tool_tree_directly_above_has_C_unknown_and_mints_no_g2",
          w.silent(t) and [g for g, _, _ in cl] == [1] and cl[0][2].get("ctx") == "?", w, t)

@scen("R18")
def _():
    w, t = std("r18")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 200); w.show(t, ask(JOB, NARR))
    w.run_to(FS + THRESH + 60)
    check("R18_an_async_job_result_and_narration_without_a_reask_still_wakes", w.woke(t, 1), w, t)

@scen("R19")
def _():
    def base(name):
        w = World(name, start=BASE - 4000)
        t = w.add_task("a")
        w.show(t, [FILL, IDLE])
        w.run_to(BASE - 3700); w.edge(t, "blocked")
        w.run_to(BASE - 3600); w.approval(t); w.edge(t, "running")       # the last approval, ~T0-60m
        w.run_to(BASE + 118); w.show(t, ask())                           # T0
        return w, t
    w, t = base("r19i")
    w.run_to(BASE + 220); w.reply(t)
    w.run_to(BASE + 226); w.show(t, ask(A1, A2))
    w.run_to(FS + 2400)
    check("R19_i_last_approval_60m_before_the_ask_then_a_captured_reply_is_silent", w.silent(t), w, t)
    w, t = base("r19ii")
    w.run_to(FS + THRESH + 60)
    first = min([a for _, a, _ in w.cp_events(t)] + [c[0] for c in w.cands_for(t)], default=None)
    check("R19_ii_last_approval_60m_before_the_ask_first_wake_is_first_seen_plus_600_not_15s",
          first == FS + THRESH and w.woke(t, 1), w, t)

@scen("R19c")
def _():
    # since > first_seen on an UNANSWERED occurrence: approved work after the
    # ask moves updated_at, and the clock is max(since, first_seen) (r1 H2).
    w, t = std("r19c")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 395); w.edge(t, "blocked")
    w.run_to(BASE + 400); w.approval(t); w.edge(t, "running")
    w.run_to(BASE + 400 + THRESH + 60)
    since = epoch(w.q("SELECT updated_at FROM tasks WHERE task_id=?", (t,))[0][0])
    first = min([a for _, a, _ in w.cp_events(t)] + [c[0] for c in w.cands_for(t)], default=None)
    check("R19c_approved_work_after_the_ask_restarts_the_unanswered_clock_at_since_not_first_seen",
          w.first_seen(t, 1) == FS and since == BASE + 400 and first is not None
          and since + THRESH <= first < since + THRESH + TICK and w.woke(t, 1, fs=since), w, t)

@scen("R20")
def _():
    w, t = predeploy_answered("r20", cond_alive=False)
    w.run_to(BASE + 2400)
    seeds = [p for _, _, p, _ in w.rows(t, "stall_request_seed") if p.get("fp")]
    check("R20_an_answered_predeploy_line_with_a_dead_conductor_is_seeded_with_no_wake_and_no_slack",
          len(seeds) == 1 and w.silent(t) and not w.slack(t), w, t)

@scen("R20b")
def _():
    w = World("r20b", start=BASE - 4000)
    t = w.add_task("a")
    w.show(t, [FILL, IDLE])
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(FS + THRESH + 60)
    check("R20b_a_predeploy_task_with_no_later_edge_wakes_on_a_new_F_at_first_seen_plus_600",
          w.woke(t, 1), w, t)

@scen("R20c")
def _():
    w, t = predeploy_answered("r20c", cond_alive=True)
    w.run_to(BASE + 195); w.edge(t, "blocked")
    w.run_to(BASE + 200); w.approval(t); w.edge(t, "running")
    w.run_to(BASE + 2400)
    check("R20c_a_predeploy_answered_line_after_a_postdeploy_approval_is_silent", w.silent(t), w, t)

@scen("R20d")
def _():
    w = World("r20d", start=BASE - 4000)
    t = w.add_task("a")
    w.show(t, [FILL, IDLE])
    w.sql("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) VALUES "
          f"('{w.hub._STALL_BOOT_EPOCH_EVENT_ID}', '', '', 'stall_watchdog_epoch', '{isoz(BASE - 2000)}', '{{}}')")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(FS + THRESH + 60)
    since = epoch(w.q("SELECT updated_at FROM tasks WHERE task_id=?", (t,))[0][0])
    check("R20d_a_task_idle_since_before_the_223_boot_wakes_on_a_new_F_after_the_cprompt_deploy",
          since < BASE - 2000 and w.woke(t, 1), w, t)

@scen("R20e")
def _():
    # §6 seeds in ANY non-terminal state: a task `running` at deploy, idling
    # later with its pre-deploy-answered line still visible.
    w = World("r20e", start=BASE - 4000)
    t = w.add_task("a", state="running")
    w.run_to(BASE - 3000); w.show(t, ask())
    w.run_to(BASE - 2900); w.old_delivery(t)
    w.run_to(BASE - 2890); w.show(t, ask(A1, A2))
    w.run_to(BASE + 300)
    w.tasks[t]["state"] = "stalled"              # derived idle; the registry row does not move
    w.run_to(BASE + 300 + 2400)
    seeds = [p for _, _, p, _ in w.rows(t, "stall_request_seed") if p.get("fp")]
    check("R20e_a_task_running_at_deploy_is_seeded_and_idling_later_on_its_answered_line_is_silent",
          len(seeds) == 1 and not w.claims(t) and w.silent(t), w, t)

@scen("R21")
def _():
    w, t = std("r21")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 221); w.reply(t)                 # the tick at +225 still shows P == pre
    w.run_to(BASE + 228); w.show(t, ask(A1))
    w.run_to(FS + 2400)
    check("R21_a_sighting_with_P_equal_pre_inside_20s_of_the_answer_mints_no_g2_and_no_wake",
          w.silent(t) and w.gens(t) == {1}, w, t)

@scen("R22")
def _():
    w, t = std("r22")
    w.run_to(BASE + 118); w.show(t, ask())
    w.hook = lambda: w.reply(t)                      # between the tick's fold read and its claim write
    w.run_to(BASE + 120)
    w.run_to(BASE + 125); w.show(t, ask(A1))
    w.run_to(FS + 2400)
    md, cl = w.rows(t, "message_delivered"), w.rows(t, "stall_request_claim")
    check("R22_claim_g1_sequenced_after_the_reply_for_g1_stays_answered",
          len(md) == 1 and len(cl) == 1 and md[0][3] < cl[0][3] and w.silent(t), w, t)

@scen("R23")
def _():
    w, t = typed_then_woken("r23")
    w.run_to(BASE + 800); w.ack(t)
    w.run_to(FS + 2400)
    check("R23_typed_answer_then_stall_ack_is_exactly_one_wake_and_no_escalation",
          w.woke(t, 1) and [e[0] for e in w.cp_events(t)] == ["stall_wake"] and w.gens(t) == {1}, w, t)

@scen("R23b")
def _():
    w, t = typed_then_woken("r23b")
    w.run_to(BASE + 800); w.ack(t)
    w.run_to(BASE + 998); w.show(t, ask(A1, A2, CTX_B, REQ_A))
    w.run_to(BASE + 1005 + THRESH + 30)
    check("R23b_after_an_ack_a_same_F_reask_under_a_new_C_claims_g2_and_wakes", w.woke(t, 2), w, t)

@scen("R23c")
def _():
    w, t = typed_then_woken("r23c")
    w.run_to(BASE + 800); w.approval(t)
    w.run_to(BASE + 998); w.show(t, ask(A1, A2, CTX_B, REQ_A))
    w.run_to(BASE + 1005 + THRESH + 30)
    check("R23c_after_an_unrelated_approval_stops_the_ladder_a_new_C_reask_claims_g2_and_wakes",
          w.woke(t, 2), w, t)

@scen("R23d")
def _():
    w, t = typed_then_woken("r23d", below=())
    w.run_to(BASE + 800); w.ack(t)
    w.run_to(BASE + 800 + 2400)
    check("R23d_an_acked_line_unchanged_for_40m_is_silent_with_no_claim_g2",
          len(w.wakes(t)) == 1 and w.silent(t, after=BASE + 800) and w.gens(t) == {1}, w, t)

@scen("R23e")
def _():
    for mode in ("i", "ii"):
        w, t = typed_then_woken(f"r23e{mode}", below=())
        w.run_to(BASE + 761); w.reply(t)                 # owner_acted, then message_delivered{req}
        if mode == "i":
            w.run_to(BASE + 766); w.show(t, ask(A1, A2, A3))
            w.run_to(BASE + 848)                         # idle sightings first
        else:
            w.run_to(BASE + 766)                         # no idle sighting before the re-ask
        w.show(t, ask(A1, A2, A3, CTX_A, REQ_A))
        w.run_to(BASE + 900 + THRESH + 30)
        check(f"R23e_{mode}_reply_after_the_wake_then_a_same_F_C_reask_with_P_equal_pre_claims_g2_and_wakes",
              2 in w.gens(t) and w.woke(t, 2), w, t)

@scen("R23f")
def _():
    w, t = typed_then_woken("r23f", below=())
    w.run_to(BASE + 761); w.ack(t)
    w.run_to(BASE + 766); w.show(t, ask(A1, A2))
    w.run_to(BASE + 848); w.show(t, ask(A1, A2, CTX_A, REQ_A))
    w.run_to(BASE + 855 + THRESH + 30)
    check("R23f_ack_then_output_then_a_same_F_C_reask_with_P_equal_pre_claims_g2_and_wakes",
          2 in w.gens(t) and w.woke(t, 2), w, t)

@scen("R23g")
def _():
    # The debounce runs from the LATEST answering row (§3): ack at +800 retires
    # g1, a captured reply lands at +821 (more than 20s after the ack, before
    # any floor), and the +825 tick still shows P == pre. Ack at +800 with the
    # reply at +900 would not test it: the +825 sighting floors post := pre.
    w, t = typed_then_woken("r23g", below=())
    w.run_to(BASE + 800); w.ack(t)
    w.run_to(BASE + 821); w.reply(t)
    w.run_to(BASE + 830); w.show(t, ask(A1))
    w.run_to(BASE + 821 + 2400)
    check("R23g_ack_then_a_captured_reply_debounces_from_the_reply_so_P_equal_pre_mints_no_g2",
          w.woke(t, 1) and len(w.wakes(t)) == 1 and w.gens(t) == {1} and w.silent(t, after=BASE + 800), w, t)

@scen("R24")
def _():
    w, t = std("r24")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 200)
    w.reply(t, "[HERDR-DENIED] the policy refused rm -rf build/ - change approach.",
            sender="sc:select", flags=("--not-an-answer",))
    w.run_to(FS + THRESH + 60)
    check("R24_a_herdr_denied_not_an_answer_notice_before_the_wake_still_wakes",
          len(w.rows(t, "message_delivered")) == 1 and w.woke(t, 1), w, t)

@scen("R24b")
def _():
    w, t = std("r24b")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 200)
    rid = w.lib("action_request_create", w.run, t, "bash", "ab" * 32, "rm -rf build/", "escalate",
                "deletes a directory", "conductor", "once",
                src=("lib/run-registry.sh", "lib/action-request.sh"))
    w.script("herdr-action.sh", "decline", rid, "--authority", "conductor",
             "--review-reason", "not needed for the release", HERDR_PANE_ID=w.tasks[t]["cond"])
    log = w.simd / "submitted.log"
    told = log.exists() and any("[HERDR-ACTION]" in ln for ln in log.read_text().splitlines())
    w.run_to(FS + THRESH + 60)
    check("R24b_a_herdr_action_notice_before_the_wake_still_wakes", told and w.woke(t, 1), w, t)

def _r25(key, below):
    w, t = std(key.lower())
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 160); w.show(t, ask(RECAP))
    w.run_to(BASE + 221); w.reply(t)
    w.run_to(BASE + 226); w.show(t, ask(RECAP, *below))
    w.run_to(FS + 2400)
    check(f"{key}_recap_after_claim_g1_then_a_{len(below)}_paragraph_answer_is_silent_floor_g1_no_claim_g2",
          w.silent(t) and any(g == 1 for g, _ in w.floors(t)) and w.gens(t) == {1}, w, t)

scen("R25")(lambda: _r25("R25", (A1, A2)))
scen("R25b")(lambda: _r25("R25b", (A1,)))

@scen("R25c")
def _():
    w, t = std("r25c")
    w.run_to(BASE + 118); w.show(t, [FILL, CTX_A, RECAP, REQ_A])
    w.run_to(BASE + 221); w.reply(t)
    w.run_to(BASE + 226); w.show(t, [FILL, CTX_A, RECAP, REQ_A, A1])
    w.run_to(BASE + 498); w.show(t, [FILL, CTX_A, REQ_A, A1])          # the recap is gone
    w.run_to(FS + 2400)
    check("R25c_C_skips_a_recap_directly_above_so_removing_it_mints_no_g2",
          w.silent(t) and w.gens(t) == {1}, w, t)

@scen("R26")
def _():
    w, t = std("r26")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 221); w.reply(t)
    w.run_to(BASE + 223); w.show(t, ask(A1))                            # 4s after: pre+1
    w.run_to(BASE + 262); w.show(t, ask(A1, A2, A3, A4))                # settled: pre+4
    w.run_to(FS + 2400)
    check("R26_the_floor_ratchets_to_the_largest_P_seen_after_the_answer",
          max((p for g, p in w.floors(t) if g == 1), default=None) == 4 and w.silent(t), w, t)

@scen("R26b")
def _():
    w, t = std("r26b")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 221); w.reply(t)
    w.run_to(BASE + 223); w.show(t, ask(A1, A2, STALE))                 # stale render 4s after: pre+3
    w.run_to(BASE + 230); w.show(t, ask(A1, A2))                        # settled: pre+2
    w.run_to(FS + 2400)
    check("R26b_a_stale_sighting_inside_the_debounce_never_raises_the_floor",
          max((p for g, p in w.floors(t) if g == 1), default=None) == 2 and w.gens(t) == {1} and w.silent(t), w, t)

@scen("R26c")
def _():
    w, t = std("r26c")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 221); w.reply(t)
    # Both reads below are OUTSIDE the 20s debounce from the reply, so each
    # can write/ratchet the floor. r2 L2: if the spinner row counted toward
    # P, the first read ratchets the floor to pre+2; the spinner then
    # vanishes (the second read is pre+1, a DROP), `same_line` fails, and a
    # false g2 is claimed. Excluding it (the fix) keeps both reads at pre+1.
    w.run_to(BASE + 251); w.show(t, ask(A1, SPINNER))                   # +30s: pre+2 if spinner counts
    w.run_to(BASE + 311); w.show(t, ask(A1))                            # +90s: spinner gone, pre+1
    w.run_to(FS + 2400)
    check("R26c_a_vanished_spinner_row_never_drops_the_floor_or_mints_g2",
          w.silent(t) and w.gens(t) == {1}, w, t)

@scen("R28")
def _():
    w, t = std("r28")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 200); w.show(t, ask(A1, A2))                                     # A typed-answered
    w.run_to(BASE + 298); w.show(t, ask(A1, A2, CTX_C, REQ_B))
    w.run_to(BASE + 361); w.reply(t)                                                 # captures B
    w.run_to(BASE + 366); w.show(t, ask(A1, A2, CTX_C, REQ_B, A3))
    w.run_to(BASE + 398); w.show(t, ask(A1, A2, CTX_C, REQ_B, A3, CTX_A, REQ_A))    # A rewritten
    w.run_to(BASE + 405 + 2400)
    wk = [e for e in w.cp_events(t) if e[0] == "stall_wake"]
    check("R28_A_rewritten_after_B_was_captured_wakes_once_at_the_new_first_seen_plus_600",
          len(wk) == 1 and wk[0][2] == 2 and w.woke(t, 2, fs=BASE + 405), w, t)

@scen("R28b")
def _():
    # R28, but the rewritten A (new C) is answered by capture BEFORE any tick
    # sights it: the capture opens n+1, it does not answer A's superseded g1.
    w, t = std("r28b")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 200); w.show(t, ask(A1, A2))                                     # A typed-answered
    w.run_to(BASE + 298); w.show(t, ask(A1, A2, CTX_C, REQ_B))
    w.run_to(BASE + 361); w.reply(t)                                                 # captures B
    w.run_to(BASE + 366); w.show(t, ask(A1, A2, CTX_C, REQ_B, A3))
    w.run_to(BASE + 398); w.show(t, ask(A1, A2, CTX_C, REQ_B, A3, CTX_B, REQ_A))    # A rewritten, new C
    w.run_to(BASE + 401); w.reply(t)                                                 # captures rewritten A
    w.run_to(BASE + 403); w.show(t, ask(A1, A2, CTX_C, REQ_B, A3, CTX_B, REQ_A, A4))
    w.run_to(BASE + 405 + 2400)
    check("R28b_the_rewritten_A_answered_by_capture_is_silent_with_no_g2",
          w.silent(t) and w.gens(t) == {1}, w, t)

@scen("R28c")
def _():
    # R28 where B is only ever CAPTURED (never claimed): a capture supersedes
    # like a claim, so rewritten A opens g2 instead of adopting g1's clock.
    w, t = std("r28c")
    w.run_to(BASE + 118); w.show(t, ask())
    w.run_to(BASE + 200); w.show(t, ask(A1, A2))                                     # A typed-answered
    w.run_to(BASE + 286); w.show(t, ask(A1, A2, CTX_C, REQ_B))
    w.run_to(BASE + 291); w.reply(t)                                                 # captures B before the +300 tick
    w.run_to(BASE + 293); w.show(t, ask(A1, A2, CTX_C, REQ_B, A3))
    w.run_to(BASE + 398); w.show(t, ask(A1, A2, CTX_C, REQ_B, A3, CTX_A, REQ_A))    # A rewritten
    w.run_to(BASE + 405 + 2400)
    wk = [e for e in w.cp_events(t) if e[0] == "stall_wake"]
    check("R28c_a_capture_alone_supersedes_so_rewritten_A_wakes_once_at_the_new_first_seen_plus_600",
          sorted(g for g, _, _ in w.claims(t)) == [1, 2] and len(wk) == 1 and wk[0][2] == 2
          and w.woke(t, 2, fs=BASE + 405), w, t)

@scen("R29")
def _():
    # (a) escalated, typed answer, no ack, output, then the same F under a new C.
    w, t = typed_then_woken("r29a", below=())
    w.run_to(FS + 3 * THRESH)
    w.run_to(BASE + 1950); w.show(t, ask(A1, A2))
    w.run_to(BASE + 2048); w.show(t, ask(A1, A2, CTX_B, REQ_A))
    w.run_to(BASE + 2055 + THRESH + 30)
    esc = [e for e in w.cp_events(t) if e[0] == "stall_escalate_claim" and e[2] == 1]
    check("R29a_escalated_then_typed_answer_then_same_F_new_C_claims_g2_and_wakes",
          len(esc) == 1 and w.woke(t, 2), w, t)
    # (b) conductor dead: K_unowned + Slack, ack, output, then the same F under a new C.
    w, t = typed_then_woken("r29b", below=(), cond_alive=False)
    w.run_to(BASE + 800); w.ack(t)
    w.run_to(BASE + 810); w.show(t, ask(A1, A2))
    w.run_to(BASE + 898); w.show(t, ask(A1, A2, CTX_B, REQ_A))
    w.run_to(BASE + 905 + THRESH + 30)
    un = [g for typ, _, g in w.cp_events(t) if typ == "stall_wake_unowned"]
    check("R29b_unowned_then_ack_then_same_F_new_C_claims_g2_and_posts_a_g2_unowned_slack",
          un == [1, 2] and w.woke(t, 2) and len(w.slack(t)) == 2, w, t)
    # (c) an owner row in the same second as K's stall_wake, then a same-C re-ask with P < pre.
    w, t = std("r29c")
    w.run_to(BASE + 118); w.show(t, ask(X1, X2))
    w.run_to(FS + THRESH); w.approval(t)
    w.run_to(BASE + 848); w.show(t, ask(X1, X2, CTX_A, REQ_A))
    w.run_to(BASE + 855 + THRESH + 30)
    wk1 = [a for typ, a, g in w.cp_events(t) if typ == "stall_wake" and g == 1]
    own = [a for _, a, _, _ in w.rows(t, "approval_reviewed")]
    check("R29c_an_owner_row_in_the_wake_second_retires_g1_and_a_lower_P_same_C_reask_claims_g2_and_wakes",
          wk1 == own == [FS + THRESH] and w.woke(t, 2), w, t)
    # (d) (a) up to the escalation, then the line unchanged for 40m.
    w, t = typed_then_woken("r29d", below=())
    w.run_to(FS + 3 * THRESH + 2400)
    check("R29d_an_escalated_line_unchanged_for_40m_is_silent_with_no_g2",
          sorted(e[0] for e in w.cp_events(t)) == ["stall_escalate_claim", "stall_wake"]
          and w.gens(t) == {1} and not w.cands_for(t, after=FS + 3 * THRESH + TICK), w, t)


for rid, fn in SCEN:
    if ONLY and rid not in ONLY:
        continue
    t0 = time.time()
    try:
        fn()
    except Exception:
        results[f"{rid}_CRASHED"] = False
        traceback.print_exc(file=sys.stderr)
    print(f"  ..    {rid} {time.time() - t0:.1f}s", file=sys.stderr)
print(json.dumps(results))
PYEOF
  echo
  echo "===== Section C — DESIGN-228 §7 ====="
  if ! sc_out="$(python3 "$SCFILE" "$here")"; then
    bad "Section C harness crashed — every DESIGN-228 regression is unverified"
    sc_out='{}'
  fi
  _tally "$sc_out"
fi

rm -rf "$WORK"
echo
echo "===== VERIFY ====="
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
