#!/usr/bin/env python3
"""hub.py — one localhost page for every operator surface, with sub-pages.

Terrence, 2026-09-05: "lots of tools using their own localhost port and
dashboard … a smart way to aggregate, sub-pages for decisions, an overall
view." This is an INDEX and an INBOX, not a rewrite: every tool keeps its
own server; the hub lists them, checks they are alive, and pulls together
the two things that need a human — attention items and open decisions.

  /            overview cards (herdr attention, decisions, fleet, KB nightly, search memory, deploy drift)
  /herdr       run-registry view: needs-attention, recent events, conductor cursors
  /decisions   inbox: open formserve forms inline (where Terrence answers), stray legacy-portal rows, answered history
  /search      consensus-search memory: totals, last queries, replay counts
  /kb          knowledge-base: nightly ledger, heartbeat, repeat-view signal audits
  /links       every surface with a liveness dot
  /projects    thurber-os docs/project-contract-plan.md §2: per project, live tasks, open PRs, open decisions, SPEC.md checklist, next step
  /timeline    registry events in a window (?since=&until=, default last 24h; ?repo= scope) — "what moved while I was away"
  /api/summary {attention, attention_tasks, handoff_debt, open_decisions, deploy_drift} — what the omp extension's one-liner reads
  /api/projects same join as /projects, JSON — what fleet-tools.ts's project_status tool and the ambient card read
  /api/timeline same window as JSON: event rows only, never a derived task status
  /api/panes   every pane herdr knows, with its agent and live agent_status
  /api/blocked just the panes waiting on a person, joined to their task
  /api/blocked/wait?since=N&timeout=S  long-poll: returns the instant that changes
  any page     ?json=1 → the page's data as JSON

The hub holds ONE `events.subscribe` connection to herdr (lib/herdr_live.py)
and treats herdr's own agent_status as authoritative for "a human is being
waited for". That is what /api/blocked/wait serves, so a supervisor no longer
polls `herdr pane list` + `pane read` per pane per tick to learn it.

Sources (all read-only): ~/.local/state/herdr/runs/registry.sqlite3 (herdr),
~/.local/state/herdr/forms/*.json (formserve registry), consensus-search
GET /log (bearer SEARCH_SYNC_TOKEN), knowledge-base's own venv + kb-deploy
checkout for kb.nightly_runs/steps, server.heartbeat.latest_snapshot(), and
server.signal_quality.recent_runs() (NEON_CONNECTION_STRING, read-only).
Secrets come from the environment or ~/.config/op/launchd-secrets.env
— never from an `op` subprocess or shell evaluation (see secret()). Loopback only,
no auth — same posture as formserve. Idempotent to start: a second copy sees
the port taken and exits 0.
"""
from __future__ import annotations

import argparse
import ast
import concurrent.futures as cf
import datetime as dt
import hashlib
import hmac
import html
import json
import math
import os
import re
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import UUID
from pathlib import Path

# lib/ is beside this script, not on sys.path — hub.py runs from launchd with
# whatever cwd the plist gives it, so the path is derived from __file__.
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from record_store import NotClaimable, claim_and_update  # noqa: E402
import herdr_live  # noqa: E402
from form_theme import force_dark  # noqa: E402

DEFAULT_PORT = int(os.environ.get("HERDR_HUB_PORT", "8600"))
STATE = Path(os.environ.get("HERDR_STATE_ROOT", Path.home() / ".local/state/herdr"))
REGISTRY = Path(os.environ.get("HERDR_RUN_REGISTRY", STATE / "runs/registry.sqlite3"))
FORMS_DIR = STATE / "forms"
KB_DEPLOY = Path(os.environ.get("KB_DEPLOY", Path.home() / "Code/kb-deploy"))
KB_PYTHON = Path(os.environ.get("KB_PYTHON", Path.home() / "Code/knowledge-base/.venv/bin/python3"))
SEARCH_URL = os.environ.get("CONSENSUS_SEARCH_URL", "https://consensus.teamthurber.com")
LAUNCHD_SECRETS = Path(os.environ.get("HERDR_HUB_SECRETS_ENV", Path.home() / ".config/op/launchd-secrets.env"))
SECRET_NAMES = frozenset(("NEON_CONNECTION_STRING", "SEARCH_SYNC_TOKEN", "DECISIONS_MIRROR_KEY"))
KB_DASHBOARD_URL = os.environ.get("KB_DASHBOARD_URL", "https://dashboard.teamthurber.com")
# The retired tourguide decision portal. Terrence, 2026-09-23: "forms should
# never point to apps.teamthurber.com" — he answers here, on this hub. Open rows
# another session still created are LISTED (so none is invisible) but never
# linked; the fix is to supersede and re-ask here. Read through tourguide's own
# CLI from its checkout, so the hub never holds the service-role key.
TOURGUIDE_DIR = Path(os.environ.get("HERDR_TOURGUIDE_DIR", str(Path.home() / "Code/tourguide")))
# Attention means A PERSON IS THE ONE BEING WAITED FOR. `running` was in here,
# which is why clearing a stale `blocked` alone did not move the badge: an
# answered worker just swapped one attention state for another and the card
# still said "N task(s) need attention" for tasks that were working fine
# (six pages for three healthy tasks, 2026-09-12). A running task is active,
# not blocked on anybody.
# `stalled` is here because it is the state a person most needs to see and the
# one nothing used to report: a worker that took a brief and went quiet looks
# exactly like a worker that is thinking (2026-09-12, PR #313 — five review
# findings dropped, noticed an hour later only because a human asked).
#
# `input_required` is NOT here, though it was until this commit: it is an EVENT
# type (lib/push-wake.sh:130), never a task state. lib/run-registry.sh's
# `_legal_transition` has no arm for it, so every transition into it is refused
# — measured, from every source state:
#
#     <empty> -> input_required : REFUSED      blocked   -> ... : REFUSED
#     starting -> ...           : REFUSED      completed -> ... : REFUSED
#     running  -> ...           : REFUSED
#
# and the live registry holds only completed/lost/running. A prompt is recorded
# as state `blocked` PLUS an `input_required` event, so `blocked` is the state
# that needs attention and this was dead vocabulary pretending to be a case.
# ATTENTION, and the ORDER it is shown in. `ready_review` is new and it is the
# state five of this machine's tasks were actually in when the taxonomy was
# added (2026-09-18): finished workers whose panes read "awaiting PR
# review/merge decision from Terrence", every one of them filed as `stalled` —
# the state whose whole meaning is "took a brief and went quiet". The page then
# said "5 tasks need attention" for a day, about nothing that was wrong, which
# is how an attention surface stops being read.
#
# Borrowed, with attribution, from eliasstravik/herdr-projects (MIT), whose
# Group enum separates Ready-for-review from Waiting-on-you and debounces both.
# Their `Landing` (a PR open AND approved) is deliberately NOT here: this
# registry holds no PR state, and polling GitHub from the hub's read path is a
# different change with a network dependency in it.
ATTENTION = ("blocked", "stalled", "ready_review")

# DEBOUNCES, so a state that is momentary does not page. A worker is blocked
# for a second or two every time it asks anything; before this the count
# flickered with every prompt. Their values, unchanged, because they were
# measured against the same agent CLIs: 30s blocked, 60s for a launch that
# never became ready.
BLOCKED_DEBOUNCE_SECS = 30
NOT_READY_SECS = 60

# WHAT YOU HAVE ALREADY LOOKED AT. Without this, a finished-but-unmerged task
# pages forever: there is no state between "needs attention" and "resolved",
# so the only way to clear it was to close the pane. An ack is not a claim that
# the work is done — it is a record that a human has SEEN it, which is the
# honest thing the hub can know.
ACK_FILE = Path(os.environ.get("HERDR_ACK_FILE") or
                (Path.home() / ".local/state/herdr/runs/acked.json"))


def _acks() -> dict:
    """{task_id: ack marker} — never raises; an unreadable file means no acks."""
    try:
        data = json.loads(ACK_FILE.read_bytes().decode("utf-8", "replace"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}

# Every surface the team runs, hosted and local. `probe` is what "alive" means
# for it; hosted ones also get the KB heartbeat verdict when a snapshot exists.
SURFACES = [
    ("consensus·search", SEARCH_URL + "/", "GET", "search"),
    ("tourguide (apps)", "https://apps.teamthurber.com/health", "GET", "tourguide"),
    ("teamthurber.com", "https://teamthurber.com/", "HEAD", "tntpgh_actions"),
    ("thurber-ai portal", "https://tunnel.teamthurber.com/", "HEAD", "thurber_ai"),
    ("knowledge-base (Fly)", "https://thurber-kb.fly.dev/healthz", "GET", "kb"),
    ("vintageskins.com (BigCommerce)", "https://vintageskins.com/", "HEAD", None),
    ("vintageskins labels (Worker)", "https://vintageskins-labels.tnt-pgh.workers.dev/", "HEAD", None),
    ("vintageskins welcome webhook (Worker)", "https://vintageskins-welcome.tnt-pgh.workers.dev/", "HEAD", None),
    ("omp auth-gateway", "http://127.0.0.1:4000/", "HEAD", None),
    ("search dev (wrangler) · optional", "http://127.0.0.1:8799/", "HEAD", None),
]
OPTIONAL = {"search dev (wrangler) · optional"}  # a dev server being down is normal, never "hot"


# How many TTLs a `stale_ok` cache may pass off a stale value before a reader
# has to wait for a real one. 4 keeps every interactive case fast (loops 10s ->
# 40s, links 60s -> 4min) while making the first load after a quiet night fill
# inline instead of rendering yesterday's answer as today's.
# The revision this PROCESS is running, resolved once at import from the
# directory the code was loaded out of. The service runs from a deployed git
# worktree pinned detached at a commit, so this is a fact about what is serving
# — not about which branch someone has checked out. `restart.sh --verify`
# prints it, and /api/summary carries it, because "did the deploy take?" was
# previously answerable only by timing a page load and inferring.
def _running_rev() -> str:
    # `describe --always --dirty`, NOT `rev-parse`: rev-parse cannot see a
    # modified tree, so this field reported a clean sha for code that was not
    # that sha. The deploy is force+clean, so dirt can only arrive AFTER a
    # deploy — i.e. exactly the incident hand-patch case, which is when an
    # honest answer matters most. `app_rev` in launchd/agent-lib.sh was fixed
    # for this and the commit message claimed this was too; it was not.
    try:
        out = subprocess.run(["git", "-C", str(Path(__file__).resolve().parent),
                              "describe", "--always", "--dirty", "--abbrev=7"],
                             capture_output=True, text=True, timeout=5)
        rev = out.stdout.strip()
    except Exception:
        return "unknown"
    return rev or "unknown"


RUNNING_REV = _running_rev()

# The tree THIS revision ships. Scripts the hub EXECUTES must come from here,
# not from the developer checkout: `herdr-deliver.sh`, `send-to-agent.sh` and
# `formserve.py` are the control plane's two action paths (deliver an answer to
# an agent; serve a decision), and resolving them through HERDR_CONTROL left
# them following whatever branch happened to be checked out — the exact mixture
# the deployed worktree exists to prevent, in the two places where it matters
# most. Found by review of the change that introduced the worktree.
#
# HERDR_CONTROL stays as it is, deliberately: it anchors LEDGER_DIR, which is
# per-MACHINE state written by the launchd collector running the live checkout.
# Code comes from the revision; machine state comes from the machine.
APP_ROOT = Path(__file__).resolve().parent

# How long a `stale_ok` cache may pass off a stale value before a reader has to
# wait for a real one — PER SOURCE, in seconds, because `ttl x 4` was a
# convenience and different observations have different consequences when old.
# Reviewed 2026-09-16:
#
#   loops  40s   attention-adjacent: a suggestion's decision state shows here
#                and the operator acts on it. Keep it close to its own TTL.
#   links  90s   surface HEALTH. A stale "alive" is the actively misleading
#                case — this page exists to say whether prod is up — so barely
#                more than its 60s TTL.
#   search 10m   memory-use stats. Nobody acts on a ten-minute-old count, and
#                its fill is the most expensive (a paged walk).
#   kb     20m   the nightly ledger. It changes once a night; a twenty-minute
#                old read of it is the same answer.
#   deploy_drift 15m  a repo's drift state moves on the scale of a deploy,
#                not a request; ttl is already 3m ("a few minutes" per spec),
#                so this only bounds the cold-start-after-a-quiet-night case.
#
# A source absent from this map gets DEFAULT_STALE_MAX, deliberately short: a
# new network cache stays conservative until someone decides otherwise.
STALE_MAX = {"loops": 40.0, "links": 90.0, "search": 600.0, "kb": 1200.0, "deploy_drift": 900.0,
             # projects_data() can run up to ~16 sequential `gh` calls on a
             # cold fill (measured 9.2s against the live registry) — well
             # past what a 2s-budgeted caller (the ambient card, project_status)
             # can wait for. 600s means a reader more than 10 minutes past the
             # last fill pays the cold cost; anything sooner gets the stale
             # value while a background refresh runs (see Cached.get()).
             "projects": 600.0}
DEFAULT_STALE_MAX = 30.0

# No single fill may run longer than this. It is the bound that makes "refresh
# in flight" a temporary state rather than a lease of unknown length: a hung
# probe held refresh ownership for as long as its own timeouts allowed
# (`search_data`: up to 50 pages at timeout=20), during which no other refresh
# could start — and readers past the staleness ceiling launched PARALLEL inline
# probes instead of waiting. Bounding the fill closes both without a second
# mechanism.
# 70s, not 25: `kb_data` shells out with `timeout=40` and `loops_data` opens by
# reading `kb`, so it inherits that. A budget below the slowest HONEST fill
# disowns healthy refreshes and duplicates them — the opposite of the problem
# it exists to solve. It must exceed the longest legitimate fill, and every
# fill's own timeouts must be what bounds it: 40s (kb) + headroom.
FILL_BUDGET_S = 70.0

# ── tiny TTL cache: each source is fetched at most once per window ─────────────
class Cached:
    """TTL cache. `stale_ok` decides who pays for a refresh: the reader, or nobody.

    Measured 2026-09-15, cold fill per cache:

        herdr    ttl=5s     3.4ms      forms  ttl=3s     2.5ms
        search   ttl=120s  341.7ms     kb     ttl=300s  323.9ms
        links    ttl=60s   365.6ms     loops  ttl=10s   362.9ms

    The four slow ones make network calls, and `/herdr` reads `loops` — TTL
    10s — so roughly every tenth second a page load paid a ~360ms probe round
    trip inline. `/` reads all four, so a cold overview cost ~1.4s. That is the
    650ms outlier behind an otherwise 13ms page.

    `stale_ok=True` serves the stale value immediately and refreshes in a
    background thread, so a reader never waits on a network probe.

    The staleness bound is "ttl + one fill, WHILE READS KEEP ARRIVING", and
    neither half of that is what an earlier draft of this docstring claimed.
    `at` advances only when a fill completes, and a refresh is only ever kicked
    by a read, so on a sparsely-read hub the served value is as old as the last
    read — a `Cached(1, …)` last filled 10h ago will hand a reader that 10h-old
    value. And "one fill" is not ~350ms at the tail: `search_data` walks up to
    50 pages at `timeout=20` each, `kb_data` shells out with `timeout=40`,
    `loops_data` opens by reading `kb` so it inherits that 40s, and
    `links_data` probes 10 surfaces at `timeout=5` over 8 workers. Hence
    STALE_CEILING: past `ttl * STALE_CEILING` the reader pays once and gets a
    real answer, so the first load of the morning is not last night's verdicts.

    It is deliberately NOT set on `herdr` or `forms`, and the honest reason is
    narrower than "it would hide a blocked worker" — `/api/blocked` and
    `/api/blocked/wait` take the blocked SET from the subscription and use
    `CACHES["herdr"]` only to join a label onto panes already known to be
    blocked, so staleness there costs a stale label. Where it genuinely matters
    is `/herdr`, which renders entirely from this cache, and the registry half
    of `/api/summary`, which is the ONLY source for a task whose pane died
    while it was blocked. Those fill inline, where the cost is 3.4ms of noise.

    Nothing refreshes on a timer INSIDE this process: a background refresh is
    only ever kicked by a read. That is deliberate — `links_data` probes
    production surfaces, and a self-arming heartbeat against them would be an
    external effect nobody asked for.

    It does NOT follow that an unattended hub is silent, and an earlier draft of
    this docstring claimed exactly that. The pages serve
    `<meta http-equiv=refresh content=15>`, so a browser tab left open on `/`
    IS a reader: it re-reads all four network caches every 15s, all night.
    Probe volume is unchanged by the stale path — the old inline code fired on
    the same cadence, driven by the same tab — but "no reader" means no tab
    open anywhere, which is not the normal state of this machine. A multi-model
    review pass caught the claim; a curl of the served HTML confirmed it.
    """

    def __init__(self, ttl: float, fn, stale_ok: bool = False, name: str = ""):
        self.ttl, self.fn, self.stale_ok, self.name = ttl, fn, stale_ok, name
        # Per-SOURCE staleness bound, not ttl x a constant. See STALE_MAX.
        self.stale_max = STALE_MAX.get(name, DEFAULT_STALE_MAX) if stale_ok else 0.0
        self.at, self.val, self.lock = 0.0, None, threading.Lock()
        self.refreshing = False
        # When the in-flight refresh started, so ownership can be BROKEN. A
        # refresh that outruns FILL_BUDGET_S is presumed hung: it no longer
        # blocks a fresh attempt, and it can no longer write (its generation
        # is bumped), because a value fetched before an unknown-length stall
        # is not evidence about now.
        self.refresh_started = 0.0
        # Bumped by invalidate(), so a refresh that started before it lands
        # knows its snapshot is no longer wanted.
        self.gen = 0

    def _fill(self):
        try:
            return self.fn()
        except Exception:  # failed readers must not leak credentials through exception text
            return {"error": "source reader unavailable"}

    def invalidate(self):
        """Drop the value, not just its timestamp — the next read MUST refill.

        Two callers poke this cache when they have just changed the thing it
        describes (serve_form_decision, serve_loop_decision). They used to do it
        by setting `at = 0.0`, which worked only because every expiry filled
        inline. Under `stale_ok` an expired `at` takes the STALE branch instead,
        so the operator's first view after deciding showed the pre-decision
        value and `/loops` re-offered the `Decide` button for a suggestion
        already being decided — a second POST then spawns a second 4-hour
        formserve for one suggestion. Clearing `val` forces the inline path,
        because `stale_ok` only ever applies when there IS something to serve.

        `gen` also moves, so a refresh already in flight cannot land its
        pre-invalidation snapshot on top of this.
        """
        with self.lock:
            self.val, self.at, self.gen = None, 0.0, self.gen + 1

    def _refresh(self, gen: int):
        # `gen` is passed IN, captured by get() under the lock at kick time.
        # Reading it here instead was a race the suite caught: thread start is
        # asynchronous, so this body can first run AFTER an invalidate() has
        # already bumped the counter — it would then read the NEW generation,
        # believe its pre-invalidation snapshot was still wanted, and write it.
        #
        # fn() runs OUTSIDE the lock on purpose: holding it across the 360ms
        # probe would block every reader on exactly the wait this removes.
        try:
            val = self._fill()
        except BaseException:
            # `_fill` already swallows Exception, so only a BaseException
            # (an interpreter teardown, a KeyboardInterrupt) reaches here.
            # Without clearing the flag it latches True and the cache freezes
            # on a stale value with no further refresh EVER — but only clear it
            # if this thread still owns it, for the same reason as below.
            with self.lock:
                if gen == self.gen:
                    self.refreshing = False
            raise
        # ONE lock block for both writes. A `finally` that cleared the flag
        # before the value write left a window — two lock acquisitions wide,
        # no I/O between — where `refreshing` was already False while `val`
        # still held the old snapshot. A reader arriving there passes
        # `not self.refreshing` and kicks a SECOND refresh: for `links` that
        # is a duplicate probe of every production surface, which is the exact
        # externality this design exists to avoid, and for `search` a
        # duplicate authenticated 50-page walk. Narrow, but it falsified the
        # one-refresh-in-flight invariant the suite asserts.
        with self.lock:
            # Clear the flag ONLY if this thread still owns it. A refresh that
            # was disowned for outrunning the budget used to clear the flag on
            # its way out — releasing the ownership of the REPLACEMENT refresh,
            # so the next reader started a third concurrent probe. Measured at
            # 3 sweeps of every production surface for one expiry.
            if gen == self.gen:
                self.refreshing = False
                self.val, self.at = val, time.monotonic()

    def get(self):
        with self.lock:
            age = time.monotonic() - self.at
            if age <= self.ttl:
                return self.val
            # Serve stale only while a reader is plausibly watching. `at` only
            # advances when a fill COMPLETES and a refresh is only ever kicked
            # by a read, so without this ceiling the first load of the morning
            # renders last night's production-surface verdicts — where the old
            # inline code cost ~365ms and rendered the truth. Past the ceiling
            # the reader pays once and gets a real answer.
            # A refresh that has outrun the fill budget is presumed hung and
            # loses ownership: bumping `gen` also stops its eventual write.
            if self.refreshing and (time.monotonic() - self.refresh_started) > FILL_BUDGET_S:
                self.refreshing = False
                self.gen += 1
            if self.stale_ok and self.val is not None and age <= self.stale_max:
                if not self.refreshing:
                    self.refreshing = True
                    self.refresh_started = time.monotonic()
                    try:
                        threading.Thread(target=self._refresh, args=(self.gen,),
                                         daemon=True).start()
                    except RuntimeError:
                        # "can't start new thread" — reachable on a
                        # ThreadingHTTPServer parking up to WAIT_MAX_CONCURRENT
                        # long-polls. No thread exists to clear the flag.
                        self.refreshing = False
                return self.val
            # Past the bound (or staleness not allowed here): the reader pays.
            #
            # But NOT in parallel with a refresh that is already running and
            # still inside its budget — that duplicated the probe, which for
            # `links` means hitting every production surface twice. Wait for
            # the one in flight instead, up to what is left of its budget; if
            # it lands, its value is this reader's answer.
            if self.refreshing and self.val is not None:
                waited = 0.0
                while self.refreshing and waited < FILL_BUDGET_S:
                    self.lock.release()
                    try:
                        time.sleep(0.05); waited += 0.05
                    finally:
                        self.lock.acquire()
                # Freshness ONLY — not `not self.refreshing`. On a budget
                # timeout the flag can still be set while the value HAS been
                # refreshed, and gating on it sent every queued reader on to
                # its own probe (measured: 3 fills for 2 readers).
                if time.monotonic() - self.at <= self.ttl:
                    return self.val          # the in-flight refresh answered it
            self.val = self._fill()
            self.at = time.monotonic()
            return self.val


    def peek(self):
        """The current value if this cache has EVER been filled, without
        triggering a fill — for a caller with a tight latency budget
        (`/api/summary`'s consumers allow 2-5s; a cold/post-idle
        `deploy_drift` fill can cost multiple seconds) that would rather
        report "not yet checked" than pay the first reader's fill cost.
        Returns None only when nothing has EVER been filled; once filled,
        returns the same value `get()` would serve, stale or not — this is
        a peek, not a freshness check."""
        with self.lock:
            return self.val


# ── live pane truth ────────────────────────────────────────────────────────────
# The registry stores what herdr cannot know (which task, which brief, what the
# worker owes). herdr stays authoritative for liveness, and we ask it at read
# time rather than trusting the copy written into `tasks.state` at event time.
# Three rows disagreed with reality on 2026-09-12 — blocked-but-idle,
# running-after-merge, and a silently abandoned brief — because every derived
# copy of a fact eventually disagrees with the fact.
#
# The truth table for this lives in status-cases.json, and verify-hub-status.py
# asserts this code satisfies it. There is exactly ONE derivation (this file)
# and ONE liveness source (the subscription below): the shell half that used to
# duplicate this in bash had no caller, and it had already drifted from this
# code in two ways no suite could see.
TERMINAL = ("completed", "failed", "cancelled", "lost")


def pane_statuses() -> dict | None:
    """{pane_id: record} from the LIVE SUBSCRIPTION, or None if it is not up.

    Each record carries `agent_status` and `birth` — herdr's `terminal_id`, the
    pane's BIRTH fingerprint. Pane ids are RECYCLED, so a status keyed on the
    id alone can describe a DIFFERENT process that inherited the slot: a
    finished task would read `running` off a stranger, or a live one read
    `stalled`. Every other guard here already compares the birth
    (lib/pane-guard.sh, herdr-select.sh, agent-edge.sh); the derivation does too.

    This USED to shell out to `herdr pane list` behind a 3s TTL cache — one
    subprocess per cache miss, per read, forever. That is the per-tick polling
    the push-based control plane removed (84 herdr RPCs per 60s of waiting ->
    0), and keeping it would have left TWO models of live pane state inside one
    process: a 3s-stale poll and a pushed subscription, disagreeing during any
    herdr hiccup, with `/herdr` and `/api/blocked` then serving different
    answers for the same pane. That is exactly the failure this change exists
    to end, reproduced one layer up.

    None is not an empty dict: a subscription that is not connected must not
    read as "no panes exist" and mark the whole fleet `gone`.
    """
    if LIVE is None:
        return None
    data = LIVE.data()
    if not data.get("connected"):
        return None
    out: dict[str, dict] = {}
    panes = data.get("panes")
    if panes is None:
        return out                         # connected, and genuinely no panes
    if not isinstance(panes, list):
        # A connected subscription whose payload is not the documented shape is
        # a subscription that did not really answer. Reading that as "no panes
        # exist" would hand every live task a `gone` verdict off a shape
        # nothing verified.
        return None
    for p in panes:
        if isinstance(p, dict):
            pid = p.get("pane_id")
            if isinstance(pid, str) and pid:
                out[pid] = p
    return out


def _iso_epoch(s: str | None) -> float | None:
    """Registry timestamps are UTC `...Z`; mtimes are epoch seconds."""
    if not s:
        return None
    try:
        return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc).timestamp()
    except ValueError:
        return None


_DONE_RE = re.compile(rb'"event"\s*:\s*"[^"]*_done"')
_TS_RE = re.compile(rb'"(?:ts|at|time|timestamp|occurred_at)"\s*:\s*"([^"]+)"')


def _central_done_at(task_id: str) -> float | None:
    """When the CENTRAL registry recorded completion for this task, if ever.

    The worktree bus is not the only sanctioned place a worker may report
    finishing. spawn-task.sh tells every worker so in as many words: a task
    whose own effect removes its worktree should "call append_event() from
    lib/run-registry.sh directly (writes to the central registry, survives
    worktree removal)". That path existed and nothing read it — `_evidence_at`
    looked only at the bus — so a worker that took the documented advice was
    indistinguishable from one that went quiet.

    THE CONTRACT IS THE SAME `_done` SUFFIX the bus uses, and it is not
    widened here. spawn-task.sh:125 builds the wake pattern as
    `${label}_done`, `_DONE_RE` matches `"event":"..._done"`, and this matches
    an event TYPE ending in `_done`, plus the two types our own reconciler
    writes (`completion_recorded`, `completion_evidence`, lib/reconcile.sh).
    That is a SHAPE, which is the point: `worker_done` DOES count, even though
    nothing in-tree writes it, because it satisfies what spawn-task.sh:125 asks
    for. A worker may name its own event without asking permission.
    (This paragraph previously claimed the opposite — that `worker_done` was
    one of six invented spellings that do not count — while the SQL below and
    this module's own test both say it does. A comment that contradicts the
    code in the one place a reader checks this risk is worse than no comment.)

    What does NOT count is anything OFF-shape, and the live registry holds five
    such spellings workers invented for "I am done": `review.verdict`,
    `review_verdict`, `review_result`, `completion_verified` and
    `late_verified_completion`. Treating those as completion would be the hub
    divining intent from a name it does not define, which is how a stale worker
    gets read as finished. The fix for them is the brief naming the exact event,
    not this function guessing.

    One asymmetry worth knowing: SQLite `LIKE` is ASCII case-INSENSITIVE, so
    `REVIEW_DONE` matches here while the bus-side `_DONE_RE` is case-sensitive
    and would not. The two sanctioned reporting paths therefore accept slightly
    different sets. Left as is: widening the regex would be a change in the
    permissive direction on the path that has always been strict.
    """
    if not task_id or not REGISTRY.exists():
        return None
    try:
        conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
        try:
            row = conn.execute(
                "SELECT occurred_at FROM events WHERE task_id = ? "
                "AND (type LIKE '%\\_done' ESCAPE '\\' "
                "     OR type IN ('completion_recorded', 'completion_evidence')) "
                "ORDER BY sequence DESC LIMIT 1", (task_id,)).fetchone()
        finally:
            conn.close()
    except sqlite3.Error:
        return None
    return _iso_epoch(row[0]) if row else None


def _completion_at(task: dict) -> float | None | str:
    """The merged completion evidence for a task: bus and central, newest wins.

    One function because there were two copies — `derive` and `herdr_data` each
    ran the same three-line merge, so every render paid for `_evidence_at` and
    `_central_done_at` TWICE per task (measured by review: 2.2ms -> 18.4ms for
    66 tasks on a 5s-TTL read path, an 8.4x regression), and the two copies
    could drift.

    `undatable` is returned unchanged: it is not a time, and every caller has
    to decide what to do about that rather than be handed a number.
    """
    ev = _evidence_at(task.get("worktree"))
    central = _central_done_at(task.get("task_id") or "")
    if central is not None:
        ev = central if not isinstance(ev, float) else max(ev, central)
    return ev


def _bus_relpaths() -> tuple[str, ...]:
    """The handoff bus locations a READER must consider, canonical first.

    `HERDR_HANDOFF_DIR` is a supported override (lib/handoff.sh `handoff_rel`),
    and hardcoding `.handoffs` here meant that on any install that sets it, hub
    found evidence for nobody — so every finished worker derived `stalled` and,
    since `stalled` is an attention state, parked permanently in the
    needs-attention list. The shell half never had this bug; that divergence is
    precisely what the shared truth table exists to prevent, in a dimension the
    table cannot express.
    """
    rel = os.environ.get("HERDR_HANDOFF_DIR") or ".handoffs"
    return (f"{rel}/events.jsonl", ".omc/handoffs/events.jsonl")


def _evidence_at(worktree: str | None) -> float | None | str:
    """When the worker last wrote COMPLETION evidence.

    Returns an epoch float, None ("no completion evidence at all"), or the
    string "undatable" ("a _done event exists but cannot be placed in time").
    The caller must treat those three as three different answers.

    Why not the file's mtime — this is the bug this whole change exists to
    prevent, reintroduced by its own fix. Round-one review caught it: the bus
    is append-only, so ANY later line (a progress note, a `_start`, anything
    not `_done`) bumps mtime and makes round one's stale completion look newer
    than a brief delivered after it. A worker that finished round one, took a
    review brief, wrote one non-`_done` line and then went quiet would read
    `completed` — exactly PR #313's five dropped findings.

    So: date the `_done` EVENT. If it carries a timestamp, use that. If it does
    not, mtime is only honest when the `_done` line is the LAST line in the
    file, because then nothing has been appended since. Otherwise we genuinely
    cannot date it, and saying so beats guessing in the optimistic direction.

    Read as BYTES throughout. A worker that echoes one non-UTF8 byte into its
    own log used to raise UnicodeDecodeError here, which `Cached.get` catches
    as a generic Exception and replaces with an error dict — leaving `/`,
    `/herdr` and `/api/summary` reporting ZERO tasks needing attention. One
    stray byte silenced the whole attention surface, the same shape as PR #61's
    floor table. Nothing in this path may decode.
    """
    if not worktree:
        return None
    best: float | None = None
    undatable = False
    for rel in _bus_relpaths():
        p = Path(worktree) / rel
        try:
            if not p.stat().st_size:
                continue
            last_done_ts: bytes | None = None
            done_is_last = False
            with p.open("rb") as fh:
                for ln in fh:
                    if not ln.strip():
                        continue
                    if _DONE_RE.search(ln):
                        m = _TS_RE.search(ln)
                        last_done_ts = m.group(1) if m else None
                        done_is_last = True
                    else:
                        done_is_last = False      # something came after it
            if last_done_ts is None and not done_is_last:
                continue                          # no _done in this file at all
            if last_done_ts:
                ts = _iso_epoch(last_done_ts.decode("ascii", "replace"))
                if ts is not None:
                    best = ts if best is None else max(best, ts)
                    continue
            if done_is_last:
                st = p.stat().st_mtime
                best = st if best is None else max(best, st)
            else:
                undatable = True
        except OSError:
            continue
    if best is not None:
        return best
    return "undatable" if undatable else None


def derived_state(task: dict, panes: dict | None,
                  asked_at: float | None = None) -> str:
    """The state to SHOW. See `derive` for the reasoning; this drops the source."""
    return derive(task, panes, asked_at)[0]


_UNSET = object()


def derive(task: dict, panes: dict | None,
           asked_at: float | None = None, completion=_UNSET) -> tuple[str, str]:
    """(state to SHOW, where it came from) — `live`, `stored`, or `registry`.

    `asked_at` is when a brief was last delivered to this worker. Completion
    evidence OLDER than that is evidence about a previous round, not this one —
    without that comparison a worker that takes a brief and goes quiet keeps
    reporting `completed` off its last round's event, which is the exact failure
    this whole change exists to make visible.

    The SOURCE is returned because the page cannot otherwise tell a
    live-confirmed state from the registry's copy: in every fallback path the
    derived state IS the stored state, so `state_stale` is False and the row
    looked exactly like a confirmed one. `blocked` because herdr says so and
    `blocked` because herdr went quiet are different facts about whether anyone
    is actually waiting.
    """
    # An empty `state` is the registry's own initial value, before the first
    # transition (lib/run-registry.sh:390) — it means "registered, nothing has
    # happened yet", which is `starting`. It used to normalise to `unknown`,
    # which is not a state anything filters on.
    stored = task.get("state") or "starting"
    # REGISTRY-OWNED states: facts no pane status can see or contradict.
    # The terminal four, and only those — see ATTENTION for why
    # `input_required` is not a task state and cannot be one.
    if stored in TERMINAL:
        return stored, "registry"
    if panes is None:
        return stored, "stored"            # herdr down: fall back, never invent
    # A pane id from the registry is untrusted input: it is TEXT in the schema
    # but this row could hold anything, and an unhashable value (a list) raised
    # TypeError straight out of .get() — which `Cached` then turned into an
    # error dict, marking every task `gone` while `herdr_reachable` still said
    # True. Round one's "the reader is now total" was total only as far as
    # the poller; the lookup itself was not.
    pane = task.get("pane_id")
    if not isinstance(pane, str) or not pane:
        return "gone", "live"
    entry = panes.get(pane)
    if entry is None:
        return "gone", "live"
    # The record shape is the subscription's projection; a bare string or the
    # old (status, birth) tuple is still accepted so the truth-table fixtures
    # and any older caller keep working.
    if isinstance(entry, dict):
        live, birth = entry.get("agent_status") or "unknown", entry.get("birth") or ""
    elif isinstance(entry, tuple):
        live, birth = entry
    else:
        live, birth = entry, ""
    # A pane id is RECYCLED. If the task registered a birth fingerprint and the
    # live pane's differs, this slot now belongs to a different process and its
    # status says nothing about our task — the same refusal pane-guard.sh makes
    # before a keypress. `gone` rather than a guess: reconcile owns that verdict.
    #
    # An EMPTY live birth is a third case, and it is not "matches".
    # lib/herdr_live.py synthesises a record with `"birth": ""` for a status
    # change on a pane it has no snapshot for yet, documenting that empty means
    # UNKNOWN and a consumer "may only refuse on a definite disagreement". Both
    # halves of that are right, and `reg and birth and ...` honoured only one:
    # with an unidentified record the guard silently switched OFF and the task
    # read the status of whatever now holds the id — a recycled pane reporting
    # `working` for a task that is dead, which is the exact hole the guard
    # exists to close. So: refuse to use the LIVE status when identity is
    # unknown (fall back to the stored copy, as if herdr had no opinion), and
    # keep `gone` for a definite mismatch.
    reg = task.get("pane_birth") or ""
    if reg and birth and reg != birth:
        return "gone", "live"
    if reg and not birth:
        return stored, "stored"
    if live == "working":
        return "running", "live"
    # herdr's OWN `unknown` is not a task state, and it is not rare: it is what
    # herdr reports when an agent's turn-detection is quiet, which was true for
    # 12 of 14 live panes on this machine when this was written
    # (smart-name.sh:149 documents it as the normal result). Passing it through
    # produced a task whose state is in no vocabulary — not TERMINAL, not
    # ATTENTION, not a highlighted class — so the task vanished from `/`,
    # `/herdr` and `/api/summary` entirely. A blocked worker whose hooks went
    # quiet became invisible again, which is worse than the stale `blocked`
    # this whole change exists to replace.
    #
    # "herdr has no opinion" and "herdr cannot be reached" deserve the same
    # answer — the stored copy — and the SOURCE this returns is what keeps them
    # distinguishable on the page, rather than reading as a confirmed state.
    if live == "unknown":
        return stored, "stored"
    if live in ("idle", "done"):
        # The bus is not the only sanctioned reporting path (see
        # _central_done_at), and the merge lives in ONE place so the read path
        # does it once per task — `completion` is passed in by herdr_data,
        # which already has it, and computed here for every other caller.
        # `completion` may be a VALUE or a THUNK. The read path passes a thunk
        # because `derive` short-circuits before this arm for terminal, gone,
        # working, blocked and herdr-unreachable rows — most rows, most of the
        # time — and computing evidence for all of them unconditionally is what
        # made `herdr_data` 8x slower on a 5s-TTL path. Callers with a value
        # already in hand (the tests) pass it directly.
        ev = (completion() if callable(completion)
              else (_completion_at(task) if completion is _UNSET else completion))
        if ev is None:
            # A worker that has not started yet is not an abandoned brief. The
            # registry's own initial states (`starting`, and the empty string
            # before the first transition — lib/run-registry.sh:390) mean the
            # pane is idle because nothing has run in it, so `stalled` would
            # put every freshly spawned worker straight into Needs-attention.
            if stored == "starting":
                return "starting", "live"
            return "stalled", "live"       # no completion evidence at all
        if ev == "undatable":
            # A `_done` exists but something was appended after it, so it
            # cannot be placed against the ask. With no ask on record, take it;
            # with one, refuse to assume it answered THIS round.
            return ("stalled", "live") if asked_at is not None else ("completed", "live")
        if asked_at is not None and ev < asked_at:
            return "stalled", "live"       # answered an older round, not this one
        # FINISHED, and the question is whether anybody has looked. Completion
        # is not the end of the work: a review whose verdict is posted and a
        # branch whose PR is open both need a decision that is not the worker's
        # to make. `completed` retires the row from every attention surface, so
        # before this the only states available were "pages forever" and
        # "invisible".
        #
        # `ready_review` is the middle: it needs you, it is not a fault, and an
        # ack clears it without pretending the task is resolved. The marker
        # compared is the EVIDENCE TIME, so a worker that reports again after
        # you acked (a second round, a follow-up) comes back — acking round one
        # does not silence round two.
        acked = _acks().get(task.get("task_id") or "")
        if isinstance(acked, (int, float)) and acked >= ev:
            return "completed", "live"
        return "ready_review", "live"
    if live == "blocked":
        # DEBOUNCED. A worker is blocked for a second or two every time it asks
        # anything, so an undebounced count flickered with every prompt and the
        # page cried wolf. `updated_at` is when the registry last saw this state
        # change; below the threshold the task is still working as far as anyone
        # needs to care.
        since = _iso_epoch(task.get("updated_at"))
        age = None if since is None else time.time() - since
        # A NEGATIVE age is SKEW, not freshness. `time.time() - since` for an
        # `updated_at` ahead of the clock is negative, which also satisfies
        # `< DEBOUNCE` — so a task a year ahead never pages again, on any
        # surface, because `blocked` is derived only here. Reachable two ways
        # without anyone doing anything wrong: lib/run-registry.sh's
        # `import_tasks` inserts `updated_at` verbatim from migrated task JSON,
        # and `_now_iso` is `date -u`, so any backward clock step (an NTP
        # correction after a wrong-clock boot, a VM or laptop resume) leaves
        # stored stamps in the future. `_age` already carries this precedent.
        if age is not None and 0 <= age < BLOCKED_DEBOUNCE_SECS:
            return "running", "live"
        return "blocked", "live"
    # An agent_status this code does not know is NOT a task state either. Same
    # reasoning as `unknown`: inventing a vocabulary entry hides the task from
    # every surface that filters on one.
    return stored, "stored"


# ── herdr registry ─────────────────────────────────────────────────────────────
def herdr_data(event_limit: int = 100) -> dict:
    if not REGISTRY.exists():
        return {"error": f"registry not found: {REGISTRY}", "tasks": [], "attention": [], "events": [], "checkpoints": []}
    conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
    conn.row_factory = sqlite3.Row
    try:
        # branch/project were added by lib/run-registry.sh's v4/v5 ALTERs.
        # This connection is read-only (mode=ro) and cannot run them itself,
        # so a registry a bash script hasn't touched yet (spawn-task.sh,
        # claim.sh, …) since this hub's own deploy would otherwise 500 the
        # whole page on "no such column" — checked once per call rather than
        # assumed, so the join degrades to empty strings instead of crashing
        # until the first bash writer migrates the file.
        cols = {r[0] for r in conn.execute("SELECT name FROM pragma_table_info('tasks')")}
        branch_col = "branch" if "branch" in cols else "'' AS branch"
        project_col = "project" if "project" in cols else "'' AS project"
        cpid_col = "conductor_pane_id" if "conductor_pane_id" in cols else "'' AS conductor_pane_id"
        cpbirth_col = "conductor_pane_birth" if "conductor_pane_birth" in cols else "'' AS conductor_pane_birth"
        pbirth_col = "pane_birth" if "pane_birth" in cols else "'' AS pane_birth"
        tasks = [dict(r) for r in conn.execute(
            "SELECT task_id, run_id, label, repo, state, pane_id, conductor_id, "
            f"{pbirth_col}, {cpid_col}, {cpbirth_col}, worktree, "
            f"{branch_col}, {project_col}, created_at, updated_at "
            "FROM tasks ORDER BY updated_at DESC")]
        events = []
        for r in conn.execute(
                # Review L4: stall-watchdog's own bookkeeping rows (first-seen
                # claim, the boot floor, the durable answered marker) carry no
                # human-meaningful content — filtered out of the feed a human
                # or conductor actually reads; stall_wake/acked/escalate stay
                # visible, those ARE real watchdog activity.
                "SELECT sequence, type, task_id, occurred_at, payload FROM events "
                "WHERE type NOT IN ('stall_watchdog_epoch','stall_request_claim',"
                "'stall_request_answered') ORDER BY sequence DESC LIMIT ?", (event_limit,)):
            e = dict(r)
            try:
                e["payload"] = json.loads(e["payload"] or "{}")
            except json.JSONDecodeError:
                e["payload"] = {"_raw": e["payload"]}
            events.append(e)
        checkpoints = [dict(r) for r in conn.execute(
            "SELECT conductor_id, last_event_seq, updated_at FROM checkpoints ORDER BY updated_at DESC LIMIT 12")]
        max_seq = conn.execute("SELECT COALESCE(MAX(sequence),0) FROM events").fetchone()[0]
        # When each worker was last handed a brief — the anchor that makes
        # "did it do what I last asked?" answerable at all.
        asked = {r[0]: r[1] for r in conn.execute(
            "SELECT task_id, MAX(occurred_at) FROM events WHERE type='brief_delivered' "
            "GROUP BY task_id")}
        # The closure reason/proof a REAL registry transition recorded — item
        # 1's "the hub shows a task as done only from the registry
        # transition, with its reason": a `completed` row with nothing here
        # is a completion this gate never actually saw (pre-gate data, or a
        # direct DB edit), and the page says so rather than inventing one.
        # Ascending order + dict overwrite: the LAST transition into
        # `completed` for a task_id wins, matching set_task_state's own
        # terminal-once invariant (there is normally exactly one).
        closure_reasons: dict[str, dict] = {}
        for r in conn.execute(
                "SELECT task_id, payload FROM events WHERE type='state_changed' "
                "AND json_extract(payload,'$.state')='completed' ORDER BY sequence"):
            try:
                p = json.loads(r["payload"] or "{}")
            except json.JSONDecodeError:
                p = {}
            if p.get("reason"):
                closure_reasons[r["task_id"]] = {"reason": p["reason"], "proof": p.get("proof")}
    finally:
        conn.close()
    labels = {t["task_id"]: t["label"] or t["task_id"] for t in tasks}
    for e in events:
        e["label"] = labels.get(e["task_id"], e["task_id"])
    # Derive at READ time. `stored_state` is kept alongside so a divergence is
    # visible rather than silently papered over — when they disagree the row
    # itself is evidence that something never transitioned.
    #
    # `state_source` is kept for the case `state_stale` cannot see: every
    # fallback path RETURNS the stored state, so the two agree and the row
    # looked live-confirmed. A reader has to be able to tell "herdr says
    # blocked" from "herdr went quiet and this is the last thing we recorded".
    panes = pane_statuses()
    for t in tasks:
        t["stored_state"] = t["state"]
        # ONE evidence computation per task, and only if the derivation
        # actually reaches the arm that needs it — a memoised thunk rather than
        # an eager call, because most rows short-circuit first.
        _cell: dict = {}
        def _comp(_t=t, _cell=_cell):
            if "v" not in _cell:
                _cell["v"] = _completion_at(_t)
            return _cell["v"]
        t["state"], t["state_source"] = derive(
            t, panes, _iso_epoch(asked.get(t["task_id"])), completion=_comp)
        _comp_value = _cell.get("v")
        # The evidence time, exposed because ack.sh binds an acknowledgement to
        # it rather than to `now`: acking must not swallow a report that lands
        # while the operator is typing the command.
        #
        # Published ONLY for the states that were actually derived FROM it.
        # Before this it was published for every row, including ones derive
        # short-circuits before ever looking at evidence (terminal, gone,
        # working, blocked, herdr-unreachable) — and that value is exactly what
        # ack.sh trusted as "this row is acknowledgeable", so an ack could be
        # written against a blocked or stalled task and lie in wait.
        t["evidence_at"] = (_comp_value if isinstance(_comp_value, float)
                            and t["state"] in ("ready_review", "completed") else None)
        c = closure_reasons.get(t["task_id"]) or {}
        t["closure_reason"] = c.get("reason")
        t["closure_proof"] = c.get("proof")
        t["state_stale"] = t["state"] != t["stored_state"]
    attention = sorted((t for t in tasks if t["state"] in ATTENTION),
                       key=lambda t: (ATTENTION.index(t["state"]), t["updated_at"]))
    return {"tasks": tasks, "attention": attention, "events": events,
            "checkpoints": checkpoints, "max_event_seq": max_seq,
            "herdr_reachable": panes is not None}


# ── live herdr state: pushed by subscription, never scraped ────────────────────
# The registry above is the DURABLE record — task identity, conductor routing,
# the event log. It is written by scripts, so `tasks.state` is only as fresh as
# the last writer, and a card reading "running" for a worker that has been
# sitting on an approval menu for an hour is the exact failure this pairs with:
# on 2026-09-12 a session escalated two tasks as blocked off status labels that
# were already `completed`, and on 2026-09-14 the reverse (a live-blocked pane
# the registry had not caught up to) kept every tool call in every pane paying
# for a pending-alert sweep.
#
# So the hub now holds ONE long-lived `events.subscribe` connection to herdr
# (lib/herdr_live.py) and treats herdr's own agent_status as authoritative for
# "is a human being waited for". The registry stays authoritative for identity.
# Where they disagree, the page SAYS SO rather than picking silently.
LIVE: herdr_live.LiveState | None = None
AGENT_EDGE = Path(__file__).resolve().parent / "agent-edge.sh"
HUB_CONNECTION_ALERT = Path(__file__).resolve().parent / "hub-connection-alert.sh"
DEPLOY_DRIFT_ALERT = Path(__file__).resolve().parent / "deploy-drift-alert.sh"
# thurber-os docs/project-contract-plan.md §3a — the level-triggered
# attention controller. See attention-tick.sh's own header for the design;
# this hub thread only feeds it the CURRENTLY blocked pane ids and reuses
# live_attention() (already joins herdr_live.py's LiveState to the registry)
# instead of re-deriving "who's blocked" a second way.
ATTENTION_SCRIPT = Path(__file__).resolve().parent / "attention-tick.sh"


def _live_log(msg: str) -> None:
    print(f"hub: live: {msg}", file=sys.stderr, flush=True)


def edge_is_actionable(before: str | None, after: str | None) -> bool:
    """Which transitions are worth a subprocess.

    A busy agent pane flips working<->idle on every turn. Dispatching those
    would spawn a shell per flap per pane to conclude "noop" — the same
    busywork this whole change removes — so only three cases reach the script:

      * something became `blocked` (a human is now being waited for),
      * something WAS `blocked` (the prompt was answered: retract and follow),
      * a first observation (`before` is None), which is the reconcile pass a
        hub start owes the registry.
    """
    if before is None:
        return True
    return herdr_live.BLOCKED in (before, after)


# In-flight edge scripts. Each blocked edge holds a shell for the whole grace
# window, and `blocked` is the fleet's highest-frequency transition under
# --approval-mode write, so an uncapped fan-out is a real process bomb: the
# edge queue's maxsize protects the STREAM thread, not the machine, because
# Popen returns immediately and nothing applies back-pressure. Past the cap we
# drop the edge and say so in the log rather than forking anyway — state stays
# correct either way (the next transition or a periodic resync re-derives it).
EDGE_MAX_INFLIGHT = int(os.environ.get("HERDR_EDGE_MAX_INFLIGHT", "12"))
_EDGE_INFLIGHT: list[subprocess.Popen] = []
# Per-pane coalescing (2026-09-25, edge-slot-starvation): two panes flipping
# blocked<->working every few seconds under --approval-mode write filled all
# 12 slots with handlers for THEMSELVES — each blocked edge forks a fresh
# agent-edge.sh that holds its slot for the whole grace window (measured
# 46-83s) even though its own peer-answer call finished in the first second.
# A pane in mid-flap can rack up a dozen such handlers well before the first
# one's grace timer expires, starving every OTHER pane's edge (`edge dropped
# ... 12 already in flight`, 782 times in one incident).
#
# At most one live handler per pane fixes this at the source: a new
# actionable edge for a pane that already has one SUPERSEDES it (SIGTERM,
# `_edge_supersede`) rather than piling on. This is strictly better than
# letting the old one run to grace expiry — its prompt is superseded by
# definition (the pane moved again), so nothing it could still do (probe,
# backstop-alert) would describe the pane's current state. A live process
# killed mid-sleep cannot deliver that stale backstop alert; the fresh
# handler this spawns immediately runs peer-answer against the pane's
# CURRENT prompt instead.
_EDGE_INFLIGHT_BY_PANE: dict[str, subprocess.Popen] = {}
_EDGE_LOCK = threading.Lock()

# Parked /api/blocked/wait requests. One per supervisor is the expected load;
# the cap exists so a local process cannot turn a thread-per-connection server
# into a wedged one (see the handler).
WAIT_MAX_CONCURRENT = int(os.environ.get("HERDR_HUB_MAX_WAITERS", "32"))
_WAITERS = {"n": 0}
_WAITERS_LOCK = threading.Lock()


def _edge_slot() -> bool:
    """Reap finished edge children, then take a slot if one is free."""
    with _EDGE_LOCK:
        _EDGE_INFLIGHT[:] = [p for p in _EDGE_INFLIGHT if p.poll() is None]
        for pane_id, p in list(_EDGE_INFLIGHT_BY_PANE.items()):
            if p.poll() is not None:
                del _EDGE_INFLIGHT_BY_PANE[pane_id]
        if len(_EDGE_INFLIGHT) >= EDGE_MAX_INFLIGHT:
            return False
        return True


def _edge_supersede(pane_id: str) -> None:
    """Kill this pane's existing edge handler, if one is still alive.

    Called before every spawn so a flapping pane never holds more than one
    slot. `terminate()` sends SIGTERM to the handler's own bash process (its
    `start_new_session=True` makes it a session leader, not a child of this
    process, but still a direct signal target); the script installs no trap,
    so bash's default disposition ends it immediately, mid `sleep "$GRACE"` if
    that is where it is. Freed here, not left to expire on its own timer.
    """
    with _EDGE_LOCK:
        old = _EDGE_INFLIGHT_BY_PANE.pop(pane_id, None)
        if old is not None and old.poll() is None:
            try:
                old.terminate()
            except OSError:
                pass
            _EDGE_INFLIGHT[:] = [p for p in _EDGE_INFLIGHT if p is not old]


def _on_agent_edge(pane_id: str, before: str | None, after: str | None, rec: dict) -> None:
    """One transition, handed to the shell that owns alerting and answering.

    Fire-and-forget by construction: the edge script does Slack, push-wake and
    peer-answer work that must never be able to stall the subscription or the
    page. `before` is empty on first observation (process start or reconnect
    diff) — the script treats that as "reconcile", not "a prompt just
    appeared", because a fresh hub must not re-alert a prompt already alerted.

    `cwd` comes from LIVE.cwd_of(), not from the served record: absolute paths
    are not published on the unauthenticated API (see _pane_record), but the
    script still wants one for its Slack line.
    """
    if not AGENT_EDGE.exists():
        return
    if not rec.get("agent"):
        return  # a plain shell pane has no prompt to alert and no task to follow
    if not edge_is_actionable(before, after):
        return
    _edge_supersede(pane_id)
    if not _edge_slot():
        _live_log(f"edge dropped for {pane_id} {before}->{after}: "
                  f"{EDGE_MAX_INFLIGHT} already in flight")
        return
    try:
        child = subprocess.Popen(
            ["bash", str(AGENT_EDGE), pane_id, after or "gone", before or "",
             rec.get("agent") or "", (LIVE.cwd_of(pane_id) if LIVE else ""),
             rec.get("birth") or ""],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        with _EDGE_LOCK:
            _EDGE_INFLIGHT.append(child)
            _EDGE_INFLIGHT_BY_PANE[pane_id] = child
    except OSError as exc:
        _live_log(f"edge spawn failed for {pane_id}: {exc}")


def _on_connection_change(connected: bool, err: str | None) -> None:
    """The herdr subscription itself went up or down — the ONE symptom no
    per-pane alert can see, because while it is down every consumer (agent-
    edge.sh's own probe included) is guessing rather than knowing.

    Fires on a genuine flip only (LiveState debounces same-state re-affirms),
    so this is called at most once per real outage and once per recovery —
    hub-connection-alert.sh still applies its own grace window before paging,
    so a reconnect that lands within a few seconds never reaches Slack.
    """
    if not HUB_CONNECTION_ALERT.exists():
        return
    if not _edge_slot():
        _live_log(f"connection-alert dropped ({'connected' if connected else 'disconnected'}): "
                  f"{EDGE_MAX_INFLIGHT} edge slots already in flight")
        return
    try:
        child = subprocess.Popen(
            ["bash", str(HUB_CONNECTION_ALERT), "connected" if connected else "disconnected",
             (err or "")[:200]],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        with _EDGE_LOCK:
            _EDGE_INFLIGHT.append(child)
    except OSError as exc:
        _live_log(f"connection-alert spawn failed: {exc}")


def live_data() -> dict:
    if LIVE is None:
        return {"connected": False, "panes": [], "blocked": [], "agents": [],
                "stats": {"last_error": "watcher not started"}}
    return LIVE.data()


def live_attention() -> list[dict]:
    """Panes herdr says are waiting on a person, joined to their task label."""
    live = live_data()
    if not live.get("connected"):
        return []
    tasks = {t.get("pane_id"): t for t in (CACHES["herdr"].get() or {}).get("tasks", [])}
    out = []
    for pane in live.get("blocked", []):
        task = tasks.get(pane["pane_id"]) or {}
        out.append({**pane, "label": task.get("label") or pane.get("label") or pane["pane_id"],
                    "task_id": task.get("task_id"), "registry_state": task.get("state")})
    return out


# ── formserve registry ─────────────────────────────────────────────────────────
def port_open(port: int, host: str = "127.0.0.1", timeout: float = 0.3) -> bool:
    with socket.socket() as s:
        s.settimeout(timeout)
        return s.connect_ex((host, port)) == 0


def form_html(form_id: str) -> Path:
    """Where the hub keeps its own copy of a form's HTML.

    The copy is what makes a decision durable. formserve's own port dies the
    moment it collects an answer (and dies WITHOUT collecting one if its
    process is killed or the machine sleeps), which used to leave a form
    listed `open` at a URL that no longer answered — observed 2026-09-09 on
    the eBay Hunter `rev 1` form, marked `gone`, unanswerable. With the HTML
    here, the hub can serve and accept that same form itself, for as long as
    the registry row exists.
    """
    return FORMS_DIR / f"{form_id}.html"


def forms_data() -> dict:
    forms = []
    now_ms = int(time.time() * 1000)
    if FORMS_DIR.is_dir():
        for p in sorted(FORMS_DIR.glob("*.json"), reverse=True):
            try:
                f = json.loads(p.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            # formserve lifts the title out of the form's <h1> and strips tags but
            # not entities, so a title with "&" arrives as "&amp;" and _esc() then
            # double-escapes it into a visible "&amp;". Decode once, here, so every
            # consumer (page, iframe title, /api) gets the human string.
            if f.get("title"):
                f["title"] = html.unescape(f["title"])
            f["hub_servable"] = form_html(f["id"]).exists()
            if f["hub_servable"]:
                f["hub_url"] = f"/decisions/{f['id']}"
            if f.get("status") == "open":
                exp = f.get("expires_at")
                if exp and now_ms > int(exp):
                    # An expired form is still unanswered — never "declined".
                    f["status"] = "expired"
                elif not f["hub_servable"] and not port_open(int(f.get("port", 0) or 0)):
                    # Pre-hub form whose server died without recording an outcome.
                    # A hub-servable one is NEVER gone: this page can still answer it.
                    f["status"] = "gone"
            forms.append(f)
    open_forms = [f for f in forms if f["status"] == "open"]
    return {"open": open_forms, "history": [f for f in forms if f["status"] != "open"][:30],
            "open_count": len(open_forms)}


def portal_data() -> dict:
    """Open rows in the decision portal. Terrence, 2026-09-23: the local
    dashboard must list them — questions sat there unseen because only served
    forms appeared here. An unreadable portal is SAID, never shown as "0 open":
    silence would read as nothing waiting."""
    cli = TOURGUIDE_DIR / "scripts" / "decision.mjs"
    if not cli.exists():
        return {"open": [], "open_count": 0, "error": f"{cli} not found"}
    try:
        r = subprocess.run(["node", str(cli), "list", "--status", "open"], cwd=TOURGUIDE_DIR,
                           capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            return {"open": [], "open_count": 0,
                    "error": f"decision.mjs exit {r.returncode}: {(r.stderr or '').strip()[:200]}"}
        rows = json.loads(r.stdout or "[]")
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        return {"open": [], "open_count": 0, "error": f"{type(e).__name__}: {e}"}
    rows = [{k: x.get(k) for k in ("gate", "decision_id", "question", "assignee", "created_at", "recommendation")}
            for x in rows if isinstance(x, dict) and x.get("status") == "open"]
    rows.sort(key=lambda x: x.get("created_at") or "", reverse=True)
    return {"open": rows, "open_count": len(rows), "error": None}


# ── answering a form from the hub itself ──────────────────────────────────────
# The hub serves the stored HTML with this shim appended, so a form authored for
# formserve needs no change: it still calls window.submitAnswers().
HUB_SUBMIT_SHIM = """
<input type="hidden" id="__formserve_token" value="%(token)s">
<script>
(function () {
  window.submitAnswers = function (answers) {
    var body = Object.assign({}, answers === undefined ? {} : answers);
    body.__formserve_token = document.getElementById("__formserve_token").value;
    return fetch("%(action)s", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then(function (r) {
      if (!r.ok) return r.text().then(function (t) { throw new Error(r.status + ": " + t); });
      document.querySelectorAll("button,input,select,textarea").forEach(function (el) { el.disabled = true; });
      var b = document.createElement("div");
      b.setAttribute("role", "status");
      b.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:99999;padding:14px 18px;" +
        "font:600 14px system-ui,sans-serif;text-align:center;background:#1f6e7e;color:#fff";
      b.textContent = "Answer recorded in the hub. The agent has been notified.";
      document.body.appendChild(b);
      return true;
    }).catch(function (e) {
      var b = document.createElement("div");
      b.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:99999;padding:14px 18px;" +
        "font:600 14px system-ui,sans-serif;text-align:center;background:#a83a2f;color:#fff";
      b.textContent = "Could not record answer: " + e.message;
      document.body.appendChild(b);
      throw e;
    });
  };
})();
</script>
"""


def _form_row(form_id: str) -> tuple[Path, dict] | tuple[None, None]:
    """Registry row for an id, or (None, None). The id is path-validated: it
    indexes a file under FORMS_DIR, so anything but the generated shape is
    refused rather than joined onto a path."""
    if not re.fullmatch(r"[0-9A-Za-z._-]{1,120}", form_id or ""):
        return None, None
    path = FORMS_DIR / f"{form_id}.json"
    try:
        return path, json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None, None


def serve_stored_form(form_id: str) -> tuple[int, bytes]:
    """The form's own HTML, plus the submit shim, at a URL that outlives its
    creating process. An already-answered form is shown read-only."""
    _, row = _form_row(form_id)
    if row is None:
        return 404, b"no such decision"
    body = form_html(form_id)
    if not body.exists():
        return 404, b"this decision predates hub-served forms; use its own port"
    try:
        raw = force_dark(body.read_text())
    except OSError:
        return 500, b"decision body unreadable"
    if row.get("status") != "open":
        answers = json.dumps(row.get("answers") or {}, indent=1, sort_keys=True)
        banner = (f"<div style=\"position:sticky;top:0;z-index:99999;padding:12px 16px;"
                  f"background:#1f6e7e;color:#fff;font:600 14px system-ui\">"
                  f"{_esc(row['status'])}"
                  + (f" · answered {_age(row.get('answered_at'))} ago" if row.get("answered_at") else "")
                  + f"<pre style=\"margin:8px 0 0;font:12px ui-monospace;white-space:pre-wrap\">{_esc(answers)}</pre></div>")
        # Insert after <body> so the banner is inside the document, and neuter
        # the form: an answered decision must not look re-answerable.
        frozen = ("<script>document.addEventListener('DOMContentLoaded',function(){"
                  "document.querySelectorAll('button,input,select,textarea')"
                  ".forEach(function(el){el.disabled=true;});});</script>")
        m = re.search(r"<body[^>]*>", raw, re.I)
        out = (raw[:m.end()] + banner + raw[m.end():]) if m else banner + raw
        out = out.replace("</body>", frozen + "</body>") if "</body>" in out else out + frozen
        return 200, out.encode()
    shim = HUB_SUBMIT_SHIM % {"token": _esc(row.get("token") or ""),
                              "action": f"/decisions/{form_id}/submit"}
    out = raw.replace("</body>", shim + "</body>") if "</body>" in raw else raw + shim
    return 200, out.encode()


def record_answer(form_id: str, payload: dict) -> tuple[int, bytes]:
    """Write an answer into the registry, then notify the waiting agent.

    Same token posture as formserve: this endpoint is unauthenticated loopback,
    so any local process could otherwise POST a fabricated answer that then
    gets typed into a live agent pane. The token is generated per form and
    embedded only in the HTML the hub actually served.
    """
    path, row = _form_row(form_id)
    if row is None:
        return 404, b"no such decision"
    token = row.get("token") or ""
    submitted = payload.pop("__formserve_token", None)
    if not token or not isinstance(submitted, str) or not hmac.compare_digest(submitted, token):
        return 403, b"forbidden: missing or invalid token"
    # The status read above is already stale — formserve's own port may answer
    # between it and this line. claim_and_update re-reads under an exclusive
    # lock and writes via rename, so the loser genuinely loses (409) instead of
    # overwriting a recorded answer, and a crash can't leave a half-written
    # decision record. See lib/record_store.py.
    # Expiry is enforced HERE, under the lock, not only in the rendered list.
    # forms_data() flipped `expired` in the loaded dict for display, but this
    # path re-read the record and would accept an answer to a form whose
    # expires_at had passed hours earlier - the exact case the hub copy exists
    # for, since the original server is gone by then (two-model review,
    # 2026-09-09). Raising NotClaimable inside the callback rejects it under the
    # same lock that protects against the double-answer.
    def _answer(row: dict) -> dict:
        exp = row.get("expires_at")
        if isinstance(exp, (int, float)) and exp > 0 and time.time() * 1000 > exp:
            raise NotClaimable("expired", row)
        row.update(status="answered", answers=payload,
                   answered_at=int(time.time() * 1000), answered_via="hub")
        return row

    try:
        row = claim_and_update(path, _answer)
    except NotClaimable as e:
        if e.state == "expired" and e.row.get("status") == "open":
            return 410, b"expired: this decision passed its deadline and is still unanswered; re-serve it"
        return 409, f"already {e.state}".encode()
    except FileNotFoundError:
        return 404, b"no such decision"
    except json.JSONDecodeError as e:
        return 500, f"decision record is corrupt: {e}".encode()
    except OSError as e:
        return 500, f"could not record: {e}".encode()
    CACHES["forms"].invalidate()
    notify_owner(row)
    key = _sidecar_key(row.get("form_path"))
    if key and key.startswith(RATINGS_KEY_PREFIX):
        _dispatch_ratings_answer(key[len(RATINGS_KEY_PREFIX):], row)
    return 200, b'{"ok":true}'


def notify_owner(row: dict) -> None:
    """Push the answer to the agent that asked, using the delivery leaf that
    already handles the two ways this strands (a reaped background task
    splitting type from Enter, and a large paste being collapsed).

    Honest limitation: omp's own agent inbox is in-process — there is no CLI to
    post into it — so "push" here means the herdr pane leaf, exactly as
    formserve --deliver does. An agent with no pane target still finds the
    answer in the registry and on this page; nothing is lost, it just has to look.
    """
    target = row.get("deliver_to")
    if not target:
        return
    leaf = APP_ROOT / "herdr-deliver.sh"
    if not leaf.exists():
        leaf = APP_ROOT / "send-to-agent.sh"
    if not leaf.exists():
        return
    via = ("\nAnswered on dashboard.teamthurber.com by " + str(row.get("answered_by") or "?")
           if row.get("answered_via") == "dashboard" else "")
    text = ("Form answers from the hub (" + str(row.get("title") or row.get("id")) + "):\n"
            + json.dumps(row.get("answers") or {}, indent=2, sort_keys=True) + via)
    # `--reply`, not a brief: this is an ANSWER to something the agent asked.
    # Without the flag this delivery records `brief_delivered`, which moves the
    # `asked_at` anchor and makes the worker's existing completion evidence
    # look like it answered an older round — so answering a form parked the
    # task in Needs-attention as `stalled`, permanently. send-to-agent.sh (the
    # fallback leaf) records nothing, so it takes no flag.
    argv = [str(target), text] if leaf.name == "send-to-agent.sh" else ["--reply", str(target), text]
    try:
        subprocess.run(["bash", str(leaf), *argv], capture_output=True, text=True,
                       timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass  # the answer is recorded; delivery is best-effort by design


# ── remote mirror: dashboard.teamthurber.com/decisions ────────────────────────
# Terrence, 2026-09-23: answer the same forms away from the Mac. Every
# MIRROR_EVERY_S the hub publishes its open forms to kb.hub_forms (KB's
# server/hub_forms.py, run in KB's own venv from the kb-deploy checkout, the
# same way kb_data() reads), closes finished ones, and pulls answers made on
# the dashboard.
#
# kb.hub_forms is NOT trusted (security review 2026-09-23, F1): everyone with
# the Neon DSN can write it, and an answer is typed into a live agent pane. So
# a pending answer is delivered only if it carries a valid MAC under
# DECISIONS_MIRROR_KEY, over a nonce only this hub can derive (from the form's
# secret local token), from an address on HERDR_DECISIONS_OWNERS. Anything else
# is acked `rejected` and never reaches notify_owner. What the hub publishes
# (id, nonce, title, HTML) is signed the same way, so the dashboard refuses a
# form a DSN holder altered. The key stops REMOTE DSN holders (CI, other Fly
# code paths, the KB MCP env, kb-deploy). It does not stop a process running as
# this user, or anything with the ambient 1Password read token — those can
# already forge a local answer through this hub's unauthenticated loopback.
#
# A remote answer is only a REQUEST until recorded here under the same lock a
# local answer takes: the loser of a race is acked `conflict`, local stands.
MIRROR_EVERY_S = float(os.environ.get("HERDR_MIRROR_EVERY_S", "20"))
MIRROR_STATE: dict = {"last_ok": None, "last_error": None, "published": 0, "pulled": 0,
                      "rejected": 0, "last_rejection": None}
_MIRROR_ACKS: list[dict] = []
MAX_REMOTE_ANSWER_BYTES = 64_000


def _decisions_owners() -> set[str]:
    raw = os.environ.get("HERDR_DECISIONS_OWNERS", "tnt@teamthurber.com")
    return {e.strip().lower() for e in raw.split(",") if e.strip()}


def _mirror_key() -> bytes:
    k = secret("DECISIONS_MIRROR_KEY") or ""
    if len(k) < 32:
        raise RuntimeError("DECISIONS_MIRROR_KEY unavailable (hub launchd secrets)")
    return k.encode()


def _mirror_mac(key: bytes, *parts: str) -> str:
    # Byte-for-byte the scheme in knowledge-base server/hub_forms.py _mac().
    return hmac.new(key, "\x1f".join(parts).encode(), hashlib.sha256).hexdigest()


def _mirror_canonical(answers: dict) -> str:
    return json.dumps(answers, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _mirror_nonce(key: bytes, form_id: str, token: str) -> str:
    return _mirror_mac(key, "nonce", form_id, token)[:32]


def record_remote_answer(form_id: str, pending: dict, key: bytes) -> str:
    """Verify a dashboard answer, then record it through the local registry.
    -> ack outcome. Verification happens BEFORE claim_and_update: a rejected
    answer changes nothing and is never delivered."""
    path, row = _form_row(form_id)
    if row is None:
        return "missing"
    answers, by = pending.get("answers"), str(pending.get("answered_by") or "").strip().lower()
    token = row.get("token") or ""

    def _reject(why: str) -> str:
        MIRROR_STATE["rejected"] += 1
        MIRROR_STATE["last_rejection"] = f"{form_id}: {why}"
        return "rejected"

    if not isinstance(answers, dict):
        return _reject("answers are not an object")
    canon = _mirror_canonical(answers)
    if len(canon.encode()) > MAX_REMOTE_ANSWER_BYTES:
        return _reject("answers too large")
    if by not in _decisions_owners():
        return _reject(f"answered_by {by or '(none)'} is not a decisions owner")
    if not token:
        return _reject("local form has no token to derive a nonce from")
    nonce = _mirror_nonce(key, form_id, token)
    if not hmac.compare_digest(str(pending.get("nonce") or ""), nonce):
        return _reject("nonce does not match the published form")
    want = _mirror_mac(key, "answer", form_id, nonce, canon, by)
    if not hmac.compare_digest(str(pending.get("answer_sig") or ""), want):
        return _reject("answer signature invalid")

    def _answer(r: dict) -> dict:
        exp = r.get("expires_at")
        if isinstance(exp, (int, float)) and exp > 0 and time.time() * 1000 > exp:
            raise NotClaimable("expired", r)
        r.update(status="answered", answers=answers, answered_at=int(time.time() * 1000),
                 answered_via="dashboard", answered_by=by)
        return r

    try:
        row = claim_and_update(path, _answer)
    except NotClaimable as e:
        if e.state == "expired":
            return "expired"
        # A lost ack after a hub restart: this very answer is already recorded.
        if e.row.get("answered_via") == "dashboard" and e.row.get("answers") == answers:
            return "delivered"
        return "conflict"
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return "missing"
    CACHES["forms"].invalidate()
    notify_owner(row)
    key = _sidecar_key(row.get("form_path"))
    if key and key.startswith(RATINGS_KEY_PREFIX):
        _dispatch_ratings_answer(key[len(RATINGS_KEY_PREFIX):], row)
    return "delivered"


def _dispatch_ratings_answer(run_id: str, row: dict) -> None:
    """Write the hub's ratings answers into kb.section_ratings, channel='hub'
    (server/ratings.py's `hub-answer` CLI -- the one write path, never a bare
    INSERT, so the one-live-row invariant and the 24h correction window are
    enforced identically to the mailed /rate link). Best-effort, off a
    background thread: the answer is ALREADY durably recorded in the local
    hub registry by the caller (above) regardless of whether this KB write
    succeeds -- a failure here is logged to stderr, never raised, and never
    loses the recorded local answer, and never delays the submit response."""
    answers = (row.get("answers") or {}).get("ratings")
    if not isinstance(answers, dict) or not answers:
        return
    payload = {"run_id": run_id, "attempt_number": 1,
               "answers": [{"section_key": k, "rating": v} for k, v in answers.items()]}
    threading.Thread(target=_dispatch_ratings_answer_now, args=(run_id, payload),
                     daemon=True).start()


def _dispatch_ratings_answer_now(run_id: str, payload: dict) -> tuple[bool, dict | None]:
    """Returns (final, result). `final=True` means KB gave a parseable,
    authoritative answer -- `result` is its {"recorded": [...], "errors": [...]}
    body. A per-section error (unknown section_key, a correction window that
    already closed, ...) is treated exactly like success: KB has SEEN the
    request and decided, so resending cannot change the outcome and would
    only add another correction row to a section it already recorded (PR
    #214 review R2-1). `final=False` means a genuine TRANSPORT failure -- no
    DSN, the subprocess itself erroring or timing out, or stdout that did not
    parse -- the one case where KB never actually saw the request and a
    bounded, backed-off retry might still land it. Callers that fire this off
    a thread (above) don't read the return value; `_reconcile_port_ratings_answers`
    below does, to decide final-vs-retry."""
    try:
        dsn = secret("NEON_CONNECTION_STRING")
    except ValueError:
        dsn = None
    if not dsn:
        print(f"hub: ratings dispatch for {run_id} skipped: NEON_CONNECTION_STRING unavailable",
              file=sys.stderr)
        return False, None
    env = {k: os.environ[k] for k in ("HOME", "PATH", "LANG", "LC_ALL", "TMPDIR") if k in os.environ}
    env["NEON_CONNECTION_STRING"] = dsn
    try:
        r = subprocess.run([str(KB_PYTHON), "-m", "server.ratings", "hub-answer"],
                           cwd=KB_DEPLOY, env=env, input=json.dumps(payload),
                           capture_output=True, text=True, timeout=30)
        result = json.loads(r.stdout) if r.stdout else None
        if not isinstance(result, dict) or "recorded" not in result or "errors" not in result:
            print(f"hub: ratings dispatch for {run_id} failed: unparseable response "
                  f"(exit {r.returncode}): stdout={r.stdout!r} stderr={r.stderr!r}", file=sys.stderr)
            return False, None
        errors = result.get("errors") or []
        if errors:
            print(f"hub: ratings dispatch for {run_id}: KB recorded "
                  f"{len(result.get('recorded') or [])}, {len(errors)} error(s), "
                  f"final (not retried): {errors}", file=sys.stderr)
        return True, result
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as e:
        print(f"hub: ratings dispatch for {run_id} failed: {e}", file=sys.stderr)
        return False, None


# PR #214 review MEDIUM F1: `record_answer` and `record_remote_answer` above
# dispatch inline because an answer there was recorded BY THIS HUB. An answer
# that lands on formserve's own port never goes through either -- that
# process (formserve.py) writes straight to the registry file via
# record_store and has no import of this module, so nothing ever called
# `_dispatch_ratings_answer` for it. It sat in the registry, recorded and
# durable, but never reached kb.section_ratings and nothing logged it. This
# reconciler is the catch-all: it finds that row later, from the registry
# itself, and dispatches it the identical way.
RATINGS_RECONCILE_EVERY_S = float(os.environ.get("HERDR_RATINGS_RECONCILE_EVERY_S", "30"))

# PR #214 review R2-1: the first fix dispatch marked a row done only on full
# success, so ANY error in a batch -- including a section KB already
# accepted, or one past its 24h correction window -- left the whole row
# unmarked and resent it every cycle forever; each resend of an already-live
# section is a NEW correction row in kb.section_ratings. A genuine transport
# failure (no DSN, a dead subprocess, unparseable stdout) is the only case
# worth retrying, and even that must stop: bounded attempts with exponential
# backoff, then a terminal "gave up" state that is logged and surfaced on the
# hub (RATINGS_RECONCILE_STATE, rendered in render_decisions() the same way
# MIRROR_STATE is) instead of silently dropping the rating forever.
RATINGS_DISPATCH_MAX_ATTEMPTS = int(os.environ.get("HERDR_RATINGS_DISPATCH_MAX_ATTEMPTS", "8"))
RATINGS_DISPATCH_BACKOFF_BASE_S = float(os.environ.get("HERDR_RATINGS_DISPATCH_BACKOFF_BASE_S", "30"))
RATINGS_DISPATCH_BACKOFF_MAX_S = float(os.environ.get("HERDR_RATINGS_DISPATCH_BACKOFF_MAX_S", "3600"))
RATINGS_RECONCILE_STATE: dict = {"gave_up": {}}  # run_id -> {error, attempts, gave_up_at}


def _undispatched_port_ratings_answers() -> list[tuple[Path, dict]]:
    """Every answered-via-port ratings row this hub still owes KB an attempt
    on: not yet dispatched (`ratings_dispatched_at`), not given up on
    (`ratings_dispatch_gave_up_at`), and not inside its current backoff
    window (`ratings_dispatch_next_at`)."""
    out: list[tuple[Path, dict]] = []
    if not FORMS_DIR.is_dir():
        return out
    for path in sorted(FORMS_DIR.glob("*.json")):
        try:
            row = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if row.get("status") != "answered" or row.get("answered_via") != "port":
            continue
        if row.get("ratings_dispatched_at") or row.get("ratings_dispatch_gave_up_at"):
            continue
        next_at = row.get("ratings_dispatch_next_at")
        if isinstance(next_at, (int, float)) and time.time() * 1000 < next_at:
            continue
        key = _sidecar_key(row.get("form_path"))
        if key and key.startswith(RATINGS_KEY_PREFIX):
            out.append((path, row))
    return out


def _mark_ratings_dispatched(result: dict):
    """KB gave a final, parseable answer (PR #214 review R2-1): mark it done
    regardless of per-section errors so it is never resent, and drop any
    retry bookkeeping left over from an earlier transport failure on this
    same row."""
    def _mark(row: dict) -> dict:
        row["ratings_dispatched_at"] = int(time.time() * 1000)
        row["ratings_dispatch_result"] = result
        row.pop("ratings_dispatch_attempts", None)
        row.pop("ratings_dispatch_next_at", None)
        row.pop("ratings_dispatch_last_error", None)
        return row
    return _mark


def _mark_ratings_retry(run_id: str, error: str):
    """A transport failure: bump the attempt count, schedule the next try
    with exponential backoff, and give up for good past
    RATINGS_DISPATCH_MAX_ATTEMPTS. Giving up is recorded on the row (so it is
    never retried again) and in RATINGS_RECONCILE_STATE (so it is visible on
    /decisions instead of a silently dropped rating)."""
    def _mark(row: dict) -> dict:
        attempts = int(row.get("ratings_dispatch_attempts") or 0) + 1
        row["ratings_dispatch_attempts"] = attempts
        row["ratings_dispatch_last_error"] = error
        if attempts >= RATINGS_DISPATCH_MAX_ATTEMPTS:
            gave_up_at = int(time.time() * 1000)
            row["ratings_dispatch_gave_up_at"] = gave_up_at
            row.pop("ratings_dispatch_next_at", None)
            RATINGS_RECONCILE_STATE["gave_up"][run_id] = {
                "error": error, "attempts": attempts, "gave_up_at": gave_up_at}
            print(f"hub: ratings dispatch for {run_id} gave up after {attempts} attempts: {error}",
                  file=sys.stderr)
        else:
            backoff = min(RATINGS_DISPATCH_BACKOFF_BASE_S * (2 ** (attempts - 1)),
                         RATINGS_DISPATCH_BACKOFF_MAX_S)
            row["ratings_dispatch_next_at"] = int(time.time() * 1000 + backoff * 1000)
        return row
    return _mark


def _reconcile_port_ratings_answers() -> None:
    """Best-effort, same posture as mirror_sync: never raises. A KB response
    that parses (recorded/errors) is FINAL and marked durably
    (`ratings_dispatched_at`) so it is never resent, even with per-section
    errors -- a closed 24h correction window is exactly as unretryable as
    success (PR #214 review R2-1). Only a genuine transport failure is
    retried, bounded and backed off by `_mark_ratings_retry`."""
    for path, row in _undispatched_port_ratings_answers():
        key = _sidecar_key(row.get("form_path")) or ""
        run_id = key[len(RATINGS_KEY_PREFIX):]
        answers = (row.get("answers") or {}).get("ratings")
        if not isinstance(answers, dict) or not answers:
            continue
        payload = {"run_id": run_id, "attempt_number": 1,
                   "answers": [{"section_key": k, "rating": v} for k, v in answers.items()]}
        final, result = _dispatch_ratings_answer_now(run_id, payload)
        try:
            if final:
                claim_and_update(path, _mark_ratings_dispatched(result), require_status="answered")
            else:
                claim_and_update(path, _mark_ratings_retry(run_id, "dispatch transport failure, see hub log"),
                                 require_status="answered")
        except (NotClaimable, FileNotFoundError, OSError, json.JSONDecodeError) as e:
            # The KB write already landed (if final) -- only the local marker
            # failed, so the next cycle dispatches again. server.ratings
            # hub-answer is a same-run_id/section_key upsert inside the 24h
            # correction window (one live row per section), so a duplicate
            # dispatch overwrites, never double-counts -- but see R2-1 above:
            # that overwrite is still a new correction row, which is exactly
            # why `final` is marked BEFORE we'd ever reach here on success.
            print(f"hub: ratings reconcile marker for {run_id} not written: {e}", file=sys.stderr)


def _ratings_reconcile_loop() -> None:
    while True:
        try:
            _reconcile_port_ratings_answers()
        except Exception as e:  # noqa: BLE001 — belt and braces: the loop must not die
            print(f"hub: ratings reconcile loop error: {type(e).__name__}: {e}", file=sys.stderr)
        time.sleep(RATINGS_RECONCILE_EVERY_S)


def mirror_sync() -> None:
    """One publish/pull cycle. Never raises: the mirror is a convenience and must
    not take the hub down; failures are shown on /decisions instead."""
    acks: list[dict] = []
    try:
        if not (KB_DEPLOY / "server" / "hub_forms.py").exists() or not KB_PYTHON.exists():
            raise RuntimeError("kb-deploy has no server/hub_forms.py yet (fast-forwards nightly)")
        dsn = secret("NEON_CONNECTION_STRING")
        if not dsn:
            raise RuntimeError("NEON_CONNECTION_STRING unavailable")
        key = _mirror_key()
        d = forms_data()
        opened = []
        for f in d["open"]:
            _, row = _form_row(str(f.get("id") or ""))
            token = (row or {}).get("token") or ""
            if not f.get("hub_servable") or not token:
                continue
            if (_sidecar_key(f.get("form_path")) or "").startswith(RATINGS_KEY_PREFIX):
                continue  # ratings stay local-only -- never mirrored to the dashboard
            try:
                html_text = form_html(f["id"]).read_text()
            except OSError:
                continue
            nonce = _mirror_nonce(key, f["id"], token)
            title = str(f.get("title") or "")[:300]     # the store keeps 300 chars; sign what it keeps
            opened.append({"id": f["id"], "title": title, "html": html_text,
                           "nonce": nonce, "expires_at_ms": f.get("expires_at"),
                           "html_sig": _mirror_mac(key, "html", f["id"], nonce, title,
                                                   hashlib.sha256(html_text.encode()).hexdigest())})
        acks, _MIRROR_ACKS[:] = list(_MIRROR_ACKS), []
        payload = {"open": opened, "closed": [f.get("id") for f in d["history"] if f.get("id")],
                   "acks": acks}
        env = {k: os.environ[k] for k in ("HOME", "PATH", "LANG", "LC_ALL", "TMPDIR") if k in os.environ}
        env["NEON_CONNECTION_STRING"] = dsn
        r = subprocess.run([str(KB_PYTHON), "-m", "server.hub_forms", "sync"], cwd=KB_DEPLOY, env=env,
                           input=json.dumps(payload), capture_output=True, text=True, timeout=40)
        if r.returncode != 0:
            raise RuntimeError(f"hub_forms sync exit {r.returncode}")
        acks = []                                       # applied by the child
        out = json.loads(r.stdout)
        if not isinstance(out, dict) or not isinstance(out.get("pending", []), list):
            raise ValueError("hub_forms sync returned an unexpected shape")
        for p in out.get("pending") or []:
            if not isinstance(p, dict):
                continue
            _MIRROR_ACKS.append({"id": p.get("id"),
                                 "outcome": record_remote_answer(str(p.get("id") or ""), p, key)})
            MIRROR_STATE["pulled"] += 1
        MIRROR_STATE.update(last_ok=time.time(), last_error=None, published=out.get("published", 0))
    except Exception as e:  # noqa: BLE001 — a dead mirror thread would look healthy forever
        _MIRROR_ACKS[:0] = acks                         # not applied: retry them next cycle
        MIRROR_STATE["last_error"] = f"{type(e).__name__}: {e}"


def _mirror_loop() -> None:
    while True:
        try:
            mirror_sync()
        except Exception as e:  # noqa: BLE001 — belt and braces: the loop must not die
            MIRROR_STATE["last_error"] = f"{type(e).__name__}: {e}"
        time.sleep(MIRROR_EVERY_S)


# ── attention controller: thurber-os docs/project-contract-plan.md §3a ────────
ATTENTION_INTERVAL_S = float(os.environ.get("HERDR_ATTENTION_INTERVAL_S", "15") or 15)
# Same shape as MIRROR_STATE: a dead or failing tick must be VISIBLE (PR #132
# review, item 7) rather than reading as a healthy silent thread forever.
ATTENTION_STATE: dict = {"ticks": 0, "last_ok": None, "last_error": None,
                         "last_rc": None, "last_stderr": "", "skipped_recycled_panes": 0}


def _attention_skipped_count() -> int:
    """How many distinct (pane, registered, live) recycled-pane skips the
    controller has ever recorded. PR #132 re-review item 3: a birth mismatch
    used to just `continue` silently in attention-tick.sh; it is now a
    claimed `attention_skipped` event, and this is what surfaces that count
    on /api/summary instead of it living only in the registry."""
    try:
        conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
        try:
            row = conn.execute("SELECT count(*) FROM events WHERE type='attention_skipped';").fetchone()
        finally:
            conn.close()
        return int(row[0]) if row else 0
    except sqlite3.Error:
        return 0

def _attention_tick() -> None:
    """One pass: hand the controller the CURRENTLY blocked pane ids from
    LiveState (via live_attention(), the same join /api/blocked already
    uses) and let attention-tick.sh do everything else — it is the one place
    that reasons about a specific prompt, so hub.py never re-derives that.

    Pane order ROTATES per tick (item 7): attention-tick.sh gives every pane
    a fresh screen read and a 60s subprocess timeout is shared across all of
    them, so a fixed order would let a persistently-blocked pane early in the
    list starve one that only just started, on a fleet large enough to miss
    the deadline. Rotating by tick count spends the "front of the queue" seat
    on a different pane each pass.

    Never raises: a bad pass here must not take down the thread any more than
    a bad mirror_sync() call may (see _mirror_loop below).
    """
    if LIVE is None or not ATTENTION_SCRIPT.exists():
        return
    panes = [p.get("pane_id") for p in live_attention() if p.get("pane_id")]
    if not panes:
        return
    n = ATTENTION_STATE["ticks"] % len(panes)
    panes = panes[n:] + panes[:n]
    try:
        result = subprocess.run(["bash", str(ATTENTION_SCRIPT), "tick"],
                                input="\n".join(panes) + "\n", capture_output=True, text=True, timeout=60)
        ATTENTION_STATE["ticks"] += 1
        ATTENTION_STATE["last_rc"] = result.returncode
        ATTENTION_STATE["last_stderr"] = (result.stderr or "").strip()[-2000:]
        if result.returncode == 0:
            ATTENTION_STATE.update(last_ok=time.time(), last_error=None)
        else:
            tail = ATTENTION_STATE["last_stderr"][-300:]
            ATTENTION_STATE["last_error"] = f"exit {result.returncode}: {tail}"
            _live_log(f"attention tick exit {result.returncode}: {tail}")
        ATTENTION_STATE["skipped_recycled_panes"] = _attention_skipped_count()
    except (OSError, subprocess.SubprocessError) as exc:
        ATTENTION_STATE["ticks"] += 1
        ATTENTION_STATE["last_error"] = f"{type(exc).__name__}: {exc}"
        _live_log(f"attention tick failed: {exc}")


ACTION_SCRIPT = Path(__file__).resolve().parent / "herdr-action.sh"


def _action_tick() -> None:
    """Hook-approval action requests (docs/design/pretool-approval.md §4):
    wake a conductor that was not woken, and for human-only (or stale)
    requests post ONE Slack alert and keep a hub decision form open, applying
    it once answered. Runs from the hub because the hub holds the Slack
    credential a --no-secrets worker does not. A pass with nothing pending is
    one SQLite query. Never raises."""
    if not ACTION_SCRIPT.exists():
        return
    try:
        subprocess.run(["bash", str(ACTION_SCRIPT), "tick"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        _live_log(f"action tick failed: {exc}")


def _attention_loop() -> None:
    while True:
        try:
            _attention_tick()
        except Exception as e:  # noqa: BLE001 — belt and braces: the loop must not die
            ATTENTION_STATE["last_error"] = f"{type(e).__name__}: {e}"
            _live_log(f"attention loop error: {type(e).__name__}: {e}")
        try:
            _action_tick()
        except Exception as e:  # noqa: BLE001 — same: never kill the loop
            _live_log(f"action tick error: {type(e).__name__}: {e}")
        time.sleep(ATTENTION_INTERVAL_S)


# DEPLOY_DRIFT_PRIME_EVERY_S — independent of any reader, unlike every other
# stale_ok cache above (Cached's own docstring: "a background refresh is
# only ever kicked by a read"). Deliberately different here: this cache's
# only cost is two small git fetches against repos WE own, so keeping it
# permanently warm is cheap, and it is what actually fixes "a cold/post-idle
# read pays the fetch inline" — the 5s fetch timeout bounds that cost, this
# loop makes a real reader hit it as close to never as possible. Well under
# both the cache's own ttl (180s) and its stale_max (900s), so a real
# reader's .get() should always see a value younger than its own ttl.
DEPLOY_DRIFT_PRIME_EVERY_S = 60


def _deploy_drift_alert_check(dd: dict) -> None:
    """.handoffs/SPEC.md KEEP list: 'deploy drift > 30 min'. Reuses the SAME
    threshold and cache the dashboard card already uses (deploy_drift_rows'
    `hot = m > 30`) rather than inventing a second notion of "drifted" — see
    deploy-drift-alert.sh's own header for why this only became reachable
    once PR #130 landed deploy_drift_data().

    An unverified repo (fetch failed, or an error) leaves the CURRENT alert
    state alone rather than guessing either direction: a transient fetch
    failure must not manufacture a false "back in sync" recovery post, and
    must not manufacture a false "drifted" page either.

    Fire-and-forget, same as _on_agent_edge/_on_connection_change: this runs
    on the prime-loop thread, which must never die on a spawn failure.
    """
    if not DEPLOY_DRIFT_ALERT.exists():
        return
    for r in dd.get("repos", []):
        if r.get("error") or r.get("fetch_ok") is False:
            continue
        repo = r.get("repo") or ""
        if not repo:
            continue
        minutes = r.get("behind_minutes") or 0
        status = "drifted" if minutes > 30 else "synced"
        try:
            subprocess.Popen(
                ["bash", str(DEPLOY_DRIFT_ALERT), repo, status, str(minutes),
                 r.get("deployed") or "", r.get("main") or ""],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exc:
            _live_log(f"deploy-drift-alert spawn failed for {repo}: {exc}")


def _deploy_drift_prime_loop() -> None:
    while True:
        try:
            _deploy_drift_alert_check(CACHES["deploy_drift"].get())
        except Exception:  # noqa: BLE001 — belt and braces: the loop must not die
            pass
        time.sleep(DEPLOY_DRIFT_PRIME_EVERY_S)


# ── secrets: pre-resolved, never `op` from a background process ───────────────
# Only the hub's two service credentials may be resolved. This is the existing
# literal assignment parser, not a shell: no expansion, sourcing, or op calls.
# The service-account file contains the broker token, not these service secrets.
def secret(name: str) -> str | None:
    if name not in SECRET_NAMES:
        raise ValueError("unsupported hub credential name")
    v = os.environ.get(name)
    if v:
        return v
    try:
        lines = LAUNCHD_SECRETS.read_text().splitlines()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError):
        raise ValueError("hub service credential file unavailable") from None
    for line in lines:
        line = line.strip()
        if line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.removeprefix("export ").partition("=")
        if key.strip() == name:
            val = val.strip()
            if val.startswith(("'", '"')):
                if len(val) < 2 or val[-1] != val[0]:
                    raise ValueError("invalid hub service credential assignment")
                val = val[1:-1]
            return val or None
    return None


# ── consensus-search memory ────────────────────────────────────────────────────
def search_data() -> dict:
    token = secret("SEARCH_SYNC_TOKEN")
    if not token:
        return {"error": "SEARCH_SYNC_TOKEN unavailable; check the hub environment or scoped launchd credential file", "rows": []}
    rows, since = [], 0
    # A wall-clock budget as well as a page cap. 50 pages at timeout=20 is up
    # to ~1000s, and a fill that long held this cache's refresh ownership for
    # the whole stall while readers past the staleness bound started parallel
    # probes. The page cap bounds ROWS; only a deadline bounds TIME.
    _deadline = time.monotonic() + FILL_BUDGET_S
    for _ in range(50):  # 50 × 500 rows is far beyond today's table; a hard stop, not a limit
        if time.monotonic() > _deadline:
            partial_walk = True
            break
        req = urllib.request.Request(
            f"{SEARCH_URL}/log?since={since}&limit=500",
            headers={"authorization": f"Bearer {token}", "user-agent": "herdr-hub/1 (+tnt@teamthurber.com)"})
        with urllib.request.urlopen(req, timeout=20) as r:
            page = json.load(r)
        rows.extend(page.get("rows", []))
        if page.get("next") is None:
            break
        since = page["next"]
    totals = {"searches": len(rows), "truncated": bool(locals().get("partial_walk")),
              "replays": sum(int(r.get("hit_count") or 0) for r in rows),
              "data_kind": sum(1 for r in rows if r.get("kind") == "data"),
              "partial": sum(1 for r in rows if r.get("status") != "ok")}
    latest = sorted(rows, key=lambda r: r["ts"], reverse=True)[:15]
    recent = []
    for r in latest:
        try:
            t = json.loads(r.get("timings_json") or "{}")
        except json.JSONDecodeError:
            t = {}
        recent.append({"id": r["id"], "ts": r["ts"], "q": r["q"], "kind": r.get("kind"), "scope": r.get("scope"),
                       "hits": r.get("hit_count") or 0, "total_s": round((t.get("total") or 0) / 1000, 1),
                       "url": f"{SEARCH_URL}/?q={urllib.parse.quote(r['q'])}"})
    return {"totals": totals, "recent": recent}


# ── knowledge-base: nightly ledger + fleet heartbeat, via KB's own venv ────────
_KB_SNIPPET = r"""
import json, sys, datetime
sys.path.insert(0, ".")
out = {}
try:
    import psycopg, os
    with psycopg.connect(os.environ["NEON_CONNECTION_STRING"], options="-c default_transaction_read_only=on") as c:
        try:
            with c.transaction():
                row = c.execute("SELECT payload FROM kb.heartbeat_snapshots ORDER BY generated_at DESC LIMIT 1").fetchone()
                payload = row[0] if row else None
                out["heartbeat"] = json.loads(payload) if isinstance(payload, str) else payload
        except Exception:
            out["heartbeat_error"] = "heartbeat reader unavailable"
        try:
            with c.transaction():
                runs = c.execute("SELECT run_id, host, weekday, git_sha, status, started_at, finished_at, total_steps "
                                 "FROM kb.nightly_runs ORDER BY started_at DESC LIMIT 5").fetchall()
                cols = ["run_id","host","weekday","git_sha","status","started_at","finished_at","total_steps"]
                out["runs"] = [dict(zip(cols, r)) for r in runs]
                if runs:
                    steps = c.execute("SELECT step_label, status, attempts, duration_s, error_class "
                                      "FROM kb.nightly_steps WHERE run_id=%s ORDER BY ctid", (runs[0][0],)).fetchall()
                    out["steps"] = [dict(zip(["step_label","status","attempts","duration_s","error_class"], s)) for s in steps]
        except Exception:
            out.pop("runs", None)
            out.pop("steps", None)
            out["ledger_error"] = "nightly ledger reader unavailable"
        try:
            with c.transaction():
                from server.signal_quality import recent_runs
                out["signal_quality_runs"] = recent_runs(c, limit=10)
        except Exception:
            out["signal_quality_error"] = "signal quality reader unavailable; check KB module, migration, and database access"
except Exception:
    out["heartbeat_error"] = "heartbeat database unavailable"
    out["ledger_error"] = "nightly ledger database unavailable"
    out["signal_quality_error"] = "signal quality database unavailable"
print(json.dumps(out, default=str))
"""


SIGNAL_SUMMARY_FIELDS = (
    "window_days", "person_count", "before_count", "after_count", "changed_count",
    "repeat_before_count", "repeat_after_count", "withheld_stale_count",
    "withheld_unknown_date_count", "violation_count",
)


def _public_signal_runs(rows) -> list[dict]:
    """Allow only typed audit metadata and aggregate counters onto localhost."""
    if not isinstance(rows, list):
        raise ValueError("invalid signal quality response")
    result = []
    for row in rows[:10]:
        if not isinstance(row, dict) or row.get("status") not in ("running", "ok", "degraded", "failed"):
            raise ValueError("invalid signal quality run")
        if not isinstance(row.get("run_id"), str):
            raise ValueError("invalid audit run identifier")
        run_id = str(UUID(row["run_id"]))
        dates = {}
        for key in ("started_at", "finished_at"):
            value = row.get(key)
            if value is None and key == "finished_at":
                dates[key] = None
                continue
            if not isinstance(value, str):
                raise ValueError("invalid audit timestamp")
            date = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if date.tzinfo is None:
                raise ValueError("audit timestamp requires timezone")
            dates[key] = date.astimezone(dt.timezone.utc).isoformat()
        rule = row.get("rule_version")
        if not isinstance(rule, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:/-]{0,95}", rule):
            raise ValueError("invalid audit rule version")
        revision = row.get("source_revision")
        if revision is not None and (not isinstance(revision, str) or not re.fullmatch(r"[0-9a-fA-F]{7,64}", revision)):
            revision = None
        summary = row.get("summary")
        if not isinstance(summary, dict):
            raise ValueError("invalid audit summary")
        counts = {}
        for key in SIGNAL_SUMMARY_FIELDS:
            value = summary.get(key)
            # A running/failed audit can lack counters; never substitute fake zeros.
            if value is None and row["status"] in ("running", "failed"):
                continue
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError("invalid audit counter")
            counts[key] = value
        # Raw error strings (including SQL/PII) have no place on this surface.
        result.append({"run_id": run_id, **dates, "status": row["status"],
                       "rule_version": rule, "source_revision": revision, "summary": counts,
                       "error_code": "audit_failed" if row.get("error_code") else None})
    return result


def _signal_quality_link() -> str | None:
    """Configured human-auth page only; no credentials/query/fragment in links."""
    value = KB_DASHBOARD_URL
    try:
        url = urllib.parse.urlsplit(value)
        if (url.scheme not in ("https", "http") or not url.hostname or url.username or url.password
                or url.query or url.fragment or url.hostname not in ("dashboard.teamthurber.com", "localhost", "127.0.0.1")
                or (url.scheme == "http" and url.hostname == "dashboard.teamthurber.com")
                or url.path not in ("", "/")):
            return None
        url.port  # reject malformed ports
    except ValueError:
        return None
    return value.rstrip("/") + "/signal-quality"


# Heartbeat: the persisted snapshot carries raw checker exception text, subprocess
# stderr and whole non-OK HTTP response bodies in systems.*.detail (SQ-SEC-04),
# so this unauthenticated surface republishes NOTHING from the payload except the
# checker names KB itself defines, its fixed status vocabulary, and counts derived
# from those — no detail strings, no unknown keys, no producer-supplied numbers.
# Names are server.heartbeat._CHECKERS; a key KB does not define is counted, never
# echoed, because an arbitrary key may itself be secret-bearing.
HEARTBEAT_SYSTEMS = frozenset(("kb", "tourguide", "tntpgh_actions", "idx_poller",
                               "syncworks", "thurber_ai", "imagen", "search"))
HEARTBEAT_UNHEALTHY = ("degraded", "unreachable")
# status -> the only diagnostic string allowed out of this projection
HEARTBEAT_CODES = {"healthy": "check_ok", "degraded": "check_degraded",
                   "unreachable": "check_unreachable", "unknown": "check_not_observed"}


def _public_heartbeat(payload) -> dict:
    """Project a snapshot into typed names/statuses/counts and fixed codes.

    Raises ValueError for any shape that cannot be summarized honestly: an
    invalid payload must read unavailable, never healthy-by-default.
    """
    if not isinstance(payload, dict):
        raise ValueError("invalid heartbeat payload")
    generated = payload.get("generated_at")
    if not isinstance(generated, str):
        raise ValueError("invalid heartbeat timestamp")
    when = dt.datetime.fromisoformat(generated.replace("Z", "+00:00"))
    if when.tzinfo is None:
        raise ValueError("heartbeat timestamp requires timezone")
    raw = payload.get("systems")
    if not isinstance(raw, dict):
        raise ValueError("invalid heartbeat systems")
    systems, unrecognized = {}, 0
    for name, value in raw.items():
        if not isinstance(name, str) or name not in HEARTBEAT_SYSTEMS:
            unrecognized += 1
            continue
        status = value.get("status") if isinstance(value, dict) else None
        status = status if status in HEARTBEAT_CODES else "unknown"
        systems[name] = {"status": status, "code": HEARTBEAT_CODES[status]}
    if not systems:
        raise ValueError("heartbeat reported no known system")
    healthy = sorted(n for n, v in systems.items() if v["status"] == "healthy")
    unhealthy = sorted(n for n, v in systems.items() if v["status"] in HEARTBEAT_UNHEALTHY)
    return {"generated_at": when.astimezone(dt.timezone.utc).isoformat(),
            "systems": dict(sorted(systems.items())),
            "healthy_count": len(healthy), "checked_count": len(healthy) + len(unhealthy),
            "total_count": len(systems), "unrecognized_count": unrecognized,
            "unhealthy": unhealthy, "divergent": bool(healthy) and bool(unhealthy)}


def _kb_unavailable(reason: str) -> dict:
    return {"error": reason, "signal_quality_error": "signal quality reader unavailable"}


def kb_data() -> dict:
    if not (KB_DEPLOY / "server").is_dir() or not KB_PYTHON.exists():
        return _kb_unavailable("kb-deploy checkout or venv missing")
    try:
        dsn = secret("NEON_CONNECTION_STRING")
    except ValueError:
        return _kb_unavailable("KB credential configuration unavailable")
    if not dsn:
        return _kb_unavailable("NEON_CONNECTION_STRING unavailable; check the hub environment or scoped launchd credential file")
    # Do not pass broker/Slack/search credentials or Python startup overrides.
    env = {key: os.environ[key] for key in ("HOME", "PATH", "LANG", "LC_ALL", "TMPDIR") if key in os.environ}
    env.update(NEON_CONNECTION_STRING=dsn, PGOPTIONS="-c default_transaction_read_only=on")
    try:
        r = subprocess.run([str(KB_PYTHON), "-c", _KB_SNIPPET], cwd=KB_DEPLOY, env=env,
                           capture_output=True, text=True, timeout=40)
    except subprocess.TimeoutExpired:
        return _kb_unavailable("kb reader timed out (40s)")
    except OSError:
        return _kb_unavailable("kb reader could not start")
    if r.returncode != 0:
        return _kb_unavailable(f"kb reader exit {r.returncode}; database observation unavailable")
    try:
        data = json.loads(r.stdout)
    except (json.JSONDecodeError, UnicodeError):
        return _kb_unavailable("kb reader returned invalid JSON")
    if not isinstance(data, dict):
        return _kb_unavailable("kb reader returned invalid data")
    for run in data.get("runs") or []:
        run["status"] = _nightly_status(run)
    # Only the producer's fixed diagnostic categories may cross this boundary.
    # A credential can look like a short token too; shape alone is not redaction.
    for step in data.get("steps") or []:
        cls = step.get("error_class")
        if cls not in (None, "transient", "structural", "unknown"):
            step["error_class"] = "error_class_withheld"
    # Errors are fixed local messages, not exception text from the child.
    for key in ("heartbeat_error", "ledger_error", "signal_quality_error", "error"):
        if key in data:
            data[key] = "KB reader unavailable" if key == "error" else key.removesuffix("_error").replace("_", " ") + " reader unavailable"
    if "heartbeat_error" in data:
        data.pop("heartbeat", None)
    elif "heartbeat" not in data:
        data["heartbeat_error"] = "heartbeat reader unavailable"
    elif data["heartbeat"] is not None:  # None = no snapshot recorded yet, which is truthful
        try:
            data["heartbeat"] = _public_heartbeat(data["heartbeat"])
        except (ValueError, TypeError, KeyError, OverflowError):
            data.pop("heartbeat", None)
            data["heartbeat_error"] = "heartbeat unavailable: invalid snapshot contract"
    if "signal_quality_error" in data:
        data.pop("signal_quality_runs", None)
    elif "signal_quality_runs" in data:
        try:
            data["signal_quality_runs"] = _public_signal_runs(data["signal_quality_runs"])
        except (ValueError, TypeError, KeyError, OverflowError):
            data.pop("signal_quality_runs", None)
            data["signal_quality_error"] = "signal quality response unavailable: invalid aggregate contract"
    else:
        data["signal_quality_error"] = "signal quality reader unavailable"
    return data


# ── liveness ───────────────────────────────────────────────────────────────────
def probe(name: str, url: str, method: str, hb_key: str | None) -> dict:
    t0 = time.monotonic()
    try:
        req = urllib.request.Request(url, method=method, headers={"user-agent": "herdr-hub/1"})
        with urllib.request.urlopen(req, timeout=5) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code  # 401/403/302 from an auth wall is still "there"
        e.close()
    except (urllib.error.URLError, OSError, ValueError) as e:
        return {"name": name, "url": url, "alive": False, "code": None, "ms": None,
                "detail": str(getattr(e, "reason", e))[:80], "hb": hb_key}
    return {"name": name, "url": url, "alive": code < 500, "code": code,
            "ms": int((time.monotonic() - t0) * 1000), "detail": "", "hb": hb_key}


def links_data() -> dict:
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(lambda s: probe(*s), SURFACES))
    forms = forms_data()
    for f in forms["open"]:
        results.append({"name": f"decision: {f.get('title') or f['id']}", "url": f["url"], "alive": True,
                        "code": 200, "ms": None, "detail": "open form", "hb": None})
    return {"surfaces": results}


# ── loops: every scheduled thing that is supposed to keep running ──────────────
# One row per loop: what it is, when it last ran, whether that is fresh for its
# cadence, and its last outcome — read from each loop's OWN artifact, never
# re-derived. `stale_after_s` is the cadence plus slack (a daily loop is late
# at 26h, not 24h01). "Suggestions" are the Stage-2 diagnose pass's own
# Stage-3-eligible / auto-remediate findings plus derived nudges from the
# freshness/outcome rules — proposal-only, exactly as the charter says.
THURBER_OS = Path(os.environ.get("THURBER_OS", Path.home() / "Code/thurber-os"))
# The Stage-1 ledger is per-MACHINE state written by the launchd job, which
# runs the live checkout — so read it from there even when this hub runs from
# a worktree. ENGINEERING_LEDGER_DIR is the same override the collector honors.
HERDR_CONTROL = Path(os.environ.get("HERDR_CONTROL_DIR", Path.home() / "Code/herdr-control"))
SENTINEL_HEARTBEAT = Path.home() / "Library/Application Support/thurber-os/local-sentinel/heartbeat.json"
LEDGER_DIR = Path(os.environ.get("ENGINEERING_LEDGER_DIR", HERDR_CONTROL / ".local-state/engineering-ledger"))
TRACKING_DIR = THURBER_OS / "docs/tracking"
GATE_REGISTRY = THURBER_OS / "docs/gate-registry.yaml"


def _parse_ts(v) -> float | None:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return v / 1000 if v > 1e11 else float(v)
    try:
        d = dt.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.timestamp()


def _loop(name, cadence, last, stale_after_s, outcome, detail, link=None) -> dict:
    ts = _parse_ts(last)
    age = (time.time() - ts) if ts else None
    observed = outcome not in ("unavailable", "unreadable", "unknown")
    stale = observed and (age is None or age > stale_after_s)
    return {"name": name, "cadence": cadence, "last": last, "age_s": age, "stale": stale,
            "observed": observed, "outcome": outcome, "detail": detail, "link": link}


def _loop_age(lp: dict) -> str:
    return "unknown" if not lp["observed"] else (_age(lp["last"]) if lp["last"] else "never")


def _signal_quality_loop(kb: dict) -> dict:
    error = kb.get("error") or kb.get("signal_quality_error")
    if error or "signal_quality_runs" not in kb:
        return _loop("signal quality [9j]", "daily (inside KB nightly)", None, 26 * 3600,
                     "unavailable", "audit reader unavailable; check credentials, KB module and migration", link="/kb")
    runs = kb["signal_quality_runs"]
    last = runs[0] if runs else {}
    summary = last.get("summary") or {}
    detail = ("repeat-view eligibility and ranking invariants only; "
              f"before {summary.get('before_count', '—')} → after {summary.get('after_count', '—')}; "
              f"violations {summary.get('violation_count', '—')}")
    return _loop("signal quality [9j]", "daily (inside KB nightly)", last.get("started_at"), 26 * 3600,
                 last.get("status", "missing"), detail if last else "no recorded audit runs", link="/kb")


def _loop_sentinel() -> dict:
    if not SENTINEL_HEARTBEAT.exists():
        return _loop("local sentinel", "every 5 min", None, 900, "missing", f"no heartbeat at {SENTINEL_HEARTBEAT}")
    try:
        raw = json.loads(SENTINEL_HEARTBEAT.read_text())
        v = raw.get("verdict")
        if isinstance(v, str):  # older writes stored a Python repr, not JSON
            v = ast.literal_eval(v)
    except (OSError, ValueError, SyntaxError) as e:
        return _loop("local sentinel", "every 5 min", None, 900, "unreadable", str(e)[:120])
    failed = v.get("failed_signals") or []
    return _loop("local sentinel", "every 5 min", v.get("checked_at"), 900, v.get("status") or "?",
                 f"failed signals: {', '.join(failed)}" if failed else "all signals healthy")


def _loop_stage1() -> dict:
    files = sorted(LEDGER_DIR.glob("*.jsonl")) if LEDGER_DIR.is_dir() else []
    if not files:
        return _loop("eloop stage 1 — engineering ledger collector", "hourly", None, 3 * 3600, "missing",
                     f"no ledger files in {LEDGER_DIR}")
    rows = []
    for line in files[-1].read_text().splitlines()[-40:]:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    last = max((r.get("observed_at") or "" for r in rows), default=None) or None
    latest_poll = [r for r in rows if r.get("observed_at") == last]
    bad = [f"{r.get('source')}:{r.get('source_id')}" for r in latest_poll if r.get("status") not in ("ok", "success", None)]
    return _loop("eloop stage 1 — engineering ledger collector", "hourly", last, 3 * 3600,
                 "degraded" if bad else "ok",
                 f"{len(latest_poll)} source rows in the last poll" + (f"; not ok: {', '.join(bad)}" if bad else ""))


_FINDING_RE = re.compile(r"^## (F\d+) — (.+)$", re.M)


def _loop_stage2() -> tuple[dict, list[dict]]:
    docs = sorted(TRACKING_DIR.glob("*-stage2-diagnose-pass.md")) if TRACKING_DIR.is_dir() else []
    if not docs:
        return _loop("eloop stage 2 — diagnose pass", "Fridays 09:00", None, 8 * 86400, "missing", "no pass docs"), []
    doc = docs[-1]
    text = doc.read_text()
    when = doc.name[:10]
    findings = []
    for m in _FINDING_RE.finditer(text):
        block = text[m.end(): text.find("\n## ", m.end()) if text.find("\n## ", m.end()) > 0 else len(text)]
        title = m.group(2)
        tags = []
        if "Stage-3-eligible" in title or "Stage-3-eligible" in block[:600]:
            tags.append("stage-3-eligible")
        if "auto-remediate" in title.lower() or "**Classification: auto-remediate**" in block:
            tags.append("auto-remediate")
        if "CARRY-OVER" in title:
            tags.append("carry-over")
        if "RESOLVED" in title:
            tags.append("resolved")
        findings.append({"id": m.group(1), "title": title, "tags": tags, "doc": doc.name})
    open_findings = [f for f in findings if "resolved" not in f["tags"]]
    return _loop("eloop stage 2 — diagnose pass", "Fridays 09:00", f"{when}T09:00:00+00:00", 8 * 86400,
                 "ok", f"{len(findings)} findings, {len(open_findings)} open, in {doc.name}",
                 link=f"file://{doc}"), findings


def _loop_gates() -> list[dict]:
    if not GATE_REGISTRY.exists():
        return []
    out, cur = [], None
    for line in GATE_REGISTRY.read_text().splitlines():
        s = line.strip()
        if s.startswith("- id: "):
            cur = {"id": s[6:].strip(), "status": "?", "title": ""}
            if cur["id"].startswith(("G-ELOOP", "G-OLOOP")):
                out.append(cur)
            else:
                cur = None
        elif cur is not None:
            if s.startswith("status:"):
                cur["status"] = s.split(":", 1)[1].strip()
            elif s.startswith("title:"):
                cur["title"] = s.split(":", 1)[1].strip()
    return out


def _nightly_status(run: dict) -> str:
    if run.get("status"):
        return run["status"]
    if run.get("started_at") and not run.get("finished_at"):
        return "running"
    return "unknown" if run else "missing"


def loops_data() -> dict:
    kb = CACHES["kb"].get() or {}
    ledger_error = kb.get("error") or kb.get("ledger_error") or ("nightly ledger response unavailable" if "runs" not in kb else None)
    runs = kb.get("runs") or []
    last_run = runs[0] if runs and not ledger_error else {}
    loops = [
        _loop("KB nightly", "daily 08:00", last_run.get("started_at"), 26 * 3600,
              "unavailable" if ledger_error else _nightly_status(last_run),
              "nightly ledger reader unavailable; check credentials and database access" if ledger_error else (
                  f"{last_run.get('total_steps') or '?'} steps · {last_run.get('host') or ''}" if last_run else "no runs"),
              link="/kb"),
    ]
    heartbeat_error = kb.get("error") or kb.get("heartbeat_error") or ("heartbeat response unavailable" if "heartbeat" not in kb else None)
    hb = (kb.get("heartbeat") or {}) if not heartbeat_error else {}
    loops.append(_loop("fleet heartbeat [9h]", "daily (inside KB nightly)", hb.get("generated_at"), 26 * 3600,
                       "unavailable" if heartbeat_error else ("divergent" if hb.get("divergent") else ("ok" if hb else "missing")),
                       "heartbeat reader unavailable; check credentials and database access" if heartbeat_error else (
                           f"{hb.get('healthy_count')}/{hb.get('total_count')} healthy" if hb else "no snapshot yet"), link="/kb"))
    loops.append(_signal_quality_loop(kb))
    loops.append(_loop_sentinel())
    loops.append(_loop_stage1())
    s2, findings = _loop_stage2()
    loops.append(s2)

    suggestions = []
    for lp in loops:
        if not lp["observed"]:
            suggestions.append({"key": f"observer:{_slug(lp['name'])}", "kind": "observer",
                                "text": f"{lp['name']} execution history is unknown: {lp['detail']}. Restore reader access before judging its schedule.",
                                "link": lp.get("link")})
        elif lp["stale"]:
            suggestions.append({"key": f"stale:{_slug(lp['name'])}", "kind": "stale", "text": f"{lp['name']} has not run in {_age(lp['last']) if lp['last'] else 'ever'} (cadence {lp['cadence']}); last outcome {lp['outcome']} — check its launchd job / log.", "link": lp.get("link")})
        elif lp["outcome"] not in ("ok", "success", "healthy", "running"):
            suggestions.append({"key": f"outcome:{_slug(lp['name'])}", "kind": "outcome", "text": f"{lp['name']} last reported {lp['outcome']}: {lp['detail']}", "link": lp.get("link")})
    for f in findings:
        if "resolved" in f["tags"]:
            continue
        if "auto-remediate" in f["tags"] or "stage-3-eligible" in f["tags"]:
            suggestions.append({"key": f"finding:{f['id']}", "kind": "finding", "text": f"{f['id']}: {f['title']}", "tags": f["tags"], "link": f"file://{TRACKING_DIR / f['doc']}"})
    decisions = _loop_decisions()
    now_ms = int(time.time() * 1000)
    dismissed = 0
    for sg in suggestions:
        d = decisions.get(sg["key"])
        sg["decision"] = None
        if d and d["status"] == "open":
            sg["decision"] = {"state": "deciding", "url": d["url"]}
        elif d and d.get("until") and d["until"] > now_ms:
            sg["decision"] = {"state": "dismissed", "until": d["until"]}
            dismissed += 1
        elif d and d.get("decision") in ("accept", "hold"):
            sg["decision"] = {"state": d["decision"], "at": d["answered_at"], "notes": d.get("notes", "")}
    return {"loops": loops, "findings": findings, "suggestions": suggestions, "dismissed": dismissed,
            "gates": _loop_gates()}


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


# Terrence, 2026-09-05 ("Rung 1"): every suggestion gets a Decide button; the
# answer is a formserve form in the /decisions inbox; dismissals stop the nag.
# No auto-dispatch: "accept" means the CONDUCTOR dispatches (Stage 3 / G-ELOOP-E2
# is provisional). Decisions are derived from the forms registry itself - the
# form's answers carry `loops_key` - so there is no second state file to drift.
DISMISS_DAYS = {"dismiss_7": 7, "dismiss_30": 30}


def _sidecar_key(form_path) -> str | None:
    """An OPEN form has no answers yet; its suggestion key sits in a sidecar
    written next to the html when the form was served."""
    if not form_path:
        return None
    try:
        return Path(form_path).with_suffix(".key").read_text().strip() or None
    except OSError:
        return None


def _loop_decisions() -> dict:
    """key -> newest form outcome for that suggestion (open, or answered)."""
    out: dict = {}
    for path in sorted(FORMS_DIR.glob("*.json")):  # oldest first; newer overwrite
        try:
            f = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        key = (f.get("answers") or {}).get("loops_key") or _sidecar_key(f.get("form_path"))
        if not key:
            continue
        if f.get("status") == "open":
            out[key] = {"status": "open", "url": f.get("url")} if port_open(int(f.get("port", 0) or 0)) else out.get(key, {})
            continue
        if f.get("status") != "answered":
            continue
        a = f.get("answers") or {}
        days = DISMISS_DAYS.get(a.get("decision"))
        out[key] = {"status": "answered", "decision": a.get("decision"), "notes": a.get("notes", ""),
                    "answered_at": f.get("answered_at"),
                    "until": (f.get("answered_at") or 0) + days * 86400 * 1000 if days else None}
    return out


DECIDE_FORM = """<!doctype html><html lang=en><head><meta charset=utf-8><title>{title}</title>
<style>:root{{--ground:#0f1115;--surface:#171a21;--line:#272c37;--ink:#e6e9ef;--dim:#9aa3b2;--accent:#6aa6ff}}
body{{margin:0;background:var(--ground);color:var(--ink);font:15px/1.5 system-ui,sans-serif}} main{{max-width:720px;margin:0 auto;padding:32px 24px 110px}}
h1{{font-size:22px;margin:0 0 6px}} .sub{{color:var(--dim);margin:0 0 22px}} fieldset{{border:1px solid var(--line);border-radius:8px;background:var(--surface);padding:14px 16px;margin:0 0 16px}}
legend{{color:var(--dim);font-size:12px;letter-spacing:.08em;text-transform:uppercase;padding:0 6px}} .opt{{display:flex;gap:10px;padding:8px 6px;border-radius:6px;cursor:pointer}} .opt:hover{{background:#1d2129}}
.hint{{display:block;color:var(--dim);font-size:13px}} textarea{{width:100%;min-height:70px;background:var(--ground);color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:8px;font:inherit}}
.bar{{position:fixed;left:0;right:0;bottom:0;background:var(--surface);border-top:1px solid var(--line);padding:12px 24px;display:flex;gap:10px;justify-content:flex-end}}
button{{font:600 14px system-ui;padding:10px 18px;border-radius:6px;border:1px solid var(--accent);background:var(--accent);color:#0b1020;cursor:pointer}} .ghost{{background:transparent;color:var(--dim);border-color:var(--line)}}
pre{{white-space:pre-wrap;background:var(--ground);border:1px solid var(--line);border-radius:6px;padding:10px;color:var(--dim);font-size:13px}}</style></head><body><main>
<h1>{title}</h1><p class=sub>Suggestion from the hub's /loops page ({kind}). Nothing is dispatched by this form: "accept" hands it to the conductor to dispatch as a herdr worker.</p>
<pre>{text}</pre>
<form id=f><fieldset><legend>Decision</legend>
<label class=opt><input type=radio name=decision value=accept required checked><span><b>Accept</b><span class=hint>conductor dispatches it (worktree + PR, human merge) and reports back</span></span></label>
<label class=opt><input type=radio name=decision value=hold><span><b>Hold</b><span class=hint>keep it visible, no action yet</span></span></label>
<label class=opt><input type=radio name=decision value=dismiss_7><span><b>Dismiss for 7 days</b><span class=hint>hidden from /loops until then; comes back if still true</span></span></label>
<label class=opt><input type=radio name=decision value=dismiss_30><span><b>Dismiss for 30 days</b></span></label>
</fieldset><fieldset><legend>Notes</legend><textarea name=notes placeholder="constraints, who, why…"></textarea></fieldset></form></main>
<div class=bar><button type=button class=ghost id=cancel>Send nothing</button><button type=submit form=f>Send answer</button></div>
<script>document.getElementById("f").addEventListener("submit",function(e){{e.preventDefault();var fd=new FormData(e.target);
window.submitAnswers({{loops_key:{key_json},decision:fd.get("decision"),notes:(fd.get("notes")||"").trim()}})}});
document.getElementById("cancel").addEventListener("click",function(){{window.submitAnswers({{cancelled:true,loops_key:{key_json}}})}});</script></body></html>"""


def serve_loop_decision(key: str) -> str | None:
    """Write a decision form for one suggestion and hand it to formserve, which
    registers it in the inbox. Returns the registry-visible title, or None."""
    sg = next((x for x in (CACHES["loops"].get() or {}).get("suggestions", []) if x["key"] == key), None)
    if not sg:
        return None
    FORMS_DIR.mkdir(parents=True, exist_ok=True)
    title = f"loops: {sg['text'][:70]}{'…' if len(sg['text']) > 70 else ''}"
    form = FORMS_DIR / f"loops-{_slug(key)}-{time.strftime('%Y%m%dT%H%M%S', time.gmtime())}.html"
    form.write_text(DECIDE_FORM.format(title=_esc(title), kind=_esc(sg["kind"]), text=_esc(sg["text"]),
                                       key_json=json.dumps(key)))
    form.with_suffix(".key").write_text(key)
    subprocess.Popen([sys.executable, str(APP_ROOT / "formserve.py"), str(form),
                      "--timeout", "14400", "--no-open"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    # invalidate(), not `at = 0.0`: under stale_ok an expired timestamp takes
    # the STALE branch, so the first view after deciding re-offered `Decide`
    # for a suggestion already being decided — and a refresh already in flight
    # would re-stamp that pre-decision value fresh for a whole TTL.
    CACHES["loops"].invalidate()   # re-read on next view so the row shows "deciding"
    CACHES["forms"].invalidate()
    return title

# ── ratings publish: knowledge-base's nightly POSTs here after [8j] ──────────
# (B1.2 v2 / closure #1, thurber-os docs/tracking/2026-09-30-feedback-loop-
# audit.md §1, §5 #1, §Decided. Terrence, formserve 20260930T150421-8722:
# ratings=hub_inline.) The mailed Access-gated /rate link answered 0 of 221
# asks in the 51 days before this closure; Terrence already answers every
# other local decision here, so the rating ask gets the SAME surface.
# Loopback, unauthenticated — same posture as every other endpoint on this
# hub. The nightly job runs on this same Mac (launchd com.teamthurber.kb-nightly,
# not Fly), so this is a same-machine call, never a network hop.
RATINGS_KEY_PREFIX = "ratings:"

RATINGS_FORM = """<!doctype html><html lang=en><head><meta charset=utf-8><title>{title}</title>
<style>:root{{--ground:#0f1115;--surface:#171a21;--line:#272c37;--ink:#e6e9ef;--dim:#9aa3b2;--accent:#6aa6ff}}
body{{margin:0;background:var(--ground);color:var(--ink);font:15px/1.5 system-ui,sans-serif}} main{{max-width:720px;margin:0 auto;padding:32px 24px 110px}}
h1{{font-size:22px;margin:0 0 6px}} .sub{{color:var(--dim);margin:0 0 22px}} fieldset{{border:1px solid var(--line);border-radius:8px;background:var(--surface);padding:14px 16px;margin:0 0 16px}}
legend{{color:var(--dim);font-size:12px;letter-spacing:.08em;text-transform:uppercase;padding:0 6px}} .opt{{display:flex;gap:10px;padding:8px 6px;border-radius:6px;cursor:pointer}} .opt:hover{{background:#1d2129}}
.summary{{color:var(--dim);font-size:13px;margin:0 0 10px}}
.bar{{position:fixed;left:0;right:0;bottom:0;background:var(--surface);border-top:1px solid var(--line);padding:12px 24px;display:flex;gap:10px;justify-content:flex-end}}
button{{font:600 14px system-ui;padding:10px 18px;border-radius:6px;border:1px solid var(--accent);background:var(--accent);color:#0b1020;cursor:pointer}}</style></head><body><main>
<h1>{title}</h1><p class=sub>Today's Morning Briefing sections the demand budget selected. One tap per section; skip any you don't have an opinion on.</p>
<form id=f>{fields}</form></main>
<div class=bar><button type=submit form=f>Send answers</button></div>
<script>document.getElementById("f").addEventListener("submit",function(e){{e.preventDefault();var fd=new FormData(e.target);
var ratings={{}};fd.forEach(function(v,k){{if(k.indexOf("section:")===0)ratings[k.slice(8)]=v;}});
window.submitAnswers({{run_id:{run_id_json},ratings:ratings}})}});</script></body></html>"""

RATINGS_FIELD = """<fieldset><legend>{title}</legend>{summary}
<label class=opt><input type=radio name="section:{slug}" value=acted_on><span>Acted on</span></label>
<label class=opt><input type=radio name="section:{slug}" value=reviewed_no_action><span>Read, no action</span></label>
<label class=opt><input type=radio name="section:{slug}" value=noise><span>Noise</span></label>
</fieldset>"""


def _ratings_key(run_id: str) -> str:
    return RATINGS_KEY_PREFIX + run_id


def _open_ratings_form_id(run_id: str) -> str | None:
    """An already-published form (open OR answered) for this run_id, or None.
    Makes publish_ratings_form idempotent against a nightly retry -- mirrors
    scripts/nightly_automation.py's own _briefing_already_sent dedup."""
    want = _ratings_key(run_id)
    for path in sorted(FORMS_DIR.glob("*.json")):
        try:
            f = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if _sidecar_key(f.get("form_path")) == want:
            return f.get("id")
    return None


def publish_ratings_form(payload: dict) -> tuple[int, bytes]:
    """Register one formserve form covering every section KB's nightly asked
    about today. Returns (status, json-or-text body)."""
    run_id = str(payload.get("run_id") or "").strip()
    sections = payload.get("sections")
    if not run_id or not isinstance(sections, list) or not sections:
        return 400, b"run_id and a non-empty sections list are required"
    existing = _open_ratings_form_id(run_id)
    if existing is not None:
        return 200, json.dumps({"ok": True, "id": existing, "already_published": True}).encode()
    fields = []
    for s in sections:
        if not isinstance(s, dict):
            continue
        slug = str(s.get("slug") or "")
        if not slug:
            continue
        title = str(s.get("title") or slug)
        summary = str(s.get("summary") or "")
        summary_html = f"<p class=summary>{_esc(summary)}</p>" if summary else ""
        fields.append(RATINGS_FIELD.format(title=_esc(title), slug=_esc(slug), summary=summary_html))
    if not fields:
        return 400, b"no valid sections in payload"
    FORMS_DIR.mkdir(parents=True, exist_ok=True)
    title = f"ratings: {time.strftime('%Y-%m-%d', time.localtime())} ({len(fields)} sections)"
    form = FORMS_DIR / f"ratings-{_slug(run_id)}-{time.strftime('%Y%m%dT%H%M%S', time.gmtime())}.html"
    form.write_text(RATINGS_FORM.format(
        title=_esc(title), fields="".join(fields), run_id_json=_script_json(run_id)))
    form.with_suffix(".key").write_text(_ratings_key(run_id))
    # 24h timeout, matching the rating's own correction window -- answerable
    # any time that day, not just the minutes right after the briefing sends.
    subprocess.Popen([sys.executable, str(APP_ROOT / "formserve.py"), str(form),
                      "--timeout", "86400", "--no-open"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    CACHES["forms"].invalidate()
    return 200, json.dumps({"ok": True, "already_published": False}).encode()



# ── handoff debt: a repo someone changed and never wrote up ───────────────────
# Written by the omp extension `handoff-coverage.ts` (omp-harness#9), never by
# anything here. It exists because the notepad tools resolve
# `.handoffs/notepad.md` from the SESSION's cwd, so a session working across
# repos files every handoff into whichever repo it happened to be standing in:
# on 2026-09-18 one session merged four PRs in herdr-control and two in
# tntpgh-dev from a thurber-os cwd and left both those notepads bare.
#
# That extension appends a row at session_shutdown for each repo it changed
# without a handoff, and DELETES a repo's rows the moment a session starts in
# it. So every row present is unpaid by construction, and this reader makes no
# judgement the writer has not already made — it only reads, and it is the
# only surface that shows the ledger to a human who is not already standing in
# the repo that owes it.
#
# A different process on a different schedule writes this file, which is the
# whole reason for the defensive parse below: absent, empty, caught mid-append
# or carrying a line from a future version of the writer, the answer must be a
# number and a list. A page whose job is to be readable when things are broken
# may not be the thing that breaks.
HANDOFF_DEBT = Path(os.environ.get("HERDR_HANDOFF_DEBT",
                                   Path.home() / ".local/state/omp/handoff-debt.jsonl"))


def _debt_row(obj) -> dict | None:
    """One ledger line, normalised — or None when it cannot be trusted.

    A row is usable only if it names a repo: every other field degrades to a
    shown-as-unknown detail, but a debt with no owner is one nobody can pay,
    and counting it would inflate the badge with work that does not exist."""
    if not isinstance(obj, dict):
        return None
    repo = obj.get("repo")
    if not isinstance(repo, str) or not repo.strip():
        return None

    def _count(key) -> int:
        # bool is an int in Python; a producer-supplied count is advisory and
        # its type is never assumed.
        v = obj.get(key)
        return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else 0

    at, cwd = obj.get("at"), obj.get("sessionCwd")
    return {"repo": repo.strip(),
            "at": at if isinstance(at, str) else "",
            "session_cwd": cwd if isinstance(cwd, str) else "",
            "writes": _count("writes"), "mutations": _count("mutations"),
            "shipped": obj.get("shipped") is True,
            "lesson_debt": obj.get("lessonDebt") is True}


def handoff_debt_data() -> dict:
    """Unpaid rows newest-first, the repos they name, and what was unreadable.

    `unreadable` is REPORTED rather than swallowed. A half-written final line
    is normal for an append-only file read at an arbitrary moment, but a reader
    that silently drops lines would show "no debt" for a file full of it — the
    failure mode that makes a surface worth less than no surface."""
    try:
        text = HANDOFF_DEBT.read_text(errors="replace")
    except FileNotFoundError:
        # No ledger is the normal state on a machine whose sessions all keep
        # their handoffs. Zero, not an error.
        return {"debt": [], "repos": [], "unreadable": 0, "present": False}
    except OSError as exc:
        return {"debt": [], "repos": [], "unreadable": 0, "present": False,
                "error": f"{type(exc).__name__}: {exc}"}
    rows, unreadable = [], 0
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            row = _debt_row(json.loads(line))
        except (json.JSONDecodeError, ValueError):
            row = None
        if row is None:
            unreadable += 1
        else:
            rows.append(row)
    rows.sort(key=lambda r: r["at"], reverse=True)  # ISO-8601 sorts as text
    return {"debt": rows, "repos": sorted({r["repo"] for r in rows}),
            "unreadable": unreadable, "present": True,
            "shipped": sum(1 for r in rows if r["shipped"]),
            "lesson_debt": sum(1 for r in rows if r["lesson_debt"])}


# Written hourly by cost-report.py (its LaunchAgent). Same env override the
# writer honours, so a test or a relocated state dir moves both ends at once.
COST_REPORT = Path(os.environ.get("HERDR_COST_REPORT_PATH", STATE / "cost-report.json"))
# Hourly writer; three missed runs means the job stopped, and a spend number
# that silently stops moving reads exactly like a quiet week.
COST_REPORT_STALE_S = 3 * 3600
# Week-over-week growth past this is worth a look even with no single outlier.
COST_GROWTH_ALERT = 1.25


def cost_report_data() -> dict:
    """The last cost-report.py snapshot plus the three reasons to look at it.

    Absent is not an error (the job may not be installed yet); unreadable,
    shapeless and stale are, because each would otherwise show a number that
    is no longer true."""
    try:
        d = json.loads(COST_REPORT.read_text())
    except FileNotFoundError:
        return {"present": False}
    except (OSError, json.JSONDecodeError) as exc:
        return {"present": False, "error": f"{type(exc).__name__}: {exc}"}
    if not isinstance(d, dict) or not isinstance(d.get("total_cost"), (int, float)):
        return {"present": False, "error": "cost-report.json has no total_cost"}
    alerts = []
    try:
        gen = dt.datetime.fromisoformat(str(d.get("generated_at")).replace("Z", "+00:00"))
        age = (dt.datetime.now(dt.timezone.utc) - gen).total_seconds()
    except (TypeError, ValueError):
        age = None
    if age is None or age > COST_REPORT_STALE_S:
        alerts.append("report is stale — is the cost-report job running?")
    # One over-threshold turn per compaction is the cap WORKING (that turn is
    # what triggers it); a second in a row with no compaction between is the
    # cap failing — cost-report.py counts exactly that as cap_misses_since_cap.
    if d.get("cap_misses_since_cap"):
        alerts.append(f"{d['cap_misses_since_cap']} turn(s) stayed over "
                      f"{_num(d.get('context_alert_threshold')) or 300_000:,} context with no compaction "
                      f"since the cap")
    prev = d.get("prev_total_cost") or 0
    if prev and d["total_cost"] > prev * COST_GROWTH_ALERT:
        alerts.append(f"spend up {(d['total_cost'] - prev) / prev * 100:.0f}% week over week")
    return dict(d, present=True, alerts=alerts)


def _num(v) -> float:
    return v if isinstance(v, (int, float)) else 0


def cost_rows(c: dict) -> str:
    """Alerts first, then the sessions that cost the most, then spend by repo.
    Every number is coerced: a hand-edited or corrupt report degrades this
    section, never the whole overview page (render_overview has one try)."""
    if c.get("error"):
        return f"<tr class=hot><td>{_esc(c['error'])}</td></tr>"
    if not c.get("present"):
        return "<tr><td class=dim>no cost report yet (cost-report.py has not run)</td></tr>"
    out = [f"<tr class=hot><td colspan=5><span class='pill hot'>alert</span> {_esc(a)}</td></tr>"
           for a in c.get("alerts", [])]
    out.append("<tr><th>session</th><th>repo</th><th>cost</th><th>turns</th><th>max context</th></tr>")
    threshold = _num(c.get("context_alert_threshold")) or 300_000
    for s in c.get("top_sessions") or []:
        if not isinstance(s, dict):
            continue
        ctx = int(_num(s.get("max_context")))
        out.append(f"<tr{' class=hot' if ctx > threshold else ''}><td>{_esc(s.get('session_id'))}</td>"
                   f"<td>{_esc(s.get('repo'))}</td><td>${_num(s.get('cost')):,.2f}</td>"
                   f"<td>{int(_num(s.get('turns')))}</td><td>{ctx:,}</td></tr>")
    by_repo = c.get("cost_by_repo") if isinstance(c.get("cost_by_repo"), dict) else {}
    repos = " · ".join(f"{_esc(r)} ${_num(v):,.0f}" for r, v in by_repo.items())
    out.append(f"<tr><td colspan=5 class=dim>by repo: {repos or '—'} · "
               f"generated {_age(c.get('generated_at'))} ago</td></tr>")
    return "".join(out)


# ── deploy drift: is the code THIS PROCESS runs still what origin/main says? ──
# The hub ran 3417af0 for hours while origin/main had fixes ahead of it, and
# kb-deploy (KB_DEPLOY, above) lags until its nightly run — nobody saw either
# until someone was debugging something else. `restart.sh --verify` already
# computes exactly this (deployed sha vs origin/main; `app_rev`/`app_rev_sha`
# in launchd/agent-lib.sh) but only when a human remembers to run it by hand.
# This is the same comparison, on the same read-time schedule as every other
# network-backed card (see CACHES below), so a stale deploy becomes a card
# instead of an incident.
#
# Two repos: herdr-control's own APP_ROOT — this process's deployed
# worktree, the same directory RUNNING_REV above is computed from, a
# DETACHED worktree pinned at a sha (agent-lib.sh's deploy_app) — and
# knowledge-base's kb-deploy checkout (KB_DEPLOY), an ORDINARY branch
# checkout its own nightly job fast-forwards (see kb_data()'s "kb-deploy has
# no server/hub_forms.py yet" comment), not a detached worktree. Either way
# HEAD is "what is deployed", never "whatever someone left checked out".
DEPLOY_DRIFT_REPOS = [
    ("herdr-control", APP_ROOT),
    ("knowledge-base", KB_DEPLOY),
]


def _repo_drift(repo: str, path: Path) -> dict:
    """One repo's deployed sha vs origin/main, and how long they have
    differed. `behind_minutes` is the AGE of the first commit origin/main has
    that the deployed sha does not — not "now minus when this cache last
    filled" — so a repo stale since yesterday does not read as "just
    noticed" every time this cache refills."""
    if not (path / ".git").exists():
        return {"repo": repo, "error": f"{path} is not a git checkout"}

    def _git(*args, timeout=10):
        try:
            out = subprocess.run(["git", "-C", str(path), *args],
                                 capture_output=True, text=True, timeout=timeout)
        except Exception:
            return None
        return out.stdout.strip() if out.returncode == 0 else None

    def _short(sha):
        return _git("rev-parse", "--short", sha) or sha[:7]

    # The only network call in this whole reader. `_deploy_drift_prime_loop`
    # (main()) keeps this cache warm off the request path; 5s (not 20s)
    # bounds the worst case for whichever reader DOES still pay it inline —
    # /api/summary's consumers allow 2-5s, and 20s x 2 repos used to be able
    # to block one behind the other under the cache's own lock.
    #
    # Its SUCCESS is recorded and reported, not just attempted: a failed
    # fetch used to leave origin/main at whatever it last resolved to, and a
    # reader comparing against that silently stale ref got "in sync" for a
    # repo nobody could actually verify — worse than reporting nothing,
    # because it looks like an answer.
    fetch_ok = _git("fetch", "-q", "origin", "main", timeout=5) is not None
    deployed, main = _git("rev-parse", "HEAD"), _git("rev-parse", "origin/main")
    if not deployed or not main:
        return {"repo": repo, "error": "git rev-parse failed (no HEAD or no origin/main here)"}
    if not fetch_ok:
        # We KNOW a comparison, just not whether it is CURRENT — the
        # origin/main resolved above is whatever the last successful fetch
        # left behind, possibly hours old. Reported hot and unverified
        # rather than as a (possibly false) verdict either way.
        return {"repo": repo, "deployed": _short(deployed), "main": _short(main),
                "behind_minutes": 0, "fetch_ok": False}
    if deployed == main:
        return {"repo": repo, "deployed": _short(deployed), "main": _short(main),
                "behind_minutes": 0, "fetch_ok": True}
    # Oldest commit reachable from origin/main but not the deployed sha: ITS
    # commit time is when the drift began.
    first = _git("rev-list", f"{deployed}..origin/main", "--reverse")
    first_sha = first.splitlines()[0] if first else None
    if not first_sha:
        # Empty: the deployed sha is ahead of (or off) main entirely — a
        # different question than "we forgot to deploy", so reported as in
        # sync, not drifted.
        return {"repo": repo, "deployed": _short(deployed), "main": _short(main),
                "behind_minutes": 0, "fetch_ok": True}
    ts = _git("log", "-1", "--format=%ct", first_sha)
    # Floored at 1, never 0: drift keys on deployed != main, already
    # established by reaching this line — a commit that landed 20 seconds
    # ago is still an undeployed commit, and "0m behind" reads as "in sync"
    # on the card and detail row.
    behind_minutes = max(1, int((time.time() - int(ts)) / 60)) if ts and ts.lstrip("-").isdigit() else 1
    return {"repo": repo, "deployed": _short(deployed), "main": _short(main),
            "behind_minutes": behind_minutes, "fetch_ok": True}


def deploy_drift_data() -> dict:
    return {"repos": [_repo_drift(repo, path) for repo, path in DEPLOY_DRIFT_REPOS]}


CACHES = {
    # Liveness: cheap, filled inline, never served stale. See Cached.
    "herdr": Cached(5, herdr_data, name="herdr"),
    "forms": Cached(3, forms_data, name="forms"),
    # One local file read of a few lines: cheaper than the registry query
    # above, so it is filled inline like the other two and never served stale.
    "debt": Cached(5, handoff_debt_data, name="debt"),
    # One local JSON read, rewritten hourly by cost-report.py.
    "cost": Cached(30, cost_report_data, name="cost"),
    # Network-backed: ~350ms each, so a reader gets the stale value and the
    # refresh happens behind them.
    "search": Cached(120, search_data, stale_ok=True, name="search"),
    "kb": Cached(300, kb_data, stale_ok=True, name="kb"),
    "links": Cached(60, links_data, stale_ok=True, name="links"),
    "loops": Cached(10, loops_data, stale_ok=True, name="loops"),
    # One ~250ms node call to Supabase: served stale, refreshed behind the reader.
    "portal": Cached(60, portal_data, stale_ok=True, name="portal"),
    # Primed by _deploy_drift_prime_loop (main()), not just read-triggered
    # like kb/links/search above — see that loop for why. Still stale_ok so
    # a request is never blocked on it; STALE_MAX above bounds the "priming
    # loop somehow hasn't run yet" case.
    "deploy_drift": Cached(180, deploy_drift_data, stale_ok=True, name="deploy_drift"),
}


# ── rendering ──────────────────────────────────────────────────────────────────
def _esc(v) -> str:
    return html.escape(str(v if v is not None else ""))


def _script_json(v) -> str:
    """json.dumps with `<` escaped to `\\u003c` so the result is safe to
    inline inside a `<script>` block -- a value containing a literal
    `</script>` would otherwise close the block early and run as markup/script
    in the hub's own origin (PR #214 review LOW F3, e.g. RATINGS_FORM's
    `run_id_json`)."""
    return json.dumps(v).replace("<", "\\u003c")


def _age(iso) -> str:
    if not iso:
        return "—"
    if isinstance(iso, (int, float)):
        then = dt.datetime.fromtimestamp(iso / 1000, tz=dt.timezone.utc)
    else:
        try:
            then = dt.datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        except ValueError:
            return str(iso)
        if then.tzinfo is None:
            then = then.replace(tzinfo=dt.timezone.utc)
    s = int((dt.datetime.now(dt.timezone.utc) - then).total_seconds())
    if s < 0:
        return f"in {-s // 60}m"
    for lim, div, suf in ((90, 1, "s"), (5400, 60, "m"), (172800, 3600, "h")):
        if s < lim:
            return f"{s // div}{suf}"
    return f"{s // 86400}d"


def _minutes_label(m: int) -> str:
    """`behind_minutes` → the same coarse-bucket style as `_age()`, for the
    deploy-drift card and its detail rows."""
    if m < 60:
        return f"{m}m"
    if m < 1440:
        return f"{m // 60}h"
    return f"{m // 1440}d"


def _drift_label(r: dict) -> str:
    if r.get("error"):
        return f"{r['repo']} unavailable"
    if r.get("fetch_ok") is False:
        return f"{r['repo']} unverified (fetch failed)"
    m = r.get("behind_minutes") or 0
    if m <= 0:
        return f"{r['repo']} in sync"
    return f"{r['repo']} {r['deployed']}→{r['main']} ({_minutes_label(m)})"


STYLE = """
 :root{color-scheme:dark}
 body{margin:0;background:#0f1115;color:#e6e9ef;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
 header{display:flex;gap:18px;align-items:center;padding:14px 20px;border-bottom:1px solid #272c37;background:#171a21}
 header b{font-size:16px} header a{color:#9aa3b2;text-decoration:none} header a.on{color:#e6e9ef;border-bottom:2px solid #e08a4a}
 main{max-width:1150px;margin:0 auto;padding:16px 20px 60px}
 h2{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#9aa3b2;margin:22px 0 8px}
 table{width:100%;border-collapse:collapse;background:#171a21;border:1px solid #272c37;border-radius:10px;overflow:hidden}
 td{padding:8px 10px;border-top:1px solid #272c37;vertical-align:top} tr:first-child td{border-top:0}
 .pill{font-size:11px;padding:1px 8px;border-radius:999px;border:1px solid #272c37;color:#9aa3b2;white-space:nowrap}
 .hot .pill,.pill.hot{color:#1a1206;background:#e08a4a;border-color:#e08a4a} .pill.ok{color:#6fd39a;border-color:#6fd39a}
 .pill.bad{color:#ff7a7a;border-color:#ff7a7a} .pill.run{color:#6aa6ff;border-color:#6aa6ff}
 .age{color:#9aa3b2;white-space:nowrap;text-align:right} .dim{color:#9aa3b2} small{color:#9aa3b2} a{color:#6aa6ff}
 .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px}
 .card{background:#171a21;border:1px solid #272c37;border-radius:12px;padding:14px 16px;text-decoration:none;color:inherit;display:block}
 .card .n{font-size:28px;font-weight:700;line-height:1.1} .card .t{color:#9aa3b2;font-size:12px;text-transform:uppercase;letter-spacing:.08em}
 .card.hot{border-color:#e08a4a} .card .s{font-size:12px;color:#9aa3b2;margin-top:6px}
 iframe{width:100%;height:720px;border:1px solid #272c37;border-radius:12px;background:#fff}
 iframe.dframe{height:calc(100vh - 190px);min-height:560px}
 .dhead{margin:10px 0 8px}
 details.hist{margin-top:22px;border-top:1px solid #272c37;padding-top:6px}
 details.hist>summary{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#9aa3b2;cursor:pointer;padding:6px 0;list-style:none}
 details.hist>summary::-webkit-details-marker{display:none}
 details.hist>summary::before{content:"\\25B8  ";color:#e08a4a}
 details.hist[open]>summary::before{content:"\\25BE  "}
 details.hist>summary:hover{color:#e6e9ef}
 details.hist>table{margin-top:8px}
 pre{background:#0c0e13;border:1px solid #272c37;border-radius:8px;padding:10px;overflow:auto;font-size:12px}
 button.decide{font:600 12px system-ui;padding:4px 10px;border-radius:5px;border:1px solid #6aa6ff;background:transparent;color:#6aa6ff;cursor:pointer} button.decide:hover{background:#6aa6ff;color:#0b1020}
 .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;background:#ff7a7a} .dot.ok{background:#6fd39a}
 .chips{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 10px}
 .chips a.chip{display:flex;align-items:baseline;gap:6px;padding:4px 10px;border:1px solid #272c37;border-radius:999px;font-size:12px;font-weight:600;color:#9fb6d0;text-decoration:none}
 .chips a.chip small{font-weight:400;color:#6b7a8d}
 .chips a.chip:hover{border-color:#6aa6ff;color:#cfe0f5}
 .chips a.chip.on{border-color:#6aa6ff;color:#cfe0f5;background:#11161d}
 .chips a.chip.hot{border-color:#ff7a7a} .chips a.chip.hot small{color:#ff9d9d}
"""
NAV = [("/", "overview"), ("/projects", "projects"), ("/decisions", "decisions"), ("/loops", "loops"), ("/herdr", "herdr"), ("/timeline", "timeline"), ("/search", "search"), ("/kb", "kb"), ("/links", "links")]

# ---- SCOPE: one hub, many projects ------------------------------------------
# Every task in the registry already carries the repo it belongs to, and the
# fleet spans five of them — but every surface rendered all of them mixed
# together, so "what needs attention" meant "in any of five repos" and the
# reader had to filter by eye. That is the whole reason a second orchestrator
# looked attractive: not because one hub cannot hold the work, but because one
# VIEW could not separate it.
#
# Scoping is READ-ONLY and additive. There is still one registry, one hub, one
# answering path — a second writer is the thing we specifically do not want,
# because `peer-answer` sees every pane and #95 gave it standing authority.
#
# `?repo=` accepts either the basename (what a chip links to, `knowledge-base`)
# or the full path (what a script has, `/Users/thurbs/Code/knowledge-base`).
def scope_of(query: str) -> str:
    """The requested repo scope, or "" for the whole fleet."""
    try:
        return (urllib.parse.parse_qs(query).get("repo") or [""])[0].strip()
    except Exception:
        return ""


def _repo_matches(repo: str, scope: str) -> bool:
    repo = repo or ""
    return bool(scope) and (repo == scope or repo.rsplit("/", 1)[-1] == scope)


def scope_repos(d: dict) -> list:
    """[(basename, full path, task count, attention count)], busiest first."""
    by: dict = {}
    for t in d.get("tasks") or []:
        full = t.get("repo") or ""
        if not full:
            continue
        row = by.setdefault(full, {"n": 0, "att": 0})
        row["n"] += 1
        if t.get("state") in ATTENTION:
            row["att"] += 1
    return sorted(((full.rsplit("/", 1)[-1], full, v["n"], v["att"]) for full, v in by.items()),
                  key=lambda r: (-r[3], -r[2], r[0]))


def scoped(d: dict, scope: str) -> dict:
    """A snapshot narrowed to one repo. Unscoped input is returned untouched.

    Events are narrowed through their TASK, because an event row carries a
    task_id and a label but no repo of its own — filtering on the label text
    would be a guess, and a scope that quietly keeps another repo's events is
    worse than no scope at all.

    `checkpoints` and `max_event_seq` are deliberately NOT narrowed: a
    conductor checkpoint is a fleet-wide fact, and pretending otherwise would
    make a per-repo view claim the fleet is further behind than it is.
    """
    if not scope or d.get("error"):
        return d
    tasks = [t for t in (d.get("tasks") or []) if _repo_matches(t.get("repo"), scope)]
    ids = {t.get("task_id") for t in tasks}
    return dict(
        d,
        tasks=tasks,
        attention=[t for t in (d.get("attention") or []) if _repo_matches(t.get("repo"), scope)],
        events=[e for e in (d.get("events") or []) if e.get("task_id") in ids],
        scope=scope,
        scope_known=any(_repo_matches(t.get("repo"), scope) for t in (d.get("tasks") or [])),
    )


def scope_chips(d: dict, path: str, scope: str) -> str:
    """The repo selector. Counts come from the UNSCOPED snapshot, so switching
    scope never hides where the rest of the work is."""
    rows = scope_repos(d)
    if not rows:
        return ""
    total_att = sum(r[3] for r in rows)
    out = [f"<a class='chip {'on' if not scope else ''}' href='{path}'>all"
           f"<small>{len(d.get('tasks') or [])} · {total_att} hot</small></a>"]
    for base, full, n, att in rows:
        on = "on" if _repo_matches(full, scope) else ""
        hot = "hot" if att else ""
        out.append(f"<a class='chip {on} {hot}' href='{path}?repo={urllib.parse.quote(base)}'>"
                   f"{_esc(base)}<small>{n} · {att} hot</small></a>")
    unknown = ""
    if scope and not any(_repo_matches(r[1], scope) for r in rows):
        # Say it, rather than rendering an empty table that looks like calm.
        unknown = (f"<div class=dim style='margin:6px 0'>no tasks for scope "
                   f"<b>{_esc(scope)}</b> — showing nothing, not nothing to show</div>")
    return f"<div class=chips>{''.join(out)}</div>{unknown}"



# ---- PROJECTS: thurber-os docs/project-contract-plan.md §2 ------------------
# A project is a repo plus an optional `project:` label (task.project, from
# spawn-task.sh --project); default is the repo's own basename. This joins,
# per project: live tasks (state/pane/claim/blocked-minutes), open PRs for
# their branches (gh, cached), open decision forms delivered to one of its
# panes, the worktree's SPEC.md acceptance checklist, and a next-step line.
# `docs/project-status.md` stays the human narrative; /api/projects is the
# live truth, and every surface (this page, the agent tool, the ambient
# card) reads the SAME payload — "one source, four surfaces".
RUNNING_TASK_STATES = frozenset(("starting", "running", "blocked"))


def project_key(task: dict) -> str:
    """The project a task belongs to: its explicit label, or its repo's own
    basename when spawn-task.sh was never told --project (every task
    registered before this feature, and every unlabeled one after it)."""
    repo = (task.get("repo") or "").rstrip("/")
    return task.get("project") or (repo.rsplit("/", 1)[-1] if repo else "(unknown)")


_SPEC_CHECKBOX = re.compile(r"^-\s*\[([ xX])\]\s*(.+?)\s*$")
# spawn-task.sh's own _spec_template writes this literal line into every
# worktree that was never given a --brief. A worker that closes `shipped`
# without ever touching SPEC.md leaves it behind verbatim — measured live,
# on the first tick after this feature deployed, as next_step for two
# already-finished projects. Never a real acceptance item.
_SPEC_PLACEHOLDER = "(one checkbox per acceptance criterion)"


def spec_checklist(worktree: str | None) -> tuple[list[dict], str | None]:
    """(items, next_step) from <worktree>/.handoffs/SPEC.md's `## Acceptance`
    section.

    Only `- [ ] text` / `- [x] text` lines count — spawn-task.sh's own
    template writes exactly that shape (_spec_template). A `--brief` SPEC.md
    that is free prose with no checkboxes at all (real example: knowledge-
    base's fub-content-layer brief, a numbered "Scope" list) has no items and
    no next step — reported as such, never guessed at, because inventing a
    next step from prose is exactly the unchecked claim item 1 exists to stop.

    A line that starts with whitespace and is not itself a new checkbox is a
    WRAPPED CONTINUATION of the previous item — appended to its text rather
    than dropped. Without this, an item that wraps onto an indented second
    line (this file's own SPEC.md acceptance list does) truncated at the
    wrap point everywhere next_step is shown: the wake card, the ambient
    card, and project_status.

    A checkbox's OWN mark (`[ ]` vs `[x]`) is read here only to decide
    ordering among items that have no other signal; project_needs_wake does
    NOT trust it to mean "this criterion is done" — see that function's own
    docstring for why (workers write PROOF.md and close the task; they are
    not expected to also tick SPEC.md).

    next_step is the first unticked item's text, or None once every item is
    ticked (or there were none to begin with, or the only line present was
    the unfilled template placeholder) — "None" here means "nothing
    outstanding in the checklist", not "the project is done"; the caller
    layers closure/PR/decision state on top before deciding that.
    """
    if not worktree:
        return [], None
    try:
        text = (Path(worktree) / ".handoffs" / "SPEC.md").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return [], None
    items: list[dict] = []
    in_acceptance = False
    for line in text.splitlines():
        if line.startswith("## "):
            in_acceptance = line.strip().lower() == "## acceptance"
            continue
        if not in_acceptance:
            continue
        m = _SPEC_CHECKBOX.match(line)
        if m:
            item_text = m.group(2)
            if item_text.strip() == _SPEC_PLACEHOLDER:
                continue
            items.append({"text": item_text, "done": m.group(1).lower() == "x"})
            continue
        if items and line.strip() and line[:1] in (" ", "\t"):
            items[-1]["text"] = f"{items[-1]['text']} {line.strip()}"
    next_step = next((it["text"] for it in items if not it["done"]), None)
    return items, next_step


# A closure reason that means the project's story is DONE, not merely that
# its latest worker exited. Set only by a real `set_task_state … completed
# <reason>` call, which already required a valid proof reference
# (lib/run-registry.sh's closure-reason gate, item 1) — a stronger signal
# than an unticked SPEC.md checkbox, which a worker is never required to
# maintain. `handed_off_to:<x>` is matched by prefix (the `<x>` varies).
_CLOSED_REASONS = frozenset(("shipped", "canceled", "no-follow-on"))


def project_needs_wake(task_states: list, next_step: str | None, open_forms: int,
                       closure_reason: str | None = None, open_prs: int = 0) -> bool:
    """thurber-os docs/project-contract-plan.md item 3, 'carry to completion':
    a project gets woken to Main when it has a next step, no live worker, and
    nothing it is waiting on from Terrence.

    * a next step must exist — a finished checklist, a --brief SPEC.md with
      no checkboxes (next_step always None), or a SPEC.md whose only line
      was the unfilled template placeholder (filtered in spec_checklist) has
      nothing to carry forward.
    * 'no live worker' is read from task_states, which the caller populates
      from the REGISTRY's stored state, never the page's derived one — see
      the caller (projects_data()) for why `stalled` and `ready_review` are
      NOT live-worker signals to trust here. `blocked` counts as LIVE on
      purpose: a worker sitting on a blocked prompt is already being carried
      by attention-tick.sh's own per-pane escalation ladder, and paging Main
      a second time for the same stuck worker through a different channel is
      exactly the double-wake PR #132 exists to prevent, one layer up.
    * 'nothing waiting on Terrence' — an open decision form for this project
      already covers it; a second page for the same gap is the noise item
      3a's own dedupe ladder exists to prevent, just at project granularity.
    * an open PR means the work is in review (Terrence's queue), even when its
      worker pane is gone and the task reconciled to `lost` — paging Main to
      "carry" it would be the respawn-reviewed-work failure (second review
      of #146, P2).
    * a CLOSED latest task (shipped/canceled/no-follow-on/handed_off_to:*)
      means a human-reviewed gate already decided this project's outcome;
      an unticked SPEC.md box left behind by a worker that never edited the
      file is not grounds to re-open it. Measured live: on the first tick
      after this feature deployed, two already-`shipped` projects
      (tourguide, watchdog-worker) paged Main with the template placeholder
      as their "next step" before this gate existed.
    """
    if not next_step:
        return False
    if any(s in RUNNING_TASK_STATES for s in task_states):
        return False
    if open_forms > 0:
        return False
    if open_prs > 0:
        return False
    if closure_reason and (closure_reason in _CLOSED_REASONS or closure_reason.startswith("handed_off_to:")):
        return False
    return True


def _now_iso_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _claims_by_worktree() -> dict:
    """worktree path -> live claim record, straight from the registry's own
    `claims` table (lib/claims.sh) — same read-only connection discipline as
    herdr_data(). Empty when the registry or the table doesn't exist yet (a
    host that has never run claim_acquire, or an old schema)."""
    if not REGISTRY.exists():
        return {}
    try:
        conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                "SELECT scope, pane_id, purpose, expires_at FROM claims "
                "WHERE released_at IS NULL AND expires_at > ?", (_now_iso_utc(),)).fetchall()
            return {r["scope"]: {"pane_id": r["pane_id"], "purpose": r["purpose"],
                                  "expires_at": r["expires_at"]} for r in rows}
        finally:
            conn.close()
    except sqlite3.Error:
        return {}


# ---- open PRs for a project's branches, via `gh` -----------------------------
# `gh` is a network call, so it gets its OWN cache rather than riding
# CACHES["projects"]'s ttl. ONE call per REPO (not per branch): the original
# cut ran `gh pr list --head <branch>` for every DISTINCT branch of every
# task ever registered (completed and lost ones included) — on the live
# registry that was 16 calls/tick, ~960/hr, growing with every spawn, and at
# ~140 branches a cold fill would exceed Cached's own FILL_BUDGET_S (70s)
# and never complete. `gh pr list --state open` with no `--head` returns
# every open PR for the repo in one call; matching a branch to its PR is a
# local dict lookup on `headRefName`, not a second network round trip.
_PR_CACHE: dict = {}
_PR_CACHE_LOCK = threading.Lock()
# Above the 60s attention-tick interval so a tick that already warmed this
# via CACHES["projects"] does not force a second cold `gh` call a few
# seconds later from a page view landing between ticks.
PR_CACHE_TTL_S = 90.0


def _open_prs_for_repo(repo: str | None) -> dict:
    """{headRefName: pr_dict} for every OPEN PR in `repo` (the MAIN checkout —
    task.repo, not the worktree; both share the same origin, and the main
    checkout is guaranteed to still exist after a worktree is removed).
    `--state open` excludes merged/closed PRs at the source — no client-side
    state filter needed. Never raises: gh missing, unauthenticated, or
    offline all degrade to no PRs rather than breaking the page."""
    if not repo:
        return {}
    now = time.monotonic()
    with _PR_CACHE_LOCK:
        cached = _PR_CACHE.get(repo)
        if cached and now - cached[0] < PR_CACHE_TTL_S:
            return cached[1]
    by_branch: dict = {}
    try:
        r = subprocess.run(
            ["gh", "pr", "list", "--state", "open",
             "--json", "number,url,title,state,headRefName,isDraft,mergeable,statusCheckRollup"],
            cwd=repo, capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            for pr in json.loads(r.stdout or "[]"):
                if isinstance(pr, dict) and pr.get("headRefName"):
                    by_branch[pr["headRefName"]] = pr
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        by_branch = {}
    with _PR_CACHE_LOCK:
        _PR_CACHE[repo] = (now, by_branch)
    return by_branch


def _project_open_forms(pane_ids: set, labels: set, forms: dict) -> list:
    """Open decision forms delivered to one of this project's panes.
    `deliver_to` (formserve.py --deliver) is a herdr pane/tab/label string —
    matched against this project's live pane ids and its task labels, the two
    shapes --deliver is normally given. Not scoped by repo at all when
    `deliver_to` is empty (a form served with no --deliver): those are fleet-
    wide decisions, correctly excluded from every project's own list."""
    out = []
    for f in forms.get("open", []):
        d = f.get("deliver_to") or ""
        if not d:
            continue
        if d in pane_ids or d in labels or any(lbl and lbl in d for lbl in labels):
            out.append(f)
    return out


# ---- a project's live blocked-prompt text, via attention-tick.sh's own probe -
# herdr_live.py's pane record deliberately carries NO screen content
# (_pane_record's own docstring: "no screen content, so nothing here can leak
# a command or a credential"), so "what is it blocked ON" has exactly one
# sanctioned reader in this codebase: attention_probe (attention-tick.sh),
# which already does the one pane read this whole repo allows for that
# purpose. Reused via its `probe` CLI verb rather than re-implemented.
_PROBE_CACHE: dict = {}
_PROBE_CACHE_LOCK = threading.Lock()
PROBE_CACHE_TTL_S = 5.0
ATTENTION_TICK_SCRIPT = Path(__file__).resolve().parent / "attention-tick.sh"


def _pane_probe(pane_id: str) -> dict:
    if not pane_id:
        return {}
    now = time.monotonic()
    with _PROBE_CACHE_LOCK:
        cached = _PROBE_CACHE.get(pane_id)
        if cached and now - cached[0] < PROBE_CACHE_TTL_S:
            return cached[1]
    result: dict = {}
    if ATTENTION_TICK_SCRIPT.exists():
        try:
            r = subprocess.run(["bash", str(ATTENTION_TICK_SCRIPT), "probe", pane_id],
                                capture_output=True, text=True, timeout=5)
            if r.returncode == 0:
                result = json.loads(r.stdout or "{}")
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
            result = {}
    with _PROBE_CACHE_LOCK:
        _PROBE_CACHE[pane_id] = (now, result)
    return result


def projects_data() -> dict:
    """The one join every /projects surface reads (§2's 'one source, four
    surfaces'): per project, live tasks, open PRs, open decisions delivered to
    its panes, the SPEC.md checklist, and a next-step line."""
    h = CACHES["herdr"].get() or {}
    if h.get("error"):
        return {"error": h["error"], "projects": []}
    tasks = h.get("tasks") or []
    claims = _claims_by_worktree()
    forms = CACHES["forms"].get() or {}

    by_project: dict = {}
    for t in tasks:
        by_project.setdefault(project_key(t), []).append(t)

    projects = []
    for slug, ptasks in sorted(by_project.items()):
        ptasks = sorted(ptasks, key=lambda t: t.get("updated_at") or "", reverse=True)
        latest = ptasks[0]
        items, next_step = spec_checklist(latest.get("worktree"))
        pane_ids = {t.get("pane_id") for t in ptasks if t.get("pane_id")}
        labels = {t.get("label") for t in ptasks if t.get("label")}
        open_forms = _project_open_forms(pane_ids, labels, forms)
        branches = {t.get("branch") for t in ptasks if t.get("branch")}
        # ONE gh call per REPO (see _open_prs_for_repo), matched locally to
        # this project's own branches — never a call per branch.
        repo_prs = _open_prs_for_repo(latest.get("repo"))
        prs = [repo_prs[b] for b in sorted(branches) if b in repo_prs]

        task_rows_out = []
        for t in ptasks:
            row = {"task_id": t.get("task_id"), "state": t.get("state"),
                   "pane_id": t.get("pane_id"), "label": t.get("label"),
                   "branch": t.get("branch"), "worktree": t.get("worktree"),
                   "updated_at": t.get("updated_at")}
            claim = claims.get(t.get("worktree") or "")
            if claim:
                row["claim"] = claim
            if t.get("state") == "blocked":
                since = _iso_epoch(t.get("updated_at"))
                row["blocked_minutes"] = round((time.time() - since) / 60, 1) if since else None
                # Redacted to the bare executable name — herdr_live's own
                # pane record deliberately carries no screen content ("so
                # nothing here can leak a command or a credential"), and this
                # unauthenticated endpoint must keep that guarantee: an
                # approval prompt routinely shows a command with an inline
                # token (`curl -H 'Authorization: Bearer …'`) or a path that
                # discloses a client name. The first whitespace-separated
                # token names the tool (bash, gh, curl, …) without any of
                # its arguments.
                probe = _pane_probe(t.get("pane_id") or "")
                cmd = probe.get("command_text") if probe.get("visible") else None
                row["blocked_on"] = cmd.split()[0] if cmd and cmd.split() else None
            task_rows_out.append(row)

        # Liveness for project_needs_wake is the REGISTRY's own stored state
        # (starting/running/blocked/completed/…), never the page's DERIVED
        # one: derive() maps a live worker with no completion evidence yet to
        # `stalled`, and a finished worker awaiting Terrence's PR review to
        # `ready_review` — both of which have stored_state == "running"
        # because nothing has transitioned them, and both mean "not actually
        # abandoned". Reading the derived state here made a project with an
        # alive idle pane, or one already waiting on Terrence's own review,
        # read as "no live worker" and page Main anyway.
        task_states = [t.get("stored_state") or t.get("state") for t in ptasks]
        # The LATEST task's closure — set only by a real `set_task_state …
        # completed <reason>` call, which already required a valid proof
        # reference (lib/run-registry.sh's closure-reason gate, item 1). A
        # project whose most recent task closed shipped/canceled/no-follow-on
        # or was handed off has a definitive, human-reviewed outcome; SPEC.md
        # checkboxes are not re-derived against it because workers are not
        # expected to tick them — they write PROOF.md and close the task.
        closure_reason = latest.get("closure_reason")
        next_step_line = next_step or (
            "waiting on: decision" if open_forms else
            ("waiting on: review" if any(t.get("state") == "ready_review" for t in ptasks) else None))
        projects.append({
            "project": slug, "repo": latest.get("repo"),
            "tasks": task_rows_out, "prs": prs,
            "open_decisions": [{"id": f.get("id"), "title": f.get("title"), "status": f.get("status")}
                               for f in open_forms],
            "spec_items": items, "next_step": next_step_line,
            "needs_wake": project_needs_wake(task_states, next_step, len(open_forms), closure_reason,
                                             open_prs=len(prs)),
        })
    return {"projects": projects}


# ---- project-level "carry to completion" wake (item 3, on top of §3a) -------
PROJECT_WAKE_SCRIPT = Path(__file__).resolve().parent / "project-wake.sh"
PROJECT_ATTENTION_INTERVAL_S = float(os.environ.get("HERDR_PROJECT_ATTENTION_INTERVAL_S", "60") or 60)


def _project_attention_tick() -> None:
    """One pass over every project's CURRENT computed state — never an edge —
    handing each one needing a wake to project-wake.sh, which owns the
    dedupe/Main-resolution/send discipline (same separation of concerns as
    attention-tick.sh itself: this file decides WHAT needs attention, the
    bash script decides HOW to deliver it safely).

    Reads CACHES["projects"].get(), never projects_data() directly: this is
    the only periodic reader that runs unconditionally every
    PROJECT_ATTENTION_INTERVAL_S regardless of whether a human is looking,
    so it is what keeps the cache warm (Cached's own docstring: "a
    background refresh is only ever kicked by a read") — calling the bare
    function bypassed the cache entirely and left it to go cold between page
    views, which is what made the ambient card's 2s-budgeted curl time out
    after any idle gap past DEFAULT_STALE_MAX (measured: a cold fill against
    the live registry's ~16 branches took 9.2s).
    """
    data = CACHES["projects"].get()
    if data.get("error"):
        return
    if not PROJECT_WAKE_SCRIPT.exists():
        return
    for p in data.get("projects", []):
        if not p.get("needs_wake"):
            continue
        next_step = p.get("next_step") or ""
        card = f"{p['project']}: next — {next_step} (no live worker, nothing open for you)"
        try:
            # send-to-agent.sh's own retry loop (composer-stability polling)
            # can run several seconds; 15s was tight enough to risk killing
            # the script BETWEEN claim_once and recording project_wake_result
            # (review #146 finding 5) — burning the one-shot slot with no
            # outcome to retry against. 25s gives it more headroom without
            # blocking this tick's other projects for long.
            subprocess.run(["bash", str(PROJECT_WAKE_SCRIPT), p["project"], next_step, card],
                           capture_output=True, timeout=25)
        except (OSError, subprocess.TimeoutExpired):
            pass


def _project_attention_loop() -> None:
    while True:
        try:
            _project_attention_tick()
        except Exception:  # noqa: BLE001 — belt and braces: the loop must not die
            pass
        time.sleep(PROJECT_ATTENTION_INTERVAL_S)


# Registered here, not in the CACHES literal above (which is defined before
# projects_data exists in this file) — same dict, same TTL discipline, just a
# statement that runs after the function it names. `gh`/pane-probe calls
# inside projects_data are their own small caches (PR_CACHE/PROBE_CACHE), so
# this outer ttl mainly bounds how often the SPEC.md/claims/join work reruns.
CACHES["projects"] = Cached(10, projects_data, stale_ok=True, name="projects")

# ---- stall watchdog: idle/done while still owing the conductor an action ---
# .handoffs/SPEC.md (feat/stall-watchdog): three real incidents, 8-14h each
# (2026-10-02/03), every one a task whose pane went idle or finished while a
# signal sat on it that nothing ever turned into a wake — the hub's own
# "N task(s) need attention" COUNT was accurate and ignored the whole time.
#
# Same split as project-wake.sh ("hub.py decides WHAT, bash decides HOW"):
# this is the WHAT half, a pure function over the already-derived task list
# herdr_data() produces (idle/done is `derive()`'s job, not re-implemented
# here) plus two small supplemental facts herdr_data() does not carry.
STALL_SIGNAL_ARTIFACTS = ("tmp/commit-msg.txt", "tmp/REVIEW.md", ".handoffs/PROOF.md")
STALL_WATCHDOG_THRESHOLD_S = float(os.environ.get("HERDR_STALL_WATCHDOG_THRESHOLD_S", "600") or 600)
# PR #223 review H1: without a floor, the first tick after EVERY deploy fires
# on every already-idle/completed row in the registry (254 completed rows,
# 160+ worktrees' empty PROOF.md, measured live) — a wake+Slack storm for
# work that finished long before this code existed to watch it. Each
# signal's own evidence epoch must be AT OR AFTER this floor to ever become
# a candidate; nothing here can be older than the watchdog itself.
# Injectable (`boot_epoch=`) so a test can pin it without sleeping.
#
# Review M-a: a bare `time.time()` constant re-floors on EVERY hub restart,
# not just the first deploy ever — a restart mid-incident silently drops any
# stall whose own evidence predates it, forever, until the task's state
# changes again. Persisted ONCE via a `claim_once`-style event (the claim
# dedupe this feature already relies on everywhere else already survives a
# restart in the registry; the floor only needs the same property) and
# cached in-process after the first read — not recomputed every tick.
_STALL_BOOT_EPOCH_CACHE: list[float] = []
_STALL_BOOT_EPOCH_EVENT_ID = "stall_watchdog_epoch"


def _stall_boot_epoch() -> float:
    if _STALL_BOOT_EPOCH_CACHE:
        return _STALL_BOOT_EPOCH_CACHE[0]
    epoch = time.time()
    if REGISTRY.exists():
        try:
            conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
            try:
                row = conn.execute("SELECT occurred_at FROM events WHERE event_id=?",
                                   (_STALL_BOOT_EPOCH_EVENT_ID,)).fetchone()
            finally:
                conn.close()
            if row and row[0]:
                persisted = _iso_epoch(row[0])
                if persisted is not None:
                    _STALL_BOOT_EPOCH_CACHE.append(persisted)
                    return persisted
        except sqlite3.Error:
            pass
        # First boot ever (no persisted floor yet): claim it now, the same
        # INSERT-OR-IGNORE idempotence `claim_once` itself uses, so two
        # processes racing this on the same registry still agree on one
        # floor (whichever insert wins, both then read it back above on
        # their next call — this process just uses its own `epoch` this
        # one time rather than paying a second read).
        try:
            conn = sqlite3.connect(str(REGISTRY), timeout=2)
            try:
                conn.execute(
                    "INSERT OR IGNORE INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
                    "VALUES (?, '', '', 'stall_watchdog_epoch', ?, '{}')",
                    (_STALL_BOOT_EPOCH_EVENT_ID, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))))
                conn.commit()
            finally:
                conn.close()
        except sqlite3.Error:
            pass
    _STALL_BOOT_EPOCH_CACHE.append(epoch)
    return epoch

_STALL_REQUEST_CLAIM_EVENT_PREFIX = "stall_request_claim_"


def _stall_request_claim(task_id: str, fingerprint: str, now: float) -> float | None:
    """The epoch THIS EXACT (task_id, fingerprint) conductor_prompt request
    was first ever observed by the watchdog — review H1/M1 (r6): the old
    gate compared a reply against the task's registry `updated_at`, which
    moves on every later, unrelated permission prompt (so an answered
    request re-fired the moment the worker's next approval landed) and can
    itself sit well BEFORE the request ever appeared (so an earlier,
    unrelated delivery read as having answered a request it preceded).

    Persisted ONCE via the same idempotent INSERT-OR-IGNORE `_stall_boot_
    epoch` uses, keyed on task+fingerprint, so it never moves again once
    claimed — the SAME fingerprint across ticks (the request sits unchanged
    while the worker goes on to other things) always reads back the SAME
    epoch, regardless of what `updated_at` does meanwhile. Two hub
    processes racing this agree on one epoch for the same reason
    `_stall_boot_epoch` does: whichever INSERT wins, both read it back.

    Review H1 (r7): called on the FIRST TICK the request line is actually
    visible in the pane — never gated on the idle-duration threshold, which
    used to delay the claim until long after the request appeared, so a
    reply landing in between read as predating it (review H1's own
    regression: a quickly-answered request still woke).

    Review L3: returns `None`, never a fabricated `now`, when the registry
    cannot confirm the claim was actually persisted (missing registry, a
    locked/read-only database). Falling open to `now` made every PAST reply
    look like it predated a claim minted "just now", so an already-answered
    request re-fired. The caller skips the candidate this tick and tries
    again next tick, once the registry is reachable again.
    """
    event_id = f"{_STALL_REQUEST_CLAIM_EVENT_PREFIX}{task_id}_{_sw_digest(fingerprint)}"
    if not REGISTRY.exists():
        return None
    try:
        conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
        try:
            row = conn.execute("SELECT occurred_at FROM events WHERE event_id=?",
                               (event_id,)).fetchone()
        finally:
            conn.close()
        if row and row[0]:
            epoch = _iso_epoch(row[0])
            if epoch is not None:
                return epoch
    except sqlite3.Error:
        pass
    occurred = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    try:
        conn = sqlite3.connect(str(REGISTRY), timeout=2)
        try:
            conn.execute(
                "INSERT OR IGNORE INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
                "VALUES (?, '', ?, 'stall_request_claim', ?, '{}')",
                (event_id, task_id, occurred))
            conn.commit()
            row = conn.execute("SELECT occurred_at FROM events WHERE event_id=?",
                               (event_id,)).fetchone()
        finally:
            conn.close()
        if row and row[0]:
            epoch = _iso_epoch(row[0])
            if epoch is not None:
                return epoch
    except sqlite3.Error:
        pass
    return None


_STALL_REQUEST_ANSWERED_EVENT_PREFIX = "stall_request_answered_"


def _stall_reply_matches(conn: sqlite3.Connection) -> dict[str, dict[str, float]]:
    """{task_id: {claim_digest: reply_epoch}} — which `conductor_prompt`
    claims (review H1/M1/M2/L2 r7) have a REAL reply bound to THIS EXACT
    request, never to whichever request happens to be newest when the
    reply's timestamp is read. Every genuine reply (`message_delivered` —
    `send-to-agent.sh` writes it for EVERY successful send, peer, Slack/hub
    or a direct conductor-pane reply alike, so this one query already
    covers all three) answers the OLDEST still-open claim for its task, in
    chronological order: a reply cannot answer a request that did not
    exist yet when it was sent (review H1's own `claimed_at`), and once an
    older request has first claim on a reply, a LATER, unrelated request
    for the same task can never also claim it (review L2 — a reply "about
    A" must never silence an unrelated, newer B that showed up after A's
    reply was already sent).

    Pure and stateless: claims and replies are both immutable, append-only
    registry rows, so re-running this against the same rows always
    reproduces the same pairing — an answered request stays answered
    forever on its own, with no help from a durable marker. `_stall_
    persist_answered` writes one anyway (review addendum: store it in the
    existing claim-store idiom, no schema change) purely for the hub event
    feed/observability, never as this function's own source of truth."""
    claims_by_task: dict[str, list[tuple[str, float]]] = {}
    for tid, event_id, occurred_at in conn.execute(
            "SELECT task_id, event_id, occurred_at FROM events "
            "WHERE type='stall_request_claim' ORDER BY sequence"):
        ep = _iso_epoch(occurred_at)
        if ep is None or len(event_id) < 16:
            continue
        claims_by_task.setdefault(tid, []).append((event_id[-16:], ep))
    replies_by_task: dict[str, list[float]] = {}
    for tid, occurred_at in conn.execute(
            "SELECT task_id, occurred_at FROM events "
            "WHERE type='message_delivered' AND task_id != '' ORDER BY sequence"):
        ep = _iso_epoch(occurred_at)
        if ep is not None:
            replies_by_task.setdefault(tid, []).append(ep)
    out: dict[str, dict[str, float]] = {}
    for tid, claims in claims_by_task.items():
        replies = replies_by_task.get(tid, [])
        ri = 0
        matched: dict[str, float] = {}
        for digest, claimed_epoch in claims:
            while ri < len(replies) and replies[ri] < claimed_epoch:
                ri += 1   # predates even the oldest open claim: spent, unusable
            if ri >= len(replies):
                break     # no replies left; every later (newer) claim stays open
            matched[digest] = replies[ri]
            ri += 1
        if matched:
            out[tid] = matched
    return out


def _stall_persist_answered(matches: dict[str, dict[str, float]]) -> None:
    """Best-effort durable record of each `_stall_reply_matches` pairing,
    via the SAME idempotent INSERT-OR-IGNORE idiom `_stall_request_claim`
    uses on the SAME `events` table/columns (no schema change) — review
    addendum point 4. A write failure here costs nothing but the hub
    event feed showing the pairing a tick late: `_stall_reply_matches`
    recomputes the identical answer from the same immutable claim/reply
    rows every tick regardless, so it is never this function's job to be
    the source of truth."""
    if not matches or not REGISTRY.exists():
        return
    try:
        conn = sqlite3.connect(str(REGISTRY), timeout=2)
        try:
            for tid, digests in matches.items():
                for digest, reply_epoch in digests.items():
                    event_id = f"{_STALL_REQUEST_ANSWERED_EVENT_PREFIX}{tid}_{digest}"
                    occurred = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(reply_epoch))
                    conn.execute(
                        "INSERT OR IGNORE INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
                        "VALUES (?, '', ?, 'stall_request_answered', ?, '{}')",
                        (event_id, tid, occurred))
            conn.commit()
        finally:
            conn.close()
    except sqlite3.Error:
        pass


_REASON_RE = re.compile(rb'"reason"\s*:\s*"([^"]*)"')


def _is_handoff_reason(reason: str | None) -> bool:
    """Any `handed_off_to:<target>` closure reason needs a wake — SPEC.md
    says "a handoff event to the conductor", but `register_task`'s own
    `_valid_closure_reason` accepts `handed_off_to:<task|role>` for ANY
    role (conductor, Main, review, conductor-merge, a specific pane id…).
    PR #223 review H5: requiring the exact literal `handed_off_to:conductor`
    matched 7 of 40 real closures live. Case/whitespace-tolerant because a
    worker's own closure reason is free text, not a validated enum value at
    the point this reads it (`_valid_closure_reason` only checks the bash
    side's own writes, not a worktree's local events.jsonl, see below)."""
    return bool(reason) and reason.strip().lower().startswith("handed_off_to:")


def _live_done_info(worktree: str | None) -> tuple[float | None, str | None]:
    """(epoch, reason) of the newest readable `_done` line in the worker's
    OWN handoff bus — PR #223 review H5's fix for incident 1's exact shape:
    while the pane stays alive, `lib/reconcile.sh` only ingests a
    worktree's `_done` once the pane is GONE, so the registry row can sit
    `running`/derive `ready_review` all night with no closure_reason at
    all, which is precisely what left incident 1 undetected. Same bus
    files, same byte-level never-decode discipline, and the same
    last-line-only mtime fallback as `_evidence_at` — reused rather than
    re-derived so the two readers can never disagree about which file.
    """
    if not worktree:
        return None, None
    best_epoch: float | None = None
    best_reason: str | None = None
    for rel in _bus_relpaths():
        p = Path(worktree) / rel
        try:
            if not p.stat().st_size:
                continue
            last_ts: bytes | None = None
            last_reason: str | None = None
            done_is_last = False
            with p.open("rb") as fh:
                for ln in fh:
                    if not ln.strip():
                        continue
                    if _DONE_RE.search(ln):
                        m = _TS_RE.search(ln)
                        last_ts = m.group(1) if m else None
                        rm = _REASON_RE.search(ln)
                        last_reason = rm.group(1).decode("ascii", "replace") if rm else None
                        done_is_last = True
                    else:
                        done_is_last = False
            if last_ts is None and not done_is_last:
                continue
            epoch = _iso_epoch(last_ts.decode("ascii", "replace")) if last_ts else None
            if epoch is None and done_is_last:
                epoch = p.stat().st_mtime
            if epoch is not None and (best_epoch is None or epoch > best_epoch):
                best_epoch, best_reason = epoch, last_reason
        except OSError:
            continue
    return best_epoch, best_reason

_ANSI_RE = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]')


def _pane_last_output(pane_id: str, lines: int = 60) -> str:
    """Review M1's pane-text source, called from hub.py since this signal
    lives beside the other four pure ones.

    Review H1 (r4): a hard-coded 20 silently dropped the exact request
    this signal exists to catch — in a real 46-column omp pane, a wrapped
    request plus omp's own recap block already fills the 18 usable output
    rows above the composer, so the `CONDUCTOR:` row itself scrolls out of
    a 20-row tail. 60 keeps a live pane's wrapped-request-plus-recap shape
    inside the window with room to spare.

    Review H1 (r7): gated only on the state/birth checks above, never on
    the idle-duration threshold — called every tick a task is idle with a
    live, birth-matched pane, so the claim's first-seen epoch
    (`_stall_request_claim`) is genuinely the first sighting, not the
    first sighting AFTER the threshold also happened to clear.

    Review M2 (r5): `--source visible` — the shape attention.sh's own
    `_vishash` uses — caps at the pane's LIVE SCREEN HEIGHT, never at
    `--lines`: measured 29-35 rows on every 46-column w5B pane regardless
    of whether `--lines` asked for 60 or 200, so a short/narrow real pane
    never got this signal the window the paragraph above claims. `recent`
    (the CLI's own default) returns exactly `--lines` rows of scrollback
    instead, independent of the live terminal size — measured live:
    `recent --lines 60` -> 60 rows on the same panes `visible` capped at
    35, for both `--lines 60` and `--lines 200`."""
    try:
        r = subprocess.run(["herdr", "pane", "read", pane_id, "--source", "recent", "--lines", str(lines)],
                           capture_output=True, text=True, timeout=5)
        return r.stdout or ""
    except Exception:
        return ""


_CHROME_COMPOSER_TOP_RE = re.compile(r'^\s*\u256d')   # ╭


def _agent_output_lines(text: str) -> list[str]:
    """Everything ABOVE the omp composer's own top border — review N3: the
    LAST rows of an idle omp pane are the composer's status bar and input
    box (`lib/prompt-parse.sh:355-361`'s own `_composer_input_rows`, whose
    "rows below the last `\u256d`" definition this takes the complement of),
    never agent output. Requiring the literal last captured row to start
    with `CONDUCTOR:`, as the first cut did, can never match a real omp
    pane — the box is always what is actually last. No `\u256d` in the
    window (a bare `\u276f` composer, or input tall enough to scroll its own
    border out of view) leaves nothing distinguishable as output, the same
    edge case `_composer_input_rows` documents; returns none rather than
    guessing."""
    raw = text.splitlines()
    top = None
    for i, line in enumerate(raw):
        if _CHROME_COMPOSER_TOP_RE.match(_ANSI_RE.sub("", line)):
            top = i
    return raw[:top] if top is not None else []


_MD_LEADING_RE = re.compile(r'^[\*_]+')   # **CONDUCTOR:** / __CONDUCTOR:__


def _last_conductor_prompt_line(text: str | None) -> str | None:
    """The most recent worker-authored `CONDUCTOR: ...` line in genuine
    agent OUTPUT (never the composer chrome below it — see
    `_agent_output_lines`) — incident 2's actual shape (SPEC.md:51): no
    deny, no delivery, no handoff event, just a worker asking directly.

    Review M1 (r3): the first cut required the literal LAST non-blank row
    to BE the whole line, so it went silent the moment the request wrapped
    across terminal columns (the wrap's continuation row, not
    `CONDUCTOR:...`, sat last), the moment the worker's own status/recap
    block followed it (the recap sat last instead), or the moment the
    worker bolded the marker (`**CONDUCTOR:**`, which a bare
    `.startswith()` missed). This scans every captured output row from
    the bottom instead, stripping a leading markdown emphasis run
    (`*`/`_`) before the prefix test, and joins the wrap's own
    continuation rows — rows that immediately follow with no blank row
    between them — onto the line it returns.

    Review H1 (r5): r4 added a guard here that dropped the result as soon
    as a SECOND, non-recap paragraph followed the request, trying to infer
    "the conductor already answered" from pane SHAPE alone. It could not:
    the round-1 live incident's own shape — a trailing paragraph, then
    omp's `※` recap — went silent under it, and so did six other ordinary
    UNANSWERED shapes a worker writes while still waiting (a plain
    sentence, an indented command block, an evidence list, a `**Recap**:`
    or `Status:` line — none of them an actual reply). Pane text cannot
    tell "the worker kept narrating" from "the conductor replied and the
    worker moved on"; only the registry can. `stall_watchdog_candidates`'s
    own `replied` argument does that instead, comparing a real
    `message_delivered` event's timestamp against THIS REQUEST's OWN claim
    epoch (review H1/M1/M2/L2 r7 — never the task's `updated_at`, which
    moves on every later, unrelated prompt) — so this function goes back
    to always returning the request plus its wrap continuation, with no
    shape-based answered guard."""
    if not text:
        return None
    rows = [_ANSI_RE.sub("", ln).rstrip() for ln in _agent_output_lines(text)]
    for i in range(len(rows) - 1, -1, -1):
        row = _MD_LEADING_RE.sub("", rows[i].strip())
        if not row or not row.startswith("CONDUCTOR:"):
            continue
        parts = [row]
        j = i + 1
        while j < len(rows) and rows[j].strip():
            parts.append(rows[j].strip())
            j += 1
        return " ".join(parts)
    return None


def _live_pane_birth(pane_id: str) -> str | None:
    """Review M-b's liveness check: the pane's CURRENT `terminal_id` from
    the already-maintained live subscription (`pane_statuses()`), not a
    fresh RPC — a herdr re-enumeration reissues this on every reconnect,
    the same fingerprint `derive()` itself compares against a task's
    registered `pane_birth` to call a pane `gone`."""
    statuses = pane_statuses()
    if not statuses:
        return None
    rec = statuses.get(pane_id)
    return rec.get("birth") if rec else None


def _conductor_prompt_fingerprint(line: str) -> str:
    """The stable fingerprint for a `CONDUCTOR: ...` request line — review
    L1 (r4): hashed whitespace-free, so a resize/rewrap of the identical
    request (which moves where the continuation join inserts its space)
    mints the SAME fingerprint, never a second wake. Factored out of
    `stall_watchdog_candidates` so every caller — production and tests
    alike — computes it the SAME way, never a hand-derived copy of the
    formula that could silently drift from it."""
    norm = re.sub(r"\s+", "", line)
    return f"cprompt:{hashlib.sha256(norm.encode()).hexdigest()[:16]}"


def stall_watchdog_candidates(tasks: list[dict], now: float | None = None,
                              denied: dict | None = None, delivered: dict | None = None,
                              owner_acted: dict | None = None, replied: dict | None = None,
                              stat_fn=None, live_done_fn=None, pane_read_fn=None,
                              pane_birth_fn=None, claim_fn=None,
                              threshold_s: float | None = None,
                              boot_epoch: float | None = None) -> list[dict]:
    """Which (task, signal) pairs have sat idle/done, owing the conductor an
    action, for at least `threshold_s` (HERDR_STALL_WATCHDOG_THRESHOLD_S).

    `denied`/`delivered`/`owner_acted` are precomputed {task_id: {"epoch":
    …, "fingerprint":…}} (or, for `owner_acted`, {task_id: epoch}) maps for
    facts `herdr_data()` cannot see on its own — see `_stall_task_signals`.
    `replied` is `{task_id: {claim_digest: epoch}}` (review H1/M1/M2/L2
    r7, `_stall_reply_matches`): each real reply is bound to the OLDEST
    still-open claim for its task, never to "whichever is newest" — so a
    reply that answers an older request can never also silence an
    unrelated, newer one (review L2) — unbounded (review M2 r6: no longer
    windowed to 8x the threshold — a genuinely old reply must keep
    silencing its request forever, not just for 80 minutes). `claim_fn`
    (review H1/M1 r6, r7) mints or reads back the epoch THIS EXACT
    (task_id, fingerprint) request was FIRST SEEN, called every tick a
    task is idle with a live, birth-matched pane — never gated behind the
    idle-duration threshold, which used to delay the claim until well
    after the request appeared (review H1) — so "answered" compares a
    reply against the REQUEST's own fixed, earliest-possible epoch, never
    the task's `updated_at` (which moves on every later, unrelated
    permission prompt). Returns `None` (review L3) when the registry
    cannot confirm the claim persisted; the caller skips the candidate
    rather than fabricate a `now` that reads every past reply as
    premature.
    `stat_fn`/`live_done_fn` are injectable (signal 2's artifact mtime+size,
    signal 1's live-bus read) so this stays a pure function callers can test
    with plain dicts, no filesystem or registry required — same testability
    as `project_needs_wake`. `boot_epoch` (PR #223 review H1/M-a) floors every
    signal's own evidence epoch so a deploy (or a restart mid-incident)
    never wakes on history; defaults to the persisted `_stall_boot_epoch()`.

    Five signals, each its own `fingerprint` (what the claim_once key in
    stall-watchdog.sh re-arms on when it changes). IDLE_STATES (`stalled`,
    `ready_review`) gates every one of them: review N1 — once a task is
    `completed`, the conductor closing it IS the action owed, whatever
    closed it; nothing fires again after that, for any signal.
      handoff     — the worker's OWN worktree bus says `handed_off_to:
                    <anything>` (review H5: not just the literal
                    `:conductor`) while its pane is STILL the one this task
                    registered (review N2: a registry-side `completed` +
                    `updated_at` branch used to ALSO fire on the close
                    itself — the exact timestamp of the conductor having
                    just acted — and produced a second claim key for the
                    same handoff; dropped entirely, live bus is now the
                    only source).
      artifact    — the single NEWEST (by mtime) of the three named files
                    that is non-empty and newer than the conductor's own
                    last recorded action on the task, idle past threshold
                    (review H1: an unconditional stat fired on the 0-byte
                    PROOF.md `spawn-task.sh` creates in every worktree;
                    review N1: used to also run on `completed` rows, so
                    reading the artifact and closing the task — the
                    NORMAL way a conductor handles one — still woke 10
                    minutes later and escalated 20 minutes after that).
                    Review M2 (r4): the newest file is picked BEFORE the
                    threshold check, and the threshold applies only to
                    that one pick — an older artifact that crossed the
                    threshold first never gets its own fingerprint while
                    a newer one is still too fresh to qualify, which used
                    to mint two wakes (one per file) seconds apart for a
                    single handoff.
      denied      — the worker's last approval was a DENY, then went idle.
      unprocessed — a message was delivered to this pane and nothing (no
                    later WORKER-originated event) has happened since.
      conductor_prompt — review M1: incident 2 had 8 approvals, all
                    `allow` — no deny, no delivery, no handoff; it just sat
                    idle with its own last pane output asking the
                    conductor directly (the `CONDUCTOR: ...` line this very
                    codebase's own workers write — see
                    `_last_conductor_prompt_line` for the wrap/bold
                    handling). Review M-b: verifies the live pane's birth
                    still matches the one this task registered before ever
                    reading it — `state != completed` used to include
                    `lost`/`cancelled`/`failed`/`gone`, any of which can
                    mean herdr already recycled the pane id to an
                    unrelated task. Review L1 (r4): the fingerprint hashes
                    the line with ALL whitespace stripped, so a pane
                    resize that re-wraps the same request at a different
                    column — and so re-places the space the continuation
                    join inserts — still hashes to the same key. Review H1
                    (r5): "already answered" is no longer inferred from
                    pane shape (that dropped real unanswered requests —
                    see `_last_conductor_prompt_line`); it is a real
    `message_delivered` event, never a guess. Review H1/M1
    (r6, r7): that reply is compared against THIS REQUEST'S OWN
    claim epoch (`claim_fn`, first-seen and held fixed — see
    `_stall_request_claim`), not the task's `updated_at` — r5
    compared against `updated_at` instead, which (a) sits well
    before the request on a task spawned long ago, so an
    earlier, unrelated delivery read as having answered a
    request it preceded, and (b) slides forward on every
    later, unrelated permission prompt, so an already-answered
    request re-fired the moment the worker's next approval
    landed. Review H1 (r7): r6 still minted the claim ONLY once
    the since/threshold/owner_acted gate below had already
    opened — the first GATED look, not the first time the
    request was actually visible — so a reply landing in that
    gap still read as predating the claim and woke anyway. The
    claim is now minted on the very first tick the line is
    visible, before any of that gate. Review M2 (r7): the
    since/threshold gate no longer also requires `owner_acted <
    since` — that compared the WRONG baseline (the task's own
    moving `updated_at`) to decide "already answered", so a
    brand-new re-ask (a new fingerprint, by definition never
    answered) stayed silenced until some LATER, unrelated
    approval happened to reopen it. "Answered" is `replied`'s
    own job now, bound to this fingerprint's own claim (review
    L2: and bound to the OLDEST open claim for the task, so a
    reply "about" an earlier request can never silence a later,
    unrelated one) — the gate below only decides WHEN an
    unanswered request starts waking.
    """
    now = time.time() if now is None else now
    threshold = STALL_WATCHDOG_THRESHOLD_S if threshold_s is None else threshold_s
    boot = _stall_boot_epoch() if boot_epoch is None else boot_epoch
    denied = denied or {}
    delivered = delivered or {}
    owner_acted = owner_acted or {}
    replied = replied or {}
    if stat_fn is None:
        def stat_fn(p):
            st = os.stat(p)
            return st.st_size, st.st_mtime
    if live_done_fn is None:
        live_done_fn = _live_done_info
    if pane_read_fn is None:
        pane_read_fn = _pane_last_output
    if pane_birth_fn is None:
        pane_birth_fn = _live_pane_birth
    if claim_fn is None:
        claim_fn = _stall_request_claim
    IDLE_STATES = ("stalled", "ready_review")
    out: list[dict] = []
    for t in tasks:
        tid = t.get("task_id")
        if not tid:
            continue
        state = t.get("state")
        base = {"task_id": tid, "run_id": t.get("run_id") or "",
                "label": t.get("label") or tid, "pane_id": t.get("pane_id") or "",
                "conductor_pane_id": t.get("conductor_pane_id") or "",
                "conductor_pane_birth": t.get("conductor_pane_birth") or ""}

        # ---- signal 1: handoff --------------------------------------------
        if state in IDLE_STATES and t.get("worktree"):
            live_epoch, live_reason = live_done_fn(t["worktree"])
            since = live_epoch if _is_handoff_reason(live_reason) else None
            fingerprint = f"live:{live_epoch}"
        else:
            since = None
            fingerprint = None
        if since is not None and since >= boot and now - since >= threshold:
            out.append({**base, "signal": "handoff", "fingerprint": fingerprint,
                       "detail": "closed handed_off_to:... ; the conductor was never told",
                       "artifact": ""})

        # ---- signal 2: artifact --------------------------------------------
        if state in IDLE_STATES and t.get("worktree"):
            owner_epoch = owner_acted.get(tid)
            best: tuple[str, float] | None = None   # (rel, mtime) of the newest qualifier
            for rel in STALL_SIGNAL_ARTIFACTS:
                try:
                    size, mtime = stat_fn(os.path.join(t["worktree"], rel))
                except OSError:
                    continue
                if not size or mtime is None:
                    continue                                   # empty file: nothing was WRITTEN
                if mtime < boot:
                    continue
                if owner_epoch is not None and owner_epoch >= mtime:
                    continue                                   # the conductor already acted since
                if best is None or mtime > best[1]:
                    best = (rel, mtime)
            # Review M2 (r4): the threshold applies ONLY to the single
            # newest pick, after it is chosen — never per-file. An older
            # artifact that crossed the threshold first is never its own
            # candidate while a newer one exists, so the two never mint
            # separate fingerprints seconds apart for the same handoff.
            if best is not None and now - best[1] >= threshold:
                rel, mtime = best
                out.append({**base, "signal": "artifact", "fingerprint": f"{rel}:{int(mtime)}",
                           "detail": f"{rel} has sat ready {int((now - mtime) / 60)}m with no action",
                           "artifact": rel})

        # ---- signal 3/4: denied, unprocessed --------------------------------
        if state == "stalled":
            d = denied.get(tid)
            if d and d["epoch"] >= boot and now - d["epoch"] >= threshold:
                out.append({**base, "signal": "denied", "fingerprint": d["fingerprint"],
                           "detail": "a policy-refused prompt was denied, then the worker went idle",
                           "artifact": ""})
            m = delivered.get(tid)
            if m and m["epoch"] >= boot and now - m["epoch"] >= threshold:
                out.append({**base, "signal": "unprocessed", "fingerprint": m["fingerprint"],
                           "detail": "a message was delivered to this pane and never processed",
                           "artifact": ""})

        # ---- signal 5: conductor_prompt (review H1/M1/M2/L2/L3 r7) ---------
        if state in IDLE_STATES and t.get("pane_id"):
            live_birth = pane_birth_fn(t["pane_id"])
            reg_birth = t.get("pane_birth") or ""
            # Review H1 (r7): read on EVERY tick a task is idle with a live,
            # birth-matched pane — never gated behind since/threshold/
            # owner_acted below. That gate used to decide BOTH "has this
            # sat long enough to escalate" AND "when was the claim first
            # minted", so the claim could only ever be minted on the first
            # GATED look, well after the request actually appeared — any
            # reply landing in that gap read as predating the claim and
            # woke anyway. The two concerns are now separate: the claim's
            # first-seen epoch comes from here, unconditionally; the gate
            # below only decides WHEN an unanswered request starts waking.
            line = (_last_conductor_prompt_line(pane_read_fn(t["pane_id"]))
                    if live_birth and reg_birth and live_birth == reg_birth else None)
            if line:
                fingerprint = _conductor_prompt_fingerprint(line)
                claimed_at = claim_fn(tid, fingerprint, now)
                # Review L3: a claim the registry never confirmed cannot be
                # trusted as "just now" — skip this tick, try again next.
                if claimed_at is not None:
                    # Review L2: bound to THIS fingerprint's own claim,
                    # never "whichever reply is latest for the task" — a
                    # reply chronologically owed to an OLDER, already-
                    # superseded request can never also silence this one.
                    reply_epoch = replied.get(tid, {}).get(_sw_digest(fingerprint))
                    # Review M2 (r7): no `owner_acted` check here — that
                    # compared the wrong baseline (`since`) to decide
                    # "already answered", so a brand-new re-ask (a new
                    # fingerprint, by definition never answered) stayed
                    # silenced until some later, unrelated approval
                    # happened to reopen it. `reply_epoch` above is the
                    # real answered check now; `since`/threshold below is
                    # purely timing — how long this task has sat idle.
                    since = _iso_epoch(t.get("updated_at"))
                    if ((reply_epoch is None or reply_epoch < claimed_at)
                            and since is not None and since >= boot
                            and now - since >= threshold):
                        out.append({**base, "signal": "conductor_prompt",
                                   "fingerprint": fingerprint,
                                   "detail": line[:200], "artifact": ""})
    return out


STALL_WATCHDOG_SCRIPT = Path(__file__).resolve().parent / "stall-watchdog.sh"
# Positive list of WORKER-originated activity (PR #223 review H4): the
# previous shape excluded stall-watchdog's own bookkeeping types and
# treated everything else as "the worker did something" — but
# `herdr-deliver.sh` itself appends `brief_delivered`/`reply_delivered`
# right after `send-to-agent.sh` returns, so EVERY delivery through the
# real delivery path (incident 3's own path) immediately read as its own
# resolution. A positive list cannot make that mistake: only genuine
# worker-side facts count. `state_changed` to `running` specifically
# (a worker resuming, or reconcile ingesting it) counts; a transition TO
# `completed` does not — that is the conductor/registry side closing the
# loop, not the worker doing something new.
_STALL_WORKER_ACTIVITY_TYPES = ("input_required", "completion_recorded")
# Owner-side activity (review H1/H2): anything a human/conductor did on
# this task, from the OTHER real paths (not just stall-ack.sh) that
# already existed before this feature — reused as both "the conductor
# already acted on this artifact" (H1) and "treat it the same as an ack"
# (H2, enforced in stall-watchdog.sh's own event query, not here).
_STALL_OWNER_ACTIVITY_TYPES = ("owner_acted", "brief_delivered", "reply_delivered", "approval_reviewed")
_STALL_DENY_CHOICE_RE = re.compile(r"\b(deny|no|reject)\b", re.IGNORECASE)


def _stall_task_signals(now: float | None = None, threshold_s: float | None = None) -> tuple[dict, dict, dict, dict]:
    """The four supplemental facts `herdr_data()` does not carry, from one
    registry connection: the latest DENIED approval per task, the latest
    `message_delivered` event per task with no later WORKER event, the
    latest owner-side action epoch per task (PR #223 review H1/M-a's "newer
    than the conductor's last action"), and — review H1 r5's `replied`,
    the one registry fact that proves a human/conductor replied to a
    `conductor_prompt` signal, since pane SHAPE cannot — which claim
    digest of which task was actually answered and when (review H1/M1/M2/
    L2 r7, `_stall_reply_matches`): each reply is bound to the OLDEST
    still-open claim for its task, never "whichever is latest", unbounded
    (review M2 r6 dropped the former 8x-threshold window, which let a
    genuinely old reply expire and the already-answered request re-fire).

    `denied` (review M2): a policy refusal is `approval_escalated`
    (`herdr-select.sh`'s `_refuse_non_human`, fired only when the policy
    itself refused), not an `approvals` row with `policy_verdict='deny'` —
    a HUMAN pressing Approve on a deny-classified prompt writes that same
    verdict, and the old query could not tell the two apart. A human's own
    declining CHOICE (`choice_text` deny/no/reject, independent of what
    the policy classified) is the other real source for the same signal.
    Either way, "then the worker went idle" (SPEC.md) is enforced here,
    the same positive-activity check as `delivered` below, not left to the
    caller's `state == "stalled"` gate alone.

    Review M-c(2): each loop below previously scanned EVERY matching row
    ever written, paying one extra `_no_worker_activity_since` query per
    unresolved one (N+1). A task still worth waking about is, by
    definition, within a few multiples of the escalate window of now —
    `occurred_at >= cutoff` bounds every scan there; anything older either
    already escalated or will never qualify, and does not need rescanning
    every tick forever.
    """
    denied: dict = {}
    delivered: dict = {}
    owner_acted: dict = {}
    replied: dict = {}
    now = time.time() if now is None else now
    threshold = STALL_WATCHDOG_THRESHOLD_S if threshold_s is None else threshold_s
    cutoff = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - threshold * 8))
    if not REGISTRY.exists():
        return denied, delivered, owner_acted, replied
    try:
        conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
    except sqlite3.Error:
        return denied, delivered, owner_acted, replied
    try:
        act_placeholders = ",".join("?" for _ in _STALL_WORKER_ACTIVITY_TYPES)

        def _no_worker_activity_since(tid: str, seq: int) -> bool:
            later = conn.execute(
                f"SELECT count(*) FROM events WHERE task_id=? AND sequence>? AND "
                f"(type IN ({act_placeholders}) OR "
                "(type='state_changed' AND json_extract(payload,'$.state')='running'))",
                (tid, seq, *_STALL_WORKER_ACTIVITY_TYPES)).fetchone()[0]
            return later == 0

        for tid, seq, occurred_at in conn.execute(
                "SELECT task_id, sequence, occurred_at FROM events "
                "WHERE type='approval_escalated' AND task_id != '' AND occurred_at >= ? ORDER BY sequence DESC",
                (cutoff,)):
            if tid in denied or not _no_worker_activity_since(tid, seq):
                continue
            ep = _iso_epoch(occurred_at)
            if ep is not None:
                denied[tid] = {"epoch": ep, "fingerprint": f"esc{seq}"}
        for tid, decided_at, approval_id, choice_text in conn.execute(
                "SELECT task_id, decided_at, approval_id, choice_text FROM approvals "
                "WHERE task_id != '' AND decided_at >= ? ORDER BY decided_at DESC",
                (cutoff,)):
            if tid in denied or not _STALL_DENY_CHOICE_RE.search(choice_text or ""):
                continue
            seq_row = conn.execute(
                "SELECT MAX(sequence) FROM events WHERE task_id=? AND occurred_at<=?",
                (tid, decided_at)).fetchone()
            seq = seq_row[0] if seq_row and seq_row[0] is not None else 0
            if not _no_worker_activity_since(tid, seq):
                continue
            ep = _iso_epoch(decided_at)
            if ep is not None:
                denied[tid] = {"epoch": ep, "fingerprint": approval_id}
        for tid, seq, occurred_at in conn.execute(
                "SELECT task_id, sequence, occurred_at FROM events "
                "WHERE type='message_delivered' AND task_id != '' AND occurred_at >= ? ORDER BY sequence DESC",
                (cutoff,)):
            if tid in delivered or not _no_worker_activity_since(tid, seq):
                continue
            ep = _iso_epoch(occurred_at)
            if ep is not None:
                delivered[tid] = {"epoch": ep, "fingerprint": str(seq)}
        own_placeholders = ",".join("?" for _ in _STALL_OWNER_ACTIVITY_TYPES)
        for tid, occurred_at in conn.execute(
                f"SELECT task_id, MAX(occurred_at) FROM events WHERE task_id != '' "
                f"AND type IN ({own_placeholders}) GROUP BY task_id",
                _STALL_OWNER_ACTIVITY_TYPES):
            ep = _iso_epoch(occurred_at)
            if ep is not None:
                owner_acted[tid] = ep
        # Review H1 (r5): a `conductor_prompt` signal is answered the
        # instant the conductor sends anything back, whether or not the
        # worker goes on to process it (that is `delivered`'s own,
        # separate concern) — so, unlike `delivered`, no "no later worker
        # activity" filter. Review M2 (r6): UNBOUNDED, no `cutoff` here —
        # the comparison is against the REQUEST's own claim epoch, which
        # can be arbitrarily old; windowing this query to "recent" rows
        # made a genuinely old, valid reply expire and the already-
        # answered request re-fire. Review H1/M1/M2/L2 (r7): bound to the
        # SPECIFIC claim it answers, never "the task's latest reply" —
        # see `_stall_reply_matches`.
        replied = _stall_reply_matches(conn)
    finally:
        conn.close()
    # Review addendum point 4: persist the pairing durably (best-effort,
    # same claim-store idiom, no schema change) — purely for the hub
    # event feed; `_stall_reply_matches` is already its own stable source
    # of truth, recomputed from the same immutable rows every tick.
    _stall_persist_answered(replied)
    return denied, delivered, owner_acted, replied


# Mirrors ATTENTION_STATE's shape (review M4: "failures are invisible... the
# loop swallows every exception with no state") — exposed on /api/summary
# alongside it so a dead/erroring thread reads as one rather than a silent
# "0 tasks need attention" forever.
STALL_WATCHDOG_STATE: dict = {"ticks": 0, "last_ok": None, "last_error": None,
                              "last_candidates": 0, "last_dispatched": 0}


def _sw_digest(text: str) -> str:
    """Python mirror of stall-watchdog.sh's `_sw_digest` (shasum -a 256 |
    cut -c1-16) — needed to reconstruct the SAME claim_once key the bash
    side computes, so the Python filter below and the bash dedupe can
    never disagree about which fingerprint a key names."""
    return hashlib.sha256((text or "").encode()).hexdigest()[:16]


def _sw_resolved_keys(conn: sqlite3.Connection, owner_acted: dict | None = None) -> set[str]:
    """claim_once keys that are ALREADY woken AND acked (review M4): the
    daemon must not spawn a subprocess plus two herdr RPCs every tick,
    forever, for a fingerprint stall-watchdog.sh would itself immediately
    recognize as handled. Filtering here is pure cost control — bash still
    owns the actual ack/escalate decision; a key this misses just costs one
    extra (cheap, no-op) dispatch, never a missed wake.

    Review M-c(1): an escalated or owner-unowned key is TERMINAL — bash's
    own `claim_once` on `${key}_escalate`/`${key}_unowned` already
    guarantees it never fires again, but paid `_sw_owner_status`'s 2 herdr
    RPCs to discover that every tick anyway, forever. An owner-acted task
    is the same waste for H2's own reason. All three are filtered here the
    same way the ack case always was."""
    owner_acted = owner_acted or {}
    claims: dict[str, tuple[str, str, str]] = {}
    for eid, tid, occurred_at, payload in conn.execute(
            "SELECT event_id, task_id, occurred_at, payload FROM events WHERE type='stall_wake'"):
        try:
            sig = json.loads(payload or "{}").get("signal", "")
        except json.JSONDecodeError:
            sig = ""
        claims[eid] = (tid, sig, occurred_at)
    acks: dict[str, list[tuple[str, str]]] = {}
    for tid, payload, occurred_at in conn.execute(
            "SELECT task_id, payload, occurred_at FROM events WHERE type='stall_acked'"):
        try:
            sig = json.loads(payload or "{}").get("signal", "all")
        except json.JSONDecodeError:
            sig = "all"
        acks.setdefault(tid, []).append((sig, occurred_at))
    resolved: set[str] = set()
    for eid, (tid, sig, claimed_at) in claims.items():
        for ack_sig, acked_at in acks.get(tid, []):
            if ack_sig in (sig, "all") and acked_at > claimed_at:
                resolved.add(eid)
                break
        if eid in resolved:
            continue
        owner_epoch = owner_acted.get(tid)
        if owner_epoch is not None:
            claimed_epoch = _iso_epoch(claimed_at)
            if claimed_epoch is not None and owner_epoch >= claimed_epoch:
                resolved.add(eid)
    for (eid,) in conn.execute("SELECT event_id FROM events WHERE type='stall_escalate_claim'"):
        if eid.endswith("_escalate"):
            resolved.add(eid[: -len("_escalate")])
    for (eid,) in conn.execute("SELECT event_id FROM events WHERE type='stall_wake_unowned'"):
        if eid.endswith("_unowned"):
            resolved.add(eid[: -len("_unowned")])
    return resolved


def _stall_watchdog_tick() -> None:
    """One pass: compute the candidates against the SAME cached herdr_data()
    every other read uses, then hand each UNRESOLVED one to stall-watchdog.sh,
    which owns dedupe/delivery/escalation. Never raises."""
    if not STALL_WATCHDOG_SCRIPT.exists():
        return
    h = CACHES["herdr"].get()
    if not h or h.get("error"):
        return
    now = time.time()
    denied, delivered, owner_acted, replied = _stall_task_signals(now=now)
    candidates = stall_watchdog_candidates(h.get("tasks") or [], now=now, denied=denied,
                                           delivered=delivered, owner_acted=owner_acted, replied=replied)
    resolved: set[str] = set()
    if REGISTRY.exists():
        try:
            conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
            try:
                resolved = _sw_resolved_keys(conn, owner_acted=owner_acted)
            finally:
                conn.close()
        except sqlite3.Error:
            resolved = set()
    dispatched = 0
    for c in candidates:
        key = f"stall_{c['task_id']}_{c['signal']}_{_sw_digest(c['fingerprint'])}"
        if key in resolved:
            continue
        dispatched += 1
        try:
            subprocess.run(["bash", str(STALL_WATCHDOG_SCRIPT), "wake", c["task_id"], c["signal"],
                            c["fingerprint"], c["detail"], c.get("artifact") or ""],
                           capture_output=True, timeout=25)
        except (OSError, subprocess.SubprocessError) as exc:
            STALL_WATCHDOG_STATE["last_error"] = f"{c['task_id']}/{c['signal']}: {exc}"
            _live_log(f"stall watchdog wake failed for {c['task_id']}/{c['signal']}: {exc}")
    STALL_WATCHDOG_STATE["ticks"] += 1
    STALL_WATCHDOG_STATE["last_ok"] = time.time()
    STALL_WATCHDOG_STATE["last_candidates"] = len(candidates)
    STALL_WATCHDOG_STATE["last_dispatched"] = dispatched


def _stall_watchdog_loop() -> None:
    while True:
        try:
            _stall_watchdog_tick()
        except Exception as e:  # noqa: BLE001 — belt and braces: the loop must not die
            STALL_WATCHDOG_STATE["last_error"] = f"{type(e).__name__}: {e}"
            _live_log(f"stall watchdog loop error: {type(e).__name__}: {e}")
        time.sleep(ATTENTION_INTERVAL_S)


def page(title: str, path: str, body: str, refresh: int = 15, scope: str = "", json_extra: str = "") -> str:
    """refresh=0 disables the meta-refresh; the caller supplies its own poller.

    `scope` is carried into the meta-refresh URL and the json link. Without it
    a scoped page silently reset to the whole fleet on its own 15s refresh —
    a filter that undoes itself while you read is worse than no filter.
    `json_extra` is appended to the json link only (e.g. /timeline's window)."""
    nav = " ".join(f"<a href='{p}' class='{'on' if p == path else ''}'>{n}</a>" for p, n in NAV)
    q = f"?repo={urllib.parse.quote(scope)}" if scope else ""
    meta = (f"<meta http-equiv=refresh content='{refresh};url={path}{q}'>" if refresh else "")
    label = f"refresh {refresh}s" if refresh else "reloads only on change"
    return (f"<!doctype html><html lang=en><head><meta charset=utf-8>{meta}"
            f"<title>{_esc(title)}</title><style>{STYLE}</style></head><body>"
            f"<header><b>hub</b>{nav}<span class=dim style='margin-left:auto'>{label} · "
            f"<a href='{path}?json=1{('&repo=' + urllib.parse.quote(scope)) if scope else ''}{_esc(json_extra)}'>json</a>"
            f"</span></header><main>{body}</main></body></html>")


# Terrence, 2026-09-05: "the form kept refreshing before I could make full
# decisions." A meta-refresh page tears down the embedded form iframe every
# tick, losing whatever was half-answered. So /decisions never auto-refreshes;
# it polls /api/summary and reloads only when the OPEN FORM SET changes (one
# served, one answered) - the two moments a reload is worth losing nothing for.
DECISIONS_POLLER = """<script>
(function(){var key=%s;setInterval(function(){fetch('/api/summary').then(function(r){return r.json()})
.then(function(s){if(s.open_ids!==key)location.reload()}).catch(function(){})},5000)})();
</script>"""


def task_rows(rows) -> str:
    out = []
    for t in rows:
        repo = (t["repo"] or "").rsplit("/", 1)[-1]
        # Derived from ATTENTION, not a second hardcoded tuple. `stalled` was
        # added to ATTENTION as "the state a person most needs to see" and then
        # rendered unhighlighted in the very table it was added for, because the
        # class list was the same concept written twice.
        cls = "hot" if t["state"] in ATTENTION else ("run" if t["state"] == "running" else "")
        # A derived state that disagrees with the stored copy is itself evidence
        # that something never transitioned — the patch computed `state_stale`
        # and then showed it nowhere.
        stale = ""
        if t.get("state_stale") and t.get("stored_state"):
            stale = f" <small class=dim title='registry still says this'>was {_esc(t['stored_state'])}</small>"
        elif t.get("state_source") == "stored":
            # The case `state_stale` is blind to: the derivation FELL BACK, so
            # it returned the stored state and the two agree. Without this the
            # row is indistinguishable from a live-confirmed one — "blocked
            # because herdr says so" and "blocked because herdr went quiet" are
            # different facts about whether anyone is actually waiting.
            stale = " <small class=dim title='herdr has no live status for this pane; this is the registry copy'>unconfirmed</small>"
        # The whole point of item 1's gate: a `completed` row NAMES why. One
        # not carrying a reason is a completion the gate never actually saw
        # (pre-gate data, or a direct DB edit) — said plainly, not hidden.
        closure = ""
        if t["state"] == "completed":
            reason = t.get("closure_reason")
            closure = (f" <small class=dim title='closure reason'>{_esc(reason)}</small>" if reason
                       else " <small class=dim title='no closure reason on record'>no reason recorded</small>")
        out.append(f"<tr class='{cls}'><td><span class='pill {cls}'>{_esc(t['state'])}</span>{stale}{closure}</td>"
                   f"<td><b>{_esc(t['label'])}</b><br><small>{_esc(repo)} · pane {_esc(t['pane_id'] or '—')} · "
                   f"{_esc(t['conductor_id'] or 'no conductor')}</small></td>"
                   f"<td class=age title='{_esc(t['updated_at'])}'>{_age(t['updated_at'])}</td></tr>")
    return "".join(out) or "<tr><td class=dim>none</td></tr>"


def debt_rows(d: dict) -> str:
    """One row per unpaid session: which repo, when, what it did, what it owes.

    The counts are the point. "3 write(s), 4 git/gh mutation(s), SHIPPED" is
    the difference between a handoff worth reconstructing and one worth
    skipping, and it is the only thing left of that session once its cwd
    notepad has scrolled past."""
    out = []
    for r in d.get("debt", []):
        pills = ["<span class='pill hot'>shipped</span>"] if r["shipped"] else []
        if r["lesson_debt"]:
            pills.append(" <span class='pill hot' title='the session shipped and called neither retain nor learn'>no lesson</span>")
        did = f"{r['writes']} write(s) · {r['mutations']} git/gh mutation(s)"
        where = r["session_cwd"] or "an unrecorded cwd"
        out.append(f"<tr class=hot><td>{''.join(pills) or '<span class=pill>owed</span>'}</td>"
                   f"<td><b>{_esc(r['repo'].rsplit('/', 1)[-1])}</b><br>"
                   f"<small>{_esc(did)} · that session was working in {_esc(where)}</small></td>"
                   f"<td class=age title='{_esc(r['at'] or 'no timestamp recorded')}'>{_esc(_age(r['at']))}</td></tr>")
    if d.get("error"):
        out.append(f"<tr><td><span class='pill bad'>unreadable</span></td>"
                   f"<td class=dim>handoff-debt ledger could not be read: {_esc(d['error'])}</td>"
                   f"<td class=age>—</td></tr>")
    if d.get("unreadable"):
        # Shown, never counted: an unparseable line may be a half-written
        # append, and a surface that turned one into a phantom debt would be
        # asking for work nobody can identify. Silence would be worse still —
        # "no debt" for a corrupt ledger is the one answer that misleads.
        out.append(f"<tr><td><span class='pill bad'>{d['unreadable']}</span></td>"
                   f"<td class=dim>unreadable ledger line(s), not counted as debt — "
                   f"{_esc(str(HANDOFF_DEBT))}</td><td class=age>—</td></tr>")
    return "".join(out) or "<tr><td class=dim>none — every repo a session changed has a handoff</td></tr>"


def deploy_drift_rows(dd: dict) -> str:
    """One row per repo: how far behind, and both shas — the detail behind
    the overview card, which only has room for a short label."""
    out = []
    for r in dd.get("repos", []):
        if r.get("error"):
            out.append(f"<tr><td><span class='pill bad'>unavailable</span></td>"
                       f"<td>{_esc(r['repo'])}</td><td class=dim>{_esc(r['error'])}</td></tr>")
            continue
        if r.get("fetch_ok") is False:
            out.append(f"<tr class=hot><td><span class='pill hot'>unverified</span></td>"
                       f"<td><b>{_esc(r['repo'])}</b></td>"
                       f"<td class=dim>git fetch failed — {_esc(r['deployed'])} vs last-known "
                       f"{_esc(r['main'])}</td></tr>")
            continue
        m = r.get("behind_minutes") or 0
        hot = m > 30
        pill = (f"<span class='pill hot'>{_minutes_label(m)} behind</span>" if hot
               else f"<span class=pill>{_minutes_label(m)} behind</span>" if m
               else "<span class=pill>in sync</span>")
        out.append(f"<tr{' class=hot' if hot else ''}><td>{pill}</td>"
                   f"<td><b>{_esc(r['repo'])}</b></td>"
                   f"<td class=dim>{_esc(r['deployed'])} → {_esc(r['main'])}</td></tr>")
    return "".join(out) or "<tr><td class=dim>no repos configured</td></tr>"


def render_overview(scope: str = "") -> str:
    h_all, f, s, k, l, lo, dbt, pd, dd, cst = (CACHES[n].get() for n in ("herdr", "forms", "search", "kb", "links", "loops", "debt", "portal", "deploy_drift", "cost"))
    # Handoff debt (#102) is per-REPO in its own right, so it narrows with the
    # scope like everything else on this page; the ledger rows carry a repo.
    h = scoped(h_all, scope)
    if scope:
        dbt = dict(dbt, debt=[r for r in (dbt.get("debt") or [])
                              if _repo_matches(r.get("repo"), scope)])
    bad_loops = [x for x in lo.get("loops", []) if x["stale"] or x["outcome"] not in ("ok", "success", "healthy")]
    att = len(h.get("attention", []))
    hb = (k or {}).get("heartbeat") or {}
    runs = (k or {}).get("runs") or []
    last = runs[0] if runs else {}
    ledger_error = k.get("error") or k.get("ledger_error") or ("nightly reader unavailable" if "runs" not in k else None)
    heartbeat_error = k.get("error") or k.get("heartbeat_error") or ("heartbeat reader unavailable" if "heartbeat" not in k else None)
    required = [x for x in l.get("surfaces", []) if x["name"] not in OPTIONAL]
    alive = sum(1 for x in required if x["alive"])
    # Counted in REPOS, not rows: the unit of work is "go stand in that repo
    # and write its handoff", which pays every row it holds at once. A count
    # of rows would say 3 for one afternoon's forgetfulness in one place.
    debt_repos = dbt.get("repos", [])
    # Deploy drift (see deploy_drift_data): the hub ran 3417af0 for hours
    # while origin/main had fixes ahead of it, and nobody saw it until
    # someone was debugging something else. Unscoped like `open_decisions`
    # below — a repo's deploy state is a machine-wide fact, not this repo's.
    dd_repos = dd.get("repos", [])
    dd_bad = [r for r in dd_repos if r.get("error")]
    # A failed fetch is its OWN bucket, never counted as in sync: we could
    # not verify it either way. See _repo_drift's fetch_ok.
    dd_unverified = [r for r in dd_repos if not r.get("error") and r.get("fetch_ok") is False]
    dd_drifted = [r for r in dd_repos if not r.get("error") and r.get("fetch_ok") is not False
                 and (r.get("behind_minutes") or 0) > 0]
    dd_in_sync = len(dd_repos) - len(dd_bad) - len(dd_unverified) - len(dd_drifted)
    cards = [
        ("/herdr", att, "need attention", f"{len(h.get('tasks', []))} tasks · events to #{h.get('max_event_seq', 0)}", att > 0),
        ("/decisions", f.get("open_count", 0) + pd.get("open_count", 0), "decisions open",
         f"{f.get('open_count', 0)} form(s) · {pd.get('open_count', 0)} stray legacy-portal row(s)"
         + (" (portal UNREADABLE)" if pd.get("error") else ""),
         f.get("open_count", 0) + pd.get("open_count", 0) > 0 or bool(pd.get("error"))),
        ("#handoff-debt", len(debt_repos), "repo(s) owe a handoff",
         (f"{len(dbt.get('debt', []))} session(s)"
          + (f" · {dbt['shipped']} shipped" if dbt.get("shipped") else "")
          + (f" · {dbt['lesson_debt']} with no lesson" if dbt.get("lesson_debt") else ""))
         if debt_repos else (dbt.get("error") or "no unpaid handoffs"),
         bool(debt_repos) or bool(dbt.get("unreadable")) or bool(dbt.get("error"))),
        ("/links", f"{alive}/{len(required)}", "surfaces alive", "probed from this Mac; dev servers not counted", alive < len(required)),
        ("/kb", "unavailable" if ledger_error else _esc(_nightly_status(last)), "last KB nightly",
         ledger_error or (f"{_age(last.get('started_at'))} ago · {last.get('total_steps') or '?'} steps" if last else "no runs"),
         bool(ledger_error) or last.get("status") == "failed"),
        ("/kb", "unavailable" if heartbeat_error else f"{hb.get('healthy_count', '—')}/{hb.get('total_count', '—')}",
         "fleet healthy (KB heartbeat)", heartbeat_error or (f"snapshot {_age(hb.get('generated_at'))} ago" if hb else "no snapshot"),
         bool(heartbeat_error) or bool(hb.get("divergent"))),
        ("/loops", f"{len(lo.get('loops', [])) - len(bad_loops)}/{len(lo.get('loops', []))}", "loops healthy", f"{len(lo.get('suggestions', []))} suggestion(s)" + (" · " + ", ".join(x["name"].split(" — ")[0] for x in bad_loops) if bad_loops else ""), bool(bad_loops)),
        ("/search", (s.get("totals") or {}).get("searches", "—"), "searches remembered", f"{(s.get('totals') or {}).get('replays', 0)} served from memory" if s.get("totals") else (s.get("error") or ""), False),
        ("#deploy-drift", f"{dd_in_sync}/{len(dd_repos)}", "in sync (deploy drift)",
         "; ".join(_drift_label(r) for r in dd_repos) if dd_repos else "no repos configured",
         bool(dd_bad) or bool(dd_unverified) or any((r.get("behind_minutes") or 0) > 30 for r in dd_drifted)),
        # Machine-wide like deploy drift: spend is not narrowed by scope.
        ("#cost", f"${cst['total_cost']:,.0f}" if cst.get("present") else "—", "LLM spend (7 days)",
         cst.get("error") or ("; ".join(cst.get("alerts") or [])
                              or (f"{(cst['total_cost'] - cst['prev_total_cost']) / cst['prev_total_cost'] * 100:+.0f}% vs prior week"
                                  if cst.get("present") and cst.get("prev_total_cost") else
                                  ("no prior-week data" if cst.get("present") else "cost-report.py has not run"))),
         bool(cst.get("error")) or bool(cst.get("alerts"))),
    ]
    body = scope_chips(h_all, "/", scope) + "<div class=cards>" + "".join(
        f"<a class='card {'hot' if hot else ''}' href='{href}'><div class=t>{t}</div><div class=n>{n}</div><div class=s>{_esc(sub)}</div></a>"
        for href, n, t, sub, hot in cards) + "</div>"
    body += "<h2>Needs attention</h2><table>" + task_rows(h.get("attention", [])) + "</table>"
    # Always rendered, so the card's anchor always resolves and "nothing owed"
    # is an answer the page gives rather than a section that silently vanished.
    body += "<h2 id=handoff-debt>Unpaid handoff debt</h2><table>" + debt_rows(dbt) + "</table>"
    body += "<h2 id=deploy-drift>Deploy drift</h2><table>" + deploy_drift_rows(dd) + "</table>"
    body += "<h2 id=cost>LLM spend</h2><table>" + cost_rows(cst) + "</table>"
    if f.get("open"):
        body += "<h2>Open decisions</h2><table>" + "".join(
            f"<tr class=hot><td><span class='pill hot'>open</span></td><td><a href='/decisions'>{_esc(x.get('title') or x['id'])}</a>"
            f"<br><small>{_esc(x['url'])}</small></td><td class=age>{_age(x.get('created_at'))}</td></tr>" for x in f["open"]) + "</table>"
    return page("hub", "/", body, scope=scope)


def _live_rows(scope: str = "") -> str:
    """herdr's own agent_status per pane, and where the registry disagrees.

    Divergence is SHOWN, never silently resolved: `registry blocked / herdr
    working` is a stale writer, `registry running / herdr blocked` is a worker
    waiting on a human nobody told. Both were real incidents; a dashboard that
    picks one source and hides the other cannot be checked.

    Under a repo scope, a pane is narrowed through the TASK that owns it — a
    pane carries no repo of its own. Panes with no task in this repo (including
    hand-started ones with no task at all) are counted and named as hidden,
    never dropped in silence: the first render of this page under a scope
    showed a scoped task list above an unscoped pane list, which reads as
    "these panes belong to this repo" and is exactly the kind of quiet wrong
    answer this dashboard exists to avoid."""
    live = live_data()
    stats = live.get("stats") or {}
    if not live.get("connected"):
        return ("<p class=dim>herdr subscription down — every row below would be stale, so none is shown. "
                f"last error: {_esc(stats.get('last_error') or 'unknown')}</p>")
    tasks = {t.get("pane_id"): t for t in (CACHES["herdr"].get() or {}).get("tasks", [])}
    agents = live.get("agents", [])
    hidden = 0
    if scope:
        mine = {t.get("pane_id") for t in (CACHES["herdr"].get() or {}).get("tasks", [])
                if t.get("pane_id") and _repo_matches(t.get("repo"), scope)}
        kept = [p for p in agents if p.get("pane_id") in mine]
        hidden = len(agents) - len(kept)
        agents = kept
    rows = []
    for p in agents:
        task = tasks.get(p["pane_id"]) or {}
        reg = task.get("state")
        blocked = p["agent_status"] == herdr_live.BLOCKED
        diverges = bool(reg) and ((reg == "blocked") != blocked) and reg not in ("completed", "failed", "cancelled", "lost")
        rows.append(
            f"<tr{' class=hot' if blocked else ''}><td>{_esc(p['pane_id'])}</td>"
            f"<td>{_esc(task.get('label') or p.get('label') or '')}</td>"
            f"<td><span class='pill{' hot' if blocked else ''}'>{_esc(p['agent_status'])}</span></td>"
            f"<td class=dim>{_esc(reg or '—')}{' <span class=\"pill hot\">diverges</span>' if diverges else ''}</td>"
            f"<td class=dim>{_esc(p.get('agent') or '')} · {_esc(p.get('workspace') or '')}</td>"
            f"<td class=age>{_age(dt.datetime.fromtimestamp(p['since'], dt.timezone.utc).isoformat()) if p.get('since') else ''}</td></tr>")
    head = ("<tr><td class=dim>pane</td><td class=dim>task</td><td class=dim>herdr says</td>"
            "<td class=dim>registry says</td><td class=dim>agent · workspace</td><td class=dim>in state</td></tr>")
    scope_note = (f" · <b>{hidden}</b> pane(s) hidden by this scope "
                  f"(<a href='/herdr'>all</a>)" if scope and hidden else "")
    meta = (f"<p class=dim>pushed by subscription · {stats.get('events', 0)} events, "
            f"{stats.get('reconnects', 0)} reconnects, {stats.get('resyncs', 0)} resyncs, "
            f"{stats.get('edges', 0)} edges" + (f", {stats['edges_dropped']} DROPPED" if stats.get("edges_dropped") else "") + scope_note + "</p>")
    return meta + "<table>" + head + ("".join(rows) or "<tr><td class=dim>no agent panes</td></tr>") + "</table>"


def _events_window_note(d_all: dict, d: dict, scope: str) -> str:
    """Say when a scoped event list is empty for a MECHANICAL reason.

    The registry query takes the newest N events FLEET-WIDE and scoping
    filters that window afterwards, so a busy repo whose last activity is
    older than the window shows zero events. Measured on live data: scoping
    to knowledge-base gave 24 tasks and 0 events. An empty table that means
    "outside the window" and an empty table that means "nothing happened"
    must not look the same — the first is a rendering artefact, the second is
    a fact about the fleet.
    """
    if not scope or d.get("events") or not d.get("tasks"):
        return ""
    total = len(d_all.get("events") or [])
    return (f"<div class=dim style='margin:-4px 0 8px'>none in the last {total} events, "
            f"which are read fleet-wide before this scope is applied — not "
            f"necessarily no activity in this repo. "
            f"<a href='/herdr'>see all</a></div>")


def render_herdr(scope: str = "") -> str:
    d_all = CACHES["herdr"].get()
    d = scoped(d_all, scope)
    if d.get("error"):
        return page("herdr", "/herdr", f"<pre>{_esc(d['error'])}</pre>")
    ev = []
    for e in d["events"]:
        p = e["payload"]
        detail = " ".join(str(p[k]) for k in ("reason", "outcome", "detail") if p.get(k))
        if p.get("prompt_id"):
            detail += f" prompt={p['prompt_id'][:12]}…"
        ev.append(f"<tr><td class=dim>#{e['sequence']}</td><td><span class=pill>{_esc(e['type'])}</span></td>"
                  f"<td>{_esc(e['label'])}</td><td class=dim>{_esc(detail)}</td><td class=age title='{_esc(e['occurred_at'])}'>{_age(e['occurred_at'])}</td></tr>")
    cp = "".join(f"<tr><td>{_esc(c['conductor_id'])}</td><td>{c['last_event_seq']} / {d['max_event_seq']}"
                 f"{' <span class=pill>behind</span>' if c['last_event_seq'] < d['max_event_seq'] else ''}</td>"
                 f"<td class=age>{_age(c['updated_at'])}</td></tr>" for c in d["checkpoints"])
    others = [t for t in d["tasks"] if t["state"] not in ATTENTION][:40]
    lo = CACHES["loops"].get()
    strip = " ".join(
        f"<a class='card {'hot' if (x['stale'] or x['outcome'] not in ('ok', 'success', 'healthy')) else ''}' href='/loops' style='padding:10px 12px'>"
        f"<div class=t>{_esc(x['name'].split(' — ')[0])}</div><div style='font-weight:600'>{'STALE · ' if x['stale'] else ''}{_esc(x['outcome'])}</div>"
        f"<div class=s>{_loop_age(x)} · {_esc(x['cadence'])}</div></a>" for x in lo.get("loops", []))
    sug = "".join(f"<li>{_esc(t['text'])}</li>" for t in lo.get("suggestions", [])[:5])
    live_blocked = live_attention()
    body = (scope_chips(d_all, "/herdr", scope)
            + f"<h2>Live fleet — herdr's own agent status</h2>{_live_rows(scope)}"
            f"<h2>Loops <a href='/loops' class=dim style='font-weight:400'>· all, with suggestions →</a></h2><div class=cards>{strip}</div>"
            + (f"<h2>Suggestions</h2><ul class=dim style='margin:0 0 6px;padding-left:18px'>{sug}</ul>" if sug else "")
            + f"<h2>Needs attention (live: {len(live_blocked)} · registry: {len(d['attention'])})</h2>"
            f"<table>{task_rows(d['attention'])}</table>"
            + f"<h2>Recent events (newest first)</h2>{_events_window_note(d_all, d, scope)}"
            f"<table>{''.join(ev) or '<tr><td class=dim>none</td></tr>'}</table>"
            f"<h2>Conductor cursors</h2><table>{cp or '<tr><td class=dim>none</td></tr>'}</table>"
            f"<h2>Other tasks (latest 40)</h2><table>{task_rows(others)}</table>")
    return page("herdr", "/herdr", body, scope=scope)


def render_decisions() -> str:
    d = CACHES["forms"].get()
    # Terrence, 2026-09-06: "open decisions should expand most of the page,
    # history defaults collapsed." The open form is the only thing on this page
    # that needs acting on, so it gets the viewport; the answered/expired log is
    # reference material behind a <details>.
    body = ""
    ms = MIRROR_STATE
    stale = ms.get("last_ok") and time.time() - ms["last_ok"] > 3 * MIRROR_EVERY_S
    if ms.get("last_error") or stale:
        why = ms.get("last_error") or f"no successful sync for {_age(ms['last_ok'] * 1000)}"
        body += (f"<p class=dim><span class='pill bad'>dashboard mirror</span> {_esc(why)} — "
                 "answer here; dashboard.teamthurber.com/decisions is not current.</p>")
    elif ms.get("last_ok"):
        body += (f"<p class=dim><span class='pill ok'>dashboard mirror</span> synced {_age(ms['last_ok'] * 1000)} ago · "
                 f"{ms.get('published', 0)} published · also answerable at "
                 f"<a href='{KB_DASHBOARD_URL}/decisions' target=_blank>dashboard.teamthurber.com/decisions</a></p>")
    if ms.get("rejected"):
        body += (f"<p><span class='pill bad'>rejected</span> {ms['rejected']} dashboard answer(s) failed "
                 f"verification and were NOT delivered — last: {_esc(ms.get('last_rejection'))}</p>")
    gave_up = RATINGS_RECONCILE_STATE.get("gave_up") or {}
    if gave_up:
        items = "".join(
            f"<li>{_esc(run_id)}: {info['attempts']} attempt(s), gave up {_age(info['gave_up_at'])} ago — "
            f"{_esc(info.get('error', ''))}</li>"
            for run_id, info in sorted(gave_up.items()))
        body += (f"<p><span class='pill bad'>ratings dispatch</span> {len(gave_up)} run(s) gave up after "
                 f"{RATINGS_DISPATCH_MAX_ATTEMPTS} failed attempts — these ratings never reached "
                 f"kb.section_ratings and need a manual resend:</p><ul>{items}</ul>")
    p = CACHES["portal"].get()
    if p.get("error"):
        body += (f"<h2>Legacy portal · unreadable</h2><p><span class='pill bad'>error</span> {_esc(p['error'])}</p>")
    elif p["open"]:
        body += (f"<h2>Legacy portal · {p['open_count']} stray</h2><p class=dim>Another session filed these in the retired "
                 "tourguide portal. You do not answer there: an agent should supersede each and re-ask it here as a form.</p><table>"
                 + "".join(
                     f"<tr class=hot><td><span class='pill hot'>{_esc(x.get('gate'))}</span></td>"
                     f"<td><b>{_esc(x.get('question'))}</b>"
                     + (f"<br><small>recommended: {_esc(x.get('recommendation'))}</small>" if x.get("recommendation") else "")
                     + f"<br><small>{_esc(x.get('decision_id'))} · {_esc(x.get('assignee'))}</small></td>"
                     f"<td class=age>{_age(x.get('created_at'))}</td></tr>" for x in p["open"])
                 + "</table>")
    if not d["open"]:
        body += ("<h2>Forms · 0 open</h2><p class=dim>No served form is waiting. "
                 "Forms appear here the moment an agent serves one.</p>")
    for f in d["open"]:
        # Prefer the hub's own durable URL: it keeps working after the creating
        # process exits, which the form's own port does not.
        src = f.get("hub_url") or f["url"]
        body += (f"<p class=dhead><b>{_esc(f.get('title') or f['id'])}</b> <span class=dim>· served {_age(f.get('created_at'))} ago · "
                 f"expires {_age(f.get('expires_at'))} · <a href='{_esc(src)}' target=_blank>open in its own tab</a>"
                 + ("" if f.get("hub_servable") else " · <span class=pill>own port only</span>")
                 + "</span></p>"
                 f"<iframe class=dframe src='{_esc(src)}' title='{_esc(f.get('title') or f['id'])}'></iframe>")
    rows = "".join(
        f"<tr><td><span class='pill {'ok' if f['status'] == 'answered' else 'bad'}'>{_esc(f['status'])}</span></td>"
        f"<td><b>{_esc(f.get('title') or f['id'])}</b><br><small>{_esc(f.get('form_path', ''))}</small>"
        + (f"<pre>{_esc(json.dumps(f.get('answers'), indent=1, sort_keys=True))}</pre>" if f.get("answers") else "")
        + f"</td><td class=age>{_age(f.get('answered_at') or f.get('created_at'))}</td></tr>" for f in d["history"])
    body += (f"<details class=hist><summary>History · {len(d['history'])} answered/expired</summary>"
             f"<table>{rows or '<tr><td class=dim>none yet</td></tr>'}</table></details>")
    key = ",".join(sorted(f["id"] for f in d["open"]))
    return page(f"decisions · {d['open_count'] + p.get('open_count', 0)} open", "/decisions",
                body + DECISIONS_POLLER % json.dumps(key), refresh=0)


def render_search() -> str:
    d = CACHES["search"].get()
    if d.get("error"):
        return page("search", "/search", f"<pre>{_esc(d['error'])}</pre>", refresh=60)
    t = d["totals"]
    body = ("<form action='" + SEARCH_URL + "/' method=get target=_blank style='margin:0 0 14px'>"
            "<input name=q placeholder='Ask consensus·search…' style='width:70%;padding:10px 14px;border-radius:10px;border:1px solid #272c37;background:#171a21;color:#e6e9ef;font-size:15px'>"
            " <button style='padding:10px 18px;border-radius:10px;border:1px solid #e08a4a;background:#e08a4a;font-weight:600'>Search</button></form>"
            "<div class=cards>" + "".join(
                f"<div class=card><div class=t>{k}</div><div class=n>{v}</div></div>"
                for k, v in (("searches", t["searches"]), ("served from memory", t["replays"]), ("data-kind", t["data_kind"]), ("partial (a leg errored)", t["partial"]))) + "</div>")
    rows = "".join(f"<tr><td><a href='{_esc(r['url'])}' target=_blank>{_esc(r['q'])}</a><br><small>{_esc(r['scope'] or '')}</small></td>"
                   f"<td><span class=pill>{_esc(r['kind'] or '?')}</span></td><td class=dim>{r['hits']}× · {r['total_s']}s</td>"
                   f"<td class=age>{_age(r['ts'])}</td></tr>" for r in d["recent"])
    body += f"<h2>Latest searches</h2><table>{rows or '<tr><td class=dim>none</td></tr>'}</table>"
    return page("search memory", "/search", body, refresh=120)


def _render_signal_quality(d: dict) -> str:
    loop = _signal_quality_loop(d)
    body = ("<h2>Signal quality — repeat-view unit</h2>"
            "<p class=dim>Same-input before/after eligibility and ranking invariants. "
            "This does not verify all sales signals or authorize outreach.</p>")
    link = _signal_quality_link()
    if link:
        body += f"<p><a href='{_esc(link)}' target=_blank rel=noopener>Inspect audit details in authenticated KB</a></p>"
    if not loop["observed"]:
        return body + "<p class='pill bad'>unavailable</p><p class=dim>Audit history is unknown. Check reader access and the KB module/migration.</p>"
    runs = d["signal_quality_runs"]
    if not runs:
        return body + "<p class=dim>No recorded audit runs (reader succeeded).</p>"
    last = runs[0]
    summary = last["summary"]
    status = last["status"]
    explanation = {
        "ok": "Audit executed successfully; covered checks passed.",
        "degraded": "Audit executed; covered quality checks need attention.",
        "failed": "Audit failed; quality has not been established.",
        "running": "Audit is running; final quality is not yet known.",
    }[status]
    body += (f"<p><span class='pill {'bad' if loop['stale'] else ('ok' if status == 'ok' else ('run' if status == 'running' else 'bad'))}'>"
             f"{'STALE · ' if loop['stale'] else ''}{_esc(status)}</span> {_esc(explanation)}<br>"
             f"<small>Rule {_esc(last['rule_version'])} · started {_esc(last['started_at'])} · "
             f"finished {_esc(last['finished_at'] or 'not yet')} · revision {_esc(last['source_revision'] or 'unknown')}</small></p>")
    cards = (
        ("Eligible before → after", f"{summary.get('before_count', '—')} → {summary.get('after_count', '—')}"),
        ("Repeat-view before → after", f"{summary.get('repeat_before_count', '—')} → {summary.get('repeat_after_count', '—')}"),
        ("Changed", summary.get("changed_count", "—")),
        ("Withheld stale / unknown date", f"{summary.get('withheld_stale_count', '—')} / {summary.get('withheld_unknown_date_count', '—')}"),
        ("Violations", summary.get("violation_count", "—")),
        ("Window days / people", f"{summary.get('window_days', '—')} / {summary.get('person_count', '—')}"),
    )
    body += "<div class=cards>" + "".join(
        f"<div class=card><div class=t>{_esc(title)}</div><div class=n>{_esc(value)}</div></div>"
        for title, value in cards) + "</div>"
    rows = []
    for run in runs[:10]:
        counts = run["summary"]
        rows.append(
            f"<tr><td><span class='pill {'ok' if run['status'] == 'ok' else ('run' if run['status'] == 'running' else 'bad')}'>{_esc(run['status'])}</span></td>"
            f"<td>{_esc(run['started_at'])}<br><small>finished {_esc(run['finished_at'] or 'not yet')} · {_esc(run['rule_version'])}</small></td>"
            f"<td>eligible {_esc(counts.get('before_count', '—'))} → {_esc(counts.get('after_count', '—'))}<br>"
            f"<small>repeat {_esc(counts.get('repeat_before_count', '—'))} → {_esc(counts.get('repeat_after_count', '—'))} · "
            f"changed {_esc(counts.get('changed_count', '—'))} · violations {_esc(counts.get('violation_count', '—'))}</small></td></tr>")
    return body + "<h3>Latest 10 audit runs</h3><table>" + "".join(rows) + "</table>"


def render_kb() -> str:
    d = CACHES["kb"].get()
    body = _render_signal_quality(d)
    if d.get("error"):
        return page("kb", "/kb", body + f"<h2>KB reader unavailable</h2><pre>{_esc(d['error'])}</pre>", refresh=120)
    hb = d.get("heartbeat") or {}
    if hb:
        systems = hb.get("systems") or {}
        rows = "".join(
            f"<tr><td><span class='pill {'ok' if v.get('status') == 'healthy' else ('' if v.get('status') == 'unknown' else 'bad')}'>{_esc(v.get('status'))}</span></td>"
            f"<td><b>{_esc(k)}</b><br><small>{_esc(v.get('code'))}</small></td></tr>"
            for k, v in systems.items() if isinstance(v, dict))
        dropped = hb.get("unrecognized_count") or 0
        body += (f"<h2>Fleet heartbeat — {_esc(hb.get('healthy_count'))}/{_esc(hb.get('total_count'))} healthy, "
                 f"{_esc(hb.get('checked_count'))} checked, snapshot {_age(hb.get('generated_at'))} ago"
                 f"{' · DIVERGENT' if hb.get('divergent') else ''}</h2>"
                 + (f"<p class=dim>{dropped} snapshot entr{'y' if dropped == 1 else 'ies'} withheld: not a KB checker.</p>" if dropped else "")
                 + f"<table>{rows}</table>")
    elif d.get("heartbeat_error"):
        body += f"<h2>Fleet heartbeat</h2><p class='pill bad'>unavailable</p><p class=dim>{_esc(d['heartbeat_error'])}</p>"
    else:
        body += "<h2>Fleet heartbeat</h2><p class=dim>No snapshot yet.</p>"
    runs = d.get("runs") or []
    if runs:
        rows = "".join(f"<tr><td><span class='pill {'ok' if _nightly_status(r) in ('ok', 'success', 'completed') else ('run' if _nightly_status(r) == 'running' else 'bad')}'>{_esc(_nightly_status(r))}</span></td>"
                       f"<td>{_esc(r['weekday'])} · {_esc(r['host'])} · <small>{_esc((r.get('git_sha') or '')[:7])}</small></td>"
                       f"<td class=dim>{r.get('total_steps') or '?'} steps</td><td class=age title='{_esc(r['started_at'])}'>{_age(r['started_at'])}</td></tr>" for r in runs)
        body += f"<h2>Nightly runs</h2><table>{rows}</table>"
        steps = "".join(f"<tr><td><span class='pill {'ok' if s['status'] in ('ok', 'success') else ('bad' if s['status'] in ('failed', 'error') else '')}'>{_esc(s['status'])}</span></td>"
                        f"<td>{_esc(s['step_label'])}<br><small>{_esc((s.get('error_class') or '')[:160])}</small></td><td class=dim>×{s.get('attempts') or 1} · {s.get('duration_s') or 0}s</td></tr>"
                        for s in d.get("steps") or [])
        body += f"<h2>Steps of the latest run</h2><table>{steps or '<tr><td class=dim>none</td></tr>'}</table>"
    elif d.get("ledger_error"):
        body += f"<h2>Nightly ledger</h2><pre>{_esc(d['ledger_error'])}</pre>"
    else:
        body += "<h2>Nightly ledger</h2><p class=dim>No recorded nightly runs.</p>"
    return page("knowledge-base", "/kb", body or "<p class=dim>nothing to show</p>", refresh=300)


def render_links() -> str:
    d = CACHES["links"].get()
    systems = ((CACHES["kb"].get() or {}).get("heartbeat") or {}).get("systems") or {}
    rows = ""
    for s in d.get("surfaces", []):
        verdict = systems.get(s["hb"]) if s["hb"] else None
        v = (f"<span class='pill {'ok' if verdict.get('status') == 'healthy' else ('' if verdict.get('status') == 'unknown' else 'bad')}'>"
             f"KB heartbeat {_esc(s['hb'])}: {_esc(verdict.get('status'))}</span>") if isinstance(verdict, dict) else ""
        rows += (f"<tr><td><span class='dot {'ok' if s['alive'] else ''}'></span>{_esc(s['name'])}</td>"
                 f"<td><a href='{_esc(s['url'])}' target=_blank>{_esc(s['url'])}</a></td>"
                 f"<td class=dim>{s['code'] or ''} {str(s['ms']) + 'ms' if s['ms'] is not None else ''} {_esc(s['detail'])}</td><td>{v}</td></tr>")
    return page("links", "/links", f"<h2>Surfaces</h2><table>{rows}</table>", refresh=60)


# ---- SLO header (project-contract-plan.md §2, "symptom SLOs, not per-event
# pings"): time-to-unblock percentiles and wake delivery rate, both derived
# from timestamps the registry already carries — no new table.
def slo_data() -> dict:
    empty = {"p50": None, "p90": None, "p99": None, "samples": 0,
             "wake_total": 0, "wake_submitted": 0, "wake_rate_pct": None}
    if not REGISTRY.exists():
        return empty
    try:
        conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
        conn.row_factory = sqlite3.Row
        try:
            # time-to-unblock: for every task_id, pair each state_changed-into-
            # 'blocked' event with the NEXT state_changed event for that same
            # task_id — the gap between them is one unblock latency sample.
            rows = conn.execute(
                "SELECT task_id, sequence, occurred_at, "
                "json_extract(payload,'$.state') AS state "
                "FROM events WHERE type='state_changed' ORDER BY task_id, sequence").fetchall()
            durations: list = []
            pending: dict = {}
            for r in rows:
                tid = r["task_id"]
                if r["state"] == "blocked":
                    pending[tid] = r["occurred_at"]
                elif tid in pending:
                    start = _iso_epoch(pending.pop(tid))
                    end = _iso_epoch(r["occurred_at"])
                    if start is not None and end is not None and end >= start:
                        durations.append(end - start)
            wake_rows = conn.execute(
                "SELECT json_extract(payload,'$.outcome') AS outcome FROM events "
                "WHERE type IN ('wake_result','attention_escalation_result','project_wake_result')").fetchall()
            wake_total = len(wake_rows)
            wake_submitted = sum(1 for r in wake_rows if r["outcome"] == "submitted")
        finally:
            conn.close()
    except sqlite3.Error:
        return empty
    if not durations:
        return {**empty, "wake_total": wake_total, "wake_submitted": wake_submitted,
                "wake_rate_pct": round(100 * wake_submitted / wake_total, 1) if wake_total else None}
    durations.sort()

    def pct(p: float) -> int:
        idx = min(len(durations) - 1, int(p * len(durations)))
        return int(durations[idx])
    return {"p50": pct(0.50), "p90": pct(0.90), "p99": pct(0.99), "samples": len(durations),
            "wake_total": wake_total, "wake_submitted": wake_submitted,
            "wake_rate_pct": round(100 * wake_submitted / wake_total, 1) if wake_total else None}


def _project_task_row(t: dict) -> str:
    cls = "hot" if t["state"] in ATTENTION else ("ok" if t["state"] == "completed" else "")
    extra = ""
    if t.get("blocked_minutes") is not None:
        extra = f" — blocked {t['blocked_minutes']}m"
        if t.get("blocked_on"):
            extra += f" on <code>{_esc(t['blocked_on'][:80])}</code>"
    claim = t.get("claim")
    claim_note = f" · claimed by {_esc(claim['pane_id'])}" if claim else ""
    return (f"<tr><td><span class='pill {cls}'>{_esc(t['state'])}</span></td>"
            f"<td>{_esc(t.get('label') or t['task_id'])}</td>"
            f"<td class=dim>{_esc(t.get('pane_id'))}{claim_note}</td>"
            f"<td class=dim>{_esc(t.get('branch'))}{extra}</td>"
            f"<td class=age>{_age(t.get('updated_at'))}</td></tr>")


def _project_card(p: dict) -> str:
    tasks_html = "".join(_project_task_row(t) for t in p["tasks"]) or "<tr><td class=dim colspan=5>no tasks</td></tr>"
    prs_html = "".join(
        f"<span class='pill {'hot' if pr.get('state') == 'OPEN' else ''}'>"
        f"<a href='{_esc(pr.get('url'))}' target=_blank>#{pr.get('number')}</a> {_esc(pr.get('state'))}"
        f"{' draft' if pr.get('isDraft') else ''}</span> "
        for pr in p["prs"]) or "<span class=dim>none</span>"
    dec_html = "".join(
        f"<span class='pill hot'>{_esc(d.get('title') or d.get('id'))}</span> " for d in p["open_decisions"]
    ) or "<span class=dim>none</span>"
    checklist_html = "".join(
        f"<li class='{'done' if it['done'] else ''}'>{'☑' if it['done'] else '☐'} {_esc(it['text'])}</li>"
        for it in p["spec_items"]) or "<li class=dim>no `- [ ]` checklist in this project's SPEC.md</li>"
    next_step = p.get("next_step")
    next_html = (f"<p><b>next:</b> {_esc(next_step)}</p>" if next_step
                 else "<p class=dim><b>next:</b> nothing outstanding</p>")
    wake_note = (" <span class='pill hot'>needs Terrence — no live worker, nothing open</span>"
                if p.get("needs_wake") else "")
    return (f"<div class=card style='margin-bottom:18px'>"
            f"<h2>{_esc(p['project'])}{wake_note}</h2>"
            f"<p class=dim>{_esc(p.get('repo'))}</p>"
            f"{next_html}"
            f"<table>{tasks_html}</table>"
            f"<p><b>PRs:</b> {prs_html}</p>"
            f"<p><b>open decisions:</b> {dec_html}</p>"
            f"<details><summary>SPEC.md acceptance</summary><ul>{checklist_html}</ul></details>"
            f"</div>")


def render_projects() -> str:
    d = CACHES["projects"].get()
    if d.get("error"):
        return page("projects", "/projects", f"<pre>{_esc(d['error'])}</pre>")
    slo = slo_data()
    slo_html = (f"<p class=dim>time-to-unblock p50 {slo['p50']}s · p90 {slo['p90']}s · p99 {slo['p99']}s · "
                f"wake delivery {slo['wake_rate_pct']}% ({slo['wake_submitted']}/{slo['wake_total']})</p>"
                if slo.get("samples") else "<p class=dim>no time-to-unblock samples yet</p>")
    body = slo_html + "".join(_project_card(p) for p in d.get("projects") or [])
    return page("projects", "/projects", body or "<p class=dim>no projects registered yet</p>", refresh=15)


# ---- TIMELINE: thurber-os docs/research/2026-09-27-epiq-review.md §B1 -------
# "What moved while I was away" — a read-only, time-windowed replay of the
# registry's own `events` table. Every other reader here answers "what IS
# happening"; this answers "what HAPPENED, in this window", without reading
# a conductor transcript.
#
# Hard rule from B1's risk section: show ONLY registry event rows, never a
# derived or conductor-claimed status — the incident this guards against is
# contract-plan §1 "done is a claim" (conductor w19:p7, 2026-09-23) landing
# again through a NEW surface. So `timeline_data` never calls `derive()` and
# never reads `tasks.state`; the only per-task fields it joins in are
# identity (label, repo, project, branch) — facts, not status. A `state`
# shown here is always an event's OWN payload, never a task's current state.
#
# `scope` reuses `_repo_matches`/`scope_of` verbatim — the same matcher
# `/herdr?repo=` and `/projects` use — rather than a second filter.
TIMELINE_ROW_CAP = 500
# The row cap bounds what is RENDERED; this bounds what is READ. There is no
# index on occurred_at, and every row in the window is json-decoded before the
# cap, so an unbounded `since=1970-…` would pull the whole table (30k+ rows,
# 2026-09-28) into Python on every hit. ~3.1k events/day -> ~96k at 31 days.
TIMELINE_MAX_DAYS = 31


def _timeline_window(query: str) -> tuple[str, str, str]:
    """(since, until, note) — canonical `...Z` bounds. Absent, unparseable or
    inverted bounds become the last 24h; a span over TIMELINE_MAX_DAYS keeps
    `until` and pulls `since` in. `note` says which happened ("" = as asked):
    always a REAL window the caller labels, never a live total (B1)."""
    q = urllib.parse.parse_qs(query)
    now = dt.datetime.now(dt.timezone.utc)
    default_since = (now - dt.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
    default_until = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    since = (q.get("since") or [""])[0].strip() or default_since
    until = (q.get("until") or [""])[0].strip() or default_until
    se, ue = _iso_epoch(since), _iso_epoch(until)
    if se is None or ue is None or se >= ue:
        return default_since, default_until, "window bounds unset or invalid \u2014 showing the default (last 24h)."
    note = ""
    if ue - se > TIMELINE_MAX_DAYS * 86400:
        se = ue - TIMELINE_MAX_DAYS * 86400
        note = f"window longer than {TIMELINE_MAX_DAYS} days \u2014 showing the last {TIMELINE_MAX_DAYS} days before until."
    # Re-emit canonically: strptime accepts `2026-9-7T1:2:3Z`, but the query
    # compares occurred_at as TEXT, and "2026-9-…" sorts after every
    # "2026-09-…" — an unpadded bound would silently select the wrong rows.
    fmt = lambda e: dt.datetime.fromtimestamp(e, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return fmt(se), fmt(ue), note


def timeline_data(since: str, until: str, scope: str = "", limit: int | None = None) -> dict:
    """Registry `events` rows in `[since, until)` — since inclusive, until
    exclusive, the half-open convention every other windowed query here
    uses, so a boundary event is never lost between two adjacent windows.

    Reuses the exact query shape `herdr_data`/`slo_data` already run against
    this same `events` table, read-only — no new store, daemon, dependency.
    The row cap bounds a single busy window (not the whole table); a capped
    window says so rather than silently truncating. Scope is applied BEFORE
    the cap, so "latest N of M" counts that project's events, and a scoped
    view never loses its older rows to other projects' traffic (~3.1k
    events/day, 2026-09-28 — a Python pass over one window is cheap).
    """
    limit = TIMELINE_ROW_CAP if limit is None else limit
    empty = {"events": [], "since": since, "until": until, "scope": scope,
             "capped": False, "total_in_window": 0}
    if not REGISTRY.exists():
        return {**empty, "error": f"registry not found: {REGISTRY}"}
    conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
    conn.row_factory = sqlite3.Row
    try:
        # Same defensive column check as herdr_data(): a registry a bash
        # writer hasn't migrated yet must degrade, never 500 the page.
        cols = {r[0] for r in conn.execute("SELECT name FROM pragma_table_info('tasks')")}
        branch_col = "branch" if "branch" in cols else "'' AS branch"
        project_col = "project" if "project" in cols else "'' AS project"
        tasks = {r["task_id"]: dict(r) for r in conn.execute(
            f"SELECT task_id, label, repo, {branch_col}, {project_col} FROM tasks")}
        rows = conn.execute(
            "SELECT sequence, type, task_id, occurred_at, payload FROM events "
            "WHERE occurred_at >= ? AND occurred_at < ? ORDER BY sequence DESC",
            (since, until)).fetchall()
    finally:
        conn.close()
    events = []
    for r in rows:
        t = tasks.get(r["task_id"]) or {}
        repo = t.get("repo") or ""
        if scope and not _repo_matches(repo, scope):
            continue
        e = dict(r)
        try:
            e["payload"] = json.loads(e["payload"] or "{}")
        except json.JSONDecodeError:
            e["payload"] = {"_raw": e["payload"]}
        if not isinstance(e["payload"], dict):
            e["payload"] = {"_raw": e["payload"]}
        e["label"] = t.get("label") or e["task_id"]
        e["repo"] = repo
        e["project"] = t.get("project") or ""
        e["branch"] = t.get("branch") or ""
        events.append(e)
    total = len(events)
    capped = total > limit
    events = events[:limit]
    # Linked PR, per distinct (repo, branch) actually shown — one cached
    # `gh` lookup per repo (`_open_prs_for_repo`), never per event. Only
    # number+url: the rest of that dict (state, mergeable, checks) is LIVE
    # status, and stamping it onto a timestamped row is the "live presented
    # as frozen" risk B1 names. It is an OPEN PR now, and is labeled so.
    prs: dict = {}
    for e in events:
        key = (e["repo"], e["branch"])
        if e["repo"] and e["branch"] and key not in prs:
            pr = _open_prs_for_repo(e["repo"]).get(e["branch"])
            prs[key] = {"number": pr.get("number"), "url": pr.get("url")} if pr else None
    for e in events:
        e["pr"] = prs.get((e["repo"], e["branch"]))
    scope_known = not scope or any(_repo_matches(t.get("repo"), scope) for t in tasks.values())
    return {"events": events, "since": since, "until": until, "scope": scope,
            "scope_known": scope_known, "capped": capped, "total_in_window": total}


def _timeline_from_query(query: str) -> dict:
    since, until, note = _timeline_window(query)
    d = timeline_data(since, until, scope_of(query))
    d["note"] = note
    return d


def _timeline_row(e: dict) -> str:
    """One row: event type, the few payload fields that matter (state
    from→to, reason/outcome/detail, prompt id), linked PR if the registry
    has one. Every worker-influenced value goes through `_esc`."""
    p = e["payload"]
    bits = []
    if p.get("state") or p.get("from"):
        bits.append(f"{_esc(p.get('from') or '?')}\u2192{_esc(p.get('state') or '?')}")
    for k in ("reason", "outcome", "detail"):
        if p.get(k):
            bits.append(_esc(str(p[k])))
    if p.get("prompt_id"):
        bits.append(f"prompt={_esc(str(p['prompt_id'])[:12])}\u2026")
    pr = e.get("pr")
    pr_html = (f" <a href='{_esc(pr.get('url'))}' title='open PR on this branch now'>open PR #{_esc(pr.get('number'))}</a>"
               if pr else "")
    return (f"<tr><td class=dim>#{e['sequence']}</td>"
            f"<td class=age title='{_esc(e['occurred_at'])}'>{_esc(e['occurred_at'])}</td>"
            f"<td><span class=pill>{_esc(e['type'])}</span></td>"
            f"<td>{_esc(e['label'])}</td><td class=dim>{_esc(e['repo'])}</td>"
            f"<td class=dim>{' '.join(bits)}{pr_html}</td></tr>")


def render_timeline(query: str = "") -> str:
    d = _timeline_from_query(query)
    since, until, scope = d["since"], d["until"], d["scope"]
    if d.get("error"):
        return page("timeline", "/timeline", f"<pre>{_esc(d['error'])}</pre>")
    empty = ("unknown repo scope \u2014 no task in the registry matches it" if not d.get("scope_known", True)
             else "none in this window")
    rows = "".join(_timeline_row(e) for e in d["events"]) or \
        f"<tr><td class=dim colspan=6>{_esc(empty)}</td></tr>"
    notes = ""
    if d.get("note"):
        notes += f"<div class=dim style='margin:-4px 0 8px'>{_esc(d['note'])}</div>"
    if d["capped"]:
        notes += (f"<div class=dim style='margin:-4px 0 8px'>showing the latest {len(d['events'])} of "
                  f"{d['total_in_window']} events in this window \u2014 narrow it to see the rest.</div>")
    form = (f"<form method=get action=/timeline class=dim style='margin-bottom:10px'>"
            f"since <input type=text name=since value='{_esc(since)}' size=20> "
            f"until <input type=text name=until value='{_esc(until)}' size=20> "
            f"<input type=hidden name=repo value='{_esc(scope)}'> "
            f"<button type=submit>apply</button></form>")
    body = (scope_chips(CACHES["herdr"].get(), "/timeline", scope)
            + form
            + f"<h2>Timeline \u2014 {_esc(since)} \u2192 {_esc(until)}</h2>"
            + notes
            + "<table><tr><th>#</th><th>when</th><th>event</th><th>task</th><th>repo</th><th>detail</th></tr>"
            + rows + "</table>")
    window_q = "&since=" + urllib.parse.quote(since) + "&until=" + urllib.parse.quote(until)
    return page("timeline", "/timeline", body, refresh=0, scope=scope, json_extra=window_q)



# ── HTTP ───────────────────────────────────────────────────────────────────────
def _suggestion_row(s: dict) -> str:
    dec = s.get("decision") or {}
    st = dec.get("state")
    if st == "deciding":
        action = "<a class='pill run' href='/decisions'>deciding…</a>"
    elif st == "accept":
        action = f"<span class='pill ok' title='{_esc(dec.get('notes'))}'>accepted · awaiting conductor dispatch</span>"
    elif st == "hold":
        action = f"<span class='pill' title='{_esc(dec.get('notes'))}'>on hold</span>"
    else:
        action = (f"<form method=post action=/loops/decide style='margin:0'><input type=hidden name=key value='{_esc(s['key'])}'>"
                  f"<button class=decide>Decide</button></form>")
    tags = f" <small>{' · '.join(s.get('tags', []))}</small>" if s.get("tags") else ""
    return (f"<tr><td><span class='pill {'hot' if s['kind'] != 'finding' else ''}'>{_esc(s['kind'])}</span></td>"
            f"<td{' class=dim' if st == 'hold' else ''}>{_esc(s['text'])}{tags}</td><td class=age>{action}</td></tr>")


def render_loops() -> str:
    d = CACHES["loops"].get()
    rows = ""
    for lp in d["loops"]:
        cls = "bad" if lp["stale"] else ("run" if lp["outcome"] == "running" else ("ok" if lp["outcome"] in ("ok", "success", "healthy") else "bad"))
        name = f"<a href='{_esc(lp['link'])}'>{_esc(lp['name'])}</a>" if lp.get("link") and not str(lp["link"]).startswith("file://") else _esc(lp["name"])
        rows += (f"<tr><td><span class='pill {cls}'>{'STALE · ' if lp['stale'] else ''}{_esc(lp['outcome'])}</span></td>"
                 f"<td><b>{name}</b><br><small>{_esc(lp['cadence'])} · {_esc(lp['detail'])}</small></td>"
                 f"<td class=age title='{_esc(lp['last'])}'>{_loop_age(lp)}</td></tr>")
    sug = "".join(_suggestion_row(s) for s in d["suggestions"] if not (s.get("decision") or {}).get("state") == "dismissed")
    if d.get("dismissed"):
        sug += f"<tr><td></td><td class=dim>{d['dismissed']} dismissed (come back when their dismissal expires)</td><td></td></tr>"
    gates = "".join(f"<tr><td><span class=pill>{_esc(g['status'])}</span></td><td><b>{_esc(g['id'])}</b> <span class=dim>{_esc(g['title'])}</span></td></tr>" for g in d["gates"])
    findings = "".join(f"<tr><td class=dim>{_esc(f['id'])}</td><td>{_esc(f['title'])}</td><td><small>{' · '.join(f['tags'])}</small></td></tr>" for f in d["findings"])
    body = (f"<h2>Loops</h2><table>{rows}</table>"
            f"<h2>Suggestions ({len(d['suggestions'])}) — proposal-only</h2><table>{sug or '<tr><td class=dim>nothing to suggest</td></tr>'}</table>"
            f"<h2>Evolution-loop gates (docs/gate-registry.yaml — Terrence signs, nobody stamps)</h2><table>{gates or '<tr><td class=dim>none</td></tr>'}</table>"
            f"<h2>Latest Stage-2 findings</h2><table>{findings or '<tr><td class=dim>none</td></tr>'}</table>")
    return page("loops", "/loops", body, refresh=60)


# The pages whose content is per-repo. `/decisions`, `/kb`, `/links`, `/loops`
# and `/search` are fleet-wide by nature — a decision carries no repo, and a
# surface probe is about this Mac — so they are NOT scoped rather than being
# given a filter that silently does nothing.
SCOPED_PAGES = ("/", "/herdr")
PAGES = {"/": (render_overview, None), "/herdr": (render_herdr, "herdr"), "/decisions": (render_decisions, "forms"),
         "/loops": (render_loops, "loops"), "/search": (render_search, "search"), "/kb": (render_kb, "kb"),
         "/links": (render_links, "links"), "/projects": (render_projects, "projects")}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/healthz":
            return self._send(200, "text/plain", b"ok")
        if path == "/api/summary":
            h_all, f, pd = CACHES["herdr"].get(), CACHES["forms"].get(), CACHES["portal"].get()
            # Scoped counts, because this endpoint is what the omp extension,
            # agent-edge.sh and the decisions poller read — an unscoped number
            # beside a scoped page is how a reader learns to distrust both.
            scope = scope_of(query)
            h = scoped(h_all, scope)
            # Attention is the UNION of what herdr says RIGHT NOW and what the
            # registry recorded, deduped by pane. Counting only the registry is
            # how a live-blocked worker stayed invisible for hours; counting
            # only herdr would lose a task whose pane died while blocked.
            live = live_attention()
            if scope:
                # A live row is a PANE, which carries no repo — it is scoped
                # through the task that owns the pane. A pane with no task in
                # this repo is not this repo's problem, and a pane with no task
                # at all belongs to the fleet view, not here.
                mine = {t.get("pane_id") for t in h.get("tasks", []) if t.get("pane_id")}
                live = [x for x in live if x.get("pane_id") in mine]
            panes = {x["pane_id"] for x in live}
            registry = [t for t in h.get("attention", []) if t.get("pane_id") not in panes]
            # How much of that count rests on a FALLBACK rather than a live
            # answer. `/herdr` marks those rows `unconfirmed`, but a consumer
            # of this endpoint (the omp extension, agent-edge.sh, a future
            # automation) saw only a number and could not tell the difference
            # — and with herdr reporting `unknown` for 12 of 14 panes, the
            # fallback is the NORMAL case, not a rare degradation. A count
            # whose provenance is invisible is how a control gets trusted
            # further than it has earned.
            unconfirmed = sum(1 for t in registry if t.get("state_source") == "stored")
            # Handoff debt is a human's job, so it is IN `attention` — that
            # field is the one number a consumer checks for "does anything
            # want me". But the repo's own history says a count whose noun is
            # wrong stops being read ("5 tasks need attention" for five
            # finished workers, 2026-09-18, ATTENTION's comment above), and
            # debt rows are not tasks. So the split is PUBLISHED rather than
            # left to a subtraction: `attention_tasks` is the pane/registry
            # half, `handoff_debt` the repo half, and the banner names each.
            debt = CACHES["debt"].get()
            debt_repos = len(debt.get("repos", []))
            # peek(), never get(): this endpoint's consumers (the omp
            # extension, agent-edge.sh) allow 2-5s, and a cold/post-idle
            # get() used to fetch INLINE under the cache's lock — see
            # _repo_drift. A cache the priming loop hasn't filled yet
            # reports "not yet checked" instead of blocking to find out.
            dd = CACHES["deploy_drift"].peek()
            attention_tasks = len(live) + len(registry)
            return self._send(200, "application/json", json.dumps(
                {"attention": attention_tasks + debt_repos,
                 "attention_tasks": attention_tasks, "live_blocked": len(live),
                 "registry_attention": len(h.get("attention", [])),
                 "attention_unconfirmed": unconfirmed,
                 "handoff_debt": debt_repos,
                 "handoff_debt_rows": len(debt.get("debt", [])),
                 "handoff_debt_unreadable": debt.get("unreadable", 0),
                 "rev": RUNNING_REV,
                 "deploy_drift": dd.get("repos", []) if dd is not None else [],
                 "deploy_drift_checked": dd is not None,
                 "live_connected": live_data().get("connected", False),
                 "attention_controller": ATTENTION_STATE,
                 "stall_watchdog": STALL_WATCHDOG_STATE,
                 "open_decisions": f.get("open_count", 0),
                 # The portal's open rows, separately: open_ids/open_decisions
                 # stay form-only because /decisions reloads on that id set.
                 "open_portal_decisions": pd.get("open_count", 0),
                 "portal_error": pd.get("error"),
                 # NOT scoped, and said so rather than implied: a served
                 # decision carries no repo, so filtering it would be a guess.
                 # A consumer that scopes its attention count and silently
                 # inherits a fleet-wide decision count would report a repo as
                 # needing a decision it has nothing to do with.
                 "decisions_scoped": False,
                 "scope": scope,
                 "scope_known": h.get("scope_known", True) if scope else True,
                 "open_ids": ",".join(sorted(x["id"] for x in f.get("open", [])))}).encode())
        if path == "/api/projects":
            return self._send(200, "application/json", json.dumps(CACHES["projects"].get(), default=str).encode())
        if path == "/api/panes":
            return self._send(200, "application/json", json.dumps(live_data(), default=str).encode())
        if path == "/api/blocked":
            live = live_data()
            return self._send(200, "application/json", json.dumps(
                {"connected": live.get("connected"), "version": live.get("version"),
                 "blocked": live_attention()}, default=str).encode())
        if path == "/api/blocked/wait":
            # THE long-poll that replaces polling herdr. The caller passes the
            # version it last saw; this returns the moment any agent status
            # changes, or empty-handed at `timeout` so a supervisor loop still
            # gets a heartbeat. Zero herdr RPCs either way — the answer comes
            # from the subscription that is already open.
            q = urllib.parse.parse_qs(query)
            try:
                since = int((q.get("since") or ["0"])[0])
                timeout = max(1.0, min(float((q.get("timeout") or ["30"])[0]), 300.0))
            except ValueError:
                return self._send(400, "text/plain", b"since and timeout must be numbers")
            if LIVE is None:
                return self._send(503, "application/json", b'{"connected":false,"error":"watcher not started"}')
            # The DURATION of one wait was bounded; the NUMBER of simultaneous
            # waits was not. ThreadingHTTPServer spawns a thread per connection
            # with no cap, and any local process (or a rebinding page in the
            # browser, since this surface has no auth) can park thousands on
            # `timeout=300`, pinning a thread and a descriptor each until the
            # hub stops answering anything — which, via agent-edge.sh's probe,
            # also silences every in-flight blocked-worker alert. Past the cap
            # a caller is told to come back rather than parked.
            with _WAITERS_LOCK:
                if _WAITERS["n"] >= WAIT_MAX_CONCURRENT:
                    return self._send(503, "application/json", json.dumps(
                        {"connected": live_data().get("connected"), "error": "too many waiters",
                         "retry_after_s": 1}).encode())
                _WAITERS["n"] += 1
            try:
                version = LIVE.wait_for_change(since, timeout)
            finally:
                with _WAITERS_LOCK:
                    _WAITERS["n"] -= 1
            live = live_data()
            return self._send(200, "application/json", json.dumps(
                {"connected": live.get("connected"), "version": version,
                 "changed": version != since, "blocked": live_attention()}, default=str).encode())
        if path == "/api/timeline":
            return self._send(200, "application/json",
                              json.dumps(_timeline_from_query(query), default=str).encode())
        if path == "/timeline":
            if "json=1" in query:
                return self._send(200, "application/json",
                                  json.dumps(_timeline_from_query(query), default=str).encode())
            return self._send(200, "text/html; charset=utf-8", render_timeline(query).encode())
        if path.startswith("/decisions/"):
            code, body = serve_stored_form(path[len("/decisions/"):].strip("/"))
            return self._send(code, "text/html; charset=utf-8" if code == 200 else "text/plain", body)
        if path not in PAGES:
            return self._send(404, "text/plain", b"not found")
        render, source = PAGES[path]
        scope = scope_of(query)
        if "json=1" in query:
            data = {n: CACHES[n].get() for n in CACHES} if source is None else CACHES[source].get()
            if path in ("/herdr", "/"):
                # Additive: every existing consumer of /herdr?json=1 keeps its
                # keys, and gains herdr's live truth beside the registry's.
                data = dict(data or {}, live=live_data())
            if scope and source == "herdr":
                # `repos` travels WITH the scoped payload: a consumer that asked
                # for one repo can still see the others exist, which is what
                # stops a per-repo automation from concluding the fleet is idle.
                data = dict(scoped(data, scope),
                            repos=[{"repo": full, "name": base, "tasks": n, "attention": att}
                                   for base, full, n, att in scope_repos(CACHES["herdr"].get())])
            return self._send(200, "application/json", json.dumps(data, default=str).encode())
        try:
            # Only the surfaces that HAVE a per-repo meaning take the scope;
            # the rest keep their zero-argument signature rather than growing a
            # parameter they would ignore.
            html = render(scope) if path in SCOPED_PAGES else render()
            return self._send(200, "text/html; charset=utf-8", html.encode())
        except Exception:  # a render bug must never publish exception text on an unauthenticated surface
            return self._send(500, "text/plain", b"page render unavailable")

    def do_POST(self):
        path, _, _ = self.path.partition("?")
        if path.startswith("/decisions/") and path.endswith("/submit"):
            form_id = path[len("/decisions/"):-len("/submit")].strip("/")
            n = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(n) if n > 0 else b"{}"
            try:
                payload = json.loads(raw.decode("utf-8") or "{}")
            except (UnicodeDecodeError, json.JSONDecodeError) as e:
                return self._send(400, "text/plain", f"bad json: {e}".encode())
            if not isinstance(payload, dict):
                return self._send(400, "text/plain", b"answers must be a JSON object")
            code, body = record_answer(form_id, payload)
            return self._send(code, "application/json" if code == 200 else "text/plain", body)
        if path == "/ratings/publish":
            ctype = (self.headers.get("content-type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":
                return self._send(400, "text/plain", b"Content-Type must be application/json")
            n = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(n) if n > 0 else b"{}"
            try:
                payload = json.loads(raw.decode("utf-8") or "{}")
            except (UnicodeDecodeError, json.JSONDecodeError) as e:
                return self._send(400, "text/plain", f"bad json: {e}".encode())
            if not isinstance(payload, dict):
                return self._send(400, "text/plain", b"payload must be a JSON object")
            code, body = publish_ratings_form(payload)
            return self._send(code, "application/json" if code == 200 else "text/plain", body)
        if path != "/loops/decide":
            return self._send(404, "text/plain", b"not found")
        n = int(self.headers.get("content-length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        key = (form.get("key") or [""])[0]
        title = serve_loop_decision(key)
        if not title:
            return self._send(404, "text/plain", f"no such suggestion: {key}".encode())
        self.send_response(303)
        self.send_header("location", "/decisions")
        self.send_header("content-length", "0")
        self.end_headers()

    def _send(self, code: int, ctype: str, body: bytes):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    global LIVE
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--no-live", action="store_true",
                    help="do not subscribe to herdr (pages fall back to the registry only)")
    ap.add_argument("--no-mirror", action="store_true",
                    help="do not sync forms to dashboard.teamthurber.com/decisions (smoke runs)")
    ap.add_argument("--no-attention", action="store_true",
                    help="do not run the attention controller sweep (smoke runs)")
    args = ap.parse_args()
    if port_open(args.port):
        print(f"hub: already serving on http://127.0.0.1:{args.port}/", file=sys.stderr)
        return 0
    if not args.no_live:
        # One subscription for the whole machine. It starts BEFORE the listener
        # so the first request already sees a bootstrapped fleet, and it is a
        # daemon thread: if it cannot reach herdr the hub still serves, with
        # `connected: false` saying plainly that the live rows are absent
        # rather than quietly showing a stale fleet.
        LIVE = herdr_live.LiveState(on_transition=_on_agent_edge, log=_live_log,
                                     on_connection_change=_on_connection_change)
        LIVE.start()
    if not args.no_mirror:
        threading.Thread(target=_mirror_loop, name="dashboard-mirror", daemon=True).start()
        # Same smoke-run flag: both need NEON_CONNECTION_STRING and shell out
        # to the kb-deploy checkout, and both degrade to a logged no-op
        # without it (PR #214 review MEDIUM F1's reconciler).
        threading.Thread(target=_ratings_reconcile_loop, name="ratings-reconcile", daemon=True).start()
    if not args.no_attention:
        threading.Thread(target=_attention_loop, name="attention-controller", daemon=True).start()
        # project-contract-plan.md item 3, "carry to completion" — a separate
        # thread, not folded into _attention_loop: that one reacts to CURRENTLY
        # blocked panes (an edge-fed list from herdr_live), this one sweeps
        # every project's computed state on its own slower cadence and can fire
        # with NO pane blocked at all (every worker for the project already
        # exited). Same --no-attention flag disables both.
        threading.Thread(target=_project_attention_loop, name="project-attention", daemon=True).start()
        # feat/stall-watchdog — a THIRD thread, same split again: an idle/done
        # task owing the conductor an action is neither "a pane blocked right
        # now" (attention-controller) nor "a project with no live worker"
        # (project-attention), so it gets its own sweep rather than being
        # folded into either. Same --no-attention flag disables all three.
        threading.Thread(target=_stall_watchdog_loop, name="stall-watchdog", daemon=True).start()
    # Unconditional (no --no-X flag): two small git fetches against repos we
    # own, nowhere near mirror's cost, and skipping it would reopen exactly
    # the inline-fetch-on-cold-read bug it exists to close.
    threading.Thread(target=_deploy_drift_prime_loop, name="deploy-drift-prime", daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"hub: http://127.0.0.1:{args.port}/", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
