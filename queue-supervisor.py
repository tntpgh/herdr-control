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

HERDR_QUEUE_SUPERVISOR_STANDING=1 (default OFF) swaps GrantDispatch for
StandingDispatch: the per-item fence (lease, DeliveryGate, journal) is
IDENTICAL, only which grant each dispatch consumes changes -- a single-use
row (GrantDispatch, oda.consume) or a fresh single-use child minted under a
standing row (StandingDispatch, oda.consume_standing). Off, this file's
behavior is byte-for-byte what it was before M9.
"""
from __future__ import annotations

import hashlib
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


STANDING_ENV_FLAG = "HERDR_QUEUE_SUPERVISOR_STANDING"


def standing_enabled(environ=os.environ) -> bool:
    return environ.get(STANDING_ENV_FLAG) == "1"


class StandingDispatch:
    """qs.Dispatch over one od.Dispatcher using the STANDING grant named by
    the item's auth_id (oda.consume_standing): each dispatch mints its own
    single-use child under that parent row instead of consuming a one-time
    grant. Active only when the conductor wires THIS class in instead of
    GrantDispatch (standing_enabled()); the Dispatcher and its fences are
    otherwise identical to the default per-item path.

    root: the SAME queue dir queue_supervisor reads -- re-read fresh here,
    right before authorization, rather than reusing tick_lane's earlier
    snapshot: the grant is bound to the queue content AT THE MOMENT OF
    CONSUMPTION, so an edit landing between item-selection and send must
    still be caught. The SAME fresh bytes also carry the item's OWN
    cost_cents (optional, validated here, never fabricated as 0): a queue
    item MAY name {"cost_cents": <non-negative int>}; consume_standing
    refuses standing_cost_missing when the grant has a real spend_cap_cents
    and this item's cost is absent or not a validated non-negative int --
    it never silently spends 0 against a real cap."""

    def __init__(self, gate, avail, send, resolve, store, lease_conn, root: Path):
        self.gate, self.avail, self.send, self.resolve, self.store = gate, avail, send, resolve, store
        self.lease_conn, self.root = lease_conn, root

    def dispatch(self, label, rid, request_text, manifest, auth_id):
        if not auth_id:
            return "held:not_dispatched:auth_missing"
        try:
            raw = (self.root / f"{label}.queue.json").read_bytes()
        except FileNotFoundError:
            raw = b"[]"
        queue_sha256 = hashlib.sha256(raw).hexdigest()
        cost_cents = _item_cost_cents(raw, label, rid)

        def authorize(lb, project, holder, r, sha, man, now):
            return oda.consume_standing(self.store, auth_id, label=lb, project=project, holder=holder,
                                        request_id=r, body_sha256=sha, manifest=man, now=now,
                                        queue_sha256=queue_sha256, lease_conn=self.lease_conn,
                                        cost_cents=cost_cents)

        return od.Dispatcher(self.gate, self.avail, self.send, self.resolve, authorize=authorize).dispatch(
            label, rid, request_text, manifest)


def _item_cost_cents(raw: bytes, label: str, rid: str) -> int | None:
    """The VALIDATED cost_cents (non-negative int) the operator priced the
    queue item named by `rid` at, read from THIS exact snapshot of
    <label>.queue.json; None when the item is missing from this snapshot,
    carries no cost_cents field, or carries one that is not a validated
    non-negative int. NEVER coerced to 0 here -- only consume_standing
    decides whether a None cost actually matters (it does only when the
    grant's spend_cap_cents is set), so an unpriced item under a lane with
    no spend cap still dispatches normally."""
    try:
        items = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(items, list):
        return None
    for item in items:
        if not isinstance(item, dict):
            continue
        iid = item.get("id")
        if not isinstance(iid, str) or qs.rid_for(label, iid) != rid:
            continue
        cost = item.get("cost_cents")
        if isinstance(cost, int) and not isinstance(cost, bool) and cost >= 0:
            return cost
        return None
    return None


def journal_state(jroot: Path, label: str, rid: str) -> str | None:
    """The owner_dispatch journal's verdict for rid (owner_dispatch.py docstring §2):
    None = no journal dir (never dispatched); else exactly one outcome file, or
    intent_only (crash across the send). A symlink anywhere is treated as uncertain."""
    d = jroot / label / rid
    if d.is_symlink() or (jroot / label).is_symlink():
        return "uncertain"
    if not d.exists():
        return None
    for name, verdict in (("settled.json", "settled"), ("uncertain.json", "uncertain"), ("refused.json", "refused")):
        if (d / name).is_symlink():
            return "uncertain"
        if (d / name).is_file():
            return verdict
    return "intent_only"


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
        lconn = ol.open_and_migrate(lease_db, require_table="owner_leases")
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

    def journal(label, rid):
        return journal_state(Path(avail.journal_root), label, rid)

    try:
        try:
            recov = od.Dispatcher(gate, avail, send, resolve).recover()
            # Scope recovery per owner label: a mismatch/unrecorded journal
            # entry for label L, or a consumed-unsent auth row bound to L,
            # stops ONLY L's lane this pass. An auth row whose label cannot
            # be determined (deleted/ambiguous since consumption), or any
            # failure reading the journal/auth store itself, is genuinely
            # shared uncertainty and still fails closed globally below.
            bad_by_label: dict[str, dict[str, str]] = {}
            for key, v in recov.items():
                if not v.startswith(("mismatch", "unrecorded")):
                    continue
                label, _, _ = key.partition("/")
                bad_by_label.setdefault(label, {})[key] = v
            shared_bad: dict[str, str] = {}
            for aid in oda.unresolved(store, str(avail.journal_root)):
                row = store.execute("SELECT owner_label FROM owner_dispatch_auth WHERE auth_id=?", (aid,)).fetchone()
                if row is None or not row[0]:
                    shared_bad[f"auth:{aid}"] = "consumed_unsent:lane_unknown"
                else:
                    bad_by_label.setdefault(row[0], {})[f"auth:{aid}"] = "consumed_unsent"
        except Exception as exc:
            print(f"refused:recovery_needs_operator shared_store={type(exc).__name__}")
            return 4
        if shared_bad:
            all_bad = dict(shared_bad)
            for lb in bad_by_label.values():
                all_bad.update(lb)
            print("refused:recovery_needs_operator " + " ".join(f"{k}={v}" for k, v in sorted(all_bad.items())))
            return 4
        lane_labels = [x for x in lanes.split(",") if x]
        runnable = [lb for lb in lane_labels if lb not in bad_by_label]
        dispatcher = (StandingDispatch(gate, avail, send, resolve, store, lconn, qroot)
                     if standing_enabled(environ) else GrantDispatch(gate, avail, send, resolve, store))
        out = qs.tick(qroot, runnable, dispatcher, accepted, events, notify, journal, environ=environ)
        for lb in lane_labels:
            if lb in bad_by_label:
                out[lb] = ("refused:recovery_needs_operator "
                          + " ".join(f"{k}={v}" for k, v in sorted(bad_by_label[lb].items())))
    finally:
        store.close()
        gate.close()
        avail.close()
    print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
