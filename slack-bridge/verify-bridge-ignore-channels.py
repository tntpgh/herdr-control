#!/usr/bin/env python3
"""Behaviour checks for slack-herdr-bridge.py's HERDR_BRIDGE_IGNORE_CHANNELS
(SPEC zero-wake-design.md Part 1). No real Slack, no real herdr: slack_bolt
is stubbed (it may not even be installed where this runs -- the bridge is
normally run inside its own venv, this check is not), and herdr-deliver.sh /
herdr-select.sh are fake scripts that record their argv to a file, the same
"0 calls" proof shape verify-publisher.py uses for delivery assertions.

    python3 slack-bridge/verify-bridge-ignore-channels.py

Every isolation test here fails against main 3c47bca: that revision has no
HERDR_BRIDGE_IGNORE_CHANNELS at all, so a message/thread/digit/button from
the channel under test is NOT ignored -- it reaches herdr-deliver.sh or
herdr-select.sh exactly as any other allowlisted traffic would, and the "0
calls" assertions below fail.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp(prefix="herdr-bridge-verify-"))
IGNORED = "C0C6R1HLM0C"
OTHER = "C0OTHERCHANL"
ALLOWED_USER = "U0ALLOWEDUSER"
TEAM = "T0TEAM00000"


def _install_fake_slack_bolt() -> None:
    """A minimal stand-in: @app.event/@app.action just register the plain
    function so the test can call it directly, the same callable the real
    Bolt dispatcher would eventually invoke with the same positional/keyword
    shape. No dispatch loop, no sockets -- on_message/on_choice_button are
    ordinary functions either way."""
    class FakeApp:
        def __init__(self, token=None):
            self.token = token

        def event(self, name):
            def deco(fn):
                return fn
            return deco

        def action(self, pattern):
            def deco(fn):
                return fn
            return deco

    class FakeSocketModeHandler:
        def __init__(self, *a, **k):
            pass

        def start(self):
            pass

    bolt_mod = types.ModuleType("slack_bolt")
    bolt_mod.App = FakeApp
    adapter_mod = types.ModuleType("slack_bolt.adapter")
    socket_mode_mod = types.ModuleType("slack_bolt.adapter.socket_mode")
    socket_mode_mod.SocketModeHandler = FakeSocketModeHandler
    sys.modules["slack_bolt"] = bolt_mod
    sys.modules["slack_bolt.adapter"] = adapter_mod
    sys.modules["slack_bolt.adapter.socket_mode"] = socket_mode_mod


_install_fake_slack_bolt()


def fake_script(name: str, env_var: str) -> Path:
    p = TMP / name
    p.write_text(f'#!/bin/bash\nfor a in "$@"; do printf "%s\\0" "$a"; done > "${env_var}"\nexit 0\n')
    p.chmod(0o755)
    return p


FAKE_DELIVER = fake_script("fake-deliver.sh", "FAKE_DELIVER_ARGV")
FAKE_SELECT = fake_script("fake-select.sh", "FAKE_SELECT_ARGV")


def load_bridge(ignore_channels: str = IGNORED, channel: str = "", team: str = TEAM):
    """Fresh module import with its own env, so successive tests (and the
    two revisions compared by tmp/'s old-vs-new proof) never share
    module-level state (ALLOW/CHANNEL/IGNORE_CHANNELS are computed at
    import time)."""
    argv_deliver, argv_select = TMP / "deliver.argv", TMP / "select.argv"
    argv_deliver.unlink(missing_ok=True)
    argv_select.unlink(missing_ok=True)
    os.environ.update(
        SLACK_BOT_TOKEN="xoxb-fake", SLACK_APP_TOKEN="xapp-fake",
        HERDR_BRIDGE_ALLOW_USERS=ALLOWED_USER, HERDR_BRIDGE_TEAM=team,
        HERDR_BRIDGE_CHANNEL=channel, HERDR_BRIDGE_IGNORE_CHANNELS=ignore_channels,
        HERDR_DELIVER_BIN=str(FAKE_DELIVER), HERDR_SELECT_BIN=str(FAKE_SELECT),
        HERDR_BRIDGE_STATE=str(TMP / f"state-{len(list(TMP.glob('state-*')))}"),
        FAKE_DELIVER_ARGV=str(argv_deliver), FAKE_SELECT_ARGV=str(argv_select),
    )
    spec = importlib.util.spec_from_file_location(f"bridge_{id(object())}", HERE / "slack-herdr-bridge.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod._argv_deliver, mod._argv_select = argv_deliver, argv_select
    return mod


class NoSay:
    """Records every say() call; a say in the ignored-channel tests means
    the isolation leaked."""
    def __init__(self):
        self.calls = []

    def __call__(self, **kw):
        self.calls.append(kw)


class NoLogger:
    def info(self, *a, **k): pass
    def warning(self, *a, **k): pass


class Isolation(unittest.TestCase):
    def test_malformed_ignore_channel_refuses_to_start(self):
        with self.assertRaises(SystemExit):
            load_bridge(ignore_channels="not-a-channel-id")

    def test_plain_message_from_ignored_channel_is_zero_calls(self):
        b = load_bridge()
        say = NoSay()
        b.on_message({"user": ALLOWED_USER, "team": TEAM, "channel": IGNORED, "text": "w1:p1 hello", "ts": "1.1"},
                     say, NoLogger(), {"team_id": TEAM})
        self.assertEqual(say.calls, [])
        self.assertFalse(b._argv_deliver.exists())

    def test_threaded_reply_in_ignored_channel_is_zero_calls(self):
        b = load_bridge()
        say = NoSay()
        b.on_message({"user": ALLOWED_USER, "team": TEAM, "channel": IGNORED, "text": "some answer",
                      "ts": "2.2", "thread_ts": "1.1"}, say, NoLogger(), {"team_id": TEAM})
        self.assertEqual(say.calls, [])
        self.assertFalse(b._argv_deliver.exists())
        self.assertFalse(b._argv_select.exists())

    def test_bare_digit_in_ignored_channel_is_zero_calls(self):
        b = load_bridge()
        # Seed a thread registry entry so a bare digit WOULD normally be a
        # choice route -- proves the ignore check runs before that lookup
        # even has a chance to matter.
        os.makedirs(b.STATE_DIR, exist_ok=True)
        with open(b.REGISTRY, "a") as f:
            f.write('{"ts": "1.1", "pane": "w1:p1", "prompt_id": "pid1"}\n')
        say = NoSay()
        b.on_message({"user": ALLOWED_USER, "team": TEAM, "channel": IGNORED, "text": "1",
                      "ts": "3.3", "thread_ts": "1.1"}, say, NoLogger(), {"team_id": TEAM})
        self.assertEqual(say.calls, [])
        self.assertFalse(b._argv_select.exists())

    def test_button_in_ignored_channel_is_zero_calls(self):
        b = load_bridge()
        say = NoSay()
        acked = []
        b.on_choice_button(lambda: acked.append(True),
                            {"user": {"id": ALLOWED_USER}, "team": {"id": TEAM}, "channel": {"id": IGNORED},
                             "actions": [{"value": "w1:p1|1|pid1"}], "message": {"ts": "4.4"}},
                            say, NoLogger())
        self.assertEqual(say.calls, [])
        self.assertFalse(b._argv_select.exists())
        self.assertEqual(acked, [], "a button in an ignored channel is not even ack()'d")

    def test_bot_post_in_ignored_channel_is_zero_calls_no_feedback_loop(self):
        b = load_bridge()
        say = NoSay()
        b.on_message({"user": "UBOT", "bot_id": "B123", "team": TEAM, "channel": IGNORED,
                      "text": "[zero-wake] task_finished rtask_x abc", "ts": "5.5"}, say, NoLogger(), {"team_id": TEAM})
        self.assertEqual(say.calls, [])
        self.assertFalse(b._argv_deliver.exists())

    def test_dm_routing_is_unchanged(self):
        """A DM (channel id shape D...) is never in IGNORE_CHANNELS and
        never equals a configured HERDR_BRIDGE_CHANNEL unless set to it --
        this must still deliver exactly as before the change."""
        b = load_bridge(ignore_channels=IGNORED, channel="")
        say = NoSay()
        os.environ["FAKE_RC"] = "0"
        b.on_message({"user": ALLOWED_USER, "team": TEAM, "channel": "D0ADIRECTMSG", "text": "w1:p1 hi there",
                      "ts": "6.6"}, say, NoLogger(), {"team_id": TEAM})
        self.assertTrue(b._argv_deliver.exists(), "an un-ignored DM must still deliver")
        self.assertEqual(len(say.calls), 1)

class Authorization(unittest.TestCase):
    """C1 (security review dce9f1f): on_message must still gate on
    authorized() -- the ignore-channel check added for zero-wake must sit
    BEFORE it, never REPLACE it. An unauthorized user's DM (no channel
    restriction in play, HERDR_BRIDGE_CHANNEL unset per the design doc) must
    produce zero deliveries and zero replies, exactly as it did before
    HERDR_BRIDGE_IGNORE_CHANNELS existed. This fails against dce9f1f, where
    on_message went ignore-check -> subtype/bot -> CHANNEL -> routing, with
    no authorized() call at all."""
    def test_unauthorized_user_dm_gets_zero_deliveries(self):
        b = load_bridge(ignore_channels=IGNORED, channel="")
        say = NoSay()
        os.environ["FAKE_RC"] = "0"
        b.on_message({"user": "UNOTALLOWED", "team": TEAM, "channel": "D0ADIRECTMSG", "text": "w1:p1 hi",
                      "ts": "7.7"}, say, NoLogger(), {"team_id": TEAM})
        self.assertFalse(b._argv_deliver.exists(), "an unauthorized user must never reach herdr-deliver")
        self.assertEqual(say.calls, [])

    def test_unauthorized_user_in_a_thread_under_an_alert_cannot_press_a_choice(self):
        b = load_bridge(ignore_channels=IGNORED, channel="")
        os.makedirs(b.STATE_DIR, exist_ok=True)
        with open(b.REGISTRY, "a") as f:
            f.write('{"ts": "1.1", "pane": "w1:p1", "prompt_id": "pid1"}\n')
        say = NoSay()
        b.on_message({"user": "UNOTALLOWED", "team": TEAM, "channel": "D0ADIRECTMSG", "text": "1",
                      "ts": "8.8", "thread_ts": "1.1"}, say, NoLogger(), {"team_id": TEAM})
        self.assertFalse(b._argv_select.exists(), "an unauthorized user must never reach herdr-select")
        self.assertEqual(say.calls, [])

    def test_unbound_team_fails_closed_even_for_an_allowlisted_id(self):
        # HERDR_BRIDGE_TEAM genuinely unset in the loaded module (R2-L1: the
        # old version reset it inside load_bridge, so it only ever tested a
        # wrong team). An allowlisted id claiming its own workspace must
        # still be refused.
        b = load_bridge(ignore_channels=IGNORED, channel="", team="")
        self.assertEqual(b.TEAM, "", "the module under test must really be unbound")
        b.on_message({"user": ALLOWED_USER, "team": TEAM, "channel": "D0ADIRECTMSG",
                      "text": "w1:p1 hi", "ts": "9.9"}, NoSay(), NoLogger(), {"team_id": TEAM})
        self.assertFalse(b._argv_deliver.exists(), "an unbound team must refuse everything, not authorize on an unverifiable claim")
        # Control: the same message with the team bound IS delivered, so the
        # refusal above is the team binding, not some other gate.
        bound = load_bridge(ignore_channels=IGNORED, channel="", team=TEAM)
        bound.on_message({"user": ALLOWED_USER, "team": TEAM, "channel": "D0ADIRECTMSG",
                          "text": "w1:p1 hi", "ts": "9.9"}, NoSay(), NoLogger(), {"team_id": TEAM})
        self.assertTrue(bound._argv_deliver.exists(), "control: a bound, matching team must deliver")



if __name__ == "__main__":
    unittest.main(verbosity=1)
