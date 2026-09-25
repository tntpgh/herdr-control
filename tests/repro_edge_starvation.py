import subprocess, time, tempfile, importlib.util
from pathlib import Path

REPO = Path("/Users/thurbs/.herdr/worktrees/herdr-control/fix/edge-slot-starvation")


def load_hub():
    spec = importlib.util.spec_from_file_location("herdr_hub_repro", REPO / "hub.py")
    hub = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hub)
    return hub


def make_script(tmp):
    script = Path(tmp) / "fake-edge.sh"
    # Mimics agent-edge.sh's real shape: near-instant peer-answer, then a
    # long held slot for the grace window (46-83s observed; scaled down here
    # so the repro finishes in seconds instead of minutes).
    script.write_text("#!/usr/bin/env bash\nsleep 2\n")
    script.chmod(0o755)
    return script


def legacy_dispatch(hub, pane_id, before, after, rec, drops):
    if not hub.edge_is_actionable(before, after):
        return
    if not hub._edge_slot():
        drops.append(pane_id)
        return
    child = subprocess.Popen(["bash", str(hub.AGENT_EDGE)],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, start_new_session=True)
    with hub._EDGE_LOCK:
        hub._EDGE_INFLIGHT.append(child)


def run(coalesce):
    hub = load_hub()
    tmp = tempfile.TemporaryDirectory()
    hub.AGENT_EDGE = make_script(tmp.name)
    hub.EDGE_MAX_INFLIGHT = 12
    hub._EDGE_INFLIGHT.clear()
    hub._EDGE_INFLIGHT_BY_PANE.clear()
    rec = {"agent": "omp", "birth": "b1"}
    drops = []
    dropped_log = []
    orig_log = hub._live_log
    hub._live_log = lambda msg: dropped_log.append(msg)

    # Two flapping panes (the observed w2C:p2 shape): blocked->working->blocked
    # every 0.3s, 10 flaps each. A THIRD, genuinely distinct pane goes blocked
    # once mid-storm -- the one that must NOT be starved of a slot.
    for i in range(10):
        for pane in ("flapA", "flapB"):
            if coalesce:
                hub._on_agent_edge(pane, "working", "blocked", rec)
            else:
                legacy_dispatch(hub, pane, "working", "blocked", rec, drops)
        if i == 5:
            if coalesce:
                hub._on_agent_edge("victim", None, "blocked", rec)
            else:
                legacy_dispatch(hub, "victim", None, "blocked", rec, drops)
        time.sleep(0.3)

    victim_dropped = any("victim" in line for line in dropped_log) or "victim" in drops
    n_drop_lines = len(dropped_log) + len(drops)
    live_count = sum(1 for p in hub._EDGE_INFLIGHT if p.poll() is None)

    for p in list(hub._EDGE_INFLIGHT):
        try:
            p.terminate()
        except Exception:
            pass
    tmp.cleanup()
    hub._live_log = orig_log
    return {
        "coalesce": coalesce,
        "total_drop_events": n_drop_lines,
        "victim_dropped": victim_dropped,
        "live_handlers_at_end": live_count,
    }


print("=== BEFORE (legacy: unbounded fan-out, no coalescing) ===")
print(run(coalesce=False))
print()
print("=== AFTER (fix: per-pane coalescing) ===")
print(run(coalesce=True))
