#!/usr/bin/env python3
"""verify-hub-mirror.py — the dashboard mirror can never type an unverified
answer into an agent pane (security review 2026-09-23, F1).

kb.hub_forms is writable by everyone holding the Neon DSN, so record_remote_answer
must refuse — before touching the registry, and without calling notify_owner —
any pending row that is unsigned, forged, signed for another form, or answered
by someone who is not a decisions owner. And it must still deliver a genuine
answer exactly once, even when an ack is lost.

    python3 verify-hub-mirror.py
"""
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE = Path(tempfile.mkdtemp())
(STATE / "forms").mkdir()
os.environ["HERDR_STATE_ROOT"] = str(STATE)
os.environ.pop("HERDR_DECISIONS_OWNERS", None)
sys.path.insert(0, str(HERE / "lib"))
spec = importlib.util.spec_from_file_location("hubmod", HERE / "hub.py")
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)

KEY = b"k" * 48
OWNER = "tnt@teamthurber.com"


def make_form(fid, token="tok-" + "x" * 20, status="open", **extra):
    row = {"id": fid, "title": fid, "status": status, "token": token, "url": "http://127.0.0.1:1/",
           "port": 1, "created_at": int(time.time() * 1000),
           "expires_at": int(time.time() * 1000) + 3_600_000, **extra}
    (STATE / "forms" / f"{fid}.json").write_text(json.dumps(row))
    return row


def signed(fid, answers, by=OWNER, token="tok-" + "x" * 20, key=KEY):
    nonce = hub._mirror_nonce(key, fid, token)
    sig = hub._mirror_mac(key, "answer", fid, nonce, hub._mirror_canonical(answers), by)
    return {"id": fid, "nonce": nonce, "answers": answers, "answered_by": by, "answer_sig": sig}


def local(fid):
    return json.loads((STATE / "forms" / f"{fid}.json").read_text())


class MirrorVerification(unittest.TestCase):
    def setUp(self):
        self.delivered = []
        hub.notify_owner = lambda row: self.delivered.append(row["id"])
        hub.MIRROR_STATE.update(rejected=0, last_rejection=None)

    def test_genuine_answer_is_recorded_attributed_and_delivered_once(self):
        make_form("ok1")
        self.assertEqual(hub.record_remote_answer("ok1", signed("ok1", {"pr": "merge"}), KEY), "delivered")
        row = local("ok1")
        self.assertEqual((row["status"], row["answered_via"], row["answered_by"]), ("answered", "dashboard", OWNER))
        self.assertEqual(self.delivered, ["ok1"])
        # a lost ack: the same pending row comes back next cycle
        self.assertEqual(hub.record_remote_answer("ok1", signed("ok1", {"pr": "merge"}), KEY), "delivered")
        self.assertEqual(self.delivered, ["ok1"], "must not type the answer into the pane twice")

    def test_forged_rows_are_rejected_untouched_and_never_delivered(self):
        cases = {
            "unsigned": lambda f: {"id": f, "answers": {"pr": "merge"}, "answered_by": OWNER},
            "garbage signature": lambda f: {**signed(f, {"pr": "merge"}), "answer_sig": "0" * 64},
            "answers altered after signing": lambda f: {**signed(f, {"pr": "hold"}), "answers": {"pr": "merge"}},
            "signed with another key": lambda f: signed(f, {"pr": "merge"}, key=b"z" * 48),
            "signed for another form's nonce": lambda f: {**signed(f, {"pr": "merge"}),
                                                          "nonce": signed("other", {"pr": "merge"})["nonce"]},
            "answered by a non-owner (validly signed)": lambda f: signed(f, {"pr": "merge"}, by="kristin@teamthurber.com"),
            "answers not an object": lambda f: {**signed(f, {"pr": "merge"}), "answers": ["merge"]},
        }
        for i, (why, build) in enumerate(cases.items()):
            with self.subTest(why):
                fid = f"forged{i}"
                make_form(fid)
                self.assertEqual(hub.record_remote_answer(fid, build(fid), KEY), "rejected")
                self.assertEqual(local(fid)["status"], "open", "a rejected answer must change nothing")
        self.assertEqual(self.delivered, [])
        self.assertEqual(hub.MIRROR_STATE["rejected"], len(cases))

    def test_local_answer_wins_a_race(self):
        make_form("race", status="answered", answers={"pr": "local"}, answered_via="hub")
        self.assertEqual(hub.record_remote_answer("race", signed("race", {"pr": "remote"}), KEY), "conflict")
        self.assertEqual(local("race")["answers"], {"pr": "local"})
        self.assertEqual(self.delivered, [])

    def test_unknown_or_path_shaped_ids_are_missing(self):
        self.assertEqual(hub.record_remote_answer("../../etc/passwd", signed("x", {"a": 1}), KEY), "missing")
        self.assertEqual(hub.record_remote_answer("nope", signed("nope", {"a": 1}), KEY), "missing")

    def test_mirror_sync_never_raises_and_says_why(self):
        hub.KB_DEPLOY = Path("/nonexistent")
        hub.mirror_sync()
        self.assertIn("hub_forms.py", hub.MIRROR_STATE["last_error"])

    def test_mac_scheme_matches_the_dashboard(self):
        kb = Path.home() / "Code/.worktrees/kb-dashboard-decisions"
        if not (kb / "server/hub_forms.py").exists():
            kb = Path.home() / "Code/knowledge-base"
        if not (kb / "server/hub_forms.py").exists():
            self.skipTest("knowledge-base server/hub_forms.py not found")
        sys.path.insert(0, str(kb))
        os.environ["DECISIONS_MIRROR_KEY"] = KEY.decode()
        from server import hub_forms  # noqa: E402
        nonce, answers = "n" * 32, {"b": 2, "a": "é"}
        self.assertEqual(hub_forms.answer_sig("f", nonce, answers, OWNER),
                         hub._mirror_mac(KEY, "answer", "f", nonce, hub._mirror_canonical(answers), OWNER))
        html_text = "<p>é</p>"
        import hashlib
        self.assertEqual(hub_forms.html_sig("f", nonce, html_text),
                         hub._mirror_mac(KEY, "html", "f", nonce, hashlib.sha256(html_text.encode()).hexdigest()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
