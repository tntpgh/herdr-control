#!/usr/bin/env python3
"""Emit actual receiver acknowledgements for the Worker's offline integration test.

Reads one issued command from stdin. Uses synthetic protected-row states and
pure tasks._receipt_ack; no files, registry, subprocesses or services are touched.
"""
import json
import sys
from pathlib import Path

import tasks


def acknowledgements(command):
    claims = json.loads(command["authorization"]["claims"])
    root = Path("/fixture/repos") / command["payload"]["repo"]
    branch = "remote/" + command["remote_task_id"].rsplit("_", 1)[-1]
    tasks.WT_ROOT = Path("/fixture/worktrees")
    source = {"command_id": command["command_id"], "remote_task_id": command["remote_task_id"],
              "source_repo": claims["repo"], "claims": claims, "payload_sha256": claims["payload_sha256"],
              "status": "accepted", "repo": claims["repo"], "deadline_at": "2026-01-01T01:00:00Z"}
    bound = {**source, "task_id": "task_fixture", "run_id": "run_fixture", "repo": str(root),
             "worktree": str(tasks.WT_ROOT / root.name / branch), "branch": branch,
             "pane_id": "pane_fixture", "pane_birth": "birth_fixture"}
    return {"accepted_receipt": tasks._receipt_ack(command, source, root, branch),
            **{status: tasks._receipt_ack(command, {**bound, "status": status}, root, branch)
               for status in ("bound", "launch_claimed", "launched")}}


if __name__ == "__main__":
    print(json.dumps(acknowledgements(json.load(sys.stdin)), sort_keys=True))
