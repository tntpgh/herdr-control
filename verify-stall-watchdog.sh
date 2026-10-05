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

# ═══════════════════════ Section B — hub.py detector ═════════════════════════
if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 not found — cannot exercise hub.py's stall_watchdog_candidates"
else
  PYFILE="$WORK/check_stall_watchdog.py"
  cat > "$PYFILE" <<'PYEOF'
import sys, json, importlib.util, os, sqlite3, subprocess, time, textwrap, inspect

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

def cw(now_epoch, reason=None):   # stub live_done_fn: constant (epoch, reason)
    return lambda worktree: (now_epoch, reason)

# review H1/M1 (r6): `claim_fn` defaults to `_stall_request_claim`, which
# touches the REAL registry — every fixture below that only cares about
# fingerprint/pane-shape behavior (not reply-suppression timing) must
# override it so it never falls through to that default before `hub.
# REGISTRY` is pointed at the scratch db further down.
NO_CLAIM = lambda tid, fp, now: 0.0

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


def _safe_signals4(label, **kw):
    """Review L1 (d): isolate a `_stall_task_signals` arity/shape change
    to the ONE call site that unpacks it, instead of raising out of this
    whole inline script -- round-2's M3 failure mode, reopened by r3's own
    L1 (reverting the arity fix crashed with 0 keys surviving).

    Review L1 (r7): records `False`, not a truthy string -- see
    `_safe_candidates`."""
    try:
        denied_, delivered_, owner_acted_, replied_ = hub._stall_task_signals(**kw)
        return denied_, delivered_, owner_acted_, replied_
    except Exception as exc:
        results[f"{label}_CRASHED"] = False
        print(f"{label}_CRASHED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return {}, {}, {}, {}


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
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
results["N3_conductor_prompt_fires_against_realistic_omp_chrome"] = any(
    c["signal"] == "conductor_prompt" for c in cands)
# The naive "literal last row" check this replaces would see the composer's
# own closing border as the last line and never match — proven directly.
results["N3_last_row_of_raw_chrome_is_not_the_conductor_line"] = (
    not hub._ANSI_RE.sub("", CHROME).splitlines()[-2].strip().startswith("CONDUCTOR:"))
# Ordinary scrollback with no such line never fires it.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_NO_PROMPT, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
results["M1_silent_without_a_conductor_line"] = cands == []
# A task state outside (stalled, ready_review) never reads the pane at all —
# review N1/M-b's state-allowlist (`lost`/`cancelled`/`gone` used to be
# included via `state != "completed"`).
t7_gone = base_task(state="gone", stored_state="gone", pane_id="p1", pane_birth="pb1",
                    updated_at="2026-01-01T00:00:00Z")
cands = hub.stall_watchdog_candidates(
    [t7_gone], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
results["Mb_conductor_prompt_silent_outside_idle_states"] = cands == []
# review M-b: the live pane's birth no longer matches what this task
# registered (herdr recycled the pane id to an unrelated task) -> silent,
# even with a real CONDUCTOR: line sitting there.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "some-other-birth", claim_fn=NO_CLAIM)
results["Mb_conductor_prompt_silent_on_a_recycled_pane"] = cands == []
# Live birth unknown (LIVE disconnected, or herdr never answered) -> fails
# closed, same reasoning.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: None, claim_fn=NO_CLAIM)
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
    pane_read_fn=lambda pane: _h1_window_default, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
results["H1_46col_wrapped_request_plus_recap_fires_in_the_real_window"] = any(
    c["signal"] == "conductor_prompt" for c in cands)
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: _h1_window_20, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
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
    pane_read_fn=lambda pane: CHROME_WRAPPED, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
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
    pane_read_fn=lambda pane: CHROME_RECAP_A, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
results["M1_fires_when_a_recap_block_follows_the_request"] = any(
    c["signal"] == "conductor_prompt" for c in cands)
fp_recap_a = next((c["fingerprint"] for c in cands if c["signal"] == "conductor_prompt"), None)
# A re-render/scroll that only changes the trailing recap text (same
# request, same blank-line boundary) must NOT re-arm the claim.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_RECAP_B, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
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
    pane_read_fn=lambda pane: _l1_chrome_at(46), pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
cands_70 = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: _l1_chrome_at(70), pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
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
    pane_read_fn=lambda pane: CHROME_BOLD, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
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
        pane_read_fn=lambda pane, _t=_h1r5_text: _t, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
    results[_h1r5_key] = any(c["signal"] == "conductor_prompt" for c in cands)

# ---- review H1/M1/M2/L2/L3 (r7): a REAL multi-tick timing/reply-binding
# proof against a real scratch registry, with the real default `claim_fn`
# -- never a `claim_fn` stub that hands back a fixed epoch (review M1's
# own finding: that shape can never let the GATE decide when the claim
# happens, which is exactly how H1 got through r6). See the
# "review H1/M1/M2/L2/L3 (r7)" section further down, once `hub.REGISTRY`
# is pointed at the real scratch database.


# ---- mutation harness: each revert variant is installed, exercised and
# restored in its own try/except/finally -- review M3: `next()` without a
# default used to raise StopIteration here and crash this ENTIRE inline
# script, which the bash harness below (`if ! py_out=...`) then reports as
# ONE "crashed" FAIL while silently dropping every other Section B result.
# Isolating each mutant means one exception can take down only its own
# result key, never the mutants -- or anything else -- around it.
def _naive_last_conductor_prompt_line(text):
    """pre-#228: literal last non-blank row, no markdown strip, no
    continuation join, no answered-guard."""
    if not text:
        return None
    for line in reversed(hub._agent_output_lines(text)):
        line = hub._ANSI_RE.sub("", line).strip()
        if not line:
            continue
        return line if line.startswith("CONDUCTOR:") else None
    return None

real_last_conductor_prompt_line = hub._last_conductor_prompt_line

def _run_mutant(mut_name, mut_fn, checks):
    """checks: [(result_key, pane_text, expect_fire)]. Installs mut_fn,
    runs every check against it, restores the real function even if a
    check raises -- and records a crash as its OWN result instead of
    letting it propagate and take the rest of Section B with it."""
    hub._last_conductor_prompt_line = mut_fn
    try:
        for result_key, pane_text, expect_fire in checks:
            try:
                cands = hub.stall_watchdog_candidates(
                    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
                    pane_read_fn=lambda pane: pane_text, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
                fired = any(c["signal"] == "conductor_prompt" for c in cands)
                results[result_key] = (fired == expect_fire)
            except Exception:
                results[f"{mut_name}:{result_key}_CRASHED"] = False
    finally:
        hub._last_conductor_prompt_line = real_last_conductor_prompt_line

# The plain one-row case predates this review round's fix and must survive
# every revert too -- proof each mutation targets only what it claims to.
_run_mutant("REVERT_full_naive", _naive_last_conductor_prompt_line, [
    ("REVERT_M1_wrap_fix_caught_on_revert", CHROME_WRAPPED, False),
    ("REVERT_M1_recap_fix_caught_on_revert", CHROME_RECAP_A, False),
    ("REVERT_M1_bold_fix_caught_on_revert", CHROME_BOLD, False),
    ("REVERT_M1_plain_case_unaffected_by_the_revert", CHROME, True),
])

cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_WRAPPED, pane_birth_fn=lambda pane: "pb1", claim_fn=NO_CLAIM)
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
conn.execute(
    f"INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
    f"VALUES ('stall_request_claim_dtask_{hub._sw_digest('cprompt:dtask-probe')}',"
    "'drun','dtask','stall_request_claim','2026-01-01T00:00:00Z','{}')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('ev1','drun','dtask','message_delivered','2026-01-01T00:00:00Z','{}')")
conn.commit(); conn.close()
denied, delivered, owner_acted, replied = _safe_signals4("sig_dtask", now=REG_NOW, threshold_s=REG_THRESH)
results["M2_denied_query_finds_the_approval_escalated_row"] = denied.get("dtask", {}).get("fingerprint") == "esc1"
results["delivered_query_finds_an_unprocessed_message"] = "dtask" in delivered
# review H1 (r5): `replied` is populated from the SAME message_delivered
# row `delivered` reads above, regardless of what happens after it --
# unlike `delivered`, it is never cleared by later worker activity.
results["H1_r5_replied_query_finds_the_message_delivered_row"] = "dtask" in replied

# ---- review M2 (r6): `replied` must never expire -- a genuinely old
# reply (well past the OLD 8x-threshold cutoff) still proves the request
# was answered and must keep silencing it, forever, not just for 80
# minutes.
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask_oldreply','drun','stalled','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')")
conn.execute(
    f"INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
    f"VALUES ('stall_request_claim_dtask_oldreply_{hub._sw_digest('cprompt:oldreply-probe')}',"
    "'drun','dtask_oldreply','stall_request_claim','2020-01-01T00:00:00Z','{}')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('ev_oldreply','drun','dtask_oldreply','message_delivered','2020-01-01T00:00:00Z','{}')")
conn.commit(); conn.close()
_, _, _, replied_old = _safe_signals4("sig_m2r6", now=REG_NOW, threshold_s=REG_THRESH)
results["M2_r6_replied_query_is_unbounded_an_ancient_reply_still_counts"] = "dtask_oldreply" in replied_old

# ---- mutant (review M2 r6): reverting to the WINDOWED replied query
# (e5c3478's own shape) must MISS this same ancient reply -- the exact
# M2 bug (an answered request re-fired once its reply aged past 8x the
# threshold).
def _m2r6_windowed_replied(conn_, now_, threshold_s_):
    cutoff_ = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now_ - threshold_s_ * 8))
    out_ = {}
    for tid_, occurred_at_ in conn_.execute(
            "SELECT task_id, MAX(occurred_at) FROM events WHERE task_id != '' "
            "AND type='message_delivered' AND occurred_at >= ? GROUP BY task_id", (cutoff_,)):
        ep_ = hub._iso_epoch(occurred_at_)
        if ep_ is not None:
            out_[tid_] = ep_
    return out_
ro = sqlite3.connect(f"file:{hub.REGISTRY}?mode=ro", uri=True)
windowed_replied = _m2r6_windowed_replied(ro, REG_NOW, REG_THRESH)
ro.close()
results["REVERT_M2r6_windowed_replied_query_misses_the_ancient_reply"] = "dtask_oldreply" not in windowed_replied

# ---- review L1 (d): prove isolation really works -- a `_stall_task_
# signals` arity change crashes only ITS OWN call, never the rest of
# Section B (round-2's M3 failure mode, reopened by r3's own L1).
_real_signals = hub._stall_task_signals
def _l1d_arity_mutant(*a, **kw):
    return _real_signals(*a, **kw)[:3]   # 3-tuple instead of 4
def _safe_signals4_isolated(label, local_results, **kw):
    """Same crash isolation as `_safe_signals4`, but records into a LOCAL
    dict, not the shared `results` -- this call's crash is the MUTANT
    ITSELF (deliberately induced, to prove isolation works), never an
    unexpected regression, so it must never count against the suite's own
    pass/fail tally the way a real crash would (that is exactly what the
    shared `_safe_signals4` is for)."""
    try:
        denied_, delivered_, owner_acted_, replied_ = hub._stall_task_signals(**kw)
        return denied_, delivered_, owner_acted_, replied_
    except Exception as exc:
        local_results[f"{label}_CRASHED"] = True
        print(f"{label}_CRASHED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return {}, {}, {}, {}
hub._stall_task_signals = _l1d_arity_mutant
_l1d_local: dict = {}
_safe_signals4_isolated("L1d_arity_mutant", _l1d_local, now=REG_NOW, threshold_s=REG_THRESH)
hub._stall_task_signals = _real_signals
results["L1_d_arity_mutant_is_isolated_not_fatal"] = "L1d_arity_mutant_CRASHED" in _l1d_local
results["L1_d_script_continues_running_after_an_arity_mutant"] = True


# review M-c(2): a WAY-older approval_escalated row, with no later worker
# activity, falls outside the window and must not populate `denied` —
# proof the bound is real, not just "still works for recent rows".
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask_old','drun','stalled','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('esc_old','drun','dtask_old','approval_escalated','2020-01-01T00:00:00Z','{}')")
conn.commit(); conn.close()
denied_old, _, _, _ = _safe_signals4("sig_mc2", now=REG_NOW, threshold_s=REG_THRESH)
results["Mc2_a_window_bounded_scan_excludes_ancient_rows"] = "dtask_old" not in denied_old

# review M2: a HUMAN pressing Approve on a deny-CLASSIFIED prompt (policy_verdict
# stayed 'deny', the human's own choice was Approve) must NEVER read as "denied".
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask2','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO approvals (approval_id, task_id, authority, policy_verdict, choice_text, decided_at) "
             "VALUES ('appr_human_ok','dtask2','human','deny','Approve','2026-01-01T00:00:00Z')")
conn.commit(); conn.close()
denied2, _, _, _ = _safe_signals4("sig_m2human", now=REG_NOW, threshold_s=REG_THRESH)
results["M2_human_approve_on_a_deny_classified_prompt_never_fires_denied"] = "dtask2" not in denied2

# A human's OWN declining choice (independent of policy_verdict) is still the
# same real signal from the other path.
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask3','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO approvals (approval_id, task_id, authority, policy_verdict, choice_text, decided_at) "
             "VALUES ('appr_deny3','dtask3','human','allow','2. Deny','2026-01-01T00:00:00Z')")
conn.commit(); conn.close()
denied3, _, _, _ = _safe_signals4("sig_m2decline", now=REG_NOW, threshold_s=REG_THRESH)
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
_, delivered4, _, _ = _safe_signals4("sig_h4", now=REG_NOW, threshold_s=REG_THRESH)
results["H4_herdr_deliver_ordering_still_reads_as_unprocessed"] = "t_deliver" in delivered4
results["H4_genuine_worker_activity_clears_unprocessed"] = "t_worker_acted" not in delivered4

# review H1: owner_acted is populated from the real owner-activity types.
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('t_owner','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('oa1','drun','t_owner','owner_acted','2026-01-01T02:00:00Z','{}')")
conn.commit(); conn.close()
_, _, owner_acted2, _ = _safe_signals4("sig_owner", now=REG_NOW, threshold_s=REG_THRESH)
results["owner_acted_populated_from_owner_acted_events"] = "t_owner" in owner_acted2

# A later event from the SAME task (real worker activity) clears "unprocessed".
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('ev2','drun','dtask','input_required','2026-01-01T00:05:00Z','{}')")
conn.commit(); conn.close()
_, delivered5, _, _ = _safe_signals4("sig_cleared", now=REG_NOW, threshold_s=REG_THRESH)
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

# ---- review H1/M1 (r6): `_stall_request_claim` persists the FIRST-seen
# epoch for a (task_id, fingerprint) pair, exactly once, against the REAL
# registry -- `claim_fn`'s default in production (every test above stubs
# it instead, since it must never touch Terrence's real registry).
_claim_t1 = time.time() - 500
claimed1 = hub._stall_request_claim("rtask", "cprompt:aaa", _claim_t1)
results["H1r6_claim_persists_the_first_seen_epoch"] = abs(claimed1 - _claim_t1) < 2
# A LATER call for the SAME (task, fingerprint), with a different `now`,
# reads back the SAME epoch -- it never re-floors to the new `now`, the
# exact property that keeps it immune to a later, unrelated prompt.
claimed1_again = hub._stall_request_claim("rtask", "cprompt:aaa", time.time())
results["H1r6_claim_is_idempotent_on_a_second_call"] = claimed1_again == claimed1
# A DIFFERENT fingerprint for the SAME task gets its OWN, independent claim.
_claim_t2 = time.time() - 100
claimed2 = hub._stall_request_claim("rtask", "cprompt:bbb", _claim_t2)
results["H1r6_claim_is_independent_per_fingerprint"] = (
    abs(claimed2 - _claim_t2) < 2 and claimed2 != claimed1)

# ---- review H1/M1/M2/L2/L3 (r7): real claim/reply timing ---------------------
# Everything below runs against the REAL scratch `hub.REGISTRY` (pointed
# there at line ~838) with the REAL default `claim_fn`/`_stall_task_
# signals` -- never a stub that hands back a fixed epoch. Review M1's own
# finding: a `claim_fn` stub can never let the GATE decide when the claim
# happens, which is exactly the shape that let H1 through r6.

# == H1: the claim is minted on the first tick the request is VISIBLE, ==
# == never the first tick the idle-duration threshold has also cleared. ==
NOW_H1 = hub._iso_epoch("2026-02-01T00:00:00Z")
THRESH_H1 = 600.0
BOOT_H1 = NOW_H1 - 100_000.0
T0 = NOW_H1 - 200.0   # idle 200s ago -- NOT yet past the 600s threshold
h1_task = base_task(task_id="h1_task", pane_id="h1_pane", pane_birth="h1_birth",
                    updated_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T0)))

# Tick 1: the request line is already visible; the OLD gate would never
# even look (threshold not yet elapsed) -- so it must stay silent...
denied1, delivered1, owner1, replied1 = hub._stall_task_signals(now=T0, threshold_s=THRESH_H1)
cands1 = hub.stall_watchdog_candidates(
    [h1_task], now=T0, threshold_s=THRESH_H1, boot_epoch=BOOT_H1,
    denied=denied1, delivered=delivered1, owner_acted=owner1, replied=replied1,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "h1_birth")
results["H1_r7_not_yet_past_threshold_stays_silent_on_tick_one"] = cands1 == []
# ...but the claim must ALREADY be minted, at (approximately) T0 -- the
# first SIGHT, never the first GATED look.
_h1_line = hub._last_conductor_prompt_line(CHROME)
fp_h1 = hub._conductor_prompt_fingerprint(_h1_line)
ro = sqlite3.connect(f"file:{hub.REGISTRY}?mode=ro", uri=True)
claim_row = ro.execute(
    "SELECT occurred_at FROM events WHERE event_id=?",
    (f"stall_request_claim_h1_task_{hub._sw_digest(fp_h1)}",)).fetchone()
ro.close()
results["H1_r7_claim_minted_on_first_sight_despite_threshold_not_elapsed"] = (
    claim_row is not None and abs(hub._iso_epoch(claim_row[0]) - T0) < 2)

# A real reply lands shortly after -- well before the threshold elapses.
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('h1_reply','drun','h1_task','message_delivered',?,'{}')",
             (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T0 + 50)),))
conn.commit(); conn.close()

# Tick 2: NOW past threshold -- the OLD code's first (and only) gated
# look. The already-answered request must stay silent.
NOW2 = T0 + 700.0
denied2, delivered2, owner2, replied2 = hub._stall_task_signals(now=NOW2, threshold_s=THRESH_H1)
cands2 = hub.stall_watchdog_candidates(
    [h1_task], now=NOW2, threshold_s=THRESH_H1, boot_epoch=BOOT_H1,
    denied=denied2, delivered=delivered2, owner_acted=owner2, replied=replied2,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "h1_birth")
results["H1_r7_a_reply_that_predates_the_old_gated_look_still_counts_as_answered"] = not any(
    c["signal"] == "conductor_prompt" for c in cands2)

# Revert mutant -- head 5e76419's OWN gate structure (claim minted ONLY
# once since/threshold/owner_acted has already opened), run against the
# SAME real `_stall_request_claim` and the SAME reply timing, on a
# separate task so its own claim store never collides with h1_task's.
def _old_structure_signal5(tasks_, now_, replied_flat_, threshold_s_, boot_epoch_,
                           pane_read_fn_, pane_birth_fn_, claim_fn_):
    out_ = []
    for t_ in tasks_:
        tid_ = t_.get("task_id")
        if t_.get("state") in ("stalled", "ready_review") and t_.get("pane_id"):
            since_ = hub._iso_epoch(t_.get("updated_at"))
            if since_ is not None and since_ >= boot_epoch_ and now_ - since_ >= threshold_s_:
                live_birth_ = pane_birth_fn_(t_["pane_id"])
                reg_birth_ = t_.get("pane_birth") or ""
                if live_birth_ and reg_birth_ and live_birth_ == reg_birth_:
                    line_ = hub._last_conductor_prompt_line(pane_read_fn_(t_["pane_id"]))
                    if line_:
                        fp_ = hub._conductor_prompt_fingerprint(line_)
                        claimed_at_ = claim_fn_(tid_, fp_, now_)
                        reply_epoch_ = replied_flat_.get(tid_)
                        if reply_epoch_ is None or reply_epoch_ < claimed_at_:
                            out_.append({"task_id": tid_, "signal": "conductor_prompt", "fingerprint": fp_})
    return out_

h1_old_task = base_task(task_id="h1_task_old", pane_id="h1_pane", pane_birth="h1_birth",
                        updated_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T0)))
_old_structure_signal5([h1_old_task], T0, {}, THRESH_H1, BOOT_H1,
                       pane_read_fn_=lambda pane: CHROME, pane_birth_fn_=lambda pane: "h1_birth",
                       claim_fn_=hub._stall_request_claim)   # tick 1: gate closed, no claim minted
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('h1_old_reply','drun','h1_task_old','message_delivered',?,'{}')",
             (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T0 + 50)),))
conn.commit(); conn.close()
old_replied_flat = {"h1_task_old": T0 + 50}   # the one fact e5c3478's own flat `replied` carried
old_cands2 = _old_structure_signal5([h1_old_task], NOW2, old_replied_flat, THRESH_H1, BOOT_H1,
                                    pane_read_fn_=lambda pane: CHROME, pane_birth_fn_=lambda pane: "h1_birth",
                                    claim_fn_=hub._stall_request_claim)
results["REVERT_H1r7_old_gate_structure_wakes_on_an_already_answered_request"] = any(
    c["signal"] == "conductor_prompt" for c in old_cands2)

# == M2: a re-ask with NEW text wakes via conductor_prompt (new ==
# == fingerprint, new first-seen epoch) even through a LATER, unrelated ==
# == owner_acted/approval -- never gated behind it. ==
NOW_M2 = hub._iso_epoch("2026-02-02T00:00:00Z")
THRESH_M2 = 600.0
BOOT_M2 = NOW_M2 - 100_000.0
T0_M2 = NOW_M2 - 700.0   # already well past threshold from tick one
m2_task = base_task(task_id="m2_task", pane_id="m2_pane", pane_birth="m2_birth",
                    updated_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T0_M2)))

denied_a, delivered_a, owner_a, replied_a = hub._stall_task_signals(now=NOW_M2, threshold_s=THRESH_M2)
cands_a = hub.stall_watchdog_candidates(
    [m2_task], now=NOW_M2, threshold_s=THRESH_M2, boot_epoch=BOOT_M2,
    denied=denied_a, delivered=delivered_a, owner_acted=owner_a, replied=replied_a,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "m2_birth")
results["M2_r7_request_A_wakes_first"] = any(c["signal"] == "conductor_prompt" for c in cands_a)

conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('m2_reply_a','drun','m2_task','message_delivered',?,'{}')",
             (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW_M2 + 30)),))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('m2_approval','drun','m2_task','approval_reviewed',?,'{}')",
             (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW_M2 + 400)),))
conn.commit(); conn.close()

NOW_M2B = NOW_M2 + 500.0
denied_b, delivered_b, owner_b, replied_b = hub._stall_task_signals(now=NOW_M2B, threshold_s=THRESH_M2)
cands_b = hub.stall_watchdog_candidates(
    [m2_task], now=NOW_M2B, threshold_s=THRESH_M2, boot_epoch=BOOT_M2,
    denied=denied_b, delivered=delivered_b, owner_acted=owner_b, replied=replied_b,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "m2_birth")
results["M2_r7_A_stays_silenced_through_the_unrelated_later_approval"] = not any(
    c["signal"] == "conductor_prompt" for c in cands_b)

CHROME_B = ("an earlier line of agent output\n"
           "CONDUCTOR: a totally different question now, please advise\n"
           "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 42% \u2500\u2500\u256e\n"
           "\u2502 >                                          \u2502\n"
           "\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n")
NOW_M2C = NOW_M2 + 900.0
denied_c, delivered_c, owner_c, replied_c = hub._stall_task_signals(now=NOW_M2C, threshold_s=THRESH_M2)
results["M2_r7_owner_acted_is_populated_and_recent"] = (
    owner_c.get("m2_task") is not None and owner_c["m2_task"] > T0_M2)
cands_c = hub.stall_watchdog_candidates(
    [m2_task], now=NOW_M2C, threshold_s=THRESH_M2, boot_epoch=BOOT_M2,
    denied=denied_c, delivered=delivered_c, owner_acted=owner_c, replied=replied_c,
    pane_read_fn=lambda pane: CHROME_B, pane_birth_fn=lambda pane: "m2_birth")
results["M2_r7_a_brand_new_reask_wakes_despite_a_recent_unrelated_owner_acted"] = any(
    c["signal"] == "conductor_prompt" for c in cands_c)

# Revert mutant: head 5e76419's OWN `owner_acted < since` guard, run on
# the SAME real owner_acted/since/claim/replied data -- must silence B.
def _old_owner_gate_signal5(tasks_, now_, owner_acted_flat_, threshold_s_, boot_epoch_,
                            pane_read_fn_, pane_birth_fn_, claim_fn_, replied_nested_):
    out_ = []
    for t_ in tasks_:
        tid_ = t_.get("task_id")
        if t_.get("state") in ("stalled", "ready_review") and t_.get("pane_id"):
            since_ = hub._iso_epoch(t_.get("updated_at"))
            owner_epoch_ = owner_acted_flat_.get(tid_)
            if (since_ is not None and since_ >= boot_epoch_ and now_ - since_ >= threshold_s_
                    and (owner_epoch_ is None or owner_epoch_ < since_)):
                live_birth_ = pane_birth_fn_(t_["pane_id"])
                reg_birth_ = t_.get("pane_birth") or ""
                if live_birth_ and reg_birth_ and live_birth_ == reg_birth_:
                    line_ = hub._last_conductor_prompt_line(pane_read_fn_(t_["pane_id"]))
                    if line_:
                        fp_ = hub._conductor_prompt_fingerprint(line_)
                        claimed_at_ = claim_fn_(tid_, fp_, now_)
                        reply_epoch_ = replied_nested_.get(tid_, {}).get(hub._sw_digest(fp_))
                        if reply_epoch_ is None or reply_epoch_ < claimed_at_:
                            out_.append({"task_id": tid_, "signal": "conductor_prompt", "fingerprint": fp_})
    return out_

old_cands_c = _old_owner_gate_signal5(
    [m2_task], NOW_M2C, owner_c, THRESH_M2, BOOT_M2,
    pane_read_fn_=lambda pane: CHROME_B, pane_birth_fn_=lambda pane: "m2_birth",
    claim_fn_=hub._stall_request_claim, replied_nested_=replied_c)
results["REVERT_M2r7_old_owner_acted_gate_silences_the_new_reask"] = old_cands_c == []

# == L2: a reply binds to the OLDEST still-open claim for its task -- a ==
# == reply owed to an older request must never silence an unrelated, ==
# == newer one. ==
digest_a = hub._sw_digest("cprompt:l2-A")
digest_b = hub._sw_digest("cprompt:l2-B")
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) VALUES "
             f"('stall_request_claim_l2_task_{digest_a}','drun','l2_task','stall_request_claim',"
             "'2026-03-01T00:00:00Z','{}'),"
             f"('stall_request_claim_l2_task_{digest_b}','drun','l2_task','stall_request_claim',"
             "'2026-03-01T00:11:00Z','{}')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('l2_reply','drun','l2_task','message_delivered','2026-03-01T00:12:00Z','{}')")
conn.commit(); conn.close()
ro = sqlite3.connect(f"file:{hub.REGISTRY}?mode=ro", uri=True)
l2_matches = hub._stall_reply_matches(ro)
ro.close()
results["L2_r7_the_older_claim_is_answered"] = digest_a in l2_matches.get("l2_task", {})
results["L2_r7_the_newer_unrelated_claim_is_not_silenced_by_a_reply_owed_to_the_older_one"] = (
    digest_b not in l2_matches.get("l2_task", {}))

# Revert mutant: the OLD per-task "latest reply" shape (e5c3478/r6's own
# flat `replied[task_id] = epoch`) carries no per-fingerprint identity, so
# the SAME reply would ALSO read as answering B, the real L2 bug.
old_flat_reply_epoch = hub._iso_epoch("2026-03-01T00:12:00Z")
claim_b_epoch = hub._iso_epoch("2026-03-01T00:11:00Z")
results["REVERT_L2r7_old_flat_per_task_reply_would_have_silenced_B_too"] = (
    old_flat_reply_epoch >= claim_b_epoch)

# == L3: a claim the registry never confirmed is never trusted as "just ==
# == now" -- the candidate is skipped, not fabricated as answered. ==
real_registry_l3 = hub.REGISTRY
hub.REGISTRY = __import__("pathlib").Path(os.environ["WORK"]) / "does-not-exist" / "registry.sqlite3"
l3_claim = hub._stall_request_claim("l3_task", "cprompt:l3", time.time())
results["L3_r7_claim_returns_None_when_the_registry_is_unreachable"] = l3_claim is None
hub.REGISTRY = real_registry_l3

l3_task = base_task(task_id="l3_task2", pane_id="l3_pane", pane_birth="l3_birth",
                    updated_at="2026-04-01T00:00:00Z")
NOW_L3 = hub._iso_epoch("2026-04-01T00:20:00Z")
THRESH_L3 = 600.0
BOOT_L3 = NOW_L3 - 100_000.0

def _failing_claim(tid_, fp_, now_):
    return None   # review L3: what a write failure must return now

cands_l3 = hub.stall_watchdog_candidates(
    [l3_task], now=NOW_L3, threshold_s=THRESH_L3, boot_epoch=BOOT_L3,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "l3_birth",
    claim_fn=_failing_claim)
results["L3_r7_candidate_is_skipped_when_the_claim_cannot_be_confirmed"] = cands_l3 == []

# Revert mutant: the OLD "fail open to now" fallback wakes anyway, even
# with a real reply dated shortly BEFORE `now` sitting right there.
l3_line = hub._last_conductor_prompt_line(CHROME)
l3_fp = hub._conductor_prompt_fingerprint(l3_line)
l3_digest = hub._sw_digest(l3_fp)

def _old_failing_claim_falls_open(tid_, fp_, now_):
    return now_   # e5c3478/r6's own fallback

cands_l3_old = hub.stall_watchdog_candidates(
    [l3_task], now=NOW_L3, threshold_s=THRESH_L3, boot_epoch=BOOT_L3,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "l3_birth",
    replied={"l3_task2": {l3_digest: NOW_L3 - 300}},
    claim_fn=_old_failing_claim_falls_open)
results["REVERT_L3r7_falling_open_to_now_wakes_an_already_answered_request"] = any(
    c["signal"] == "conductor_prompt" for c in cands_l3_old)



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
