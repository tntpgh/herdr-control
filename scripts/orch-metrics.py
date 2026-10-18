#!/usr/bin/env python3
"""Read-only metrics over the herdr-control run registry (registry.sqlite3).

Computes the figures from ORCH-HIERARCHY-PLAN-v2.md Appendix A that P0 of the
orchestration-hierarchy plan needs, plus the Section 9.3 "Main drops threads"
daily series:

  - blocked episodes / total minutes / >=10-minute share       (Appendix A §a)
  - top approval_escalated reasons (top 5) + total              (Appendix A §b)
  - conductor-authority signal->answer latency p50/p90/p99,
    plus `unresolved` (arrived, never decided)                  (Appendix A §c, block 1)
  - occurrence lifecycle latencies, each occ_key-joined and each
    with an `unresolved` denominator that is never censored out:
      dispatch   prompt_occ_seen.dispatched_at_ms -> .at_ms
      decision   prompt_occ_seen.at_ms -> prompt_occ_authorized.at_ms
      completion prompt_occ_authorized.at_ms -> prompt_occ_completed.at_ms
                                                                  (Appendix A §c, block 2;
                                                                   plan P0 items 1 + 2)
  - every `decided_by` actor, full breakdown, no top-N truncation,
    totals reconciled against the sum                            (plan P0 item 4)
  - unsubmitted-wake share                                      (Appendix A §d, block 1)
  - conductor decisions per day                                 (Appendix A §d, block 2)
  - repeated (task_id, command) approval pairs, n>=3             (Appendix A §d, block 3)
  - duplicate input_required signals by (date, prompt_id)       (Appendix A §e)
  - no-provenance overlay occurrences, n>=2                     (Appendix A §f)
  - daily (conductor decisions, conductor p90) pairs             (plan §8 P1 target / stop rule)
  - stop-rule series: daily arrivals (lambda) and mean wait (W);
    queue depth L is explicitly NOT computed (see
    `compute_stop_rule_series`'s docstring)                      (plan §8 stop rule, §9.3)
  - "Main drops threads" daily series, reason-classified against
    the real emitting code (attention-tick.sh), not a guessed
    enum                                                         (plan §9.3; plan P0 item 4)
  - cost proxies where the schema has one (none for tokens/$;
    `prompts_per_task` as the available workload proxy)          (plan P0 item 5)
  - optional version-scoped windows: bucket the whole report by
    deployed app revision when `--deploys` is given              (plan P0 item 3)

The DB is opened strictly read-only via a `file:...?mode=ro` URI: any write
attempted through the connection this script opens raises
`sqlite3.OperationalError`. This script never opens, reads, or infers the
path to a real registry on its own; the caller supplies `--db` explicitly.
Likewise it never shells out to git to find deploy times -- `--deploys`
takes a file the caller builds from the deploy log (see `load_deploys`'s
docstring) so this script's only inputs stay `--db` and that one file.

Percentile method (stated per Appendix A's instruction to record one):
nearest-rank on the ascending-sorted sample, matching SQLite's `NTILE(100)`
windowing: for percentile p and n samples, index = ceil(p/100 * n), 1-based,
clamped to [1, n]. n=0 -> None for every percentile. n=1 -> every percentile
returns the single value.

Schema expected (names drawn from Appendix A's "schema the reviewer
confirmed" plus the `roles` primitive described in plan §1.3/§2, verified
against lib/run-registry.sh's actual CREATE TABLE statements):
  events(sequence, event_id, run_id, task_id, type, occurred_at, payload)
  approvals(approval_id, run_id, task_id, pane_id, prompt_id, choice,
            decided_by, authority, policy_verdict, command, decided_at,
            attempted_at, outcome)
  tasks(task_id, state, project, updated_at, conductor_pane_id, ...)
  roles(label, pane_id, ...)                     -- optional; see --main-pane

`payload` is a JSON text column; fields are pulled with SQLite's
`json_extract`.

Verified schema notes (P0 item 1/4 -- read from the emitting code, not
assumed from the plan's Appendix A, which the plan itself marks UNRUN):

- `prompt_occ_seen` / `prompt_occ_authorized` / `prompt_occ_completed` /
  `prompt_occ_declined` / `prompt_occ_withdrawn` (lib/prompt-occurrence.py)
  key every row by `$.occ_key` (a hash of run_id/task_id/pane_id/pane_birth/
  native_session/tool_call_id), NEVER `$.prompt_id` -- the module's own
  docstring: "never prompt_id -- a repaint changes prompt_id without being a
  new question." `input_required`/`approvals` are a different identity
  scheme and DO use `$.prompt_id`/`prompt_id`; that join is correct as-is.
- `prompt_occ_seen` carries two independent timestamps: `dispatched_at_ms`
  (optional, caller-supplied, often absent) and `at_ms` (always present,
  when the hook itself first recorded the occurrence). `prompt_occ_authorized`
  and the resolution events each carry their own `at_ms`. These four
  timestamps are exactly the lifecycle verify-approval-payload.sh's synthetic
  check proves in production, under the names `dispatched`, `proposal_created`,
  `approval_resolved`, `exec_end_result` -- the stage labels below reuse that
  vocabulary rather than inventing new ones (e.g. never "resume", a word the
  emitting code does not use for any of these transitions).
- `roles` (schema v10, lib/run-registry.sh `_migrate_schema_v10`) is the
  CANONICAL table for Main's designation; its primary key column is `label`,
  not `role`. It was split out from the older, still-live `owners` table
  specifically so Main's row would be invisible to every generic `owners`
  reader (security review PR #252 finding F1) -- `owners` must never be
  read for this purpose, and this script now only ever reads `roles`.
- `attention_form_served` payloads carry a free-text `reason` (attention-
  tick.sh `_attn_maybe_form`'s only two call sites), not the two-value enum
  the plan's prose implies; see `_classify_drop_reason`'s docstring for the
  verified prefixes and why a literal "unanswerable_overlay" string never
  matches anything.
"""
from __future__ import annotations

import argparse
import json
import math
import sqlite3
import sys
from datetime import datetime, timezone
from typing import Optional


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


PERCENTILE_METHOD = ("nearest-rank on ascending-sorted deltas, "
                      "index=ceil(p/100*n) 1-based (NTILE(100)-equivalent)")


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
    seconds, p50/p90/p99, for prompts that WERE decided by a conductor.

    `unresolved` additionally counts `input_required` arrivals in the same
    window (by their own `occurred_at`, since an undecided prompt has no
    `decided_at` to window on) with NO matching `approvals` row of ANY
    authority -- plan P0 item 2: a prompt nobody ever decided is exactly the
    backlog/loss this figure exists to surface, and silently excluding it
    from the denominator would hide that. `n`/the percentiles keep the
    original decided_at-windowed basis; `unresolved` is a second, honestly
    different-basis count, not folded into the same total."""
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

    ir_clause, ir_params = _since_until_clause("ir.occurred_at", since, until)
    unresolved = conn.execute(
        f"""
        SELECT count(*) AS n FROM events ir
        WHERE ir.type='input_required'{ir_clause}
          AND NOT EXISTS (
            SELECT 1 FROM approvals a WHERE a.prompt_id = json_extract(ir.payload,'$.prompt_id')
          )
        """,
        ir_params,
    ).fetchone()["n"]
    return {
        "n": len(deltas),
        "unresolved": unresolved,
        "p50": percentile(deltas, 50),
        "p90": percentile(deltas, 90),
        "p99": percentile(deltas, 99),
        "method": PERCENTILE_METHOD,
    }


def compute_dispatch_latency(conn: sqlite3.Connection, since: Optional[str],
                              until: Optional[str], tool: Optional[str] = None) -> dict:
    """Lifecycle stage 1 ("dispatched" -> "proposal_created" in verify-
    approval-payload.sh's synthetic timeline): `prompt_occ_seen.dispatched_at_ms`
    -> `prompt_occ_seen.at_ms`, both in the same payload (lib/prompt-
    occurrence.py `record_seen`), so this is a single-table read, not a join.
    `dispatched_at_ms` is optional and caller-supplied; a seen row that never
    recorded one is excluded from `n` entirely (not counted as a 0 or as
    unresolved -- the information was simply never captured for that row).
    `tool=None` (default) covers every tool; pass e.g. `tool="write"` to
    match a single one."""
    tool_clause = ""
    tool_params: list = []
    if tool is not None:
        tool_clause = " AND json_extract(payload,'$.tool')=?"
        tool_params = [tool]
    clause, since_params = _since_until_clause("occurred_at", since, until)
    rows = conn.execute(
        f"""
        SELECT json_extract(payload,'$.dispatched_at_ms') AS d_ms,
               json_extract(payload,'$.at_ms') AS a_ms
        FROM events
        WHERE type='prompt_occ_seen'{tool_clause}{clause}
        """,
        tool_params + since_params,
    ).fetchall()
    deltas = sorted(
        (r["a_ms"] - r["d_ms"]) / 1000.0 for r in rows
        if r["d_ms"] is not None and r["a_ms"] is not None
    )
    return {
        "tool": tool, "n": len(deltas),
        "p50": percentile(deltas, 50), "p90": percentile(deltas, 90), "p99": percentile(deltas, 99),
        "method": PERCENTILE_METHOD,
    }


def compute_decision_latency(conn: sqlite3.Connection, since: Optional[str],
                              until: Optional[str], tool: str = "write") -> dict:
    """Lifecycle stage 2 ("proposal_created" -> "approval_resolved"):
    `prompt_occ_seen` -> `prompt_occ_authorized`, joined on `occ_key` -- the
    identity these two event types actually carry (lib/prompt-occurrence.py:
    occ_key is a hash of run_id/task_id/pane_id/pane_birth/native_session/
    tool_call_id; `$.prompt_id` does not exist on either payload). The prior
    version of this function (then named `compute_write_binding_latency`)
    joined on `json_extract(payload,'$.prompt_id')`, which both payloads
    never write -- the join matched zero rows against a real registry, so
    the figure silently reported `n=0` in production instead of raising.
    Fixed here; `tool` defaults to "write" to keep the plan's "omp binding
    seen -> authorized, write" figure (§1.1) directly reproducible.

    `unresolved` counts `prompt_occ_seen` occurrences (tool-filtered,
    windowed by their own `occurred_at`) with NO matching `prompt_occ_authorized`
    at all -- never authorized, never silently dropped from the denominator
    (plan P0 item 2)."""
    clause, params = _since_until_clause("auth.auth_at", since, until)
    rows = conn.execute(
        f"""
        WITH seen AS (
          SELECT json_extract(payload,'$.occ_key') AS key, occurred_at AS seen_at
          FROM events WHERE type='prompt_occ_seen' AND json_extract(payload,'$.tool')=?
        ),
        auth AS (
          SELECT json_extract(payload,'$.occ_key') AS key, occurred_at AS auth_at
          FROM events WHERE type='prompt_occ_authorized'
        )
        SELECT auth.auth_at AS auth_at, seen.seen_at AS seen_at
        FROM seen JOIN auth ON seen.key = auth.key
        WHERE 1=1{clause}
        """,
        [tool] + params,
    ).fetchall()
    deltas = sorted(_parse_ts(r["auth_at"]) - _parse_ts(r["seen_at"]) for r in rows)

    seen_clause, seen_params = _since_until_clause("occurred_at", since, until)
    unresolved = conn.execute(
        f"""
        SELECT count(*) AS n FROM events seen
        WHERE seen.type='prompt_occ_seen' AND json_extract(seen.payload,'$.tool')=?{seen_clause}
          AND NOT EXISTS (
            SELECT 1 FROM events auth WHERE auth.type='prompt_occ_authorized'
              AND json_extract(auth.payload,'$.occ_key') = json_extract(seen.payload,'$.occ_key')
          )
        """,
        [tool] + seen_params,
    ).fetchone()["n"]
    return {
        "tool": tool, "n": len(deltas), "unresolved": unresolved,
        "p50": percentile(deltas, 50), "p90": percentile(deltas, 90), "p99": percentile(deltas, 99),
        "method": PERCENTILE_METHOD,
    }


def compute_completion_latency(conn: sqlite3.Connection, since: Optional[str],
                                until: Optional[str]) -> dict:
    """Lifecycle stage 3 ("approval_resolved" -> "exec_end_result"):
    `prompt_occ_authorized` -> `prompt_occ_completed`, occ_key-joined (same
    identity as `compute_decision_latency`).

    `unresolved` counts authorized occurrences in-window with NO resolution
    event at all -- not `prompt_occ_completed`, not `_declined`, not
    `_withdrawn`. A declined/withdrawn occurrence is a REAL resolution
    (plan: "approval is never completion") and is correctly excluded from
    `unresolved`; only a genuinely lost-mid-execution occurrence counts,
    never silently excluded (plan P0 item 2)."""
    clause, params = _since_until_clause("auth.auth_at", since, until)
    rows = conn.execute(
        f"""
        WITH auth AS (
          SELECT json_extract(payload,'$.occ_key') AS key, occurred_at AS auth_at
          FROM events WHERE type='prompt_occ_authorized'
        ),
        comp AS (
          SELECT json_extract(payload,'$.occ_key') AS key, occurred_at AS comp_at
          FROM events WHERE type='prompt_occ_completed'
        )
        SELECT auth.auth_at AS auth_at, comp.comp_at AS comp_at
        FROM auth JOIN comp ON auth.key = comp.key
        WHERE 1=1{clause}
        """,
        params,
    ).fetchall()
    deltas = sorted(_parse_ts(r["comp_at"]) - _parse_ts(r["auth_at"]) for r in rows)

    a_clause, a_params = _since_until_clause("occurred_at", since, until)
    unresolved = conn.execute(
        f"""
        SELECT count(*) AS n FROM events auth
        WHERE auth.type='prompt_occ_authorized'{a_clause}
          AND NOT EXISTS (
            SELECT 1 FROM events r
            WHERE r.type IN ('prompt_occ_completed','prompt_occ_declined','prompt_occ_withdrawn')
              AND json_extract(r.payload,'$.occ_key') = json_extract(auth.payload,'$.occ_key')
          )
        """,
        a_params,
    ).fetchone()["n"]
    return {
        "n": len(deltas), "unresolved": unresolved,
        "p50": percentile(deltas, 50), "p90": percentile(deltas, 90), "p99": percentile(deltas, 99),
        "method": PERCENTILE_METHOD,
    }


def compute_decided_by_actors(conn: sqlite3.Connection, since: Optional[str],
                               until: Optional[str]) -> dict:
    """Every distinct `decided_by` actor, full breakdown, no LIMIT (plan P0
    item 4). The live registry has dozens of single-occurrence values --
    individual hub-form ids, raw pane ids, `sentinel` -- alongside the
    high-volume ones (`cli`, `conductor:<pane>`, `peer-answer`); a top-N
    truncation (as `compute_top_escalations` uses, deliberately, for a
    different figure) would silently drop most of that tail. `total`
    reconciles exactly against `sum(a['n'] for a in actors)` -- same query,
    two projections of the same rows, nothing computed from a second pass
    that could drift out of sync."""
    clause, params = _since_until_clause("decided_at", since, until)
    rows = conn.execute(
        f"""
        SELECT decided_by, count(*) AS n
        FROM approvals WHERE 1=1{clause}
        GROUP BY decided_by ORDER BY n DESC
        """,
        params,
    ).fetchall()
    actors = [{"decided_by": r["decided_by"], "n": r["n"]} for r in rows]
    return {"actors": actors, "total": sum(a["n"] for a in actors)}


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
    """`roles` (schema v10) is the CANONICAL table for Main's designation --
    deliberately split out from the older, still-live `owners` table so
    Main's row is invisible to every generic `owners` reader (security
    review PR #252 finding F1, lib/run-registry.sh `_migrate_schema_v10`'s
    comment). Its primary-key column is `label`, not `role` -- the prior
    version of this query (`WHERE role='main'`) named a column that does not
    exist, which `sqlite3.OperationalError`s, is caught below, and silently
    resolves to "unresolved" every time: in production this made `--main-pane`
    the ONLY way `compute_main_drops_threads` ever worked, with no visible
    error explaining why the plain run always returned an empty series."""
    if main_pane_override:
        return main_pane_override
    try:
        row = conn.execute(
            "SELECT pane_id FROM roles WHERE label='main' LIMIT 1"
        ).fetchone()
    except sqlite3.OperationalError:
        return None
    return row["pane_id"] if row else None


def _classify_drop_reason(reason: Optional[str]) -> str:
    """attention-tick.sh's sole emitter of `attention_form_served`
    (`_attn_maybe_form`, exactly two call sites) writes a free-text prose
    `reason`, never an enum -- verified both against the source and against
    every `reason` value actually present in the live registry snapshot:

      - reserved/deny class (attention-tick.sh, the `[ -n "$reserved" ] ||
        [ "$verdict" = "deny" ]` branch): "Only a human can approve this
        (...)". Excluded by design, matching plan §9.3's "human_reserved":
        only a human may approve it, and its conductor may still deny/
        redirect it before the form is ever answered.
      - escalation-ladder timeout (the other branch): "No response Ns after
        its conductor was alerted; ...". This is the ONLY other shape the
        emitting code produces.

    The plan's second exclusion category, "unanswerable_overlay" (a panel-
    less overlay only a human can clear), names a SCENARIO, not a distinct
    reason string -- the emitting code records nothing that tells the two
    "No response" cases apart. Matching a literal "unanswerable_overlay"
    string (the prior version of this script) therefore matched zero rows,
    ever, against a real registry -- the exclusion silently never fired.

    A reason that is empty or matches neither known prefix classifies as
    `unverified`: reported as its own bucket and counted as a drop (plan P0
    item 2 -- excluding on an unproven guess would censor a real drop), never
    silently folded into `no_response` or discarded."""
    if not reason:
        return "unverified"
    if reason.startswith("Only a human can approve this"):
        return "human_reserved"
    if reason.startswith("No response "):
        return "no_response"
    return "unverified"


def compute_main_drops_threads(conn: sqlite3.Connection, since: Optional[str],
                                until: Optional[str],
                                main_pane_override: Optional[str] = None) -> dict:
    """Plan §9.3: per day, `attention_form_served` events on tasks whose
    conductor is Main's pane, classified by `_classify_drop_reason`.
    `human_reserved` is excluded from `drops` by design; `no_response` and
    `unverified` are both counted as drops and reported as separate
    breakdown entries rather than silently merged, so a reason string that
    drifts from the two known prefixes stays visible. `served` = `drops` +
    `excluded_human_reserved` always reconciles against the raw row count
    for that day (every served form lands in exactly one bucket)."""
    main_pane = resolve_main_pane(conn, main_pane_override)
    if main_pane is None:
        return {
            "main_pane": None,
            "series": [],
            "note": "main pane unresolved: no `roles` row for label='main' and "
                    "no --main-pane override given; series is empty, not zero",
        }
    clause, params = _since_until_clause("e.occurred_at", since, until)
    rows = conn.execute(
        f"""
        SELECT date(e.occurred_at) AS d, json_extract(e.payload,'$.reason') AS reason
        FROM events e JOIN tasks t ON e.task_id = t.task_id
        WHERE e.type='attention_form_served'
          AND t.conductor_pane_id = ?
          {clause}
        """,
        [main_pane] + params,
    ).fetchall()
    by_day: dict = {}
    for r in rows:
        bucket = by_day.setdefault(r["d"], {"human_reserved": 0, "no_response": 0, "unverified": 0})
        bucket[_classify_drop_reason(r["reason"])] += 1
    series = []
    for d in sorted(by_day):
        b = by_day[d]
        drops = b["no_response"] + b["unverified"]
        series.append({
            "date": d,
            "drops": drops,
            "no_response": b["no_response"],
            "unverified": b["unverified"],
            "excluded_human_reserved": b["human_reserved"],
            "served": drops + b["human_reserved"],
        })
    return {"main_pane": main_pane, "series": series}


def compute_cost_proxies(conn: sqlite3.Connection, since: Optional[str],
                          until: Optional[str]) -> dict:
    """Plan P0 item 5: report a cost proxy where the schema has one,
    otherwise say plainly that none exists rather than fabricating a figure.
    Checked against the real schema (lib/run-registry.sh's `tasks`/`events`/
    `approvals`/`roles`/`owners` CREATE TABLE statements): no column
    anywhere stores a token count or a dollar cost, so `tokens` is always
    `None` here, with a note instead of a silently-omitted key.

    The one proxy the registry does support is approval volume per task --
    `prompts_per_task`, the count of decided `approvals` rows grouped by
    `task_id` in-window. This is a workload stand-in (more approvals asked
    of a task roughly tracks more tool calls made), explicitly NOT a token
    or dollar figure."""
    clause, params = _since_until_clause("decided_at", since, until)
    rows = conn.execute(
        f"""
        SELECT task_id, count(*) AS n FROM approvals WHERE 1=1{clause}
        GROUP BY task_id ORDER BY n DESC
        """,
        params,
    ).fetchall()
    per_task = [{"task_id": r["task_id"], "n": r["n"]} for r in rows]
    avg = round(sum(p["n"] for p in per_task) / len(per_task), 2) if per_task else None
    return {
        "tokens": None,
        "tokens_note": "no token or dollar-cost column exists in the registry schema "
                       "(tasks/events/approvals/roles/owners) -- not computed, not estimated",
        "prompts_per_task": per_task,
        "prompts_per_task_avg": avg,
    }


def load_deploys(path: str) -> list:
    """Caller-supplied JSON file: a list of `{"revision": str, "deployed_at":
    ISO8601}` objects, sorted ascending by `deployed_at` on load. This
    script stays a pure reader of `--db` plus (optionally) this one file; it
    never shells out to git or infers a deploy-log path itself, the same
    discipline as never guessing the registry path.

    Build the file from the real deploy log -- this repo's deploy log IS
    config.sh's git history (every `release: pin vNN bound launcher` commit
    repoints `HERDR_OMP_BIN` to a new `releases/<label>/` path; the commit's
    author date is the deploy time, `<label>` is the revision):

      git log --format='%aI %H' -- config.sh

    then pair each commit with the `releases/<label>/` component of
    `HERDR_OMP_BIN` as checked out at that commit, oldest first."""
    with open(path, "r", encoding="utf-8") as f:
        deploys = json.load(f)
    return sorted(deploys, key=lambda d: d["deployed_at"])


def deploy_windows(deploys: list, since: Optional[str], until: Optional[str]) -> list:
    """Split `[since, until]` into consecutive `(revision, win_since,
    win_until)` windows at every deploy boundary that falls inside it.
    `since`/`until` of `None` bind to the deploy list's own first/last
    `deployed_at` -- an unbounded window can't otherwise be split into
    finitely many pieces. A window's revision is the most recent deploy at
    or before its start; a span before the earliest deploy in `deploys` is
    labelled `pre-<first revision>` rather than silently attributed to it."""
    if not deploys:
        return [(None, since, until)]
    lo = since or deploys[0]["deployed_at"]
    hi = until or deploys[-1]["deployed_at"]
    edges = sorted({lo, hi} | {d["deployed_at"] for d in deploys if lo <= d["deployed_at"] <= hi})

    def revision_at(ts: str) -> str:
        active = None
        for d in deploys:
            if d["deployed_at"] <= ts:
                active = d["revision"]
        return active if active is not None else f"pre-{deploys[0]['revision']}"

    windows = []
    for i in range(len(edges) - 1):
        w_since, w_until = edges[i], edges[i + 1]
        if w_since == w_until:
            continue
        windows.append((revision_at(w_since), w_since, w_until))
    if not windows:
        windows = [(revision_at(lo), lo, hi)]
    return windows


def build_report(conn: sqlite3.Connection, since: Optional[str], until: Optional[str],
                  main_pane_override: Optional[str], revision: Optional[str] = None) -> dict:
    return {
        "window": {"since": since, "until": until},
        "revision": revision,
        "blocked_episodes": compute_blocked_episodes(conn, since, until),
        "top_escalations": compute_top_escalations(conn, since, until),
        "conductor_latency_s": compute_conductor_latency(conn, since, until),
        "dispatch_latency_s": compute_dispatch_latency(conn, since, until, tool="write"),
        "decision_latency_s": compute_decision_latency(conn, since, until, tool="write"),
        "completion_latency_s": compute_completion_latency(conn, since, until),
        "decided_by_actors": compute_decided_by_actors(conn, since, until),
        "wake_outcomes": compute_wake_outcomes(conn, since, until),
        "decisions_per_day": compute_decisions_per_day(conn, since, until),
        "repeated_commands": compute_repeated_commands(conn, since, until),
        "duplicate_signals": compute_duplicate_signals(conn, since, until),
        "overlay_no_provenance": compute_overlay_no_provenance(conn, since, until),
        "daily_conductor_pairs": compute_daily_conductor_pairs(conn, since, until),
        "stop_rule_series": compute_stop_rule_series(conn, since, until),
        "main_drops_threads": compute_main_drops_threads(conn, since, until, main_pane_override),
        "cost_proxies": compute_cost_proxies(conn, since, until),
    }


def format_text(report: dict) -> str:
    lines = []
    w = report["window"]
    lines.append(f"window: since={w['since'] or '-'} until={w['until'] or '-'} "
                 f"revision={report.get('revision') or '-'}")

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
        f"conductor latency s: n={lat['n']} unresolved={lat['unresolved']} "
        f"p50={lat['p50']} p90={lat['p90']} p99={lat['p99']}"
    )

    disp = report["dispatch_latency_s"]
    lines.append(f"dispatch latency s (tool={disp['tool']}): n={disp['n']} "
                 f"p50={disp['p50']} p90={disp['p90']} p99={disp['p99']}")

    dec = report["decision_latency_s"]
    lines.append(f"decision latency s (tool={dec['tool']}): n={dec['n']} "
                 f"unresolved={dec['unresolved']} p50={dec['p50']} p90={dec['p90']} p99={dec['p99']}")

    comp = report["completion_latency_s"]
    lines.append(f"completion latency s: n={comp['n']} unresolved={comp['unresolved']} "
                 f"p50={comp['p50']} p90={comp['p90']} p99={comp['p99']}")

    dba = report["decided_by_actors"]
    lines.append(f"decided_by actors (total={dba['total']}):")
    for row in dba["actors"]:
        lines.append(f"  {row['decided_by']}: {row['n']}")

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
        lines.append(f"  {row['date']}: drops={row['drops']} (no_response={row['no_response']} "
                     f"unverified={row['unverified']}) excluded_human_reserved="
                     f"{row['excluded_human_reserved']} served={row['served']}")
    if mdt.get("note"):
        lines.append(f"  note: {mdt['note']}")

    cp = report["cost_proxies"]
    lines.append(f"cost proxies: tokens={cp['tokens']} ({cp['tokens_note']})")
    lines.append(f"  prompts_per_task_avg={cp['prompts_per_task_avg']} "
                 f"({len(cp['prompts_per_task'])} tasks)")

    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", required=True, help="path to registry.sqlite3")
    ap.add_argument("--since", default=None, help="ISO8601 lower bound (inclusive)")
    ap.add_argument("--until", default=None, help="ISO8601 upper bound (inclusive)")
    ap.add_argument("--main-pane", default=None,
                     help="override Main's pane id (skips the `roles` table lookup)")
    ap.add_argument("--deploys", default=None,
                     help="path to a JSON deploy list (see load_deploys docstring); "
                          "when given, the report is split into one per deployed revision")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = ap.parse_args(argv)

    conn = connect_ro(args.db)
    try:
        if args.deploys:
            deploys = load_deploys(args.deploys)
            windows = deploy_windows(deploys, args.since, args.until)
            reports = [build_report(conn, w_since, w_until, args.main_pane, revision=rev)
                       for rev, w_since, w_until in windows]
        else:
            reports = [build_report(conn, args.since, args.until, args.main_pane)]
    finally:
        conn.close()

    if args.json:
        print(json.dumps(reports if args.deploys else reports[0], indent=2, sort_keys=True))
    else:
        print("\n\n".join(format_text(r) for r in reports))
    return 0


if __name__ == "__main__":
    sys.exit(main())
