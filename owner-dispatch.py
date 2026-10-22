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
    (owner-dispatch-auth/2, opened by owner_dispatch_auth.open_store: exact
    canonical path, private regular file, protected parent, safe sidecars).
    The grant must name this label, its project and the exact resolved holder
    tuple incl. lease generation. Missing/denied/consumed/expired/mismatch/
    ambiguous -> held BEFORE admission or any write.
  - Identity: the registry owners row (remote-mcp/publisher.registry_resolver)
    must equal the live lease tuple. The session digest is a REGISTRY-ATTESTED
    identity, not authentication of the process at the pane.
  - recover() runs first; any mismatch/unrecorded journal entry, or any
    consumed-but-unsent grant (owner_dispatch_auth.unsent), refuses the run.
Exit: 0 dispatched; 2 held (typed reason on stdout); 3 ambiguous; 4 config/recovery refusal.
"""
from __future__ import annotations

import argparse
import os
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


def make_send(deliver: str):
    """The delivery adapter: herdr-deliver <pane> <text>, exit 0 = delivered."""
    def send(label, holder, text: bytes) -> bool:
        return subprocess.run([deliver, holder[0], text.decode("utf-8")], capture_output=True,
                              timeout=120).returncode == 0
    return send


def main(argv=None, send=None, resolve=None) -> int:
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
    if not lease_db or not auth_db:
        print("refused:store_not_configured")
        return 4
    try:
        store = oda.open_store(auth_db)  # never creates the auth store
    except ValueError as exc:
        print(f"refused:{exc}")
        return 4
    avail = ra.from_env()
    if avail is None:
        store.close()
        print("refused:result_availability_off")
        return 4
    try:
        data = oda.read_request_once(a.request_dir, a.request_name)
    except (ValueError, OSError) as exc:
        store.close()
        avail.close()
        print(f"held:not_dispatched:request_unreadable:{exc if isinstance(exc, ValueError) else type(exc).__name__}")
        return 2
    if send is None or resolve is None:
        import publisher  # noqa: E402  (read-only registry resolver + DELIVER path)
        send = send or make_send(publisher.DELIVER)
        resolve = resolve or publisher.registry_resolver
    gate = old.DeliveryGate(lease_db)

    def authorize(label, project, holder, rid, sha, manifest, now):
        return oda.consume(store, a.auth_id, label=label, project=project, holder=holder, request_id=rid,
                           body_sha256=sha, manifest=manifest, now=now)

    d = od.Dispatcher(gate, avail, send, resolve, authorize=authorize)
    try:
        bad = {k: v for k, v in d.recover().items() if v.startswith(("mismatch", "unrecorded"))}
        bad.update({f"auth:{aid}": "consumed_unsent" for aid in oda.unsent(store, str(avail.journal_root))})
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
