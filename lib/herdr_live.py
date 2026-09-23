"""herdr_live.py — the fleet's live pane state, pushed by herdr, never polled.

herdr already knows which pane is blocked: its agent integrations report state
over the socket API (`pane.report_agent`; omp's own integration drives it from
`tool_approval_requested`/`tool_approval_resolved`), and the server emits
`pane_updated` / `pane_agent_status_changed` when it changes. Until this module
existed, herdr-control re-derived that fact by SCRAPING — `herdr pane read` per
pane, per tool call, per sweep — which is how the control plane pushed the herdr
socket's p95 from 9ms to 136ms and made the TUI itself feel laggy (measured
2026-09-14; see the commit that removed the notify poll).

So: ONE long-lived `events.subscribe` connection, one in-memory map, and an edge
callback. Everything that used to ask "is this pane blocked?" reads this instead
of the terminal.

Design notes that are load-bearing, not style:

* BOOTSTRAP ORDER. Per herdr's socket-api doc, subscribe FIRST, then call
  `session.snapshot` on a second connection, then apply what the stream
  buffered. Snapshotting first would lose every change that happened between
  the snapshot and the subscription — exactly the gap that makes a cache lie.
  The stream connection is not read during the bootstrap request; the socket's
  own buffer preserves those events in order, and `revision` (monotonic per
  pane) makes a late-applied event a no-op rather than a regression.

* A RECONNECT IS A DIFF, NOT A RESET. The server can restart, the socket can
  drop, a new pane needs a new per-pane subscription. Every (re)connect
  re-snapshots and DIFFS against the state we already had, emitting the
  transitions that happened while we were away. That is what makes an event
  stream safe to build alerting on: no event is load-bearing on its own, only
  the state it implies.

* PER-PANE STATUS SUBSCRIPTIONS. `pane.agent_status_changed` requires a
  `pane_id` (verified against the bundled schema — the subscription variant has
  `required: [type, pane_id]`), so a fleet-wide watcher subscribes to it once
  per known pane plus the pane lifecycle events. When a pane appears that we
  have no subscription for, we reconnect with the wider set; `pane_updated`
  carries the full PaneInfo including `agent_status`, so the lifecycle stream
  alone already keeps state correct in the meantime.

* PERIODIC RESYNC, NOT POLLING. Every `resync_every_s` of wall clock we spend
  ONE `session.snapshot` RPC and diff it in, whether or not events are
  flowing. It started as an IDLE resync (only after 600s with no event at all)
  and that never ran on a working fleet: nine events a second from other panes
  kept resetting it, so a status change whose event was never delivered stayed
  wrong indefinitely. herdr changes `agent_status` WITHOUT bumping `revision`,
  so a pane that goes blocked and then sits quiet (the pane this module exists
  to report) has no later event to correct it. Measured 2026-09-23: after a
  hub restart, 109 of 120 samples in 4 minutes had a worker `blocked` in herdr
  and `working` here AT THE SAME REVISION (w1G:p3 for 3 minutes, on an
  allow-class `jq` the peer would have answered in 2 seconds). One snapshot
  every 10s is 0.1 RPC/s: the polling this replaced was 20 reads per tool call
  per worker.

* EDGES RUN OFF-THREAD. The callback may spawn shell (alerting, retraction,
  peer-answer). It runs on a worker thread draining a bounded queue, so a slow
  or hung edge script can never stall the stream or drop state updates.
"""

from __future__ import annotations

import json
import os
import queue
import socket
import threading
import time
from pathlib import Path
from typing import Callable

# Lifecycle subscriptions carry no pane_id and cover the fleet. `pane.updated`
# is the workhorse: its payload is the whole PaneInfo, agent_status included.
# `pane.output_changed` is deliberately NOT here — it fires per screen revision
# (24/s across an idle 15-pane session, measured) and tells us nothing about
# whether a human is needed.
LIFECYCLE_SUBSCRIPTIONS = (
    "pane.created",
    "pane.closed",
    "pane.exited",
    "pane.updated",
    "pane.moved",
    "pane.agent_detected",
    "workspace.renamed",
    "workspace.closed",
)

# The one status that means A PERSON IS BEING WAITED FOR. herdr's vocabulary is
# idle | working | blocked | done | unknown; only `blocked` is a human's turn.
BLOCKED = "blocked"

# After this many consecutive `pane_not_found` rejections, subscribe to the
# lifecycle events ONLY. Per-pane status subscriptions are the richer signal,
# but a fleet churning panes faster than we can resubscribe must not cost us
# the stream itself.
STATUS_SUBS_GIVE_UP_AFTER = 3

DEFAULT_SOCKET = Path.home() / ".config/herdr/herdr.sock"


def socket_path() -> Path:
    return Path(os.environ.get("HERDR_SOCKET_PATH") or DEFAULT_SOCKET)


class _Wire:
    """One socket connection, newline-delimited JSON both ways."""

    def __init__(self, path: Path, timeout: float = 5.0):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(str(path))
        self._buf = b""

    def send(self, obj: dict) -> None:
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def read(self, timeout: float | None) -> dict | None:
        """Next message, or None on timeout. Raises on a closed connection."""
        self.sock.settimeout(timeout)
        while b"\n" not in self._buf:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                raise ConnectionError("herdr socket closed")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        if not line.strip():
            return {}
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return {}

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def request(method: str, params: dict | None = None, timeout: float = 5.0) -> dict:
    """One-shot socket request. Used for `session.snapshot` bootstraps only."""
    wire = _Wire(socket_path(), timeout)
    try:
        wire.send({"id": f"hl_{int(time.time()*1000)}", "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            msg = wire.read(timeout=deadline - time.monotonic())
            if msg is None:
                break
            if "result" in msg:
                return msg["result"] or {}
            if "error" in msg:
                raise RuntimeError(f"{method}: {msg['error']}")
        raise TimeoutError(f"{method}: no response in {timeout}s")
    finally:
        wire.close()


def _pane_record(pane: dict, workspaces: dict[str, str]) -> dict:
    """The projection every consumer gets. Deliberately small: identity, who is
    in the pane, what herdr says it is doing — no screen content, so nothing
    here can leak a command or a credential into a page or a log.

    `birth` is herdr's `terminal_id`, the pane's BIRTH fingerprint. Pane ids are
    RECYCLED, so a status keyed on the id alone can describe a different process
    that inherited the slot: herdr-select.sh, lib/pane-guard.sh and
    lib/reconcile.sh all compare it before acting, and the security review found
    the new edge writer was the one path that could not, because this record did
    not carry it. It is an opaque id, not content.

    `cwd` is deliberately NOT here. The record is served on an unauthenticated
    loopback API, and an absolute path discloses the machine's project inventory
    — one live row was
    `/Users/…/CloudStorage/GoogleDrive-<address>/My Drive/Reno`, i.e. an email
    address and a client-matter name. Nothing rendered needs it; the edge script
    gets it from `cwd_of()` below, which the hub reads from its own state rather
    than publishing.
    """
    wid = pane.get("workspace_id") or ""
    return {
        "pane_id": pane.get("pane_id") or "",
        "workspace_id": wid,
        "workspace": workspaces.get(wid) or wid,
        "tab_id": pane.get("tab_id") or "",
        "label": pane.get("label"),
        "agent": pane.get("agent"),
        "agent_status": pane.get("agent_status") or "unknown",
        "birth": pane.get("terminal_id") or "",
        "revision": pane.get("revision") or 0,
    }


class LiveState:
    """Live pane/agent state for the whole herdr session, kept by subscription.

    `on_transition(pane_id, previous, current, record)` fires for every
    agent_status change, including the first observation of a pane (previous is
    None) and a pane disappearing (current is None). It is called on a worker
    thread, never on the stream thread.
    """

    def __init__(
        self,
        on_transition: Callable[[str, str | None, str | None, dict], None] | None = None,
        log: Callable[[str], None] | None = None,
        resync_every_s: float = 10.0,
        max_backoff_s: float = 30.0,
    ):
        self._on_transition = on_transition
        self._log = log or (lambda _msg: None)
        self._resync_every_s = resync_every_s
        self._max_backoff_s = max_backoff_s
        self._lock = threading.Lock()
        # Shares _lock, so a state change can bump the version and wake every
        # long-poll waiter inside the same critical section that applied it.
        self._changed = threading.Condition(self._lock)
        self._version = 0
        self._panes: dict[str, dict] = {}
        self._since: dict[str, float] = {}       # pane_id -> when its status last changed
        # Panes whose `pane.agent_status_changed` subscription the CURRENT
        # connection holds. For these, status comes only from that event and
        # from snapshots — never from `pane_updated`. See _apply_pane.
        self._status_covered: set[str] = set()
        # Kept OUT of the served record on purpose (see _pane_record): the edge
        # script needs a cwd, an unauthenticated API reader does not.
        self._cwd: dict[str, str] = {}
        self._workspaces: dict[str, str] = {}    # workspace_id -> label
        self._subscribe_failures = 0
        self._edges: queue.Queue = queue.Queue(maxsize=1024)
        self._stop = threading.Event()
        self.stats = {
            "connected": False,
            "connected_since": None,
            "reconnects": 0,
            "resubscribes": 0,
            "subscribe_pruned": 0,
            "status_subs_degraded": False,
            # Missing until 2026-09-15, which made the idle-resync path raise
            # KeyError instead of resyncing: the exception was caught one frame
            # up as "stream lost", so every quiet period became a reconnect and
            # the safety net for a silently dead stream never once ran.
            "resyncs": 0,
            "events": 0,
            "edges": 0,
            "edges_dropped": 0,
            "last_event_at": None,
            "last_error": None,
        }

    # ── public surface ────────────────────────────────────────────────────────
    def start(self) -> None:
        threading.Thread(target=self._stream_forever, name="herdr-live", daemon=True).start()
        threading.Thread(target=self._drain_edges, name="herdr-live-edges", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()

    def panes(self) -> list[dict]:
        with self._lock:
            out = []
            for pid, rec in self._panes.items():
                row = dict(rec)
                row["since"] = self._since.get(pid)
                out.append(row)
        out.sort(key=lambda r: (r["agent_status"] != BLOCKED, r["pane_id"]))
        return out

    def blocked(self) -> list[dict]:
        return [p for p in self.panes() if p["agent_status"] == BLOCKED]

    def status(self, pane_id: str) -> str | None:
        with self._lock:
            rec = self._panes.get(pane_id)
        return rec["agent_status"] if rec else None

    def version(self) -> int:
        """Bumped on every status change. A long-poll caller passes the version
        it last saw and is woken the moment that number moves — which is how
        `wait-for-blocked.sh` stops polling herdr 4 times a minute per pane."""
        with self._lock:
            return self._version

    def wait_for_change(self, since: int, timeout: float) -> int:
        with self._changed:
            if self._version == since:
                self._changed.wait(timeout)
            return self._version

    def data(self) -> dict:
        """What the hub serves. `connected` false means every row is STALE —
        callers must say so rather than presenting a cached fleet as live."""
        panes = self.panes()
        with self._lock:
            stats = dict(self.stats)
            version = self._version
        return {
            "connected": stats["connected"],
            "version": version,
            "stats": stats,
            "panes": panes,
            "blocked": [p for p in panes if p["agent_status"] == BLOCKED],
            "agents": [p for p in panes if p.get("agent")],
        }

    def cwd_of(self, pane_id: str) -> str:
        """The pane's cwd, for a caller that needs it (the edge script's Slack
        text). Deliberately not part of the served record — see _pane_record."""
        with self._lock:
            return self._cwd.get(pane_id, "")

    # ── state application ─────────────────────────────────────────────────────
    def _apply_pane(self, pane: dict, now: float,
                    authoritative: bool = False) -> tuple[str, str | None, str | None, dict] | None:
        """`authoritative` is True for a snapshot row: current truth, so it may
        set agent_status for any pane. An event-carried row may not, for a pane
        whose status events we are subscribed to."""
        pid = pane.get("pane_id")
        if not pid:
            return None
        rec = _pane_record(pane, self._workspaces)
        prev = self._panes.get(pid)
        # A RECYCLED id is a NEW pane, so the revision guard must not apply to
        # it. herdr restarts revision numbering per pane: if a pane closes and
        # a fresh one inherits the id with a lower revision, comparing
        # revisions alone drops every update for it forever — status, agent and
        # cwd stay those of the dead occupant and no edge ever fires. `birth`
        # (terminal_id) is what tells them apart.
        if prev and rec["birth"] and prev.get("birth") and rec["birth"] != prev["birth"]:
            self._since.pop(pid, None)
            prev = None
        if prev and rec["revision"] and prev["revision"] > rec["revision"]:
            # A pane_updated that the socket buffered during a bootstrap can
            # arrive after the snapshot that already superseded it. Revisions
            # are monotonic WITHIN one pane, so the older one is simply dropped.
            return None
        if (prev and not authoritative and pid in self._status_covered
                and rec["agent_status"] != prev["agent_status"]):
            # `pane_updated` is not a status source for a covered pane. It is
            # built when OUTPUT changes and delivered up to ~8s LATE, carrying
            # the status of that moment. herdr changes status WITHOUT bumping
            # `revision`, and the status event carries no revision, so nothing
            # can tell a late row from a fresh one. Measured on the live stream
            # 2026-09-23 (150s tap): every one of 22 transitions arrived as a
            # pane.agent_status_changed within ~1s, while three pane_updated
            # rows arrived 7-8s after their pane had moved on, each carrying
            # the pre-transition status. The one built just before an approval
            # menu painted says `working`; applied after the blocked event, it
            # un-blocked the pane, which then sat silent — no output, no event —
            # so nothing ever corrected it, and the peer never saw the prompt.
            # The 3s "sticky" hold this replaces was shorter than that delay.
            # Every other field still refreshes; the periodic resync bounds
            # any status event we do miss.
            rec["agent_status"] = prev["agent_status"]
        cwd = pane.get("foreground_cwd") or pane.get("cwd")
        if cwd:
            self._cwd[pid] = cwd
        self._panes[pid] = rec
        before = prev["agent_status"] if prev else None
        if before != rec["agent_status"]:
            self._since[pid] = now
            self._bump()
            return (pid, before, rec["agent_status"], rec)
        return None

    def _bump(self) -> None:
        """Caller MUST hold _lock (the condition shares it), so a waiter cannot
        miss a change that lands between its version read and its wait."""
        self._version += 1
        self._changed.notify_all()

    def _drop_pane(self, pane_id: str) -> tuple[str, str | None, str | None, dict] | None:
        prev = self._panes.pop(pane_id, None)
        # EVERY per-pane map, not just _since: a map that survives here grows
        # without bound on a fleet that recycles panes, and hands a recycled id
        # the previous occupant's state.
        self._since.pop(pane_id, None)
        self._status_covered.discard(pane_id)
        self._cwd.pop(pane_id, None)
        if not prev:
            return None
        self._bump()
        return (pane_id, prev["agent_status"], None, prev)

    def _apply_snapshot(self, snap: dict) -> list[tuple]:
        """Install a full snapshot AS A DIFF, so transitions we missed while
        disconnected still fire. This is what makes reconnection safe."""
        body = snap.get("snapshot") or snap
        now = time.time()
        edges: list[tuple] = []
        with self._lock:
            self._workspaces = {
                w.get("workspace_id"): (w.get("label") or w.get("workspace_id"))
                for w in body.get("workspaces") or []
                if w.get("workspace_id")
            }
            live_ids = set()
            for pane in body.get("panes") or []:
                live_ids.add(pane.get("pane_id"))
                edge = self._apply_pane(pane, now, authoritative=True)
                if edge:
                    edges.append(edge)
            for gone in [pid for pid in self._panes if pid not in live_ids]:
                edge = self._drop_pane(gone)
                if edge:
                    edges.append(edge)
        return edges

    def _apply_event(self, msg: dict) -> list[tuple]:
        # TWO naming schemes arrive on one connection, and this cost a day of
        # wrong state before it was caught: herdr's general event stream uses
        # underscores (`pane_updated`, `pane_agent_status_changed` — schema
        # `EventKind`), while the SUBSCRIPTION-typed events use the dotted
        # subscription name (`pane.agent_status_changed` — schema
        # `SubscriptionEventKind`). Handling only the underscore form silently
        # dropped every status change: `pane_updated` fires on OUTPUT, so a
        # pane that goes blocked and then sits quietly (exactly the pane we
        # care about) never corrects, and /api/blocked said `working` for a
        # worker herdr had already reported blocked (measured 2026-09-15,
        # divergence persisted for 30s+ of sampling with 9 events/s arriving).
        kind = (msg.get("event") or "").replace(".", "_")
        data = msg.get("data") or {}
        now = time.time()
        edges: list[tuple] = []
        with self._lock:
            if kind in ("pane_updated", "pane_created"):
                edge = self._apply_pane(data.get("pane") or {}, now)
                if edge:
                    edges.append(edge)
            elif kind == "pane_moved":
                # The pane keeps its occupant but can change id/tab/workspace.
                old = data.get("previous_pane_id")
                pane = data.get("pane") or {}
                if old and old != pane.get("pane_id"):
                    self._panes.pop(old, None)
                    self._since.pop(old, None)
                    self._cwd.pop(old, None)
                    # This connection's status subscription is for the OLD id;
                    # the new id is uncovered until the next resubscribe.
                    self._status_covered.discard(old)
                edge = self._apply_pane(pane, now)
                if edge:
                    edges.append(edge)
            elif kind in ("pane_closed", "pane_exited"):
                edge = self._drop_pane(data.get("pane_id") or "")
                if edge:
                    edges.append(edge)
            elif kind == "pane_agent_status_changed":
                pid = data.get("pane_id") or ""
                if not pid:
                    return edges
                rec = self._panes.get(pid)
                if rec is None:
                    # A status change for a pane we have no record of yet (it
                    # appeared between snapshots). Never drop it: `blocked` is
                    # the one fact this whole module exists to carry, so build
                    # a minimal record from the event itself and let the next
                    # pane_updated/snapshot fill in cwd and workspace label.
                    wid = data.get("workspace_id") or ""
                    rec = {"pane_id": pid, "workspace_id": wid,
                           "workspace": self._workspaces.get(wid) or wid,
                           "tab_id": "", "label": data.get("title"),
                           "agent": data.get("agent"), "agent_status": "unknown",
                           # The status event carries no terminal_id. Empty means
                           # UNKNOWN, never "mismatch": a consumer may only refuse
                           # on a definite disagreement, and the next pane_updated
                           # or snapshot fills this in.
                           "birth": "", "revision": 0}
                    self._panes[pid] = rec
                merged = dict(rec)
                merged["agent_status"] = data.get("agent_status") or "unknown"
                merged["agent"] = data.get("agent") or rec.get("agent")
                before = rec["agent_status"]
                self._panes[pid] = merged
                if before != merged["agent_status"]:
                    self._since[pid] = now
                    self._bump()
                    edges.append((pid, before, merged["agent_status"], merged))
            elif kind == "pane_agent_detected":
                pid = data.get("pane_id") or ""
                rec = self._panes.get(pid)
                if rec is not None and data.get("agent"):
                    rec["agent"] = data["agent"]
            elif kind in ("workspace_renamed", "workspace_created", "workspace_updated"):
                ws = data.get("workspace") or {}
                wid = ws.get("workspace_id")
                if wid:
                    self._workspaces[wid] = ws.get("label") or wid
                    for rec in self._panes.values():
                        if rec["workspace_id"] == wid:
                            rec["workspace"] = self._workspaces[wid]
            elif kind == "workspace_closed":
                wid = (data.get("workspace") or {}).get("workspace_id") or data.get("workspace_id")
                for pid in [p for p, r in self._panes.items() if r["workspace_id"] == wid]:
                    edge = self._drop_pane(pid)
                    if edge:
                        edges.append(edge)
        return edges

    # ── edge delivery ─────────────────────────────────────────────────────────
    def _emit(self, edges: list[tuple]) -> None:
        for edge in edges:
            if not self._on_transition:
                continue
            try:
                self._edges.put_nowait(edge)
                self.stats["edges"] += 1
            except queue.Full:
                # Never block the stream on a backed-up edge handler. Dropping
                # is visible in stats, and state stays correct either way — the
                # next transition (or a periodic resync) re-derives what is needed.
                self.stats["edges_dropped"] += 1

    def _drain_edges(self) -> None:
        while not self._stop.is_set():
            try:
                pane_id, before, after, rec = self._edges.get(timeout=1.0)
            except queue.Empty:
                continue
            try:
                self._on_transition(pane_id, before, after, rec)  # type: ignore[misc]
            except Exception as exc:  # an edge handler must never kill the watcher
                self._log(f"edge handler failed for {pane_id} {before}->{after}: {exc!r}")

    # ── the stream ────────────────────────────────────────────────────────────
    def _subscriptions(self) -> tuple[list[dict], set[str]]:
        """The subscription set, plus the panes it covers individually.

        After repeated `pane_not_found` rejections the per-pane half is dropped
        (see _subscribe_rejected): a degraded stream that still delivers
        pane_updated and snapshots beats no stream at all."""
        subs: list[dict] = [{"type": t} for t in LIFECYCLE_SUBSCRIPTIONS]
        with self._lock:
            known = sorted(self._panes)
            degraded = self._subscribe_failures >= STATUS_SUBS_GIVE_UP_AFTER
        if degraded:
            self.stats["status_subs_degraded"] = True
            return subs, set()
        subs += [{"type": "pane.agent_status_changed", "pane_id": pid} for pid in known]
        return subs, set(known)

    def _subscribe_rejected(self, ack: dict | None) -> bool:
        """True when this rejection is recoverable and we should retry NOW.

        THE WEDGE THIS FIXES (observed live 2026-09-15, 08:5x): a per-pane
        `pane.agent_status_changed` subscription for a pane that has since
        CLOSED makes the server reject the ENTIRE events.subscribe with
        `pane_not_found`. The old code raised, backed off, and rebuilt the same
        subscription list from the same stale state — because pruning only
        happens in the snapshot that runs AFTER the ack. So one closed pane
        (w8:p2F) stopped the subscription permanently: `connected:false`, 15
        frozen panes, retry every 30s forever, and every consumer silently back
        on stale data.

        Recovery is to re-snapshot BEFORE retrying — which drops the vanished
        pane (and emits its edge) — then subscribe again with the pruned set.
        The snapshot is the same call bootstrap uses; if it fails too, the
        caller backs off as before.
        """
        err = (ack or {}).get("error") or {}
        if err.get("code") != "pane_not_found":
            return False
        with self._lock:
            self._subscribe_failures += 1
            n = self._subscribe_failures
            self.stats["subscribe_pruned"] += 1
        self._log(f"subscribe rejected ({err.get('message')}) — re-snapshotting to prune (attempt {n})")
        self._emit(self._apply_snapshot(request("session.snapshot")))
        return True

    def _connect_and_stream(self) -> bool:
        """Stream until the connection dies or the subscription set is stale.

        Returns True when it ended because we need to RESUBSCRIBE (a pane
        appeared or vanished, so the subscription set is stale) rather than
        because of a failure — the caller must not count that as a reconnect or
        back off."""
        wire = _Wire(socket_path(), timeout=5.0)
        try:
            subs, covered = self._subscriptions()
            # Degraded means we GAVE UP on per-pane subscriptions after repeated
            # rejections — read from the counter _subscriptions() itself uses.
            # It used to be inferred from "the list has no per-pane entry",
            # which is ALSO true on a fresh process that simply knows no panes
            # yet: the first connect then called itself degraded, forced
            # `uncovered` empty, and never resubscribed, so after every hub
            # restart no status event arrived until some pane was created
            # (found in review 2026-09-23; it is why the stuck-`working`
            # divergence came straight back after a restart).
            with self._lock:
                degraded = self._subscribe_failures >= STATUS_SUBS_GIVE_UP_AFTER
            wire.send({"id": "herdr-live", "method": "events.subscribe",
                       "params": {"subscriptions": subs}})
            ack = wire.read(timeout=5.0)
            if not ack or "result" not in ack:
                if self._subscribe_rejected(ack):
                    return True
                raise ConnectionError(f"subscribe not acknowledged: {ack!r}")
            # NOT reset on a degraded ack. Clearing the counter here made the
            # next attempt rebuild the full (rejecting) subscription set, so
            # degraded mode became a 4-connect cycle that repeated forever:
            # measured against a stub that keeps rejecting, 767,698 connects and
            # 767,697 session.snapshot RPCs in TWO SECONDS, event loop entered
            # zero times, while stats still said connected:true and
            # last_error:null. Against the real socket that is precisely the
            # single-threaded saturation this module exists to remove.
            with self._lock:
                if not degraded:
                    self._subscribe_failures = 0
                # Empty when degraded: with no status events arriving,
                # pane_updated is the only live status signal left.
                self._status_covered = set(covered)

            # Bootstrap AFTER the subscription is live (see module docstring).
            self._emit(self._apply_snapshot(request("session.snapshot")))
            with self._lock:
                self.stats["connected"] = True
                self.stats["connected_since"] = time.time()
                self.stats["last_error"] = None
                uncovered = set() if degraded else set(self._panes) - covered
            if uncovered:
                # Every pane needs its own `pane.agent_status_changed`
                # subscription (the schema requires a pane_id), and the first
                # connection of a fresh process knows no panes at all. One more
                # round trip installs them; `pane.updated` already carries
                # agent_status fleet-wide, so state is never blind meanwhile.
                # Converges in two connects: the second is built from the
                # snapshot the first installed.
                self._log(f"resubscribing to cover {len(uncovered)} pane(s)")
                return True

            next_resync = time.monotonic() + self._resync_every_s
            while not self._stop.is_set():
                # Resync BEFORE reading, never between a read and applying it:
                # a message already off the wire predates the snapshot, and
                # applied after it would regress the state the snapshot set.
                if time.monotonic() >= next_resync:
                    with self._lock:
                        self.stats["resyncs"] += 1
                    self._emit(self._apply_snapshot(request("session.snapshot")))
                    next_resync = time.monotonic() + self._resync_every_s
                # Floored above zero: settimeout(0) is NON-BLOCKING mode, where
                # recv raises BlockingIOError instead of timing out — that would
                # surface as "stream lost" and reconnect on every resync.
                msg = wire.read(timeout=max(0.05, next_resync - time.monotonic()))
                if msg is None:
                    continue
                if "result" in msg or "error" in msg:
                    continue
                with self._lock:
                    self.stats["events"] += 1
                    self.stats["last_event_at"] = time.time()
                self._emit(self._apply_event(msg))
                if msg.get("event") in ("pane_created", "pane_agent_detected"):
                    return True
            return False
        finally:
            # The next connection's subscription set is not ours to assume.
            with self._lock:
                self._status_covered = set()
            wire.close()

    def _stream_forever(self) -> None:
        backoff = 0.5
        rapid = 0
        last = 0.0
        while not self._stop.is_set():
            try:
                started = time.monotonic()
                resubscribe = self._connect_and_stream()
                backoff = 0.5
                with self._lock:
                    self.stats["resubscribes" if resubscribe else "reconnects"] += 1
                # A FLOOR on the resubscribe path. It is deliberately not a
                # failure (a new pane legitimately needs a wider subscription),
                # so it does not back off — which means any bug that returns
                # True immediately becomes a hot loop hammering the socket. One
                # did: the degraded-mode cycle above turned into ~380k
                # connect+snapshot round trips per second. Converging normally
                # takes two connects, so more than a handful of sub-second
                # cycles in a row is a bug, and the right response is to slow
                # down and say so rather than to saturate the server.
                if time.monotonic() - started < 0.25:
                    rapid += 1
                else:
                    rapid = 0
                if rapid >= 5:
                    pause = min(0.5 * (rapid - 4), 10.0)
                    if time.monotonic() - last > 30:
                        self._log(f"subscription cycling ({rapid} sub-second connects); pacing {pause:.1f}s")
                        last = time.monotonic()
                    self._stop.wait(pause)
            except Exception as exc:
                with self._lock:
                    self.stats["connected"] = False
                    self.stats["last_error"] = f"{type(exc).__name__}: {exc}"
                self._log(f"herdr stream lost ({exc!r}); retrying in {backoff:.1f}s")
                self._stop.wait(backoff)
                backoff = min(backoff * 2, self._max_backoff_s)
