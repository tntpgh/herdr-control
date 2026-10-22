#!/usr/bin/env python3
"""owner-dispatch-issue.py --approval FILE --approval-sha256 HEX --request-dir D
One-shot writer for ONE approved owner-dispatch pilot (OFF BY DEFAULT, INERT).

It consumes exactly one approval record (protocol owner-dispatch-approval/1),
which is the decided form answer, frozen to bytes whose sha256 the operator
passes on the command line. One record authorizes, conditionally:
  - the EXPECTED initial lease claim (generation 1) for the named owner, and
  - issuing exactly ONE grant bound to the frozen request.
Every field is checked against live state, and any mismatch aborts:
  - the request bytes must hash to request_sha256;
  - the registry identity must equal expected_holder, both BEFORE the claim
    and again before issuing;
  - the owner_projects mapping must equal the approved project;
  - the claim must be an initial gen-1 claim (no invented or existing lease);
  - the lease holder after the claim must equal expected_holder plus gen 1;
  - grant_expires_at must be no more than 60 min after decided_at and still in
    the future;
  - auth_id and approval_id must never have been used before.
The grant row is written by fixed code with fixed columns; there is no
free-form SQL path. This tool has no retry, renewal, reassignment, takeover or
second grant. The dispatch itself is owner-dispatch.py, which re-resolves the
identity a third time.

The lease DB and the auth store are separate files, so claim+issue are not one
transaction. If the issue step aborts after a successful claim, the lease is
held with no grant: dispatch holds auth_missing and the lease expires on its
TTL. That is reported as `claimed_not_issued`, never retried.

Flags: HERDR_OWNER_DISPATCH_ISSUE=1, HERDR_OWNER_LEASE_WRITER=1,
HERDR_OWNER_LEASE_DELIVERY=1; stores: HERDR_OWNER_LEASE_DB,
HERDR_OWNER_DISPATCH_AUTH_DB (existing, private, never created here).
Exit: 0 issued; 2 refused (typed, nothing written); 5 claimed_not_issued; 4 config.
"""
from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import os
import re
import stat
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))

import owner_dispatch_auth as oda  # noqa: E402
import owner_lease as ol  # noqa: E402
import private_sqlite  # noqa: E402

PROTOCOL = "owner-dispatch-approval/1"
MAX_APPROVAL_BYTES = 8192
MAX_WINDOW_S = 3600
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ISO_Z = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
KEYS = {"protocol", "approval_id", "prompt_id", "decided_at", "owner_label", "project", "expected_holder",
        "expected_generation", "lease_ttl_s", "request_id", "request_name", "request_sha256", "manifest",
        "auth_id", "grant_expires_at"}
HOLDER_KEYS = {"pane_id", "pane_birth", "session_digest"}


class Refused(Exception):
    pass


def _epoch(s: str) -> float:
    if not isinstance(s, str) or not ISO_Z.match(s):
        raise Refused("bad_timestamp")
    try:
        t = time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        raise Refused("bad_timestamp") from None
    if time.strftime("%Y-%m-%dT%H:%M:%SZ", t) != s:
        raise Refused("bad_timestamp")
    return float(calendar.timegm(t))


def read_approval(path: str, want_sha: str) -> dict:
    """Bounded no-follow read of a regular file, its exact sha256, then a strict schema."""
    if not HEX64.match(want_sha or ""):
        raise Refused("approval_sha_malformed")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        raise Refused("approval_unreadable") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_APPROVAL_BYTES:
            raise Refused("approval_not_regular_or_too_big")
        data = os.read(fd, MAX_APPROVAL_BYTES + 1)
    finally:
        os.close(fd)
    if hashlib.sha256(data).hexdigest() != want_sha:
        raise Refused("approval_sha_mismatch")
    try:
        rec = json.loads(data)
    except ValueError:
        raise Refused("approval_not_json") from None
    if not isinstance(rec, dict) or set(rec) != KEYS:
        raise Refused("approval_schema")
    h = rec["expected_holder"]
    if not isinstance(h, dict) or set(h) != HOLDER_KEYS or not all(isinstance(v, str) and v for v in h.values()) \
            or not HEX64.match(h["session_digest"]):
        raise Refused("approval_holder_schema")
    if rec["protocol"] != PROTOCOL:
        raise Refused("approval_protocol")
    for k in ("approval_id", "prompt_id", "owner_label", "request_id", "request_name", "auth_id"):
        if not isinstance(rec[k], str) or not SAFE_ID.match(rec[k]):
            raise Refused(f"approval_field_{k}")
    if not isinstance(rec["project"], str) or not rec["project"]:
        raise Refused("approval_field_project")
    if not HEX64.match(rec["request_sha256"] if isinstance(rec["request_sha256"], str) else ""):
        raise Refused("approval_field_request_sha256")
    m = rec["manifest"]
    if not isinstance(m, list) or not m or not all(isinstance(x, str) and SAFE_ID.match(x) for x in m) or len(set(m)) != len(m):
        raise Refused("approval_field_manifest")
    if rec["expected_generation"] != 1 or type(rec["expected_generation"]) is not int:
        raise Refused("approval_generation_not_initial")
    ttl = rec["lease_ttl_s"]
    if type(ttl) is not int or not 60 <= ttl <= MAX_WINDOW_S:
        raise Refused("approval_field_lease_ttl_s")
    return rec


def check_window(rec: dict, now: float) -> float:
    decided, exp = _epoch(rec["decided_at"]), _epoch(rec["grant_expires_at"])
    if decided > now + 60:
        raise Refused("approval_decided_in_future")
    if not decided < exp <= decided + MAX_WINDOW_S:
        raise Refused("approval_window_over_60min")
    if now >= exp:
        raise Refused("approval_expired")
    return exp


def same_identity(resolve, rec) -> None:
    h = rec["expected_holder"]
    if resolve(rec["owner_label"]) != (h["pane_id"], h["pane_birth"], h["session_digest"]):
        raise Refused("identity_mismatch")


def insert_grant(store, rec, exp: float) -> None:
    """The only grant writer: fixed columns, one row, refuses any prior use of
    auth_id or approval_id, inside one BEGIN IMMEDIATE."""
    h = rec["expected_holder"]
    store.execute("BEGIN IMMEDIATE")
    try:
        if store.execute("SELECT 1 FROM owner_dispatch_auth WHERE auth_id=? OR approval_id=?",
                         (rec["auth_id"], rec["approval_id"])).fetchone():
            raise Refused("approval_already_used")
        store.execute(
            "INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,session_digest,"
            "lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,decided_at,expires_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'granted',?,?)",
            (rec["auth_id"], oda.PROTOCOL, rec["owner_label"], rec["project"], h["pane_id"], h["pane_birth"],
             h["session_digest"], 1, rec["request_id"], rec["request_sha256"], oda.manifest_key(rec["manifest"]),
             rec["prompt_id"], rec["approval_id"], rec["decided_at"], exp))
        store.execute("COMMIT")
    finally:
        if store.in_transaction:
            store.execute("ROLLBACK")


def main(argv=None, resolve=None, now=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--approval", required=True)
    ap.add_argument("--approval-sha256", required=True)
    ap.add_argument("--request-dir", required=True)
    a = ap.parse_args(argv)
    if not all(os.environ.get(f) == "1" for f in ("HERDR_OWNER_DISPATCH_ISSUE", "HERDR_OWNER_LEASE_WRITER",
                                                   "HERDR_OWNER_LEASE_DELIVERY")):
        print("refused:flags_off")
        return 4
    os.umask(0o077)
    clock = (lambda: now) if now is not None else time.time
    try:
        rec = read_approval(a.approval, a.approval_sha256)
        exp = check_window(rec, clock())
        try:
            data = oda.read_request_once(a.request_dir, rec["request_name"])
        except (ValueError, OSError):
            raise Refused("request_unreadable") from None
        if oda.body_sha256(data) != rec["request_sha256"]:
            raise Refused("request_sha_mismatch")
    except Refused as exc:
        print(f"refused:{exc}")
        return 2
    try:
        lconn = private_sqlite.open_private(os.environ.get("HERDR_OWNER_LEASE_DB", ""), ol.connect,
                                            require_table="owner_leases")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    try:
        store = oda.open_store(os.environ.get("HERDR_OWNER_DISPATCH_AUTH_DB", ""))
    except ValueError as exc:
        lconn.close()
        print(f"refused:auth_{exc}")
        return 4
    if resolve is None:
        import publisher  # noqa: E402
        resolve = publisher.registry_resolver
    claimed = False
    try:
        same_identity(resolve, rec)                                   # revalidation 1: before claim
        row = lconn.execute("SELECT project FROM owner_projects WHERE label=?", (rec["owner_label"],)).fetchone()
        if not row or row[0] != rec["project"]:
            raise Refused("owner_project_mismatch")
        if store.execute("SELECT 1 FROM owner_dispatch_auth WHERE auth_id=? OR approval_id=?",
                         (rec["auth_id"], rec["approval_id"])).fetchone():
            raise Refused("approval_already_used")
        h = rec["expected_holder"]
        try:
            gen = ol.claim_initial(lconn, rec["owner_label"], h["pane_id"], h["pane_birth"], rec["lease_ttl_s"],
                                   h["session_digest"], now=clock())
        except ol.LeaseConflict:
            raise Refused("not_initial") from None
        except (ol.Disabled, ol.InvalidOwner, ValueError) as exc:
            raise Refused(f"claim_{type(exc).__name__}") from None
        claimed = True
        if gen != rec["expected_generation"]:
            raise Refused("generation_mismatch")
        check_window(rec, clock())
        same_identity(resolve, rec)                                   # revalidation 2: before issue
        if ol.holder_tuple(lconn, rec["owner_label"], clock()) != (h["pane_id"], h["pane_birth"], h["session_digest"], 1):
            raise Refused("lease_holder_mismatch")
        insert_grant(store, rec, exp)
    except Refused as exc:
        print(f"{'claimed_not_issued' if claimed else 'refused'}:{exc}")
        return 5 if claimed else 2
    finally:
        lconn.close()
        store.close()
    print(f"issued:{rec['auth_id']}:gen1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
