#!/usr/bin/env python3
"""Offline checks for issue-client.py: no sockets, no real state dir.

grants.call and ingest_key are patched to fixture data (issue-client.py
never touches /oauth/token itself, so there is no token to fake); LABELS_PATH
is pointed at a tempdir before any --apply write. Covers the --profile
exact-set check (and that the dot/duet profiles equal the Worker's own
CLIENT_GRANTS ceilings), grant selection when a client holds both a legacy
and an fm grant, the "zero" -> "dot" name alias, and that the CIMD client_ids
match and label byte-for-byte.
"""
from __future__ import annotations

import importlib.util
import json
import re
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


def worker_grants() -> dict[str, tuple[str, frozenset[str]]]:
    """policy.ts CLIENT_GRANTS as {client_id: (label, scopes)}, constants
    resolved through types.ts."""
    src = Path(__file__).resolve().parents[1] / "worker/src"
    consts = dict(re.findall(r'export const (FM_[A-Z_]+) = "([^"]+)"', (src / "types.ts").read_text()))
    rows = re.findall(r'"(https://[^"]+)": \{ label: "(\w+)", scopes: \[([^\]]*)\] \}', (src / "policy.ts").read_text())
    return {cid: (label, frozenset(consts[c.strip()] for c in scopes.split(","))) for cid, label, scopes in rows}


class ScopeProfiles(unittest.TestCase):
    def test_dot_and_duet_profiles_are_the_workers_own_ceilings(self):
        got = worker_grants()
        self.assertEqual(got, {CHATGPT_CLIENT_ID: ("dot", issue_client.SCOPE_PROFILES["dot"]),
                               CLAUDE_CLIENT_ID: ("duet", issue_client.SCOPE_PROFILES["duet"])})


LEGACY = ["herdr:read", "herdr:message.owner"]


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
        with mock.patch.object(issue_client, "call", FakeCall(grants)), mock.patch("sys.stdout"), \
                mock.patch("sys.stderr"):
            return issue_client.main(argv)

    def test_dot_defaults_to_its_own_profile_and_a_dry_run_writes_nothing(self):
        grants = [grant(CHATGPT_CLIENT_ID, sorted(issue_client.SCOPE_PROFILES["dot"]))]
        self.assertEqual(self.run_main(grants, ["label", "dot", "--client-id", CHATGPT_CLIENT_ID]), 0)
        self.assertFalse(self.labels_path.exists())

    def test_duet_refuses_a_pre_parity_grant_without_decide_note(self):
        grants = [grant(CLAUDE_CLIENT_ID, ["fm:read", "fm:reports", "fm:request", "fm:peer"])]
        self.assertEqual(self.run_main(grants, ["label", "duet", "--client-id", CLAUDE_CLIENT_ID]), 1)

    def test_a_missing_scope_is_refused(self):
        grants = [grant(CHATGPT_CLIENT_ID, ["fm:read", "fm:reports", "fm:request"])]
        self.assertEqual(self.run_main(grants, ["label", "dot", "--client-id", CHATGPT_CLIENT_ID]), 1)

    def test_the_matching_grant_is_chosen_when_a_client_holds_legacy_and_fm_grants(self):
        grants = [grant(CLAUDE_CLIENT_ID, LEGACY, grant_id="g_old"),
                  grant(CLAUDE_CLIENT_ID, sorted(issue_client.SCOPE_PROFILES["duet"]), grant_id="g_new")]
        self.assertEqual(self.run_main(grants, ["label", "duet", "--client-id", CLAUDE_CLIENT_ID, "--apply"]), 0)
        self.assertEqual(self.run_main(grants, ["label", "duet", "--grant-id", "g_old"]), 1)
        self.assertEqual(self.run_main(grants, ["label", "duet", "--grant-id", "g_old", "--profile", "legacy-peer-inbox"]), 0)

    def test_another_name_needs_an_explicit_profile(self):
        grants = [grant(CHATGPT_CLIENT_ID, ["fm:read", "fm:reports"])]
        with self.assertRaises(SystemExit) as cm:
            self.run_main(grants, ["label", "viewer", "--client-id", CHATGPT_CLIENT_ID])
        self.assertEqual(cm.exception.code, 2)
        self.assertEqual(self.run_main(grants, ["label", "viewer", "--client-id", CHATGPT_CLIENT_ID, "--profile", "read"]), 0)

    def test_name_alias_zero_resolves_to_dot_and_applies_under_dot(self):
        grants = [grant(CHATGPT_CLIENT_ID, sorted(issue_client.SCOPE_PROFILES["dot"]))]
        self.assertEqual(self.run_main(grants, ["label", "zero", "--client-id", CHATGPT_CLIENT_ID, "--apply"]), 0)
        self.assertEqual(json.loads(self.labels_path.read_text()), {CHATGPT_CLIENT_ID: "dot"})

    def test_unknown_profile_is_refused_by_argparse_before_any_scope_check(self):
        grants = [grant(CLAUDE_CLIENT_ID, sorted(issue_client.SCOPE_PROFILES["duet"]))]
        with self.assertRaises(SystemExit) as cm:
            self.run_main(grants, ["label", "duet", "--client-id", CLAUDE_CLIENT_ID, "--profile", "full"])
        self.assertEqual(cm.exception.code, 2)
        self.assertFalse(self.labels_path.exists())

    def test_both_cimd_clients_label_byte_for_byte(self):
        grants = [grant(CLAUDE_CLIENT_ID, sorted(issue_client.SCOPE_PROFILES["duet"]), grant_id="g_duet"),
                  grant(CHATGPT_CLIENT_ID, sorted(issue_client.SCOPE_PROFILES["dot"]), grant_id="g_dot")]
        self.assertEqual(self.run_main(grants, ["label", "duet", "--client-id", CLAUDE_CLIENT_ID, "--apply"]), 0)
        self.assertEqual(self.run_main(grants, ["label", "dot", "--client-id", CHATGPT_CLIENT_ID, "--apply"]), 0)
        self.assertEqual(json.loads(self.labels_path.read_text()), {CLAUDE_CLIENT_ID: "duet", CHATGPT_CLIENT_ID: "dot"})

    def test_relabel_same_client_under_a_different_name_is_refused(self):
        grants = [grant(CHATGPT_CLIENT_ID, sorted(issue_client.SCOPE_PROFILES["read"]))]
        self.assertEqual(self.run_main(grants, ["label", "dot", "--client-id", CHATGPT_CLIENT_ID, "--profile", "read",
                                                "--apply"]), 0)
        self.assertEqual(self.run_main(grants, ["label", "duet", "--client-id", CHATGPT_CLIENT_ID, "--profile", "read"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
