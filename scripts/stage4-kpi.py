#!/usr/bin/env python3
"""scripts/stage4-kpi.py — offline calculator for the charter's Stage 4 KPIs.

.handoffs/SPEC.md T4 item 3 (2026-10-21, "T5 seed"): thurber-os
docs/engineering-evolution-loop-charter.md §3 Stage 4 ("MEASURE & ADAPT")
names four KPIs this computes, read-only, from the Stage-1 poll ledger JSONL
(lib/engineering-ledger.sh's output, default `.local-state/engineering-ledger/
*.jsonl` under this repo, override with `--ledger-dir` or
`STAGE4_LEDGER_DIR`):

  1. surfaced-by-loop vs surfaced-by-human ratio
  2. time-to-fix: surfaced -> PR opened -> merged
  3. cost per fix, Sol vs Fable-5 tracked separately
  4. recurrence rate: did a bug-class resurface after a fix

Every poll record in that ledger today has `source` in {sentry, kb, github}
(see lib/engineering-ledger.sh's `ledger_collect_*` functions) -- health
snapshots, not fix-provenance events. None of the four KPIs above can be
computed from that alone, so this script also defines the one new record
kind the ledger needs before they can report real numbers, `"source":
"loop_event"`, and looks for it on every run:

  {"schema":1,"observed_at":"<ISO8601Z>","source":"loop_event",
   "kind":"finding_surfaced","signature":"<bug-class>",
   "surfaced_by":"loop"|"human"}
  {"schema":1,"observed_at":"<ISO8601Z>","source":"loop_event",
   "kind":"pr_opened","signature":"<bug-class>","pr":"<repo>#<n>"}
  {"schema":1,"observed_at":"<ISO8601Z>","source":"loop_event",
   "kind":"pr_merged","signature":"<bug-class>","pr":"<repo>#<n>"}
  {"schema":1,"observed_at":"<ISO8601Z>","source":"loop_event",
   "kind":"fix_cost","signature":"<bug-class>","model":"sol"|"fable-5",
   "cost_usd":<number>}

As of 2026-10-21 NOTHING writes `loop_event` records -- run this against the
live ledger today and every KPI below correctly reports `insufficient_data`.
That is the honest answer (SPEC: "Unknown or insufficient data = reported as
such, never 0"), not a bug in this script. The next gate before any of the
four KPIs carries real numbers is Stage 2/3 wiring `finding_surfaced`/
`pr_opened`/`pr_merged`/`fix_cost` events into the ledger as those stages
produce them -- see .handoffs/briefs/eloop-stage2-repair.RESULT.md.

Time-to-fix and recurrence pair events per signature POSITIONALLY (i-th
finding_surfaced with i-th pr_opened with i-th pr_merged, each list sorted
by observed_at) -- a seed heuristic, not a join key; a future iteration that
stamps a shared `finding_id` across the four kinds should pair on that
instead.

  python3 scripts/stage4-kpi.py [--ledger-dir DIR] [--format json|text]

Exit codes: 0 on a normal report (however thin the data), 2 if --ledger-dir
does not exist (misconfiguration, not "no data yet").
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
DEFAULT_LEDGER_DIR = Path(
    os.environ.get("STAGE4_LEDGER_DIR", str(REPO_ROOT / ".local-state" / "engineering-ledger"))
)

INSUFFICIENT = "insufficient_data"
OK = "ok"


def _parse_ts(s: str) -> dt.datetime | None:
    try:
        return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except (ValueError, TypeError):
        return None


def load_loop_events(ledger_dir: Path) -> tuple[list[dict], int, int]:
    """Returns (loop_event records, total lines read, malformed lines skipped).
    Never raises on a bad file or line -- an offline reporting tool must not
    crash on the exact messy input it exists to characterize honestly."""
    events: list[dict] = []
    total = 0
    malformed = 0
    for path in sorted(glob.glob(str(ledger_dir / "*.jsonl"))):
        try:
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    total += 1
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        malformed += 1
                        continue
                    if not isinstance(rec, dict) or rec.get("source") != "loop_event":
                        continue
                    events.append(rec)
        except OSError:
            continue
    return events, total, malformed


def compute_surfacing(events: list[dict]) -> dict:
    surfaced = [e for e in events if e.get("kind") == "finding_surfaced"]
    loop_n = sum(1 for e in surfaced if e.get("surfaced_by") == "loop")
    human_n = sum(1 for e in surfaced if e.get("surfaced_by") == "human")
    total = loop_n + human_n
    if total == 0:
        return {"status": INSUFFICIENT, "reason": "no finding_surfaced records in the ledger"}
    return {
        "status": OK,
        "loop_surfaced": loop_n,
        "human_surfaced": human_n,
        "loop_ratio": round(loop_n / total, 4),
    }


def _by_signature(events: list[dict], kind: str) -> dict[str, list[dt.datetime]]:
    out: dict[str, list[dt.datetime]] = {}
    for e in events:
        if e.get("kind") != kind:
            continue
        sig = e.get("signature")
        ts = _parse_ts(e.get("observed_at", ""))
        if sig is None or ts is None:
            continue
        out.setdefault(sig, []).append(ts)
    for sig in out:
        out[sig].sort()
    return out


def compute_time_to_fix(events: list[dict]) -> dict:
    surfaced = _by_signature(events, "finding_surfaced")
    opened = _by_signature(events, "pr_opened")
    merged = _by_signature(events, "pr_merged")
    surfaced_to_opened_h: list[float] = []
    opened_to_merged_h: list[float] = []
    surfaced_to_merged_h: list[float] = []
    for sig, s_list in surfaced.items():
        o_list = opened.get(sig, [])
        m_list = merged.get(sig, [])
        n = min(len(s_list), len(o_list), len(m_list))
        for i in range(n):
            s, o, m = s_list[i], o_list[i], m_list[i]
            surfaced_to_opened_h.append((o - s).total_seconds() / 3600)
            opened_to_merged_h.append((m - o).total_seconds() / 3600)
            surfaced_to_merged_h.append((m - s).total_seconds() / 3600)
    if not surfaced_to_merged_h:
        return {"status": INSUFFICIENT, "reason": "no signature has a complete surfaced->opened->merged triple"}
    return {
        "status": OK,
        "complete_fixes": len(surfaced_to_merged_h),
        "median_surfaced_to_opened_hours": round(statistics.median(surfaced_to_opened_h), 2),
        "median_opened_to_merged_hours": round(statistics.median(opened_to_merged_h), 2),
        "median_surfaced_to_merged_hours": round(statistics.median(surfaced_to_merged_h), 2),
    }


def compute_cost_per_fix(events: list[dict]) -> dict:
    by_model: dict[str, list[float]] = {}
    for e in events:
        if e.get("kind") != "fix_cost":
            continue
        model = e.get("model")
        cost = e.get("cost_usd")
        if model is None or not isinstance(cost, (int, float)):
            continue
        by_model.setdefault(model, []).append(float(cost))
    if not by_model:
        return {"status": INSUFFICIENT, "reason": "no fix_cost records in the ledger"}
    per_model = {}
    for model in ("sol", "fable-5"):
        costs = by_model.get(model)
        if not costs:
            per_model[model] = {"status": INSUFFICIENT, "reason": f"no fix_cost records for model={model}"}
        else:
            per_model[model] = {
                "status": OK,
                "fixes": len(costs),
                "mean_cost_usd": round(statistics.mean(costs), 4),
                "total_cost_usd": round(sum(costs), 4),
            }
    other_models = sorted(set(by_model) - {"sol", "fable-5"})
    if other_models:
        per_model["_other_models_seen"] = other_models
    return {"status": OK, "by_model": per_model}


def compute_recurrence(events: list[dict]) -> dict:
    surfaced = _by_signature(events, "finding_surfaced")
    merged = _by_signature(events, "pr_merged")
    closed_signatures = [sig for sig, m_list in merged.items() if m_list]
    if not closed_signatures:
        return {"status": INSUFFICIENT, "reason": "no signature has a pr_merged record to measure recurrence against"}
    recurred = 0
    for sig in closed_signatures:
        first_merge = merged[sig][0]
        if any(s > first_merge for s in surfaced.get(sig, [])):
            recurred += 1
    return {
        "status": OK,
        "signatures_with_a_fix": len(closed_signatures),
        "signatures_that_recurred": recurred,
        "recurrence_rate": round(recurred / len(closed_signatures), 4),
    }


def compute_report(ledger_dir: Path) -> dict:
    events, total_lines, malformed = load_loop_events(ledger_dir)
    return {
        "ledger_dir": str(ledger_dir),
        "jsonl_lines_read": total_lines,
        "malformed_lines_skipped": malformed,
        "loop_event_records_found": len(events),
        "kpis": {
            "surfaced_by_loop_vs_human": compute_surfacing(events),
            "time_to_fix": compute_time_to_fix(events),
            "cost_per_fix": compute_cost_per_fix(events),
            "recurrence_rate": compute_recurrence(events),
        },
    }


def render_text(report: dict) -> str:
    lines = [
        f"ledger: {report['ledger_dir']}",
        f"  {report['jsonl_lines_read']} lines read, {report['malformed_lines_skipped']} malformed skipped, "
        f"{report['loop_event_records_found']} loop_event records",
        "",
    ]
    for name, kpi in report["kpis"].items():
        if kpi["status"] == INSUFFICIENT:
            lines.append(f"{name}: insufficient_data — {kpi['reason']}")
        else:
            lines.append(f"{name}: {json.dumps(kpi)}")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ledger-dir", default=str(DEFAULT_LEDGER_DIR),
                    help="directory of poll-ledger *.jsonl files (read-only)")
    ap.add_argument("--format", choices=("json", "text"), default="json")
    args = ap.parse_args()

    ledger_dir = Path(args.ledger_dir)
    if not ledger_dir.is_dir():
        print(f"stage4-kpi: ledger dir does not exist: {ledger_dir}", file=sys.stderr)
        return 2

    report = compute_report(ledger_dir)
    if args.format == "json":
        print(json.dumps(report, indent=2))
    else:
        print(render_text(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
