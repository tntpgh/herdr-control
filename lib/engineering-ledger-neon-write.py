#!/usr/bin/env python3
"""Insert Stage-1 engineering-ledger records into kb.engineering_activity.

Companion to engineering-ledger-kb.py's read-only export: this one connects
without `default_transaction_read_only=on` because writing is the point.
Reads a JSON array of rows (run_id, task_id, repo, event_type, summary,
payload, observed_at) from stdin and inserts them in one transaction. The
table is expected to already exist (kb-engineering-activity-schema migration,
knowledge-base repo) — a missing table surfaces as a normal connection/query
failure, which the caller treats as "Neon unavailable this cycle".
"""

from __future__ import annotations

import json
import os
import sys

import psycopg


def main() -> int:
    dsn = os.environ.get("NEON_CONNECTION_STRING", "")
    if not dsn:
        return 2

    try:
        rows = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 2
    if not isinstance(rows, list) or not rows:
        return 2

    values = [
        (
            row.get("run_id"),
            row.get("task_id"),
            row.get("repo"),
            row.get("event_type"),
            row.get("summary"),
            json.dumps(row.get("payload")) if row.get("payload") is not None else None,
            row.get("observed_at"),
        )
        for row in rows
    ]

    with psycopg.connect(
        dsn,
        autocommit=True,
        connect_timeout=30,
        options="-c search_path=kb,public",
    ) as conn:
        conn.cursor().executemany(
            """
            INSERT INTO kb.engineering_activity
                (run_id, task_id, repo, event_type, summary, payload, observed_at)
            VALUES (%s, %s, %s, %s, %s, %s::jsonb, %s)
            """,
            values,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
