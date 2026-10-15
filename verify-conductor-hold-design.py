#!/usr/bin/env python3
"""Executable, non-operative model for task-scoped approval holds."""
from __future__ import annotations

from dataclasses import dataclass, replace

AUTOMATIC = {"peer", "scope", "file", "grant", "bound-peer"}
HOLD_SCOPES = {"remote-publication", "all-automatic-approvals"}
ACTION_SCOPES = {"remote-publication", "local-read", "local-build", "branch-work"}


@dataclass(frozen=True)
class Hold:
    task: str
    pane_birth: str
    scope: str
    released: bool = False
    kind: str = "durable"
    expires_at: int | None = None

    def __post_init__(self) -> None:
        if self.scope not in HOLD_SCOPES:
            raise ValueError("unknown hold scope")


def deny_publication(*, task: str, pane_birth: str, action_scope: str,
                     authority: str, now: int) -> Hold | None:
    if authority != "human" or action_scope != "remote-publication":
        return None
    return Hold(task, pane_birth, "remote-publication", kind="deny-fence",
                expires_at=now + 30 * 60)


def may_auto(*, task: str, pane_birth: str, authority: str,
             action_scope: str, hold: Hold | None, now: int = 0) -> bool:
    if authority not in AUTOMATIC:
        return False
    if hold is None or hold.released or (hold.expires_at is not None and now >= hold.expires_at):
        return True
    if (hold.task, hold.pane_birth) != (task, pane_birth):
        return True
    if action_scope not in ACTION_SCOPES:
        return False
    return not (hold.scope == "all-automatic-approvals" or hold.scope == action_scope)


def release(hold: Hold, *, task: str, pane_birth: str, authority: str,
            actor: str, registered_conductor: str, conductor_live: bool,
            reviewed: bool, reason: str, combined_with_approval: bool) -> Hold:
    if combined_with_approval or not reason.strip():
        raise PermissionError("release must be separate and reasoned")
    if (task, pane_birth) != (hold.task, hold.pane_birth):
        raise PermissionError("release identity mismatch")
    if authority == "human":
        return replace(hold, released=True)
    if not (authority == "conductor" and actor == registered_conductor
            and conductor_live and reviewed):
        raise PermissionError("release authority mismatch")
    return replace(hold, released=True)


def check(name: str, value: bool) -> None:
    if not value:
        raise AssertionError(name)
    print(f"ok {name}")


h = Hold("task-1", "birth-1", "remote-publication")
for route in sorted(AUTOMATIC):
    check(f"hold wins over {route}", not may_auto(
        task="task-1", pane_birth="birth-1", authority=route,
        action_scope="remote-publication", hold=h))

fence = deny_publication(task="task-1", pane_birth="birth-1",
                         action_scope="remote-publication", authority="human", now=100)
check("human denial acquires bounded publication fence", fence is not None)
check("rewritten body command and prompt id cannot bypass fence", not may_auto(
    task="task-1", pane_birth="birth-1", authority="peer",
    action_scope="remote-publication", hold=fence, now=101))
check("denial fence expires", may_auto(task="task-1", pane_birth="birth-1",
    authority="peer", action_scope="remote-publication", hold=fence, now=1900))
check("unrelated local read remains eligible", may_auto(task="task-1",
    pane_birth="birth-1", authority="peer", action_scope="local-read", hold=h))
check("another task is not held", may_auto(task="task-2", pane_birth="birth-2",
    authority="peer", action_scope="remote-publication", hold=h))
check("recycled birth does not inherit hold", may_auto(task="task-1",
    pane_birth="birth-2", authority="peer", action_scope="remote-publication", hold=h))
check("unknown action classification fails closed", not may_auto(task="task-1",
    pane_birth="birth-1", authority="peer", action_scope="unknown", hold=h))

all_hold = Hold("task-1", "birth-1", "all-automatic-approvals")
for scope in sorted(ACTION_SCOPES):
    check(f"all-automatic hold blocks {scope}", not may_auto(task="task-1",
        pane_birth="birth-1", authority="bound-peer", action_scope=scope, hold=all_hold))

released = release(h, task="task-1", pane_birth="birth-1", authority="conductor",
    actor="main", registered_conductor="main", conductor_live=True, reviewed=True,
    reason="revised artifact accepted", combined_with_approval=False)
check("reviewed live conductor release restores ordinary policy", may_auto(
    task="task-1", pane_birth="birth-1", authority="peer",
    action_scope="remote-publication", hold=released))
check("unknown authority is never broadened", not may_auto(task="task-1",
    pane_birth="birth-1", authority="mystery", action_scope="local-read", hold=None))

try:
    Hold("task-1", "birth-1", "typo")
except ValueError:
    check("invalid hold scope is rejected", True)
else:
    check("invalid hold scope is rejected", False)

for name, changes in {
    "peer cannot release": {"authority": "peer"},
    "wrong task cannot release": {"task": "task-2"},
    "wrong birth cannot release": {"pane_birth": "birth-2"},
    "stale conductor cannot release": {"conductor_live": False},
    "unreviewed conductor cannot release": {"reviewed": False},
    "empty reason cannot release": {"reason": ""},
    "release cannot combine with approval": {"combined_with_approval": True},
}.items():
    args = dict(task="task-1", pane_birth="birth-1", authority="conductor",
                actor="main", registered_conductor="main", conductor_live=True,
                reviewed=True, reason="accepted", combined_with_approval=False)
    args.update(changes)
    try:
        release(h, **args)
    except PermissionError:
        check(name, True)
    else:
        check(name, False)
