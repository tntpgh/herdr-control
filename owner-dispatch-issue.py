#!/usr/bin/env python3
"""owner-dispatch-issue.py --form-id ID --request-dir D
One-shot writer for ONE approved owner-dispatch pilot (OFF BY DEFAULT, INERT).

TRUST ROOT: the answered formserve decision record, not a caller-supplied
file or digest. The writer reads, from the canonical forms directory
($HERDR_STATE_ROOT/forms, default ~/.local/state/herdr/forms):
  <ID>.json   the registry row formserve/hub write claim-once on submit
              (status "answered", answered_at, answers), and
  <ID>.html   the exact page that was served to Terrence.
The page embeds the approval record as <script type="application/json"
id="owner-dispatch-approval">. The answers must say decision="approve" AND
echo approval_sha256 = sha256 of exactly those embedded bytes, so an
approval binds the record that was on screen. decided_at is the record's
answered_at. grant expiry = answered_at + approval.grant_window_s (<= 3600).
The form id is the approval_id/prompt_id.
LIMITS, stated: the forms directory is same-UID state. A same-UID process can
write a fake answered record plus HTML; the per-run formserve token proves only
that the submit came from a loaded page. There is NO separately authenticated
operator identity on this machine. The trust root is therefore "a first-hand
answer on the local hub, under the same-UID trust boundary", nothing stronger.

One approval authorizes, conditionally: the EXPECTED initial lease claim
(generation 1) and issuing exactly ONE grant bound to the frozen request.
Each check aborts on mismatch: request bytes; the registry identity (checked
before the claim AND before issue); the owner_projects row (project AND
max_open must equal the approval); initial-only claim; holder after the claim;
expiry; prior use of auth_id/approval_id.
The grant row and an immutable issuance record (approval sha256, a copy of the
approval bytes, the form record and HTML sha256s, answered_at) are written in
ONE transaction in the auth store. owner_dispatch_issuance is append-only.
Lease and auth stores are separate files, so claim+issue are not atomic.
Exit:
  0 issued;
  2 refused before any write;
  4 config;
  5 claimed_not_issued (the grant was verified ABSENT after the claim);
  6 issue_uncertain (an error after the claim, or a failed commit, and the
    grant row could not be verified absent: inspect the store, never retry).
Nothing retries.
"""
from __future__ import annotations

import argparse
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

PROTOCOL = "owner-dispatch-approval/2"
MAX_FILE_BYTES = 256 * 1024
MAX_WINDOW_S = 3600
HEX64 = re.compile(r"^[0-9a-f]{64}$")
FORM_ID = re.compile(r"^[0-9]{8}T[0-9]{6}-[0-9]{2,5}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
EMBED = re.compile(rb'<script type="application/json" id="owner-dispatch-approval">(.*?)</script>', re.S)
KEYS = {"protocol", "owner_label", "project", "max_open", "expected_holder", "expected_generation", "lease_ttl_s",
        "request_id", "request_name", "request_sha256", "manifest", "auth_id", "grant_window_s"}
HOLDER_KEYS = {"pane_id", "pane_birth", "session_digest"}


class Refused(Exception):
    pass


def forms_dir() -> str:
    return os.path.join(os.environ.get("HERDR_STATE_ROOT", os.path.expanduser("~/.local/state/herdr")), "forms")


def _read_nofollow(path: str) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        raise Refused("form_unreadable") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_FILE_BYTES or st.st_uid != os.getuid():
            raise Refused("form_file_not_private_regular")
        return os.read(fd, MAX_FILE_BYTES + 1)
    finally:
        os.close(fd)


def validate_approval(rec) -> dict:
    if not isinstance(rec, dict) or set(rec) != KEYS:
        raise Refused("approval_schema")
    h = rec["expected_holder"]
    if not isinstance(h, dict) or set(h) != HOLDER_KEYS or not all(isinstance(v, str) and v for v in h.values()) \
            or not HEX64.match(h["session_digest"]):
        raise Refused("approval_holder_schema")
    if rec["protocol"] != PROTOCOL:
        raise Refused("approval_protocol")
    for k in ("owner_label", "request_id", "request_name", "auth_id"):
        if not isinstance(rec[k], str) or not SAFE_ID.match(rec[k]):
            raise Refused(f"approval_field_{k}")
    if not isinstance(rec["project"], str) or not rec["project"]:
        raise Refused("approval_field_project")
    if not isinstance(rec["request_sha256"], str) or not HEX64.match(rec["request_sha256"]):
        raise Refused("approval_field_request_sha256")
    m = rec["manifest"]
    if not isinstance(m, list) or not m or not all(isinstance(x, str) and SAFE_ID.match(x) for x in m) or len(set(m)) != len(m):
        raise Refused("approval_field_manifest")
    if type(rec["expected_generation"]) is not int or rec["expected_generation"] != 1:
        raise Refused("approval_generation_not_initial")
    if type(rec["max_open"]) is not int or rec["max_open"] != 1:
        raise Refused("approval_max_open_not_1")
    if type(rec["lease_ttl_s"]) is not int or not 60 <= rec["lease_ttl_s"] <= MAX_WINDOW_S:
        raise Refused("approval_field_lease_ttl_s")
    if type(rec["grant_window_s"]) is not int or not 60 <= rec["grant_window_s"] <= MAX_WINDOW_S:
        raise Refused("approval_field_grant_window_s")
    return rec


def read_decision(form_id: str) -> dict:
    """The answered formserve record + served HTML -> the approved record and its provenance."""
    if not isinstance(form_id, str) or not FORM_ID.match(form_id):
        raise Refused("form_id_malformed")
    d = forms_dir()
    if os.path.realpath(d) != d:
        raise Refused("forms_dir_not_canonical")
    row_bytes = _read_nofollow(os.path.join(d, form_id + ".json"))
    html = _read_nofollow(os.path.join(d, form_id + ".html"))
    try:
        row = json.loads(row_bytes)
    except ValueError:
        raise Refused("form_record_not_json") from None
    if not isinstance(row, dict) or row.get("id") != form_id or row.get("status") != "answered":
        raise Refused("form_not_answered")
    at = row.get("answered_at")
    if type(at) is not int or at <= 0:
        raise Refused("form_answered_at_missing")
    found = EMBED.findall(html)
    if len(found) != 1:
        raise Refused("form_html_no_single_embedded_approval")
    embedded = found[0]
    sha = hashlib.sha256(embedded).hexdigest()
    ans = row.get("answers")
    if not isinstance(ans, dict) or ans.get("decision") != "approve":
        raise Refused("form_not_approved")
    if ans.get("approval_sha256") != sha:
        raise Refused("form_answer_not_bound_to_displayed_record")
    try:
        rec = json.loads(embedded)
    except ValueError:
        raise Refused("approval_not_json") from None
    return {"rec": validate_approval(rec), "approval_bytes": embedded, "approval_sha256": sha, "form_id": form_id,
            "answered_at": at / 1000.0, "form_record_sha256": hashlib.sha256(row_bytes).hexdigest(),
            "form_html_sha256": hashlib.sha256(html).hexdigest()}


def window(dec: dict, now: float) -> float:
    decided = dec["answered_at"]
    if decided > now + 60:
        raise Refused("approval_decided_in_future")
    exp = decided + dec["rec"]["grant_window_s"]
    if now >= exp:
        raise Refused("approval_expired")
    return exp


def same_identity(resolve, rec) -> None:
    h = rec["expected_holder"]
    if resolve(rec["owner_label"]) != (h["pane_id"], h["pane_birth"], h["session_digest"]):
        raise Refused("identity_mismatch")


def insert_grant(store, dec, exp: float) -> None:
    """The only grant writer: fixed columns; grant row + immutable issuance
    record in ONE transaction; refuses any prior use of auth_id/approval_id."""
    rec, h = dec["rec"], dec["rec"]["expected_holder"]
    decided_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(dec["answered_at"]))
    store.execute("BEGIN IMMEDIATE")
    try:
        if store.execute("SELECT 1 FROM owner_dispatch_auth WHERE auth_id=? OR approval_id=?",
                         (rec["auth_id"], dec["form_id"])).fetchone():
            raise Refused("approval_already_used")
        store.execute(
            "INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,session_digest,"
            "lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,decided_at,expires_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'granted',?,?)",
            (rec["auth_id"], oda.PROTOCOL, rec["owner_label"], rec["project"], h["pane_id"], h["pane_birth"],
             h["session_digest"], 1, rec["request_id"], rec["request_sha256"], oda.manifest_key(rec["manifest"]),
             dec["form_id"], dec["form_id"], decided_iso, exp))
        store.execute(
            "INSERT INTO owner_dispatch_issuance(auth_id,approval_sha256,approval_bytes,form_id,form_record_sha256,"
            "form_html_sha256,answered_at,issued_at) VALUES (?,?,?,?,?,?,?,?)",
            (rec["auth_id"], dec["approval_sha256"], dec["approval_bytes"], dec["form_id"], dec["form_record_sha256"],
             dec["form_html_sha256"], dec["answered_at"], time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
        store.execute("COMMIT")
    finally:
        if store.in_transaction:
            store.execute("ROLLBACK")


def grant_state(auth_db: str, dec) -> str:
    """After an error: 'present' (grant + matching issuance found), 'absent', or 'unknown'."""
    try:
        c = oda.open_store(auth_db)
        try:
            g = c.execute("SELECT approval_id FROM owner_dispatch_auth WHERE auth_id=?", (dec["rec"]["auth_id"],)).fetchone()
            i = c.execute("SELECT approval_sha256 FROM owner_dispatch_issuance WHERE auth_id=?", (dec["rec"]["auth_id"],)).fetchone()
        finally:
            c.close()
    except Exception:  # noqa: BLE001
        return "unknown"
    if g is None and i is None:
        return "absent"
    if g and i and g[0] == dec["form_id"] and i[0] == dec["approval_sha256"]:
        return "present"
    return "unknown"


def main(argv=None, resolve=None, now=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--form-id", required=True)
    ap.add_argument("--request-dir", required=True)
    a = ap.parse_args(argv)
    if not all(os.environ.get(f) == "1" for f in ("HERDR_OWNER_DISPATCH_ISSUE", "HERDR_OWNER_LEASE_WRITER",
                                                   "HERDR_OWNER_LEASE_DELIVERY")):
        print("refused:flags_off")
        return 4
    os.umask(0o077)
    clock = (lambda: now) if now is not None else time.time
    try:
        dec = read_decision(a.form_id)
        rec = dec["rec"]
        exp = window(dec, clock())
        try:
            data = oda.read_request_once(a.request_dir, rec["request_name"])
        except (ValueError, OSError):
            raise Refused("request_unreadable") from None
        if oda.body_sha256(data) != rec["request_sha256"]:
            raise Refused("request_sha_mismatch")
    except Refused as exc:
        print(f"refused:{exc}")
        return 2
    lease_db, auth_db = os.environ.get("HERDR_OWNER_LEASE_DB", ""), os.environ.get("HERDR_OWNER_DISPATCH_AUTH_DB", "")
    try:
        lconn = private_sqlite.open_private(lease_db, ol.connect, require_table="owner_leases")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    try:
        store = oda.open_store(auth_db)
    except ValueError as exc:
        lconn.close()
        print(f"refused:auth_{exc}")
        return 4
    if resolve is None:
        import publisher  # noqa: E402
        resolve = publisher.registry_resolver
    claimed = False
    h = rec["expected_holder"]
    try:
        try:
            same_identity(resolve, rec)                               # revalidation 1: before claim
            row = lconn.execute("SELECT project, max_open FROM owner_projects WHERE label=?", (rec["owner_label"],)).fetchone()
            if not row or row[0] != rec["project"] or row[1] != rec["max_open"]:
                raise Refused("owner_project_mismatch")
            if store.execute("SELECT 1 FROM owner_dispatch_auth WHERE auth_id=? OR approval_id=?",
                             (rec["auth_id"], dec["form_id"])).fetchone():
                raise Refused("approval_already_used")
            try:
                gen = ol.claim_initial(lconn, rec["owner_label"], h["pane_id"], h["pane_birth"], rec["lease_ttl_s"],
                                       h["session_digest"], now=clock())
            except ol.LeaseConflict:
                raise Refused("not_initial") from None
            except (ol.Disabled, ol.InvalidOwner, ValueError) as exc:
                raise Refused(f"claim_{type(exc).__name__}") from None
        except Refused as exc:
            print(f"refused:{exc}")
            return 2
        except Exception as exc:  # noqa: BLE001  pre-claim failure: nothing was written by this run
            print(f"refused:error_{type(exc).__name__}")
            return 2
        claimed = True
        try:
            if gen != rec["expected_generation"]:
                raise Refused("generation_mismatch")
            window(dec, clock())
            same_identity(resolve, rec)                               # revalidation 2: before issue
            if ol.holder_tuple(lconn, rec["owner_label"], clock()) != (h["pane_id"], h["pane_birth"], h["session_digest"], 1):
                raise Refused("lease_holder_mismatch")
            insert_grant(store, dec, exp)
        except BaseException as exc:  # noqa: BLE001  after the claim: classify by what the store says
            reason = str(exc) if isinstance(exc, Refused) else f"error_{type(exc).__name__}"
            st = grant_state(auth_db, dec)
            if st == "present":
                print(f"issued:{rec['auth_id']}:gen1 (after {reason}; verified in store)")
                return 0
            if st == "absent" and isinstance(exc, Refused):
                print(f"claimed_not_issued:{reason}")
                return 5
            print(f"issue_uncertain:{reason}:store_{st}")
            return 6
    finally:
        for c in (lconn, store):
            try:
                c.close()
            except Exception:  # noqa: BLE001
                pass
    print(f"issued:{rec['auth_id']}:gen1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
