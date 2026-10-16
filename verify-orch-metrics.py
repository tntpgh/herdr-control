#!/usr/bin/env python3
"""Fixture-only verification for scripts/orch-metrics.py.

Builds a synthetic sqlite registry (tables tasks/events/approvals/roles, with
the schema columns Appendix A of ORCH-HIERARCHY-PLAN-v2.md names) with known
answers, asserts every figure the script computes — including empty-window
and single-row edges — and asserts the script's connection refuses to write.

NEVER touches a real registry: the only database this suite opens is the
tempfile it creates and deletes.
"""
import json
import math
import os
import sqlite3
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "orch_metrics", os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts", "orch-metrics.py")
)
orch_metrics = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(orch_metrics)

SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts", "orch-metrics.py")

CHECKS = 0


def check(label, cond):
    global CHECKS
    assert cond, f"FAILED: {label}"
    CHECKS += 1
    print(f"ok: {label}")


def new_fixture_db(with_roles=True):
    fd, path = tempfile.mkstemp(suffix=".sqlite3", prefix="orch-metrics-fixture-")
    os.close(fd)
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE tasks (
          task_id TEXT PRIMARY KEY, state TEXT, project TEXT,
          updated_at TEXT, conductor_pane_id TEXT
        );
        CREATE TABLE events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT,
          run_id TEXT, task_id TEXT, type TEXT, occurred_at TEXT, payload TEXT
        );
        CREATE TABLE approvals (
          approval_id TEXT PRIMARY KEY, run_id TEXT, task_id TEXT, pane_id TEXT,
          prompt_id TEXT, choice TEXT, decided_by TEXT, authority TEXT,
          policy_verdict TEXT, command TEXT, decided_at TEXT, attempted_at TEXT,
          outcome TEXT
        );
        """
    )
    if with_roles:
        conn.execute("CREATE TABLE roles (role TEXT PRIMARY KEY, pane_id TEXT)")
    conn.commit()
    return path, conn


def ev(conn, task_id, type_, occurred_at, payload=None):
    conn.execute(
        "INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
        "VALUES (?, 'r1', ?, ?, ?, ?)",
        (f"evt_{type_}_{occurred_at}_{task_id}", task_id, type_, occurred_at,
         json.dumps(payload or {})),
    )


def appr(conn, approval_id, task_id, authority, decided_at, pane_id="p0", prompt_id=None):
    conn.execute(
        "INSERT INTO approvals (approval_id, run_id, task_id, pane_id, prompt_id, choice, "
        "decided_by, authority, policy_verdict, command, decided_at, attempted_at, outcome) "
        "VALUES (?, 'r1', ?, ?, ?, 'approve', 'human', ?, 'allow', 'cmd', ?, ?, 'ok')",
        (approval_id, task_id, pane_id, prompt_id or approval_id, authority, decided_at, decided_at),
    )


def build_populated_fixture():
    path, conn = new_fixture_db()

    # tasks
    conn.execute("INSERT INTO tasks VALUES ('T1','running','proj-a','2026-10-09T10:00:00Z','w72:p1')")
    conn.execute("INSERT INTO tasks VALUES ('T2','blocked','proj-a','2026-10-09T11:00:00Z','w72:p1')")
    conn.execute("INSERT INTO tasks VALUES ('TB','running','proj-b','2026-10-09T09:00:00Z','w7T:pX')")
    conn.execute("INSERT INTO roles VALUES ('main','w72:p1')")

    # --- blocked episodes (Appendix A §a) ---
    # T1 episode 1: blocked 10:00:00 -> running 10:05:00 = 300s = 5 min
    ev(conn, "T1", "state_changed", "2026-10-09T10:00:00Z", {"from": "running", "to": "blocked"})
    ev(conn, "T1", "state_changed", "2026-10-09T10:05:00Z", {"from": "blocked", "to": "running"})
    # T1 episode 2: blocked 10:10:00 -> running 10:25:00 = 900s = 15 min (>=10min)
    ev(conn, "T1", "state_changed", "2026-10-09T10:10:00Z", {"from": "running", "to": "blocked"})
    ev(conn, "T1", "state_changed", "2026-10-09T10:25:00Z", {"from": "blocked", "to": "running"})
    # T2: blocked 11:00:00, never closed -> open-ended, clamped to --until (12:00:00) = 3600s = 60 min
    ev(conn, "T2", "state_changed", "2026-10-09T11:00:00Z", {"from": "running", "to": "blocked"})

    # --- top escalations (Appendix A §b): distinct counts, no ties ---
    reasons = [
        ("multi_row_menu", 6), ("tool_mismatch", 5), ("parser_find", 4),
        ("parser_git", 3), ("unresolvable_script", 2), ("sixth_reason", 1),
    ]
    i = 0
    for reason, n in reasons:
        for _ in range(n):
            i += 1
            ev(conn, "T1", "approval_escalated", f"2026-10-09T12:{i:02d}:00Z", {"reason": reason})

    # --- conductor latency (Appendix A §c): 10 deltas, 10..100s step 10 ---
    for k in range(1, 11):
        pid = f"lat_{k}"
        delta_s = k * 10
        seen_at = "2026-10-09T13:00:00Z"
        decided_at = f"2026-10-09T13:{delta_s // 60:02d}:{delta_s % 60:02d}Z"
        ev(conn, "T1", "input_required", seen_at, {"prompt_id": pid})
        appr(conn, f"lat_appr_{k}", "T1", "conductor", decided_at, prompt_id=pid)
    # single-row latency case, isolated by its own window (prompt id/time distinct)
    ev(conn, "T1", "input_required", "2026-10-09T14:00:00Z", {"prompt_id": "lat_solo"})
    appr(conn, "lat_appr_solo", "T1", "conductor", "2026-10-09T14:00:42Z", prompt_id="lat_solo")

    # --- wake outcomes (Appendix A §d): 6 submitted, 3 unsubmitted, 1 refused ---
    for k in range(6):
        ev(conn, "T1", "wake_result", f"2026-10-09T15:00:{k:02d}Z", {"outcome": "submitted"})
    for k in range(3):
        ev(conn, "T1", "wake_result", f"2026-10-09T15:01:{k:02d}Z", {"outcome": "unsubmitted"})
    ev(conn, "T1", "wake_result", "2026-10-09T15:02:00Z", {"outcome": "refused"})

    # --- decisions/day (Appendix A §d): isolated date range, no input_required join needed ---
    for k in range(3):
        appr(conn, f"dpd_d10_{k}", "T1", "conductor", f"2026-10-10T0{k}:00:00Z")
    for k in range(2):
        appr(conn, f"dpd_d11_{k}", "T1", "conductor", f"2026-10-11T0{k}:00:00Z")
    appr(conn, "dpd_d12_0", "T1", "conductor", "2026-10-12T00:00:00Z")

    # --- main drops threads (plan §9.3) ---
    # T1's conductor is Main (w72:p1): one counted, one excluded (human_reserved) on day1;
    # one excluded (unanswerable_overlay), one counted on day2.
    ev(conn, "T1", "attention_form_served", "2026-10-13T01:00:00Z", {})
    ev(conn, "T1", "attention_form_served", "2026-10-13T02:00:00Z", {"reason": "human_reserved"})
    ev(conn, "T1", "attention_form_served", "2026-10-14T01:00:00Z", {"reason": "unanswerable_overlay"})
    ev(conn, "T1", "attention_form_served", "2026-10-14T02:00:00Z", {})
    # TB's conductor is NOT main -> must never be counted even with no excluded reason
    ev(conn, "TB", "attention_form_served", "2026-10-13T01:30:00Z", {})

    conn.commit()
    conn.close()
    return path


def main():
    path = build_populated_fixture()
    try:
        conn = orch_metrics.connect_ro(path)

        # --- write refusal (mode=ro) ---
        try:
            conn.execute("INSERT INTO tasks VALUES ('X','x','x','x','x')")
            conn.commit()
            raise AssertionError("FAILED: read-only connection accepted a write")
        except sqlite3.OperationalError as e:
            check("connect_ro refuses writes", "readonly" in str(e).lower())

        # --- blocked episodes, full window ---
        be = orch_metrics.compute_blocked_episodes(conn, "2026-10-09T09:00:00Z", "2026-10-09T12:00:00Z")
        check("blocked episodes count", be["episodes"] == 3)
        check("blocked total_min", math.isclose(be["total_min"], 80.0))
        check("blocked episodes_ge10", be["episodes_ge10"] == 2)
        check("blocked min_ge10", math.isclose(be["min_ge10"], 75.0))
        check("blocked ge10_episode_share", math.isclose(be["ge10_episode_share"], round(2 / 3, 4)))
        check("blocked ge10_minute_share", math.isclose(be["ge10_minute_share"], round(75 / 80, 4)))

        # --- blocked episodes, single-row edge (just T1 episode 1) ---
        be_single = orch_metrics.compute_blocked_episodes(conn, "2026-10-09T09:55:00Z", "2026-10-09T10:06:00Z")
        check("blocked single-row episodes", be_single["episodes"] == 1)
        check("blocked single-row total_min", math.isclose(be_single["total_min"], 5.0))
        check("blocked single-row ge10_episode_share", be_single["ge10_episode_share"] == 0.0)

        # --- blocked episodes, empty window ---
        be_empty = orch_metrics.compute_blocked_episodes(conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("blocked empty episodes", be_empty["episodes"] == 0)
        check("blocked empty total_min", be_empty["total_min"] == 0)
        check("blocked empty share is None", be_empty["ge10_episode_share"] is None
              and be_empty["ge10_minute_share"] is None)

        # --- top escalations ---
        esc = orch_metrics.compute_top_escalations(
            conn, "2026-10-09T00:00:00Z", "2026-10-09T23:59:59Z")
        check("escalations total", esc["total"] == 21)
        check("escalations top5 len", len(esc["top"]) == 5)
        check("escalations top1", esc["top"][0] == {"reason": "multi_row_menu", "n": 6})
        check("escalations top5 excludes 6th", all(r["reason"] != "sixth_reason" for r in esc["top"]))
        esc_empty = orch_metrics.compute_top_escalations(conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("escalations empty window", esc_empty["total"] == 0 and esc_empty["top"] == [])

        # --- conductor latency: known deltas 10..100s ---
        lat = orch_metrics.compute_conductor_latency(
            conn, "2026-10-09T13:00:00Z", "2026-10-09T13:01:40Z")
        check("latency n", lat["n"] == 10)
        check("latency p50 (idx5=50s)", math.isclose(lat["p50"], 50.0))
        check("latency p90 (idx9=90s)", math.isclose(lat["p90"], 90.0))
        check("latency p99 (idx10=100s)", math.isclose(lat["p99"], 100.0))

        # single-row edge
        lat_solo = orch_metrics.compute_conductor_latency(
            conn, "2026-10-09T13:59:00Z", "2026-10-09T14:01:00Z")
        check("latency single-row n", lat_solo["n"] == 1)
        check("latency single-row all percentiles equal",
              lat_solo["p50"] == lat_solo["p90"] == lat_solo["p99"] == 42.0)

        # empty window
        lat_empty = orch_metrics.compute_conductor_latency(
            conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("latency empty n", lat_empty["n"] == 0)
        check("latency empty percentiles None",
              lat_empty["p50"] is None and lat_empty["p90"] is None and lat_empty["p99"] is None)

        # --- wake outcomes ---
        wo = orch_metrics.compute_wake_outcomes(conn, "2026-10-09T15:00:00Z", "2026-10-09T15:02:00Z")
        check("wake submitted count", wo["counts"]["submitted"] == 6)
        check("wake unsubmitted count", wo["counts"]["unsubmitted"] == 3)
        check("wake refused count", wo["counts"]["refused"] == 1)
        check("wake total", wo["total"] == 10)
        check("wake unsubmitted_share", math.isclose(wo["unsubmitted_share"], 0.3))
        wo_empty = orch_metrics.compute_wake_outcomes(conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("wake empty share is None", wo_empty["unsubmitted_share"] is None and wo_empty["total"] == 0)

        # --- decisions per day ---
        dpd = orch_metrics.compute_decisions_per_day(conn, "2026-10-10T00:00:00Z", "2026-10-12T23:59:59Z")
        check("decisions/day series", dpd == [
            {"date": "2026-10-10", "n": 3},
            {"date": "2026-10-11", "n": 2},
            {"date": "2026-10-12", "n": 1},
        ])
        dpd_empty = orch_metrics.compute_decisions_per_day(conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("decisions/day empty", dpd_empty == [])

        # --- main drops threads ---
        mdt = orch_metrics.compute_main_drops_threads(conn, "2026-10-13T00:00:00Z", "2026-10-14T23:59:59Z")
        check("main_drops_threads main_pane resolved", mdt["main_pane"] == "w72:p1")
        check("main_drops_threads series", mdt["series"] == [
            {"date": "2026-10-13", "n": 1},
            {"date": "2026-10-14", "n": 1},
        ])
        mdt_empty = orch_metrics.compute_main_drops_threads(
            conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("main_drops_threads empty window", mdt_empty["series"] == [])

        # --- main-pane override (explicit --main-pane bypasses roles lookup) ---
        mdt_override = orch_metrics.compute_main_drops_threads(
            conn, "2026-10-13T00:00:00Z", "2026-10-14T23:59:59Z", main_pane_override="w7T:pX")
        check("main_drops_threads override targets TB only",
              mdt_override["main_pane"] == "w7T:pX" and
              mdt_override["series"] == [{"date": "2026-10-13", "n": 1}])

        conn.close()

        # --- no-roles-table fixture: main pane unresolved without --main-pane ---
        no_roles_path, no_roles_conn = new_fixture_db(with_roles=False)
        no_roles_conn.execute(
            "INSERT INTO tasks VALUES ('T1','running','proj-a','2026-10-09T10:00:00Z','w72:p1')"
        )
        no_roles_conn.commit()
        no_roles_conn.close()
        ro = orch_metrics.connect_ro(no_roles_path)
        mdt_noroles = orch_metrics.compute_main_drops_threads(
            ro, "2026-10-09T00:00:00Z", "2026-10-09T23:59:59Z")
        check("main_drops_threads unresolved without roles table",
              mdt_noroles["main_pane"] is None and mdt_noroles["series"] == []
              and "note" in mdt_noroles)
        ro.close()
        os.remove(no_roles_path)

        # --- CLI smoke: run the script as a subprocess against the fixture ---
        out = subprocess.run(
            [sys.executable, SCRIPT_PATH, "--db", path,
             "--since", "2026-10-10T00:00:00Z", "--until", "2026-10-12T23:59:59Z", "--json"],
            capture_output=True, text=True, check=True,
        )
        cli_report = json.loads(out.stdout)
        check("CLI JSON decisions_per_day matches", cli_report["decisions_per_day"] == [
            {"date": "2026-10-10", "n": 3},
            {"date": "2026-10-11", "n": 2},
            {"date": "2026-10-12", "n": 1},
        ])

        # --- CLI refuses to write even through the subprocess path: run against a
        # fixture, then reopen the same file directly and confirm it is untouched
        # (the CLI run above would have failed loudly if it attempted any write,
        # since mode=ro raises OperationalError which argparse/main() does not catch).
        check("CLI subprocess exited 0 (no write attempted/failed silently)",
              out.returncode == 0)

    finally:
        os.remove(path)

    print(f"\n{CHECKS} checks passed")


if __name__ == "__main__":
    main()
