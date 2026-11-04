#!/usr/bin/env python3
"""owner-lease-resume-sweep.py [--apply] -- one read-only pass over every
REGISTERED label (owner_projects) that finds an EXPIRED-but-unreleased
lease and, for exactly the labels where owner-lease-resume.py's own
preconditions would accept (same holder still current in the registry),
invokes that EXISTING, unmodified, already-reviewed CLI to resume it.

THE GAP THIS CLOSES (docs/design/weekly-conductor-authorization.md (f)):
conductor-week-daily-tick.sh's unattended path only ever extends
owner_projects.lifecycle_end_at through owner-lease-recover.py -- a
DIFFERENT column than owner_leases.expires_at, the one factory-status.py's
lease_view() and queue-supervisor's own dispatch fence actually check. A
lane can have `recovered` lifecycle and `BLOCKED lease_expired` at the
same time; lifecycle recovery was never meant to touch the lease itself
(design doc line 7-9: "owner leases remain short and must still be
renewed or recovered through their normal state machine"). The "normal
state machine" for an ALREADY-LIVE lease is lib/owner_lease_renew.py's
renew_all_due(), wired into publisher.py's existing 15s tick behind
HERDR_OWNER_LEASE_RENEW=1 -- but renew_all_due() explicitly, by design
(R15/F1, a security-reviewed invariant), NEVER revives a lease that has
already expired ("claiming a first lease is owner-lease-claim.py's job,
not this pass's; this is also the outcome for an expired ... lease").
The authorized path for an EXPIRED-but-same-holder lease has always been
owner-lease-resume.py -- "pure continuity of an identity the system
already trusts... no approval form, no auth/grant row" -- but nothing has
ever called it except a human running it by hand. This script is that
missing, narrow, additive wiring: it never widens owner-lease-resume.py's
refusals (no_predecessor / wrong_prev_generation / live_predecessor /
different_holder / flags_off all still apply, enforced by that script at
write time, not re-implemented here), and never takes over a holder the
registry no longer agrees is current -- the exact same "different_holder"
refusal fires whether a human or this sweep triggers the attempt.

Candidate selection here is READ-ONLY and, for the holder-identity and
wrong_prev_generation checks, strictly looser than owner-lease-resume.py's
own preconditions (which also require the registry's CURRENT holder to
match and, as of the independent-review round below, the label's own
lifecycle bound and registration state), so every candidate this script
finds either resumes or is refused by the real CLI for a documented
reason -- never silently skipped without being named in the report.

INDEPENDENT REVIEW ROUND (pane w9T:p6R, against a35dca2) found the
original cut revived a lease past, or with no, lifecycle_end_at (HIGH
F1: a perpetual lease, defeating the weekly grant's own expiry) and
resumed an already-unregistered label through a non-atomic pre-read
(Low F4). Fixed at the authoritative write path, owner-lease-resume.py
itself -- not only here -- so the manual, human-run CLI path cannot
bypass either check either: a lease now refuses `no_lifecycle_bound` /
`lifecycle_ended` / `ttl_below_delivery_floor_after_lifecycle_clamp`,
its TTL is clamped to `min(--ttl, bound - now)`, and `unregistered_at`
is checked once at the precondition read and re-checked immediately
before the write to narrow (acquire()'s own internal transaction makes
fully closing it a lib/owner_lease.py change, out of this round's
scope) the TOCTOU window. This script mirrors both checks read-only, so
most doomed candidates are filtered before ever spawning the CLI -- this
IS now a second, read-only copy of part of the write-time check, kept
deliberately IN SYNC (same `olr._ts()` parser, same bound semantics) with
owner-lease-resume.py's authoritative enforcement, not a replacement for
it.

DRY-RUN BY DEFAULT: without --apply, prints the candidate list and the
plan: line each one's dry-run invocation of owner-lease-resume.py would
print, writing nothing. --apply re-invokes it for real.

Exit: always 0 -- a sweep that fails one label must still report every
other label and never abort the caller's tick (same contract
omp-reconcile.sh and the renew/result-availability ticks already use).
Per-label outcomes are in the printed report, not the process exit code.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))

import owner_lease as ol  # noqa: E402
import owner_lease_renew as olr  # noqa: E402 -- RENEW_TTL_S and the reviewed _ts() ISO parser

RESUME_CLI = HERE / "owner-lease-resume.py"


def due_candidates(conn, now: float) -> dict[str, int]:
    """label -> generation, for every registered label whose most recent
    lease row is unreleased and already expired. Read-only; never a
    second copy of owner-lease-resume.py's own write-time checks (holder
    identity, wrong_prev_generation races) -- just enough to avoid
    invoking the real CLI for a label with nothing to resume. The
    lifecycle-bound and unregistered checks below are the SAME defense
    the CLI now enforces at write time (F1/F4) -- filtering here is
    purely to skip a doomed subprocess call, never the authoritative
    check; a label that slips past this read-only filter (a race, or a
    bound that changes between this read and the CLI's own) is still
    refused by owner-lease-resume.py itself."""
    out: dict[str, int] = {}
    now_iso = ol._iso(now)  # noqa: SLF001 -- same-tree reuse, exact format the CLI itself compares against
    for label, end_iso, unregistered_at in conn.execute(
            "SELECT label, lifecycle_end_at, unregistered_at FROM owner_projects ORDER BY label"):
        if unregistered_at is not None:
            continue  # unregistered -- never this script's job
        if end_iso is None or now >= olr._ts(end_iso):  # noqa: SLF001 -- same reviewed parser renew_due uses
            continue  # no bound, or already past it -- never resume with no/expired authorization window
        row = conn.execute(
            "SELECT generation, expires_at, released_at FROM owner_leases "
            "WHERE label=? ORDER BY generation DESC LIMIT 1", (label,)).fetchone()
        if not row:
            continue  # no_predecessor -- never this script's job (owner-lease-claim.py's)
        gen, expires_at, released_at = row
        if released_at is not None:
            continue  # explicitly released, not merely stale -- not this script's job
        if expires_at > now_iso:
            continue  # still live -- renew_all_due's job, not this one
        out[label] = gen
    return out


def main(argv=None, now=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="without this, print the plan and write nothing")
    a = ap.parse_args(argv)
    now_s = time.time() if now is None else now

    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1" or os.environ.get("HERDR_OWNER_LEASE_DELIVERY") != "1":
        print("refused:flags_off")
        return 4
    db = os.environ.get("HERDR_OWNER_LEASE_DB", "")
    try:
        conn = ol.open_ro(db, require_table="owner_leases")  # read-only for the candidate scan either way
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4

    try:
        candidates = due_candidates(conn, now_s)
    finally:
        conn.close()

    if not candidates:
        print(json.dumps({}, sort_keys=True))
        return 0

    report: dict[str, str] = {}
    for label, gen in candidates.items():
        argv_cli = ["--label", label, "--ttl", str(olr.RENEW_TTL_S), "--expect-prev-generation", str(gen)]
        if a.apply:
            argv_cli.append("--apply")
        try:
            proc = subprocess.run([sys.executable, str(RESUME_CLI), *argv_cli],
                                   capture_output=True, text=True, timeout=30, env=os.environ.copy())
            report[label] = (proc.stdout or proc.stderr or f"exit:{proc.returncode}").strip()
        except subprocess.TimeoutExpired:
            # F5: one hung label must never abort the sweep or drop the report for every
            # label already resumed in this pass -- the sweep's own "Exit: always 0, every
            # other label still reported" contract from its own docstring, which a bare
            # TimeoutExpired propagating out of this loop would have broken.
            report[label] = "refused:timeout"

    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
