"""lib/conductor_week_form.py -- the preview/approve/issue mechanism
grant-conductor-week.sh build/approve/issue wraps (docs/design/weekly-
conductor-authorization.md (h)).

Reuses lib/record_store.py's claim-once atomic file update -- the SAME
primitive formserve.py/hub.py use for every other local decision record --
instead of formserve.py's own HTTP-server form. A weekly, T-run-by-hand mint
has no need for a served page/browser tab; it needs exactly the property
record_store gives for free: insert can never happen before display, by
construction, because `build` writes ONLY this preview file (zero
task_authorizations rows, enforced structurally -- this module never imports
or calls anything in lib/task-authorization.py), and `issue` can only ever
act on a file that `approve` already flipped to "answered" under the same
exclusive-lock claim-once discipline every other formserve-gated decision
uses, with a fresh digest recompute refusing any hand-edited tamper and a
CONFIRM_WINDOW_MS staleness cap refusing a stale approval.

Scope note: this is a simpler, self-contained preview/approve file --not--
formserve.py's HTML-serving/hub-rendering path. The record shape
(status/answered_at/answers) deliberately matches that vocabulary so wiring
a real hub surface onto it later is additive, not a rewrite; this build pass
does not attempt that wiring (grant-conductor-week.sh's `build`/`approve`/
`issue` are plain CLI subcommands T runs by hand, not a served page).
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import secrets
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE / "lib"))

import record_store as rs  # noqa: E402

CONDUCTOR_WEEK_LABEL = "conductor"
CONDUCTOR_WEEK_TTL_MS = 120 * 60 * 60 * 1000       # 120h, fixed -- never a caller choice
CONDUCTOR_HANDOVER_CAP = 10
CONFIRM_WINDOW_MS = 60 * 60 * 1000                 # issue must land within 1h of the previewed build


def forms_dir() -> Path:
    # Same PINNED-but-env-overridable root formserve.py/owner-lease-
    # recover.py both read (HERDR_STATE_ROOT) -- never any other
    # argument-controlled path.
    return Path(os.environ.get("HERDR_STATE_ROOT", str(Path.home() / ".local/state/herdr"))) / "forms"


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _preview_fields(issued_at_ms: int, expires_at_ms: int, reason: str, minting_marker: str) -> dict:
    return {
        "labels": [CONDUCTOR_WEEK_LABEL], "handover_cap": CONDUCTOR_HANDOVER_CAP,
        "issued_at": issued_at_ms, "expires_at": expires_at_ms,
        "reason": reason, "minting_marker": minting_marker,
    }


def _spans_weekend(issued_at_ms: int, expires_at_ms: int) -> bool:
    d = dt.datetime.fromtimestamp(issued_at_ms / 1000, dt.timezone.utc).date()
    end = dt.datetime.fromtimestamp(expires_at_ms / 1000, dt.timezone.utc).date()
    while d <= end:
        if d.weekday() >= 5:  # Sat=5, Sun=6
            return True
        d += dt.timedelta(days=1)
    return False


def build(reason: str, minting_marker: str, now_ms: int | None = None) -> dict:
    """Writes ONLY this preview file. The window/scope/cap are computed
    HERE, once, and never recomputed at `issue` time -- issue reads back
    exactly these previewed values, never a later `now()`."""
    if not reason or not reason.strip():
        raise ValueError("reason is required")
    now_ms = now_ms if now_ms is not None else int(time.time() * 1000)
    issued_at, expires_at = now_ms, now_ms + CONDUCTOR_WEEK_TTL_MS
    fields = _preview_fields(issued_at, expires_at, reason, minting_marker)
    form_id = "conductor-week-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now_ms / 1000)) + "-" + secrets.token_hex(4)
    row = {
        "id": form_id, "kind": "conductor_weekly_authorization_preview",
        "status": "open", "created_at": now_ms, "expires_at": expires_at,
        "fields": fields, "digest": digest(canonical(fields)),
        "weekend_spanning": _spans_weekend(issued_at, expires_at),
        "answers": None, "answered_at": None,
    }
    fdir = forms_dir()
    fdir.mkdir(parents=True, exist_ok=True)
    path = fdir / f"{form_id}.json"
    rs.write_atomic(path, row)
    return row


def read(form_id: str) -> dict | None:
    try:
        return json.loads((forms_dir() / f"{form_id}.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def approve(form_id: str, now_ms: int | None = None) -> dict:
    """Flips status open -> answered under the SAME claim-once discipline
    formserve.py/hub.py use -- a second approve attempt sees NotClaimable
    (lib/record_store.py) and loses cleanly, never double-answers."""
    now_ms = now_ms if now_ms is not None else int(time.time() * 1000)
    path = forms_dir() / f"{form_id}.json"

    def _apply(row: dict) -> dict:
        row["status"] = "answered"
        row["answered_at"] = now_ms
        row["answers"] = {"decision": "approve"}
        return row

    return rs.claim_and_update(path, _apply, require_status="open")


def issue_precheck(form_id: str, now_ms: int | None = None) -> tuple[dict | None, str | None]:
    """(row, refusal). Validates: file readable, right kind, status==
    'answered', decision=='approve', the STORED digest still matches a
    fresh recompute of `fields` (tamper check -- a hand-edited file after
    approval is refused, not trusted), and answered_at is within
    CONFIRM_WINDOW_MS of now -- a stale approval is refused rather than
    silently issued against a now-stale preview."""
    row = read(form_id)
    if row is None:
        return None, "form_unreadable"
    if row.get("kind") != "conductor_weekly_authorization_preview":
        return None, "form_wrong_kind"
    if row.get("status") != "answered":
        return None, "form_not_answered"
    answers = row.get("answers") or {}
    if answers.get("decision") != "approve":
        return None, "form_not_approved"
    fields = row.get("fields") or {}
    if digest(canonical(fields)) != row.get("digest"):
        return None, "form_tampered"
    answered_at = row.get("answered_at")
    if not isinstance(answered_at, int):
        return None, "form_missing_answered_at"
    now_ms = now_ms if now_ms is not None else int(time.time() * 1000)
    if now_ms - answered_at > CONFIRM_WINDOW_MS:
        return None, "form_confirmation_stale"
    return row, None
