"""lib/kill_switch.py — the one-file stop check, shared by every caller that
must refuse rather than guess when a revocation marker is unreadable.

Extracted from queue-supervisor.py's own `kill_switch_engaged` (same logic,
same fail-closed-on-unreadable semantics, moved here so a second caller
(owner-dispatch-issue.py's `consume-pending`) does not re-implement it and
risk drifting from the original -- a lesson already paid for once in this
repo (lib/agent-profiles.sh exists because the agent-name list had already
been copy-pasted into three scripts and diverged).
"""
from __future__ import annotations

import os
import re


def engaged(path) -> bool:
    """Present, or unknowable (any lstat error but ENOENT) -> engaged: an
    unreadable state dir never reads as 'switch off'."""
    try:
        os.lstat(path)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


# Per-envelope revocation markers (owner-dispatch-approval-weekly/1). One file
# per envelope auth_id under ONE pinned directory, never read from env (a
# caller cannot point it elsewhere); tests rebind this module attribute. The
# file is the immediate, DB-independent stop: dispatch checks it inside the
# consume transaction, and `owner-dispatch-issue.py revoke-envelope` writes it
# BEFORE touching the auth store, so a locked or broken DB cannot delay a kill.
ENVELOPE_REVOKE_DIR = os.path.join(os.path.expanduser("~"), ".local", "state", "herdr", "owner-dispatch",
                                   "envelope-revoked")
_ENVELOPE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


def envelope_marker(auth_id) -> str | None:
    """The marker path for an envelope id, or None when the id could not be a
    legitimate envelope id (never joined into a path: a hostile queue item's
    auth_id cannot escape the directory)."""
    if not isinstance(auth_id, str) or not _ENVELOPE_ID.match(auth_id) or ".." in auth_id:
        return None
    return os.path.join(ENVELOPE_REVOKE_DIR, auth_id + ".revoked")


def envelope_revoked(auth_id) -> bool:
    """Marker present, unreadable, or an unusable id -> revoked (fail closed)."""
    marker = envelope_marker(auth_id)
    return True if marker is None else engaged(marker)
