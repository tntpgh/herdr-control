#!/usr/bin/env python3
"""Offline proofs for the factory-on code (.handoffs/FACTORY-ON-PLAN.md §4):
  G3 owner-dispatch-issue.py build-standing-form
  G4 queue-supervisor.py kill switch
  G5 factory-status.py
Disposable temp state only (temp sqlite DBs, temp queue roots, temp plists,
a temp forms dir); fixtures come from verify-owner-dispatch.py. No herdr, no
pane, no network, no live store, no launchctl."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import shutil
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


V = load("vod", "verify-owner-dispatch.py")      # fixtures: env(), acquire(), KB, PANE, SESS
ODI = load("odi_factory", "owner-dispatch-issue.py")
QSUP = load("qsup_factory", "queue-supervisor.py")
FS = load("fstatus_factory", "factory-status.py")
oda, ol = V.oda, V.ol
KB, PANE, SESS = V.KB, V.PANE, V.SESS
FAILS: list[str] = []
NOW = float(int(time.time()))
REG = {KB: (*PANE[KB], SESS[KB])}.get


def case(name, ok):
    print(("OK   " if ok else "FAIL ") + name)
    if not ok:
        FAILS.append(name)


def quiet(fn, *a, **k):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn(*a, **k)
    return rc, buf.getvalue().strip()


def lane_fixture(d: Path, items, live=True):
    """Lease DB with KB registered (+ live lease), migrated 0600 auth store, queue file."""
    d.mkdir(mode=0o700)
    lc, av, _roots, lease_db = V.env(d)
    av.close()
    os.chmod(lease_db, 0o600)
    if live:
        V.acquire(lc, KB, now=NOW - 10)
    adb = d / "auth.db"
    c = sqlite3.connect(str(adb), isolation_level=None)
    oda.migrate(c)
    c.close()
    os.chmod(adb, 0o600)
    qd = d / "queue"
    qd.mkdir(mode=0o700)
    (qd / f"{KB}.queue.json").write_text(json.dumps(items))
    proj = lc.execute("SELECT project FROM owner_projects WHERE label=?", (KB,)).fetchone()[0]
    return lc, lease_db, adb, qd, proj


ITEMS = [{"id": "i1", "request": "do one\n", "auth_id": "stand-kb", "manifest": ["result.md"], "cost_cents": 30},
         {"id": "i2", "request": "do two\n", "auth_id": "stand-kb", "manifest": ["result.md"], "cost_cents": 40},
         {"id": "i3", "request": "later\n", "auth_id": "other", "hold": True}]


def build(d, lease_db, qd, proj, *extra, resolve=REG, auth="stand-kb", out="form.html", qname=f"{KB}.queue.json"):
    argv = ["build-standing-form", "--label", KB, "--project", proj, "--queue-dir", str(qd), "--queue-name", qname,
            "--auth-id", auth, "--lease-db", lease_db, "--spend-cap-cents", "100", "--out", str(d / out), *extra]
    return quiet(ODI.main, argv, resolve=resolve, now=NOW)


def build_cases(base: Path) -> None:
    # --- round trip: what build-standing-form writes is exactly what the REAL issuer accepts ---
    d = base / "b1"
    lc, ldb, adb, qd, proj = lane_fixture(d, ITEMS)
    rc, out = build(d, ldb, qd, proj, "--standing-window-s", "3600")
    html = (d / "form.html").read_bytes() if (d / "form.html").exists() else b""
    emb = ODI.EMBED.findall(html)
    rec = json.loads(emb[0]) if len(emb) == 1 else {}
    qbytes = (qd / f"{KB}.queue.json").read_bytes()
    case("BUILD: rc 0, prints built:<out>:html_sha256=…:approval_sha256=<sha of embedded record>",
         rc == 0 and out == (f"built:{d / 'form.html'}:html_sha256={hashlib.sha256(html).hexdigest()}"
                             f":approval_sha256={hashlib.sha256(emb[0]).hexdigest()}"))
    case("BUILD: page is byte-identical to render_standing_form(record) and the record validates",
         html == ODI.render_standing_form(rec) and ODI.validate_standing_approval(rec) is rec)
    case("BUILD: binds registry holder, LIVE generation, exact queue sha and canonical items",
         rec.get("expected_holder") == {"pane_id": PANE[KB][0], "pane_birth": PANE[KB][1], "session_digest": SESS[KB]}
         and rec.get("expected_generation") == ol.holder_tuple(lc, KB, NOW)[3]
         and rec.get("queue_sha256") == hashlib.sha256(qbytes).hexdigest()
         and rec.get("queue_items") == ODI.canonical_queue_items(qbytes))
    case("BUILD: --item-cap default = number of DISPATCH items (2; the held item is not counted)",
         rec.get("item_cap") == 2 and rec.get("spend_cap_cents") == 100 and rec.get("standing_window_s") == 3600)
    case("BUILD: page is private (0600)", (d / "form.html").stat().st_mode & 0o777 == 0o600)
    # answer the page exactly as formserve records it, then run the REAL issue-standing + consume_standing
    forms = d / "state" / "forms"
    forms.mkdir(parents=True, mode=0o700)
    fid = "20261030T230000-4242"
    (forms / f"{fid}.html").write_bytes(html)
    (forms / f"{fid}.json").write_text(json.dumps({"id": fid, "status": "answered", "answered_at": int((NOW - 60) * 1000),
                                                   "answers": {"decision": "approve",
                                                               "approval_sha256": hashlib.sha256(emb[0]).hexdigest()}}))
    keys = {"HERDR_OWNER_DISPATCH_ISSUE": "1", "HERDR_OWNER_LEASE_WRITER": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
            "HERDR_OWNER_LEASE_DB": ldb, "HERDR_OWNER_DISPATCH_AUTH_DB": str(adb)}
    saved = {k: os.environ.get(k) for k in keys}
    real_root, ODI.STATE_ROOT = ODI.STATE_ROOT, os.path.realpath(d / "state")
    os.environ.update(keys)
    try:
        rci, outi = quiet(ODI.main, ["issue-standing", "--form-id", fid, "--queue-dir", str(qd),
                                     "--queue-name", f"{KB}.queue.json"], resolve=REG, now=NOW)
    finally:
        ODI.STATE_ROOT = real_root
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    case("ROUND TRIP: the REAL issue-standing accepts the built page -> issued:stand-kb",
         (rci, outi) == (0, "issued:stand-kb"))
    ac = sqlite3.connect(str(adb), isolation_level=None)
    child = oda.consume_standing(ac, "stand-kb", label=KB, project=proj, holder=ol.holder_tuple(lc, KB, NOW),
                                 request_id="q-knowledge-base-i1", body_sha256="b" * 64, manifest=["result.md"],
                                 now=NOW, queue_sha256=hashlib.sha256(qbytes).hexdigest(), cost_cents=30)
    case("ROUND TRIP: the issued row dispatches a child through the REAL consume_standing",
         isinstance(child, dict) and child.get("request_id") == "q-knowledge-base-i1")
    ac.close()
    page_before = (d / "form.html").read_bytes()
    rc2, out2 = build(d, ldb, qd, proj)
    case("BUILD: never overwrites an existing page (refused:out_exists, page unchanged)",
         (rc2, out2) == (2, "refused:out_exists") and (d / "form.html").read_bytes() == page_before)
    lc.close()


def refusal_cases(base: Path) -> None:
    n = [0]

    def fresh(items=ITEMS, live=True):
        n[0] += 1
        d = base / f"r{n[0]}"
        lc, ldb, adb, qd, proj = lane_fixture(d, items, live=live)
        return d, lc, ldb, qd, proj

    def refused(name, expect, items=ITEMS, live=True, **kw):
        d, lc, ldb, qd, proj = fresh(items, live)
        extra = kw.pop("extra", ())
        if kw.pop("bad_project", False):
            proj = "tntpgh/elsewhere"
        rc, out = build(d, ldb, qd, proj, *extra, **kw)
        case(f"REFUSE {name}: rc 2 '{expect}', no page written",
             rc == 2 and out == expect and not (d / "form.html").exists())
        lc.close()

    refused("dispatch item naming another auth_id (would freeze the lane at dispatch)",
            "refused:queue_item_auth_id_mismatch", auth="some-other-grant")
    refused("queue with only held items", "refused:queue_no_dispatch_items",
            items=[{"id": "h1", "request": "x\n", "auth_id": "stand-kb", "hold": True}])
    refused("unpriced dispatch item (would freeze standing_cost_missing at dispatch)",
            "refused:queue_item_cost_missing",
            items=[{"id": "u1", "request": "x\n", "auth_id": "stand-kb"}])
    refused("negative --item-cap", "refused:standing_approval_field_item_cap", extra=("--item-cap", "-1"))
    refused("queue the real validator rejects", "refused:queue_invalid",
            items=[{"id": "bad id!", "request": "x\n", "auth_id": "stand-kb"}])
    refused("missing queue file", "refused:queue_unreadable", qname="nope.queue.json")
    refused("no live lease (expired / never claimed)", "refused:live_generation_unresolved", live=False)
    refused("registry identity differs from the live lease holder", "refused:live_generation_unresolved",
            resolve={KB: (PANE[KB][0], "term_other", SESS[KB])}.get)
    refused("registry identity unresolved", "refused:identity_unresolved", resolve=lambda _l: None)
    refused("owner_projects row names a different project", "refused:owner_project_mismatch", bad_project=True)
    refused("window above MAX_STANDING_WINDOW_S (24h)", "refused:standing_approval_field_standing_window_s",
            extra=("--standing-window-s", str(ODI.MAX_STANDING_WINDOW_S + 1)))


def kill_switch_cases(base: Path) -> None:
    sw = base / "state" / "owner-dispatch.revoked"
    sw.parent.mkdir(parents=True)
    QSUP.KILL_SWITCH = sw
    on = {"HERDR_QUEUE_SUPERVISOR": "1", "HERDR_OWNER_DISPATCH": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
          "HERDR_QUEUE_SUPERVISOR_ROOT": str(base / "q"), "HERDR_QUEUE_SUPERVISOR_LANES": KB,
          "HERDR_OWNER_LEASE_DB": str(base / "nope-lease.db"), "HERDR_OWNER_DISPATCH_AUTH_DB": str(base / "nope-auth.db")}
    rc, out = quiet(QSUP.main, on)
    case("KILL SWITCH absent: a configured pass proceeds to open the stores (here: refused, missing auth store)",
         rc == 4 and out.startswith("refused:"))
    sw.write_text("")
    rc, out = quiet(QSUP.main, on)
    case("KILL SWITCH present: stopped:kill_switch <path>, rc 0, before any store is opened",
         (rc, out) == (0, f"stopped:kill_switch {sw}"))
    rc, out = quiet(QSUP.main, {})
    case("KILL SWITCH present but supervisor flag off: still exactly 'off' (unchanged behavior)", (rc, out) == (0, "off"))
    sw.unlink()
    sw.symlink_to(base / "dangling-target")
    case("KILL SWITCH as a dangling symlink still stops (presence, not target)", quiet(QSUP.main, on)[1].startswith("stopped:"))
    sw.unlink()
    locked = base / "locked"
    locked.mkdir()
    QSUP.KILL_SWITCH = locked / "owner-dispatch.revoked"
    os.chmod(locked, 0)
    try:
        case("KILL SWITCH unknowable (state dir unreadable) -> stopped, never 'absent'", QSUP.kill_switch_engaged())
    finally:
        os.chmod(locked, 0o700)
    QSUP.KILL_SWITCH = sw
    case("KILL SWITCH removed: the next pass resumes (no restart)", quiet(QSUP.main, on)[1].startswith("refused:"))


def status_cases(base: Path) -> None:
    d = base / "fs"
    lc, ldb, adb, qd, proj = lane_fixture(d, ITEMS)
    sw = base / "fs-state" / "owner-dispatch.revoked"
    sw.parent.mkdir(parents=True)
    FS.QSUP.KILL_SWITCH = sw
    env = {"HERDR_QUEUE_SUPERVISOR": "1", "HERDR_OWNER_DISPATCH": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
           "HERDR_RESULT_AVAILABILITY": "1", "HERDR_QUEUE_SUPERVISOR_ROOT": str(qd),
           "HERDR_QUEUE_SUPERVISOR_LANES": KB, "HERDR_OWNER_LEASE_DB": ldb, "HERDR_OWNER_DISPATCH_AUTH_DB": str(adb),
           "HERDR_QUEUE_SUPERVISOR_STANDING": "1"}
    hub, remote = d / "hub.plist", d / "remote.plist"

    def plists(e, renew="1"):
        hub.write_bytes(plistlib.dumps({"Label": "com.herdr-control.hub", "EnvironmentVariables": e}))
        remote.write_bytes(plistlib.dumps({"EnvironmentVariables": {"HERDR_OWNER_LEASE_RENEW": renew}}))

    def run():
        rc, out = quiet(FS.main, ["--json", "--hub-plist", str(hub), "--remote-mcp-plist", str(remote)], now=NOW)
        st = json.loads(out)
        return rc, st, (st["lanes"][0] if st["lanes"] else {})

    def digest():
        return [hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in (ldb, adb, qd / f"{KB}.queue.json")]

    plists(env)
    before = digest()
    rc, st, lane = run()
    case("STATUS: standing on, no standing grant -> BLOCKED no_standing_grant:none, exit 1",
         rc == 1 and lane["verdict"] == "BLOCKED" and lane["blockers"] == ["no_standing_grant:none"]
         and lane["lease"]["state"] == "live" and lane["queue"]["pending"] == 2 and st["lease_renew"] is True)
    qsha = hashlib.sha256((qd / f"{KB}.queue.json").read_bytes()).hexdigest()
    ac = sqlite3.connect(str(adb), isolation_level=None)
    ac.execute("INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,session_digest,"
               "lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,decided_at,expires_at,"
               "kind,queue_sha256,item_cap) VALUES ('stand-kb',?,?,?,?,?,?,1,'','','[]','f','f','granted','t',?,"
               "'standing',?,2)", (oda.PROTOCOL, KB, proj, *PANE[KB], SESS[KB], NOW + 600, qsha))
    ac.close()
    before = digest()
    rc, st, lane = run()
    case("STATUS: live lease + unexpired standing grant bound to this queue -> RUNNABLE, exit 0",
         rc == 0 and lane["verdict"] == "RUNNABLE" and lane["grant"]["auth_id"] == "stand-kb")
    case("STATUS: read-only -- lease DB, auth DB and queue bytes unchanged by the run", digest() == before)
    sw.write_text("")
    rc, st, lane = run()
    case("STATUS: kill switch -> shared blocker, lane BLOCKED, exit 1",
         rc == 1 and st["shared_blockers"] == [f"kill_switch:{sw}"] and lane["verdict"] == "BLOCKED")
    sw.unlink()
    (qd / f"{KB}.queue.json").write_text(json.dumps(ITEMS[:1]))
    rc, st, lane = run()
    case("STATUS: queue edited after the grant -> no_standing_grant:queue_sha_mismatch",
         lane["blockers"] == ["no_standing_grant:queue_sha_mismatch"])
    (qd / f"{KB}.ledger.jsonl").write_text(json.dumps({"kind": "dispatched", "item": "i1", "at": NOW}) + "\n")
    rc, st, lane = run()
    case("STATUS: an item in flight -> RUNNING (waiting on its accepted result), exit 0",
         rc == 0 and lane["verdict"] == "RUNNING" and lane["queue"]["in_flight"] == "i1")
    (qd / f"{KB}.ledger.jsonl").write_text(json.dumps({"kind": "done", "item": "i1", "at": NOW}) + "\n")
    rc, st, lane = run()
    case("STATUS: every item settled -> BLOCKED queue_empty", "queue_empty" in lane["blockers"])
    (qd / f"{KB}.ledger.jsonl").unlink()
    single = dict(env)
    single.pop("HERDR_QUEUE_SUPERVISOR_STANDING")
    plists(single, renew="0")
    (qd / f"{KB}.queue.json").write_text(json.dumps([{"id": "s1", "request": "x\n", "auth_id": "one-shot"}]))
    rc, st, lane = run()
    case("STATUS: single-use mode, next item's grant missing -> no_grant:missing; renew off reported",
         lane["blockers"] == ["no_grant:missing"] and st["lease_renew"] is False and st["standing"] is False)
    V.insert_grant(sqlite3.connect(str(adb), isolation_level=None), "one-shot", label=KB, project=proj,
                   holder=(*PANE[KB], SESS[KB], 1), rid="q-knowledge-base-s1", sha="a" * 64, manifest=[],
                   expires=NOW - 1)
    rc, st, lane = run()
    case("STATUS: single-use grant past expires_at -> no_grant:expired", lane["blockers"] == ["no_grant:expired"])
    lc.execute("UPDATE owner_leases SET expires_at=? WHERE label=?", ("2000-01-01T00:00:00Z", KB))
    rc, st, lane = run()
    case("STATUS: lease past expiry -> lease_expired:gen1 alongside the grant blocker",
         lane["lease"]["state"] == "expired" and "lease_expired:gen1" in lane["blockers"])
    off = {k: v for k, v in single.items() if k not in ("HERDR_QUEUE_SUPERVISOR", "HERDR_OWNER_DISPATCH_AUTH_DB")}
    plists(off)
    rc, st, _ = run()
    case("STATUS: supervisor off + store unconfigured -> both shared blockers, no lane opened",
         rc == 1 and "supervisor_off" in st["shared_blockers"]
         and "not_configured:HERDR_OWNER_DISPATCH_AUTH_DB" in st["shared_blockers"] and st["lanes"] == [])
    plist_cases(d, env)
    lc.close()


# The live remote-mcp plist's header comment carries `--` (install.sh --remote-mcp) on line 14:
# illegal in an XML comment, so plistlib/expat raised ExpatError and factory-status crashed, while
# launchd (CoreFoundation) loads the same file. The fixture puts that `--` on line 14 too.
SENTINEL = "SENTINEL_VALUE_7f3a"
CF_ONLY_PLIST = ('<?xml version="1.0" encoding="UTF-8"?>\n'
                 '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                 '<!-- com.herdr-control.remote-mcp\n' + "".join(f"\t\t     header line {n}\n" for n in range(4, 14))
                 + '\t\t     Render (install.sh --remote-mcp): /opt/homebrew/bin/python3.14 -> an\n'
                 '\t\t     explicit interpreter.\n-->\n<plist version="1.0">\n<dict>\n'
                 '  <key>EnvironmentVariables</key>\n  <dict>\n'
                 '    <key>HERDR_OWNER_LEASE_RENEW</key><string>1</string>\n'
                 f'    <key>SOME_TOKEN</key><string>{SENTINEL}</string>\n  </dict>\n</dict>\n</plist>\n')
BROKEN_PLIST = ('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
                f'  <key>EnvironmentVariables</key>\n  <dict>\n    <key>SOME_TOKEN</key><string>{SENTINEL} & x</string>\n')


def plist_cases(d: Path, env: dict) -> None:
    hub, remote = d / "p-hub.plist", d / "p-remote.plist"
    hub.write_bytes(plistlib.dumps({"EnvironmentVariables": env}))
    has_cf = shutil.which("plutil") is not None

    def run(*extra, h=hub, r=remote):
        rc, out = quiet(FS.main, [*extra, "--hub-plist", str(h), "--remote-mcp-plist", str(r)], now=NOW)
        return rc, out

    remote.write_text(CF_ONLY_PLIST)
    case("PLIST precondition: the fixture has `--` in its comment on line 14 and plistlib rejects it",
         "--remote-mcp" in CF_ONLY_PLIST.splitlines()[13] and _strict_fails(CF_ONLY_PLIST))
    rc, out = run("--json")
    st = json.loads(out)
    remote_blk = [b for b in st["shared_blockers"] if b.startswith("remote_mcp_plist_unreadable")]
    if has_cf:
        case("PLIST `--` in comment (live shape): no crash; read as launchd reads it -> lease_renew on, no blocker",
             st["lease_renew"] is True and remote_blk == [])
    else:
        case("PLIST `--` in comment, no plutil on this host: no crash; BLOCKED with the reason",
             remote_blk == ["remote_mcp_plist_unreadable:ExpatError:no_plutil"] and rc == 1)
    remote.write_text(BROKEN_PLIST)
    rc, out = run("--json")
    st = json.loads(out)
    case("PLIST unparseable by both parsers (raw '&', truncated): BLOCKED remote_mcp_plist_unreadable:ExpatError, exit 1",
         rc == 1 and any(b.startswith("remote_mcp_plist_unreadable:ExpatError") for b in st["shared_blockers"])
         and all(ln["verdict"] == "BLOCKED" for ln in st["lanes"]) and st["lease_renew"] is False)
    rc, out = run()
    case("PLIST unparseable, text mode: exit 1, reason shown, no env value echoed",
         rc == 1 and "remote_mcp_plist_unreadable:ExpatError" in out and SENTINEL not in out)
    rc, out = run("--json", r=d / "absent-remote.plist")
    st = json.loads(out)
    case("PLIST remote-mcp not installed: renewal off, not a blocker (unchanged)",
         st["lease_renew"] is False and not any("remote_mcp" in b for b in st["shared_blockers"]))
    hub.write_text(BROKEN_PLIST)
    remote.write_bytes(plistlib.dumps({"EnvironmentVariables": {"HERDR_OWNER_LEASE_RENEW": "1"}}))
    rc, out = run("--json")
    st = json.loads(out)
    case("PLIST hub unparseable: exit 1, the ONLY blocker is hub_plist_unreadable:<reason>, no lane opened",
         rc == 1 and len(st["shared_blockers"]) == 1
         and st["shared_blockers"][0].startswith("hub_plist_unreadable:ExpatError") and st["lanes"] == []
         and SENTINEL not in out)
    rc, out = run(h=d / "absent-hub.plist")
    case("PLIST hub missing: exit 1, hub_plist_unreadable:FileNotFoundError (text mode, no crash)",
         rc == 1 and "hub_plist_unreadable:FileNotFoundError" in out)


def _strict_fails(text: str) -> bool:
    try:
        plistlib.loads(text.encode())
    except Exception:  # noqa: BLE001 -- the precondition is "plistlib does not accept it", whatever it raises
        return True
    return False
    lc.close()


def main() -> int:
    base = Path(os.path.realpath(tempfile.mkdtemp()))
    try:
        build_cases(base)
        refusal_cases(base)
        kill_switch_cases(base)
        status_cases(base)
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print(f"{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failure(s)")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
