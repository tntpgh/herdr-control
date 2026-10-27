"""Synthetic hub data for the staged preview. Invented repos/labels only.

install(hub, now, tmp, herdr_down=False) swaps every reader the render path
touches for fixed values, so no page can reach the registry, forms dir,
network, git or a secret. Times are relative to `now` so a baseline and a
new render taken with the same `now` see identical data.
"""
from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
from types import SimpleNamespace


def _iso(now: float, ago_s: float) -> str:
    return dt.datetime.fromtimestamp(now - ago_s, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _task(now, n, label, repo, state, source, ago_s, pane, **kw):
    t = {"task_id": f"task_demo_{n:02d}", "run_id": f"run_demo_{n:02d}", "label": label,
         "repo": f"/demo/{repo}", "state": state, "stored_state": kw.pop("stored", state),
         "state_source": source, "pane_id": pane, "conductor_id": "conductor_demo",
         "worktree": f"/demo/.worktrees/{repo}-{n}", "branch": label.split(":", 1)[-1],
         "project": repo, "created_at": _iso(now, ago_s + 3600), "updated_at": _iso(now, ago_s),
         "evidence_at": None, "closure_reason": None, "closure_proof": None}
    t.update(kw)
    t["state_stale"] = t["state"] != t["stored_state"]
    return t


def tasks(now: float) -> list[dict]:
    T = lambda *a, **k: _task(now, *a, **k)  # noqa: E731
    return [
        T(1, "implement:feat/login-form", "demo-app", "running", "live", 40, "w1:p1"),
        T(2, "code:fix/null-guard", "demo-app", "running", "stored", 900, "w1:p2"),
        T(3, "plan:plan/q4-roadmap", "demo-infra", "blocked", "live", 600, "w2:p1"),
        T(4, "design:design/settings-page", "demo-app", "stalled", "live", 1500, "w1:p3", stored="running"),
        T(5, "review:review/pr-41", "demo-app", "ready_review", "live", 300, "w3:p1", stored="running"),
        T(6, "deep-review:review/pr-38-r2", "demo-docs", "running", "live", 20, "w3:p2"),
        T(7, "debug:fix/flaky-timer", "demo-infra", "blocked", "stored", 2400, "w2:p2"),
        T(8, "research:research/vendor-scan", "demo-docs", "starting", "registry", 60, "w4:p1"),
        T(9, "quick:chore/lint-pass", "demo-app", "completed", "registry", 7200, "w4:p2",
          closure_reason="shipped", closure_proof=".handoffs/PROOF.md#lint-pass"),
        T(10, "mechanical:chore/rename-sweep", "demo-infra", "completed", "registry", 10800, "w4:p3",
          closure_reason="superseded"),
        T(11, "docs:docs/runbook", "demo-docs", "failed", "registry", 5400, "w5:p1"),
        T(12, "explore:explore/cache-options", "demo-infra", "lost", "registry", 9000, "w5:p2"),
        T(13, "hotfix-ad-hoc", "demo-app", "running", "live", 90, "w6:p1"),
        T(14, "architect:arch/event-bus", "demo-infra", "cancelled", "registry", 12600, "w6:p2",
          closure_reason="no-follow-on"),
        T(15, "implement:feat/export-csv", "demo-app", "gone", "live", 1800, "w6:p3", stored="running"),
        T(16, "implement:feat/old-thing", "demo-app", "completed", "registry", 3 * 86400, "w7:p1",
          closure_reason="shipped", closure_proof=".handoffs/PROOF.md#old-thing"),
    ]


def herdr(now: float, err: bool = False) -> dict:
    if err:
        return {"error": "registry not found: /demo/registry.sqlite3", "tasks": [], "attention": [], "events": [], "checkpoints": []}
    ts = tasks(now)
    attention = [t for t in ts if t["state"] in ("blocked", "stalled", "ready_review")]
    events = [
        {"sequence": 412, "type": "state_changed", "task_id": "task_demo_03", "occurred_at": _iso(now, 600),
         "payload": {"from": "running", "state": "blocked", "reason": "asked for a decision"}, "label": "plan:plan/q4-roadmap"},
        {"sequence": 411, "type": "input_required", "task_id": "task_demo_03", "occurred_at": _iso(now, 605),
         "payload": {"prompt_id": "a1b2c3d4e5f6a7b8c9d0"}, "label": "plan:plan/q4-roadmap"},
        {"sequence": 410, "type": "wake_result", "task_id": "task_demo_04", "occurred_at": _iso(now, 1500),
         "payload": {"outcome": "submitted"}, "label": "design:design/settings-page"},
    ]
    return {"tasks": ts, "attention": attention, "events": events, "max_event_seq": 412,
            "checkpoints": [{"conductor_id": "conductor_demo", "last_event_seq": 405, "updated_at": _iso(now, 700)}]}


def forms(now: float) -> dict:
    ms = lambda ago: int((now - ago) * 1000)  # noqa: E731
    open_forms = [
        {"id": "pv-1", "title": "Demo: approve the q4 roadmap draft?", "url": "http://127.0.0.1:59001/",
         "status": "open", "created_at": ms(600), "expires_at": ms(-3 * 3600), "hub_servable": True,
         "hub_url": "/decisions/pv-1", "port": 59001, "token": "preview-token-not-real"},
        {"id": "pv-2", "title": "Demo: pick a cache option", "url": "http://127.0.0.1:59002/",
         "status": "open", "created_at": ms(3000), "expires_at": ms(-1800), "hub_servable": False, "port": 59002},
    ]
    history = [
        {"id": "pv-0", "title": "Demo: merge the lint pass?", "status": "answered", "created_at": ms(9000),
         "answered_at": ms(8000), "answers": {"decision": "approve"}, "form_path": "/demo/forms/pv-0.html"},
        {"id": "pv-x", "title": "Demo: rename sweep scope", "status": "expired", "created_at": ms(90000),
         "form_path": "/demo/forms/pv-x.html"},
    ]
    return {"open": open_forms, "history": history, "open_count": len(open_forms)}


def loops(now: float) -> dict:
    lp = lambda name, cadence, detail, ago, outcome, stale=False: {  # noqa: E731
        "name": name, "cadence": cadence, "detail": detail, "last": _iso(now, ago) if ago is not None else None,
        "observed": ago is not None, "stale": stale, "outcome": outcome, "link": None}
    return {
        "loops": [lp("nightly demo build \u2014 build", "daily 03:00", "12 steps", 6 * 3600, "ok"),
                  lp("link probe \u2014 surfaces", "every 60s", "8 surfaces", 50, "ok"),
                  lp("ledger collector \u2014 stage 1", "hourly", "no new rows", 5 * 3600, "ok", stale=True),
                  lp("signal audit \u2014 9j", "daily", "reader unavailable", None, "unknown")],
        "suggestions": [
            {"key": "s1", "kind": "suggestion", "text": "Demo: add a retry budget to the link probe.", "tags": ["probe"], "decision": None},
            {"key": "s2", "kind": "suggestion", "text": "Demo: split the nightly build into two jobs.", "tags": [], "decision": {"state": "accept", "notes": "ok"}},
            {"key": "s3", "kind": "finding", "text": "Demo: ledger collector stale for 5h.", "tags": ["stale"], "decision": {"state": "hold", "notes": "after release"}},
        ],
        "dismissed": 1,
        "gates": [{"id": "G-demo-1", "title": "Demo gate: evidence reviewed", "status": "pending"}],
        "findings": [{"id": "F-demo-7", "title": "Demo finding: flaky timer", "tags": ["test"]}],
    }


def projects(now: float) -> dict:
    ts = tasks(now)
    out = []
    for name in ("demo-app", "demo-docs", "demo-infra"):
        mine = [t for t in ts if t["project"] == name]
        out.append({"project": name, "repo": f"/demo/{name}",
                    "tasks": [dict(t, blocked_minutes=(40 if t["state"] == "blocked" else None),
                                   blocked_on=("a decision form" if t["state"] == "blocked" else None), claim=None)
                              for t in mine],
                    "prs": [{"number": 41, "url": "https://example.invalid/pr/41", "state": "OPEN", "isDraft": False}] if name == "demo-app" else [],
                    "open_decisions": [{"id": "pv-1", "title": "Demo: approve the q4 roadmap draft?", "status": "open"}] if name == "demo-infra" else [],
                    "spec_items": [{"text": "Demo acceptance item", "done": True}, {"text": "Second item", "done": False}],
                    "next_step": "waiting on: review" if name == "demo-app" else None,
                    "needs_wake": name == "demo-docs"})
    return {"projects": out}


def owners(now: float) -> dict:
    return {"owners": [{"label": "demo-app-owner",
                        "registered": {"pane_id": "w1:p9", "registered_at": _iso(now, 7200), "has_agent_session": True},
                        "project": "demo-app", "lease": {"state": "live", "pane_id": "w1:p9", "expires_at": _iso(now, -600)},
                        "queue_lane": True, "grants": [{"status": "consumed", "expires_at": now - 60}]},
                       {"label": "demo-infra-owner", "registered": None, "project": None, "lease": None,
                        "queue_lane": False, "grants": []}],
            "sources": {"owners": "ok", "leases": "ok", "queue": "ok", "grants": "ok"},
            "queue_supervisor_enabled": False}


def kb(now: float) -> dict:
    return {"heartbeat": {"systems": {"demo-api": {"status": "healthy", "code": "200"},
                                      "demo-worker": {"status": "unknown", "code": "no probe"},
                                      "demo-db": {"status": "failing", "code": "timeout"}},
                          "healthy_count": 1, "total_count": 3, "checked_count": 3,
                          "generated_at": _iso(now, 1200), "divergent": False, "unrecognized_count": 0},
            "runs": [{"status": "ok", "weekday": "Mon", "host": "demo-host", "git_sha": "abc1234def",
                      "total_steps": 12, "started_at": _iso(now, 6 * 3600)}],
            "steps": [{"status": "ok", "step_label": "demo step", "attempts": 1, "duration_s": 42},
                      {"status": "failed", "step_label": "demo flaky step", "error_class": "TimeoutError", "attempts": 3, "duration_s": 90}],
            "signal_quality_runs": []}


def links(now: float) -> dict:
    return {"surfaces": [{"name": "demo api", "url": "https://example.invalid/api", "alive": True, "code": 200, "ms": 84, "detail": "", "hb": "demo-api"},
                         {"name": "demo dashboard", "url": "https://example.invalid/dash", "alive": False, "code": 502, "ms": 310, "detail": "bad gateway", "hb": None}]}


def search(now: float) -> dict:
    return {"totals": {"searches": 128, "replays": 37, "data_kind": 5, "partial": 2},
            "recent": [{"url": "https://example.invalid/s/1", "q": "demo query", "scope": "demo", "kind": "web",
                        "hits": 3, "total_s": 1.2, "ts": _iso(now, 400)}]}


def debt(now: float) -> dict:
    return {"repos": ["/demo/demo-docs"], "shipped": 1, "lesson_debt": 1, "unreadable": 0,
            "debt": [{"repo": "/demo/demo-docs", "shipped": True, "lesson_debt": True, "writes": 3,
                      "mutations": 4, "session_cwd": "/demo/demo-docs", "at": _iso(now, 5000)}]}


def deploy_drift(now: float) -> dict:
    return {"repos": [{"repo": "demo-app", "deployed": "a1b2c3d", "main": "a1b2c3d", "behind_minutes": 0, "fetch_ok": True},
                      {"repo": "demo-infra", "deployed": "d4e5f6a", "main": "b7c8d9e", "behind_minutes": 95, "fetch_ok": True},
                      {"repo": "demo-docs", "deployed": "1122334", "main": "5566778", "fetch_ok": False}]}


def cost(now: float) -> dict:
    return {"present": True, "total_cost": 84.2, "prev_total_cost": 70.0, "alerts": [],
            "top_sessions": [{"session_id": "demo-session-1", "repo": "demo-app", "cost": 12.5, "turns": 140, "max_context": 210000}],
            "cost_by_repo": {"demo-app": 50.0, "demo-infra": 34.2}, "generated_at": _iso(now, 1800),
            "context_alert_threshold": 300000}


def live(now: float, down: bool) -> dict:
    if down:
        return {"connected": False, "panes": [], "blocked": [], "agents": [],
                "stats": {"last_error": "preview: subscription simulated down"}}
    agents = [{"pane_id": p, "agent_status": s, "agent": "omp", "workspace": "demo", "since": now - a}
              for p, s, a in (("w1:p1", "working", 40), ("w2:p1", "blocked", 600), ("w1:p3", "idle", 1500),
                              ("w3:p1", "idle", 300), ("w3:p2", "working", 20), ("w6:p1", "working", 90))]
    return {"connected": True, "version": 7, "agents": agents, "panes": agents,
            "blocked": [{"pane_id": "w2:p1", "agent_status": "blocked"}],
            "stats": {"events": 1200, "reconnects": 0, "resyncs": 1, "edges": 33}}


def timeline(now: float):
    def timeline_data(since, until, scope="", limit=None):
        ev = [dict(e, repo="/demo/demo-infra", project="demo-infra", branch="plan/q4-roadmap", pr=None)
              for e in herdr(now)["events"]]
        if scope:
            ev = [e for e in ev if e["repo"].rsplit("/", 1)[-1] == scope]
        return {"events": ev, "since": since, "until": until, "scope": scope,
                "scope_known": not scope or bool(ev), "capped": False, "total_in_window": len(ev)}
    return timeline_data


FORM_HTML = """<!doctype html><html lang=en><head><meta charset=utf-8><title>Demo decision</title></head>
<body><main><h1>Demo: approve the q4 roadmap draft?</h1><p>Synthetic preview form. Submitting is refused by the preview.</p>
<label><input type=radio name=decision value=approve> Approve</label>
<label><input type=radio name=decision value=hold> Hold</label>
<button onclick="submitAnswers({decision:document.querySelector('input[name=decision]:checked')?.value})">Send</button>
</main></body></html>"""


def install(hub, now: float, tmp: Path, herdr_down: bool = False, registry_error: bool = False) -> None:
    fixed = lambda v: SimpleNamespace(get=lambda: v, peek=lambda: v)  # noqa: E731
    data = {"herdr": herdr(now, registry_error), "forms": forms(now), "search": search(now), "kb": kb(now),
            "links": links(now), "loops": loops(now), "debt": debt(now),
            "portal": {"open": [], "open_count": 0, "error": None},
            "deploy_drift": deploy_drift(now), "cost": cost(now), "projects": projects(now), "owners": owners(now)}
    missing = set(hub.CACHES) - set(data)
    if missing:
        raise SystemExit(f"preview fixtures do not cover caches: {sorted(missing)}")
    for k, v in data.items():
        hub.CACHES[k] = fixed(v)
    lv = live(now, herdr_down)
    hub.live_data = lambda: lv
    hub.slo_data = lambda: {"p50": 240, "p90": 1800, "p99": 5400, "samples": 9,
                            "wake_total": 20, "wake_submitted": 19, "wake_rate_pct": 95.0}
    hub.timeline_data = timeline(now)
    hub._open_prs_for_repo = lambda repo: {}
    forms_dir = Path(hub.FORMS_DIR)
    forms_dir.mkdir(parents=True, exist_ok=True)
    row = dict(data["forms"]["open"][0])
    (forms_dir / "pv-1.json").write_text(json.dumps(row))
    (forms_dir / "pv-1.html").write_text(FORM_HTML)
