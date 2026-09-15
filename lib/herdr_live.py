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

* IDLE RESYNC, NOT POLLING. A silently dead stream is indistinguishable from a
  quiet fleet, and a control plane that cannot tell those apart is the thing
  this replaces. If no event arrives for `resync_after_idle_s`, we spend ONE
  `session.snapshot` RPC to re-verify. That is 6 RPCs an hour, not 6 a second.

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

# How long a `pane.agent_status_changed` event outranks the status carried by
# an output-driven `pane_updated` for the same pane. See _apply_pane.
STATUS_EVENT_STICKY_S = 3.0

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
    in the pane, what herdr says it is doing, and where — no screen content, so
    nothing here can leak a command or a credential into a page or a log."""
    wid = pane.get("workspace_id") or ""
    return {
        "pane_id": pane.get("pane_id") or "",
        "workspace_id": wid,
        "workspace": workspaces.get(wid) or wid,
        "tab_id": pane.get("tab_id") or "",
        "label": pane.get("label"),
        "agent": pane.get("agent"),
        "agent_status": pane.get("agent_status") or "unknown",
        "cwd": pane.get("foreground_cwd") or pane.get("cwd"),
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
        resync_after_idle_s: float = 600.0,
        max_backoff_s: float = 30.0,
    ):
        self._on_transition = on_transition
        self._log = log or (lambda _msg: None)
        self._resync_after_idle_s = resync_after_idle_s
        self._max_backoff_s = max_backoff_s
        self._lock = threading.Lock()
        # Shares _lock, so a state change can bump the version and wake every
        # long-poll waiter inside the same critical section that applied it.
        self._changed = threading.Condition(self._lock)
        self._version = 0
        self._panes: dict[str, dict] = {}
        self._since: dict[str, float] = {}       # pane_id -> when its status last changed
        self._status_event_at: dict[str, float] = {}   # pane_id -> last authoritative status event
        self._workspaces: dict[str, str] = {}    # workspace_id -> label
        self._edges: queue.Queue = queue.Queue(maxsize=1024)
        self._stop = threading.Event()
        self.stats = {
            "connected": False,
            "connected_since": None,
            "reconnects": 0,
            "resubscribes": 0,
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

    # ── state application ─────────────────────────────────────────────────────
    def _apply_pane(self, pane: dict, now: float) -> tuple[str, str | None, str | None, dict] | None:
        pid = pane.get("pane_id")
        if not pid:
            return None
        rec = _pane_record(pane, self._workspaces)
        prev = self._panes.get(pid)
        if prev and rec["revision"] and prev["revision"] > rec["revision"]:
            # A pane_updated that the socket buffered during a bootstrap can
            # arrive after the snapshot that already superseded it. Revisions
            # are monotonic per pane, so the older one is simply dropped.
            return None
        if (prev and rec["agent_status"] != prev["agent_status"]
                and now - self._status_event_at.get(pid, 0.0) < STATUS_EVENT_STICKY_S):
            # `pane_updated` fires on OUTPUT and carries whatever status the
            # record held when it was built, so one emitted around the same
            # instant as a status change can carry the pre-change value and
            # flip `blocked` back to `working`. The dedicated
            # pane.agent_status_changed event is the authority for status, so
            # for a moment after one lands, an output event may refresh every
            # field EXCEPT the status.
            rec["agent_status"] = prev["agent_status"]
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
        self._since.pop(pane_id, None)
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
                edge = self._apply_pane(pane, now)
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
                           "agent": data.get("agent"), "agent_status": "unknown", "revision": 0}
                    self._panes[pid] = rec
                merged = dict(rec)
                merged["agent_status"] = data.get("agent_status") or "unknown"
                merged["agent"] = data.get("agent") or rec.get("agent")
                before = rec["agent_status"]
                self._panes[pid] = merged
                self._status_event_at[pid] = now
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
                # next transition (or an idle resync) re-derives what is needed.
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
        """The subscription set, plus the panes it covers individually."""
        subs: list[dict] = [{"type": t} for t in LIFECYCLE_SUBSCRIPTIONS]
        with self._lock:
            known = sorted(self._panes)
        subs += [{"type": "pane.agent_status_changed", "pane_id": pid} for pid in known]
        return subs, set(known)

    def _connect_and_stream(self) -> bool:
        """Stream until the connection dies or the subscription set is stale.

        Returns True when it ended because we need to RESUBSCRIBE (a pane
        appeared that no per-pane subscription covers) rather than because of a
        failure — the caller must not count that as a reconnect or back off."""
        wire = _Wire(socket_path(), timeout=5.0)
        try:
            subs, covered = self._subscriptions()
            wire.send({"id": "herdr-live", "method": "events.subscribe",
                       "params": {"subscriptions": subs}})
            ack = wire.read(timeout=5.0)
            if not ack or "result" not in ack:
                raise ConnectionError(f"subscribe not acknowledged: {ack!r}")

            # Bootstrap AFTER the subscription is live (see module docstring).
            self._emit(self._apply_snapshot(request("session.snapshot")))
            with self._lock:
                self.stats["connected"] = True
                self.stats["connected_since"] = time.time()
                self.stats["last_error"] = None
                uncovered = set(self._panes) - covered
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

            while not self._stop.is_set():
                msg = wire.read(timeout=self._resync_after_idle_s)
                if msg is None:
                    with self._lock:
                        self.stats["resyncs"] += 1
                    self._emit(self._apply_snapshot(request("session.snapshot")))
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
            wire.close()

    def _stream_forever(self) -> None:
        backoff = 0.5
        while not self._stop.is_set():
            try:
                resubscribe = self._connect_and_stream()
                backoff = 0.5
                with self._lock:
                    self.stats["resubscribes" if resubscribe else "reconnects"] += 1
            except Exception as exc:
                with self._lock:
                    self.stats["connected"] = False
                    self.stats["last_error"] = f"{type(exc).__name__}: {exc}"
                self._log(f"herdr stream lost ({exc!r}); retrying in {backoff:.1f}s")
                self._stop.wait(backoff)
                backoff = min(backoff * 2, self._max_backoff_s)
