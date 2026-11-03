#!/usr/bin/env python3
"""Offline checks for relay-responder.py.

Covers the SPEC's required behavior without an OAuth token, network, model, or
live inbox: ack/no-reply classification is skipped; send precedes checkpoint
and a crash before checkpoint redelivers with client_msg_id dedupe; the
forbidden owner/task tools are blocked at runtime and absent from call sites.

Run manually with: python3 remote-mcp/verify-relay-responder.py
"""
from __future__ import annotations

import ast
import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "scripts" / "relay-responder.py"
spec = importlib.util.spec_from_file_location("relay_responder_verify", SCRIPT)
relay = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = relay
spec.loader.exec_module(relay)


class FakeClient:
    def __init__(self):
        self.calls = []
        self.sent_ids = set()
        self.crash_before_commit = False

    def call_tool(self, name, **args):
        self.calls.append((name, args.copy()))
        if name == "list_peer_messages":
            return {"messages": [{
                "seq": 7, "message_id": "pm_7", "from": "duet", "body": "FYI: done", "task_id": None,
            }], "next_after_seq": 7}
        if name == "send_peer_message":
            duplicate = args["client_msg_id"] in self.sent_ids
            self.sent_ids.add(args["client_msg_id"])
            return {"message_id": "reply_1", "to": args["to"], "shared_task_id": None,
                    "duplicate": duplicate}
        if name == "commit_consumer_position":
            if self.crash_before_commit:
                self.crash_before_commit = False
                raise RuntimeError("simulated crash before commit")
            return {"result": "ok", "committed_cursor": args["new_cursor"], "lease_epoch": args["lease_epoch"]}
        raise AssertionError(name)


class RelayBehavior(unittest.TestCase):
    def setUp(self):
        self.old_classify = relay.classify_and_draft
        self.old_save = relay.save_state
        self.old_park = relay.park_for_conductor
        relay.save_state = lambda _state: None
        relay.classify_and_draft = lambda _sender, _body: {"action": "reply", "reply": "received"}
        relay.park_for_conductor = lambda *_args: True

    def tearDown(self):
        relay.classify_and_draft = self.old_classify
        relay.save_state = self.old_save
        relay.park_for_conductor = self.old_park

    def test_plain_ack_or_fyi_skips_without_send(self):
        result = self.old_classify("duet", "thanks", lambda _prompt: '{"action":"skip","reply":null}')
        self.assertEqual(result, {"action": "skip", "reply": None})
        client = FakeClient()
        relay.classify_and_draft = lambda _sender, _body: result
        outcome = relay.process_message(client, relay.RateLimiter(), {
            "seq": 1, "message_id": "pm_ack", "from": "duet", "body": "thanks",
        })
        self.assertEqual(outcome, "skipped")
        self.assertEqual(client.calls, [])

    def test_send_then_commit_and_crash_redelivery_dedupes(self):
        client = FakeClient()
        state = {"after_seq": 0, "counts": {}}
        page = {"result": "ok", "scope_hash": "scope", "scanned_through_cursor": 11,
                "latest_cursor": 11, "events": [{"type": "peer.message_ready"}]}
        client.crash_before_commit = True
        with self.assertRaises(RuntimeError):
            relay._advance(client, state, relay.RateLimiter(), page, 0, 1)
        names = [name for name, _args in client.calls]
        self.assertLess(names.index("send_peer_message"), names.index("commit_consumer_position"))
        self.assertEqual(state["after_seq"], 0)
        self.assertEqual(len([x for x in client.calls if x[0] == "send_peer_message"]), 1)

        relay._advance(client, state, relay.RateLimiter(), page, 0, 1)
        self.assertEqual(state["after_seq"], 7)
        sends = [args for name, args in client.calls if name == "send_peer_message"]
        self.assertEqual(len(sends), 2)
        self.assertEqual(sends[0]["client_msg_id"], "reply-to:pm_7")
        self.assertEqual(sends[0]["client_msg_id"], sends[1]["client_msg_id"])
        self.assertTrue(client.sent_ids == {"reply-to:pm_7"})

    def test_forbidden_tools_and_call_sites_guard(self):
        client = relay.McpClient.__new__(relay.McpClient)
        for tool in ("send_owner_message", "start_task"):
            with self.assertRaises(relay.ForbiddenToolError):
                client.call_tool(tool)
        tree = ast.parse(SCRIPT.read_text())
        tool_calls = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "call_tool":
                if node.args and isinstance(node.args[0], ast.Constant):
                    tool_calls.append(node.args[0].value)
        self.assertNotIn("send_owner_message", tool_calls)
        self.assertNotIn("start_task", tool_calls)


if __name__ == "__main__":
    unittest.main(verbosity=1)
