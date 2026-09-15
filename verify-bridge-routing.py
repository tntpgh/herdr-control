#!/usr/bin/env python3
"""The Slack bridge must deliver an ANSWER as an answer, and a brief as a brief.

hub.py anchors "did this worker do what I last asked?" to the last
`brief_delivered` event. herdr-deliver.sh records that for every delivery
EXCEPT `--reply`/`--blocked`. So a delivery that is semantically an answer but
is recorded as a brief moves the anchor past the worker's own completion
evidence, and the task parks in Needs-attention forever — a finished worker
never writes another `_done`. That was PR #63's P1 #2, and review (2026-09-15)
found the bridge's threaded-reply route still doing it: the highest-traffic
delivery path in the repo, and herdr-deliver.sh's own comment calls it "the
Slack free-text reply path (the common case)".

The mapping is per ROUTE, which is why it needs a test rather than a rule:

  1. reply threaded under an alert  -> ANSWER   (the alert asked the question)
  2. explicit "w8:p2 <text>"        -> BRIEF    (a human issuing new work)
  3. the single blocked agent       -> ANSWER   (--blocked is an answer)

Route 2 must keep moving the anchor: a fresh instruction IS a new ask, and
recording it as a reply would leave a genuinely stalled worker reading
`completed` off the round before.

`slack_bolt` is not installed outside the bridge's venv, so it is stubbed —
the decorators must hand back the undecorated function for the handler to be
callable here.
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
ok = bad = 0


def check(name: str, got, want) -> None:
    global ok, bad
    if got == want:
        ok += 1
        print(f"  ok    {name}")
    else:
        bad += 1
        print(f"  FAIL  {name}\n        want={want!r} got={got!r}")


def load_bridge():
    """Import the bridge with slack_bolt stubbed and a plausible environment."""
    bolt = types.ModuleType("slack_bolt")

    class App:                                   # noqa: D401 - stub
        def __init__(self, *_a, **_k):
            pass

        def event(self, *_a, **_k):
            return lambda fn: fn                 # hand back the real function

        def action(self, *_a, **_k):
            return lambda fn: fn

        def command(self, *_a, **_k):
            return lambda fn: fn

        def message(self, *_a, **_k):
            return lambda fn: fn

    bolt.App = App
    adapter = types.ModuleType("slack_bolt.adapter")
    socket_mode = types.ModuleType("slack_bolt.adapter.socket_mode")

    class SocketModeHandler:                     # noqa: D401 - stub
        def __init__(self, *_a, **_k):
            pass

        def start(self):
            raise AssertionError("the suite must never start the socket handler")

    socket_mode.SocketModeHandler = SocketModeHandler
    sys.modules.update({"slack_bolt": bolt, "slack_bolt.adapter": adapter,
                        "slack_bolt.adapter.socket_mode": socket_mode})
    os.environ.update({
        "SLACK_BOT_TOKEN": "xoxb-test", "SLACK_APP_TOKEN": "xapp-test",
        "HERDR_BRIDGE_ALLOW_USERS": "U_TEST", "HERDR_BRIDGE_TEAM": "T_TEST",
        "HERDR_BRIDGE_STATE": "/tmp/herdr-bridge-verify",
    })
    spec = importlib.util.spec_from_file_location(
        "slack_herdr_bridge", HERE / "slack-bridge" / "slack-herdr-bridge.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    mod = load_bridge()
    calls: list[list[str]] = []

    class Result:
        returncode = 0
        stdout = "delivered"
        stderr = ""

    real_run = mod.subprocess.run          # captured BEFORE the stub replaces it
    mod.subprocess.run = lambda argv, **_k: (calls.append(list(argv)), Result())[1]
    said: list[str] = []
    # The handler takes `logger` as a parameter; a module-level one does not
    # exist (slack_bolt injects it), so the suite supplies its own.
    import logging
    logger = logging.getLogger("verify-bridge-routing")

    def say(text="", **_k):
        said.append(text)

    # Route 1: a threaded reply under an alert. pane_for_thread resolves it.
    mod.pane_for_thread = lambda ts: ("w8:p2", "prompt-1") if ts else (None, None)
    calls.clear()
    mod.on_message({"user": "U_TEST", "text": "yes, option B", "ts": "2.0",
                    "thread_ts": "1.0", "channel": "C1"},
                   say, logger, {"team_id": "T_TEST"})
    argv = calls[-1] if calls else []
    check("threaded reply passes --reply", "--reply" in argv, True)
    check("threaded reply targets the alert's pane", "w8:p2" in argv, True)

    # Route 2: an explicit target prefix in a NEW message. Not an answer.
    mod.pane_for_thread = lambda ts: (None, None)
    calls.clear()
    mod.on_message({"user": "U_TEST", "text": "w8:p3 please rerun the migration",
                    "ts": "3.0", "channel": "C1"},
                   say, logger, {"team_id": "T_TEST"})
    argv = calls[-1] if calls else []
    check("explicit-target message is a BRIEF (no --reply)", "--reply" in argv, False)
    check("explicit-target message targets that pane", "w8:p3" in argv, True)

    # Route 3: no thread, no prefix -> the single blocked agent, which is an
    # answer by construction (it is sitting on a prompt).
    calls.clear()
    mod.on_message({"user": "U_TEST", "text": "go ahead", "ts": "4.0", "channel": "C1"},
                   say, logger, {"team_id": "T_TEST"})
    argv = calls[-1] if calls else []
    check("--blocked route passes --reply", "--reply" in argv, True)
    check("--blocked route keeps its target", "--blocked" in argv, True)

    # A bare number in a thread is a CHOICE and must not reach deliver() at all:
    # it goes through herdr-select, which checks the option is really on offer.
    mod.pane_for_thread = lambda ts: ("w8:p2", "prompt-1") if ts else (None, None)
    calls.clear()
    picked: list[tuple] = []
    mod.select_option = lambda *a, **k: (picked.append((a, k)), (True, "picked"))[1]
    mod.on_message({"user": "U_TEST", "text": "2", "ts": "5.0", "thread_ts": "1.0",
                    "channel": "C1"},
                   say, logger, {"team_id": "T_TEST"})
    check("a numbered reply goes to herdr-select, not deliver", calls, [])
    check("and it is recorded as a selection", len(picked), 1)

    # The flag must reach herdr-deliver.sh's own reply detection, not just look
    # right in argv: it is the FIRST argument, before the target, or the script
    # treats it as the target and refuses.
    mod.pane_for_thread = lambda ts: ("w8:p2", "prompt-1") if ts else (None, None)
    calls.clear()
    mod.on_message({"user": "U_TEST", "text": "answer text", "ts": "6.0",
                    "thread_ts": "1.0", "channel": "C1"},
                   say, logger, {"team_id": "T_TEST"})
    argv = calls[-1]
    check("--reply precedes the target in argv",
          argv.index("--reply") < argv.index("w8:p2"), True)

    # And prove herdr-deliver.sh really CONSUMES the flag rather than taking it
    # for the target. Behavioural, not a grep for a spelling: run it with a
    # deliberately unresolvable pane. A parser that consumed `--reply` reports
    # the PANE as unresolvable; one that did not reports `--reply` itself, which
    # is exactly how a renamed flag would silently downgrade every answer to a
    # brief. Nothing is delivered either way — the target cannot resolve.
    # `mod.subprocess` IS this suite's `subprocess` — module objects are
    # shared — so the stub installed above replaced `run` for both. Use the
    # real one captured before stubbing, or this "behavioural" check just reads
    # the stub's own fake output back.
    out = real_run(
        ["bash", str(HERE / "herdr-deliver.sh"), "--reply", "w9:NOSUCH", "x"],
        capture_output=True, text=True,
        env={**os.environ,
             "HERDR_EXTRA_PATH": os.environ.get("HERDR_EXTRA_PATH",
                                                "/opt/homebrew/bin:/usr/local/bin")})
    err = out.stdout + out.stderr
    check("herdr-deliver.sh consumes --reply as a flag, not as the target",
          "'w9:NOSUCH'" in err and "'--reply'" not in err, True)

    print(f"\nverify-bridge-routing.py: {ok} passed, {bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
