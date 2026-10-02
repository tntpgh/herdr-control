#!/usr/bin/env python3
"""Real-registry e2e for tasks.py's command pipeline.

register_task() (lib/run-registry.sh), registry-bridge.sh's set-remote-id /
set-deadline / set-verified / cancel, and close-done-workers.sh all run for
REAL here, against a scratch HERDR_RUN_STATE_DIR -- proving tasks.py's SQL
assumptions match what lib/run-registry.sh's own v7 schema and migration
actually produce, which verify-tasks.py's hand-rolled fixture schema
(deliberately minimal, for speed) cannot catch. Uses the REAL
remote-mcp/task-allowlist.json, unmodified.

The only thing faked is spawn-task.sh's actual pane/tab/agent launch
(verify-tasks-e2e-fake-spawn.sh calls register_task() for real and writes a
real identity.json, then stops short of starting a real tab) -- a real
wrangler-dev + real publisher tick + real spawn-task.sh against a real repo
is SPEC.md Acceptance item 2, explicitly deferred to the conductor's own
live e2e (see .handoffs/PROOF.md).

    python3 remote-mcp/verify-tasks-e2e.py
"""
import json
import os
import shutil
import signal
import sqlite3
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp(prefix="herdr-tasks-e2e-"))

# Must be set before `import tasks`: its module-level constants read these
# once, at import time, exactly like the real publisher process does.
os.environ["HERDR_RUN_STATE_DIR"] = str(TMP / "runs")
os.environ["HERDR_WT_DIR"] = str(TMP / "worktrees")
os.environ["HERDR_CODE_DIR"] = str(TMP / "code")
os.environ["HERDR_MCP_TASKS"] = "1"
(TMP / "code/knowledge-base/.git").mkdir(parents=True)

sys.path.insert(0, str(HERE))
import tasks as tsk  # noqa: E402 (must follow the env vars above)

tsk.SPAWN_TASK = str(HERE / "verify-tasks-e2e-fake-spawn.sh")
# REGISTRY_BRIDGE and CLOSE_DONE are left at their real defaults
# (HERE/registry-bridge.sh, REPO/close-done-workers.sh) -- the whole point
# of this script versus verify-tasks.py's faked stand-ins for those two.

failures: list[str] = []


def check(label: str, cond: bool, detail: object = "") -> None:
    print(f"  {'ok  ' if cond else 'FAIL'}  {label}" + (f" -- {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(label)


def registry_row(task_id: str) -> dict | None:
    con = sqlite3.connect(tsk.REGISTRY)
    con.row_factory = sqlite3.Row
    row = con.execute("SELECT * FROM tasks WHERE task_id=?", (task_id,)).fetchone()
    con.close()
    return dict(row) if row else None


def restore_working_herdr_and_free_slot(fake_herdr_path: Path, log_path: Path, cmd_id: str,
                                         remote_task_id: str, local_task_id: str) -> None:
    """Each negative-outcome section below points `fake_herdr_path` (the
    single file on PATH all of them share) at a DIFFERENT broken `herdr`
    to prove its own failure mode. Left as-is, that broken fake leaks
    into whichever section runs next (R3-3's own real cancel needs a
    WORKING `herdr pane list`), and the section's own task -- correctly
    left non-terminal by the fix under test -- keeps holding one of the
    allowlist's 4 concurrent slots forever, starving every later start.
    Point `herdr pane list` at an always-empty, always-succeeding
    response (nothing of ours is in it, so registry-bridge.sh's cancel
    takes the "already gone" branch with no close needed) and cancel the
    section's task for real, freeing both the PATH and the slot before
    the next section assumes a clean slate."""
    log_path.write_text("")
    fake_herdr_path.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {log_path}
case "$1 $2" in
  "pane list") printf '{{"result":{{"panes":[]}}}}\\n'; exit 0 ;;
esac
exit 0
""")
    out = tsk.process_command({
        "command_id": cmd_id, "op": "cancel", "remote_task_id": remote_task_id,
        "payload": {"local_task_id": local_task_id, "reason": "test_cleanup"},
    })
    check(f"cleanup ({cmd_id}): task cancelled for real once the pane is confirmed gone "
          "(restores a working `herdr` and frees the concurrency slot for later sections)",
          out.get("outcome") == "accepted", json.dumps(out))


print("== start_task: real register_task() + real registry-bridge.sh set-remote-id/set-deadline ==")
out = tsk.process_command({
    "command_id": "cmd_1", "op": "start", "remote_task_id": "rtask_20261002T000001Z_e2e00001",
    "payload": {"repo": "knowledge-base", "mode": "research",
                "objective": "find the most recent tl;dv meeting in the KB and summarise it"},
})
check("start accepted", out.get("outcome") == "accepted", json.dumps(out))
task_id, run_id = out.get("local_task_id", ""), out.get("local_run_id", "")
row = registry_row(task_id) if task_id else None
check("registry row exists for real (schema v7, register_task())", row is not None)
if row:
    check("remote_task_id round-tripped through real registry-bridge.sh set-remote-id",
          row.get("remote_task_id") == "rtask_20261002T000001Z_e2e00001", row.get("remote_task_id"))
    check("deadline_at set by real registry-bridge.sh set-deadline", bool(row.get("deadline_at")))
    check("state is 'starting' immediately after register_task()", row.get("state") == "starting")

print("== sweep(): real close-done-workers.sh auto-closes a finished research task ==")
wt = Path(row["worktree"]) if row and row.get("worktree") else None
check("registry row carries a real worktree directory", bool(wt) and wt.is_dir(), row)
if wt:
    (wt / ".handoffs/ANSWER.md").write_text(
        "Found it: https://kb.teamthurber.com/entity/e2e-123 -- summary here.\n")
    (wt / ".handoffs/events.jsonl").write_text(
        json.dumps({"event": "e2e_done", "status": "completed", "reason": "no-follow-on"}) + "\n")
    t = {"task_id": task_id, "run_id": run_id, "state": "running", "worktree": str(wt)}
    actions = tsk.sweep({task_id: t}, datetime.now(timezone.utc))
    check("sweep() produced exactly one action", len(actions) == 1, str(actions))
    if actions:
        check("action is auto_close", actions[0]["action"] == "auto_close", str(actions[0]))
        check("real close-done-workers.sh --apply succeeded", actions[0]["ok"], actions[0]["detail"])
    row = registry_row(task_id)
    check("registry state is 'completed' after the real close-done-workers.sh ran",
          bool(row) and row.get("state") == "completed", row)

print("== a second task: real registry-bridge.sh cancel ==")
out2 = tsk.process_command({
    "command_id": "cmd_2", "op": "start", "remote_task_id": "rtask_20261002T000002Z_e2e00002",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "y"},
})
check("second start accepted", out2.get("outcome") == "accepted", json.dumps(out2))
task_id2 = out2.get("local_task_id", "")
cout = tsk.process_command({
    "command_id": "cmd_3", "op": "cancel", "remote_task_id": "rtask_20261002T000002Z_e2e00002",
    "payload": {"local_task_id": task_id2, "reason": "canceled"},
})
check("cancel accepted", cout.get("outcome") == "accepted", json.dumps(cout))
row2 = registry_row(task_id2)
check("registry state is 'cancelled' after the real registry-bridge.sh cancel ran",
      bool(row2) and row2.get("state") == "cancelled", row2)

print("== N5: real registry-bridge.sh cancel skips the pane close when `herdr pane list` itself fails ==")
fake_herdr_dir = TMP / "fake-herdr-bin"
fake_herdr_dir.mkdir()
fake_herdr_log = TMP / "fake-herdr-calls.log"
fake_herdr = fake_herdr_dir / "herdr"
fake_herdr.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {fake_herdr_log}
case "$1 $2" in
  "pane list") exit 1 ;;
esac
exit 0
""")
fake_herdr.chmod(0o755)
os.environ["PATH"] = f"{fake_herdr_dir}:{os.environ['PATH']}"
out3 = tsk.process_command({
    "command_id": "cmd_4", "op": "start", "remote_task_id": "rtask_20261002T000003Z_e2e00003",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "z"},
})
check("third start accepted", out3.get("outcome") == "accepted", json.dumps(out3))
task_id3 = out3.get("local_task_id", "")
cout3 = tsk.process_command({
    "command_id": "cmd_5", "op": "cancel", "remote_task_id": "rtask_20261002T000003Z_e2e00003",
    "payload": {"local_task_id": task_id3, "reason": "canceled"},
})
check("cancel FAILS (not accepted) when herdr pane list itself fails -- Z1: the row must never be marked cancelled on an unconfirmed pane",
      cout3.get("outcome") == "failed", json.dumps(cout3))
row3 = registry_row(task_id3)
check("registry state is NOT 'cancelled' (stays non-terminal for the next retry)",
      bool(row3) and row3.get("state") != "cancelled", row3)
herdr_calls = fake_herdr_log.read_text() if fake_herdr_log.exists() else ""
check("`herdr pane list` was attempted", "pane list" in herdr_calls, herdr_calls)
check("`herdr pane close` was NEVER attempted once `pane list` failed (N5, no fail-open)",
      "pane close" not in herdr_calls, herdr_calls)
restore_working_herdr_and_free_slot(fake_herdr, fake_herdr_log, "cmd_n5_cleanup",
                                     "rtask_20261002T000003Z_e2e00003", task_id3)


print("== R3-3: real registry-bridge.sh cancel refuses when the row's own remote_task_id does not match ==")
import subprocess  # noqa: E402 (test-only, added for this direct bridge call)
out4 = tsk.process_command({
    "command_id": "cmd_6", "op": "start", "remote_task_id": "rtask_20261002T000004Z_e2e00004",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "w"},
})
check("fourth start accepted", out4.get("outcome") == "accepted", json.dumps(out4))
task_id4, run_id4 = out4.get("local_task_id", ""), out4.get("local_run_id", "")
bridge_out = subprocess.run(
    [tsk.REGISTRY_BRIDGE, "cancel", run_id4, task_id4, "wrong_task_mismatch", "rtask_SOMEONE_ELSES_TASK"],
    capture_output=True, text=True)
check("registry-bridge.sh cancel exits nonzero on a remote_task_id mismatch", bridge_out.returncode != 0, bridge_out.stderr)
row4 = registry_row(task_id4)
check("registry state is untouched by the refused cancel (still starting/running, not cancelled)",
      bool(row4) and row4.get("state") != "cancelled", row4)
bridge_out2 = subprocess.run(
    [tsk.REGISTRY_BRIDGE, "cancel", run_id4, task_id4, "correct_match", "rtask_20261002T000004Z_e2e00004"],
    capture_output=True, text=True)
check("registry-bridge.sh cancel succeeds when the expected remote_task_id matches the row's own",
      bridge_out2.returncode == 0, bridge_out2.stderr)
row4b = registry_row(task_id4)
check("registry state is 'cancelled' once the remote_task_id actually matches",
      bool(row4b) and row4b.get("state") == "cancelled", row4b)
# This cancel went through registry-bridge.sh DIRECTLY (subprocess.run
# above), bypassing tasks.py's own _cancel() and the
# _kill_hard_stop_timer() call it makes on success -- a real gap only a
# test taking this out-of-band shortcut hits (production cancels always
# go through _cancel()); reap it here so this suite does not itself leak
# a ~62-minute sleep process.
tsk._kill_hard_stop_timer(run_id4, task_id4)

print("== R3-6: real registry-bridge.sh cancel skips the pane close when `herdr pane list` returns non-JSON with rc 0 ==")
fake_herdr2_log = TMP / "fake-herdr2-calls.log"
fake_herdr.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {fake_herdr2_log}
case "$1 $2" in
  "pane list") printf 'not json at all\\n'; exit 0 ;;
esac
exit 0
""")
out5 = tsk.process_command({
    "command_id": "cmd_7", "op": "start", "remote_task_id": "rtask_20261002T000005Z_e2e00005",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "v"},
})
check("fifth start accepted", out5.get("outcome") == "accepted", json.dumps(out5))
task_id5 = out5.get("local_task_id", "")
cout5 = tsk.process_command({
    "command_id": "cmd_8", "op": "cancel", "remote_task_id": "rtask_20261002T000005Z_e2e00005",
    "payload": {"local_task_id": task_id5, "reason": "canceled"},
})
check("cancel FAILS (not accepted) when `herdr pane list` returns rc=0 but non-JSON -- Z1: an unparseable list must never fail open",
      cout5.get("outcome") == "failed", json.dumps(cout5))
row5 = registry_row(task_id5)
check("registry state is NOT 'cancelled' when the pane list could not be parsed",
      bool(row5) and row5.get("state") != "cancelled", row5)
herdr2_calls = fake_herdr2_log.read_text() if fake_herdr2_log.exists() else ""
check("`herdr pane list` was attempted", "pane list" in herdr2_calls, herdr2_calls)
check("`herdr pane close` was NEVER attempted when jq could not parse a rc=0 list (R3-6, no fail-open)",
      "pane close" not in herdr2_calls, herdr2_calls)
restore_working_herdr_and_free_slot(fake_herdr, fake_herdr2_log, "cmd_r36_cleanup",
                                     "rtask_20261002T000005Z_e2e00005", task_id5)


print("== Z1: real registry-bridge.sh cancel fails (stays non-terminal) when `herdr pane close` itself fails ==")
fake_herdr3_log = TMP / "fake-herdr3-calls.log"
fake_herdr.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {fake_herdr3_log}
case "$1 $2" in
  "pane list") printf '{{"result":{{"panes":[{{"pane_id":"pane_e2e_fake","terminal_id":"birth_e2e_fake"}}]}}}}\\n'; exit 0 ;;
  "pane close") exit 1 ;;
esac
exit 0
""")
out6 = tsk.process_command({
    "command_id": "cmd_9", "op": "start", "remote_task_id": "rtask_20261002T000007Z_e2e00007",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "w"},
})
check("sixth start accepted", out6.get("outcome") == "accepted", json.dumps(out6))
task_id6 = out6.get("local_task_id", "")
cout6 = tsk.process_command({
    "command_id": "cmd_10", "op": "cancel", "remote_task_id": "rtask_20261002T000007Z_e2e00007",
    "payload": {"local_task_id": task_id6, "reason": "canceled"},
})
check("cancel fails when herdr pane close itself fails", cout6.get("outcome") == "failed", json.dumps(cout6))
row6 = registry_row(task_id6)
check("registry state is NOT 'cancelled' when the close failed (nothing of ours was actually confirmed gone)",
      bool(row6) and row6.get("state") != "cancelled", row6)
herdr3_calls = fake_herdr3_log.read_text() if fake_herdr3_log.exists() else ""
check("`herdr pane close` WAS attempted (the live pane matched the registered birth)", "pane close" in herdr3_calls, herdr3_calls)
restore_working_herdr_and_free_slot(fake_herdr, fake_herdr3_log, "cmd_z1a_cleanup",
                                     "rtask_20261002T000007Z_e2e00007", task_id6)


print("== Z1: real registry-bridge.sh cancel refuses to mark cancelled when the pane is STILL alive after close (no fail-open on a survivor) ==")
fake_herdr4_log = TMP / "fake-herdr4-calls.log"
fake_herdr.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {fake_herdr4_log}
case "$1 $2" in
  "pane list") printf '{{"result":{{"panes":[{{"pane_id":"pane_e2e_fake","terminal_id":"birth_e2e_fake"}}]}}}}\\n'; exit 0 ;;
  "pane close") exit 0 ;;
esac
exit 0
""")
out7 = tsk.process_command({
    "command_id": "cmd_11", "op": "start", "remote_task_id": "rtask_20261002T000008Z_e2e00008",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "u"},
})
check("seventh start accepted", out7.get("outcome") == "accepted", json.dumps(out7))
task_id7 = out7.get("local_task_id", "")
cout7 = tsk.process_command({
    "command_id": "cmd_12", "op": "cancel", "remote_task_id": "rtask_20261002T000008Z_e2e00008",
    "payload": {"local_task_id": task_id7, "reason": "canceled"},
})
check("cancel fails when the pane is STILL reported alive after close (fake herdr's close is a no-op on the fixture pane)",
      cout7.get("outcome") == "failed", json.dumps(cout7))
row7 = registry_row(task_id7)
check("registry state is NOT 'cancelled' when the post-close list still shows the SAME pane alive",
      bool(row7) and row7.get("state") != "cancelled", row7)
herdr4_calls = fake_herdr4_log.read_text() if fake_herdr4_log.exists() else ""
check("`herdr pane close` WAS attempted before the row was ever refused", "pane close" in herdr4_calls, herdr4_calls)
check("`herdr pane list` was called TWICE (once before the close, once after, to prove the pane survived it)",
      herdr4_calls.count("pane list") >= 2, herdr4_calls)
restore_working_herdr_and_free_slot(fake_herdr, fake_herdr4_log, "cmd_z1b_cleanup",
                                     "rtask_20261002T000008Z_e2e00008", task_id7)

print("== F2: real registry-bridge.sh cancel on an already-terminal row refuses BEFORE touching any pane ==")
out_f2 = tsk.process_command({
    "command_id": "cmd_f2", "op": "start", "remote_task_id": "rtask_20261002T000011Z_0000f2f2",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "f2"},
})
check("F2 start accepted", out_f2.get("outcome") == "accepted", json.dumps(out_f2))
task_id_f2, run_id_f2 = out_f2.get("local_task_id", ""), out_f2.get("local_run_id", "")
cout_f2_first = tsk.process_command({
    "command_id": "cmd_f2_cancel1", "op": "cancel", "remote_task_id": "rtask_20261002T000011Z_0000f2f2",
    "payload": {"local_task_id": task_id_f2, "reason": "canceled"},
})
check("F2 first cancel (real pane, real herdr fake) accepted", cout_f2_first.get("outcome") == "accepted", json.dumps(cout_f2_first))
fake_herdr_log.write_text("")  # restore_working_herdr_and_free_slot already left a working herdr on PATH
f2_second_argv = [tsk.REGISTRY_BRIDGE, "cancel", run_id_f2, task_id_f2, "second_cancel_attempt"]
bridge_out_f2_second = subprocess.run(f2_second_argv, capture_output=True, text=True)
check("R2-2: a SECOND cancel on an ALREADY-CANCELLED row is idempotent (exits 0, not an error)",
      bridge_out_f2_second.returncode == 0, bridge_out_f2_second.stderr)
check("F2: no `herdr pane list` or `pane close` call was ever made for the already-terminal row (refused before touching any pane)",
      fake_herdr_log.read_text().strip() == "", fake_herdr_log.read_text())
# F2's OWN refusal (a cancel that must NOT succeed) only still applies to
# completed/failed/lost, per R2-2 -- the very first task in this file
# auto-closed to 'completed' at the top and is still in scope.
fake_herdr_log.write_text("")
f2_completed_argv = [tsk.REGISTRY_BRIDGE, "cancel", run_id, task_id, "cancel_a_completed_task"]
bridge_out_f2_completed = subprocess.run(f2_completed_argv, capture_output=True, text=True)
check("F2: a cancel on a COMPLETED row (not idempotently-cancellable) still refuses and exits nonzero",
      bridge_out_f2_completed.returncode != 0, bridge_out_f2_completed.stderr)
check("F2: the refusal message says 'already terminal'", "already terminal" in bridge_out_f2_completed.stderr, bridge_out_f2_completed.stderr)
check("F2: no `herdr pane list` or `pane close` call was ever made for the completed row either",
      fake_herdr_log.read_text().strip() == "", fake_herdr_log.read_text())


print("== F1: real registry-bridge.sh cancel corroborates a terminal_id mismatch via agent_session (herdr restart case) ==")


def _set_agent_session(run_id: str, task_id: str, session: str) -> None:
    script = TMP / f"set-session-{task_id}.sh"
    script.write_text(f"""#!/usr/bin/env bash
set -euo pipefail
. "{HERE.parent}/lib/run-registry.sh"
set_task_agent_session {run_id} {task_id} {session}
""")
    script.chmod(0o755)
    out = subprocess.run(["bash", str(script)], capture_output=True, text=True)
    check(f"setup: agent_session stamped for {task_id}", out.returncode == 0, out.stderr)


fake_herdr_f1a_log = TMP / "fake-herdr-f1a-calls.log"
out_f1a = tsk.process_command({
    "command_id": "cmd_f1a", "op": "start", "remote_task_id": "rtask_20261002T000012Z_0000f1a1",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "f1a"},
})
check("F1a start accepted", out_f1a.get("outcome") == "accepted", json.dumps(out_f1a))
task_id_f1a, run_id_f1a = out_f1a.get("local_task_id", ""), out_f1a.get("local_run_id", "")
_set_agent_session(run_id_f1a, task_id_f1a, "/Users/thurbs/.omp/agent/sessions/f1a/session.jsonl")
# herdr restarted: same pane_id, a FRESH terminal_id (never equal to the
# registered pane_birth), but the SAME agent_session -- the underlying
# agent process survived (lib/reconcile.sh:139-142); this must corroborate
# as "still ours" and proceed to close.
fake_herdr.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {fake_herdr_f1a_log}
case "$1 $2" in
  "pane list") printf '{{"result":{{"panes":[{{"pane_id":"pane_e2e_fake","terminal_id":"fresh_after_restart","agent_session":{{"value":"/Users/thurbs/.omp/agent/sessions/f1a/session.jsonl"}}}}]}}}}\\n'; exit 0 ;;
  "pane close") exit 1 ;;
esac
exit 0
""")
cout_f1a = tsk.process_command({
    "command_id": "cmd_f1a_cancel", "op": "cancel", "remote_task_id": "rtask_20261002T000012Z_0000f1a1",
    "payload": {"local_task_id": task_id_f1a, "reason": "canceled"},
})
f1a_calls = fake_herdr_f1a_log.read_text() if fake_herdr_f1a_log.exists() else ""
check("F1a: pane close WAS attempted (same agent_session corroborated 'still ours' despite the terminal_id mismatch)",
      "pane close" in f1a_calls, f1a_calls)
check("F1a: cancel fails here only because this fixture's `pane close` itself fails (proves the match, not the close)",
      cout_f1a.get("outcome") == "failed", json.dumps(cout_f1a))
restore_working_herdr_and_free_slot(fake_herdr, fake_herdr_f1a_log, "cmd_f1a_cleanup",
                                     "rtask_20261002T000012Z_0000f1a1", task_id_f1a)

fake_herdr_f1b_log = TMP / "fake-herdr-f1b-calls.log"
out_f1b = tsk.process_command({
    "command_id": "cmd_f1b", "op": "start", "remote_task_id": "rtask_20261002T000013Z_0000f1b1",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "f1b"},
})
check("F1b start accepted", out_f1b.get("outcome") == "accepted", json.dumps(out_f1b))
task_id_f1b, run_id_f1b = out_f1b.get("local_task_id", ""), out_f1b.get("local_run_id", "")
_set_agent_session(run_id_f1b, task_id_f1b, "/Users/thurbs/.omp/agent/sessions/f1b/session.jsonl")
# A DIFFERENT occupant now reports this pane_id: different terminal_id AND
# a different agent_session -- two independent signals confirm our own
# pane is genuinely gone (recycled). Nothing of ours to close; proceeds
# straight to marking the row cancelled.
fake_herdr.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {fake_herdr_f1b_log}
case "$1 $2" in
  "pane list") printf '{{"result":{{"panes":[{{"pane_id":"pane_e2e_fake","terminal_id":"someone_elses_pane","agent_session":{{"value":"/Users/thurbs/.omp/agent/sessions/different-task/other.jsonl"}}}}]}}}}\\n'; exit 0 ;;
esac
exit 0
""")
cout_f1b = tsk.process_command({
    "command_id": "cmd_f1b_cancel", "op": "cancel", "remote_task_id": "rtask_20261002T000013Z_0000f1b1",
    "payload": {"local_task_id": task_id_f1b, "reason": "canceled"},
})
check("F1b: cancel SUCCEEDS when a disagreeing agent_session confirms a different occupant (nothing of ours to close)",
      cout_f1b.get("outcome") == "accepted", json.dumps(cout_f1b))
f1b_calls = fake_herdr_f1b_log.read_text() if fake_herdr_f1b_log.exists() else ""
check("F1b: `herdr pane close` was NEVER attempted (not our pane)", "pane close" not in f1b_calls, f1b_calls)
row_f1b = registry_row(task_id_f1b)
check("F1b: registry state is 'cancelled'", bool(row_f1b) and row_f1b.get("state") == "cancelled", row_f1b)

fake_herdr_f1c_log = TMP / "fake-herdr-f1c-calls.log"
out_f1c = tsk.process_command({
    "command_id": "cmd_f1c", "op": "start", "remote_task_id": "rtask_20261002T000014Z_0000f1c1",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "f1c"},
})
check("F1c start accepted", out_f1c.get("outcome") == "accepted", json.dumps(out_f1c))
task_id_f1c = out_f1c.get("local_task_id", "")
# agent_session was never stamped for this row (still empty) -- terminal_id
# differs and there is nothing to corroborate with on our own side. Must
# fail closed, never guess.
fake_herdr.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {fake_herdr_f1c_log}
case "$1 $2" in
  "pane list") printf '{{"result":{{"panes":[{{"pane_id":"pane_e2e_fake","terminal_id":"ambiguous_after_restart","agent_session":{{"value":"/Users/thurbs/.omp/agent/sessions/whoever/other.jsonl"}}}}]}}}}\\n'; exit 0 ;;
esac
exit 0
""")
cout_f1c = tsk.process_command({
    "command_id": "cmd_f1c_cancel", "op": "cancel", "remote_task_id": "rtask_20261002T000014Z_0000f1c1",
    "payload": {"local_task_id": task_id_f1c, "reason": "canceled"},
})
check("F1c: cancel FAILS when our own side has no agent_session to corroborate with (fail closed, never guess)",
      cout_f1c.get("outcome") == "failed", json.dumps(cout_f1c))
row_f1c = registry_row(task_id_f1c)
check("F1c: registry state is NOT 'cancelled' (stays non-terminal for the next retry)",
      bool(row_f1c) and row_f1c.get("state") != "cancelled", row_f1c)
restore_working_herdr_and_free_slot(fake_herdr, fake_herdr_f1c_log, "cmd_f1c_cleanup",
                                     "rtask_20261002T000014Z_0000f1c1", task_id_f1c)

print("== Fz: real registry-bridge.sh cancel treats a wrong-shaped-but-valid-JSON `herdr pane list` as UNPARSEABLE, never 'gone' ==")
fake_herdr_fza_log = TMP / "fake-herdr-fza-calls.log"
out_fza = tsk.process_command({
    "command_id": "cmd_fza", "op": "start", "remote_task_id": "rtask_20261002T000015Z_0000fda1",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "fza"},
})
check("Fz-a start accepted", out_fza.get("outcome") == "accepted", json.dumps(out_fza))
task_id_fza = out_fza.get("local_task_id", "")
# Valid JSON, but an error envelope -- no .result.panes/.panes array at all.
fake_herdr.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {fake_herdr_fza_log}
case "$1 $2" in
  "pane list") printf '{{"error":{{"code":"rate_limited","message":"slow down"}}}}\\n'; exit 0 ;;
esac
exit 0
""")
cout_fza = tsk.process_command({
    "command_id": "cmd_fza_cancel", "op": "cancel", "remote_task_id": "rtask_20261002T000015Z_0000fda1",
    "payload": {"local_task_id": task_id_fza, "reason": "canceled"},
})
check("Fz-a: cancel FAILS on a valid-JSON error envelope (never mistaken for an empty/gone list)",
      cout_fza.get("outcome") == "failed", json.dumps(cout_fza))
fza_calls = fake_herdr_fza_log.read_text() if fake_herdr_fza_log.exists() else ""
check("Fz-a: `herdr pane close` was NEVER attempted on an unparseable shape", "pane close" not in fza_calls, fza_calls)
restore_working_herdr_and_free_slot(fake_herdr, fake_herdr_fza_log, "cmd_fza_cleanup",
                                     "rtask_20261002T000015Z_0000fda1", task_id_fza)

fake_herdr_fzb_log = TMP / "fake-herdr-fzb-calls.log"
out_fzb = tsk.process_command({
    "command_id": "cmd_fzb", "op": "start", "remote_task_id": "rtask_20261002T000016Z_0000fdb1",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "fzb"},
})
check("Fz-b start accepted", out_fzb.get("outcome") == "accepted", json.dumps(out_fzb))
task_id_fzb = out_fzb.get("local_task_id", "")
# The pane_id MATCHES -- a real entry exists -- but that entry is missing
# terminal_id entirely. A pane we can SEE must never read as "gone".
fake_herdr.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {fake_herdr_fzb_log}
case "$1 $2" in
  "pane list") printf '{{"result":{{"panes":[{{"pane_id":"pane_e2e_fake","label":"renamed, no terminal_id field"}}]}}}}\\n'; exit 0 ;;
esac
exit 0
""")
cout_fzb = tsk.process_command({
    "command_id": "cmd_fzb_cancel", "op": "cancel", "remote_task_id": "rtask_20261002T000016Z_0000fdb1",
    "payload": {"local_task_id": task_id_fzb, "reason": "canceled"},
})
check("Fz-b: cancel FAILS when the matched pane entry is missing terminal_id (found-but-unreadable is never 'absent')",
      cout_fzb.get("outcome") == "failed", json.dumps(cout_fzb))
fzb_calls = fake_herdr_fzb_log.read_text() if fake_herdr_fzb_log.exists() else ""
check("Fz-b: `herdr pane close` was NEVER attempted (never confirmed as our own live pane, never confirmed gone either)",
      "pane close" not in fzb_calls, fzb_calls)
restore_working_herdr_and_free_slot(fake_herdr, fake_herdr_fzb_log, "cmd_fzb_cleanup",
                                     "rtask_20261002T000016Z_0000fdb1", task_id_fzb)

print("== R4-1: a spawn timeout BEFORE remote_task_id is ever stamped still gets the orphan cancelled (real registry-bridge.sh, real registry) ==")
# Mirrors spawn-task.sh's own real sequence: register_task() runs long
# before the caller ever calls set-remote-id -- a crash/timeout in that
# window must not bring back the pre-R3-3 orphan (M7/N1). _start derives
# worktree/branch from remote_task_id by a fixed formula, so both are
# precomputed here to match exactly what _start will itself compute.
remote_id_r41 = "rtask_20261002T000006Z_0000a41f"
run_id_r41, task_id_r41 = "run_r41", "task_r41"
branch_r41 = f"remote/{remote_id_r41.rsplit('_', 1)[-1]}"
wt_r41 = TMP / "worktrees" / "knowledge-base" / branch_r41
wt_r41.mkdir(parents=True)
reg_script = TMP / "register-r41.sh"
reg_script.write_text(f"""#!/usr/bin/env bash
set -euo pipefail
. "{HERE.parent}/lib/run-registry.sh"
register_task {run_id_r41} {task_id_r41} worker1 cond1 cpane1 cbirth1 pane_r41 birth_r41 \\
  knowledge-base {wt_r41} remote:r41 {branch_r41} main "" "" menu
""")
reg_script.chmod(0o755)


def _spawn_registers_then_times_out(root, branch, mcfg, brief):
    # Simulates spawn-task.sh: register the task for real (remote_task_id
    # stays empty, exactly as it is until a LATER set-remote-id call), then
    # hang/crash before ever returning or writing identity.json.
    reg_out = subprocess.run(["bash", str(reg_script)], capture_output=True, text=True)
    if reg_out.returncode != 0:
        raise RuntimeError(f"test setup: register_task failed: {reg_out.stderr}")
    raise subprocess.TimeoutExpired(cmd="spawn-task.sh", timeout=75)


old_spawn_fn = tsk._spawn
tsk._spawn = _spawn_registers_then_times_out
try:
    out_r41 = tsk.process_command({
        "command_id": "cmd_r41", "op": "start", "remote_task_id": remote_id_r41,
        "payload": {"repo": "knowledge-base", "mode": "research", "objective": "r41"},
    })
finally:
    tsk._spawn = old_spawn_fn
check("start returns failed (spawn timed out)", out_r41.get("outcome") == "failed", json.dumps(out_r41))
row_r41 = registry_row(task_id_r41)
check("the orphaned row (registered before the timeout, remote_task_id never stamped) IS cancelled",
      bool(row_r41) and row_r41.get("state") == "cancelled", row_r41)

print("== R4-1: real registry-bridge.sh cancel accepts an UNSTAMPED row (set-remote-id failure window) ==")
run_id_r41b, task_id_r41b = "run_r41b", "task_r41b"
branch_r41b = "remote/r41borphan"
wt_r41b = TMP / "worktrees" / "knowledge-base" / branch_r41b
wt_r41b.mkdir(parents=True)
reg_script_b = TMP / "register-r41b.sh"
reg_script_b.write_text(f"""#!/usr/bin/env bash
set -euo pipefail
. "{HERE.parent}/lib/run-registry.sh"
register_task {run_id_r41b} {task_id_r41b} worker1 cond1 cpane1 cbirth1 pane_r41b birth_r41b \\
  knowledge-base {wt_r41b} remote:r41b {branch_r41b} main "" "" menu
""")
reg_script_b.chmod(0o755)
reg_out_b = subprocess.run(["bash", str(reg_script_b)], capture_output=True, text=True)
check("setup: register_task for the never-stamped row succeeded", reg_out_b.returncode == 0, reg_out_b.stderr)
row_before = registry_row(task_id_r41b)
check("the freshly-registered row's remote_task_id is genuinely still empty", (row_before or {}).get("remote_task_id", "x") == "")
bridge_out_r41b = subprocess.run(
    [tsk.REGISTRY_BRIDGE, "cancel", run_id_r41b, task_id_r41b, "post_spawn_setup_failed", "rtask_whatever_was_expected"],
    capture_output=True, text=True)
check("registry-bridge.sh cancel succeeds against an unstamped row (no false refusal)",
      bridge_out_r41b.returncode == 0, bridge_out_r41b.stderr)
row_after = registry_row(task_id_r41b)
check("state is 'cancelled' after cancelling the unstamped row",
      bool(row_after) and row_after.get("state") == "cancelled", row_after)

print("== Z5: every accepted start schedules a real, independently-firing hard-stop timer, "
      "killed on a real cancel but NOT while the task is still running (F9) ==")
out_z5a = tsk.process_command({
    "command_id": "cmd_z5a", "op": "start", "remote_task_id": "rtask_20261002T000009Z_00005a01",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "z5a"},
})
check("Z5a start accepted", out_z5a.get("outcome") == "accepted", json.dumps(out_z5a))
task_id_z5a, run_id_z5a = out_z5a.get("local_task_id", ""), out_z5a.get("local_run_id", "")


def _hard_stop_pid(task_id: str) -> int | None:
    con = sqlite3.connect(tsk.REGISTRY)
    con.row_factory = sqlite3.Row
    row = con.execute("SELECT payload FROM events WHERE task_id=? AND type='hard_stop_scheduled' "
                       "ORDER BY sequence DESC LIMIT 1", (task_id,)).fetchone()
    con.close()
    if not row:
        return None
    try:
        pid = json.loads(row["payload"]).get("pid")
    except ValueError:
        return None
    return pid if isinstance(pid, int) and pid > 0 else None


def _reap_or_confirm_dead(pid: int, timeout_s: float = 2.0) -> bool:
    """Kill a hard-stop timer's process group and confirm it is actually
    gone before anything calls it a leak. Fix for a conductor-reported
    flake: `os.kill(pid, 0)` alone returns success for an unreaped
    ZOMBIE (signalled but never waited on) -- this script is the real
    parent of every timer it schedules (tasks.py's real, unfaked Popen
    runs in-process here), so a plain killpg without a reap leaves
    exactly that zombie, which then looks indistinguishable from "still
    running" to anything checking with signal 0 alone. Reaps via
    waitpid when this process is still the pid's parent; falls back to
    polling `ps`'s own STAT column (Z or no row at all means dead) for a
    pid this process is no longer the parent of (e.g. already reaped by
    tasks.py's own _kill_hard_stop_timer through a real _cancel() call
    earlier in this same run)."""
    try:
        os.killpg(pid, signal.SIGTERM)
    except OSError:
        pass
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            reaped_pid, _ = os.waitpid(pid, os.WNOHANG)
            if reaped_pid == pid:
                return True
        except ChildProcessError:
            out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
            if out.stdout.strip() in ("", ) or out.stdout.strip().startswith("Z"):
                return True
        time.sleep(0.05)
    return False


pid_z5a = _hard_stop_pid(task_id_z5a)
check("a real numeric hard-stop pid was recorded for Z5a's start", pid_z5a is not None, pid_z5a)
alive_before_cancel = False
if pid_z5a is not None:
    try:
        os.kill(pid_z5a, 0)
        alive_before_cancel = True
    except ProcessLookupError:
        pass
check("Z5a's hard-stop pid is a REAL, live detached process before cancel (not a placeholder)",
      alive_before_cancel, pid_z5a)

cout_z5a = tsk.process_command({
    "command_id": "cmd_z5a_cancel", "op": "cancel", "remote_task_id": "rtask_20261002T000009Z_00005a01",
    "payload": {"local_task_id": task_id_z5a, "reason": "canceled"},
})
check("Z5a cancel (through tasks.py's own process_command, the real production path) accepted",
      cout_z5a.get("outcome") == "accepted", json.dumps(cout_z5a))
still_alive_after_cancel = True
if pid_z5a is not None:
    try:
        os.kill(pid_z5a, 0)
    except ProcessLookupError:
        still_alive_after_cancel = False
check("F9: Z5a's hard-stop pid was killed by the cancel it went through -- no 60+-minute leaked sleep",
      not still_alive_after_cancel, pid_z5a)

print("== Z5b: a hard-stop timer is NOT killed while its task is still running (F9 only fires on a terminal transition) ==")
out_z5b = tsk.process_command({
    "command_id": "cmd_z5b", "op": "start", "remote_task_id": "rtask_20261002T000010Z_00005b01",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "z5b"},
})
check("Z5b start accepted", out_z5b.get("outcome") == "accepted", json.dumps(out_z5b))
task_id_z5b = out_z5b.get("local_task_id", "")
pid_z5b = _hard_stop_pid(task_id_z5b)
check("a real numeric hard-stop pid was recorded for Z5b's start", pid_z5b is not None, pid_z5b)
# No cancel, no auto_close, no sweep() here -- Z5b's task stays 'running'.
# Its timer must still be alive; F9 only kills on a terminal transition.
still_alive_z5b = False
if pid_z5b is not None:
    try:
        os.kill(pid_z5b, 0)
        still_alive_z5b = True
    except ProcessLookupError:
        pass
check("Z5b's hard-stop pid is still alive -- nothing killed it while the task is still running",
      still_alive_z5b, pid_z5b)
if pid_z5b is not None and still_alive_z5b:
    _reap_or_confirm_dead(pid_z5b)  # it would otherwise sleep ~62 real minutes

# Conductor's own nit (round-2 review): every per-section cleanup above
# handles its OWN out-of-band shortcut; this is the blanket safety net
# for anything missed -- every hard_stop_scheduled pid this run ever
# recorded gets confirmed (and if needed, reaped) dead before teardown,
# so this suite never leaks a real sleep process regardless of which
# section scheduled it, and never flags a zombie it just killed itself
# as a false leak either (the fix for the flake: a plain `os.kill(pid,
# 0)` right after killpg sees a just-killed-but-unreaped zombie as
# "still alive").
con_cleanup = sqlite3.connect(tsk.REGISTRY)
con_cleanup.row_factory = sqlite3.Row
leftover_pids = [
    json.loads(r["payload"]).get("pid")
    for r in con_cleanup.execute("SELECT payload FROM events WHERE type='hard_stop_scheduled'").fetchall()
]
con_cleanup.close()
leaked = [pid for pid in leftover_pids if pid is not None and not _reap_or_confirm_dead(pid)]
check("teardown: no hard-stop timer scheduled anywhere in this run was left alive",
      leaked == [], leaked)
shutil.rmtree(TMP, ignore_errors=True)
print()
if failures:
    print(f"FAILED: {len(failures)} check(s): {failures}")
    sys.exit(1)
print("PASS: all real-registry e2e checks green")
