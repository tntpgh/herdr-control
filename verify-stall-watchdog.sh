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
import sys, json, importlib.util, os, sqlite3, subprocess, time

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
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "pb1")
results["N3_conductor_prompt_fires_against_realistic_omp_chrome"] = any(
    c["signal"] == "conductor_prompt" for c in cands)
# The naive "literal last row" check this replaces would see the composer's
# own closing border as the last line and never match — proven directly.
results["N3_last_row_of_raw_chrome_is_not_the_conductor_line"] = (
    not hub._ANSI_RE.sub("", CHROME).splitlines()[-2].strip().startswith("CONDUCTOR:"))
# Ordinary scrollback with no such line never fires it.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_NO_PROMPT, pane_birth_fn=lambda pane: "pb1")
results["M1_silent_without_a_conductor_line"] = cands == []
# The owner already acted after the pane's last line -> silent.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "pb1",
    owner_acted={"t1": NOW - 1})
results["M1_silent_once_the_owner_already_acted"] = cands == []
# A task state outside (stalled, ready_review) never reads the pane at all —
# review N1/M-b's state-allowlist (`lost`/`cancelled`/`gone` used to be
# included via `state != "completed"`).
t7_gone = base_task(state="gone", stored_state="gone", pane_id="p1", pane_birth="pb1",
                    updated_at="2026-01-01T00:00:00Z")
cands = hub.stall_watchdog_candidates(
    [t7_gone], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "pb1")
results["Mb_conductor_prompt_silent_outside_idle_states"] = cands == []
# review M-b: the live pane's birth no longer matches what this task
# registered (herdr recycled the pane id to an unrelated task) -> silent,
# even with a real CONDUCTOR: line sitting there.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "some-other-birth")
results["Mb_conductor_prompt_silent_on_a_recycled_pane"] = cands == []
# Live birth unknown (LIVE disconnected, or herdr never answered) -> fails
# closed, same reasoning.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: None)
results["Mb_conductor_prompt_silent_when_birth_cannot_be_confirmed"] = cands == []

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
    pane_read_fn=lambda pane: CHROME_WRAPPED, pane_birth_fn=lambda pane: "pb1")
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
    pane_read_fn=lambda pane: CHROME_RECAP_A, pane_birth_fn=lambda pane: "pb1")
results["M1_fires_when_a_recap_block_follows_the_request"] = any(
    c["signal"] == "conductor_prompt" for c in cands)
fp_recap_a = next(c["fingerprint"] for c in cands if c["signal"] == "conductor_prompt")
# A re-render/scroll that only changes the trailing recap text (same
# request, same blank-line boundary) must NOT re-arm the claim.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_RECAP_B, pane_birth_fn=lambda pane: "pb1")
fp_recap_b = next(c["fingerprint"] for c in cands if c["signal"] == "conductor_prompt")
results["M1_a_rerendered_recap_is_not_a_new_fingerprint"] = fp_recap_a == fp_recap_b

CHROME_BOLD = ("an earlier line of agent output\n"
              "**CONDUCTOR:** approve request ar_11 or tell me why not\n"
              "\u256d\u2500\u2500 omp \u00b7 sonnet \u00b7 ctx 42% \u2500\u2500\u256e\n"
              "\u2502 >                                          \u2502\n"
              "\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n")
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_BOLD, pane_birth_fn=lambda pane: "pb1")
results["M1_fires_on_a_bold_markdown_conductor_marker"] = any(
    c["signal"] == "conductor_prompt" for c in cands)

# ---- M1 revert-proof: the PRE-FIX detector (literal last-non-blank-row,
# no markdown strip) is installed in memory over the real one — no git
# checkout/stash — and must go silent on exactly the three shapes above,
# while the plain one-row case (N3, already fixed before this review round)
# still fires either way.
def _naive_last_conductor_prompt_line(text):
    if not text:
        return None
    for line in reversed(hub._agent_output_lines(text)):
        line = hub._ANSI_RE.sub("", line).strip()
        if not line:
            continue
        return line if line.startswith("CONDUCTOR:") else None
    return None

real_last_conductor_prompt_line = hub._last_conductor_prompt_line
hub._last_conductor_prompt_line = _naive_last_conductor_prompt_line

cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_WRAPPED, pane_birth_fn=lambda pane: "pb1")
results["REVERT_M1_wrap_fix_caught_on_revert"] = not any(
    c["signal"] == "conductor_prompt" for c in cands)
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_RECAP_A, pane_birth_fn=lambda pane: "pb1")
results["REVERT_M1_recap_fix_caught_on_revert"] = not any(
    c["signal"] == "conductor_prompt" for c in cands)
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_BOLD, pane_birth_fn=lambda pane: "pb1")
results["REVERT_M1_bold_fix_caught_on_revert"] = not any(
    c["signal"] == "conductor_prompt" for c in cands)
# The plain one-row case predates this round's fix and must survive the
# revert too — proof the mutation targets only what M1 actually changed.
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME, pane_birth_fn=lambda pane: "pb1")
results["REVERT_M1_plain_case_unaffected_by_the_revert"] = any(
    c["signal"] == "conductor_prompt" for c in cands)

hub._last_conductor_prompt_line = real_last_conductor_prompt_line
cands = hub.stall_watchdog_candidates(
    [t7], now=NOW, threshold_s=THRESH, boot_epoch=BOOT,
    pane_read_fn=lambda pane: CHROME_WRAPPED, pane_birth_fn=lambda pane: "pb1")
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
denied, delivered, owner_acted = hub._stall_task_signals(now=REG_NOW, threshold_s=REG_THRESH)
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
denied_old, _, _ = hub._stall_task_signals(now=REG_NOW, threshold_s=REG_THRESH)
results["Mc2_a_window_bounded_scan_excludes_ancient_rows"] = "dtask_old" not in denied_old

# review M2: a HUMAN pressing Approve on a deny-CLASSIFIED prompt (policy_verdict
# stayed 'deny', the human's own choice was Approve) must NEVER read as "denied".
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask2','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO approvals (approval_id, task_id, authority, policy_verdict, choice_text, decided_at) "
             "VALUES ('appr_human_ok','dtask2','human','deny','Approve','2026-01-01T00:00:00Z')")
conn.commit(); conn.close()
denied2, _, _ = hub._stall_task_signals(now=REG_NOW, threshold_s=REG_THRESH)
results["M2_human_approve_on_a_deny_classified_prompt_never_fires_denied"] = "dtask2" not in denied2

# A human's OWN declining choice (independent of policy_verdict) is still the
# same real signal from the other path.
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('dtask3','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO approvals (approval_id, task_id, authority, policy_verdict, choice_text, decided_at) "
             "VALUES ('appr_deny3','dtask3','human','allow','2. Deny','2026-01-01T00:00:00Z')")
conn.commit(); conn.close()
denied3, _, _ = hub._stall_task_signals(now=REG_NOW, threshold_s=REG_THRESH)
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
_, delivered4, _ = hub._stall_task_signals(now=REG_NOW, threshold_s=REG_THRESH)
results["H4_herdr_deliver_ordering_still_reads_as_unprocessed"] = "t_deliver" in delivered4
results["H4_genuine_worker_activity_clears_unprocessed"] = "t_worker_acted" not in delivered4

# review H1: owner_acted is populated from the real owner-activity types.
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO tasks (task_id, run_id, state, created_at, updated_at) "
             "VALUES ('t_owner','drun','stalled','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')")
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('oa1','drun','t_owner','owner_acted','2026-01-01T02:00:00Z','{}')")
conn.commit(); conn.close()
_, _, owner_acted2 = hub._stall_task_signals(now=REG_NOW, threshold_s=REG_THRESH)
results["owner_acted_populated_from_owner_acted_events"] = "t_owner" in owner_acted2

# A later event from the SAME task (real worker activity) clears "unprocessed".
conn = sqlite3.connect(str(hub.REGISTRY))
conn.execute("INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
             "VALUES ('ev2','drun','dtask','input_required','2026-01-01T00:05:00Z','{}')")
conn.commit(); conn.close()
_, delivered5, _ = hub._stall_task_signals(now=REG_NOW, threshold_s=REG_THRESH)
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
hub._stall_watchdog_tick()
results["rule_removed_stays_silent_on_a_real_candidate"] = calls == []

# restored — the same scenario now fires.
hub.STALL_WATCHDOG_SCRIPT = real_script
hub._stall_watchdog_tick()
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
hub._stall_watchdog_tick()
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
