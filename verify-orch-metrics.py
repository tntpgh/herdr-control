#!/usr/bin/env python3
"""Fixture-only verification for scripts/orch-metrics.py.

Builds a synthetic sqlite registry (tables tasks/events/approvals/roles, with
the schema columns verified against lib/run-registry.sh's real CREATE TABLE
statements -- not the plan's Appendix A, which the plan itself marks UNRUN
and which named the wrong `roles` column and the wrong prompt_occ_* join
key) with known answers, asserts every figure the script computes --
including empty-window and single-row edges -- and asserts the script's
connection refuses to write.

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
        # Real schema (lib/run-registry.sh _migrate_schema_v10): primary key
        # column is `label`, not `role`.
        conn.execute(
            "CREATE TABLE roles (label TEXT PRIMARY KEY, pane_id TEXT, pane_birth TEXT, "
            "agent_session TEXT, workspace TEXT, registered_at TEXT, updated_at TEXT)"
        )
    conn.commit()
    return path, conn


def ev(conn, task_id, type_, occurred_at, payload=None, suffix=""):
    conn.execute(
        "INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
        "VALUES (?, 'r1', ?, ?, ?, ?)",
        (f"evt_{type_}_{occurred_at}_{task_id}{suffix}", task_id, type_, occurred_at,
         json.dumps(payload or {})),
    )


def appr(conn, approval_id, task_id, authority, decided_at, pane_id="p0", prompt_id=None,
          command="cmd", decided_by="human"):
    conn.execute(
        "INSERT INTO approvals (approval_id, run_id, task_id, pane_id, prompt_id, choice, "
        "decided_by, authority, policy_verdict, command, decided_at, attempted_at, outcome) "
        "VALUES (?, 'r1', ?, ?, ?, 'approve', ?, ?, 'allow', ?, ?, ?, 'ok')",
        (approval_id, task_id, pane_id, prompt_id or approval_id, decided_by, authority,
         command, decided_at, decided_at),
    )


def build_populated_fixture():
    path, conn = new_fixture_db()

    # tasks
    conn.execute("INSERT INTO tasks VALUES ('T1','running','proj-a','2026-10-09T10:00:00Z','w72:p1')")
    conn.execute("INSERT INTO tasks VALUES ('T2','blocked','proj-a','2026-10-09T11:00:00Z','w72:p1')")
    conn.execute("INSERT INTO tasks VALUES ('TB','running','proj-b','2026-10-09T09:00:00Z','w7T:pX')")
    conn.execute("INSERT INTO roles VALUES ('main','w72:p1','birth1','sess1','ws1',"
                 "'2026-10-01T00:00:00Z','2026-10-01T00:00:00Z')")

    # --- blocked episodes (Appendix A §a) ---
    ev(conn, "T1", "state_changed", "2026-10-09T10:00:00Z", {"from": "running", "to": "blocked"})
    ev(conn, "T1", "state_changed", "2026-10-09T10:05:00Z", {"from": "blocked", "to": "running"})
    ev(conn, "T1", "state_changed", "2026-10-09T10:10:00Z", {"from": "running", "to": "blocked"})
    ev(conn, "T1", "state_changed", "2026-10-09T10:25:00Z", {"from": "blocked", "to": "running"})
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

    # --- conductor latency (Appendix A §c): 10 decided deltas, 10..100s step 10 ---
    for k in range(1, 11):
        pid = f"lat_{k}"
        delta_s = k * 10
        seen_at = "2026-10-09T13:00:00Z"
        decided_at = f"2026-10-09T13:{delta_s // 60:02d}:{delta_s % 60:02d}Z"
        ev(conn, "T1", "input_required", seen_at, {"prompt_id": pid}, suffix=f"_{k}")
        appr(conn, f"lat_appr_{k}", "T1", "conductor", decided_at, prompt_id=pid)
    ev(conn, "T1", "input_required", "2026-10-09T14:00:00Z", {"prompt_id": "lat_solo"})
    appr(conn, "lat_appr_solo", "T1", "conductor", "2026-10-09T14:00:42Z", prompt_id="lat_solo")
    # unresolved: arrived in-window, never decided by anyone
    ev(conn, "T1", "input_required", "2026-10-09T14:30:00Z", {"prompt_id": "lat_unresolved"})

    # --- wake outcomes (Appendix A §d) ---
    for k in range(6):
        ev(conn, "T1", "wake_result", f"2026-10-09T15:00:{k:02d}Z", {"outcome": "submitted"})
    for k in range(3):
        ev(conn, "T1", "wake_result", f"2026-10-09T15:01:{k:02d}Z", {"outcome": "unsubmitted"})
    ev(conn, "T1", "wake_result", "2026-10-09T15:02:00Z", {"outcome": "refused"})

    # --- decisions/day + decided_by actors (Appendix A §d / plan P0 item 4) ---
    for k in range(3):
        appr(conn, f"dpd_d10_{k}", "T1", "conductor", f"2026-10-10T0{k}:00:00Z", decided_by="cli")
    for k in range(2):
        appr(conn, f"dpd_d11_{k}", "T1", "conductor", f"2026-10-11T0{k}:00:00Z", decided_by="peer-answer")
    appr(conn, "dpd_d12_0", "T1", "conductor", "2026-10-12T00:00:00Z", decided_by="w72:p1")
    appr(conn, "dpd_d12_1", "T1", "conductor", "2026-10-12T01:00:00Z", decided_by="hub form 123")

    # --- main drops threads (plan §9.3 / P0 item 4): real prose reasons ---
    ev(conn, "T1", "attention_form_served", "2026-10-13T01:00:00Z",
       {"reason": "No response 1234s after its conductor was alerted; one escalation to Main went unanswered."})
    ev(conn, "T1", "attention_form_served", "2026-10-13T02:00:00Z",
       {"reason": "Only a human can approve this (merge, governance, push), and its conductor has not denied or redirected it in 999s."})
    ev(conn, "T1", "attention_form_served", "2026-10-14T01:00:00Z", {"reason": "something unexpected"})
    ev(conn, "T1", "attention_form_served", "2026-10-14T02:00:00Z", {})
    ev(conn, "TB", "attention_form_served", "2026-10-13T01:30:00Z",
       {"reason": "No response 500s after its conductor was alerted; Main could not be reached."})

    # --- blocked episode, exact 600s boundary ---
    ev(conn, "T3", "state_changed", "2026-10-09T16:00:00Z", {"from": "running", "to": "blocked"})
    ev(conn, "T3", "state_changed", "2026-10-09T16:10:00Z", {"from": "blocked", "to": "running"})

    # --- dispatch latency: dispatched_at_ms -> at_ms, two known deltas (ms) ---
    ev(conn, "T1", "prompt_occ_seen", "2026-10-09T17:00:00Z",
       {"occ_key": "occ_disp_1", "tool": "write", "dispatched_at_ms": 1_000_000, "at_ms": 1_000_500})
    ev(conn, "T1", "prompt_occ_seen", "2026-10-09T17:00:05Z",
       {"occ_key": "occ_disp_2", "tool": "write", "dispatched_at_ms": 2_000_000, "at_ms": 2_001_500})
    # a seen row with no dispatched_at_ms at all: excluded from dispatch n, not counted as 0
    ev(conn, "T1", "prompt_occ_seen", "2026-10-09T17:00:10Z",
       {"occ_key": "occ_disp_nodispatch", "tool": "write", "at_ms": 3_000_000})

    # --- decision latency (occ_key join, tool=write): 3 known deltas 40/50/60s ---
    for k, delta_s in enumerate((40, 50, 60), start=1):
        key = f"occ_wb_{k}"
        ev(conn, "T1", "prompt_occ_seen", "2026-10-09T18:00:00Z",
           {"occ_key": key, "tool": "write"}, suffix=f"_seen{k}")
        ev(conn, "T1", "prompt_occ_authorized", f"2026-10-09T18:0{delta_s // 60}:{delta_s % 60:02d}Z",
           {"occ_key": key}, suffix=f"_auth{k}")
    # single-row edge, isolated window
    ev(conn, "T1", "prompt_occ_seen", "2026-10-09T19:00:00Z",
       {"occ_key": "occ_wb_solo", "tool": "write"})
    ev(conn, "T1", "prompt_occ_authorized", "2026-10-09T19:00:25Z", {"occ_key": "occ_wb_solo"})
    # unresolved: seen (tool=write), never authorized
    ev(conn, "T1", "prompt_occ_seen", "2026-10-09T19:30:00Z",
       {"occ_key": "occ_wb_unresolved", "tool": "write"})
    # a non-write seen must never pollute the tool='write' figures
    ev(conn, "T1", "prompt_occ_seen", "2026-10-09T19:00:00Z",
       {"occ_key": "occ_wb_bash", "tool": "bash"}, suffix="_bashseen")
    ev(conn, "T1", "prompt_occ_authorized", "2026-10-09T19:00:01Z",
       {"occ_key": "occ_wb_bash"}, suffix="_bashauth")

    # --- completion latency (occ_key join): 2 known deltas 5/15s ---
    for k, delta_s in enumerate((5, 15), start=1):
        key = f"occ_comp_{k}"
        ev(conn, "T1", "prompt_occ_authorized", "2026-10-09T20:00:00Z",
           {"occ_key": key}, suffix=f"_cauth{k}")
        ev(conn, "T1", "prompt_occ_completed", f"2026-10-09T20:00:{delta_s:02d}Z",
           {"occ_key": key, "is_error": False}, suffix=f"_ccomp{k}")
    # unresolved: authorized, never completed/declined/withdrawn
    ev(conn, "T1", "prompt_occ_authorized", "2026-10-09T20:30:00Z", {"occ_key": "occ_comp_unresolved"})
    # declined is a REAL resolution, must not count as unresolved
    ev(conn, "T1", "prompt_occ_authorized", "2026-10-09T20:40:00Z", {"occ_key": "occ_comp_declined"},
       suffix="_dauth")
    ev(conn, "T1", "prompt_occ_declined", "2026-10-09T20:40:05Z",
       {"occ_key": "occ_comp_declined", "reason": "deny"}, suffix="_ddecl")

    # --- repeated (task_id, command) pairs ---
    for k in range(4):
        appr(conn, f"rc_t1_cmda_{k}", "T1", "conductor", f"2026-10-20T0{k}:00:00Z", command="cmdA")
    for k in range(2):
        appr(conn, f"rc_t1_cmdb_{k}", "T1", "conductor", f"2026-10-20T1{k}:00:00Z", command="cmdB")
    for k in range(3):
        appr(conn, f"rc_t2_cmda_{k}", "T2", "conductor", f"2026-10-20T2{k}:00:00Z", command="cmdA")

    # --- duplicate input_required signals ---
    ev(conn, "T1", "input_required", "2026-10-21T01:00:00Z", {"prompt_id": "dup1"}, suffix="_a")
    ev(conn, "T1", "input_required", "2026-10-21T02:00:00Z", {"prompt_id": "dup1"}, suffix="_b")
    ev(conn, "T1", "input_required", "2026-10-21T03:00:00Z", {"prompt_id": "nodupe"})

    # --- no-provenance overlay occurrences ---
    ev(conn, "T1", "notify_probe_outcome", "2026-10-22T01:00:00Z",
       {"occurrence_id": "occA", "result": "no_provenance"}, suffix="_a")
    ev(conn, "T1", "notify_probe_outcome", "2026-10-22T01:05:00Z",
       {"occurrence_id": "occA", "result": "no_provenance"}, suffix="_b")
    ev(conn, "T1", "notify_probe_outcome", "2026-10-22T01:10:00Z",
       {"occurrence_id": "occB", "result": "no_provenance"})
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
        be_single = orch_metrics.compute_blocked_episodes(
            conn, "2026-10-09T09:55:00Z", "2026-10-09T10:06:00Z")
        check("blocked single-row episodes", be_single["episodes"] == 1)
        check("blocked single-row total_min", math.isclose(be_single["total_min"], 5.0))
        check("blocked single-row ge10_episode_share", be_single["ge10_episode_share"] == 0.0)

        # --- blocked episodes, empty window ---
        be_empty = orch_metrics.compute_blocked_episodes(
            conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("blocked empty episodes", be_empty["episodes"] == 0)
        check("blocked empty total_min", be_empty["total_min"] == 0)
        check("blocked empty share is None", be_empty["ge10_episode_share"] is None
              and be_empty["ge10_minute_share"] is None)

        # --- blocked episodes, exact 600s boundary (>= must include it) ---
        be_600 = orch_metrics.compute_blocked_episodes(
            conn, "2026-10-09T15:59:00Z", "2026-10-09T16:11:00Z")
        check("blocked 600s-boundary episodes", be_600["episodes"] == 1)
        check("blocked 600s-boundary total_min", math.isclose(be_600["total_min"], 10.0))
        check("blocked 600s-boundary counted as ge10", be_600["episodes_ge10"] == 1)

        # --- top escalations ---
        esc = orch_metrics.compute_top_escalations(
            conn, "2026-10-09T00:00:00Z", "2026-10-09T23:59:59Z")
        check("escalations total", esc["total"] == 21)
        check("escalations top5 len", len(esc["top"]) == 5)
        check("escalations top1", esc["top"][0] == {"reason": "multi_row_menu", "n": 6})
        check("escalations top5 excludes 6th", all(r["reason"] != "sixth_reason" for r in esc["top"]))
        esc_empty = orch_metrics.compute_top_escalations(conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("escalations empty window", esc_empty["total"] == 0 and esc_empty["top"] == [])

        # --- conductor latency: known deltas 10..100s, plus unresolved ---
        lat = orch_metrics.compute_conductor_latency(
            conn, "2026-10-09T13:00:00Z", "2026-10-09T13:01:40Z")
        check("latency n", lat["n"] == 10)
        check("latency p50 (idx5=50s)", math.isclose(lat["p50"], 50.0))
        check("latency p90 (idx9=90s)", math.isclose(lat["p90"], 90.0))
        check("latency p99 (idx10=100s)", math.isclose(lat["p99"], 100.0))

        lat_unresolved = orch_metrics.compute_conductor_latency(
            conn, "2026-10-09T14:29:00Z", "2026-10-09T14:31:00Z")
        check("latency unresolved counts the never-decided arrival",
              lat_unresolved["unresolved"] == 1 and lat_unresolved["n"] == 0)

        lat_empty = orch_metrics.compute_conductor_latency(
            conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("latency empty n and unresolved", lat_empty["n"] == 0 and lat_empty["unresolved"] == 0)

        # --- dispatch latency: dispatched_at_ms -> at_ms ---
        disp = orch_metrics.compute_dispatch_latency(
            conn, "2026-10-09T16:59:00Z", "2026-10-09T17:01:00Z", tool="write")
        check("dispatch latency excludes the no-dispatched_at_ms row", disp["n"] == 2)
        check("dispatch latency p50 (0.5s, 1.5s -> idx1=0.5)", math.isclose(disp["p50"], 0.5))
        check("dispatch latency p99 (1.5s)", math.isclose(disp["p99"], 1.5))

        # --- decision latency: occ_key-joined, tool=write, 3 known deltas + unresolved ---
        dec = orch_metrics.compute_decision_latency(
            conn, "2026-10-09T17:59:00Z", "2026-10-09T18:01:00Z", tool="write")
        check("decision latency n (occ_key join fixed, was prompt_id and matched 0)", dec["n"] == 3)
        check("decision latency p50 (idx2=50s)", math.isclose(dec["p50"], 50.0))
        check("decision latency p90 (idx3=60s)", math.isclose(dec["p90"], 60.0))
        check("decision latency bash occurrence not counted under tool=write",
              dec["n"] == 3)

        dec_unresolved = orch_metrics.compute_decision_latency(
            conn, "2026-10-09T19:29:00Z", "2026-10-09T19:31:00Z", tool="write")
        check("decision latency unresolved counts the never-authorized seen",
              dec_unresolved["unresolved"] == 1 and dec_unresolved["n"] == 0)

        dec_solo = orch_metrics.compute_decision_latency(
            conn, "2026-10-09T18:59:00Z", "2026-10-09T19:01:00Z", tool="write")
        check("decision latency single-row n", dec_solo["n"] == 1)
        check("decision latency single-row value", dec_solo["p50"] == 25.0)

        # --- completion latency: occ_key-joined, 2 known deltas + unresolved + declined-not-unresolved ---
        comp = orch_metrics.compute_completion_latency(
            conn, "2026-10-09T19:59:00Z", "2026-10-09T20:01:00Z")
        check("completion latency n", comp["n"] == 2)
        check("completion latency p50 (idx1=5s)", math.isclose(comp["p50"], 5.0))
        check("completion latency p99 (idx2=15s)", math.isclose(comp["p99"], 15.0))

        comp_unresolved = orch_metrics.compute_completion_latency(
            conn, "2026-10-09T20:29:00Z", "2026-10-09T20:41:00Z")
        check("completion latency unresolved excludes the declined occurrence",
              comp_unresolved["unresolved"] == 1)

        # --- decided_by actors: full breakdown, no truncation, totals reconcile ---
        dba = orch_metrics.compute_decided_by_actors(
            conn, "2026-10-10T00:00:00Z", "2026-10-12T23:59:59Z")
        check("decided_by actors distinct count (no top-N truncation)", len(dba["actors"]) == 4)
        check("decided_by actors total reconciles", dba["total"] == sum(a["n"] for a in dba["actors"])
              and dba["total"] == 7)
        check("decided_by actors includes every distinct value", {a["decided_by"] for a in dba["actors"]}
              == {"cli", "peer-answer", "w72:p1", "hub form 123"})

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
            {"date": "2026-10-12", "n": 2},
        ])
        dpd_empty = orch_metrics.compute_decisions_per_day(conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("decisions/day empty", dpd_empty == [])

        # --- repeated (task_id, command) pairs, n>=3 ---
        rc = orch_metrics.compute_repeated_commands(
            conn, "2026-10-20T00:00:00Z", "2026-10-20T23:59:59Z")
        check("repeated commands total_pairs", rc["total_pairs"] == 2)
        check("repeated commands max_n", rc["max_n"] == 4)
        check("repeated commands excludes <3", all(
            not (p["task_id"] == "T1" and p["command"] == "cmdB") for p in rc["pairs"]))
        check("repeated commands includes both qualifying pairs", sorted(
            (p["task_id"], p["command"], p["n"]) for p in rc["pairs"]
        ) == [("T1", "cmdA", 4), ("T2", "cmdA", 3)])
        rc_empty = orch_metrics.compute_repeated_commands(
            conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("repeated commands empty", rc_empty["pairs"] == [] and rc_empty["max_n"] == 0)

        # --- duplicate input_required signals by (date, prompt_id) ---
        ds = orch_metrics.compute_duplicate_signals(
            conn, "2026-10-21T00:00:00Z", "2026-10-21T23:59:59Z")
        check("duplicate signals total", ds["total"] == 1)
        check("duplicate signals entry", ds["duplicates"] == [
            {"date": "2026-10-21", "prompt_id": "dup1", "n": 2}
        ])
        ds_empty = orch_metrics.compute_duplicate_signals(
            conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("duplicate signals empty", ds_empty["duplicates"] == [] and ds_empty["total"] == 0)

        # --- no-provenance overlay occurrences, n>=2 ---
        onp = orch_metrics.compute_overlay_no_provenance(
            conn, "2026-10-22T00:00:00Z", "2026-10-22T23:59:59Z")
        check("overlay occurrences total", onp["total"] == 1)
        check("overlay occurrences entry", onp["occurrences"] == [
            {"task_id": "T1", "occurrence_id": "occA", "n": 2}
        ])
        onp_empty = orch_metrics.compute_overlay_no_provenance(
            conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("overlay occurrences empty", onp_empty["occurrences"] == [] and onp_empty["total"] == 0)

        # --- daily (conductor decisions, conductor p90) pairs ---
        dcp = orch_metrics.compute_daily_conductor_pairs(
            conn, "2026-10-09T13:00:00Z", "2026-10-09T13:01:40Z")
        check("daily conductor pairs", dcp == [
            {"date": "2026-10-09", "decisions": 10, "p90": 90.0}
        ])
        dcp_empty = orch_metrics.compute_daily_conductor_pairs(
            conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("daily conductor pairs empty", dcp_empty == [])

        # --- stop-rule series ---
        srs = orch_metrics.compute_stop_rule_series(
            conn, "2026-10-09T13:00:00Z", "2026-10-09T13:01:40Z")
        check("stop-rule series", srs["series"] == [
            {"date": "2026-10-09", "arrivals": 10, "mean_wait_s": 55.0}
        ])
        check("stop-rule L not computed", srs["L"] is None and isinstance(srs["L_note"], str))

        # --- main drops threads: real-prose reason classification ---
        mdt = orch_metrics.compute_main_drops_threads(conn, "2026-10-13T00:00:00Z", "2026-10-14T23:59:59Z")
        check("main_drops_threads main_pane resolved via `label` column (was `role`, always None)",
              mdt["main_pane"] == "w72:p1")
        check("main_drops_threads day1: 1 no_response drop, 1 excluded human_reserved", mdt["series"][0] == {
            "date": "2026-10-13", "drops": 1, "no_response": 1, "unverified": 0,
            "excluded_human_reserved": 1, "served": 2,
        })
        check("main_drops_threads day2: unmatched/empty reasons both land in unverified, counted as drops",
              mdt["series"][1] == {
                  "date": "2026-10-14", "drops": 2, "no_response": 0, "unverified": 2,
                  "excluded_human_reserved": 0, "served": 2,
              })
        check("main_drops_threads excludes TB (conductor is not main)",
              sum(r["served"] for r in mdt["series"]) == 4)

        check("_classify_drop_reason: human_reserved prefix",
              orch_metrics._classify_drop_reason("Only a human can approve this (x)") == "human_reserved")
        check("_classify_drop_reason: no_response prefix",
              orch_metrics._classify_drop_reason("No response 5s after ...") == "no_response")
        check("_classify_drop_reason: empty -> unverified",
              orch_metrics._classify_drop_reason("") == "unverified")
        check("_classify_drop_reason: unmatched text -> unverified (never silently excluded)",
              orch_metrics._classify_drop_reason("something unexpected") == "unverified")
        check("_classify_drop_reason: the old literal enum string never matches anything real",
              orch_metrics._classify_drop_reason("human_reserved") == "unverified"
              and orch_metrics._classify_drop_reason("unanswerable_overlay") == "unverified")

        # --- main-pane override still works ---
        mdt_override = orch_metrics.compute_main_drops_threads(
            conn, "2026-10-13T00:00:00Z", "2026-10-14T23:59:59Z", main_pane_override="w7T:pX")
        check("main_drops_threads override targets TB only",
              mdt_override["main_pane"] == "w7T:pX" and len(mdt_override["series"]) == 1
              and mdt_override["series"][0]["served"] == 1)

        mdt_empty = orch_metrics.compute_main_drops_threads(
            conn, "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        check("main_drops_threads empty window", mdt_empty["main_pane"] == "w72:p1"
              and mdt_empty["series"] == [])

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

        # --- cost proxies: no token column; prompts_per_task is the available proxy ---
        cp = orch_metrics.compute_cost_proxies(conn, "2026-10-20T00:00:00Z", "2026-10-20T23:59:59Z")
        check("cost proxies: tokens is None with an explanatory note",
              cp["tokens"] is None and "no token" in cp["tokens_note"])
        check("cost proxies: prompts_per_task covers both tasks", {p["task_id"] for p in cp["prompts_per_task"]}
              == {"T1", "T2"})
        check("cost proxies: prompts_per_task_avg", math.isclose(cp["prompts_per_task_avg"], 4.5))

        conn.close()

        # --- deploy_windows: pure function, no DB needed ---
        dw_none = orch_metrics.deploy_windows([], "2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z")
        check("deploy_windows: no deploys -> one unlabeled window",
              dw_none == [(None, "2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z")])

        deploys = [
            {"revision": "v1", "deployed_at": "2026-10-10T00:00:00Z"},
            {"revision": "v2", "deployed_at": "2026-10-15T00:00:00Z"},
        ]
        dw = orch_metrics.deploy_windows(deploys, "2026-10-05T00:00:00Z", "2026-10-20T00:00:00Z")
        check("deploy_windows: splits into pre/v1/v2", [w[0] for w in dw] == ["pre-v1", "v1", "v2"])
        check("deploy_windows: window edges are contiguous", dw == [
            ("pre-v1", "2026-10-05T00:00:00Z", "2026-10-10T00:00:00Z"),
            ("v1", "2026-10-10T00:00:00Z", "2026-10-15T00:00:00Z"),
            ("v2", "2026-10-15T00:00:00Z", "2026-10-20T00:00:00Z"),
        ])

        dw_unbounded = orch_metrics.deploy_windows(deploys, None, None)
        check("deploy_windows: since/until None binds to the deploy list's own span",
              dw_unbounded == [("v1", "2026-10-10T00:00:00Z", "2026-10-15T00:00:00Z")])

        dw_single_point = orch_metrics.deploy_windows(deploys, "2026-10-12T00:00:00Z", "2026-10-12T00:00:00Z")
        check("deploy_windows: zero-length request still returns the active revision",
              dw_single_point == [("v1", "2026-10-12T00:00:00Z", "2026-10-12T00:00:00Z")])

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
            {"date": "2026-10-12", "n": 2},
        ])
        check("CLI JSON revision is null without --deploys", cli_report["revision"] is None)

        # --- CLI smoke with --deploys: output is a list, one report per revision window ---
        deploys_fd, deploys_path = tempfile.mkstemp(suffix=".json", prefix="orch-metrics-deploys-")
        with os.fdopen(deploys_fd, "w") as f:
            json.dump([
                {"revision": "pre-fix", "deployed_at": "2026-10-10T00:00:00Z"},
                {"revision": "post-fix", "deployed_at": "2026-10-11T00:00:00Z"},
            ], f)
        try:
            out2 = subprocess.run(
                [sys.executable, SCRIPT_PATH, "--db", path, "--deploys", deploys_path,
                 "--since", "2026-10-10T00:00:00Z", "--until", "2026-10-12T23:59:59Z", "--json"],
                capture_output=True, text=True, check=True,
            )
            cli_reports = json.loads(out2.stdout)
            check("CLI --deploys: one report per revision window", len(cli_reports) == 2)
            check("CLI --deploys: revisions labeled in order",
                  [r["revision"] for r in cli_reports] == ["pre-fix", "post-fix"])
        finally:
            os.remove(deploys_path)

        check("CLI subprocess exited 0 (no write attempted/failed silently)",
              out.returncode == 0)

    finally:
        os.remove(path)

    print(f"\n{CHECKS} checks passed")


if __name__ == "__main__":
    main()
