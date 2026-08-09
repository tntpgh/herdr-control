#!/usr/bin/env python3
"""Read the KB nightly-resilience ledger through a read-only Neon session."""

from __future__ import annotations

import json
import os
import sys

import psycopg


def main() -> int:
    dsn = os.environ.get("NEON_CONNECTION_STRING", "")
    if not dsn:
        return 2

    # Match knowledge-base/scripts/kb_ledger_export.py: the server enforces
    # read-only transactions, and the search path is explicit. This script
    # contains exactly one statement, a bounded SELECT; error_message is not
    # selected because it may contain client data or credentials.
    with psycopg.connect(
        dsn,
        autocommit=True,
        connect_timeout=30,
        options="-c default_transaction_read_only=on -c search_path=kb,public",
    ) as conn:
        rows = conn.execute(
            """
            SELECT
                s.run_id::text,
                s.step_label,
                s.error_class,
                s.error_signature,
                s.started_at,
                r.started_at AS run_started_at
            FROM kb.nightly_steps AS s
            JOIN kb.nightly_runs AS r ON r.run_id = s.run_id
            WHERE s.status = 'failed'
              AND s.started_at >= now() - interval '24 hours'
            ORDER BY s.started_at DESC
            LIMIT 200
            """
        ).fetchall()

    out = [
        {
            "run_id": row[0],
            "step_label": row[1],
            "error_class": row[2],
            "error_signature": row[3],
            "started_at": row[4].isoformat() if row[4] else None,
            "run_started_at": row[5].isoformat() if row[5] else None,
        }
        for row in rows
    ]
    json.dump(out, sys.stdout, separators=(",", ":"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
