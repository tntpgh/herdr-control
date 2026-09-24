#!/usr/bin/env bash
# verify-herdr-live.sh — the live-state subscriber and its edge dispatcher.
#
# No live herdr, no live panes, no Slack: the state machine is fed fixture
# events directly and agent-edge.sh runs against stub binaries. What is being
# pinned here is the set of things that were WRONG in the first cut and would
# be silently wrong again:
#
#   1. Two event naming schemes on one connection. Subscription-typed events
#      arrive dotted (`pane.agent_status_changed`), the general stream arrives
#      underscored (`pane_agent_status_changed`). Handling only one dropped
#      every status change, and /api/blocked reported `working` for a worker
#      herdr had already reported blocked.
#   2. `pane_updated` fires on OUTPUT and carries the status the record held
#      when it was built, so one racing a status change can flip `blocked`
#      back to `working`.
#   3. A reconnect must be a DIFF, not a reset: transitions that happened
#      while disconnected have to fire, or an alert is lost for good.
#   4. A first observation is NOT a fresh prompt. Alerting on hub start would
#      re-post every already-answered prompt in the fleet.
#   5. The edge dispatcher must not press keys unless explicitly enabled.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }

echo "== state machine (lib/herdr_live.py, fixture events) =="
out=$(python3 - "$HERE" <<'PY'
import sys, json, threading, time
sys.path.insert(0, f"{sys.argv[1]}/lib")
import herdr_live

SNAP_WORKING = {"snapshot": {
    "workspaces": [{"workspace_id": "w1", "label": "repo"}],
    "panes": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
               "agent": "omp", "agent_status": "working", "revision": 10, "cwd": "/repo"}]}}


def fresh():
    """A LiveState that already knows one working omp pane. No socket, no
    threads — the state machine is driven directly by the fixtures below."""
    live = herdr_live.LiveState()
    live._apply_snapshot(SNAP_WORKING)
    return live


def flat(edges):
    return [[p, b, a] for (p, b, a, _rec) in edges]


def pane(status, rev):
    return {"event": "pane_updated", "data": {"type": "pane_updated", "pane": {
        "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "omp",
        "agent_status": status, "revision": rev, "cwd": "/repo"}}}


def status_event(kind, pane_id="w1:p1", status="blocked", agent="omp", ws="w1"):
    return {"event": kind, "data": {"type": kind, "pane_id": pane_id,
                                    "workspace_id": ws, "agent": agent, "agent_status": status}}


results = {}


def outcome(live, edges):
    """Status AFTER the event, plus the edges it emitted. Written as a helper
    because a tuple literal evaluates left to right — reading the status in the
    same expression that applies the event reports the PRE-event value, which
    made four of these cases pass-looking nonsense on the first run."""
    return (live.status("w1:p1"), flat(edges))


# 1/2. BOTH event naming schemes must apply and emit the transition.
live = fresh()
results["dotted_name"] = outcome(live, live._apply_event(status_event("pane.agent_status_changed")))
live = fresh()
results["underscore_name"] = outcome(live, live._apply_event(status_event("pane_agent_status_changed")))

# 3. For a pane whose status events we are subscribed to, a LATE pane_updated
# (herdr delivers them up to ~8s after the fact, at a HIGHER revision than the
# last one we saw, carrying the pre-transition status) must not un-block it —
# however long after the status event it lands. The 3s hold this replaced let
# exactly this row through on the live stream (2026-09-23).
live = fresh()
live._status_covered = {"w1:p1"}
live._apply_event(status_event("pane.agent_status_changed"))
real_time = time.time
time.time = lambda: real_time() + 10    # the row lands 10s after the status event
try:
    results["late_output_row"] = outcome(live, live._apply_event(pane("working", 11)))
finally:
    time.time = real_time

# 4. ...while the real sources still move it: the next status event, and a
# snapshot (current truth) even with no event at all.
live = fresh()
live._status_covered = {"w1:p1"}
live._apply_event(status_event("pane.agent_status_changed"))
unblock = live._apply_event(status_event("pane.agent_status_changed", status="working"))
live._apply_event(status_event("pane.agent_status_changed"))
snap = live._apply_snapshot(SNAP_WORKING)
results["covered_sources"] = (flat(unblock), live.status("w1:p1"), flat(snap))

# 4b. An UNCOVERED pane (degraded mode, or not yet subscribed) has no status
# events, so pane_updated stays its live status signal.
live = fresh()
results["uncovered_output_row"] = outcome(live, live._apply_event(pane("blocked", 11)))

# 5. A lower-revision event (buffered during a bootstrap) is dropped.
live = fresh()
live._apply_event(pane("blocked", 20))
results["revision_guard"] = outcome(live, live._apply_event(pane("idle", 15)))

# 6. A reconnect snapshot DIFFS: a change made while disconnected still fires.
live = fresh()
results["reconnect_diff"] = outcome(live, live._apply_snapshot({"snapshot": {
    "workspaces": [{"workspace_id": "w1", "label": "repo"}],
    "panes": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
               "agent": "omp", "agent_status": "blocked", "revision": 40, "cwd": "/repo"}]}}))

# 7. A pane that vanished while disconnected is dropped, with an edge.
live = fresh()
results["reconnect_drop"] = outcome(
    live, live._apply_snapshot({"snapshot": {"workspaces": [], "panes": []}}))

# 8. A status event for a pane we had not seen is kept, never discarded.
live = fresh()
live._apply_event(status_event("pane.agent_status_changed", pane_id="w9:p9", agent="claude", ws="w9"))
results["unknown_pane"] = (live.status("w9:p9"), [p["pane_id"] for p in live.blocked()])

# 9. The version moves on a change and wakes a long-poll waiter.
live = fresh()
v0 = live.version()
live._apply_event(pane("blocked", 30))
v1 = live.version()
results["version"] = (v1 - v0, live.wait_for_change(v0, 0.1) == v1,
                      live.wait_for_change(v1, 0.05) == v1)

# 10. pane_moved re-keys ONE record, it does not leave a ghost behind.
live = fresh()
live._apply_event({"event": "pane_moved", "data": {
    "type": "pane_moved", "previous_pane_id": "w1:p1", "previous_workspace_id": "w1",
    "previous_tab_id": "w1:t1",
    "pane": {"pane_id": "w2:p1", "workspace_id": "w2", "tab_id": "w2:t1", "agent": "omp",
             "agent_status": "blocked", "revision": 50, "cwd": "/repo"}}})
results["pane_moved"] = ([p["pane_id"] for p in live.panes()], live.status("w2:p1"))

# 11. Delivery: an edge reaches the callback on the worker thread, and a
# callback that raises does not kill the drainer or lose the next edge.
seen, errors = [], []
live = herdr_live.LiveState(on_transition=lambda p, b, a, r: (_ for _ in ()).throw(RuntimeError("boom"))
                            if p == "bad" else seen.append([p, b, a]),
                            log=lambda m: errors.append(m))
threading.Thread(target=live._drain_edges, daemon=True).start()

live._emit([("bad", "working", "blocked", {}), ("w1:p1", "working", "blocked", {})])
deadline = time.time() + 3
while time.time() < deadline and not seen:
    time.sleep(0.05)
live.stop()
results["delivery"] = (seen, len(errors) == 1)

# 12. Which edges are worth a subprocess (hub.py). A busy pane flips
# working<->idle every turn; spawning a shell per flap to conclude "noop" is
# the busywork this change exists to remove.
import importlib.util
spec = importlib.util.spec_from_file_location("hubmod", f"{sys.argv[1]}/hub.py")
hubmod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hubmod)
results["actionable"] = {
    "first_sight": hubmod.edge_is_actionable(None, "idle"),
    "became_blocked": hubmod.edge_is_actionable("working", "blocked"),
    "was_blocked": hubmod.edge_is_actionable("blocked", "idle"),
    "pane_gone_while_blocked": hubmod.edge_is_actionable("blocked", None),
    "working_idle_flap": hubmod.edge_is_actionable("working", "idle"),
    "idle_working_flap": hubmod.edge_is_actionable("idle", "working"),
    "done_flap": hubmod.edge_is_actionable("working", "done"),
}

# 14. A RECYCLED pane id is a NEW pane. herdr restarts revision numbering per
# pane, so if the revision guard is applied across a birth change, every update
# for the new occupant is dropped FOREVER: status, agent and cwd stay those of
# the dead pane and no edge ever fires.
live = fresh()
occupant_a = {"event": "pane_updated", "data": {"type": "pane_updated", "pane": {
    "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "omp",
    "agent_status": "blocked", "revision": 90, "cwd": "/repo",
    "terminal_id": "term_OLD"}}}
live._apply_event(occupant_a)           # occupant A, high revision, known birth
recycled = {"event": "pane_updated", "data": {"type": "pane_updated", "pane": {
    "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "claude",
    "agent_status": "working", "revision": 2, "cwd": "/other",
    "terminal_id": "term_NEW"}}}
edges = live._apply_event(recycled)
rec = [p for p in live.panes() if p["pane_id"] == "w1:p1"][0]
results["recycled_pane"] = (rec["agent"], rec["agent_status"], flat(edges))

# 15. Degraded mode must actually STREAM. After STATUS_SUBS_GIVE_UP_AFTER
# rejections the subscription set carries no per-pane entries, and the
# post-bootstrap "am I covering every pane?" check then saw every pane as
# uncovered and returned "resubscribe" BEFORE the read loop — a connect +
# session.snapshot cycle that never streamed and never slept (measured 767,698
# connects in 2s against a stub, with connected:true and last_error:null).
live = fresh()
live._subscribe_failures = herdr_live.STATUS_SUBS_GIVE_UP_AFTER
subs, covered = live._subscriptions()
results["degraded_shape"] = (
    [s for s in subs if s["type"] == "pane.agent_status_changed"] == [],
    len(covered) == 0,
    # degraded mode carries no per-pane subs (the loop itself keys on the counter)
    any(s["type"] == "pane.agent_status_changed" for s in subs) is False,
)

# 13. A CLOSED pane must not wedge the subscription. One per-pane
# `pane.agent_status_changed` subscription for a pane herdr has closed makes
# the server reject the WHOLE events.subscribe with `pane_not_found`; the
# first cut then backed off and rebuilt the same list from the same stale
# state, so one closed pane (w8:p2F, live on 2026-09-15) stopped the
# subscription permanently — connected:false, frozen panes, every consumer
# quietly back on stale data. Recovery is to re-snapshot (pruning the pane)
# and retry at once. `request` is stubbed here: no socket, no live herdr.
snapshots = []


def fake_snapshot(method, params=None, timeout=5.0):
    snapshots.append(method)
    return {"snapshot": {"workspaces": [{"workspace_id": "w1", "label": "repo"}],
                         "panes": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                                    "agent": "omp", "agent_status": "working", "revision": 10,
                                    "cwd": "/repo"}]}}


herdr_live.request = fake_snapshot
live = fresh()
live._panes["w1:pDEAD"] = dict(live._panes["w1:p1"], pane_id="w1:pDEAD")
had_dead = "w1:pDEAD" in [p["pane_id"] for p in live.panes()]
recoverable = live._subscribe_rejected(
    {"error": {"code": "pane_not_found", "message": "pane w1:pDEAD not found"}})
results["closed_pane"] = {
    "seeded": had_dead,
    "recoverable": recoverable,
    "resnapshotted": snapshots == ["session.snapshot"],
    "pruned": "w1:pDEAD" not in [p["pane_id"] for p in live.panes()],
    "counted": live.data()["stats"]["subscribe_pruned"] == 1,
}
# Any OTHER rejection is not silently retried — it raises and backs off.
results["other_rejection"] = live._subscribe_rejected({"error": {"code": "internal", "message": "boom"}})
# And a fleet churning panes faster than we can resubscribe degrades to
# lifecycle-only rather than losing the stream.
live._subscribe_failures = herdr_live.STATUS_SUBS_GIVE_UP_AFTER
subs, covered = live._subscriptions()
results["degraded_subs"] = (
    [s for s in subs if s["type"] == "pane.agent_status_changed"] == [],
    len(covered) == 0,
    any(s["type"] == "pane.updated" for s in subs),
)

# 16. A BUSY stream must not starve the resync. herdr flips agent_status
# without bumping revision, so a pane that goes blocked and then sits quiet has
# no later event to correct it if the status event never arrives. The resync
# used to run only after 600s with NO event at all, which a working fleet
# never produces — live 2026-09-23, a worker sat blocked on an allow-class
# command for 3 minutes while the hub said working at the same revision.
# Here another pane streams an event every 10ms for the whole run.
def two_panes(p1_status):
    return {"snapshot": {"workspaces": [{"workspace_id": "w1", "label": "repo"}], "panes": [
        {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "omp",
         "agent_status": p1_status, "revision": 10, "cwd": "/repo"},
        {"pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "omp",
         "agent_status": "working", "revision": 100, "cwd": "/repo"}]}}


class BusyWire:
    def __init__(self, *a, **k):
        self.n = 0

    def send(self, obj):
        pass

    def read(self, timeout):
        self.n += 1
        if self.n == 1:
            return {"id": "herdr-live", "result": {"type": "subscription_started"}}
        time.sleep(0.01)
        return {"event": "pane_updated", "data": {"type": "pane_updated", "pane": {
            "pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "omp",
            "agent_status": "working", "revision": 100 + self.n, "cwd": "/repo"}}}

    def close(self):
        pass


truth_calls = []


def truth_snapshot(method, params=None, timeout=5.0):
    truth_calls.append(method)
    # The bootstrap sees w1:p1 working; after that herdr has flipped it to
    # blocked at the SAME revision and no status event ever reaches the wire.
    return two_panes("working" if len(truth_calls) == 1 else "blocked")


real_wire = herdr_live._Wire
herdr_live._Wire, herdr_live.request = BusyWire, truth_snapshot
live = herdr_live.LiveState(resync_every_s=0.3)
live._apply_snapshot(two_panes("working"))
t = threading.Thread(target=live._connect_and_stream, daemon=True)
t.start()
time.sleep(1.0)
live.stop()
t.join(2)
herdr_live._Wire = real_wire
st = live.data()["stats"]
results["busy_stream_resync"] = (live.status("w1:p1"), st["resyncs"] >= 1, st["events"] > 20)

# 17. A FRESH process must reach per-pane status subscriptions. It knows no
# panes at first, so its first subscribe has no per-pane entry — which the loop
# used to read as "degraded", after which it never resubscribed: after every
# hub restart no status event arrived until some pane was created.
sent = []


class RecordingWire:
    def __init__(self, *a, **k):
        self.n = 0

    def send(self, obj):
        sent.append(obj)

    def read(self, timeout):
        self.n += 1
        if self.n == 1:
            return {"id": "herdr-live", "result": {"type": "subscription_started"}}
        time.sleep(min(timeout, 0.02))
        return None

    def close(self):
        pass


herdr_live._Wire, herdr_live.request = RecordingWire, lambda *a, **k: two_panes("working")
live = herdr_live.LiveState(resync_every_s=60)
box = {}
t1 = threading.Thread(target=lambda: box.update(first=live._connect_and_stream()), daemon=True)
t1.start()
t1.join(1.0)                                            # the bug: this connect streams forever
first = box.get("first", "never returned: streamed with no per-pane subscriptions")
if "first" in box:
    t = threading.Thread(target=live._connect_and_stream, daemon=True)
    t.start()
    time.sleep(0.3)
covered_while_streaming = sorted(getattr(live, "_status_covered", set()))
live.stop()
t1.join(2)
if "first" in box:
    t.join(2)
herdr_live._Wire = real_wire
per_pane = [sorted(s["pane_id"] for s in m["params"]["subscriptions"] if s["type"] == "pane.agent_status_changed")
            for m in sent]
results["fresh_process_coverage"] = (first, per_pane, covered_while_streaming)

# PR #131 review, P2: on_connection_change must fire on a genuine flip only —
# never on a same-state resubscribe (the success path in _connect_and_stream
# can run repeatedly without ever having disconnected) — and must fire for
# BOTH halves of a real outage (disconnect, then reconnect), not just one.
conn_calls = []
conn_live = herdr_live.LiveState(on_connection_change=lambda c, e: conn_calls.append([c, e]))
conn_live._set_connected(True)                 # initial connect — not part of either assertion below
conn_calls.clear()
conn_live._set_connected(True)                 # same-state resubscribe
results["conn_resubscribe_fires"] = len(conn_calls)
conn_calls.clear()
conn_live._set_connected(False, "socket reset")   # disconnect
conn_live._set_connected(True)                    # reconnect
results["conn_flip_sequence_fires"] = len(conn_calls)
results["conn_flip_sequence_values"] = conn_calls

print(json.dumps(results))
PY
) || { echo "  FAIL python harness did not run: $out"; exit 1; }

get() { printf '%s' "$out" | jq -c ".$1"; }

[ "$(get dotted_name)" = '["blocked",[["w1:p1","working","blocked"]]]' ] \
  && ok "dotted pane.agent_status_changed applies and emits an edge" \
  || no "dotted name" "$(get dotted_name)"
[ "$(get underscore_name)" = '["blocked",[["w1:p1","working","blocked"]]]' ] \
  && ok "underscored pane_agent_status_changed applies too" \
  || no "underscore name" "$(get underscore_name)"
[ "$(get late_output_row)" = '["blocked",[]]' ] \
  && ok "a late output row cannot un-block a covered pane" || no "late output row" "$(get late_output_row)"
[ "$(get covered_sources)" = '[[["w1:p1","blocked","working"]],"working",[["w1:p1","blocked","working"]]]' ] \
  && ok "a covered pane still moves on its status event and on a snapshot" \
  || no "covered sources" "$(get covered_sources)"
[ "$(get uncovered_output_row)" = '["blocked",[["w1:p1","working","blocked"]]]' ] \
  && ok "an uncovered pane still takes its status from pane_updated" \
  || no "uncovered output row" "$(get uncovered_output_row)"
[ "$(get revision_guard)" = '["blocked",[]]' ] \
  && ok "a lower-revision event is dropped" || no "revision guard" "$(get revision_guard)"
[ "$(get reconnect_diff)" = '["blocked",[["w1:p1","working","blocked"]]]' ] \
  && ok "a reconnect snapshot fires the transition it missed" || no "reconnect diff" "$(get reconnect_diff)"
[ "$(get reconnect_drop)" = '[null,[["w1:p1","working",null]]]' ] \
  && ok "a pane gone while disconnected is dropped with an edge" || no "reconnect drop" "$(get reconnect_drop)"
[ "$(get unknown_pane)" = '["blocked",["w9:p9"]]' ] \
  && ok "blocked is never dropped for a pane we had not seen" || no "unknown pane" "$(get unknown_pane)"
[ "$(get version)" = '[1,true,true]' ] \
  && ok "version moves on change, wakes a waiter, and holds a current one" || no "version" "$(get version)"
[ "$(get pane_moved)" = '[["w2:p1"],"blocked"]' ] \
  && ok "pane_moved re-keys one record, not two" || no "pane_moved" "$(get pane_moved)"
[ "$(get delivery)" = '[[["w1:p1","working","blocked"]],true]' ] \
  && ok "an edge reaches the callback, and a throwing callback loses nothing after it" \
  || no "delivery" "$(get delivery)"
[ "$(get 'actionable | [.first_sight, .became_blocked, .was_blocked, .pane_gone_while_blocked]')" = '[true,true,true,true]' ] \
  && ok "blocked edges and first sightings reach the dispatcher" \
  || no "actionable" "$(get actionable)"
[ "$(get 'actionable | [.working_idle_flap, .idle_working_flap, .done_flap]')" = '[false,false,false]' ] \
  && ok "a working<->idle flap never spawns anything" || no "flap filter" "$(get actionable)"
# `before` is null, not "blocked": a recycled id is a NEW pane, so it reads as
# a FIRST OBSERVATION, which agent-edge.sh handles as reconcile-only (no alert,
# no keypress) and the registry birth guard refuses to write against the
# previous occupant's task. Reporting it as a transition OF the dead pane would
# attribute a stranger's prompt to that worker's task, which is the failure the
# birth guard exists to prevent.
[ "$(get recycled_pane)" = '["claude","working",[["w1:p1",null,"working"]]]' ] \
  && ok "a recycled pane id is treated as a NEW pane, not a stale revision" \
  || no "recycled pane" "$(get recycled_pane)"
[ "$(get degraded_subs)" = '[true,true,true]' ] \
  && ok "repeated rejections degrade to lifecycle-only rather than losing the stream" \
  || no "degraded subs" "$(get degraded_subs)"
[ "$(get degraded_shape)" = '[true,true,true]' ] \
  && ok "degraded mode reports itself as covering every pane, so it streams" \
  || no "degraded shape" "$(get degraded_shape)"
[ "$(get 'closed_pane | [.seeded, .recoverable, .resnapshotted, .pruned, .counted]')" = '[true,true,true,true,true]' ] \
  && ok "a closed pane is pruned and the subscription retried, not wedged" \
  || no "closed pane" "$(get closed_pane)"
[ "$(get other_rejection)" = 'false' ] \
  && ok "any other rejection still raises and backs off" || no "other rejection" "$(get other_rejection)"
[ "$(get degraded_subs)" = '[true,true,true]' ] \
  && ok "repeated rejections degrade to lifecycle-only rather than losing the stream" \
  || no "degraded subs" "$(get degraded_subs)"
[ "$(get busy_stream_resync)" = '["blocked",true,true]' ] \
  && ok "a busy stream still resyncs, so a quiet blocked pane is corrected" \
  || no "busy stream resync" "$(get busy_stream_resync)"
[ "$(get fresh_process_coverage)" = '[true,[[],["w1:p1","w1:p2"]],["w1:p1","w1:p2"]]' ] \
  && ok "a fresh process resubscribes once and covers every pane" \
  || no "fresh process coverage" "$(get fresh_process_coverage)"
[ "$(get conn_resubscribe_fires)" = '0' ] \
  && ok "on_connection_change: a same-state resubscribe fires zero times" \
  || no "conn resubscribe" "$(get conn_resubscribe_fires)"
[ "$(get conn_flip_sequence_fires)" = '2' ] \
  && ok "on_connection_change: connected->disconnected->connected fires exactly twice" \
  || no "conn flip sequence" "$(get conn_flip_sequence_fires) $(get conn_flip_sequence_values)"
[ "$(get conn_flip_sequence_values)" = '[[false,"socket reset"],[true,null]]' ] \
  && ok "on_connection_change carries the right (connected, err) pair each time" \
  || no "conn flip values" "$(get conn_flip_sequence_values)"

echo
echo "== edge dispatcher (agent-edge.sh, stubbed) =="
tmp=$(mktemp -d "${TMPDIR:-/tmp}/verify-edge.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/bridge"

# Stubs via the script's documented seams (config.sh exports its own PATH, so
# PATH shadowing does not work here). Nothing real is reachable: no Slack, no
# keypress, no hub.
# The probe reads the hub, so the stub must answer the way the hub does:
# `connected` plus a panes ARRAY. STUB_DOWN makes it unreachable (the
# "could not look" case, which must NOT be read as "cleared").
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
[ -n "${STUB_DOWN:-}" ] && exit 7
if [ -n "${STUB_CLEARED:-}" ]; then echo '{"connected":true,"panes":[{"pane_id":"w1:p1","agent_status":"idle"},{"pane_id":"w1:p9","agent_status":"idle"}]}'
else echo '{"connected":true,"panes":[{"pane_id":"w1:p1","agent_status":"blocked"},{"pane_id":"w1:p9","agent_status":"blocked"}]}'; fi
STUB
cat > "$tmp/bin/record" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$STUB_LOG"
exit 0
STUB
# The real herdr-notify appends {ts,pane} to pending.jsonl when it is given
# --choices (that is what makes the alert retractable). The stub models that,
# so the suite can tell a queued backstop from an un-queued one — the HIGH
# finding this branch fixes. STUB_NOTIFY_NOQUEUE models the broken case.
cat > "$tmp/bin/notify" <<'STUB'
#!/usr/bin/env bash
echo "notify $*" >> "$STUB_LOG"
case " $* " in *" --choices "*) ;; *) exit 0 ;; esac
[ -n "${STUB_NOTIFY_NOQUEUE:-}" ] && exit 0
printf '{"ts":"%s","pane":"w1:p1"}\n' "$(date +%s)" >> "$STUB_PENDING"
exit 0
STUB
chmod +x "$tmp/bin/curl" "$tmp/bin/record" "$tmp/bin/notify"
for name in resolve peer-answer; do cp "$tmp/bin/record" "$tmp/bin/$name"; done

run_edge() {                            # <status> <previous> [env assignments...]
  : > "$tmp/log"
  # HERDR_RUN_STATE_DIR is set for EVERY case, not only the registry section:
  # without it these runs call task_for_pane/set_task_state against the REAL
  # ~/.local/state/herdr/runs registry, and a suite that mutates live
  # control-plane state is one nobody can run on a working machine. Callers may
  # still override it (the registry section points it at its own root).
  env STUB_LOG="$tmp/log" STUB_PENDING="$tmp/bridge/pending.jsonl" \
      HERDR_RUN_STATE_DIR="$tmp/runs-isolated" \
      HERDR_STATE_DIR="$tmp/state" HERDR_BRIDGE_STATE="$tmp/bridge" \
      HERDR_EDGE_ALERT_GRACE_S=0 \
      HERDR_EDGE_CURL="$tmp/bin/curl" HERDR_EDGE_NOTIFY="$tmp/bin/notify" \
      HERDR_EDGE_RESOLVE="$tmp/bin/resolve" HERDR_EDGE_PEER_ANSWER_SH="$tmp/bin/peer-answer" \
      "${@:3}" \
      bash "$HERE/agent-edge.sh" w1:p1 "$1" "$2" omp /repo >/dev/null 2>&1
  tail -1 "$tmp/state/agent-edges.jsonl" 2>/dev/null
}

did() { printf '%s' "$1" | jq -r '.did // ""'; }

line=$(run_edge blocked "")
case "$(did "$line")" in "registry-follow-only (first observation) reg="*) true ;; *) false ;; esac \
  && ok "first observation of a blocked pane records state and alerts nothing" \
  || no "first observation" "$line"

# ...and with standing authority it ANSWERS that prompt while still alerting
# nothing. A pane that was already blocked when the hub started produces no
# further transition, so this is the only chance to clear it; three review
# lanes sat stranded through exactly this gap on 2026-09-18.
line=$(run_edge blocked "" HERDR_EDGE_PEER_ANSWER=1)
case "$(did "$line")" in "peer-answer(first observation) reg="*) true ;; *) false ;; esac \
  && grep -q "^peer-answer .*w1:p1" "$tmp/log" \
  && ! grep -q "^notify" "$tmp/log" \
  && ok "first observation answers an allow-class prompt and still alerts nothing" \
  || no "first-observation peer-answer" "$line $(cat "$tmp/log")"
# Without the grant it must stay exactly as before: record, answer nothing.
: > "$tmp/log"
line=$(run_edge blocked "")
case "$(did "$line")" in "registry-follow-only (first observation) reg="*) [ ! -s "$tmp/log" ] ;; *) false ;; esac \
  && ok "without standing authority a first observation answers nothing" \
  || no "first observation ungranted" "$line $(cat "$tmp/log")"

line=$(run_edge idle "")
case "$(did "$line")" in "registry-heal (first observation) reg="*) [ ! -s "$tmp/log" ] ;; *) false ;; esac \
  && ok "first sight of an unblocked pane heals the registry, alerts nothing" \
  || no "registry heal" "$line $(cat "$tmp/log")"

line=$(run_edge blocked working)
case "$(did "$line")" in "backstop alert (queued for retraction) reg="*) true ;; *) false ;; esac \
  && grep -q "^notify --choices --pane w1:p1" "$tmp/log" \
  && ok "the backstop alerts WITH --choices, so the alert is queued and answerable" \
  || no "backstop" "$line $(cat "$tmp/log")"
rm -f "$tmp/bridge/pending.jsonl"

# The HIGH finding this replaced: an alert posted with no pending entry is
# un-retractable, invisible to the dedupe, and button-less. If that ever
# happens again the audit line must SAY so instead of reading like a success.
line=$(run_edge blocked working STUB_NOTIFY_NOQUEUE=1)
case "$(did "$line")" in *"NOT QUEUED"*) true ;; *) false ;; esac \
  && ok "an alert that failed to queue is recorded as NOT QUEUED, not as success" \
  || no "unqueued alert" "$line"
rm -f "$tmp/bridge/pending.jsonl"

line=$(run_edge blocked working STUB_CLEARED=1)
[ "$(did "$line")" = "cleared within grace, no alert" ] && ! grep -q "^notify" "$tmp/log" \
  && ok "a prompt answered inside the grace window is not alerted" || no "grace" "$line"

# "Could not look" must never read as "cleared": that suppressed the page in
# exactly the conditions where the control plane is least healthy, and wrote
# `cleared within grace` into the audit file while doing it.
line=$(run_edge blocked working STUB_DOWN=1)
case "$(did "$line")" in *"probe unreachable"*|*"NOT QUEUED"*|*"queued for retraction"*) true ;; *) false ;; esac \
  && grep -q "^notify --choices" "$tmp/log" \
  && ok "an unreachable probe alerts anyway, and says the probe failed" \
  || no "probe unknown" "$line $(cat "$tmp/log")"
rm -f "$tmp/bridge/pending.jsonl"

printf '{"ts":"1","pane":"w1:p1"}\n' > "$tmp/bridge/pending.jsonl"
line=$(run_edge blocked working)
[ "$(did "$line")" = "already alerted by the worker's own hook" ] && ! grep -q "^notify" "$tmp/log" \
  && ok "no double alert when the hook already queued one" || no "dedupe" "$line"
rm -f "$tmp/bridge/pending.jsonl"

line=$(run_edge blocked working)
grep -q "^peer-answer" "$tmp/log" \
  && no "peer-answer default" "auto-answer ran without being enabled" \
  || ok "auto-answering is off unless HERDR_EDGE_PEER_ANSWER=1"

line=$(run_edge blocked working HERDR_EDGE_PEER_ANSWER=1)
grep -q "^peer-answer --max-rounds 1 --agent omp w1:p1" "$tmp/log" \
  && ok "opting in answers exactly one round, for that pane only" \
  || no "peer-answer opt-in" "$(cat "$tmp/log")"

line=$(run_edge working blocked)
case "$(did "$line")" in "unblocked: registry running + retract reg="*) true ;; *) false ;; esac && grep -q "^resolve" "$tmp/log" \
  && ok "unblocking follows the registry and retracts the alert" || no "unblock" "$line"

line=$(run_edge working idle)
[ "$(did "$line")" = "noop" ] && [ ! -s "$tmp/log" ] \
  && ok "a working<->idle flap does no work at all" || no "flap" "$line $(cat "$tmp/log")"

echo
echo "== registry follow (real sqlite registry, isolated root) =="
# The case that failed live and looked like it had worked: the audit line said
# `registry-heal` while the row stayed `blocked`. The stub tests above cannot
# catch that — they never touch a registry — so this one drives the repo's own
# run-registry against a throwaway root.
regroot="$tmp/runs"
mkdir -p "$regroot"
env HERDR_RUN_STATE_DIR="$regroot" bash -c '
  . "'"$HERE"'/config.sh"; . "'"$HERE"'/lib/run-registry.sh"
  register_task run_v task_v worker_v conductor_v c:p1 birth1 w1:p1 birth2 /repo /wt lane >/dev/null
  set_task_state run_v task_v blocked >/dev/null' 2>/dev/null
before=$(sqlite3 "$regroot/registry.sqlite3" "select state from tasks where task_id='task_v';" 2>/dev/null)
line=$(run_edge idle "" HERDR_RUN_STATE_DIR="$regroot")
after=$(sqlite3 "$regroot/registry.sqlite3" "select state from tasks where task_id='task_v';" 2>/dev/null)
[ "$before" = "blocked" ] && [ "$after" = "running" ] && [ "$(did "$line")" = "registry-heal (first observation) reg=running" ] \
  && ok "a stale blocked row is healed, and the audit line says reg=running" \
  || no "registry follow" "before=$before after=$after did=$(did "$line")"

# And a terminal row is never resurrected: the registry's own legality rule.
env HERDR_RUN_STATE_DIR="$regroot" bash -c '
  . "'"$HERE"'/config.sh"; . "'"$HERE"'/lib/run-registry.sh"
  set_task_state run_v task_v completed no-follow-on >/dev/null' 2>/dev/null
rm -f "$tmp/bridge/pending.jsonl"   # or the dedupe exits before the audit line
line=$(run_edge blocked working HERDR_RUN_STATE_DIR="$regroot")
after=$(sqlite3 "$regroot/registry.sqlite3" "select state from tasks where task_id='task_v';" 2>/dev/null)
[ "$after" = "completed" ] && case "$(did "$line")" in *"reg=refused("*) true ;; *) false ;; esac \
  && ok "a completed task is not dragged back to blocked, and the refusal is recorded" \
  || no "terminal guard" "after=$after did=$(did "$line")"

# A RECYCLED pane id must not let this writer touch the previous occupant's
# row. Every other writer in the repo refuses on a birth mismatch; this one
# could not until the live record carried terminal_id.
env HERDR_RUN_STATE_DIR="$regroot" bash -c '
  . "'"$HERE"'/config.sh"; . "'"$HERE"'/lib/run-registry.sh"
  register_task run_b task_b worker_b conductor_b c:p1 birth1 w1:p9 REGISTERED-BIRTH /repo /wt lane >/dev/null
  set_task_state run_b task_b running >/dev/null' 2>/dev/null
rm -f "$tmp/bridge/pending.jsonl"
: > "$tmp/log"
env STUB_LOG="$tmp/log" STUB_PENDING="$tmp/bridge/pending.jsonl" \
    HERDR_STATE_DIR="$tmp/state" HERDR_BRIDGE_STATE="$tmp/bridge" HERDR_EDGE_ALERT_GRACE_S=0 \
    HERDR_EDGE_CURL="$tmp/bin/curl" HERDR_EDGE_NOTIFY="$tmp/bin/notify" \
    HERDR_EDGE_RESOLVE="$tmp/bin/resolve" HERDR_EDGE_PEER_ANSWER_SH="$tmp/bin/peer-answer" \
    HERDR_RUN_STATE_DIR="$regroot" \
    bash "$HERE/agent-edge.sh" w1:p9 blocked working omp /repo LIVE-BIRTH-DIFFERENT >/dev/null 2>&1
after=$(sqlite3 "$regroot/registry.sqlite3" "select state from tasks where task_id='task_b';" 2>/dev/null)
line=$(tail -1 "$tmp/state/agent-edges.jsonl" 2>/dev/null)
[ "$after" = "running" ] && case "$(did "$line")" in *"pane recycled"*) true ;; *) false ;; esac \
  && ok "a birth mismatch refuses the write and names it as a recycled pane" \
  || no "birth guard" "after=$after did=$(did "$line")"

# ...and a MATCHING birth still heals, so the guard is not just "always refuse".
rm -f "$tmp/bridge/pending.jsonl"
env STUB_LOG="$tmp/log" STUB_PENDING="$tmp/bridge/pending.jsonl" \
    HERDR_STATE_DIR="$tmp/state" HERDR_BRIDGE_STATE="$tmp/bridge" HERDR_EDGE_ALERT_GRACE_S=0 \
    HERDR_EDGE_CURL="$tmp/bin/curl" HERDR_EDGE_NOTIFY="$tmp/bin/notify" \
    HERDR_EDGE_RESOLVE="$tmp/bin/resolve" HERDR_EDGE_PEER_ANSWER_SH="$tmp/bin/peer-answer" \
    HERDR_RUN_STATE_DIR="$regroot" \
    bash "$HERE/agent-edge.sh" w1:p9 blocked working omp /repo REGISTERED-BIRTH >/dev/null 2>&1
after=$(sqlite3 "$regroot/registry.sqlite3" "select state from tasks where task_id='task_b';" 2>/dev/null)
[ "$after" = "blocked" ] \
  && ok "a matching birth still writes the state" || no "birth match" "after=$after"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
