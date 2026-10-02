#!/usr/bin/env python3
"""Behaviour checks for publisher.py's owner-inbox additions (ZERO-LOOP-001
#5): registry_owners/owner_pane_status (the F1 identity re-check),
write_inbox_message, scan_owner_replies (including the symlink-refusal case
SPEC's acceptance list names explicitly, "as in F5"), and deliver_owner's
exit-code mapping. No network beyond a loopback fixture hub, no real herdr:
delivery goes to a fake herdr-deliver that records its argv -- same fixture
shape as verify-publisher.py, loaded fresh so the two scripts never share
module-level state.

    python3 remote-mcp/verify-owner-inbox.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp(prefix="herdr-mcp-verify-owner-"))
NOW = datetime.now(timezone.utc)

PANES = [
    dict(pane_id="w1:p1", birth="term_cond", agent="omp", agent_status="idle", label="conductor", workspace="ops", tab_id="w1:t1", since=1.79e9),
    dict(pane_id="w1:p9", birth="term_shell", agent=None, agent_status="unknown", label=None, workspace="kb", tab_id="w1:t9", since=1.79e9),
]
REG = TMP / "registry.sqlite3"
con = sqlite3.connect(REG)
con.execute("CREATE TABLE tasks (task_id TEXT PRIMARY KEY, pane_birth TEXT)")
con.execute("CREATE TABLE events (sequence INTEGER PRIMARY KEY, task_id TEXT, type TEXT, occurred_at TEXT, payload TEXT)")
con.execute("""CREATE TABLE owners (label TEXT PRIMARY KEY, pane_id TEXT, pane_birth TEXT, agent_session TEXT,
                workspace TEXT, registered_at TEXT, updated_at TEXT)""")
con.executemany(
    "INSERT INTO owners (label, pane_id, pane_birth, agent_session, workspace, registered_at, updated_at) VALUES (?,?,?,?,?,?,?)",
    [
        ("conductor", "w1:p1", "term_cond", "sess-cond", "ops", "t", "t"),   # live: birth matches
        ("stale-birth", "w1:p1", "term_OLD", "", "ops", "t", "t"),           # same pane, birth disagrees -> changed
        ("vanished", "w1:gone", "term_x", "", "", "t", "t"),                 # pane_id not in the live list -> gone
    ],
)
con.commit()
con.close()


class Hub(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = {"/herdr?json=1": {"tasks": [], "herdr_reachable": True, "live": {"connected": True}},
                "/api/panes": {"connected": True, "panes": PANES},
                "/api/summary": {"rev": "abc", "live_connected": True, "attention": 0, "open_decisions": 0, "handoff_debt": 0},
                }.get(self.path)
        self.send_response(200 if body else 404)
        self.end_headers()
        self.wfile.write(json.dumps(body or {}).encode())

    def log_message(self, *a):
        pass


hub = HTTPServer(("127.0.0.1", 0), Hub)
threading.Thread(target=hub.serve_forever, daemon=True).start()

FAKE = TMP / "fake-deliver.sh"
FAKE.write_text('#!/bin/bash\nfor a in "$@"; do printf "%s\\0" "$a"; done > "$FAKE_ARGV"\n'
                '[ -n "${FAKE_ERR:-}" ] && echo "$FAKE_ERR" >&2\nexit "${FAKE_RC:-0}"\n')
FAKE.chmod(0o755)
CHROME = TMP / "fake-chrome-relay.py"
CHROME.write_text("print('not json')\n")

os.environ.update(HERDR_HUB_URL=f"http://127.0.0.1:{hub.server_port}", HERDR_RUN_REGISTRY=str(REG),
                   HERDR_STATE_DIR=str(TMP / "state"), HERDR_DELIVER=str(FAKE), FAKE_ARGV=str(TMP / "argv"),
                   HERDR_CHROME_RELAY=str(CHROME), HERDR_MCP_OWNER_INBOX="1")
spec = importlib.util.spec_from_file_location("publisher_owner", HERE / "publisher.py")
pub = importlib.util.module_from_spec(spec)
sys.modules["publisher_owner"] = pub
spec.loader.exec_module(pub)
pub.INBOX_ROOT = TMP / "inbox"


class RegistryAndStatus(unittest.TestCase):
    def test_registry_owners_reads_every_column(self):
        rows = pub.registry_owners()
        self.assertEqual(rows["conductor"],
                          {"pane_id": "w1:p1", "pane_birth": "term_cond", "agent_session": "sess-cond", "workspace": "ops"})

    def test_ok_when_birth_matches(self):
        rows = pub.registry_owners()
        live = {p["pane_id"]: p for p in PANES}
        self.assertEqual(pub.owner_pane_status("conductor", rows, live), "ok")

    def test_changed_when_birth_disagrees_on_the_same_pane_id(self):
        rows = pub.registry_owners()
        live = {p["pane_id"]: p for p in PANES}
        self.assertEqual(pub.owner_pane_status("stale-birth", rows, live), "changed")

    def test_gone_when_the_pane_id_is_not_in_the_live_list(self):
        rows = pub.registry_owners()
        live = {p["pane_id"]: p for p in PANES}
        self.assertEqual(pub.owner_pane_status("vanished", rows, live), "gone")

    def test_not_registered_for_an_unknown_label(self):
        self.assertEqual(pub.owner_pane_status("no-such-label", {}, {}), "not_registered")

    def test_build_snapshot_carries_label_and_live_only(self):
        snap, local = pub.build(NOW)
        by_label = {o["label"]: o for o in snap["owners"]}
        self.assertEqual(set(by_label), {"conductor", "stale-birth", "vanished"})
        self.assertEqual(by_label["conductor"], {"label": "conductor", "live": True})
        self.assertEqual(by_label["stale-birth"], {"label": "stale-birth", "live": False})
        self.assertNotIn("pane_id", by_label["conductor"])  # pane_id/cwd never leave the Mac
        self.assertIn("conductor", local["owners"])  # local carries the full row for delivery's own re-check


class InboxWrite(unittest.TestCase):
    def test_writes_private_atomic_and_dedupes_on_retry(self):
        ok = pub.write_inbox_message("conductor", "oex_test0001", "zero@example.com", "hello there")
        self.assertTrue(ok)
        p = pub.INBOX_ROOT / "conductor/messages/oex_test0001.md"
        self.assertTrue(p.is_file())
        self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        first = p.read_text()
        self.assertIn("hello there", first)
        self.assertIn("UNTRUSTED REMOTE DATA", first)
        # A retry (same exchange_id) must never overwrite what the owner may
        # already be reading or have replied to.
        ok2 = pub.write_inbox_message("conductor", "oex_test0001", "zero@example.com", "DIFFERENT BODY")
        self.assertTrue(ok2)
        self.assertEqual(p.read_text(), first)

    def test_refuses_a_bad_label_or_exchange_id_shape(self):
        self.assertFalse(pub.write_inbox_message("Bad_Label", "oex_x", "z", "b"))
        self.assertFalse(pub.write_inbox_message("conductor", "../../etc/passwd", "z", "b"))


class ReplyScan(unittest.TestCase):
    def test_reads_a_normal_reply_redacted_and_capped(self):
        d = pub.INBOX_ROOT / "conductor/replies"
        d.mkdir(parents=True, exist_ok=True)
        (d / "oex_r1.md").write_text("all done. token sk-" + "a" * 20)
        out = pub.scan_owner_replies(set())
        (row,) = [r for r in out if r["exchange_id"] == "oex_r1"]
        self.assertEqual(row["owner_label"], "conductor")
        self.assertIn("[REDACTED:api-key]", row["body"])
        self.assertNotIn("sk-" + "a" * 20, row["body"])

    def test_already_sent_keys_are_skipped(self):
        out = pub.scan_owner_replies({"conductor/oex_r1"})
        self.assertNotIn("oex_r1", {r["exchange_id"] for r in out})

    def test_refuses_a_symlinked_reply_file(self):
        secret = TMP / "secret.md"
        secret.write_text("this must never be sent to the Worker")
        d = pub.INBOX_ROOT / "conductor/replies"
        d.mkdir(parents=True, exist_ok=True)
        (d / "oex_sym1.md").symlink_to(secret)
        out = pub.scan_owner_replies(set())
        self.assertNotIn("oex_sym1", {r["exchange_id"] for r in out})

    def test_refuses_when_the_label_directory_itself_is_a_symlink(self):
        """F5's own demonstrated escape: not a symlinked LEAF, a symlinked
        per-owner DIRECTORY, pointed at a different owner's replies."""
        elsewhere = TMP / "elsewhere-owner"
        (elsewhere / "replies").mkdir(parents=True)
        (elsewhere / "replies" / "oex_sym2.md").write_text("belongs to a different owner")
        (pub.INBOX_ROOT / "hijacked").symlink_to(elsewhere)
        out = pub.scan_owner_replies(set())
        self.assertNotIn("oex_sym2", {r["exchange_id"] for r in out})


class Deliver(unittest.TestCase):
    def setUp(self):
        self.local = {"owners": pub.registry_owners(), "panes": {p["pane_id"]: p for p in PANES}}
        os.environ.pop("FAKE_RC", None)
        os.environ.pop("FAKE_ERR", None)
        argv_file = Path(os.environ["FAKE_ARGV"])
        if argv_file.exists():
            argv_file.unlink()

    def test_blocked_owner_not_registered(self):
        item = {"exchange_id": "oex_a", "owner_label": "no-such-label", "sender": "z", "body": "hi"}
        self.assertEqual(pub.deliver_owner(item, self.local), {"exchange_id": "oex_a", "outcome": "blocked", "reason": "owner_not_registered"})

    def test_blocked_owner_pane_gone(self):
        item = {"exchange_id": "oex_b", "owner_label": "vanished", "sender": "z", "body": "hi"}
        self.assertEqual(pub.deliver_owner(item, self.local), {"exchange_id": "oex_b", "outcome": "blocked", "reason": "owner_pane_gone"})

    def test_blocked_owner_identity_changed(self):
        item = {"exchange_id": "oex_c", "owner_label": "stale-birth", "sender": "z", "body": "hi"}
        self.assertEqual(pub.deliver_owner(item, self.local), {"exchange_id": "oex_c", "outcome": "blocked", "reason": "owner_identity_changed"})

    def test_delivered_writes_file_and_types_only_the_fixed_notice(self):
        item = {"exchange_id": "oex_ok1", "owner_label": "conductor", "sender": "zero@example.com", "body": "the real payload"}
        out = pub.deliver_owner(item, self.local)
        self.assertEqual(out, {"exchange_id": "oex_ok1", "outcome": "delivered"})
        msg = (pub.INBOX_ROOT / "conductor/messages/oex_ok1.md").read_text()
        self.assertIn("the real payload", msg)
        argv = Path(os.environ["FAKE_ARGV"]).read_bytes().decode().split("\0")[:-1]
        self.assertEqual(argv[0], "w1:p1")
        self.assertNotIn("the real payload", argv[1])  # the BODY is never typed
        self.assertIn("oex_ok1", argv[1])
        self.assertIn("[INBOX]", argv[1])

    def test_exit_5_maps_to_owner_at_approval_prompt_not_generic_retry(self):
        os.environ["FAKE_RC"] = "5"
        item = {"exchange_id": "oex_d", "owner_label": "conductor", "sender": "z", "body": "hi"}
        self.assertEqual(pub.deliver_owner(item, self.local), {"exchange_id": "oex_d", "outcome": "blocked", "reason": "owner_at_approval_prompt"})

    def test_other_exit_codes_map_to_deliver_failed_rc(self):
        os.environ["FAKE_RC"] = "3"
        item = {"exchange_id": "oex_e", "owner_label": "conductor", "sender": "z", "body": "hi"}
        self.assertEqual(pub.deliver_owner(item, self.local), {"exchange_id": "oex_e", "outcome": "blocked", "reason": "deliver_failed:3"})


if __name__ == "__main__":
    unittest.main(verbosity=1)
