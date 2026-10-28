#!/usr/bin/env python3
"""owner-dispatch-issue.py --form-id ID --request-dir D
One-shot writer for ONE approved owner-dispatch pilot (OFF BY DEFAULT, INERT).

TRUST ROOT: the answered formserve decision record, not a caller-supplied
file or digest. The writer reads, from the PINNED forms directory
~/.local/state/herdr/forms (opened per component with O_NOFOLLOW; own-UID,
no group/world write; HERDR_STATE_ROOT is ignored):
  <ID>.json   the registry row formserve/hub write claim-once on submit
              (status "answered", answered_at, answers), and
  <ID>.html   the exact page that was served to Terrence.
The page must be byte-identical to render_form(record) (built offline by
`owner-dispatch-issue.py build-form`, which binds the holder resolved fresh from
the registry and the request sha256); it embeds the record's canonical bytes as
<script type="application/json" id="owner-dispatch-approval">. The answers must say decision="approve" AND
echo approval_sha256 = sha256 of exactly those embedded bytes, so an
approval binds the record that was on screen. decided_at is the record's
answered_at. grant expiry = answered_at + approval.grant_window_s (<= 3600).
The form id is the approval_id/prompt_id.
LIMITS, stated: the forms directory is same-UID state. A same-UID process can
write a fake answered record plus HTML; the per-run formserve token proves only
that the submit came from a loaded page. There is NO separately authenticated
operator identity on this machine. The trust root is therefore "a first-hand
answer on the local hub, under the same-UID trust boundary", nothing stronger.

One approval authorizes, conditionally: the EXPECTED lease claim -- initial
generation 1 (no expected_prev_generation key: the classic, frozen record
shape) or a successor generation after an expired predecessor
(expected_prev_generation key present, >= 1) -- and issuing exactly
ONE grant bound to the frozen request.
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
import sqlite3
import stat
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))

import owner_dispatch_auth as oda  # noqa: E402
import owner_lease as ol  # noqa: E402
import queue_supervisor as qs  # noqa: E402

PROTOCOL = "owner-dispatch-approval/2"
MAX_FILE_BYTES = 256 * 1024
MAX_WINDOW_S = 3600
HEX64 = re.compile(r"^[0-9a-f]{64}$")
FORM_ID = re.compile(r"^[0-9]{8}T[0-9]{6}-[0-9]{2,5}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
EMBED = re.compile(rb'<script type="application/json" id="owner-dispatch-approval">(.*?)</script>', re.S)
KEYS = {"protocol", "owner_label", "project", "max_open", "expected_holder", "expected_generation", "lease_ttl_s",
        "request_id", "request_name", "request_sha256", "manifest", "auth_id", "grant_window_s"}
# A successor (prev>=1) approval ADDS exactly these two keys to the frozen
# gen1 schema above; it never replaces or renames an existing key, so a
# classic gen1 record (set(rec) == KEYS, no successor keys at all) is
# byte-identical, schema and HTML, to the pre-successor frozen baseline.
SUCCESSOR_KEYS = KEYS | {"expected_prev_generation", "expected_prev_holder"}
HOLDER_KEYS = {"pane_id", "pane_birth", "session_digest"}

# A SEPARATE record kind for standing grants (owner-dispatch-approval-standing/1,
# never owner-dispatch-approval/2): queue-rooted, multi-dispatch, its OWN window
# bound. KEYS/SUCCESSOR_KEYS/MAX_WINDOW_S/validate_approval/render_form/the
# --form-id/--request-dir single-use path below are UNCHANGED by any of this --
# a classic single-use record is refused by validate_standing_approval (disjoint
# key set) exactly as a standing record is refused by validate_approval.
STANDING_PROTOCOL = "owner-dispatch-approval-standing/1"
MAX_STANDING_WINDOW_S = 86400  # longer than MAX_WINDOW_S: covers a multi-item
                               # queue over a working session; item_cap and
                               # spend_cap_cents, not window length, bound the
                               # exposure of each individual future dispatch.
STANDING_KEYS = {"protocol", "owner_label", "project", "expected_holder", "expected_generation",
                 "queue_sha256", "queue_items", "item_cap", "spend_cap_cents", "auth_id", "standing_window_s"}


class Refused(Exception):
    pass


# PINNED canonical state root. Deliberately NOT read from HERDR_STATE_ROOT or
# any argument: the caller cannot choose where the "answered" record lives.
# (Tests rebind this module attribute; no runtime path does.)
STATE_ROOT = os.path.join(os.path.expanduser("~"), ".local", "state", "herdr")


def _safe_dir_fd(path: str) -> int:
    """Open `path` one component at a time from '/', O_NOFOLLOW|O_DIRECTORY on
    every component (no symlink anywhere in the chain). Every ancestor must be
    owned by root or this user and not group/world-writable (unless sticky);
    the final forms directory must be owned by this user with no g/o write."""
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        raise Refused("forms_dir_not_canonical")
    parts = [p for p in path.split("/") if p]
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for i, name in enumerate(parts):
            try:
                nfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except OSError:
                raise Refused("forms_dir_unsafe_path") from None
            os.close(fd)
            fd = nfd
            st = os.fstat(fd)
            if i == len(parts) - 1:
                if st.st_uid != os.getuid() or st.st_mode & 0o022:
                    raise Refused("forms_dir_not_private")
            elif st.st_uid not in (0, os.getuid()) or (st.st_mode & 0o022 and not st.st_mode & stat.S_ISVTX):
                raise Refused("forms_dir_unsafe_ancestor")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _read_at(dfd: int, name: str) -> bytes:
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except OSError:
        raise Refused("form_unreadable") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_FILE_BYTES or st.st_uid != os.getuid() or st.st_mode & 0o022:
            raise Refused("form_file_not_private_regular")
        return os.read(fd, MAX_FILE_BYTES + 1)
    finally:
        os.close(fd)


def approval_bytes(rec: dict) -> bytes:
    """The ONE canonical serialization of an approval record."""
    return json.dumps(rec, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def _valid_holder(h) -> bool:
    return isinstance(h, dict) and set(h) == HOLDER_KEYS and all(isinstance(v, str) and v for v in h.values()) \
        and bool(HEX64.match(h["session_digest"]))


def render_form(rec: dict) -> bytes:
    """Deterministic decision page for one approval record. read_decision()
    accepts ONLY a stored page byte-identical to this rendering, so what was on
    screen is exactly the record (including holder, request sha and window).
    A classic gen1 record (no expected_prev_generation key) renders
    BYTE-IDENTICAL to the original claim_initial-only form (frozen at
    1a0b873); a successor record (expected_prev_generation present)
    additionally names the released predecessor and the generation being
    claimed (claim_successor path)."""
    emb = approval_bytes(rec)
    sha = hashlib.sha256(emb).hexdigest()
    h = rec["expected_holder"]
    is_successor = "expected_prev_generation" in rec
    rows = [("Owner", rec["owner_label"]), ("Project", rec["project"]), ("Holder pane", h["pane_id"]),
            ("Holder birth", h["pane_birth"]), ("Holder session sha256", h["session_digest"]),
            ("Request", f'{rec["request_id"]} / {rec["request_name"]}'), ("Request sha256", rec["request_sha256"]),
            ("Manifest", ", ".join(rec["manifest"])), ("Grant id", rec["auth_id"])]
    ph = {}
    if is_successor:
        prev_gen = rec["expected_prev_generation"]
        raw_ph = rec.get("expected_prev_holder")
        ph = raw_ph if isinstance(raw_ph, dict) else {}
        rows.append(("Predecessor",
                     f'releases expired generation {prev_gen}, held by {ph.get("pane_id", "?")}@{ph.get("pane_birth", "?")}'))
    rows += [("Lease", f'generation {rec["expected_generation"]}, ttl {rec["lease_ttl_s"]} s, max_open {rec["max_open"]}'),
             ("Approval valid for", f'{rec["grant_window_s"]} s after you answer'), ("Approval record sha256", sha)]
    esc = lambda v: str(v).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    table = "".join(f"<tr><th>{esc(k)}</th><td><code>{esc(v)}</code></td></tr>" for k, v in rows)
    intro = ("<p>Approving issues exactly one generation-1 lease claim and one grant for the request below. Nothing retries.</p>"
             if not is_successor else
             f'<p>Approving releases the expired predecessor lease (generation {rec["expected_prev_generation"]}, held by '
             f'{ph.get("pane_id", "?")}@{ph.get("pane_birth", "?")}) and issues exactly one '
             f'generation-{rec["expected_generation"]} lease claim and one grant for the request below. Nothing retries.</p>')
    return ("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Approve ONE KB owner-dispatch pilot request</title></head><body>"
            "<h1>Approve ONE read-only KB pilot request?</h1>"
            f"{intro}"
            f"<table>{table}</table>"
            f'<script type="application/json" id="owner-dispatch-approval">{emb.decode()}</script>'
            f'<button onclick="window.submitAnswers({{decision:\'approve\',approval_sha256:\'{sha}\'}})">Approve</button> '
            "<button onclick=\"window.submitAnswers({decision:'decline'})\">Decline</button>"
            "</body></html>").encode()


def validate_approval(rec) -> dict:
    if not isinstance(rec, dict) or set(rec) not in (KEYS, SUCCESSOR_KEYS):
        raise Refused("approval_schema")
    is_successor = "expected_prev_generation" in rec
    if not _valid_holder(rec["expected_holder"]):
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
    if is_successor:
        pg = rec["expected_prev_generation"]
        if type(pg) is not int or pg < 1:
            raise Refused("approval_field_expected_prev_generation")
        if not _valid_holder(rec["expected_prev_holder"]):
            raise Refused("approval_prev_holder_schema")
        if type(rec["expected_generation"]) is not int or rec["expected_generation"] != pg + 1:
            raise Refused("approval_generation_mismatch")
    elif type(rec["expected_generation"]) is not int or rec["expected_generation"] != 1:
        raise Refused("approval_generation_not_initial")
    if type(rec["max_open"]) is not int or rec["max_open"] != 1:
        raise Refused("approval_max_open_not_1")
    if type(rec["lease_ttl_s"]) is not int or not 60 <= rec["lease_ttl_s"] <= MAX_WINDOW_S:
        raise Refused("approval_field_lease_ttl_s")
    if type(rec["grant_window_s"]) is not int or not 60 <= rec["grant_window_s"] <= MAX_WINDOW_S:
        raise Refused("approval_field_grant_window_s")
    return rec


def render_standing_form(rec: dict) -> bytes:
    """Deterministic decision page for ONE standing approval record: the
    caps and the exact queue item list, so approving authorizes dispatch of
    exactly that item set and nothing more. A SEPARATE record kind
    (STANDING_PROTOCOL/STANDING_KEYS) from render_form's single-request page.
    read_decision() validates the record's schema BEFORE ever comparing
    render output, so a malformed record never reaches a canonical render;
    field lookups here are defensive (.get) purely so a malformed/attacker
    record still renders SOME deterministic page rather than crashing this
    module, never as a substitute for validate_standing_approval's checks."""
    emb = approval_bytes(rec)
    sha = hashlib.sha256(emb).hexdigest()
    h = rec.get("expected_holder") if isinstance(rec.get("expected_holder"), dict) else {}
    esc = lambda v: str(v).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    rows = [("Owner", rec.get("owner_label")), ("Project", rec.get("project")),
            ("Holder pane", h.get("pane_id")), ("Holder birth", h.get("pane_birth")),
            ("Holder session sha256", h.get("session_digest")),
            ("Lease generation (floor)", rec.get("expected_generation")),
            ("Queue sha256", rec.get("queue_sha256")), ("Item cap", rec.get("item_cap")),
            ("Spend cap (cents)", rec.get("spend_cap_cents")), ("Grant id", rec.get("auth_id")),
            ("Approval valid for", f'{rec.get("standing_window_s")} s after you answer'),
            ("Approval record sha256", sha)]
    table = "".join(f"<tr><th>{esc(k)}</th><td><code>{esc(v)}</code></td></tr>" for k, v in rows)
    qi = rec.get("queue_items") if isinstance(rec.get("queue_items"), list) else []
    items_html = "".join(
        f"<tr><td><code>{esc(it.get('id') if isinstance(it, dict) else it)}</code></td>"
        f"<td><code>{esc(it.get('request_sha256') if isinstance(it, dict) else '')}</code></td>"
        f"<td><code>{esc(', '.join(it.get('manifest', [])) if isinstance(it, dict) and isinstance(it.get('manifest'), list) else '')}</code></td>"
        f"<td><code>{esc(it.get('cost_cents') if isinstance(it, dict) and it.get('cost_cents') is not None else '-')}</code></td>"
        f"<td><code>{esc(it.get('action') if isinstance(it, dict) else '')}</code></td></tr>"
        for it in qi)
    return (f'<!DOCTYPE html><html><head><meta charset="utf-8"><title>Approve standing grant: '
            f'{esc(rec.get("owner_label"))} / {esc(rec.get("project"))}</title></head><body>'
            f'<h1>Approve a standing grant for {esc(rec.get("owner_label"))} ({esc(rec.get("project"))})? '
            f'Up to {esc(rec.get("item_cap"))} dispatches, spend capped at {esc(rec.get("spend_cap_cents"))}c, '
            f'valid {esc(rec.get("standing_window_s"))} s after you answer.</h1>'
            f"<p>Approving authorizes up to {esc(rec.get('item_cap'))} future dispatches (spend capped at "
            f"{esc(rec.get('spend_cap_cents'))}c) against the EXACT queue below, for the currently-live holder "
            "shown. Nothing claims a new lease.</p>"
            f"<table>{table}</table>"
            f"<h2>Queue items</h2><table><tr><th>id</th><th>request sha256</th><th>manifest</th><th>cost_cents</th>"
            f"<th>action</th></tr>{items_html}</table>"
            f'<script type="application/json" id="owner-dispatch-approval">{emb.decode()}</script>'
            f'<button onclick="window.submitAnswers({{decision:\'approve\',approval_sha256:\'{sha}\'}})">Approve</button> '
            "<button onclick=\"window.submitAnswers({decision:'decline'})\">Decline</button>"
            "</body></html>").encode()


def validate_standing_approval(rec) -> dict:
    if not isinstance(rec, dict) or set(rec) != STANDING_KEYS:
        raise Refused("standing_approval_schema")
    if not _valid_holder(rec["expected_holder"]):
        raise Refused("standing_approval_holder_schema")
    if rec["protocol"] != STANDING_PROTOCOL:
        raise Refused("standing_approval_protocol")
    for k in ("owner_label", "auth_id"):
        if not isinstance(rec[k], str) or not SAFE_ID.match(rec[k]):
            raise Refused(f"standing_approval_field_{k}")
    if not isinstance(rec["project"], str) or not rec["project"]:
        raise Refused("standing_approval_field_project")
    if type(rec["expected_generation"]) is not int or rec["expected_generation"] < 1:
        raise Refused("standing_approval_field_expected_generation")
    if not isinstance(rec["queue_sha256"], str) or not HEX64.match(rec["queue_sha256"]):
        raise Refused("standing_approval_field_queue_sha256")
    if type(rec["item_cap"]) is not int or rec["item_cap"] < 1:
        raise Refused("standing_approval_field_item_cap")
    if type(rec["spend_cap_cents"]) is not int or rec["spend_cap_cents"] < 0:
        raise Refused("standing_approval_field_spend_cap_cents")
    if type(rec["standing_window_s"]) is not int or not 60 <= rec["standing_window_s"] <= MAX_STANDING_WINDOW_S:
        raise Refused("standing_approval_field_standing_window_s")
    qi = rec["queue_items"]
    if (not isinstance(qi, list) or not qi or len(qi) > 100
            or len({it.get("id") for it in qi if isinstance(it, dict)}) != len(qi)):
        raise Refused("standing_approval_field_queue_items")
    for it in qi:
        if not isinstance(it, dict) or set(it) != {"id", "request_sha256", "manifest", "cost_cents", "action"}:
            raise Refused("standing_approval_field_queue_items")
        if not isinstance(it["id"], str) or not SAFE_ID.match(it["id"]):
            raise Refused("standing_approval_field_queue_items")
        if not isinstance(it["request_sha256"], str) or not HEX64.match(it["request_sha256"]):
            raise Refused("standing_approval_field_queue_items")
        man = it["manifest"]
        if (not isinstance(man, list) or len(man) > qs.MAX_MANIFEST or len(set(man)) != len(man)
                or not all(isinstance(m, str) and SAFE_ID.match(m) for m in man)):
            raise Refused("standing_approval_field_queue_items")
        c = it["cost_cents"]
        if c is not None and (type(c) is not int or c < 0):
            raise Refused("standing_approval_field_queue_items")
        if it["action"] not in ("dispatch", "hold"):
            raise Refused("standing_approval_field_queue_items")
    return rec


def canonical_queue_items(data: bytes) -> list[dict]:
    """The APPROVABLE item list derived from the EXACT queue bytes via the
    SAME validator queue-supervisor.py's real tick() uses
    (lib/queue_supervisor.validate_queue) -- never re-implemented, never
    trusts the caller's own list. One entry per item, in file order: id,
    the request text's own sha256 (never the full text -- same principle as
    the single-use path's request_sha256), manifest, cost_cents (None when
    absent), action ('hold' when hold:true, else 'dispatch'). Raises
    ValueError (the caller wraps it as Refused) on anything the real
    validator itself would reject. The caller requires the SIGNED record's
    queue_items to equal exactly this, so an approver cannot be shown one
    queue and sign a record naming another."""
    items = qs.validate_queue(json.loads(data))
    return [{"id": it["id"], "request_sha256": hashlib.sha256(it["request"].encode()).hexdigest(),
            "manifest": list(it.get("manifest", [])), "cost_cents": it.get("cost_cents"),
            "action": "hold" if it.get("hold") else "dispatch"} for it in items]


def read_decision(form_id: str, validate=validate_approval, render=render_form) -> dict:
    """The answered formserve record + served HTML -> the approved record and its provenance."""
    if not isinstance(form_id, str) or not FORM_ID.match(form_id):
        raise Refused("form_id_malformed")
    dfd = _safe_dir_fd(os.path.join(STATE_ROOT, "forms"))
    try:
        row_bytes = _read_at(dfd, form_id + ".json")
        html = _read_at(dfd, form_id + ".html")
    finally:
        os.close(dfd)
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
    rec = validate(rec)
    if approval_bytes(rec) != embedded or render(rec) != html:
        raise Refused("form_html_not_canonical_rendering")
    return {"rec": rec, "approval_bytes": embedded, "approval_sha256": sha, "form_id": form_id,
            "answered_at": at / 1000.0, "form_record_sha256": hashlib.sha256(row_bytes).hexdigest(),
            "form_html_sha256": hashlib.sha256(html).hexdigest()}


def window(dec: dict, now: float, key: str = "grant_window_s") -> float:
    decided = dec["answered_at"]
    if decided > now + 60:
        raise Refused("approval_decided_in_future")
    exp = decided + dec["rec"][key]
    if now >= exp:
        raise Refused("approval_expired")
    return exp


def same_identity(resolve, rec) -> None:
    h = rec["expected_holder"]
    if resolve(rec["owner_label"]) != (h["pane_id"], h["pane_birth"], h["session_digest"]):
        raise Refused("identity_mismatch")


GRANT_COLS = ("auth_id", "protocol", "owner_label", "project", "pane_id", "pane_birth", "session_digest", "lease_generation",
              "request_id", "body_sha256", "manifest", "prompt_id", "approval_id", "status", "decided_at", "expires_at")
ISSUANCE_COLS = ("auth_id", "approval_sha256", "approval_bytes", "form_id", "form_record_sha256", "form_html_sha256", "answered_at")


def expected_rows(dec, exp: float) -> tuple[tuple, tuple]:
    """The complete grant tuple and issuance tuple (minus issued_at) this approval produces."""
    rec, h = dec["rec"], dec["rec"]["expected_holder"]
    decided_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(dec["answered_at"]))
    grant = (rec["auth_id"], oda.PROTOCOL, rec["owner_label"], rec["project"], h["pane_id"], h["pane_birth"], h["session_digest"],
             rec["expected_generation"], rec["request_id"], rec["request_sha256"], oda.manifest_key(rec["manifest"]),
             dec["form_id"], dec["form_id"], "granted", decided_iso, exp)
    issuance = (rec["auth_id"], dec["approval_sha256"], dec["approval_bytes"], dec["form_id"], dec["form_record_sha256"],
                dec["form_html_sha256"], dec["answered_at"])
    return grant, issuance


def insert_grant(store, dec, exp: float) -> None:
    """The only grant writer: fixed columns; grant row + immutable issuance
    record in ONE transaction; refuses any prior use of auth_id/approval_id."""
    rec = dec["rec"]
    grant, issuance = expected_rows(dec, exp)
    store.execute("BEGIN IMMEDIATE")
    try:
        if store.execute("SELECT 1 FROM owner_dispatch_auth WHERE auth_id=? OR approval_id=?",
                         (rec["auth_id"], dec["form_id"])).fetchone():
            raise Refused("approval_already_used")
        store.execute(f"INSERT INTO owner_dispatch_auth({','.join(GRANT_COLS)}) VALUES ({','.join('?' * len(GRANT_COLS))})", grant)
        store.execute(f"INSERT INTO owner_dispatch_issuance({','.join(ISSUANCE_COLS)},issued_at) VALUES ({','.join('?' * (len(ISSUANCE_COLS) + 1))})",
                      (*issuance, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
        store.execute("COMMIT")
    finally:
        if store.in_transaction:
            store.execute("ROLLBACK")


def grant_state(auth_db: str, dec, exp: float) -> str:
    """After an error: 'present' only when the COMPLETE expected grant tuple and
    issuance tuple are both stored; 'absent' when neither the auth_id nor the
    form id is used anywhere; otherwise 'unknown'."""
    want_g, want_i = expected_rows(dec, exp)
    try:
        c = oda.open_store(auth_db)
        try:
            g = c.execute(f"SELECT {','.join(GRANT_COLS)} FROM owner_dispatch_auth WHERE auth_id=? OR approval_id=?",
                          (dec["rec"]["auth_id"], dec["form_id"])).fetchall()
            i = c.execute(f"SELECT {','.join(ISSUANCE_COLS)} FROM owner_dispatch_issuance WHERE auth_id=? OR form_id=?",
                          (dec["rec"]["auth_id"], dec["form_id"])).fetchall()
        finally:
            c.close()
    except Exception:  # noqa: BLE001
        return "unknown"
    if not g and not i:
        return "absent"
    if [tuple(r) for r in g] == [want_g] and [tuple(r) for r in i] == [want_i]:
        return "present"
    return "unknown"


STANDING_GRANT_COLS = ("auth_id", "protocol", "owner_label", "project", "pane_id", "pane_birth", "session_digest",
                       "lease_generation", "request_id", "body_sha256", "manifest", "prompt_id", "approval_id",
                       "status", "decided_at", "expires_at", "kind", "queue_sha256", "item_cap", "spend_cap_cents")


def expected_standing_rows(dec, exp: float) -> tuple[tuple, tuple]:
    """The complete standing-parent tuple and issuance tuple (minus issued_at)
    this approval produces. request_id/body_sha256/manifest are placeholders
    ('', '', '[]') -- the parent authorizes a QUEUE, not one frozen request;
    consume_standing never reads these three columns for a standing row."""
    rec, h = dec["rec"], dec["rec"]["expected_holder"]
    decided_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(dec["answered_at"]))
    grant = (rec["auth_id"], oda.PROTOCOL, rec["owner_label"], rec["project"], h["pane_id"], h["pane_birth"], h["session_digest"],
             rec["expected_generation"], "", "", "[]", dec["form_id"], dec["form_id"], "granted", decided_iso, exp,
             "standing", rec["queue_sha256"], rec["item_cap"], rec["spend_cap_cents"])
    issuance = (rec["auth_id"], dec["approval_sha256"], dec["approval_bytes"], dec["form_id"], dec["form_record_sha256"],
                dec["form_html_sha256"], dec["answered_at"])
    return grant, issuance


def insert_standing_grant(store, dec, exp: float) -> None:
    """The only STANDING grant writer: parent row (kind='standing') + immutable
    issuance record in ONE transaction; refuses any prior use of auth_id/approval_id.
    Caller must have already run lib/owner_dispatch_auth.migrate(store) (a
    v1-only store has none of the standing columns yet)."""
    rec = dec["rec"]
    grant, issuance = expected_standing_rows(dec, exp)
    store.execute("BEGIN IMMEDIATE")
    try:
        if store.execute("SELECT 1 FROM owner_dispatch_auth WHERE auth_id=? OR approval_id=?",
                         (rec["auth_id"], dec["form_id"])).fetchone():
            raise Refused("approval_already_used")
        store.execute(f"INSERT INTO owner_dispatch_auth({','.join(STANDING_GRANT_COLS)}) VALUES ({','.join('?' * len(STANDING_GRANT_COLS))})", grant)
        store.execute(f"INSERT INTO owner_dispatch_issuance({','.join(ISSUANCE_COLS)},issued_at) VALUES ({','.join('?' * (len(ISSUANCE_COLS) + 1))})",
                      (*issuance, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
        store.execute("COMMIT")
    finally:
        if store.in_transaction:
            store.execute("ROLLBACK")


def standing_grant_state(auth_db: str, dec, exp: float) -> str:
    """After an error: 'present' only when the COMPLETE expected standing grant
    tuple and issuance tuple are both stored; 'absent' when neither the
    auth_id nor the form id is used anywhere; otherwise 'unknown'."""
    want_g, want_i = expected_standing_rows(dec, exp)
    try:
        c = oda.open_store(auth_db)
        try:
            g = c.execute(f"SELECT {','.join(STANDING_GRANT_COLS)} FROM owner_dispatch_auth WHERE auth_id=? OR approval_id=?",
                         (dec["rec"]["auth_id"], dec["form_id"])).fetchall()
            i = c.execute(f"SELECT {','.join(ISSUANCE_COLS)} FROM owner_dispatch_issuance WHERE auth_id=? OR form_id=?",
                         (dec["rec"]["auth_id"], dec["form_id"])).fetchall()
        finally:
            c.close()
    except Exception:  # noqa: BLE001
        return "unknown"
    if not g and not i:
        return "absent"
    if [tuple(r) for r in g] == [want_g] and [tuple(r) for r in i] == [want_i]:
        return "present"
    return "unknown"


def build_main(argv, resolve=None) -> int:
    """OFFLINE: write the deterministic decision page for ONE request, binding the
    holder identity resolved fresh from the registry NOW and the request bytes'
    sha256. --expected-prev-generation 0 (default) is the initial gen-1 claim;
    >=1 additionally resolves the EXPIRED predecessor's (pane_id, pane_birth,
    session_digest) from --lease-db (read-only) for display in the form text.
    Serves nothing and records nothing."""
    ap = argparse.ArgumentParser(prog="owner-dispatch-issue.py build-form")
    for a in ("--label", "--project", "--request-dir", "--request-name", "--request-id", "--auth-id", "--out"):
        ap.add_argument(a, required=True)
    ap.add_argument("--manifest", action="append", required=True)
    ap.add_argument("--lease-ttl-s", type=int, default=1800)
    ap.add_argument("--grant-window-s", type=int, default=1800)
    ap.add_argument("--expected-prev-generation", type=int, default=0)
    ap.add_argument("--lease-db")
    a = ap.parse_args(argv)
    if a.expected_prev_generation < 0:
        print("refused:expected_prev_generation_negative")
        return 2
    if resolve is None:
        import publisher  # noqa: E402
        resolve = publisher.registry_resolver
    ident = resolve(a.label)
    if not ident:
        print("refused:identity_unresolved")
        return 2
    prev_holder = None
    if a.expected_prev_generation >= 1:
        if not a.lease_db:
            print("refused:lease_db_required_for_successor")
            return 2
        try:
            plconn = ol.open_rw_checked(a.lease_db, require_table="owner_leases")
        except ValueError as exc:
            print(f"refused:lease_{exc}")
            return 4
        except ol.SchemaMigrationRequired as exc:
            print(f"refused:schema_migration_required:{exc.cur}->{exc.target}:owner-lease-migrate.py --db {a.lease_db} --apply")
            return 4
        try:
            prow = plconn.execute(
                "SELECT pane_id, pane_birth, session_digest FROM owner_leases WHERE label=? AND generation=?",
                (a.label, a.expected_prev_generation)).fetchone()
        finally:
            plconn.close()
        if not prow or not prow[2]:
            print("refused:predecessor_unresolved")
            return 2
        prev_holder = {"pane_id": prow[0], "pane_birth": prow[1], "session_digest": prow[2]}
    try:
        data = oda.read_request_once(a.request_dir, a.request_name)
    except (ValueError, OSError):
        print("refused:request_unreadable")
        return 2
    rec = {"protocol": PROTOCOL, "owner_label": a.label, "project": a.project, "max_open": 1,
           "expected_holder": {"pane_id": ident[0], "pane_birth": ident[1], "session_digest": ident[2]},
           "expected_generation": a.expected_prev_generation + 1, "lease_ttl_s": a.lease_ttl_s, "request_id": a.request_id,
           "request_name": a.request_name, "request_sha256": oda.body_sha256(data), "manifest": a.manifest,
           "auth_id": a.auth_id, "grant_window_s": a.grant_window_s}
    if a.expected_prev_generation >= 1:
        rec["expected_prev_generation"] = a.expected_prev_generation
        rec["expected_prev_holder"] = prev_holder
    try:
        validate_approval(rec)
    except Refused as exc:
        print(f"refused:{exc}")
        return 2
    os.umask(0o077)
    html = render_form(rec)
    fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(html)
    print(f"built:{a.out}:html_sha256={hashlib.sha256(html).hexdigest()}:approval_sha256={hashlib.sha256(approval_bytes(rec)).hexdigest()}")
    return 0


def issue_standing_main(argv, resolve=None, now=None) -> int:
    """Standing-grant counterpart to main(): reuses read_decision (bound to
    validate_standing_approval/render_standing_form), the pinned forms dir,
    the SAME prior-use and identity re-checks as the single-use path -- but
    NEVER claims a lease (claim_initial/claim_successor are not called at
    all): the floor generation named in the approval must already be the
    LIVE holder, reconfirmed via ol.holder_tuple exactly like the single-use
    path's post-claim re-check, never minted here. Writes ONE kind='standing'
    row plus an immutable issuance record in ONE transaction via
    lib/owner_dispatch_auth, against an ALREADY v2 store: migration is a
    SEPARATE, separately-approved setup step (lib/owner_dispatch_auth.migrate)
    -- this path never calls it and refuses a v1/unmigrated store with a
    typed config refusal before any write. The signed record's queue_items
    must equal canonical_queue_items() derived from the EXACT queue bytes,
    so a caller cannot show one queue and sign another.
    Exit: 0 issued; 2 refused before any write; 4 config; 6 issue_uncertain
    (an error after the prior-use/identity checks passed, or a failed commit,
    and the row could not be verified absent: inspect the store, never
    retry). There is no 'claimed_not_issued' code: nothing is ever claimed."""
    ap = argparse.ArgumentParser(prog="owner-dispatch-issue.py issue-standing")
    ap.add_argument("--form-id", required=True)
    ap.add_argument("--queue-dir", required=True)
    ap.add_argument("--queue-name", required=True)
    a = ap.parse_args(argv)
    if not all(os.environ.get(f) == "1" for f in ("HERDR_OWNER_DISPATCH_ISSUE", "HERDR_OWNER_LEASE_WRITER",
                                                   "HERDR_OWNER_LEASE_DELIVERY")):
        print("refused:flags_off")
        return 4
    os.umask(0o077)
    clock = (lambda: now) if now is not None else time.time
    try:
        dec = read_decision(a.form_id, validate=validate_standing_approval, render=render_standing_form)
        rec = dec["rec"]
        exp = window(dec, clock(), key="standing_window_s")
        try:
            data = oda.read_request_once(a.queue_dir, a.queue_name)
        except (ValueError, OSError):
            raise Refused("queue_unreadable") from None
        if hashlib.sha256(data).hexdigest() != rec["queue_sha256"]:
            raise Refused("queue_sha_mismatch")
        try:
            canon = canonical_queue_items(data)
        except ValueError:
            raise Refused("queue_invalid") from None
        if canon != rec["queue_items"]:
            raise Refused("queue_items_mismatch")
    except Refused as exc:
        print(f"refused:{exc}")
        return 2
    lease_db, auth_db = os.environ.get("HERDR_OWNER_LEASE_DB", ""), os.environ.get("HERDR_OWNER_DISPATCH_AUTH_DB", "")
    try:
        lconn = ol.open_rw_checked(lease_db, require_table="owner_leases")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    except ol.SchemaMigrationRequired as exc:
        print(f"refused:schema_migration_required:{exc.cur}->{exc.target}:owner-lease-migrate.py --db {lease_db} --apply")
        return 4
    try:
        store = oda.open_store(auth_db)
    except ValueError as exc:
        lconn.close()
        print(f"refused:auth_{exc}")
        return 4
    try:
        v = store.execute("SELECT COALESCE(MAX(version),0) FROM owner_dispatch_auth_schema_version").fetchone()[0]
    except sqlite3.OperationalError:
        v = 0
    if v < 2:
        lconn.close()
        store.close()
        print("refused:auth_store_not_migrated")
        return 4
    if resolve is None:
        import publisher  # noqa: E402
        resolve = publisher.registry_resolver
    h = rec["expected_holder"]
    try:
        try:
            same_identity(resolve, rec)                                # revalidation 1: before issue
            row = lconn.execute("SELECT project FROM owner_projects WHERE label=?", (rec["owner_label"],)).fetchone()
            if not row or row[0] != rec["project"]:
                raise Refused("owner_project_mismatch")
            if store.execute("SELECT 1 FROM owner_dispatch_auth WHERE auth_id=? OR approval_id=?",
                             (rec["auth_id"], dec["form_id"])).fetchone():
                raise Refused("approval_already_used")
            if ol.holder_tuple(lconn, rec["owner_label"], clock()) != (h["pane_id"], h["pane_birth"], h["session_digest"],
                                                                       rec["expected_generation"]):
                raise Refused("lease_holder_mismatch")                  # floor must ALREADY be live -- never claimed here
            window(dec, clock(), key="standing_window_s")               # revalidation 2: before issue
            same_identity(resolve, rec)
            insert_standing_grant(store, dec, exp)
        except Refused as exc:
            print(f"refused:{exc}")
            return 2
        except Exception as exc:  # noqa: BLE001  after the prior-use/identity checks passed
            st = standing_grant_state(auth_db, dec, exp)
            if st == "present":
                print(f"issued:{rec['auth_id']} (after error_{type(exc).__name__}; verified in store)")
                return 0
            print(f"issue_uncertain:error_{type(exc).__name__}:store_{st}")
            return 6
    finally:
        for c in (lconn, store):
            try:
                c.close()
            except Exception:  # noqa: BLE001
                pass
    print(f"issued:{rec['auth_id']}")
    return 0


def main(argv=None, resolve=None, now=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["build-form"]:
        return build_main(argv[1:], resolve=resolve)
    if argv[:1] == ["issue-standing"]:
        return issue_standing_main(argv[1:], resolve=resolve, now=now)
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
        lconn = ol.open_rw_checked(lease_db, require_table="owner_leases")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    except ol.SchemaMigrationRequired as exc:
        print(f"refused:schema_migration_required:{exc.cur}->{exc.target}:owner-lease-migrate.py --db {lease_db} --apply")
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
            prev_gen = rec.get("expected_prev_generation", 0)
            try:
                if prev_gen == 0:
                    gen = ol.claim_initial(lconn, rec["owner_label"], h["pane_id"], h["pane_birth"], rec["lease_ttl_s"],
                                           h["session_digest"], now=clock())
                else:
                    ph = rec["expected_prev_holder"]
                    gen = ol.claim_successor(lconn, rec["owner_label"], prev_gen, ph["pane_id"], ph["pane_birth"],
                                             ph["session_digest"], h["pane_id"], h["pane_birth"], rec["lease_ttl_s"],
                                             h["session_digest"], now=clock())
            except ol.LeaseConflict:
                raise Refused("not_initial") from None
            except ol.SuccessorRefused as exc:
                raise Refused(f"successor_{exc.code}") from None
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
            if ol.holder_tuple(lconn, rec["owner_label"], clock()) != (h["pane_id"], h["pane_birth"], h["session_digest"],
                                                                       rec["expected_generation"]):
                raise Refused("lease_holder_mismatch")
            insert_grant(store, dec, exp)
        except BaseException as exc:  # noqa: BLE001  after the claim: classify by what the store says
            reason = str(exc) if isinstance(exc, Refused) else f"error_{type(exc).__name__}"
            st = grant_state(auth_db, dec, exp)
            if st == "present":
                print(f"issued:{rec['auth_id']}:gen{rec['expected_generation']} (after {reason}; verified in store)")
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
    print(f"issued:{rec['auth_id']}:gen{rec['expected_generation']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
