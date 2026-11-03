"""lib/conductor_week_approval.py -- build-form/issue for the weekly
conductor authorization mint (docs/design/weekly-conductor-authorization.md
(h)). Mirrors owner-dispatch-issue.py's own protocol EXACTLY: `build-form`
is OFFLINE (reads nothing live but the caller's own identity, writes ONE
deterministic HTML page with the exact candidate record embedded as
<script type="application/json">, serves nothing, records nothing);
`formserve.py <that html file>` is what actually serves/answers it (T's own
existing tool, never reimplemented here); `issue` reads back ONLY an
ANSWERED, byte-identical-to-render_form() record and inserts the real grant
-- never the reverse order, same "the approval binds the record that was
on screen" trust root owner-dispatch-issue.py's own module docstring
states.

Storage target: task_authorizations via lib/task-authorization.py's own
accept_conductor_week (ALREADY built and reviewed clean, see
knowledge-base/review/ff-s2-8301f50/tmp/REVIEW-WEEKLY-BUILD-STATIC.md
section 1: "no correctness bugs found" in that file) -- this module adds
NO new SQLite table of its own; owner-dispatch-issue.py's own
owner_dispatch_auth/owner_dispatch_issuance tables are a DIFFERENT
protocol's shape (holder/lease/manifest columns with no conductor-week
analog) and are never repurposed here.

The older JSON preview/approve prototype was removed. This module and
grant-conductor-week-v2.sh are the only accepted weekly grant protocol.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

PROTOCOL = "conductor-weekly-authorization-approval/1"
CONDUCTOR_WEEK_LABELS = [
    "conductor",
    "thurber-os",
    "tntpgh-dev",
    "tourguide",
    "knowledge-base",
    "herdr-control",
]
CONDUCTOR_WEEK_TTL_MS = 168 * 60 * 60 * 1000      # 7 days, fixed -- never a caller choice
CONDUCTOR_HANDOVER_CAP = 10
CONFIRM_WINDOW_S = 3600                            # §(h) step 3.2, proposed CONFIRM_WINDOW_S
KEYS = {"protocol", "reason", "minting_marker", "minting_pane", "minting_pane_birth",
        "labels", "handover_cap", "issued_at", "expires_at", "weekend_spanning"}
FORM_ID = re.compile(r"^[0-9]{8}T[0-9]{6}-[0-9]{2,5}$")
EMBED = re.compile(rb'<script type="application/json" id="conductor-week-approval">(.*?)</script>', re.S)


class Refused(Exception):
    pass


def approval_bytes(rec: dict) -> bytes:
    """The ONE canonical serialization of an approval record."""
    return json.dumps(rec, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def _spans_weekend(issued_at_ms: int, expires_at_ms: int) -> bool:
    import datetime as dt
    d = dt.datetime.fromtimestamp(issued_at_ms / 1000, dt.timezone.utc).date()
    end = dt.datetime.fromtimestamp(expires_at_ms / 1000, dt.timezone.utc).date()
    while d <= end:
        if d.weekday() >= 5:  # Sat=5, Sun=6
            return True
        d += dt.timedelta(days=1)
    return False


def validate_approval(rec) -> dict:
    if not isinstance(rec, dict) or set(rec) != KEYS:
        raise Refused("approval_schema")
    if rec.get("protocol") != PROTOCOL:
        raise Refused("approval_protocol")
    if not isinstance(rec.get("reason"), str) or not rec["reason"].strip():
        raise Refused("approval_reason")
    for key in ("minting_marker", "minting_pane", "minting_pane_birth"):
        if not isinstance(rec.get(key), str):
            raise Refused(f"approval_{key}")
    if rec.get("labels") != CONDUCTOR_WEEK_LABELS:
        raise Refused("approval_labels")
    if rec.get("handover_cap") != CONDUCTOR_HANDOVER_CAP:
        raise Refused("approval_handover_cap")
    issued, expires = rec.get("issued_at"), rec.get("expires_at")
    if not isinstance(issued, int) or not isinstance(expires, int):
        raise Refused("approval_window_type")
    if expires - issued != CONDUCTOR_WEEK_TTL_MS:
        raise Refused("approval_window_ttl")
    if rec.get("weekend_spanning") != _spans_weekend(issued, expires):
        raise Refused("approval_weekend_flag")
    return rec


def render_form(rec: dict) -> bytes:
    """Deterministic decision page for ONE conductor-week mint. read_decision()
    accepts ONLY a stored page byte-identical to this rendering -- what was
    on screen is exactly the record (window, scope, caps, reason, minting
    identity), same discipline owner-dispatch-issue.py's own render_form
    uses (§(h): "nothing is hidden or deferred to after the fact")."""
    emb = approval_bytes(rec)
    sha = hashlib.sha256(emb).hexdigest()
    issued_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(rec["issued_at"] / 1000))
    expires_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(rec["expires_at"] / 1000))
    rows = [("Scope (labels)", ", ".join(rec["labels"])), ("Handover cap", str(rec["handover_cap"])),
            ("Issued at", issued_iso), ("Expires at", expires_iso),
            ("Weekend-spanning", "yes" if rec["weekend_spanning"] else "no"),
            ("Reason", rec["reason"]), ("Minting pane", rec["minting_pane"] or "(none -- outside herdr)"),
            ("Minting pane birth", rec["minting_pane_birth"] or "(none)"),
            ("Approval record sha256", sha)]
    esc = lambda v: str(v).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    table = "".join(f"<tr><th>{esc(k)}</th><td><code>{esc(v)}</code></td></tr>" for k, v in rows)
    intro = ('<p>Approving mints exactly ONE weekly conductor authorization for the window and scope below -- '
              'a human consent that the registry\'s live Main may act, unattended, within this window and cap, '
              'without a fresh daily ask. Nothing retries; a new week needs its own fresh build-form + approve.</p>')
    return (f'<!DOCTYPE html><html><head><meta charset="utf-8">'
            f'<title>Approve ONE weekly conductor authorization?</title></head><body>'
            f'<h1>Approve ONE weekly conductor authorization?</h1>'
            f'{intro}'
            f'<table>{table}</table>'
            f'<script type="application/json" id="conductor-week-approval">{emb.decode()}</script>'
            f'<button onclick="window.submitAnswers({{decision:\'approve\',approval_sha256:\'{sha}\'}})">Approve</button> '
            "<button onclick=\"window.submitAnswers({decision:'decline'})\">Decline</button>"
            "</body></html>").encode()


def read_decision(form_id: str, forms_dir) -> dict:
    """The answered formserve record + served HTML -> the approved record
    and its provenance. `forms_dir` is a pathlib.Path -- the caller's own
    pinned state root, never a caller-controlled argument."""
    if not isinstance(form_id, str) or not FORM_ID.match(form_id):
        raise Refused("form_id_malformed")
    try:
        row_bytes = (forms_dir / f"{form_id}.json").read_bytes()
        html = (forms_dir / f"{form_id}.html").read_bytes()
    except OSError:
        raise Refused("form_unreadable") from None
    try:
        row = json.loads(row_bytes)
    except ValueError:
        raise Refused("form_record_not_json") from None
    if not isinstance(row, dict) or row.get("id") != form_id or row.get("status") != "answered":
        raise Refused("form_not_answered")
    at = row.get("answered_at")
    if type(at) is not int or at <= 0:
        raise Refused("form_answered_at_missing")
    found = EMBED.findall(html)
    if len(found) != 1:
        raise Refused("form_html_no_single_embedded_approval")
    embedded = found[0]
    sha = hashlib.sha256(embedded).hexdigest()
    ans = row.get("answers")
    if not isinstance(ans, dict) or ans.get("decision") != "approve":
        raise Refused("form_not_approved")
    if ans.get("approval_sha256") != sha:
        raise Refused("form_answer_not_bound_to_displayed_record")
    try:
        rec = json.loads(embedded)
    except ValueError:
        raise Refused("approval_not_json") from None
    rec = validate_approval(rec)
    if approval_bytes(rec) != embedded or render_form(rec) != html:
        raise Refused("form_html_not_canonical_rendering")
    return {"rec": rec, "form_id": form_id, "answered_at": at / 1000.0}


def confirm_window_ok(dec: dict, now: float) -> None:
    """§(h) step 3.2 / §(g) item 21: an approval answered longer than
    CONFIRM_WINDOW_S ago is refused, forcing a fresh build-form + approve
    rather than redeeming a stale consent."""
    decided = dec["answered_at"]
    if decided > now + 60:
        raise Refused("approval_decided_in_future")
    if now - decided > CONFIRM_WINDOW_S:
        raise Refused("approval_confirmation_stale")


def registry_db() -> Path:
    # Same env var/path convention owner-lease-recover.py's own
    # registry_db() and lib/run-registry.sh's run_state_root() use
    # (HERDR_RUN_STATE_DIR) -- the task_authorizations grant row lives in
    # the registry, not a new store of this module's own.
    return Path(os.environ.get("HERDR_RUN_STATE_DIR", str(Path.home() / ".local/state/herdr/runs"))) / "registry.sqlite3"


def _task_authorization(op: str, *args: str) -> dict:
    """Subprocess call to lib/task-authorization.py -- the SAME adapter
    shape lib/run-registry.sh's own _task_authorization_adapter and
    owner-lease-recover.py's own _task_authorization use, never a third,
    parallel reimplementation of the storage layer."""
    helper = Path(__file__).resolve().parent / "task-authorization.py"
    try:
        out = subprocess.run([sys.executable, str(helper), str(registry_db()), op, *args],
                             capture_output=True, text=True, timeout=10)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise Refused(f"task_authorization_adapter_unreachable:{exc}") from exc
    if out.returncode != 0:
        reason = (out.stderr or "").strip() or "task_authorization_adapter_failed"
        raise Refused(reason)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError as exc:
        raise Refused(f"task_authorization_adapter_bad_output:{op}") from exc


def forms_dir() -> Path:
    # Same PINNED-but-env-overridable root formserve.py's own FORMS_DIR
    # reads (HERDR_STATE_ROOT) -- this is where T's own `formserve.py
    # <built.html>` run writes the answered <id>.json/<id>.html pair this
    # module's `issue` reads back.
    return Path(os.environ.get("HERDR_STATE_ROOT", str(Path.home() / ".local/state/herdr"))) / "forms"


def build_main(argv, minting_pane: str = "", minting_pane_birth: str = "", now: float | None = None) -> int:
    """OFFLINE: write the deterministic decision page for ONE weekly
    conductor-authorization mint. Serves nothing and records nothing --
    T separately runs `formserve.py <the written file>` to actually serve
    and answer it. --out must not already exist (O_EXCL): a build never
    silently overwrites a prior candidate."""
    ap = argparse.ArgumentParser(prog="conductor_week_approval.py build-form")
    ap.add_argument("--reason", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    if not a.reason.strip():
        print("refused:reason_required")
        return 2
    now_ms = int((now if now is not None else time.time()) * 1000)
    issued, expires = now_ms, now_ms + CONDUCTOR_WEEK_TTL_MS
    rec = {"protocol": PROTOCOL, "reason": a.reason, "minting_marker": minting_pane or "outside-herdr",
           "minting_pane": minting_pane, "minting_pane_birth": minting_pane_birth,
           "labels": CONDUCTOR_WEEK_LABELS, "handover_cap": CONDUCTOR_HANDOVER_CAP,
           "issued_at": issued, "expires_at": expires, "weekend_spanning": _spans_weekend(issued, expires)}
    try:
        validate_approval(rec)
    except Refused as exc:
        print(f"refused:{exc}")
        return 2
    html = render_form(rec)
    try:
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError as exc:
        print(f"refused:out_unwritable:{exc}")
        return 2
    with os.fdopen(fd, "wb") as f:
        f.write(html)
    issued_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(issued / 1000))
    expires_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(expires / 1000))
    print(f"built:{a.out}")
    print(f"  issued_at:  {issued_iso}")
    print(f"  expires_at: {expires_iso}")
    print(f"  scope:      labels={rec['labels']}")
    print(f"  caps:       handover_cap={rec['handover_cap']}")
    if rec["weekend_spanning"]:
        print("  WEEKEND-SPANNING: this window includes a Saturday or Sunday")
    print(f"  approval record sha256: {hashlib.sha256(approval_bytes(rec)).hexdigest()}")
    print(f"next: formserve.py {a.out}   # T answers it there")
    print(f"then: conductor_week_approval.py issue --confirm-form <form-id>")
    return 0


def issue_main(argv, now: float | None = None) -> int:
    """May run unattended -- authority already flows entirely from T's own
    form answer, the identical trust boundary owner-dispatch-issue.py's
    own issue step already relies on."""
    ap = argparse.ArgumentParser(prog="conductor_week_approval.py issue")
    ap.add_argument("--confirm-form", required=True, dest="confirm_form")
    a = ap.parse_args(argv)
    clock = now if now is not None else time.time()
    try:
        dec = read_decision(a.confirm_form, forms_dir())
        confirm_window_ok(dec, clock)
    except Refused as exc:
        print(f"refused:{exc}")
        return 2
    rec = dec["rec"]
    try:
        redeemable_command_id = f"conductor_week_{dec['form_id']}"
        grant = _task_authorization("accept-conductor-week", redeemable_command_id,
                                    rec["minting_marker"], rec["reason"],
                                    str(rec["issued_at"]), str(rec["expires_at"]))
    except Refused as exc:
        print(f"refused:{exc}")
        return 2
    print(f"issued:{grant.get('command_id', redeemable_command_id)}")
    print(json.dumps(grant, indent=2, sort_keys=True))
    return 0


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        print("usage: conductor_week_approval.py build-form --reason \"<text>\" --out <path.html> | issue --confirm-form <id>",
              file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "build-form":
        return build_main(rest, minting_pane=os.environ.get("_CONDUCTOR_WEEK_MINTING_PANE", ""),
                          minting_pane_birth=os.environ.get("_CONDUCTOR_WEEK_MINTING_PANE_BIRTH", ""))
    if cmd == "issue":
        return issue_main(rest)
    print(f"conductor_week_approval.py: unrecognized subcommand {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
