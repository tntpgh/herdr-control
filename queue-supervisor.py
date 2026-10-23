#!/usr/bin/env python3
"""One queue-supervisor pass over the configured lanes (DEFAULT OFF).

Wires lib/queue_supervisor.tick to the SAME stores and fences owner-dispatch.py
uses: owner_dispatch_auth (one-time grant named by each queue item's auth_id),
owner_lease_delivery.DeliveryGate, result_availability (journal, roots,
`accepted` stage) and publisher's read-only registry resolver + DELIVER path.

Refuses (exit 4, nothing dispatched) unless HERDR_QUEUE_SUPERVISOR=1 AND the
owner-dispatch flags/stores are configured, or when owner_dispatch recovery
finds a mismatch / consumed-unsent grant (same rule as owner-dispatch.py).

Env: HERDR_QUEUE_SUPERVISOR_ROOT (queue + ledger dir), HERDR_QUEUE_SUPERVISOR_LANES
(comma-separated owner labels). Escalations append to <root>/escalations.jsonl
for the hub/attention surface; this script contacts no one.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))
import owner_dispatch as od  # noqa: E402
import owner_dispatch_auth as oda  # noqa: E402
import owner_lease as ol  # noqa: E402
import owner_lease_delivery as old  # noqa: E402
import private_sqlite  # noqa: E402
import queue_supervisor as qs  # noqa: E402
import result_availability as ra  # noqa: E402


class GrantDispatch:
    """qs.Dispatch over one od.Dispatcher; the grant consumed is exactly the
    queue item's auth_id (never a new or re-armed one)."""

    def __init__(self, gate, avail, send, resolve, store):
        self.gate, self.avail, self.send, self.resolve, self.store = gate, avail, send, resolve, store

    def dispatch(self, label, rid, request_text, manifest, auth_id):
        if not auth_id:
            return "held:not_dispatched:auth_missing"

        def authorize(lb, project, holder, r, sha, man, now):
            return oda.consume(self.store, auth_id, label=lb, project=project, holder=holder, request_id=r,
                               body_sha256=sha, manifest=man, now=now)

        return od.Dispatcher(self.gate, self.avail, self.send, self.resolve, authorize=authorize).dispatch(
            label, rid, request_text, manifest)


def main(environ=os.environ, send=None, resolve=None) -> int:
    if not qs.enabled(environ):
        print("off")
        return 0
    if environ.get("HERDR_OWNER_DISPATCH") != "1" or environ.get("HERDR_OWNER_LEASE_DELIVERY") != "1":
        print("refused:flags_off")
        return 4
    root, lanes = environ.get("HERDR_QUEUE_SUPERVISOR_ROOT", ""), environ.get("HERDR_QUEUE_SUPERVISOR_LANES", "")
    lease_db, auth_db = environ.get("HERDR_OWNER_LEASE_DB", ""), environ.get("HERDR_OWNER_DISPATCH_AUTH_DB", "")
    if not (root and lanes and lease_db and auth_db):
        print("refused:not_configured")
        return 4
    os.umask(0o077)
    try:
        store = oda.open_store(auth_db)
    except ValueError as exc:
        print(f"refused:{exc}")
        return 4
    avail = ra.from_env(environ)
    if avail is None:
        store.close()
        print("refused:result_availability_off")
        return 4
    if send is None or resolve is None:
        import importlib.util

        import publisher  # read-only registry resolver + DELIVER path

        spec = importlib.util.spec_from_file_location("owner_dispatch_cli", HERE / "owner-dispatch.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        send = send or cli.make_send(publisher.DELIVER)  # the one delivery adapter
        resolve = resolve or publisher.registry_resolver
    try:
        lconn = private_sqlite.open_private(lease_db, ol.connect, require_table="owner_leases")
    except ValueError as exc:
        store.close()
        avail.close()
        print(f"refused:lease_{exc}")
        return 4
    gate = old.DeliveryGate(lease_db, conn=lconn)
    qroot = Path(root)
    esc = qroot / "escalations.jsonl"

    def notify(label, item, reason):
        fd = os.open(esc, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, (json.dumps({"at": time.time(), "label": label, "item": item, "reason": reason}) + "\n").encode())
            os.fsync(fd)
        finally:
            os.close(fd)

    def accepted(label, rid):
        return "accepted" in avail.stages(rid)

    def events(label, rid):
        lroot = avail.roots.get(label)
        return qs.latest_queue_event(Path(lroot) / "events.jsonl", rid) if lroot else None

    try:
        recov = od.Dispatcher(gate, avail, send, resolve).recover()
        bad = {k: v for k, v in recov.items() if v.startswith(("mismatch", "unrecorded"))}
        bad.update({f"auth:{a}": "consumed_unsent" for a in oda.unresolved(store, str(avail.journal_root))})
        if bad:
            print("refused:recovery_needs_operator " + " ".join(f"{k}={v}" for k, v in sorted(bad.items())))
            return 4
        out = qs.tick(qroot, [x for x in lanes.split(",") if x], GrantDispatch(gate, avail, send, resolve, store),
                      accepted, events, notify, environ=environ)
    finally:
        store.close()
        gate.close()
        avail.close()
    print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
