#!/usr/bin/env python3
"""lib/prompt-occurrence.py — the one place a menu/`ask` prompt's lifecycle is
recorded and folded, shared by the TS hook (via subprocess), the shell
notify/attention/selector path (via subprocess) and hub.py (via
importlib, since this file's name carries the project's lib/ hyphen
convention and cannot be `import`ed directly).

Why this exists (docs/plans/dot-herdr-recovery-slices.md §2): omp's
`tool_approval_resolved` carries a session id but not completion; its
`tool_execution_end` carries completion but no session id; and neither alone
proves the pane screen a human sees still describes the same request. Every
existing consumer (omp-notify.sh, attention-tick.sh, herdr-select.sh,
hub.py's watchdog) answered that question for itself, out of whatever
partial signal it already had, and that is the gap this closes: a reusable
fold that every consumer reads, so "is this occurrence still open, and is
the screen still proven to be about it" has exactly one answer.

Occurrence identity is immutable: (run_id, task_id, pane_id, pane_birth,
native_session, tool_call_id) — never content, never prompt_id (a repaint
changes prompt_id without being a new question). Reusing the existing
`events` table (lib/run-registry.sh's schema_version 10) rather than a new
store: append-only, UNIQUE(event_id) dedup, one sequence counter already
shared by every other consumer of this registry.

Event types written here (all prefixed `prompt_occ_` to stay out of every
other consumer's namespace):
  prompt_occ_seen       — first-seen tool/input for an occurrence. Written
                          once (INSERT OR IGNORE on the occurrence's own
                          event id): the first call wins the first-seen
                          timestamp, a retry is a no-op.
  prompt_occ_enriched   — the same occurrence's input became available
                          later (e.g. tool_call's cached input arrived after
                          tool_approval_requested had already fired with
                          none). Does not change first-seen time or identity.
  prompt_occ_mismatch   — a DIFFERENT tool or input digest arrived under the
                          same occurrence key. This is a distinct fact from
                          enrichment (missing -> present): a real identity
                          collision, never silently merged.
  prompt_occ_screen     — a screen read correlated (or failed to correlate)
                          against this occurrence: display in
                          {pending_parseable, pending_unreadable, read_failed}
                          plus the screen's own prompt_id, when one is
                          readable.
  prompt_occ_authorized — a decision was recorded for this occurrence
                          (idempotent per occurrence: the first decision is
                          what gets recorded as the authorizing one).
  prompt_occ_completed  — a matching `tool_execution_end` arrived for a
                          previously-approved occurrence.
  prompt_occ_declined   — `tool_approval_resolved` arrived with approved
                          false. This retires the occurrence directly: a
                          real deny is never followed by execution.
  prompt_occ_withdrawn  — `tool_execution_end` arrived for an occurrence
                          that was still `requested` (no decision was ever
                          ARRIVED at: the call was aborted/skipped before an
                          approval or denial reached this store).

Approval is never completion (plan §2): `prompt_occ_authorized` moves
lifecycle from `requested` to `approved_awaiting_completion`, never to
`resolved`. Only `prompt_occ_completed` / `_declined` / `_withdrawn` resolve
an occurrence, and a resolved occurrence is STICKY — later events for the
same key keep being recorded (audit trail), never reopen it.

CLI: every subcommand prints one JSON object on stdout and exits 0 whatever
happens internally (`{"error": "..."}` on failure) — this is a monitoring
path a caller must never let crash the thing it observes, same contract as
agent-hooks/omp-herdr-control.ts's own hooks.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
import time
from pathlib import Path

DISPLAY_STATES = {"pending_parseable", "pending_unreadable", "no_prompt", "read_failed", "unknown"}
RESOLVED_TYPES = {"prompt_occ_completed", "prompt_occ_declined", "prompt_occ_withdrawn"}
LIFECYCLE_BY_RESOLUTION = {
    "prompt_occ_completed": "resolved:completed",
    "prompt_occ_declined": "resolved:declined",
    "prompt_occ_withdrawn": "resolved:withdrawn",
}
# A caller may record a denial through record_authorized's `choice` instead
# of the dedicated record_declined (e.g. a single "the decision was X" call
# site that only learns the verb afterward). Fold must never read a deny
# choice as approval regardless of which path recorded it — Main's review
# (H1, 2026-10-10): "record_authorized stores `choice` but fold sets
# authorization=approved for EVERY prompt_occ_authorized."
DENY_CHOICES = {"deny", "denied", "decline", "declined", "reject", "rejected", "no"}
# H1 residual (Main review, dc6a55d): an explicit allowlist, not "everything
# that is not a deny" — a blank choice, an unrecognized value, or a typo'd
# future caller must never silently fold as approved. Anything outside both
# sets leaves the occurrence's lifecycle untouched (still `requested`),
# exactly as if the authorized event had not landed at all.
APPROVE_CHOICES = {"approve", "approved", "yes", "allow", "allowed", "accept", "accepted"}


def occurrence_key(run_id: str, task_id: str, pane_id: str, pane_birth: str,
                    native_session: str, tool_call_id: str) -> str:
    """The immutable occurrence identity, hashed. Every field is required and
    used as-given (never normalized/defaulted) so two genuinely different
    identities — e.g. empty vs missing pane_birth on an unregistered pane —
    never collide onto the same key by accident."""
    raw = "\x1f".join([run_id, task_id, pane_id, pane_birth, native_session, tool_call_id])
    return "occ_" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def input_digest(tool: str, tool_input: object) -> str:
    """Canonical, order-independent digest of tool+input — sorted keys, no
    whitespace, so the identical input serialized two different ways by two
    different callers (the TS hook vs. a test fixture) digests the same.
    `tool_input=None` (nothing known yet) digests distinctly from any real
    value, including `{}`/`""` — M3 (Main review): a caller must say "no
    input" by never calling with one, not by having malformed JSON silently
    coerced into an indistinguishable empty value."""
    body = json.dumps({"tool": tool, "input": tool_input, "known": tool_input is not None},
                       sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(body.encode("utf-8")).hexdigest()[:32]


def _now_iso(now: float | None = None) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now if now is not None else time.time()))


def _connect(db_path: str, readonly: bool = False) -> sqlite3.Connection:
    if readonly:
        return sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
    conn = sqlite3.connect(db_path, timeout=5)
    conn.execute("PRAGMA busy_timeout=5000;")
    return conn


def _put(conn: sqlite3.Connection, event_id: str, run_id: str, task_id: str,
          typ: str, payload: dict, now: float | None = None) -> bool:
    """INSERT OR IGNORE + commit. Returns True iff THIS call's own insert won
    the UNIQUE(event_id) race (sqlite3's rowcount reflects only this
    statement on this connection — concurrent writers racing the same id is
    exactly what UNIQUE dedup exists for)."""
    cur = conn.execute(
        "INSERT OR IGNORE INTO events (event_id, run_id, task_id, type, occurred_at, payload) "
        "VALUES (?, ?, ?, ?, ?, ?);",
        (event_id, run_id, task_id, typ, _now_iso(now),
         json.dumps(payload, sort_keys=True, separators=(",", ":"))),
    )
    conn.commit()
    return cur.rowcount == 1


def _latest_identity(conn: sqlite3.Connection, task_id: str, key: str) -> dict:
    """The occurrence's current known (tool, input_digest), independent of
    which row happens to sort last. `prompt_occ_seen`/`prompt_occ_enriched`
    each live at one FIXED event id per key (no per-call suffix) so there
    is at most one row of each to read, and enriched (when present) always
    overrides seen's original value: enrichment is a one-time unknown->known
    transition, and anything after that is compared against THIS, never
    against the stale original (M2, Main review)."""
    seen_id = f"prompt_occ_seen_{key}"
    enr_id = f"prompt_occ_enriched_{key}"
    rows = conn.execute(
        "SELECT event_id, payload FROM events WHERE task_id=? AND event_id IN (?, ?);",
        (task_id, seen_id, enr_id),
    ).fetchall()
    by_id = {rid: json.loads(payload) for rid, payload in rows}
    tool = by_id.get(seen_id, {}).get("tool")
    digest = by_id[enr_id]["input_digest"] if enr_id in by_id else by_id.get(seen_id, {}).get("input_digest")
    return {"tool": tool, "input_digest": digest}


def record_seen(db_path: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
                native_session: str, tool_call_id: str, tool: str, tool_input: object,
                source: str, now: float | None = None) -> dict:
    conn = _connect(db_path)
    try:
        key = occurrence_key(run_id, task_id, pane_id, pane_birth, native_session, tool_call_id)
        digest = input_digest(tool, tool_input) if tool_input is not None else None
        eid = f"prompt_occ_seen_{key}"
        # M4 (Main review): never persist the raw tool input (a bash command
        # can carry secrets). Identity/mismatch comparison only ever needs
        # the digest; pane_birth/native_session here are occurrence IDENTITY
        # material, not command content, and stay.
        payload = {
            "occ_key": key, "run_id": run_id, "task_id": task_id, "pane_id": pane_id,
            "pane_birth": pane_birth, "native_session": native_session, "tool_call_id": tool_call_id,
            "tool": tool, "input_digest": digest, "source": source,
        }
        first = _put(conn, eid, run_id, task_id, "prompt_occ_seen", payload, now)
        if first:
            return {"occ_key": key, "written": "seen"}
        # Already seen: compare against the CURRENT known identity (seen,
        # overridden by enriched if any has landed), never against the
        # original seen row alone — a second, DIFFERENT input arriving after
        # a real enrichment must be a mismatch, not silently re-enriched
        # (M2, Main review).
        current = _latest_identity(conn, task_id, key)
        prior_tool, prior_digest = current["tool"], current["input_digest"]
        if prior_tool is not None and prior_tool != tool:
            meid = f"prompt_occ_mismatch_{key}_{digest}"
            _put(conn, meid, run_id, task_id, "prompt_occ_mismatch",
                 {"occ_key": key, "prior_tool": prior_tool, "prior_input_digest": prior_digest,
                  "tool": tool, "input_digest": digest}, now)
            return {"occ_key": key, "written": "mismatch"}
        if prior_digest is None:
            if digest is not None:
                eeid = f"prompt_occ_enriched_{key}"
                _put(conn, eeid, run_id, task_id, "prompt_occ_enriched",
                     {"occ_key": key, "input_digest": digest}, now)
                return {"occ_key": key, "written": "enriched"}
            return {"occ_key": key, "written": "duplicate"}
        if digest is None or digest == prior_digest:
            return {"occ_key": key, "written": "duplicate"}
        meid = f"prompt_occ_mismatch_{key}_{digest}"
        _put(conn, meid, run_id, task_id, "prompt_occ_mismatch",
             {"occ_key": key, "prior_tool": prior_tool, "prior_input_digest": prior_digest,
              "tool": tool, "input_digest": digest}, now)
        return {"occ_key": key, "written": "mismatch"}
    finally:
        conn.close()


def record_screen(db_path: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
                   native_session: str, tool_call_id: str, display: str,
                   screen_prompt_id: str = "", now: float | None = None) -> dict:
    if display not in DISPLAY_STATES:
        return {"error": f"unknown display state: {display}"}
    conn = _connect(db_path)
    try:
        key = occurrence_key(run_id, task_id, pane_id, pane_birth, native_session, tool_call_id)
        eid = f"prompt_occ_screen_{key}_{display}_{screen_prompt_id or 'none'}"
        _put(conn, eid, run_id, task_id, "prompt_occ_screen",
             {"occ_key": key, "display": display, "screen_prompt_id": screen_prompt_id}, now)
        return {"occ_key": key, "written": "screen"}
    finally:
        conn.close()


def record_authorized(db_path: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
                       native_session: str, tool_call_id: str, decided_by: str, choice: str,
                       now: float | None = None) -> dict:
    conn = _connect(db_path)
    try:
        key = occurrence_key(run_id, task_id, pane_id, pane_birth, native_session, tool_call_id)
        eid = f"prompt_occ_authorized_{key}"
        first = _put(conn, eid, run_id, task_id, "prompt_occ_authorized",
                     {"occ_key": key, "decided_by": decided_by, "choice": choice}, now)
        return {"occ_key": key, "written": "authorized" if first else "duplicate"}
    finally:
        conn.close()


def _resolve(db_path: str, kind: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
             native_session: str, tool_call_id: str, detail: dict | None = None,
             now: float | None = None) -> dict:
    conn = _connect(db_path)
    try:
        key = occurrence_key(run_id, task_id, pane_id, pane_birth, native_session, tool_call_id)
        eid = f"prompt_{kind}_{key}"
        payload = {"occ_key": key, **(detail or {})}
        first = _put(conn, eid, run_id, task_id, f"prompt_{kind}", payload, now)
        return {"occ_key": key, "written": kind if first else "duplicate"}
    finally:
        conn.close()


def record_completed(db_path: str, *, is_error: bool = False, **kw) -> dict:
    return _resolve(db_path, "occ_completed", detail={"is_error": is_error}, **kw)


def record_declined(db_path: str, *, reason: str = "", **kw) -> dict:
    return _resolve(db_path, "occ_declined", detail={"reason": reason}, **kw)


def record_withdrawn(db_path: str, *, reason: str = "", **kw) -> dict:
    return _resolve(db_path, "occ_withdrawn", detail={"reason": reason}, **kw)


def fold_task(db_path: str, run_id: str, task_id: str, readonly: bool = True) -> dict:
    """The deterministic fold: every prompt_occ_* event for this (run, task),
    collapsed to one record per occurrence key. Pure function of the event
    rows — safe after a restart, a crash mid-write (an uncommitted row
    simply is not there yet) and concurrent readers, because nothing here
    mutates anything; record_* above is the only writer path."""
    if readonly and not Path(db_path).exists():
        # L1 (Main review): a readonly URI connect to a file that does not
        # exist raises immediately, before any try/except could catch it.
        return {}
    try:
        conn = _connect(db_path, readonly=readonly)
    except sqlite3.Error as exc:
        return {"error": str(exc)}
    try:
        try:
            rows = conn.execute(
                "SELECT sequence, event_id, type, occurred_at, payload FROM events "
                "WHERE run_id=? AND task_id=? AND type LIKE 'prompt_occ_%' ORDER BY sequence;",
                (run_id, task_id),
            ).fetchall()
        except sqlite3.Error as exc:
            return {"error": str(exc)}
    finally:
        conn.close()

    # Pass 1: order-independent per-key facts. H2 (Main review): two
    # processes can commit rows in an order that does not match wall-clock
    # reality (a delayed/retried INSERT), so "was this key ever seen" and
    # "was an AFFIRMATIVE decision ever recorded for it" must be known from
    # the WHOLE set, not from "have we reached it yet in sequence order" —
    # otherwise a real out-of-order write makes a genuinely approved
    # completion look unapproved, and an unseen/unapproved one look clean.
    seen_keys: set[str] = set()
    approved_keys: set[str] = set()
    for _sequence, _event_id, typ, _occurred_at, payload_json in rows:
        try:
            payload = json.loads(payload_json)
        except (TypeError, ValueError):
            continue
        key = payload.get("occ_key")
        if not isinstance(key, str) or not key:
            continue
        if typ == "prompt_occ_seen":
            seen_keys.add(key)
        elif typ == "prompt_occ_authorized":
            choice = str(payload.get("choice") or "").strip().lower()
            if choice not in DENY_CHOICES:
                approved_keys.add(key)

    occ: dict[str, dict] = {}
    for sequence, event_id, typ, occurred_at, payload_json in rows:
        try:
            payload = json.loads(payload_json)
        except (TypeError, ValueError):
            continue
        key = payload.get("occ_key")
        if not isinstance(key, str) or not key:
            continue
        rec = occ.get(key)
        if rec is None:
            rec = {
                "occ_key": key, "tool": None, "input_digest": None,
                "display": "unknown", "screen_prompt_id": "", "mismatch": False,
                "authorization": "none", "decided_by": None, "lifecycle": "unknown",
                "identity_verified": False, "unresolved_reason": None,
                "first_seen_seq": None, "first_seen_at": None, "last_seq": sequence,
                "last_at": occurred_at,
            }
            occ[key] = rec
        rec["last_seq"] = sequence
        rec["last_at"] = occurred_at

        if typ == "prompt_occ_seen":
            rec["tool"] = payload.get("tool")
            rec["input_digest"] = payload.get("input_digest")
            rec["pane_id"] = payload.get("pane_id")
            rec["pane_birth"] = payload.get("pane_birth")
            rec["native_session"] = payload.get("native_session")
            rec["tool_call_id"] = payload.get("tool_call_id")
            rec["source"] = payload.get("source")
            rec["first_seen_seq"] = sequence
            rec["first_seen_at"] = occurred_at
            # M1 (Main review): a missing pane_birth or native_session is
            # not "a value equal to another occurrence's missing value" —
            # it is unknown identity, and a consumer must treat it with the
            # same caution as correlation_mismatch (never send keys on it).
            rec["identity_verified"] = bool(payload.get("pane_birth")) and bool(payload.get("native_session"))
            if rec["lifecycle"] == "unknown":
                rec["lifecycle"] = "requested"
        elif typ == "prompt_occ_enriched":
            if rec["input_digest"] is None:
                rec["input_digest"] = payload.get("input_digest")
        elif typ == "prompt_occ_mismatch":
            rec["mismatch"] = True
        elif typ == "prompt_occ_screen":
            # Resolved occurrences keep their lifecycle; a late screen read
            # is still recorded above (last_seq/last_at) but must not revive
            # pending display on something already closed.
            if not rec["lifecycle"].startswith("resolved"):
                rec["display"] = payload.get("display", rec["display"])
                rec["screen_prompt_id"] = payload.get("screen_prompt_id", "")
        elif typ == "prompt_occ_authorized":
            if not rec["lifecycle"].startswith("resolved"):
                choice = str(payload.get("choice") or "").strip().lower()
                rec["decided_by"] = payload.get("decided_by")
                if choice in DENY_CHOICES:
                    # H1 (Main review): a deny choice resolves as declined
                    # directly, whichever path recorded it — it must never
                    # read as approval.
                    rec["lifecycle"] = "resolved:declined"
                elif choice in APPROVE_CHOICES:
                    rec["authorization"] = "approved"
                    rec["lifecycle"] = "approved_awaiting_completion"
                # else: an unrecognized or blank choice (H1 residual, Main
                # review dc6a55d) decides nothing — the occurrence stays
                # exactly where it was (normally `requested`), never folded
                # as approved by default.
        elif typ in RESOLVED_TYPES:
            # Sticky: the FIRST resolution wins; a duplicate/out-of-order
            # resolution event for an already-resolved key is audit only.
            if not rec["lifecycle"].startswith("resolved"):
                if key not in seen_keys:
                    # H2 (Main review): a resolution for a key that was
                    # never actually seen/requested is not a real
                    # occurrence to resolve — there is nothing here to call
                    # completed, declined or withdrawn.
                    rec["lifecycle"] = "unknown"
                    rec["unresolved_reason"] = "resolution_without_seen"
                elif typ == "prompt_occ_completed" and key not in approved_keys:
                    # A completion claiming success without ever being
                    # approved is never trusted as a clean completion
                    # (plan: "a failed matching completion resolves the
                    # action as failed, without declaring task success").
                    rec["lifecycle"] = "resolved:withdrawn"
                    rec["unresolved_reason"] = "completed_without_approval"
                else:
                    rec["lifecycle"] = LIFECYCLE_BY_RESOLUTION[typ]

    for rec in occ.values():
        if rec["mismatch"] and not rec["lifecycle"].startswith("resolved"):
            # A proven identity collision is never a safe thing to answer:
            # unknown display, no authorization inferred from either side.
            rec["display"] = "correlation_mismatch"
    return occ


def occurrence_state(db_path: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
                      native_session: str, tool_call_id: str) -> dict:
    key = occurrence_key(run_id, task_id, pane_id, pane_birth, native_session, tool_call_id)
    folded = fold_task(db_path, run_id, task_id)
    if isinstance(folded, dict) and "error" in folded and key not in folded:
        return folded
    return folded.get(key, {"occ_key": key, "lifecycle": "unknown", "display": "unknown",
                             "authorization": "none"})


def _add_identity_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--db", required=True)
    p.add_argument("--run", dest="run_id", required=True)
    p.add_argument("--task", dest="task_id", required=True)
    p.add_argument("--pane", dest="pane_id", required=True)
    p.add_argument("--birth", dest="pane_birth", required=True)
    p.add_argument("--session", dest="native_session", required=True)
    p.add_argument("--call-id", dest="tool_call_id", required=True)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="prompt-occurrence.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("seen")
    _add_identity_args(s)
    s.add_argument("--tool", required=True)
    s.add_argument("--input-json", default=None)
    s.add_argument("--source", default="")

    s = sub.add_parser("screen")
    _add_identity_args(s)
    s.add_argument("--display", required=True)
    s.add_argument("--prompt-id", dest="screen_prompt_id", default="")

    s = sub.add_parser("authorized")
    _add_identity_args(s)
    s.add_argument("--decided-by", default="")
    s.add_argument("--choice", default="")

    for name in ("completed", "declined", "withdrawn"):
        s = sub.add_parser(name)
        _add_identity_args(s)
        if name == "completed":
            s.add_argument("--is-error", action="store_true")
        else:
            s.add_argument("--reason", default="")

    s = sub.add_parser("state")
    _add_identity_args(s)

    s = sub.add_parser("fold")
    s.add_argument("--db", required=True)
    s.add_argument("--run", dest="run_id", required=True)
    s.add_argument("--task", dest="task_id", required=True)

    args = ap.parse_args(argv)
    try:
        if args.cmd == "seen":
            if args.input_json is None:
                tool_input = None
            else:
                try:
                    tool_input = json.loads(args.input_json)
                except (TypeError, ValueError):
                    print(json.dumps({"error": f"malformed --input-json: {args.input_json!r}"}))
                    return 0
            out = record_seen(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                               pane_birth=args.pane_birth, native_session=args.native_session,
                               tool_call_id=args.tool_call_id, tool=args.tool, tool_input=tool_input,
                               source=args.source)
        elif args.cmd == "screen":
            out = record_screen(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                 pane_birth=args.pane_birth, native_session=args.native_session,
                                 tool_call_id=args.tool_call_id, display=args.display,
                                 screen_prompt_id=args.screen_prompt_id)
        elif args.cmd == "authorized":
            out = record_authorized(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                     pane_birth=args.pane_birth, native_session=args.native_session,
                                     tool_call_id=args.tool_call_id, decided_by=args.decided_by,
                                     choice=args.choice)
        elif args.cmd == "completed":
            out = record_completed(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                    pane_birth=args.pane_birth, native_session=args.native_session,
                                    tool_call_id=args.tool_call_id, is_error=args.is_error)
        elif args.cmd == "declined":
            out = record_declined(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                   pane_birth=args.pane_birth, native_session=args.native_session,
                                   tool_call_id=args.tool_call_id, reason=args.reason)
        elif args.cmd == "withdrawn":
            out = record_withdrawn(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                    pane_birth=args.pane_birth, native_session=args.native_session,
                                    tool_call_id=args.tool_call_id, reason=args.reason)
        elif args.cmd == "state":
            out = occurrence_state(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                    pane_birth=args.pane_birth, native_session=args.native_session,
                                    tool_call_id=args.tool_call_id)
        elif args.cmd == "fold":
            out = fold_task(args.db, args.run_id, args.task_id)
        else:
            out = {"error": f"unknown command {args.cmd}"}
    except Exception as exc:  # noqa: BLE001 — a monitoring CLI must never crash its caller
        out = {"error": str(exc)}
    print(json.dumps(out, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
