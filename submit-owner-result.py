#!/usr/bin/env python3
"""submit-owner-result.py -- item 9's narrow producer op, adjacent to
lib/result_availability.py (Availability.submit_owner_result).

Takes rid only. No caller-supplied flags, auth-ref or file paths: every
binding (owner identity, request digest, result pins) is DERIVED from the
rid's own already-registered ra_requests row, the journal's settled record,
and the result bytes on disk right now -- never from anything this CLI's
caller asserts.

CALLER IDENTITY: resolved from process ancestry via lib/pane-guard.sh's
caller_pane_from_ancestry -- the SAME resolver designate-main.sh and
conductor-handover.sh already use for this exact reason (security review PR
#252, F2): $HERDR_PANE_ID/$HERDR_TASK_ID are the caller's OWN environment, a
worker can export either to whatever it likes, and are NEVER trusted for
identity anywhere else in this repo. This CLI does not invent a new
convention; it reuses that one. The resolved pane, and the LIVE owner-lease
holder for the rid's registered label (lib/owner_lease.holder_tuple), must
both equal the rid's registered (pane_id, pane_birth, session_id,
generation) -- i.e. you can only submit a result while you ARE, right now,
the live project-owner pane that rid was dispatched to.

TRUST LIMIT: this proves the result bytes and the calling pane's own
resolved identity matched the rid's registered owner incarnation at submit
time (and accept-time re-checks this again, fresh). It is Herdr's
same-UID/command-approval boundary only -- it is NOT human approval, and NOT
cryptographic isolation from another process running as the same UID.

OFF BY DEFAULT: refuses unless HERDR_RESULT_AVAILABILITY=1 (same flag/stores
every other RA tool already requires) AND HERDR_OWNER_LEASE_DB is set (the
same lease store owner-dispatch.py/owner-lease-delivery already require) --
no new activation surface.

Exit: 0 submitted (prints `submitted:<receipt_id>`); 2 held (a binding did
not match, typed reason on stdout); 4 config refusal.
"""
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import owner_lease as ol  # noqa: E402
import result_availability as ra  # noqa: E402

PANE_GUARD = HERE / "lib" / "pane-guard.sh"


def caller_pane_from_ancestry() -> str | None:
    """Shells into lib/pane-guard.sh's caller_pane_from_ancestry: the first
    ancestor pid of THIS process that herdr itself reports as a pane's
    current foreground process. None if the walk found no herdr pane
    anywhere in this process's ancestry, or herdr itself is unreachable --
    either way, nothing safe to submit as."""
    try:
        out = subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(PANE_GUARD))} >/dev/null 2>&1 && caller_pane_from_ancestry"],
            capture_output=True, text=True, timeout=30)
    except Exception:  # noqa: BLE001 -- any failure to resolve identity is a refusal, never a crash
        return None
    if out.returncode != 0:
        return None
    pane = out.stdout.strip()
    return pane or None


SEND_TO_AGENT = HERE / "send-to-agent.sh"


def wake_main(rid: str, receipt_id: str, caller_pane: str) -> str:
    """Best-effort notification to Main -- the SAME existing mechanism
    attention-tick.sh's _attn_maybe_escalate (attention-tick.sh:213-253)
    already uses to wake a conductor: $HERDR_MAIN_PANE_ID as the target
    (attention-tick.sh:216), gated through lib/pane-guard.sh's
    pane_is_agent (lib/pane-guard.sh:41) before sending, delivered via
    send-to-agent.sh --not-an-answer (attention-tick.sh:253). No new wake
    channel. A failed or unconfigured wake never rolls back the receipt
    already durably written by submit_owner_result -- same discipline
    conductor-handover.sh:243-249 documents for its own best-effort notify.
    Returns a short status string for the caller to print; never raises."""
    main_pane = os.environ.get("HERDR_MAIN_PANE_ID", "")
    if not main_pane:
        return "wake:skipped:no_main_pane_configured"
    try:
        gate = subprocess.run(
            ["bash", "-c",
             f"source {shlex.quote(str(PANE_GUARD))} >/dev/null 2>&1 && pane_is_agent {shlex.quote(main_pane)}"],
            capture_output=True, text=True, timeout=30)
    except Exception:  # noqa: BLE001
        return "wake:skipped:pane_guard_unreachable"
    if gate.returncode != 0:
        return "wake:skipped:main_pane_not_a_safe_target"
    msg = (f"[HERDR-SUBMIT] rid={rid} receipt_id={receipt_id} submitted by pane {caller_pane}."
          f" Independent review needed: run accept-owner-result.py --receipt-id {receipt_id} with your OWN pins.")
    try:
        p = subprocess.run(["bash", str(SEND_TO_AGENT), main_pane, "--not-an-answer", msg],
                           capture_output=True, text=True, timeout=30)
    except Exception:  # noqa: BLE001
        return "wake:failed:transport_error"
    return "wake:sent" if p.returncode == 0 else f"wake:failed:rc{p.returncode}"


def main(argv=None, caller_pane_resolver=caller_pane_from_ancestry, waker=wake_main, environ=os.environ) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rid", required=True)
    a = ap.parse_args(argv)

    try:
        avail = ra.from_env(environ)
    except ra.Refused as exc:
        print(f"refused:{exc}")
        return 4
    if avail is None:
        print("refused:result_availability_off")
        return 4
    try:
        caller_pane = caller_pane_resolver()
        if not caller_pane:
            print("held:not_submitted:caller_identity_unresolved")
            return 2
        lease_db = environ.get("HERDR_OWNER_LEASE_DB")
        if not lease_db:
            print("refused:owner_lease_db_not_configured")
            return 4
        lc = ol.connect(lease_db)
        try:
            holder = lambda label: ol.holder_tuple(lc, label, time.time())  # noqa: E731
            try:
                receipt_id = avail.submit_owner_result(a.rid, caller_pane, holder)
            except ra.Refused as exc:
                print(f"held:not_submitted:conflicting_resubmit:{exc}")
                return 2
        finally:
            lc.close()
    finally:
        avail.close()
    if receipt_id is None:
        print("held:not_submitted:bindings_did_not_match")
        return 2
    wake_status = waker(a.rid, receipt_id, caller_pane)
    print(f"submitted:{receipt_id}:{wake_status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
