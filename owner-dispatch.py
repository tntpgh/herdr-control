#!/usr/bin/env python3
"""owner-dispatch.py — the one real caller of lib/owner_dispatch.Dispatcher.

OFF BY DEFAULT and INERT on this machine: refuses unless
HERDR_OWNER_DISPATCH=1, HERDR_OWNER_LEASE_DELIVERY=1 and every store is
configured explicitly. Nothing here issues a grant, creates an owner mapping,
or acquires, renews, reaps or takes over a lease.

  owner-dispatch.py --label L --rid R --request-dir /canonical/dir --request-name F \
      --auth-id A --manifest result.md [--manifest more.md]

  - The request is read ONCE (owner_dispatch_auth.read_request_once: bounded,
    O_NOFOLLOW, regular file, exact canonical parent). Those captured bytes are
    hashed for the grant AND are what the Dispatcher journals and types.
  - Authorization: consume grant A from HERDR_OWNER_DISPATCH_AUTH_DB
    (owner-dispatch-auth/1). Missing/denied/consumed/mismatch/ambiguous -> held
    BEFORE admission or any write.
  - Identity: the registry owners row (remote-mcp/publisher.registry_resolver)
    must equal the live lease tuple. The session digest is a REGISTRY-ATTESTED
    identity, not authentication of the process at the pane.
  - recover() runs first; any mismatch/unrecorded journal entry refuses the run.
Exit: 0 dispatched; 2 held (typed reason on stdout); 3 ambiguous; 4 config/recovery refusal.
"""
from __future__ import annotations

import argparse
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))

import owner_dispatch as od  # noqa: E402
import owner_dispatch_auth as oda  # noqa: E402
import owner_lease_delivery as old  # noqa: E402
import result_availability as ra  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--rid", required=True)
    ap.add_argument("--request-dir", required=True)
    ap.add_argument("--request-name", required=True)
    ap.add_argument("--auth-id", required=True)
    ap.add_argument("--manifest", action="append", required=True)
    a = ap.parse_args(argv)
    if os.environ.get("HERDR_OWNER_DISPATCH") != "1" or os.environ.get("HERDR_OWNER_LEASE_DELIVERY") != "1":
        print("refused:flags_off")
        return 4
    lease_db, auth_db = os.environ.get("HERDR_OWNER_LEASE_DB", ""), os.environ.get("HERDR_OWNER_DISPATCH_AUTH_DB", "")
    if not lease_db or not auth_db or not Path(auth_db).is_file():
        print("refused:store_not_configured")  # never creates the auth store
        return 4
    avail = ra.from_env()
    if avail is None:
        print("refused:result_availability_off")
        return 4
    try:
        data = oda.read_request_once(a.request_dir, a.request_name)
    except (ValueError, OSError) as exc:
        print(f"held:not_dispatched:request_unreadable:{exc if isinstance(exc, ValueError) else type(exc).__name__}")
        return 2
    import publisher  # noqa: E402  (read-only registry resolver + DELIVER path)
    gate = old.DeliveryGate(lease_db)
    store = sqlite3.connect(auth_db, isolation_level=None, timeout=10)

    def authorize(label, rid, sha, manifest):
        return oda.consume(store, a.auth_id, label=label, request_id=rid, body_sha256=sha, manifest=manifest)

    def send(label, holder, text: bytes) -> bool:
        return subprocess.run([publisher.DELIVER, holder[0], text.decode("utf-8")], capture_output=True,
                              timeout=120).returncode == 0

    d = od.Dispatcher(gate, avail, send, publisher.registry_resolver, authorize=authorize)
    try:
        bad = {k: v for k, v in d.recover().items() if v.startswith(("mismatch", "unrecorded"))}
        if bad:
            print("refused:recovery_needs_operator " + " ".join(f"{k}={v}" for k, v in sorted(bad.items())))
            return 4
        out = d.dispatch(a.label, a.rid, data, a.manifest)
    finally:
        store.close()
        gate.close()
        avail.close()
    print(out)
    return 0 if out == "dispatched" else 3 if out.startswith("ambiguous") else 2


if __name__ == "__main__":
    sys.exit(main())
