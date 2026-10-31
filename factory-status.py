#!/usr/bin/env python3
"""factory-status.py [--json] [--hub-plist P] [--remote-mcp-plist P]

READ-ONLY answer to "is the factory running, and if not, what is missing":
one verdict per queue-supervisor lane, plus the switches every lane shares.

Configuration comes from the INSTALLED hub plist, because the dispatch tick
(hub.py _queue_tick -> queue-supervisor.py) runs with that environment, not
with this shell's. Stores are opened read-only (owner_lease.open_ro; the auth
store via sqlite mode=ro). The queue and ledger are read through
lib/queue_supervisor.Lane / _lane_state, the same functions the tick uses.
Nothing here writes, claims, issues, renews or dispatches.

Lane verdicts:
  RUNNING   an item is in flight (waiting on its accepted result)
  RUNNABLE  the next tick would dispatch the next item
  BLOCKED   every reason is listed, not just the first
Exit: 0 every lane RUNNING/RUNNABLE; 1 anything BLOCKED, including a plist
neither plistlib nor plutil can parse (reported as a reason, never a crash).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from xml.parsers.expat import ExpatError

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_lease as ol  # noqa: E402
import queue_supervisor as qs  # noqa: E402

_spec = importlib.util.spec_from_file_location("queue_supervisor_cli", HERE / "queue-supervisor.py")
QSUP = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(QSUP)  # the ONE kill-switch definition, reused

AGENTS = Path.home() / "Library" / "LaunchAgents"
FLAGS = ("HERDR_OWNER_DISPATCH", "HERDR_OWNER_LEASE_DELIVERY", "HERDR_RESULT_AVAILABILITY")
PATHS = ("HERDR_QUEUE_SUPERVISOR_ROOT", "HERDR_OWNER_LEASE_DB", "HERDR_OWNER_DISPATCH_AUTH_DB")


class PlistUnreadable(Exception):
    """Reason only (an exception class name), never file content: plists hold env values."""


def plist_env(path: Path) -> dict:
    """EnvironmentVariables as launchd sees them. plistlib's expat parser is
    stricter than CoreFoundation's: the rendered remote-mcp plist carries
    `--` inside its header XML comment (illegal XML, ExpatError) yet launchd
    loads it. On a strict-parse failure the file is normalised by plutil
    (the CoreFoundation parser launchd uses) and parsed again. Raises
    PlistUnreadable when neither accepts it."""
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise PlistUnreadable(type(exc).__name__) from None
    try:
        doc = plistlib.loads(data)
    except (plistlib.InvalidFileException, ExpatError, ValueError) as exc:
        doc = _cf_parse(path, type(exc).__name__)
    env = doc.get("EnvironmentVariables") if isinstance(doc, dict) else None
    if env is not None and not isinstance(env, dict):
        raise PlistUnreadable("EnvironmentVariables_not_a_dict")
    return env or {}


def _cf_parse(path: Path, strict_err: str):
    plutil = shutil.which("plutil")
    if not plutil:
        raise PlistUnreadable(f"{strict_err}:no_plutil")
    try:
        r = subprocess.run([plutil, "-convert", "xml1", "-o", "-", os.path.abspath(path)],
                           capture_output=True, timeout=10)  # output never echoed: it is env values
        if r.returncode == 0:
            return plistlib.loads(r.stdout)
    except (OSError, subprocess.TimeoutExpired, plistlib.InvalidFileException, ExpatError, ValueError):
        pass
    raise PlistUnreadable(strict_err)


def lease_view(lease_db: str, label: str, now: float) -> tuple[dict, list[str]]:
    try:
        lc = ol.open_ro(lease_db, require_table="owner_leases")
    except (ValueError, sqlite3.Error) as exc:
        return {}, [f"lease_store_unreadable:{exc}"]
    try:
        live = ol.holder_tuple(lc, label, now)
        last = lc.execute("SELECT generation, expires_at FROM owner_leases WHERE label=?"
                          " ORDER BY generation DESC LIMIT 1", (label,)).fetchone()
    except sqlite3.Error as exc:
        return {}, [f"lease_store_unreadable:{type(exc).__name__}"]
    finally:
        lc.close()
    if live:
        return {"state": "live", "generation": live[3]}, []
    if last:
        return {"state": "expired", "generation": last[0], "expires_at": last[1]}, [f"lease_expired:gen{last[0]}"]
    return {"state": "none"}, ["lease_none"]


def grant_view(auth_db: str, label: str, standing: bool, next_item: dict | None, queue_sha: str,
               now: float) -> tuple[dict, list[str]]:
    try:
        ac = sqlite3.connect(f"file:{auth_db}?mode=ro", uri=True, timeout=5)
    except sqlite3.Error as exc:
        return {}, [f"auth_store_unreadable:{type(exc).__name__}"]
    try:
        if standing:
            rows = ac.execute("SELECT auth_id, status, expires_at, queue_sha256, item_cap, used_count"
                              " FROM owner_dispatch_auth WHERE owner_label=? AND kind='standing'"
                              " ORDER BY decided_at DESC", (label,)).fetchall()
        elif next_item is not None:
            rows = ac.execute("SELECT auth_id, status, expires_at FROM owner_dispatch_auth WHERE auth_id=?",
                              (next_item["auth_id"],)).fetchall()
        else:
            rows = []
    except sqlite3.Error as exc:
        return {}, [f"auth_store_unreadable:{type(exc).__name__}"]
    finally:
        ac.close()
    if standing:
        usable = [r for r in rows if r[1] == "granted" and r[2] > now and r[3] == queue_sha
                  and (r[4] is None or r[5] < r[4])]
        if usable:
            r = usable[0]
            return {"mode": "standing", "auth_id": r[0], "expires_at": r[2], "used": r[5], "item_cap": r[4]}, []
        why = "none"
        if rows:
            r = rows[0]
            why = ("denied" if r[1] == "denied" else "expired" if r[2] <= now else
                   "queue_sha_mismatch" if r[3] != queue_sha else "cap_used")
        return {"mode": "standing", "latest": rows[0][0] if rows else None}, [f"no_standing_grant:{why}"]
    if next_item is None:
        return {"mode": "single"}, []
    if rows and rows[0][1] == "granted" and rows[0][2] > now:
        return {"mode": "single", "auth_id": rows[0][0], "expires_at": rows[0][2]}, []
    why = "missing" if not rows else rows[0][1] if rows[0][1] != "granted" else "expired"
    return {"mode": "single", "auth_id": next_item["auth_id"]}, [f"no_grant:{why}"]


def lane_view(env: dict, label: str, now: float) -> dict:
    root = Path(env["HERDR_QUEUE_SUPERVISOR_ROOT"])
    lane = qs.Lane(root, label)
    out: dict = {"label": label, "blockers": []}
    try:
        in_flight, frozen, settled, _esc, _exh, _n = qs._lane_state(lane.ledger())
    except qs.LedgerCorrupt as exc:
        out["blockers"].append(f"ledger_corrupt:{exc}")
        in_flight = frozen = None
        settled = set()
    try:
        items, sha = lane.queue_snapshot()
    except (ValueError, OSError) as exc:
        out["blockers"].append(f"queue_invalid:{exc}")
        items, sha = [], ""
    nxt = next((i for i in items if i["id"] not in settled and not i.get("hold")), None)
    out["queue"] = {"present": lane.queue_path.exists(), "sha256": sha, "items": len(items),
                    "pending": sum(1 for i in items if i["id"] not in settled and not i.get("hold")),
                    "in_flight": in_flight}
    if frozen:
        out["blockers"].append(f"frozen:{frozen}")
    if in_flight is None and nxt is None and sha:
        out["blockers"].append("queue_empty")
    out["lease"], b = lease_view(env["HERDR_OWNER_LEASE_DB"], label, now)
    out["blockers"] += b
    if in_flight is None:
        standing = env.get(QSUP.STANDING_ENV_FLAG) == "1"
        out["grant"], b = grant_view(env["HERDR_OWNER_DISPATCH_AUTH_DB"], label, standing, nxt, sha, now)
        out["blockers"] += b
    out["verdict"] = "BLOCKED" if out["blockers"] else "RUNNING" if in_flight else "RUNNABLE"
    return out


def status(hub_plist: Path, remote_plist: Path, now: float) -> dict:
    shared = []
    try:
        env = plist_env(hub_plist)
    except PlistUnreadable as exc:
        # Without the tick's env every other check would only be noise.
        return {"shared_blockers": [f"hub_plist_unreadable:{exc}"], "standing": False, "lease_renew": False,
                "lanes": []}
    if QSUP.kill_switch_engaged():
        shared.append(f"kill_switch:{QSUP.KILL_SWITCH}")
    if env.get(qs.ENV_FLAG) != "1":
        shared.append("supervisor_off")
    shared += [f"flag_off:{k}" for k in FLAGS if env.get(k) != "1"]
    shared += [f"not_configured:{k}" for k in PATHS if not env.get(k)]
    lanes = [x for x in env.get("HERDR_QUEUE_SUPERVISOR_LANES", "").split(",") if x]
    if not lanes:
        shared.append("not_configured:HERDR_QUEUE_SUPERVISOR_LANES")
    try:
        renew = plist_env(remote_plist).get("HERDR_OWNER_LEASE_RENEW") == "1"
    except PlistUnreadable as exc:
        renew = False
        if str(exc) != "FileNotFoundError":  # not installed = renewal off, as before
            shared.append(f"remote_mcp_plist_unreadable:{exc}")
    out = {"shared_blockers": shared, "standing": env.get(QSUP.STANDING_ENV_FLAG) == "1",
           "lease_renew": renew, "lanes": []}
    if all(env.get(k) for k in PATHS):
        out["lanes"] = [lane_view(env, lb, now) for lb in lanes]
    for lane in out["lanes"]:
        if shared:
            lane["verdict"] = "BLOCKED"
    return out


def main(argv=None, now=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--hub-plist", default=str(AGENTS / "com.herdr-control.hub.plist"))
    ap.add_argument("--remote-mcp-plist", default=str(AGENTS / "com.herdr-control.remote-mcp.plist"))
    a = ap.parse_args(argv)
    st = status(Path(a.hub_plist), Path(a.remote_mcp_plist), time.time() if now is None else now)
    if a.json:
        print(json.dumps(st, sort_keys=True, default=str))
    else:
        print(f"factory: standing={'on' if st['standing'] else 'off'} lease_renew={'on' if st['lease_renew'] else 'off'}"
              f" shared_blockers={','.join(st['shared_blockers']) or 'none'}")
        for lane in st["lanes"]:
            q = lane["queue"]
            print(f"lane {lane['label']}: {lane['verdict']} {','.join(lane['blockers']) or ''}".rstrip()
                  + f" | queue pending={q['pending']} in_flight={q['in_flight']} lease={lane['lease'].get('state')}")
    blocked = bool(st["shared_blockers"]) or any(lane["verdict"] == "BLOCKED" for lane in st["lanes"])
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
