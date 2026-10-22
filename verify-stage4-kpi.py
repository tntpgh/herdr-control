#!/usr/bin/env python3
"""Fixture-only verification for scripts/stage4-kpi.py.

.handoffs/SPEC.md T4 item 3 (2026-10-21): proves the four charter Stage-4
KPIs compute correctly from synthetic `loop_event` ledger records, AND --
the more important property today, since nothing yet writes those records
-- that an empty ledger and the REAL current ledger shape (sentry/kb/github
poller records only, zero loop_event records) both report every KPI as
`insufficient_data`, never 0.

NEVER touches a real ledger: every ledger dir this suite reads is a
tempfile directory it creates and deletes.
"""
import glob
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT_PATH = os.path.join(HERE, "scripts", "stage4-kpi.py")

_spec = importlib.util.spec_from_file_location("stage4_kpi", SCRIPT_PATH)
stage4_kpi = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stage4_kpi)

CHECKS = 0


def check(label, cond):
    global CHECKS
    assert cond, f"FAILED: {label}"
    CHECKS += 1
    print(f"ok: {label}")


def write_jsonl(path, lines):
    with open(path, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line if isinstance(line, str) else json.dumps(line))
            f.write("\n")


def main():
    workdir = tempfile.mkdtemp()
    try:
        # ---- empty ledger dir: every KPI insufficient, never 0 -----------
        empty_dir = os.path.join(workdir, "empty")
        os.makedirs(empty_dir)
        report = stage4_kpi.compute_report(__import__("pathlib").Path(empty_dir))
        check("empty ledger: zero loop_event records found", report["loop_event_records_found"] == 0)
        for name, kpi in report["kpis"].items():
            check(f"empty ledger: {name} reports insufficient_data (never 0)", kpi["status"] == "insufficient_data")
            check(f"empty ledger: {name} status is a string, not a bare 0/number", isinstance(kpi["status"], str))

        # ---- real-shaped ledger: today's actual poller records only ------
        # Mirrors the real schema (lib/engineering-ledger.sh ledger_collect_*):
        # sentry/kb/github sources, zero loop_event -- the exact shape of
        # .local-state/engineering-ledger/*.jsonl today.
        pollers_dir = os.path.join(workdir, "pollers")
        os.makedirs(pollers_dir)
        write_jsonl(os.path.join(pollers_dir, "2026-10-20.jsonl"), [
            {"schema": 1, "poll_id": "p1", "observed_at": "2026-10-20T20:00:00Z", "source": "sentry",
             "source_id": "tourguide", "status": "ok"},
            {"schema": 1, "poll_id": "p1", "observed_at": "2026-10-20T20:00:00Z", "source": "kb",
             "source_id": "nightly_resilience", "status": "ok", "window_hours": 24, "failed_steps_count": 0,
             "error_signatures": {}, "failures": []},
            {"schema": 1, "poll_id": "p1", "observed_at": "2026-10-20T20:00:00Z", "source": "github",
             "source_id": "tourguide", "status": "ok",
             "pull_requests": {"status": "ok", "sample_size": 20, "open": 2, "merged": 18}},
        ])
        report = stage4_kpi.compute_report(__import__("pathlib").Path(pollers_dir))
        check("pollers-only ledger: 3 lines read", report["jsonl_lines_read"] == 3)
        check("pollers-only ledger: zero loop_event records (today's real ledger shape)",
              report["loop_event_records_found"] == 0)
        for name, kpi in report["kpis"].items():
            check(f"pollers-only ledger: {name} reports insufficient_data, not a fabricated 0",
                  kpi["status"] == "insufficient_data")

        # ---- malformed lines: skipped and counted, never crash -----------
        malformed_dir = os.path.join(workdir, "malformed")
        os.makedirs(malformed_dir)
        write_jsonl(os.path.join(malformed_dir, "a.jsonl"), [
            "{not json",
            {"schema": 1, "observed_at": "2026-10-01T00:00:00Z", "source": "loop_event",
             "kind": "finding_surfaced", "signature": "sigX", "surfaced_by": "human"},
            "",
            "also not json {{{",
        ])
        events, total, malformed = stage4_kpi.load_loop_events(__import__("pathlib").Path(malformed_dir))
        check("malformed lines: 3 non-blank lines read", total == 3)
        check("malformed lines: 2 malformed lines skipped, not crashed on", malformed == 2)
        check("malformed lines: the 1 valid loop_event record still parsed", len(events) == 1)

        # ---- full synthetic data: exact computed math ---------------------
        synth_dir = os.path.join(workdir, "synth")
        os.makedirs(synth_dir)
        T0 = "2026-08-01T00:00:00Z"
        write_jsonl(os.path.join(synth_dir, "a.jsonl"), [
            # sigA: loop-surfaced, fixed in 10h total (2h to open, 8h to merge), never recurs
            {"schema": 1, "observed_at": "2026-08-01T00:00:00Z", "source": "loop_event",
             "kind": "finding_surfaced", "signature": "sigA", "surfaced_by": "loop"},
            {"schema": 1, "observed_at": "2026-08-01T02:00:00Z", "source": "loop_event",
             "kind": "pr_opened", "signature": "sigA", "pr": "tourguide#1"},
            {"schema": 1, "observed_at": "2026-08-01T10:00:00Z", "source": "loop_event",
             "kind": "pr_merged", "signature": "sigA", "pr": "tourguide#1"},
            {"schema": 1, "observed_at": "2026-08-01T00:00:00Z", "source": "loop_event",
             "kind": "fix_cost", "signature": "sigA", "model": "sol", "cost_usd": 2.0},
            # sigB: human-surfaced, fixed in 8h total (4h to open, 4h to merge), RECURS at +20h
            {"schema": 1, "observed_at": "2026-08-01T00:00:00Z", "source": "loop_event",
             "kind": "finding_surfaced", "signature": "sigB", "surfaced_by": "human"},
            {"schema": 1, "observed_at": "2026-08-01T04:00:00Z", "source": "loop_event",
             "kind": "pr_opened", "signature": "sigB", "pr": "tourguide#2"},
            {"schema": 1, "observed_at": "2026-08-01T08:00:00Z", "source": "loop_event",
             "kind": "pr_merged", "signature": "sigB", "pr": "tourguide#2"},
            {"schema": 1, "observed_at": "2026-08-01T20:00:00Z", "source": "loop_event",
             "kind": "finding_surfaced", "signature": "sigB", "surfaced_by": "loop"},
            {"schema": 1, "observed_at": "2026-08-01T00:00:00Z", "source": "loop_event",
             "kind": "fix_cost", "signature": "sigB", "model": "fable-5", "cost_usd": 10.0},
            # sigC: lone human-surfaced finding, no fix yet (never pairs for time-to-fix)
            {"schema": 1, "observed_at": "2026-08-01T00:00:00Z", "source": "loop_event",
             "kind": "finding_surfaced", "signature": "sigC", "surfaced_by": "human"},
            # second sol fix (unrelated signature) for the cost-per-fix mean
            {"schema": 1, "observed_at": "2026-08-01T00:00:00Z", "source": "loop_event",
             "kind": "fix_cost", "signature": "sigD", "model": "sol", "cost_usd": 4.0},
        ])
        report = stage4_kpi.compute_report(__import__("pathlib").Path(synth_dir))
        surf = report["kpis"]["surfaced_by_loop_vs_human"]
        check("synthetic: surfacing status ok", surf["status"] == "ok")
        check("synthetic: 2 loop-surfaced (sigA, sigB recurrence)", surf["loop_surfaced"] == 2)
        check("synthetic: 2 human-surfaced (sigB initial, sigC)", surf["human_surfaced"] == 2)
        check("synthetic: loop ratio 0.5", surf["loop_ratio"] == 0.5)

        ttf = report["kpis"]["time_to_fix"]
        check("synthetic: time_to_fix status ok", ttf["status"] == "ok")
        check("synthetic: 2 complete surfaced->opened->merged triples", ttf["complete_fixes"] == 2)
        check("synthetic: median surfaced->opened = 3h (sigA 2h, sigB 4h)",
              ttf["median_surfaced_to_opened_hours"] == 3.0)
        check("synthetic: median opened->merged = 6h (sigA 8h, sigB 4h)",
              ttf["median_opened_to_merged_hours"] == 6.0)
        check("synthetic: median surfaced->merged = 9h (sigA 10h, sigB 8h)",
              ttf["median_surfaced_to_merged_hours"] == 9.0)

        cost = report["kpis"]["cost_per_fix"]
        check("synthetic: cost_per_fix status ok", cost["status"] == "ok")
        check("synthetic: sol mean cost 3.0 across 2 fixes", cost["by_model"]["sol"]["mean_cost_usd"] == 3.0
              and cost["by_model"]["sol"]["fixes"] == 2)
        check("synthetic: fable-5 mean cost 10.0 across 1 fix", cost["by_model"]["fable-5"]["mean_cost_usd"] == 10.0
              and cost["by_model"]["fable-5"]["fixes"] == 1)

        rec = report["kpis"]["recurrence_rate"]
        check("synthetic: recurrence status ok", rec["status"] == "ok")
        check("synthetic: 2 signatures had a fix (sigA, sigB)", rec["signatures_with_a_fix"] == 2)
        check("synthetic: 1 of 2 recurred (sigB only)", rec["signatures_that_recurred"] == 1)
        check("synthetic: recurrence rate 0.5", rec["recurrence_rate"] == 0.5)

        # ---- CLI: missing ledger dir is a real error (exit 2), not insufficient-data --
        missing = os.path.join(workdir, "does-not-exist")
        out = subprocess.run([sys.executable, SCRIPT_PATH, "--ledger-dir", missing],
                              capture_output=True, text=True)
        check("CLI: missing ledger dir exits 2", out.returncode == 2)
        check("CLI: missing ledger dir names the path on stderr", missing in out.stderr)

        # ---- CLI: --format text on the empty dir still reports honestly --
        out2 = subprocess.run([sys.executable, SCRIPT_PATH, "--ledger-dir", empty_dir, "--format", "text"],
                               capture_output=True, text=True)
        check("CLI --format text: exits 0", out2.returncode == 0)
        check("CLI --format text: every KPI line says insufficient_data",
              out2.stdout.count("insufficient_data") == 4)

        # ---- CLI: --format json round-trips the same report shape --------
        out3 = subprocess.run([sys.executable, SCRIPT_PATH, "--ledger-dir", synth_dir],
                               capture_output=True, text=True)
        check("CLI --format json: exits 0", out3.returncode == 0)
        cli_report = json.loads(out3.stdout)
        check("CLI json output matches direct compute_report()", cli_report["kpis"] == report["kpis"])

    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print(f"\n{CHECKS} checks passed")


if __name__ == "__main__":
    main()
