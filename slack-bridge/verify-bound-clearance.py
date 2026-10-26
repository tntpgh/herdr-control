#!/usr/bin/env python3
"""Negative-test suite for Part B's bound-clearance Slack button
(approval-classification-repair-5d6e094a.md, thurber-os .handoffs/frozen).

No real Slack, no real herdr: slack_bolt is stubbed (same fake used by
verify-bridge-ignore-channels.py) and herdr-action.sh is a fake script that
records its argv to a file. HERDR_BOUND_CLEARANCE_SLACK is set so the
bridge-side gate is exercised; herdr-action.sh's OWN gate on that same
variable is covered separately (it is a fake here, recording argv only).

    python3 slack-bridge/verify-bound-clearance.py

Every test here fails against a revision with no on_bound_choice_button at
all (the state before this change): no action_id `herdr_bound_approve` /
`herdr_bound_deny` handler is registered, so nothing here has anything to
call, and a forged/malformed/unauthorized click would have had no path to
decide a request in the first place — there was no handler to exploit NOR to
protect. These tests exist to prove the handler that now exists does
refuse the cases menu-occurrence-design.md and approval-classification-
repair-5d6e094a.md's negative-test lists require (replay via wrong digest,
unauthorized/wrong-team identity, malformed value) and constructs the
correct argv for the one path it is allowed to clear.
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
TMP = Path(tempfile.mkdtemp(prefix="herdr-bound-clearance-verify-"))
ALLOWED_USER = "U0ALLOWEDUSER"
OTHER_USER = "U0OTHERUSER0"
TEAM = "T0TEAM00000"
OTHER_TEAM = "T0OTHERTEAM0"
REQUEST_ID = "ar_deadbeef01234567_1"
ACTION_SHA = "a" * 64
WRONG_SHA = "b" * 64


def _install_fake_slack_bolt() -> None:
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
FAKE_ACTION = fake_script("fake-action.sh", "FAKE_ACTION_ARGV")


def load_bridge(team: str = TEAM, channel: str = ""):
    argv_action = TMP / "action.argv"
    argv_action.unlink(missing_ok=True)
    os.environ.update(
        SLACK_BOT_TOKEN="xoxb-fake", SLACK_APP_TOKEN="xapp-fake",
        HERDR_BRIDGE_ALLOW_USERS=ALLOWED_USER, HERDR_BRIDGE_TEAM=team,
        HERDR_BRIDGE_CHANNEL=channel, HERDR_BRIDGE_IGNORE_CHANNELS="",
        HERDR_DELIVER_BIN=str(FAKE_DELIVER), HERDR_SELECT_BIN=str(FAKE_SELECT),
        HERDR_ACTION_BIN=str(FAKE_ACTION),
        HERDR_BRIDGE_STATE=str(TMP / f"state-{len(list(TMP.glob('state-*')))}"),
        FAKE_DELIVER_ARGV=str(argv_action.parent / "deliver.argv"),
        FAKE_SELECT_ARGV=str(argv_action.parent / "select.argv"),
        FAKE_ACTION_ARGV=str(argv_action),
    )
    spec = importlib.util.spec_from_file_location(f"bridge_{id(object())}", HERE / "slack-herdr-bridge.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod._argv_action = argv_action
    return mod


def read_argv(path: Path):
    if not path.exists():
        return None
    return path.read_bytes().decode().rstrip("\0").split("\0")


class NoSay:
    def __init__(self):
        self.calls = []

    def __call__(self, **kw):
        self.calls.append(kw)


class NoLogger:
    def __init__(self):
        self.warnings = []

    def info(self, *a, **k):
        pass

    def warning(self, *a, **k):
        self.warnings.append((a, k))


def click_body(user=ALLOWED_USER, team=TEAM, action_id="herdr_bound_approve",
               value=f"{REQUEST_ID}|{ACTION_SHA}", channel=None):
    return {
        "user": {"id": user},
        "team": {"id": team},
        "actions": [{"action_id": action_id, "value": value}],
        "message": {"ts": "1700000000.000100"},
        **({"channel": {"id": channel}} if channel else {}),
    }


class BoundClearance(unittest.TestCase):
    def test_unauthorized_user_never_calls_herdr_action(self):
        """A click from a Slack user id not on the allowlist must not reach
        herdr-action.sh at all — same identity gate every other button here
        uses, never a shortcut for this action_id."""
        mod = load_bridge()
        say, logger = NoSay(), NoLogger()
        mod.on_bound_choice_button(ack=lambda: None, body=click_body(user=OTHER_USER),
                                    say=say, logger=logger)
        self.assertIsNone(read_argv(mod._argv_action), "unauthorized click must not invoke herdr-action.sh")
        self.assertEqual(say.calls, [], "no say() for a silently-ignored unauthorized click")

    def test_wrong_team_never_calls_herdr_action(self):
        """Same allowlisted user id, different Slack workspace — the
        workspace-binding gap this allowlist exists to close (authorized()'s
        own docstring/history)."""
        mod = load_bridge()
        say, logger = NoSay(), NoLogger()
        mod.on_bound_choice_button(ack=lambda: None, body=click_body(team=OTHER_TEAM),
                                    say=say, logger=logger)
        self.assertIsNone(read_argv(mod._argv_action), "wrong-team click must not invoke herdr-action.sh")

    def test_malformed_value_never_calls_herdr_action(self):
        """A button value that is not exactly <request_id>|<64-hex-sha> is
        refused outright — never partially parsed, never passed through."""
        mod = load_bridge()
        say, logger = NoSay(), NoLogger()
        for bad_value in ["", "justarequestid", f"{REQUEST_ID}|not-hex",
                           f"{REQUEST_ID}|{ACTION_SHA[:10]}", f"|{ACTION_SHA}",
                           f"{REQUEST_ID}|{ACTION_SHA}|extra"]:
            with self.subTest(value=bad_value):
                mod._argv_action.unlink(missing_ok=True)
                mod.on_bound_choice_button(ack=lambda: None,
                                            body=click_body(value=bad_value), say=say, logger=logger)
                self.assertIsNone(read_argv(mod._argv_action),
                                   f"malformed value {bad_value!r} must not invoke herdr-action.sh")
        self.assertTrue(any("malformed" in str(w) for w in logger.warnings))

    def test_ignored_channel_never_calls_herdr_action(self):
        mod = load_bridge()
        mod.IGNORE_CHANNELS.add("C0IGNOREDCHAN")
        say, logger = NoSay(), NoLogger()
        mod.on_bound_choice_button(ack=lambda: None,
                                    body=click_body(channel="C0IGNOREDCHAN"), say=say, logger=logger)
        self.assertIsNone(read_argv(mod._argv_action))
        self.assertEqual(say.calls, [])

    def test_approve_click_builds_correct_argv(self):
        """The one path that IS allowed to clear: authorized user, real
        team, well-formed value -> herdr-action.sh approve <id> --authority
        human --via slack-button --slack-user <uid> --slack-team <tid>
        --action-sha256 <sha>. herdr-action.sh's own CAS/digest check is the
        actual security boundary (fake here, argv-only) — this proves the
        bridge submits the right request for it to judge, with the real
        clicking user's identity, never a placeholder."""
        mod = load_bridge()
        say, logger = NoSay(), NoLogger()
        mod.on_bound_choice_button(ack=lambda: None, body=click_body(action_id="herdr_bound_approve"),
                                    say=say, logger=logger)
        argv = read_argv(mod._argv_action)
        self.assertIsNotNone(argv, "authorized approve click must invoke herdr-action.sh")
        self.assertEqual(argv[:2], ["approve", REQUEST_ID])
        self.assertIn("--authority", argv)
        self.assertEqual(argv[argv.index("--authority") + 1], "human")
        self.assertIn("--via", argv)
        self.assertEqual(argv[argv.index("--via") + 1], "slack-button")
        self.assertIn("--slack-user", argv)
        self.assertEqual(argv[argv.index("--slack-user") + 1], ALLOWED_USER)
        self.assertIn("--slack-team", argv)
        self.assertEqual(argv[argv.index("--slack-team") + 1], TEAM)
        self.assertIn("--action-sha256", argv)
        self.assertEqual(argv[argv.index("--action-sha256") + 1], ACTION_SHA)

    def test_deny_click_maps_to_decline_verb(self):
        """herdr-action.sh's own dispatcher only accepts approve|decline|
        supersede — Deny must map to 'decline', never a made-up verb it
        would refuse with 'unknown argument'."""
        mod = load_bridge()
        say, logger = NoSay(), NoLogger()
        mod.on_bound_choice_button(ack=lambda: None, body=click_body(action_id="herdr_bound_deny"),
                                    say=say, logger=logger)
        argv = read_argv(mod._argv_action)
        self.assertEqual(argv[:2], ["decline", REQUEST_ID])

    def test_wrong_digest_still_reaches_herdr_action_for_it_to_refuse(self):
        """The bridge itself never second-guesses the digest in the button
        value (it only validates SHAPE, not correctness) — a stale/forged
        sha must still be SUBMITTED, so herdr-action.sh's own exact-match
        check (not this bridge) is what refuses it. Proves the bridge does
        not silently swallow a wrong-digest click as if it were malformed."""
        mod = load_bridge()
        say, logger = NoSay(), NoLogger()
        mod.on_bound_choice_button(ack=lambda: None,
                                    body=click_body(value=f"{REQUEST_ID}|{WRONG_SHA}"), say=say, logger=logger)
        argv = read_argv(mod._argv_action)
        self.assertIsNotNone(argv, "a wrong-digest click must still reach herdr-action.sh's own refusal")
        self.assertEqual(argv[argv.index("--action-sha256") + 1], WRONG_SHA)


if __name__ == "__main__":
    unittest.main(verbosity=1)
