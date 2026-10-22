#!/usr/bin/env python3
"""Run one argv command in its own process group with a hard deadline.

usage: bounded-run.py <seconds> <outfile> -- <argv...>

stdin is /dev/null; stdout+stderr go to <outfile>. No shell is involved.
Exit status:
  the command's own status when it finishes in time;
  124  deadline hit, and the WHOLE process group was confirmed gone;
  125  the group could not be confirmed gone (caller must keep temp roots and fail);
  2    usage error.
On deadline: killpg TERM -> bounded grace -> killpg KILL -> bounded leader reap
-> bounded wait until killpg(pgid, 0) reports no such group.
Only the group this helper created is ever signalled.
"""
import os
import signal
import subprocess
import sys
import time

GRACE_S = 2.0
REAP_S = 5.0
GONE_S = 5.0


def group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_gone(pgid: int, limit: float) -> bool:
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if not group_alive(pgid):
            return True
        time.sleep(0.05)
    return not group_alive(pgid)


def main(argv: list[str]) -> int:
    if len(argv) < 4 or argv[2] != "--":
        print("usage: bounded-run.py <seconds> <outfile> -- <argv...>", file=sys.stderr)
        return 2
    deadline_s, outfile, cmd = float(argv[0]), argv[1], argv[3:]
    with open(outfile, "wb") as out, open(os.devnull, "rb") as devnull:
        proc = subprocess.Popen(cmd, stdin=devnull, stdout=out, stderr=subprocess.STDOUT,
                                start_new_session=True, close_fds=True)
    pgid = proc.pid  # start_new_session: the leader's pid is the new group id
    try:
        rc = proc.wait(timeout=deadline_s)
    except subprocess.TimeoutExpired:
        rc = None
    if rc is not None:
        # Finished in time and the leader is already REAPED, so its pid (= our
        # pgid) may be reused: never signal the group now. Survivors -> 125 and
        # the caller retains its temp roots. (Zombie members also read as
        # alive; 125/retention is the safe answer for them too.)
        if group_alive(pgid):
            print(f"bounded-run: leader exited but group {pgid} still has members; not signalling after reap", file=sys.stderr)
            return 125
        return rc
    # Deadline hit. The leader is NOT reaped (wait raised TimeoutExpired), so
    # its pid, and therefore the pgid, stays reserved, even as a zombie, until
    # we reap it. Every group signal happens before that reap.
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    time.sleep(GRACE_S)  # grace with no poll/wait: nothing reaps the leader here
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=REAP_S)  # first and only reap of the leader
    except subprocess.TimeoutExpired:
        print(f"bounded-run: leader {pgid} not reaped within {REAP_S}s", file=sys.stderr)
        return 125
    # Post-reap: signal 0 only. A reused pgid would read as alive -> 125 (safe).
    if not wait_gone(pgid, GONE_S):
        print(f"bounded-run: process group {pgid} not confirmed gone", file=sys.stderr)
        return 125
    return 124


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
