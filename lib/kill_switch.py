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
