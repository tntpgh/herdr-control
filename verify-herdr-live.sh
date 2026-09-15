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

# 3. An output event racing the status change must not un-block the pane.
live = fresh()
live._apply_event(status_event("pane.agent_status_changed"))
results["sticky"] = outcome(live, live._apply_event(pane("working", 11)))

# 4. ...but the hold expires, so a genuine unblock still lands.
live = fresh()
live._apply_event(status_event("pane.agent_status_changed"))
live._status_event_at["w1:p1"] -= (herdr_live.STATUS_EVENT_STICKY_S + 1)
results["sticky_expires"] = outcome(live, live._apply_event(pane("working", 12)))

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
[ "$(get sticky)" = '["blocked",[]]' ] \
  && ok "a racing output event cannot un-block the pane" || no "sticky" "$(get sticky)"
[ "$(get sticky_expires)" = '["working",[["w1:p1","blocked","working"]]]' ] \
  && ok "the status hold expires, so a real unblock still lands" || no "sticky expiry" "$(get sticky_expires)"
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

echo
echo "== edge dispatcher (agent-edge.sh, stubbed) =="
tmp=$(mktemp -d "${TMPDIR:-/tmp}/verify-edge.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/bridge"

# Stubs via the script's documented seams (config.sh exports its own PATH, so
# PATH shadowing does not work here). Nothing real is reachable: no Slack, no
# keypress, no hub.
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
if [ -n "${STUB_CLEARED:-}" ]; then echo '{"panes":[{"pane_id":"w1:p1","agent_status":"idle"}]}'
else echo '{"panes":[{"pane_id":"w1:p1","agent_status":"blocked"}]}'; fi
STUB
cat > "$tmp/bin/record" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$tmp/bin/curl" "$tmp/bin/record"
for name in notify resolve peer-answer; do cp "$tmp/bin/record" "$tmp/bin/$name"; done

run_edge() {                            # <status> <previous> [env assignments...]
  : > "$tmp/log"
  env STUB_LOG="$tmp/log" \
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

line=$(run_edge idle "")
case "$(did "$line")" in "registry-heal (first observation) reg="*) [ ! -s "$tmp/log" ] ;; *) false ;; esac \
  && ok "first sight of an unblocked pane heals the registry, alerts nothing" \
  || no "registry heal" "$line $(cat "$tmp/log")"

line=$(run_edge blocked working)
case "$(did "$line")" in "backstop alert reg="*) true ;; *) false ;; esac && grep -q "^notify --pane w1:p1" "$tmp/log" \
  && ok "a real block with no hook alert gets the backstop, via notify" || no "backstop" "$line $(cat "$tmp/log")"

line=$(run_edge blocked working STUB_CLEARED=1)
[ "$(did "$line")" = "cleared within grace, no alert" ] && ! grep -q "^notify" "$tmp/log" \
  && ok "a prompt answered inside the grace window is not alerted" || no "grace" "$line"

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
grep -q "^peer-answer --max-rounds 1 w1:p1" "$tmp/log" \
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
  set_task_state run_v task_v completed >/dev/null' 2>/dev/null
line=$(run_edge blocked working HERDR_RUN_STATE_DIR="$regroot")
after=$(sqlite3 "$regroot/registry.sqlite3" "select state from tasks where task_id='task_v';" 2>/dev/null)
[ "$after" = "completed" ] && case "$(did "$line")" in *"reg=refused("*) true ;; *) false ;; esac \
  && ok "a completed task is not dragged back to blocked, and the refusal is recorded" \
  || no "terminal guard" "after=$after did=$(did "$line")"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
