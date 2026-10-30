#!/usr/bin/env python3
"""R12e (tmp/in/r12/QUEUE-RID.md): owner-dispatch-issue.py build-form's new
--queue-item-id flag must make a queue-bound grant's request_id structurally
equal to queue_supervisor.rid_for(label, item_id) -- the gap
tmp/out/r12/REPORT-r12d-queue-rid.md reported (a grant built with an
arbitrary --request-id is silently, permanently unconsumable via the real
queue path).

End to end through the REAL CLI, not a hand-inserted auth row (unlike
verify-queue-supervisor-e2e.py's test-only `grant()` issuer, which already
hardcodes the correct request_id and therefore cannot see this gap):
build-form -> (simulated operator approval, same mechanics as
verify-owner-dispatch.py's decision()/run()) -> issue (owner-dispatch-
issue.py main(), the real CLI) -> a queue item -> queue_supervisor.tick_lane()
driving the REAL lib.owner_dispatch.Dispatcher (via queue-supervisor.py's
GrantDispatch, exactly as production queue-supervisor.py wires it) ->
lib.owner_dispatch_auth.consume(). oda.consume()/consume_standing() are not
imported for their equality logic here -- only exercised through the real
call chain, never monkeypatched.

Disposable temp stores only; no live state, no launchctl, no network."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_dispatch as od  # noqa: E402
import owner_dispatch_auth as oda  # noqa: E402
import owner_lease as ol  # noqa: E402
import owner_lease_delivery as old  # noqa: E402
import queue_supervisor as qs  # noqa: E402
import result_availability as ra  # noqa: E402

spec = importlib.util.spec_from_file_location("odissue_ridbind", HERE / "owner-dispatch-issue.py")
odi = importlib.util.module_from_spec(spec); spec.loader.exec_module(odi)
spec2 = importlib.util.spec_from_file_location("qscli_ridbind", HERE / "queue-supervisor.py")
qscli = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(qscli)

FAILS: list[str] = []


def case(name, ok):
    print(("OK   " if ok else "FAIL ") + name)
    if not ok:
        FAILS.append(name)


LABEL = "proj-ridbind"
PROJECT = "tntpgh/proj-ridbind"
TTL = 3600
T0 = 1_800_000_000.0
PANE_ID, PANE_BIRTH = "wRB:p1", "term_ridbind"
SESS = hashlib.sha256(b"ridbind-session").hexdigest()
REG = {LABEL: (PANE_ID, PANE_BIRTH, SESS)}
reg_ok = REG.get
body = b"READ-ONLY: ridbind fixture request. Write nothing.\n"
TMPBASE = Path(os.path.realpath(HERE / "tmp" / "r12e_tmpdir"))
TMPBASE.mkdir(parents=True, exist_ok=True)


def setup():
    """One disposable store set: lease db (owner registered, NO pre-acquired
    lease -- odi.main()'s issue step calls ol.claim_initial() itself, which
    refuses (not_initial) if a lease already exists; the fix round's
    build-form step only RESOLVES identity via the registry callable, it
    does not touch the lease db), auth db, availability root, delivery
    gate, pinned forms root, a request file. Mirrors verify-owner-
    dispatch.py's env()/setup() and verify-queue-supervisor-e2e.py's
    module-level store construction."""
    d = Path(os.path.realpath(tempfile.mkdtemp(dir=str(TMPBASE))))
    root = d / "root"; root.mkdir()
    (d / "journal").mkdir()
    (d / "state" / "forms").mkdir(parents=True)
    lease_db = str(d / "lease.db")
    lc = ol.connect(lease_db); ol.migrate(lc)
    ol.register_owner(lc, LABEL, PROJECT, max_open=1, now=T0)  # build_main() always rec["max_open"]=1
    os.chmod(lease_db, 0o600)
    adb = d / "auth.db"
    store = sqlite3.connect(str(adb), isolation_level=None, timeout=10)
    oda.migrate(store)
    os.chmod(adb, 0o600)
    av = ra.Availability(str(d / "ra.db"), {LABEL: str(root)}, str(d / "journal"))
    gate = old.DeliveryGate(lease_db)
    rq = d / "req"; rq.mkdir(); (rq / "req.txt").write_bytes(body)
    return d, lc, store, lease_db, adb, av, gate, rq


ISSUE_ENV_KEYS = ("HERDR_OWNER_DISPATCH_ISSUE", "HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DELIVERY",
                  "HERDR_OWNER_LEASE_DB", "HERDR_OWNER_DISPATCH_AUTH_DB")
REAL_STATE_ROOT = odi.STATE_ROOT


def build_and_issue(d, lease_db, adb, rq, *, auth_id, queue_item_id=None, request_id=None, fid_tag):
    """build-form (real CLI) -> simulated operator approval (same mechanics
    as verify-owner-dispatch.py's decision(): the approval record is
    recovered from build-form's OWN embedded script tag, never reconstructed
    by hand, so this exercises exactly what a browser round-trip would see)
    -> issue (odi.main(), the real CLI). Returns (build_rc, build_out,
    issue_rc, issue_out)."""
    out_path = d / f"form-{fid_tag}.html"
    build_argv = ["--label", LABEL, "--project", PROJECT, "--request-dir", str(rq), "--request-name", "req.txt",
                  "--auth-id", auth_id, "--out", str(out_path), "--manifest", "result.md"]
    if queue_item_id is not None:
        build_argv += ["--queue-item-id", queue_item_id]
    if request_id is not None:
        build_argv += ["--request-id", request_id]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        build_rc = odi.build_main(build_argv, resolve=reg_ok, now=T0)
    build_out = buf.getvalue().strip()
    if build_rc != 0:
        return build_rc, build_out, None, None
    html = out_path.read_bytes()
    embedded = odi.EMBED.findall(html)[0]
    sha = hashlib.sha256(embedded).hexdigest()
    fid = f"20261030T0000{fid_tag:02d}-91{fid_tag:02d}"
    (d / "state" / "forms" / f"{fid}.html").write_bytes(html)
    (d / "state" / "forms" / f"{fid}.json").write_text(json.dumps(
        {"id": fid, "status": "answered", "answers": {"decision": "approve", "approval_sha256": sha},
         "answered_at": int((T0 - 60) * 1000)}))
    env = {"HERDR_OWNER_DISPATCH_ISSUE": "1", "HERDR_OWNER_LEASE_WRITER": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
           "HERDR_OWNER_LEASE_DB": lease_db, "HERDR_OWNER_DISPATCH_AUTH_DB": str(adb)}
    odi.STATE_ROOT = os.path.realpath(d / "state")
    saved = {k: os.environ.get(k) for k in ISSUE_ENV_KEYS}
    for k in saved:
        os.environ.pop(k, None)
    os.environ.update(env)
    buf2 = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf2):
            issue_rc = odi.main(["--form-id", fid, "--request-dir", str(rq)], resolve=reg_ok, now=T0)
    finally:
        odi.STATE_ROOT = REAL_STATE_ROOT
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    return build_rc, build_out, issue_rc, buf2.getvalue().strip()


def auth_row(adb, auth_id):
    c = sqlite3.connect(str(adb))
    row = c.execute("SELECT status, request_id, used_count FROM owner_dispatch_auth WHERE auth_id=?",
                    (auth_id,)).fetchone()
    c.close()
    return row


def run_tick(d, lease_db, adb, queue_items, tag):
    qroot = d / f"queue-{tag}"; qroot.mkdir()
    (qroot / f"{LABEL}.queue.json").write_text(json.dumps(queue_items))
    av = ra.Availability(str(d / "ra.db"), {LABEL: str(d / "root")}, str(d / "journal"))
    gate = old.DeliveryGate(lease_db)
    store = sqlite3.connect(str(adb), isolation_level=None, timeout=10)
    dispatcher = qscli.GrantDispatch(gate, av, lambda lb, h, t: True, reg_ok, store)
    lane = qs.Lane(qroot, LABEL)
    out = qs.tick_lane(lane, dispatcher, lambda lb, rid: False, lambda lb, rid: None,
                       lambda lb, item, reason: None, lambda lb, rid: qscli.journal_state(d / "journal", lb, rid))
    av.close(); store.close()
    return out


# --- Scenario 1 (POSITIVE): build-form --queue-item-id X -> issue -> queue
# item {id: X, auth_id, manifest} -> tick -> consume succeeds, request_id ==
# q-<label>-X, grant consumed exactly once. ---
d1, lc1, store1, ldb1, adb1, av1, gate1, rq1 = setup()
auth_id1 = "auth-ridbind-pos"
b_rc1, b_out1, i_rc1, i_out1 = build_and_issue(d1, ldb1, adb1, rq1, auth_id=auth_id1, queue_item_id="i1", fid_tag=1)
case("SCENARIO 1 setup: build-form --queue-item-id i1 succeeds and issues a granted auth row",
     b_rc1 == 0 and i_rc1 == 0 and i_out1.startswith("issued:"))
row1_before = auth_row(adb1, auth_id1)
case("SCENARIO 1 setup: the issued grant's request_id is EXACTLY q-<label>-i1, never a free-form value",
     row1_before is not None and row1_before[0] == "granted" and row1_before[1] == qs.rid_for(LABEL, "i1"))
tick1 = run_tick(d1, ldb1, adb1, [{"id": "i1", "request": body.decode(), "manifest": ["result.md"],
                                   "auth_id": auth_id1}], tag=1)
row1_after = auth_row(adb1, auth_id1)
case("SCENARIO 1 (POSITIVE): queue-supervisor tick dispatches i1 -- consume succeeded through the real CLI-built grant",
     tick1 == "dispatched:i1")
case("SCENARIO 1: the grant is consumed exactly once (status granted -> consumed, used_count still the "
     "single-use default 0 -- used_count is a STANDING-grant-only counter per lib/owner_dispatch_auth.py:168,"
     "345; a single-use grant's own 'used once' proof is status==consumed, checked above) and request_id "
     "unchanged at q-<label>-i1",
     row1_after is not None and row1_after[0] == "consumed" and row1_after[1] == qs.rid_for(LABEL, "i1"))
lc1.close()

# --- Scenario 2 (NEGATIVE, unchanged refusal): a grant issued with a plain
# --request-id (not derived from rid_for) cannot be consumed via the queue. ---
d2, lc2, store2, ldb2, adb2, av2, gate2, rq2 = setup()
auth_id2 = "auth-ridbind-plainrid"
b_rc2, b_out2, i_rc2, i_out2 = build_and_issue(d2, ldb2, adb2, rq2, auth_id=auth_id2,
                                               request_id="arbitrary-operator-slug", fid_tag=2)
case("SCENARIO 2 setup: build-form --request-id (plain, free-form) still works unchanged and issues",
     b_rc2 == 0 and i_rc2 == 0 and i_out2.startswith("issued:"))
tick2 = run_tick(d2, ldb2, adb2, [{"id": "i1", "request": body.decode(), "manifest": ["result.md"],
                                   "auth_id": auth_id2}], tag=2)
row2_after = auth_row(adb2, auth_id2)
case("SCENARIO 2 (NEGATIVE, reproduces REPORT-r12d-queue-rid.md, unchanged): a plain --request-id grant is "
     "held_consumed by the queue -- request_id 'arbitrary-operator-slug' != q-<label>-i1, oda.consume() refuses "
     "auth_mismatch, exactly the reported gap -- --queue-item-id exists precisely so an operator need not hit this",
     tick2 == "frozen:held_consumed:i1" and row2_after is not None and row2_after[0] == "granted")
lc2.close()

# --- Scenario 3 (NEGATIVE): a queue item id that differs from the signed
# one is refused -- the grant was built for queue-item-id i1, but queued
# under a different item id i2 (auth_id still points at the i1 grant). ---
d3, lc3, store3, ldb3, adb3, av3, gate3, rq3 = setup()
auth_id3 = "auth-ridbind-mismatch"
b_rc3, b_out3, i_rc3, i_out3 = build_and_issue(d3, ldb3, adb3, rq3, auth_id=auth_id3, queue_item_id="i1", fid_tag=3)
case("SCENARIO 3 setup: build-form --queue-item-id i1 issues (request_id == q-<label>-i1)",
     b_rc3 == 0 and i_rc3 == 0 and i_out3.startswith("issued:"))
tick3 = run_tick(d3, ldb3, adb3, [{"id": "i2", "request": body.decode(), "manifest": ["result.md"],
                                   "auth_id": auth_id3}], tag=3)
row3_after = auth_row(adb3, auth_id3)
case("SCENARIO 3 (NEGATIVE): queuing the i1-signed grant under a DIFFERENT item id (i2) is refused -- rid_for "
     "computes q-<label>-i2 for the tick, which != the grant's stored q-<label>-i1, oda.consume() refuses "
     "auth_mismatch; the grant stays granted, never silently consumed under the wrong item",
     tick3 == "frozen:held_consumed:i2" and row3_after is not None and row3_after[0] == "granted")
lc3.close()

# --- Mutual exclusivity + required-ness of --request-id / --queue-item-id ---
d4, lc4, store4, ldb4, adb4, av4, gate4, rq4 = setup()
buf4 = io.StringIO()
with contextlib.redirect_stdout(buf4):
    rc4a = odi.build_main(["--label", LABEL, "--project", PROJECT, "--request-dir", str(rq4), "--request-name",
                           "req.txt", "--auth-id", "auth-both", "--out", str(d4 / "both.html"), "--manifest",
                           "result.md", "--request-id", "x", "--queue-item-id", "i1"], resolve=reg_ok, now=T0)
case("MUTUAL EXCLUSION: --request-id and --queue-item-id together is refused before any write",
     rc4a == 2 and buf4.getvalue().strip() == "refused:request_id_and_queue_item_id_mutually_exclusive"
     and not (d4 / "both.html").exists())
buf4b = io.StringIO()
with contextlib.redirect_stdout(buf4b):
    rc4b = odi.build_main(["--label", LABEL, "--project", PROJECT, "--request-dir", str(rq4), "--request-name",
                           "req.txt", "--auth-id", "auth-neither", "--out", str(d4 / "neither.html"), "--manifest",
                           "result.md"], resolve=reg_ok, now=T0)
case("REQUIRED: neither --request-id nor --queue-item-id given is refused before any write",
     rc4b == 2 and buf4b.getvalue().strip() == "refused:request_id_or_queue_item_id_required"
     and not (d4 / "neither.html").exists())
lc4.close()

# --- R12f (tmp/in/r12/QUEUE-RID-VALIDATE.md): --queue-item-id and its
# derived rid are validated BEFORE any approval bytes are built or hashed,
# reusing queue_supervisor's OWN alphabets (lib/queue_supervisor.py:71
# _ID_RE <=64 chars, :123 _RID_RE <=100 chars -- the SAME patterns
# tick_lane() itself checks before ever consuming a grant). Negative cases
# assert no form file (and so no approval) exists afterwards; boundary
# positives assert the opposite -- build-form SUCCEEDS at the limit, not
# one past it (the brief's "no form file" wording applies to the negative
# cases; a boundary POSITIVE that produced no form would contradict its
# own purpose of proving the limit is inclusive, not exclusive). ---
LONGLABEL = "x" * 48  # LABEL_RE max length (lib/owner_lease.py:82, ^[a-z0-9][a-z0-9-]{0,47}$)


def build_only(tag, *, label, resolve, queue_item_id=None, request_id=None):
    d = Path(os.path.realpath(tempfile.mkdtemp(dir=str(TMPBASE))))
    rq = d / "req"; rq.mkdir(); (rq / "req.txt").write_bytes(body)
    out_path = d / f"form-{tag}.html"
    argv = ["--label", label, "--project", f"tntpgh/{label}", "--request-dir", str(rq), "--request-name", "req.txt",
           "--auth-id", f"auth-{tag}", "--out", str(out_path), "--manifest", "result.md"]
    if queue_item_id is not None:
        argv += ["--queue-item-id", queue_item_id]
    if request_id is not None:
        argv += ["--request-id", request_id]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = odi.build_main(argv, resolve=resolve, now=T0)
    return rc, buf.getvalue().strip(), out_path


rc5a, out5a, path5a = build_only("badchar", label=LABEL, resolve=reg_ok, queue_item_id="bad id")
case("R12f NEGATIVE: a queue item id with a bad character (space, outside _ID_RE's "
     "[A-Za-z0-9_-]) is refused before any approval bytes are built, no form written",
     rc5a == 2 and out5a == "refused:queue_item_id_invalid" and not path5a.exists())

id65 = "a" * 65
rc5b, out5b, path5b = build_only("id65", label=LABEL, resolve=reg_ok, queue_item_id=id65)
case("R12f NEGATIVE: a 65-character queue item id (_ID_RE caps at 64) is refused, no form written",
     rc5b == 2 and out5b == "refused:queue_item_id_invalid" and not path5b.exists())

id_exceed = "y" * 50  # len(LONGLABEL)=48 + len(id)=50 + len("q--")=3 -> rid 101 chars, > _RID_RE's 100
rc5c, out5c, path5c = build_only("ridexceed", label=LONGLABEL, resolve={LONGLABEL: (PANE_ID, PANE_BIRTH, SESS)}.get,
                                 queue_item_id=id_exceed)
case("R12f NEGATIVE: a VALID id (passes _ID_RE) whose derived rid exceeds 100 chars (a long label) is "
     "refused before any approval bytes are built, no form written -- id alone being valid is not enough",
     rc5c == 2 and out5c == "refused:queue_item_id_rid_invalid" and not path5c.exists()
     and len(qs.rid_for(LONGLABEL, id_exceed)) == 101)

id64 = "w" * 64
rc5d, out5d, path5d = build_only("id64", label=LABEL, resolve=reg_ok, queue_item_id=id64)
case("R12f BOUNDARY POSITIVE: a 64-character queue item id (_ID_RE's own limit, inclusive) is ACCEPTED, "
     "form written",
     rc5d == 0 and out5d.startswith("built:") and path5d.exists())

id_rid100 = "z" * 49  # len(LONGLABEL)=48 + len(id)=49 + len("q--")=3 -> rid exactly 100
rc5e, out5e, path5e = build_only("rid100", label=LONGLABEL, resolve={LONGLABEL: (PANE_ID, PANE_BIRTH, SESS)}.get,
                                 queue_item_id=id_rid100)
case("R12f BOUNDARY POSITIVE: a derived rid of exactly 100 chars (_RID_RE's own limit, inclusive) is "
     "ACCEPTED, form written",
     rc5e == 0 and out5e.startswith("built:") and path5e.exists()
     and len(qs.rid_for(LONGLABEL, id_rid100)) == 100)


print(f"{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failing")
sys.exit(1 if FAILS else 0)
