"""Is an approval for this (owner label, grant id) still on its way?

The 2026-11-01 race: the hub ticks the queue supervisor BEFORE the human's
approval has been issued as a grant. consume_standing then returns
`standing_missing`, which tick_lane treats as consumed-and-frozen
(`held_consumed`) -- permanently burning an item for a grant that was about to
exist. A caller that gets a *_missing refusal asks pending() first; when it is
True the item is left PENDING (a retry-safe hold) instead.

pending() only ever DELAYS: it converts one refusal into a non-consuming hold.
It can never authorise anything, so it reads the forms directory with a plain,
untrusted peek (the real trust root stays owner-dispatch-issue.py's
read_decision). A forged or stale form can at worst keep an item waiting for at
most its own approval window; it can not make an item run.

A form counts as pending when it names this label and grant id, in one of the
known approval protocols, and is
  * status "open" and not past its expires_at (still awaiting the human), or
  * status "answered" with decision "approve" and still inside the window the
    record itself declares (answered, not yet issued by consume-pending).
A declined, expired, withdrawn or cancelled form is never pending.
"""
from __future__ import annotations

import json
import os
import re

# owner-dispatch-issue.py's STANDING_PROTOCOL (a hyphenated script, not
# importable); verify-approval-pending.py asserts the two stay equal.
STANDING_PROTOCOL = "owner-dispatch-approval-standing/1"
WEEKLY_PROTOCOL = "owner-dispatch-approval-weekly/1"
WINDOW_KEY = {STANDING_PROTOCOL: "standing_window_s", WEEKLY_PROTOCOL: "envelope_window_s"}
_EMBED = re.compile(rb'<script type="application/json" id="owner-dispatch-approval">(.*?)</script>', re.S)
_MAX_BYTES = 256 * 1024


def _read(path: str) -> bytes | None:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        return os.read(fd, _MAX_BYTES + 1)[:_MAX_BYTES]
    except OSError:
        return None
    finally:
        os.close(fd)


def pending(forms_dir: str, label: str, auth_id: str, now: float, protocols=tuple(WINDOW_KEY)) -> bool:
    try:
        names = [n for n in os.listdir(forms_dir) if n.endswith(".json")]
    except OSError:
        return False
    for name in names:
        raw = _read(os.path.join(forms_dir, name))
        html = _read(os.path.join(forms_dir, name[:-5] + ".html"))
        if raw is None or html is None:
            continue
        try:
            row = json.loads(raw)
            found = _EMBED.findall(html)
            peek = json.loads(found[0]) if len(found) == 1 else None
        except ValueError:
            continue
        if (not isinstance(row, dict) or not isinstance(peek, dict) or peek.get("protocol") not in protocols
                or peek.get("owner_label") != label or peek.get("auth_id") != auth_id):
            continue
        status = row.get("status")
        if status == "open":
            exp = row.get("expires_at")
            if exp is None or (isinstance(exp, (int, float)) and exp / 1000.0 > now):
                return True
        elif status == "answered":
            ans, at = row.get("answers"), row.get("answered_at")
            win = peek.get(WINDOW_KEY[peek["protocol"]])
            if (isinstance(ans, dict) and ans.get("decision") == "approve" and type(at) is int
                    and type(win) is int and at / 1000.0 + win > now):
                return True
    return False
