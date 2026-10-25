#!/usr/bin/env python3
"""accept-owner-result.py -- item 9's receipt-based consumer, adjacent to
lib/result_availability.py (Availability.accept_receipt).

Input is --receipt-id plus the INDEPENDENT reviewer's own --pin values only
-- no rid, no auth-ref, no caller-supplied owner/incarnation fields. The rid
and every binding are looked up FROM the receipt
(submit-owner-result.py/Availability.submit_owner_result wrote it) and
re-verified FRESH right now: the receipt row's own digest, the rid's
registered row, the journal's settled record, the owner's CURRENT live
incarnation (lib/owner_lease.holder_tuple), and the receipt's own pins
against the CURRENT result bytes -- before the reviewer's --pin values are
separately required to ALSO match those same current bytes. Any mismatch at
any step refuses; nothing here is a fallback for another.

TRUST: Herdr's same-UID/command-approval boundary only (the submit side's
own trust limit; see submit-owner-result.py). Not human approval, and not
cryptographic isolation from an arbitrary same-UID writer.

OFF BY DEFAULT: refuses unless HERDR_RESULT_AVAILABILITY=1 AND
HERDR_OWNER_LEASE_DB are set -- the same flags/stores every other RA/lease
tool already requires; no new activation surface.

Exit: 0 accepted; 2 held (typed reason on stdout); 4 config refusal.

main()'s optional `post_accept` parameter is a TEST SEAM ONLY (default
no-op in production): it runs after accept_receipt's durable write and
before the caller observes success, so an offline test can inject a
simulated crash in that exact window without touching production code.
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import owner_lease as ol  # noqa: E402
import result_availability as ra  # noqa: E402


def main(argv=None, post_accept=lambda: None, environ=os.environ) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--receipt-id", required=True)
    ap.add_argument("--by", required=True, help="the independent reviewer's own identity")
    ap.add_argument("--pin", action="append", required=True, metavar="NAME=SHA256",
                    help="the reviewer's OWN manifest pin, repeated once per manifest entry;"
                         " verified independently of the receipt's own pins")
    a = ap.parse_args(argv)

    pins: dict[str, str] = {}
    for item in a.pin:
        name, sep, sha = item.partition("=")
        if not sep or not name or not sha:
            print(f"refused:bad_pin:{item!r}")
            return 4
        if name in pins:
            print(f"refused:duplicate_pin:{name!r}")
            return 4
        pins[name] = sha

    try:
        avail = ra.from_env(environ)
    except ra.Refused as exc:
        print(f"refused:{exc}")
        return 4
    if avail is None:
        print("refused:result_availability_off")
        return 4
    try:
        lease_db = environ.get("HERDR_OWNER_LEASE_DB")
        if not lease_db:
            print("refused:owner_lease_db_not_configured")
            return 4
        lc = ol.connect(lease_db)
        try:
            holder = lambda label: ol.holder_tuple(lc, label, time.time())  # noqa: E731
            try:
                ok = avail.accept_receipt(a.receipt_id, pins, holder, a.by)
            except ra.Refused as exc:
                print(f"held:not_accepted:conflicting_stage:{exc}")
                return 2
        finally:
            lc.close()
    finally:
        avail.close()
    if not ok:
        print("held:not_accepted:bindings_did_not_match")
        return 2
    post_accept()  # test seam only: production default is a no-op, called AFTER accept_receipt's durable write,
                   # BEFORE the caller observes success -- lets a test simulate a crash in exactly that window
    print("accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
