#!/usr/bin/env python3
"""Read-only metrics over the herdr-control run registry (registry.sqlite3).

Computes the figures from ORCH-HIERARCHY-PLAN-v2.md Appendix A that P0 of the
orchestration-hierarchy plan needs, plus the Section 9.3 "Main drops threads"
daily series:

  - blocked episodes / total minutes / >=10-minute share       (Appendix A §a)
  - top approval_escalated reasons (top 5) + total              (Appendix A §b)
  - conductor-authority signal->answer latency p50/p90/p99      (Appendix A §c, block 1)
  - write-tool binding (prompt_occ_seen->prompt_occ_authorized)
    latency p50/p90/p99                                         (Appendix A §c, block 2)
  - unsubmitted-wake share                                      (Appendix A §d, block 1)
  - conductor decisions per day                                 (Appendix A §d, block 2)
  - repeated (task_id, command) approval pairs, n>=3             (Appendix A §d, block 3)
  - duplicate input_required signals by (date, prompt_id)       (Appendix A §e)
  - no-provenance overlay occurrences, n>=2                     (Appendix A §f)
  - daily (conductor decisions, conductor p90) pairs             (plan §8 P1 target / stop rule)
  - stop-rule series: daily arrivals (lambda) and mean wait (W);
    queue depth L is explicitly NOT computed (see
    `compute_stop_rule_series`'s docstring)                      (plan §8 stop rule, §9.3)
  - "Main drops threads" daily series                           (plan §9.3)

The DB is opened strictly read-only via a `file:...?mode=ro` URI: any write
attempted through the connection this script opens raises
`sqlite3.OperationalError`. This script never opens, reads, or infers the
path to a real registry on its own; the caller supplies `--db` explicitly.

Percentile method (stated per Appendix A's instruction to record one):
nearest-rank on the ascending-sorted sample, matching SQLite's `NTILE(100)`
windowing: for percentile p and n samples, index = ceil(p/100 * n), 1-based,
clamped to [1, n]. n=0 -> None for every percentile. n=1 -> every percentile
returns the single value.

Schema expected (names drawn from Appendix A's "schema the reviewer
confirmed" plus the `roles` primitive described in plan §1.3/§2):
  events(sequence, event_id, run_id, task_id, type, occurred_at, payload)
  approvals(approval_id, run_id, task_id, pane_id, prompt_id, choice,
            decided_by, authority, policy_verdict, command, decided_at,
            attempted_at, outcome)
  tasks(task_id, state, project, updated_at, conductor_pane_id, ...)
  roles(role, pane_id, ...)                      -- optional; see --main-pane

`payload` is a JSON text column; fields are pulled with SQLite's
`json_extract`. The "Main drops threads" query assumes `attention_form_served`
payloads carry an escalation-reason field named `reason` (the same key name
`approval_escalated` payloads use elsewhere in the registry) with values
`human_reserved` / `unanswerable_overlay` for the two excluded categories
named in plan §9.3; the plan does not spell out the exact key, so this is an
explicit convention choice, not a verified fact.
"""
from __future__ import annotations

import argparse
import json
import math
import sqlite3
import sys
from datetime import datetime, timezone
from typing import Optional


EXCLUDED_DROP_REASONS = ("human_reserved", "unanswerable_overlay")


def connect_ro(db_path: str) -> sqlite3.Connection:
    """Open `db_path` strictly read-only. Any write through this connection
    raises sqlite3.OperationalError (`attempt to write a readonly database`)."""
    uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def percentile(sorted_vals: list, p: float) -> Optional[float]:
    """Nearest-rank percentile on an already-ascending-sorted sequence."""
    n = len(sorted_vals)
    if n == 0:
        return None
    idx = max(1, min(n, math.ceil(p / 100.0 * n)))
    return sorted_vals[idx - 1]


def _parse_ts(s: str) -> float:
    """Parse a registry timestamp (ISO8601, optional trailing 'Z') to a UTC
    epoch float. Computed in Python rather than via SQLite's julianday/strftime
    because those silently return NULL on some SQLite builds for a trailing
    'Z', which would corrupt every downstream delta."""
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def _since_until_clause(column: str, since: Optional[str], until: Optional[str]):
    clauses = []
    params: list = []
    if since:
        clauses.append(f"{column} >= ?")
        params.append(since)
    if until:
        clauses.append(f"{column} <= ?")
        params.append(until)
    sql = (" AND " + " AND ".join(clauses)) if clauses else ""
    return sql, params


def compute_blocked_episodes(conn: sqlite3.Connection, since: Optional[str],
                              until: Optional[str]) -> dict:
    """Appendix A §a. Episode = a `state_changed` event with to='blocked',
    closed by that task's next `state_changed` event in the (optionally
    windowed) event stream; open-ended if none follows. Open-ended episodes
    are clamped to `until` if given, else to the current UTC instant (`now`,
    matching the Appendix A query's `strftime('now')` fallback)."""
    clause, params = _since_until_clause("occurred_at", since, until)
    rows = conn.execute(
        f"""
        SELECT task_id, sequence, occurred_at,
               json_extract(payload,'$.to') AS to_state
        FROM events
        WHERE type='state_changed'{clause}
        ORDER BY task_id, sequence
        """,
        params,
    ).fetchall()

    now_ref = until or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")

    by_task: dict = {}
    for r in rows:
        by_task.setdefault(r["task_id"], []).append(r)

    episodes = []
    for task_id, trows in by_task.items():
        for i, r in enumerate(trows):
            if r["to_state"] != "blocked":
                continue
            start_at = r["occurred_at"]
            end_at = None
            for later in trows[i + 1:]:
                end_at = later["occurred_at"]
                break
            close_at = end_at or now_ref
            dur_s = _parse_ts(close_at) - _parse_ts(start_at)
            episodes.append(dur_s)

    total_min = sum(episodes) / 60.0
    ge10 = [e for e in episodes if e >= 600]
    ge10_min = sum(ge10) / 60.0
    return {
        "episodes": len(episodes),
        "total_min": round(total_min, 2),
        "episodes_ge10": len(ge10),
        "min_ge10": round(ge10_min, 2),
        "ge10_episode_share": round(len(ge10) / len(episodes), 4) if episodes else None,
        "ge10_minute_share": round(ge10_min / total_min, 4) if total_min else None,
    }


def compute_top_escalations(conn: sqlite3.Connection, since: Optional[str],
                             until: Optional[str], limit: int = 5) -> dict:
    """Appendix A §b: top `approval_escalated` reasons plus the total count."""
    clause, params = _since_until_clause("occurred_at", since, until)
    rows = conn.execute(
        f"""
        SELECT json_extract(payload,'$.reason') AS reason, count(*) AS n
        FROM events
        WHERE type='approval_escalated'{clause}
        GROUP BY reason ORDER BY n DESC LIMIT ?
        """,
        params + [limit],
    ).fetchall()
    total = conn.execute(
        f"SELECT count(*) AS n FROM events WHERE type='approval_escalated'{clause}",
        params,
    ).fetchone()["n"]
    return {
        "top": [{"reason": r["reason"], "n": r["n"]} for r in rows],
        "total": total,
    }


def compute_conductor_latency(conn: sqlite3.Connection, since: Optional[str],
                               until: Optional[str]) -> dict:
    """Appendix A §c: input_required -> conductor-authority decision latency,
    seconds, p50/p90/p99."""
    clause, params = _since_until_clause("a.decided_at", since, until)
    rows = conn.execute(
        f"""
        WITH ir AS (
          SELECT json_extract(payload,'$.prompt_id') AS pid, occurred_at AS seen_at
          FROM events WHERE type='input_required'
        )
        SELECT a.decided_at AS decided_at, ir.seen_at AS seen_at
        FROM approvals a JOIN ir ON ir.pid = a.prompt_id
        WHERE a.authority='conductor'{clause}
        """,
        params,
    ).fetchall()
    deltas = sorted(_parse_ts(r["decided_at"]) - _parse_ts(r["seen_at"]) for r in rows)
    return {
        "n": len(deltas),
        "p50": percentile(deltas, 50),
        "p90": percentile(deltas, 90),
        "p99": percentile(deltas, 99),
        "method": "nearest-rank on ascending-sorted deltas, "
                  "index=ceil(p/100*n) 1-based (NTILE(100)-equivalent)",
    }


def compute_write_binding_latency(conn: sqlite3.Connection, since: Optional[str],
                                   until: Optional[str]) -> dict:
    """Appendix A §c, second block: `prompt_occ_seen` (tool='write') ->
    `prompt_occ_authorized` latency, seconds, p50/p90/p99. This is the
    "omp binding seen -> authorized, write" / "write seen->decision" figure
    (§1.1, §8 P1 target) and is a distinct figure from
    `compute_conductor_latency`'s generic signal->answer latency: it measures
    the write-tool binding round trip, not every conductor-authority decision."""
    clause, params = _since_until_clause("auth.auth_at", since, until)
    rows = conn.execute(
        f"""
        WITH seen AS (
          SELECT task_id, json_extract(payload,'$.prompt_id') AS pid, occurred_at AS seen_at
          FROM events WHERE type='prompt_occ_seen' AND json_extract(payload,'$.tool')='write'
        ),
        auth AS (
          SELECT task_id, json_extract(payload,'$.prompt_id') AS pid, occurred_at AS auth_at
          FROM events WHERE type='prompt_occ_authorized'
        )
        SELECT auth.auth_at AS auth_at, seen.seen_at AS seen_at
        FROM seen JOIN auth ON seen.task_id = auth.task_id AND seen.pid = auth.pid
        WHERE 1=1{clause}
        """,
        params,
    ).fetchall()
    deltas = sorted(_parse_ts(r["auth_at"]) - _parse_ts(r["seen_at"]) for r in rows)
    return {
        "n": len(deltas),
        "p50": percentile(deltas, 50),
        "p90": percentile(deltas, 90),
        "p99": percentile(deltas, 99),
        "method": "nearest-rank on ascending-sorted deltas, "
                  "index=ceil(p/100*n) 1-based (NTILE(100)-equivalent)",
    }


def compute_wake_outcomes(conn: sqlite3.Connection, since: Optional[str],
                           until: Optional[str]) -> dict:
    """Appendix A §d (wake_result half): outcome counts and unsubmitted share."""
    clause, params = _since_until_clause("occurred_at", since, until)
    rows = conn.execute(
        f"""
        SELECT json_extract(payload,'$.outcome') AS outcome, count(*) AS n
        FROM events WHERE type='wake_result'{clause}
        GROUP BY outcome
        """,
        params,
    ).fetchall()
    counts = {r["outcome"]: r["n"] for r in rows}
    total = sum(counts.values())
    unsubmitted = counts.get("unsubmitted", 0)
    return {
        "counts": counts,
        "total": total,
        "unsubmitted_share": round(unsubmitted / total, 4) if total else None,
    }


def compute_decisions_per_day(conn: sqlite3.Connection, since: Optional[str],
                               until: Optional[str]) -> list:
    """Appendix A §d (decisions/day half): conductor-authority decisions, by day."""
    clause, params = _since_until_clause("decided_at", since, until)
    rows = conn.execute(
        f"""
        SELECT date(decided_at) AS d, count(*) AS n
        FROM approvals WHERE authority='conductor'{clause}
        GROUP BY d ORDER BY d
        """,
        params,
    ).fetchall()
    return [{"date": r["d"], "n": r["n"]} for r in rows]


def compute_repeated_commands(conn: sqlite3.Connection, since: Optional[str],
                               until: Optional[str], min_n: int = 3) -> dict:
    """Appendix A §d, third block: identical `(task_id, command)` approval
    pairs decided `min_n` or more times (the "repetition breaker" input,
    §1.1's "53 (task, command) pairs ... at most 16 times")."""
    clause, params = _since_until_clause("decided_at", since, until)
    rows = conn.execute(
        f"""
        SELECT task_id, command, count(*) AS n
        FROM approvals WHERE 1=1{clause}
        GROUP BY task_id, command HAVING n >= ? ORDER BY n DESC
        """,
        params + [min_n],
    ).fetchall()
    pairs = [{"task_id": r["task_id"], "command": r["command"], "n": r["n"]} for r in rows]
    return {
        "pairs": pairs,
        "total_pairs": len(pairs),
        "max_n": max((p["n"] for p in pairs), default=0),
    }


def compute_duplicate_signals(conn: sqlite3.Connection, since: Optional[str],
                               until: Optional[str]) -> dict:
    """Appendix A §e: duplicate `input_required` events for the same
    `(date, prompt_id)` (feeds G1's "duplicate-signal ... metrics are clean"
    gate; healthy registry state is an empty list, per §1.1's "0 duplicates")."""
    clause, params = _since_until_clause("occurred_at", since, until)
    rows = conn.execute(
        f"""
        SELECT date(occurred_at) AS d, json_extract(payload,'$.prompt_id') AS pid, count(*) AS n
        FROM events WHERE type='input_required'{clause}
        GROUP BY d, pid HAVING n > 1
        """,
        params,
    ).fetchall()
    dups = [{"date": r["d"], "prompt_id": r["pid"], "n": r["n"]} for r in rows]
    return {"duplicates": dups, "total": len(dups)}


def compute_overlay_no_provenance(conn: sqlite3.Connection, since: Optional[str],
                                   until: Optional[str], min_n: int = 2) -> dict:
    """Appendix A §f: `notify_probe_outcome` occurrences with `result`
    'no_provenance' `min_n` or more times on the same `(task_id,
    occurrence_id)` — the §7 `unanswerable_overlay` escalation condition."""
    clause, params = _since_until_clause("occurred_at", since, until)
    rows = conn.execute(
        f"""
        SELECT task_id, json_extract(payload,'$.occurrence_id') AS occ, count(*) AS n
        FROM events
        WHERE type='notify_probe_outcome'
          AND json_extract(payload,'$.result')='no_provenance'{clause}
        GROUP BY task_id, occ HAVING n >= ?
        """,
        params + [min_n],
    ).fetchall()
    occs = [{"task_id": r["task_id"], "occurrence_id": r["occ"], "n": r["n"]} for r in rows]
    return {"occurrences": occs, "total": len(occs)}


def compute_daily_conductor_pairs(conn: sqlite3.Connection, since: Optional[str],
                                   until: Optional[str]) -> list:
    """Plan §8 P1's reporting requirement and §8's stop-rule fallback
    derivation: daily `(conductor decisions, conductor p90)` pairs, grouped by
    decision date. Reuses `compute_conductor_latency`'s join (input_required
    seen_at -> conductor-authority decided_at) but per day instead of
    window-wide, which the stop rule's "p90 exceeded 45s on at least 3 days"
    condition requires."""
    clause, params = _since_until_clause("a.decided_at", since, until)
    rows = conn.execute(
        f"""
        WITH ir AS (
          SELECT json_extract(payload,'$.prompt_id') AS pid, occurred_at AS seen_at
          FROM events WHERE type='input_required'
        )
        SELECT date(a.decided_at) AS d, a.decided_at AS decided_at, ir.seen_at AS seen_at
        FROM approvals a JOIN ir ON ir.pid = a.prompt_id
        WHERE a.authority='conductor'{clause}
        """,
        params,
    ).fetchall()
    by_day: dict = {}
    for r in rows:
        delta = _parse_ts(r["decided_at"]) - _parse_ts(r["seen_at"])
        by_day.setdefault(r["d"], []).append(delta)
    out = []
    for d in sorted(by_day):
        deltas = sorted(by_day[d])
        out.append({"date": d, "decisions": len(deltas), "p90": percentile(deltas, 90)})
    return out


def compute_stop_rule_series(conn: sqlite3.Connection, since: Optional[str],
                              until: Optional[str]) -> dict:
    """Plan §8's stop-rule inputs, computed daily from registry rows only:

      - lambda (arrivals): count of conductor-authority `input_required`
        arrivals per day, grouped by the arrival (seen_at) date.
      - W (mean wait): mean seen_at->decided_at latency, seconds, for the
        same per-day group.
      - L (queue depth): **not computed.** The plan's own text defines L as
        "the number of undecided conductor-authority `input_required`
        prompts ... sampled at every hub tick" — a live point-in-time queue
        depth. The registry (this script's only input) holds the *resolved*
        row for each prompt (`input_required` plus, once decided, an
        `approvals` row); it has no periodic tick/sample event recording how
        many prompts were *simultaneously* undecided at a given instant. L
        could be reconstructed from the raw interval data (open intervals at
        time t = prompts whose input_required is before t and whose decision
        is after or absent), but that is a different, heavier computation
        than this script's per-row daily aggregation and is left undone
        rather than silently approximated; `L` is `None` here and the
        14-day stop-rule's L=lambda*W check cannot run on this series alone."""
    clause, params = _since_until_clause("ir.seen_at", since, until)
    rows = conn.execute(
        f"""
        WITH ir AS (
          SELECT json_extract(payload,'$.prompt_id') AS pid, occurred_at AS seen_at
          FROM events WHERE type='input_required'
        )
        SELECT date(ir.seen_at) AS d, ir.seen_at AS seen_at, a.decided_at AS decided_at
        FROM approvals a JOIN ir ON ir.pid = a.prompt_id
        WHERE a.authority='conductor'{clause}
        """,
        params,
    ).fetchall()
    by_day: dict = {}
    for r in rows:
        delta = _parse_ts(r["decided_at"]) - _parse_ts(r["seen_at"])
        by_day.setdefault(r["d"], []).append(delta)
    series = []
    for d in sorted(by_day):
        deltas = by_day[d]
        series.append({
            "date": d,
            "arrivals": len(deltas),
            "mean_wait_s": round(sum(deltas) / len(deltas), 4) if deltas else None,
        })
    return {
        "series": series,
        "L": None,
        "L_note": "queue depth L is not computed: it requires hub-tick live "
                  "sampling of simultaneously-undecided prompts, which has no "
                  "corresponding registry row (see docstring)",
    }


def resolve_main_pane(conn: sqlite3.Connection, main_pane_override: Optional[str]) -> Optional[str]:
    if main_pane_override:
        return main_pane_override
    try:
        row = conn.execute(
            "SELECT pane_id FROM roles WHERE role='main' LIMIT 1"
        ).fetchone()
    except sqlite3.OperationalError:
        return None
    return row["pane_id"] if row else None


def compute_main_drops_threads(conn: sqlite3.Connection, since: Optional[str],
                                until: Optional[str],
                                main_pane_override: Optional[str] = None) -> dict:
    """Plan §9.3: per day, count of `attention_form_served` events on tasks
    whose conductor is Main's pane, excluding forms whose escalation reason is
    human-reserved or unanswerable_overlay (those go to a form by design)."""
    main_pane = resolve_main_pane(conn, main_pane_override)
    if main_pane is None:
        return {
            "main_pane": None,
            "series": [],
            "note": "main pane unresolved: no `roles` row for role='main' and "
                    "no --main-pane override given; series is empty, not zero",
        }
    clause, params = _since_until_clause("e.occurred_at", since, until)
    placeholders = ",".join("?" for _ in EXCLUDED_DROP_REASONS)
    rows = conn.execute(
        f"""
        SELECT date(e.occurred_at) AS d, count(*) AS n
        FROM events e JOIN tasks t ON e.task_id = t.task_id
        WHERE e.type='attention_form_served'
          AND t.conductor_pane_id = ?
          AND COALESCE(json_extract(e.payload,'$.reason'), '') NOT IN ({placeholders})
          {clause}
        GROUP BY d ORDER BY d
        """,
        [main_pane, *EXCLUDED_DROP_REASONS] + params,
    ).fetchall()
    return {
        "main_pane": main_pane,
        "series": [{"date": r["d"], "n": r["n"]} for r in rows],
    }


def build_report(conn: sqlite3.Connection, since: Optional[str], until: Optional[str],
                  main_pane_override: Optional[str]) -> dict:
    return {
        "window": {"since": since, "until": until},
        "blocked_episodes": compute_blocked_episodes(conn, since, until),
        "top_escalations": compute_top_escalations(conn, since, until),
        "conductor_latency_s": compute_conductor_latency(conn, since, until),
        "write_binding_latency_s": compute_write_binding_latency(conn, since, until),
        "wake_outcomes": compute_wake_outcomes(conn, since, until),
        "decisions_per_day": compute_decisions_per_day(conn, since, until),
        "repeated_commands": compute_repeated_commands(conn, since, until),
        "duplicate_signals": compute_duplicate_signals(conn, since, until),
        "overlay_no_provenance": compute_overlay_no_provenance(conn, since, until),
        "daily_conductor_pairs": compute_daily_conductor_pairs(conn, since, until),
        "stop_rule_series": compute_stop_rule_series(conn, since, until),
        "main_drops_threads": compute_main_drops_threads(conn, since, until, main_pane_override),
    }


def format_text(report: dict) -> str:
    lines = []
    w = report["window"]
    lines.append(f"window: since={w['since'] or '-'} until={w['until'] or '-'}")

    be = report["blocked_episodes"]
    lines.append(
        f"blocked episodes: {be['episodes']} total_min={be['total_min']} "
        f"ge10={be['episodes_ge10']} ge10_min={be['min_ge10']} "
        f"ge10_episode_share={be['ge10_episode_share']} ge10_minute_share={be['ge10_minute_share']}"
    )

    esc = report["top_escalations"]
    lines.append(f"top escalations (of {esc['total']}):")
    for row in esc["top"]:
        lines.append(f"  {row['reason']}: {row['n']}")

    lat = report["conductor_latency_s"]
    lines.append(
        f"conductor latency s: n={lat['n']} p50={lat['p50']} p90={lat['p90']} p99={lat['p99']}"
    )
    lines.append(f"  method: {lat['method']}")

    wbl = report["write_binding_latency_s"]
    lines.append(
        f"write-binding latency s: n={wbl['n']} p50={wbl['p50']} p90={wbl['p90']} p99={wbl['p99']}"
    )

    wo = report["wake_outcomes"]
    lines.append(f"wake outcomes: {wo['counts']} total={wo['total']} "
                 f"unsubmitted_share={wo['unsubmitted_share']}")

    lines.append("decisions/day:")
    for row in report["decisions_per_day"]:
        lines.append(f"  {row['date']}: {row['n']}")

    rc = report["repeated_commands"]
    lines.append(f"repeated (task,command) pairs >=3: {rc['total_pairs']} (max n={rc['max_n']}):")
    for row in rc["pairs"]:
        lines.append(f"  {row['task_id']} / {row['command']}: {row['n']}")

    ds = report["duplicate_signals"]
    lines.append(f"duplicate input_required signals: {ds['total']}")
    for row in ds["duplicates"]:
        lines.append(f"  {row['date']} {row['prompt_id']}: {row['n']}")

    onp = report["overlay_no_provenance"]
    lines.append(f"no-provenance overlay occurrences (>=2): {onp['total']}")
    for row in onp["occurrences"]:
        lines.append(f"  {row['task_id']} {row['occurrence_id']}: {row['n']}")

    lines.append("daily conductor (decisions, p90) pairs:")
    for row in report["daily_conductor_pairs"]:
        lines.append(f"  {row['date']}: decisions={row['decisions']} p90={row['p90']}")

    srs = report["stop_rule_series"]
    lines.append(f"stop-rule series (L={srs['L']}, {srs['L_note']}):")
    for row in srs["series"]:
        lines.append(f"  {row['date']}: arrivals={row['arrivals']} mean_wait_s={row['mean_wait_s']}")

    mdt = report["main_drops_threads"]
    lines.append(f"main drops threads (main_pane={mdt['main_pane']}):")
    for row in mdt.get("series", []):
        lines.append(f"  {row['date']}: {row['n']}")
    if mdt.get("note"):
        lines.append(f"  note: {mdt['note']}")

    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", required=True, help="path to registry.sqlite3")
    ap.add_argument("--since", default=None, help="ISO8601 lower bound (inclusive)")
    ap.add_argument("--until", default=None, help="ISO8601 upper bound (inclusive)")
    ap.add_argument("--main-pane", default=None,
                     help="override Main's pane id (skips the `roles` table lookup)")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = ap.parse_args(argv)

    conn = connect_ro(args.db)
    try:
        report = build_report(conn, args.since, args.until, args.main_pane)
    finally:
        conn.close()

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(format_text(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
