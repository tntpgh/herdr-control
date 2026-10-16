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
import os
import re
import sqlite3
import sys
import time
from datetime import datetime
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


def _canonical_input_body(tool: str, tool_input: object) -> bytes:
    return json.dumps({"tool": tool, "input": tool_input, "known": tool_input is not None},
                      sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")


def input_digest(tool: str, tool_input: object) -> str:
    """Canonical, order-independent digest of tool+input — sorted keys, no
    whitespace, so the identical input serialized two different ways by two
    different callers (the TS hook vs. a test fixture) digests the same.
    `tool_input=None` (nothing known yet) digests distinctly from any real
    value, including `{}`/`""` — M3 (Main review): a caller must say "no
    input" by never calling with one, not by having malformed JSON silently
    coerced into an indistinguishable empty value."""
    return hashlib.sha256(_canonical_input_body(tool, tool_input)).hexdigest()[:32]


def payload_sha256(tool: str, tool_input: object) -> str:
    """The full sha256 of the same canonical body input_digest truncates: the
    hash an approval of a complete write/edit payload is bound to (#277)."""
    return hashlib.sha256(_canonical_input_body(tool, tool_input)).hexdigest()


# ---- complete approval payloads for write/edit (herdr-control #277) --------
# The registry row (prompt_occ_seen/enriched: input_digest + payload_sha256 +
# cwd) is the trust anchor; the proposal FILE only carries the bytes, because
# M4 keeps raw tool input out of the shared events table. A file that does not
# hash to the registry's value is refused, so tampering, truncation or a
# substituted file cannot be approved. Deleted when the occurrence resolves.
# Slice (b), bound-bash: default OFF (env var absent). With the flag off,
# PROPOSAL_TOOLS stays exactly {"write", "edit"} — today's behaviour,
# byte-for-byte. Binding proves identity only; the canonical bash command
# still goes through herdr-select.sh's Path A command-policy check.
# Exact "1" only, no whitespace trimming: must match herdr-select.sh and the
# TS hook byte-for-byte so a padded value is OFF in all three readers.
HERDR_BOUND_BASH = os.environ.get("HERDR_BOUND_BASH", "") == "1"
PROPOSAL_TOOLS = {"write", "edit"} | ({"bash", "shell"} if HERDR_BOUND_BASH else set())
PROPOSAL_VERSION = 1
# Bounded: raw input never enters the shared events table, only this
# per-occurrence file, capped at PROPOSAL_MAX_BYTES and deleted when the
# occurrence resolves. Over the cap no file is written: human-only.
PROPOSAL_MAX_BYTES = 262_144
NOTEPAD_XD = {"xd://notepad_append", "xd://notepad_priority", "xd://notepad_stats", "xd://notepad_read"}
# A proposal whose resolution was never recorded (hook queue drop, omp crash,
# a human approval that never finished) is swept once this old; a prompt
# still pending past it simply fails closed (no proposal).
PROPOSAL_MAX_AGE_S = 24 * 3600


def proposal_path(db_path: str, key: str) -> Path:
    return Path(db_path).resolve().parent / "proposals" / f"{key}.json"


def _write_proposal(db_path: str, key: str, record: dict) -> str:
    """Atomic, 0600, never overwrites an existing proposal for the key (the
    first recorded input is the one the registry digest describes)."""
    path = proposal_path(db_path, key)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    _sweep_proposals(path.parent)
    if path.exists():
        return "exists"
    data = json.dumps(record, sort_keys=True)
    if len(data.encode("utf-8")) > PROPOSAL_MAX_BYTES:
        return "too_large"
    tmp = path.with_name(f".{key}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    return "written"


def _drop_proposal(db_path: str, key: str) -> None:
    try:
        proposal_path(db_path, key).unlink()
    except OSError:
        pass


def _sweep_proposals(directory: Path, now: float | None = None) -> None:
    """Drop proposals (and temp files a killed writer left) past the age cap."""
    cutoff = (now if now is not None else time.time()) - PROPOSAL_MAX_AGE_S
    for entry in directory.iterdir():
        try:
            if entry.name.endswith((".json", ".tmp")) and entry.lstat().st_mtime < cutoff:
                entry.unlink()
        except OSError:
            pass


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
                source: str, cwd: str = "", dispatched_at_ms: int | None = None,
                approval_request_id: str = "", core_arguments_digest: str = "",
                binding_protocol: str = "", core_arguments_json: str = "",
                now: float | None = None) -> dict:
    conn = _connect(db_path)
    try:
        key = occurrence_key(run_id, task_id, pane_id, pane_birth, native_session, tool_call_id)
        digest = input_digest(tool, tool_input) if tool_input is not None else None
        full = payload_sha256(tool, tool_input) if tool_input is not None else None
        eid = f"prompt_occ_seen_{key}"
        # M4 (Main review): never persist the raw tool input (a bash command
        # can carry secrets). Identity/mismatch comparison only ever needs
        # the digest; pane_birth/native_session here are occurrence IDENTITY
        # material, not command content, and stay.
        payload = {
            "occ_key": key, "run_id": run_id, "task_id": task_id, "pane_id": pane_id,
            "pane_birth": pane_birth, "native_session": native_session, "tool_call_id": tool_call_id,
            "tool": tool, "input_digest": digest, "payload_sha256": full, "source": source,
            "cwd": cwd, "dispatched_at_ms": dispatched_at_ms,
            "approval_request_id": approval_request_id,
            "core_arguments_digest": core_arguments_digest,
            "binding_protocol": binding_protocol,
            "at_ms": int((now if now is not None else time.time()) * 1000),
        }

        def proposal(written: str) -> dict:
            out = {"occ_key": key, "written": written}
            if tool_input is not None and str(tool).lower() in PROPOSAL_TOOLS:
                try:
                    out["proposal"] = _write_proposal(db_path, key, {
                        "version": PROPOSAL_VERSION, "occ_key": key, "run_id": run_id, "task_id": task_id,
                        "pane_id": pane_id, "pane_birth": pane_birth, "native_session": native_session,
                        "tool_call_id": tool_call_id, "tool": tool, "input": tool_input,
                        "payload_sha256": full,
                        "approval_request_id": approval_request_id,
                        "core_arguments_digest": core_arguments_digest,
                        "binding_protocol": binding_protocol,
                        "core_arguments_json": core_arguments_json,
                    })
                except OSError as exc:
                    # The occurrence itself IS recorded; without its file the
                    # payload simply cannot be approved by automation.
                    out["proposal"] = f"failed: {exc}"
            return out

        first = _put(conn, eid, run_id, task_id, "prompt_occ_seen", payload, now)
        if first:
            return proposal("seen")
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
                won = _put(conn, eeid, run_id, task_id, "prompt_occ_enriched",
                           {"occ_key": key, "input_digest": digest, "payload_sha256": full}, now)
                # Only the call whose enrichment the registry holds may write
                # the file that has to hash to it.
                return proposal("enriched") if won else {"occ_key": key, "written": "enriched"}
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
                     {"occ_key": key, "decided_by": decided_by, "choice": choice,
                      "at_ms": int((now if now is not None else time.time()) * 1000)}, now)
        if str(choice).strip().lower() in DENY_CHOICES:
            _drop_proposal(db_path, key)
        return {"occ_key": key, "written": "authorized" if first else "duplicate"}
    finally:
        conn.close()


def authorize_bound(db_path: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
                    native_session: str, tool_call_id: str, approval_request_id: str,
                    core_arguments_digest: str, worktree: str, conductor_pane: str,
                    conductor_birth: str, approval_id: str, choice: str, authority: str,
                    decided_by: str,
                    review_reason: str, review_category: str, reviewer: str,
                    audit_text: str, expect_payload_sha: str, now: float | None = None) -> dict:
    """Atomically prove current task/conductor authority and claim one bound request."""
    conn = _connect(db_path)
    key = occurrence_key(run_id, task_id, pane_id, pane_birth, native_session, tool_call_id)
    event_id = f"prompt_occ_authorized_{key}"
    stamp = _now_iso(now)
    at_ms = int((now if now is not None else time.time()) * 1000)
    try:
        conn.execute("BEGIN IMMEDIATE")
        task = conn.execute(
            "SELECT run_id,pane_id,pane_birth,worktree,state,conductor_pane_id,conductor_pane_birth "
            "FROM tasks WHERE task_id=?", (task_id,),
        ).fetchone()
        if not task or task[0] != run_id or task[1] != pane_id or task[2] != pane_birth \
                or task[3] != worktree or task[4] not in {"starting", "running", "blocked"} \
                or task[5] != conductor_pane or task[6] != conductor_birth:
            conn.rollback()
            return {"occ_key": key, "written": "authority_changed"}
        seen = conn.execute(
            "SELECT payload,occurred_at FROM events WHERE event_id=? AND run_id=? AND task_id=? AND type='prompt_occ_seen'",
            (f"prompt_occ_seen_{key}", run_id, task_id),
        ).fetchone()
        if not seen:
            conn.rollback()
            return {"occ_key": key, "written": "request_missing"}
        try:
            payload = json.loads(seen[0])
        except (TypeError, ValueError):
            conn.rollback()
            return {"occ_key": key, "written": "request_malformed"}
        if payload.get("approval_request_id") != approval_request_id \
                or payload.get("core_arguments_digest") != core_arguments_digest \
                or payload.get("binding_protocol") != "omp.tool-approval-binding.v1" \
                or payload.get("payload_sha256") != expect_payload_sha:
            conn.rollback()
            return {"occ_key": key, "written": "request_changed"}
        try:
            age = (now if now is not None else time.time()) - datetime.fromisoformat(
                str(seen[1]).replace("Z", "+00:00")).timestamp()
        except (TypeError, ValueError):
            conn.rollback()
            return {"occ_key": key, "written": "request_malformed"}
        if age < -30 or age > 60 * 60:
            conn.rollback()
            return {"occ_key": key, "written": "request_expired"}
        closed = conn.execute(
            "SELECT 1 FROM events WHERE run_id=? AND task_id=? "
            "AND json_extract(payload,'$.occ_key')=? "
            "AND type IN ('prompt_occ_authorized','prompt_occ_mismatch','prompt_occ_completed',"
            "'prompt_occ_declined','prompt_occ_withdrawn') LIMIT 1",
            (run_id, task_id, key),
        ).fetchone()
        if closed:
            conn.rollback()
            return {"occ_key": key, "written": "closed_or_mismatched"}
        conn.execute(
            "INSERT INTO approvals (approval_id,run_id,task_id,pane_id,prompt_id,choice,choice_text,"
            "decided_by,authority,policy_verdict,command,decided_at,attempted_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (approval_id, run_id, task_id, pane_id, approval_request_id,
             "1" if str(choice).strip().lower() in APPROVE_CHOICES else "2", choice,
             decided_by, authority, "allow", audit_text[:500], stamp, stamp),
        )
        review_payload = {"approval_id": approval_id, "reason": review_reason,
                          "category": review_category, "reviewer": reviewer,
                          "approval_request_id": approval_request_id,
                          "tool_call_id": tool_call_id, "arguments_digest": core_arguments_digest}
        conn.execute(
            "INSERT INTO events (event_id,run_id,task_id,type,occurred_at,payload) VALUES (?,?,?,?,?,?)",
            (f"approval_reviewed_{approval_id}", run_id, task_id, "approval_reviewed", stamp,
             json.dumps(review_payload, sort_keys=True, separators=(",", ":"))),
        )
        conn.execute(
            "INSERT INTO events (event_id,run_id,task_id,type,occurred_at,payload) VALUES (?,?,?,?,?,?)",
            (event_id, run_id, task_id, "prompt_occ_authorized", stamp,
             json.dumps({"occ_key": key, "decided_by": decided_by, "choice": choice, "at_ms": at_ms},
                        sort_keys=True, separators=(",", ":"))),
        )
        conn.commit()
        if str(choice).strip().lower() in DENY_CHOICES:
            _drop_proposal(db_path, key)
        return {"occ_key": key, "written": "authorized", "approval_id": approval_id}
    except sqlite3.IntegrityError:
        conn.rollback()
        return {"occ_key": key, "written": "duplicate"}
    finally:
        conn.close()


def _resolve(db_path: str, kind: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
             native_session: str, tool_call_id: str, detail: dict | None = None,
             now: float | None = None) -> dict:
    conn = _connect(db_path)
    try:
        key = occurrence_key(run_id, task_id, pane_id, pane_birth, native_session, tool_call_id)
        eid = f"prompt_{kind}_{key}"
        payload = {"occ_key": key, **(detail or {}),
                   "at_ms": int((now if now is not None else time.time()) * 1000)}
        first = _put(conn, eid, run_id, task_id, f"prompt_{kind}", payload, now)
        if kind in ("occ_completed", "occ_declined", "occ_withdrawn"):
            _drop_proposal(db_path, key)
        return {"occ_key": key, "written": kind if first else "duplicate"}
    finally:
        conn.close()


def record_started(db_path: str, **kw) -> dict:
    """`tool_execution_start` for an approved occurrence: timing evidence
    only (#277); never changes lifecycle."""
    return _resolve(db_path, "occ_started", **kw)


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
            if choice in APPROVE_CHOICES:
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
            rec["approval_request_id"] = payload.get("approval_request_id") or ""
            rec["core_arguments_digest"] = payload.get("core_arguments_digest") or ""
            rec["binding_protocol"] = payload.get("binding_protocol") or ""
            if payload.get("payload_sha256") is not None or "payload_sha256" not in rec:
                rec["payload_sha256"] = payload.get("payload_sha256")
            rec["cwd"] = payload.get("cwd") or ""
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
            if rec.get("payload_sha256") is None and payload.get("payload_sha256") is not None:
                rec["payload_sha256"] = payload.get("payload_sha256")
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

    # M1 (Main review, dc6a55d): identity_verified was computed but nothing
    # enforced it — "safe only if every consumer refuses keys when
    # identity_verified is false; that is not yet enforced." Enforced here,
    # once, for every consumer of this fold (occurrence_state, hub.py,
    # any future reader) rather than trusting each one to re-check the flag
    # itself: an occurrence with an unproven pane_birth/native_session must
    # never read as authorized or completed, whichever event recorded it.
    for rec in occ.values():
        if rec["mismatch"] and not rec["lifecycle"].startswith("resolved"):
            # A proven identity collision is never a safe thing to answer:
            # unknown display, no authorization inferred from either side.
            rec["display"] = "correlation_mismatch"
        if not rec.get("identity_verified") and rec["lifecycle"] in (
            "approved_awaiting_completion", "resolved:completed",
        ):
            rec["lifecycle"] = "unknown"
            rec["authorization"] = "none"
            rec["unresolved_reason"] = "identity_unverified"
    return occ


def occurrence_state(db_path: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
                      native_session: str, tool_call_id: str) -> dict:
    key = occurrence_key(run_id, task_id, pane_id, pane_birth, native_session, tool_call_id)
    folded = fold_task(db_path, run_id, task_id)
    if isinstance(folded, dict) and "error" in folded and key not in folded:
        return folded
    return folded.get(key, {"occ_key": key, "lifecycle": "unknown", "display": "unknown",
                             "authorization": "none"})


_PATH_FIELDS = ("path", "file_path", "filePath", "filepath", "file", "notebook_path", "target", "dest",
                "destination", "new_path", "newPath")
_EDIT_HEADER = re.compile(r"^\[(.+)#[0-9A-Fa-f]{4}\]$")
_EDIT_PATCH = re.compile(r"^\*{3}\s+(?:(?:Add|Update|Delete|Edit)\s+File|Move\s+to):\s*(.+)$", re.I)
_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def _unquote(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    return s


def _path_fields(rec: dict) -> list[str]:
    out: list[str] = []
    for k in (*_PATH_FIELDS, "paths", "files"):
        v = rec.get(k)
        if isinstance(v, str) and v:
            out.append(v)
        elif isinstance(v, list):
            out.extend(x for x in v if isinstance(x, str) and x)
    return out


def _payload_targets(tool: str, inp: object) -> list[str] | str:
    """Every file a write/edit input names — the same fields
    agent-hooks/omp-herdr-control.ts mutationTargets reads."""
    if not isinstance(inp, dict):
        return "tool input is not an object"
    if tool in ("bash", "shell"):
        # A bash/shell command names no file target; the write/edit-shaped
        # walk below would misread `command`/`input` text as a patch body.
        return []
    targets = _path_fields(inp)
    if tool == "write":
        if not isinstance(inp.get("content"), str):
            return "write input has no string content"
        return targets or "write names no path"
    for k in ("input", "patch", "diff"):
        text = inp.get(k)
        if not isinstance(text, str):
            continue
        last = ""
        for line in text.splitlines():
            t = line.strip()
            if t.startswith("["):
                m = _EDIT_HEADER.match(t)
                if not m:
                    return f"cannot parse the edit section header {t[:120]!r}"
                last = _unquote(m.group(1))
                targets.append(last)
            elif re.match(r"^mv(\s|$)", t, re.I):
                dest = _unquote(t[2:])
                if not dest:
                    return "an MV op names no destination"
                targets.append(dest)
                if last and not os.path.isabs(dest) and not re.match(r"^[~@:\[]", dest):
                    targets.append(os.path.join(os.path.dirname(last), dest))
            else:
                m = _EDIT_PATCH.match(t)
                if m:
                    targets.append(_unquote(m.group(1)))
    for entry in inp.get("edits") or []:
        if isinstance(entry, dict):
            targets.extend(_path_fields(entry))
            if isinstance(entry.get("rename"), str) and entry["rename"]:
                targets.append(entry["rename"])
    return targets or "cannot tell which file this edit touches"


def _canonical_target(raw: str, cwd: str, wt_real: str, tool: str) -> tuple[str, str]:
    """(canonical path, "") or ("", refusal). Resolved NOW, so a symlink or
    directory swapped in after the proposal was recorded is caught."""
    p = raw.strip()
    if tool == "write" and p in NOTEPAD_XD:
        return p, ""
    if not p or _SCHEME.match(p) or p[0] in "~@[":
        return "", f"target {raw!r} is not a plain filesystem path"
    if ".." in p.split("/"):
        # normpath would collapse `link/..` textually while the kernel follows
        # `link` first, so the reviewed target could differ from the written one.
        return "", f"target {raw!r} has a '..' component"
    if not os.path.isabs(p):
        if not os.path.isabs(cwd):
            return "", f"relative target {raw!r} but the occurrence recorded no absolute cwd"
        p = os.path.join(cwd, p)
    lexical = os.path.normpath(p)
    if os.path.islink(lexical):
        return "", f"target {lexical} is a symlink"
    canon = os.path.join(os.path.realpath(os.path.dirname(lexical)), os.path.basename(lexical))
    if os.path.realpath(canon) != canon:
        return "", f"target {lexical} does not resolve to itself"
    rel = os.path.relpath(canon, wt_real)
    if rel == "." or rel == ".." or rel.startswith(".." + os.sep):
        return "", f"target {canon} is outside the worker worktree {wt_real}"
    if ".git" in [part.lower() for part in rel.split(os.sep)]:
        return "", f"target {canon} is inside .git"
    if os.path.isdir(canon):
        return "", f"target {canon} is a directory"
    if os.path.isfile(canon) and os.lstat(canon).st_nlink > 1:
        # Mirrors the dispatch guard (agent-hooks/omp-herdr-control.ts): a write
        # through a hard link also changes the file's other names.
        return "", f"target {canon} is a hard link"
    return canon, ""


def proposal_check(db_path: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
                   screen_prompt_id: str, worktree: str, tool: str = "", expect_sha: str = "",
                   approval_request_id: str = "", expect_arguments_digest: str = "",
                   expect_tool_call_id: str = "") -> dict:
    """Verify the complete write/edit payload behind the prompt now on screen
    (#277). Fails closed on every missing, malformed, truncated, substituted,
    stale or out-of-scope case; `ok: true` only when the file hashes to the
    registry row of the one unresolved occurrence that pane's screen shows."""
    def no(reason: str) -> dict:
        return {"ok": False, "reason": reason, "checked_at_ms": int(time.time() * 1000)}

    folded = fold_task(db_path, run_id, task_id)
    if not isinstance(folded, dict) or "error" in folded:
        return no(f"occurrence registry unreadable: {folded.get('error') if isinstance(folded, dict) else folded}")
    bound_lookup = bool(approval_request_id)
    if bound_lookup:
        if not expect_arguments_digest or not expect_tool_call_id:
            return no("bound request lookup requires the reviewed arguments digest and tool call id")
        matches = [r for r in folded.values()
                   if r.get("pane_id") == pane_id
                   and r.get("approval_request_id") == approval_request_id]
    else:
        if not screen_prompt_id:
            return no("no prompt id is readable on screen")
        matches = [r for r in folded.values()
                   if r.get("pane_id") == pane_id and r.get("screen_prompt_id") == screen_prompt_id]
    if not matches:
        return no("no recorded occurrence matches the exact bound request" if bound_lookup
                  else "no recorded occurrence of this task matches the prompt on screen")
    if len(matches) != 1:
        return no("more than one occurrence claims this bound request" if bound_lookup
                  else "more than one occurrence claims the prompt on screen")
    rec = matches[0]
    rtool = str(rec.get("tool") or "")
    if rec.get("lifecycle") != "requested":
        return no(f"occurrence is {rec.get('lifecycle')}, not awaiting approval")
    if not rec.get("identity_verified") or (pane_birth and rec.get("pane_birth") != pane_birth):
        return no("occurrence identity is unverified or from a different pane lifetime")
    if rec.get("mismatch"):
        return no("occurrence identity/input correlation is mismatched")
    if bound_lookup:
        if rec.get("binding_protocol") != "omp.tool-approval-binding.v1":
            return no("occurrence is not an exact OMP v1 bound request")
        if rec.get("core_arguments_digest") != expect_arguments_digest:
            return no("bound request arguments digest differs from the reviewed digest")
        if rec.get("tool_call_id") != expect_tool_call_id:
            return no("bound request tool call id differs from the reviewed call")
        first_seen = rec.get("first_seen_at")
        try:
            age = time.time() - datetime.fromisoformat(str(first_seen).replace("Z", "+00:00")).timestamp()
        except (TypeError, ValueError):
            return no("bound request has no parseable creation time")
        if age < -30 or age > 60 * 60:
            return no("bound request is outside the one-hour resolver lifetime")
    elif rec.get("display") != "pending_parseable":
        return no(f"occurrence display is {rec.get('display')} (input mismatch or unreadable screen)")
    if rtool.lower() not in PROPOSAL_TOOLS or (tool and rtool.lower() != tool.lower()):
        return no(f"occurrence tool {rtool!r} is not the write/edit tool on screen ({tool!r})")
    digest, full = rec.get("input_digest"), rec.get("payload_sha256")
    if not digest or not full:
        return no("no complete payload was recorded for this occurrence")
    if expect_sha and expect_sha != full:
        return no(f"payload changed since review: reviewed {expect_sha[:16]}…, recorded {full[:16]}…")
    path = proposal_path(db_path, rec["occ_key"])
    try:
        if path.is_symlink():
            return no("proposal file is a symlink")
        if path.stat().st_size > PROPOSAL_MAX_BYTES:
            return no("proposal file exceeds the size bound")
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return no(f"proposal file missing, unreadable or malformed: {exc.__class__.__name__}")
    if not isinstance(doc, dict) or doc.get("version") != PROPOSAL_VERSION:
        return no("proposal file is not a version-1 proposal")
    want = {"occ_key": rec["occ_key"], "run_id": run_id, "task_id": task_id, "pane_id": pane_id,
            "pane_birth": rec.get("pane_birth"), "native_session": rec.get("native_session"),
            "tool_call_id": rec.get("tool_call_id"), "tool": rtool,
            "approval_request_id": rec.get("approval_request_id") or "",
            "core_arguments_digest": rec.get("core_arguments_digest") or "",
            "binding_protocol": rec.get("binding_protocol") or ""}
    bad = sorted(k for k, v in want.items() if doc.get(k) != v)
    if bad:
        return no(f"proposal identity differs from the occurrence: {', '.join(bad)}")
    if rec.get("binding_protocol"):
        core_json = doc.get("core_arguments_json")
        core_digest = rec.get("core_arguments_digest") or ""
        if not isinstance(core_json, str) or not core_digest.startswith("sha256:"):
            return no("bound proposal lacks canonical OMP arguments")
        if "sha256:" + hashlib.sha256(core_json.encode("utf-8")).hexdigest() != core_digest:
            return no("canonical OMP arguments do not match the bound digest")
        try:
            if json.loads(core_json) != doc.get("input"):
                return no("reviewed proposal differs from OMP effective arguments")
        except ValueError:
            return no("canonical OMP arguments are malformed")
    inp = doc.get("input")
    if input_digest(rtool, inp) != digest or payload_sha256(rtool, inp) != full:
        return no("proposal does not hash to the recorded payload (truncated or substituted)")
    raw_targets = _payload_targets(rtool.lower(), inp)
    if isinstance(raw_targets, str):
        return no(raw_targets)
    wt_real = os.path.realpath(worktree) if worktree else ""
    if not wt_real or not os.path.isdir(wt_real):
        return no("the worker worktree is unknown or missing")
    targets: list[str] = []
    for raw in raw_targets:
        canon, err = _canonical_target(raw, rec.get("cwd") or "", wt_real, rtool.lower())
        if err:
            return no(err)
        if canon not in targets:
            targets.append(canon)
    if rtool.lower() == "write":
        body, label = inp["content"], "Content"
    elif isinstance(inp.get("input"), str) and set(inp) <= {"input"}:
        body, label = inp["input"], "Input"
    else:
        body, label = json.dumps(inp, sort_keys=True, indent=1), "Input"
    header = f"Allow tool: {rtool.lower()} Path: {', '.join(targets)}"
    body_bytes = len(body.encode("utf-8"))
    return {
        "ok": True, "checked_at_ms": int(time.time() * 1000),
        "occ_key": rec["occ_key"], "tool": rtool.lower(), "tool_call_id": rec.get("tool_call_id"),
        "pane_birth": rec.get("pane_birth"), "native_session": rec.get("native_session"),
        "payload_sha256": full, "input_digest": digest,
        "approval_request_id": rec.get("approval_request_id"),
        "core_arguments_digest": rec.get("core_arguments_digest"),
        "binding_protocol": rec.get("binding_protocol"),
        "command": (inp.get("command", "") if isinstance(inp, dict) else "") if rtool.lower() in ("bash", "shell") else None,
        "raw_targets": raw_targets, "targets": targets, "body_bytes": body_bytes,
        "body": body, "review_text": f"{header} {label}: " + " ".join(body.split()),
        # What shared stores (events, approvals.command) may carry: no raw body.
        "audit_text": f"{header} [complete payload sha256 {full}, {body_bytes} bytes]",
    }


def resolve_exact_pending(db_path: str, *, run_id: str, task_id: str, pane_id: str, pane_birth: str,
                          tool: str = "", screen_prompt_id: str = "") -> dict:
    """herdr-control security review Finding 1: the automated (non-human)
    write/edit approval gate must select which occurrence to authorize by
    its OWN OMP v1 request id, recorded at `seen` time, never by matching
    the painted screen's prompt id -- a screen-id-only lookup can credit an
    unreviewed occurrence's payload to a DIFFERENT, still-live painted
    panel (e.g. one whose own screen write never landed). This returns the
    one occurrence the automated gate may hand to proposal_check's
    bound_lookup branch; it never itself verifies the payload -- that
    re-check still runs, keyed to the exact ids returned here.

    screen_prompt_id, if given, is only a CROSS-CHECK: the screen-correlated
    lookup (same matching proposal_check's non-bound branch uses) must
    either find nothing, or agree with the exact occurrence found here.
    Disagreement, or more than one pending bound write/edit occurrence in
    this pane's scope, refuses -- there is no safe default to guess with."""
    def no(reason: str) -> dict:
        return {"ok": False, "reason": reason}

    folded = fold_task(db_path, run_id, task_id)
    if not isinstance(folded, dict) or "error" in folded:
        return no(f"occurrence registry unreadable: {folded.get('error') if isinstance(folded, dict) else folded}")
    bound = [r for r in folded.values()
             if r.get("pane_id") == pane_id
             and (not pane_birth or r.get("pane_birth") == pane_birth)
             and r.get("lifecycle") == "requested"
             and str(r.get("tool") or "").lower() in PROPOSAL_TOOLS
             and (not tool or str(r.get("tool") or "").lower() == tool.lower())
             and r.get("binding_protocol") == "omp.tool-approval-binding.v1"
             and r.get("approval_request_id")]
    if not bound:
        return no("no bound write/edit occurrence is pending for this pane -- exact resolution unavailable")
    if len(bound) != 1:
        return no("more than one pending bound write/edit occurrence in this pane -- ambiguous, refusing")
    rec = bound[0]
    if screen_prompt_id:
        screen_matches = [r for r in folded.values()
                          if r.get("pane_id") == pane_id and r.get("screen_prompt_id") == screen_prompt_id]
        if len(screen_matches) > 1:
            return no("more than one occurrence claims the prompt on screen -- ambiguous, refusing")
        if screen_matches and screen_matches[0].get("occ_key") != rec.get("occ_key"):
            return no("the screen-correlated occurrence disagrees with the exact bound occurrence -- refusing")
    return {"ok": True, "occ_key": rec["occ_key"], "approval_request_id": rec.get("approval_request_id"),
            "core_arguments_digest": rec.get("core_arguments_digest"), "tool_call_id": rec.get("tool_call_id"),
            "tool": rec.get("tool")}


def _format_show(out: dict) -> str:
    if not out.get("ok"):
        return f"REFUSED: {out.get('reason')}\n"
    return (f"tool: {out['tool']}\ntargets: {' '.join(out['targets'])}\n"
            f"payload_sha256: {out['payload_sha256']}\nbytes: {out['body_bytes']}\n"
            f"approval: human-only (#277); --expect-sha {out['payload_sha256']} confirms this payload is unchanged\n"
            f"----- complete payload -----\n{out['body']}\n----- end payload -----\n")


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
    # `-` reads the JSON from stdin, keeping write/edit content out of argv (ps).
    s.add_argument("--input-json", default=None)
    s.add_argument("--source", default="")
    s.add_argument("--cwd", default="")
    s.add_argument("--dispatched-at-ms", type=int, default=None)
    s.add_argument("--approval-request-id", default="")
    s.add_argument("--core-arguments-digest", default="")
    s.add_argument("--binding-protocol", default="")
    s.add_argument("--bound-envelope", action="store_true")

    s = sub.add_parser("screen")
    _add_identity_args(s)
    s.add_argument("--display", required=True)
    s.add_argument("--prompt-id", dest="screen_prompt_id", default="")

    s = sub.add_parser("authorized")
    _add_identity_args(s)
    s.add_argument("--decided-by", default="")
    s.add_argument("--choice", default="")

    s = sub.add_parser("authorize-bound")
    _add_identity_args(s)
    for name in ("approval-request-id", "core-arguments-digest", "worktree", "conductor-pane",
                 "conductor-birth", "approval-id", "choice", "authority", "decided-by", "review-reason",
                 "review-category", "reviewer", "audit-text", "expect-payload-sha"):
        s.add_argument("--" + name, required=True)

    for name in ("completed", "declined", "withdrawn"):
        s = sub.add_parser(name)
        _add_identity_args(s)
        if name == "completed":
            s.add_argument("--is-error", action="store_true")
        else:
            s.add_argument("--reason", default="")

    s = sub.add_parser("started")
    _add_identity_args(s)

    s = sub.add_parser("state")
    _add_identity_args(s)

    s = sub.add_parser("proposal")
    s.add_argument("--db", required=True)
    s.add_argument("--run", dest="run_id", required=True)
    s.add_argument("--task", dest="task_id", required=True)
    s.add_argument("--pane", dest="pane_id", required=True)
    s.add_argument("--birth", dest="pane_birth", default="")
    s.add_argument("--prompt-id", dest="screen_prompt_id", default="")
    s.add_argument("--worktree", required=True)
    s.add_argument("--tool", default="")
    s.add_argument("--expect-sha", default="")
    s.add_argument("--approval-request-id", default="")
    s.add_argument("--expect-arguments-digest", default="")
    s.add_argument("--expect-tool-call-id", default="")
    s.add_argument("--show", action="store_true")

    s = sub.add_parser("pending-bound")
    s.add_argument("--db", required=True)
    s.add_argument("--run", dest="run_id", required=True)
    s.add_argument("--task", dest="task_id", required=True)
    s.add_argument("--pane", dest="pane_id", required=True)
    s.add_argument("--birth", dest="pane_birth", default="")
    s.add_argument("--tool", default="")
    s.add_argument("--prompt-id", dest="screen_prompt_id", default="")

    s = sub.add_parser("fold")
    s.add_argument("--db", required=True)
    s.add_argument("--run", dest="run_id", required=True)
    s.add_argument("--task", dest="task_id", required=True)

    args = ap.parse_args(argv)
    try:
        if args.cmd == "seen":
            core_arguments_json = ""
            if args.input_json is None:
                tool_input = None
            else:
                try:
                    raw_input = sys.stdin.read() if args.input_json == "-" else args.input_json
                    parsed_input = json.loads(raw_input)
                    if args.bound_envelope:
                        tool_input = parsed_input["input"]
                        core_arguments_json = parsed_input["core_arguments_json"]
                        if not isinstance(core_arguments_json, str):
                            raise ValueError("core arguments are not a string")
                    else:
                        tool_input = parsed_input
                except (KeyError, TypeError, ValueError):
                    print(json.dumps({"error": "malformed --input-json"}))
                    return 0
            out = record_seen(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                               pane_birth=args.pane_birth, native_session=args.native_session,
                               tool_call_id=args.tool_call_id, tool=args.tool, tool_input=tool_input,
                               source=args.source, cwd=args.cwd, dispatched_at_ms=args.dispatched_at_ms,
                               approval_request_id=args.approval_request_id,
                               core_arguments_digest=args.core_arguments_digest,
                               binding_protocol=args.binding_protocol,
                               core_arguments_json=core_arguments_json)
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
        elif args.cmd == "authorize-bound":
            out = authorize_bound(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                  pane_birth=args.pane_birth, native_session=args.native_session,
                                  tool_call_id=args.tool_call_id,
                                  approval_request_id=args.approval_request_id,
                                  core_arguments_digest=args.core_arguments_digest,
                                  worktree=args.worktree, conductor_pane=args.conductor_pane,
                                  conductor_birth=args.conductor_birth, approval_id=args.approval_id,
                                  choice=args.choice, authority=args.authority,
                                  decided_by=args.decided_by,
                                  review_reason=args.review_reason, review_category=args.review_category,
                                  reviewer=args.reviewer, audit_text=args.audit_text,
                                  expect_payload_sha=args.expect_payload_sha)
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
        elif args.cmd == "started":
            out = record_started(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                 pane_birth=args.pane_birth, native_session=args.native_session,
                                 tool_call_id=args.tool_call_id)
        elif args.cmd == "proposal":
            out = proposal_check(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                 pane_birth=args.pane_birth, screen_prompt_id=args.screen_prompt_id,
                                 worktree=args.worktree, tool=args.tool, expect_sha=args.expect_sha,
                                 approval_request_id=args.approval_request_id,
                                 expect_arguments_digest=args.expect_arguments_digest,
                                 expect_tool_call_id=args.expect_tool_call_id)
            if args.show:
                sys.stdout.write(_format_show(out))
                return 0
        elif args.cmd == "pending-bound":
            out = resolve_exact_pending(args.db, run_id=args.run_id, task_id=args.task_id,
                                        pane_id=args.pane_id, pane_birth=args.pane_birth,
                                        tool=args.tool, screen_prompt_id=args.screen_prompt_id)
        elif args.cmd == "state":
            out = occurrence_state(args.db, run_id=args.run_id, task_id=args.task_id, pane_id=args.pane_id,
                                    pane_birth=args.pane_birth, native_session=args.native_session,
                                    tool_call_id=args.tool_call_id)
        elif args.cmd == "fold":
            out = fold_task(args.db, args.run_id, args.task_id)
        else:
            out = {"error": f"unknown command {args.cmd}"}
    except Exception as exc:  # noqa: BLE001 — a monitoring CLI must never crash its caller
        out = {"error": str(exc)} if args.cmd != "proposal" else {"ok": False, "reason": f"error: {exc}"}
        if args.cmd == "proposal" and args.show:
            sys.stdout.write(_format_show(out))
            return 0
    print(json.dumps(out, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
