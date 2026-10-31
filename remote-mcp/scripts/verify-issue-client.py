#!/usr/bin/env python3
"""Offline checks for issue-client.py: no sockets, no real state dir.

grants.call and ingest_key are patched to fixture data (issue-client.py
never touches /oauth/token itself, so there is no token to fake); LABELS_PATH
is pointed at a tempdir before any --apply write. Covers the peer-inbox/full
--profile exact-set check, the "zero" -> "dot" name alias, and that a CIMD
client_id (the full registration-document URL Claude.ai and ChatGPT use)
matches and labels exactly like any other client_id.
"""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("issue_client", Path(__file__).resolve().parent / "issue-client.py")
issue_client = importlib.util.module_from_spec(SPEC)
sys.modules["issue_client"] = issue_client
SPEC.loader.exec_module(issue_client)

CLAUDE_CLIENT_ID = "https://claude.ai/oauth/mcp-oauth-client-metadata"
CHATGPT_CLIENT_ID = "https://chatgpt.com/oauth/client.json"


def grant(client_id: str, scope: list[str], grant_id: str = "grant_1") -> dict:
    return {"grant_id": grant_id, "client_id": client_id, "scope": scope, "created_at": 0, "expires_at": None}


class FakeCall:
    """Stands in for grants.call: the only op issue-client.py ever sends is list."""

    def __init__(self, grants: list[dict]):
        self.grants = grants

    def __call__(self, key, body, path="/admin/grants"):
        assert body["op"] == "list"
        return 200, {"grants": self.grants}


class ScopeProfiles(unittest.TestCase):
    def test_full_scope_is_peer_inbox_plus_messaging_and_all_task_verbs(self):
        self.assertEqual(
            issue_client.FULL_SCOPE,
            issue_client.PEER_INBOX_SCOPE
            | frozenset({"herdr:message", "herdr:task.start", "herdr:task.implement", "herdr:task.cancel"}),
        )

    def test_profiles_table_has_exactly_peer_inbox_and_full(self):
        self.assertEqual(set(issue_client.SCOPE_PROFILES), {"peer-inbox", "full"})


class LabelCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.labels_path = Path(self.tmp.name) / "client-labels.json"
        for target, value in (("LABELS_PATH", self.labels_path), ("ingest_key", lambda: "fixture-key")):
            p = mock.patch.object(issue_client, target, value)
            p.start()
            self.addCleanup(p.stop)

    def run_main(self, grants: list[dict], argv: list[str]) -> int:
        with mock.patch.object(issue_client, "call", FakeCall(grants)):
            return issue_client.main(argv)

    def test_peer_inbox_profile_accepts_exact_scope_dry_run(self):
        grants = [grant(CHATGPT_CLIENT_ID, ["herdr:read", "herdr:message.owner"])]
        rc = self.run_main(grants, ["label", "dot", "--client-id", CHATGPT_CLIENT_ID])
        self.assertEqual(rc, 0)
        self.assertFalse(self.labels_path.exists())  # dry run never writes

    def test_full_profile_refuses_peer_inbox_only_scope(self):
        grants = [grant(CLAUDE_CLIENT_ID, ["herdr:read", "herdr:message.owner"])]
        rc = self.run_main(grants, ["label", "duet", "--client-id", CLAUDE_CLIENT_ID, "--profile", "full"])
        self.assertEqual(rc, 1)

    def test_full_profile_accepts_exact_full_scope_and_applies(self):
        grants = [grant(CLAUDE_CLIENT_ID, sorted(issue_client.FULL_SCOPE))]
        rc = self.run_main(grants, ["label", "duet", "--client-id", CLAUDE_CLIENT_ID, "--profile", "full", "--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(self.labels_path.read_text()), {CLAUDE_CLIENT_ID: "duet"})

    def test_peer_inbox_profile_refuses_extra_task_scope(self):
        grants = [grant(CHATGPT_CLIENT_ID, ["herdr:read", "herdr:message.owner", "herdr:task.start"])]
        rc = self.run_main(grants, ["label", "dot", "--client-id", CHATGPT_CLIENT_ID])
        self.assertEqual(rc, 1)

    def test_name_alias_zero_resolves_to_dot_and_applies_under_dot(self):
        grants = [grant(CHATGPT_CLIENT_ID, ["herdr:read", "herdr:message.owner"])]
        rc = self.run_main(grants, ["label", "zero", "--client-id", CHATGPT_CLIENT_ID, "--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(self.labels_path.read_text()), {CHATGPT_CLIENT_ID: "dot"})

    def test_unknown_profile_is_refused_by_argparse_before_any_scope_check(self):
        grants = [grant(CLAUDE_CLIENT_ID, sorted(issue_client.FULL_SCOPE))]
        with self.assertRaises(SystemExit) as cm, mock.patch("sys.stderr"):
            self.run_main(grants, ["label", "duet", "--client-id", CLAUDE_CLIENT_ID, "--profile", "bogus"])
        self.assertEqual(cm.exception.code, 2)
        self.assertFalse(self.labels_path.exists())

    def test_cimd_url_client_ids_match_byte_for_byte_for_both_real_clients(self):
        grants = [
            grant(CLAUDE_CLIENT_ID, sorted(issue_client.FULL_SCOPE), grant_id="g_duet"),
            grant(CHATGPT_CLIENT_ID, ["herdr:read", "herdr:message.owner"], grant_id="g_dot"),
        ]
        self.assertEqual(
            self.run_main(grants, ["label", "duet", "--client-id", CLAUDE_CLIENT_ID, "--profile", "full", "--apply"]), 0
        )
        self.assertEqual(self.run_main(grants, ["label", "dot", "--client-id", CHATGPT_CLIENT_ID, "--apply"]), 0)
        self.assertEqual(
            json.loads(self.labels_path.read_text()), {CLAUDE_CLIENT_ID: "duet", CHATGPT_CLIENT_ID: "dot"}
        )

    def test_relabel_same_client_under_a_different_name_is_refused(self):
        grants = [grant(CHATGPT_CLIENT_ID, ["herdr:read", "herdr:message.owner"])]
        self.assertEqual(self.run_main(grants, ["label", "dot", "--client-id", CHATGPT_CLIENT_ID, "--apply"]), 0)
        rc = self.run_main(grants, ["label", "duet", "--client-id", CHATGPT_CLIENT_ID])
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
