#!/usr/bin/env python3
"""Behaviour checks for zero_wake.py (SPEC zero-wake-design.md) and its one
safety-critical wiring point in publisher.py: an "ack <event_id>" owner
message is consumed BEFORE delivery and never typed into any pane. No
network, no real Slack: PublisherWiring reuses verify-publisher.py's own
fixture shape (a loopback fake hub, a fake herdr-deliver.sh whose argv is
recorded to a file) so "not typed" is an observed absence of a call, not an
assumption.

    python3 remote-mcp/verify-zero-wake.py

Every test here either exercises a module that does not exist on main
(zero_wake.py) or a publisher.py code path added by this change (the
owner_outbox ack short-circuit) -- both fail outright against main 3c47bca.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import threading
import unittest
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import zero_wake as zw  # noqa: E402

NOW = datetime.now(timezone.utc)
NOW_TS = NOW.timestamp()


def new_id() -> str:
    return str(uuid.uuid4())


class WakeChannel(unittest.TestCase):
    def test_empty_is_off_with_no_log(self):
        self.assertIsNone(zw.wake_channel(""))
        self.assertIsNone(zw.wake_channel("   "))

    def test_malformed_is_off(self):
        for bad in ("not-a-channel", "C123", "xC0C6R1HLM0C", "C0C6R1HLM0C;rm -rf"):
            self.assertIsNone(zw.wake_channel(bad), bad)

    def test_valid_channel_passes_through(self):
        self.assertEqual(zw.wake_channel(" C0C6R1HLM0C "), "C0C6R1HLM0C")


class RaiseEvent(unittest.TestCase):
    def setUp(self):
        self.ob = zw.new_outbox()

    def test_invalid_ref_shape_refused(self):
        for bad_ref in ("not_a_ref_123", "oex-missing-prefix-sep", "", "task_abc"):
            self.assertIsNone(zw.raise_event(self.ob, "reply_ready", bad_ref, "k", {bad_ref}, NOW_TS))
        self.assertEqual(self.ob["events"], [])

    def test_ref_not_in_known_refs_refused(self):
        self.assertIsNone(zw.raise_event(self.ob, "reply_ready", "oex_20261004T000000Z_deadbeef", "k", set(), NOW_TS))
        self.assertEqual(self.ob["events"], [])

    def test_unknown_kind_refused(self):
        ref = "rtask_20261004T000000Z_deadbeef"
        self.assertIsNone(zw.raise_event(self.ob, "spooky", ref, "k", {ref}, NOW_TS))
        self.assertEqual(self.ob["events"], [])

    def test_coalescing_same_triple_updates_last_at_only(self):
        ref = "oex_20261004T000000Z_deadbeef"
        ev1 = zw.raise_event(self.ob, "reply_ready", ref, "accepted", {ref}, NOW_TS)
        ev2 = zw.raise_event(self.ob, "reply_ready", ref, "accepted", {ref}, NOW_TS + 30)
        self.assertEqual(ev1["event_id"], ev2["event_id"])
        self.assertEqual(len(self.ob["events"]), 1)
        self.assertEqual(ev2["last_at"], zw._iso(NOW_TS + 30))
        self.assertEqual(ev2["first_at"], zw._iso(NOW_TS))  # unchanged

    def test_different_state_key_is_a_new_event(self):
        ref = "rtask_20261004T000000Z_deadbeef"
        ev1 = zw.raise_event(self.ob, "blocked", ref, "since_1", {ref}, NOW_TS)
        ev2 = zw.raise_event(self.ob, "blocked", ref, "since_2", {ref}, NOW_TS)
        self.assertNotEqual(ev1["event_id"], ev2["event_id"])
        self.assertEqual(len(self.ob["events"]), 2)

    def test_a_repeat_after_acked_is_a_new_event_not_a_coalesce(self):
        ref = "oex_20261004T000000Z_deadbeef"
        ev1 = zw.raise_event(self.ob, "reply_ready", ref, "accepted", {ref}, NOW_TS)
        zw.consume_ack(self.ob, ev1["event_id"], NOW_TS)
        ev2 = zw.raise_event(self.ob, "reply_ready", ref, "accepted", {ref}, NOW_TS + 10)
        self.assertNotEqual(ev1["event_id"], ev2["event_id"])


class PostingRetryBackoff(unittest.TestCase):
    def setUp(self):
        self.ob = zw.new_outbox()
        self.ref = "rtask_20261004T000000Z_deadbeef"
        self.ev = zw.raise_event(self.ob, "task_finished", self.ref, "verify", {self.ref}, NOW_TS)

    def test_post_text_is_the_exact_fixed_shape(self):
        self.assertEqual(zw.post_text(self.ev), f"[zero-wake] task_finished {self.ref} {self.ev['event_id']}")

    def test_a_clean_failure_retries_the_same_event_id(self):
        poster = lambda *a: (False, False, "channel_not_found")  # noqa: E731
        out = zw.tick(self.ob, "C0C6R1HLM0C", "xoxb-tok", NOW_TS, poster=poster)
        self.assertEqual(out[0]["event_id"], self.ev["event_id"])
        self.assertEqual(self.ev["status"], "pending")
        self.assertEqual(self.ev["attempts"], 1)

    def test_an_ambiguous_outcome_keeps_the_same_event_id_and_retries(self):
        original_id = self.ev["event_id"]
        poster = lambda *a: (False, True, "timeout")  # noqa: E731
        zw.tick(self.ob, "C0C6R1HLM0C", "xoxb-tok", NOW_TS, poster=poster)
        self.assertEqual(self.ev["event_id"], original_id)
        self.assertEqual(len(self.ob["events"]), 1)  # no new event minted
        self.assertEqual(self.ev["status"], "pending")

    def test_exponential_backoff_governs_due_events(self):
        poster = lambda *a: (False, True, "timeout")  # noqa: E731
        t = NOW_TS
        zw.tick(self.ob, "C0C6R1HLM0C", "xoxb-tok", t, poster=poster)  # attempts -> 1, delay 60s
        self.assertEqual(zw.due_events(self.ob, t + 1), [])
        self.assertEqual(zw.due_events(self.ob, t + 61), [self.ev])
        zw.tick(self.ob, "C0C6R1HLM0C", "xoxb-tok", t + 61, poster=poster)  # attempts -> 2, delay 120s
        self.assertEqual(zw.due_events(self.ob, t + 61 + 119), [])
        self.assertEqual(zw.due_events(self.ob, t + 61 + 121), [self.ev])

    def test_retry_cap_then_failed(self):
        poster = lambda *a: (False, False, "channel_not_found")  # noqa: E731
        t = NOW_TS
        for i in range(zw.MAX_ATTEMPTS):
            zw.tick(self.ob, "C0C6R1HLM0C", "xoxb-tok", t, poster=poster)
            t = zw._next_retry_ts(self.ev) if self.ev["status"] == "pending" else t
        self.assertEqual(self.ev["status"], "failed")
        self.assertEqual(self.ev["attempts"], zw.MAX_ATTEMPTS)
        # A failed event is never posted again, no matter how due it looks.
        self.assertEqual(zw.due_events(self.ob, t + 999999), [])

    def test_a_successful_post_marks_posted_and_is_never_reposted(self):
        poster = lambda *a: (True, False, "ok")  # noqa: E731
        zw.tick(self.ob, "C0C6R1HLM0C", "xoxb-tok", NOW_TS, poster=poster)
        self.assertEqual(self.ev["status"], "posted")
        self.assertEqual(zw.due_events(self.ob, NOW_TS + 999999), [])

    def test_posts_per_tick_are_capped(self):
        ob = zw.new_outbox()
        evs = []
        for i in range(zw.MAX_POSTS_PER_TICK + 3):
            ref = f"rtask_{i}_deadbeef"
            evs.append(zw.raise_event(ob, "task_finished", ref, "verify", {ref}, NOW_TS + i))
        poster = lambda *a: (True, False, "ok")  # noqa: E731
        out = zw.tick(ob, "C0C6R1HLM0C", "xoxb-tok", NOW_TS + 1000, poster=poster)
        self.assertEqual(len(out), zw.MAX_POSTS_PER_TICK)
        still_pending = [e for e in ob["events"] if e["status"] == "pending"]
        self.assertEqual(len(still_pending), 3)

    def test_off_channel_is_a_no_op_event_stays_pending(self):
        out = zw.tick(self.ob, None, "xoxb-tok", NOW_TS, poster=lambda *a: (True, False, "ok"))
        self.assertEqual(out, [])
        self.assertEqual(self.ev["status"], "pending")
        self.assertEqual(self.ev["attempts"], 0)


class Ack(unittest.TestCase):
    def setUp(self):
        self.ob = zw.new_outbox()
        self.ref = "oex_20261004T000000Z_deadbeef"
        self.ev = zw.raise_event(self.ob, "reply_ready", self.ref, "accepted", {self.ref}, NOW_TS)

    def test_ack_matches_the_exact_shape(self):
        self.assertIsNotNone(zw.ACK_RE.match(f"ack {self.ev['event_id']}"))
        for bad in (f"ACK {self.ev['event_id']}", f"ack  {self.ev['event_id']}",
                    f"please ack {self.ev['event_id']}", f"ack {self.ev['event_id']} thanks", "ack not-a-uuid"):
            self.assertIsNone(zw.ACK_RE.match(bad), bad)

    def test_ack_consumed_marks_acked(self):
        self.assertEqual(zw.consume_ack(self.ob, self.ev["event_id"], NOW_TS), "acked")
        self.assertEqual(self.ev["status"], "acked")

    def test_unknown_event_id_is_a_no_op(self):
        self.assertEqual(zw.consume_ack(self.ob, new_id(), NOW_TS), "unknown")
        self.assertEqual(self.ev["status"], "pending")  # untouched

    def test_duplicate_ack_is_a_no_op(self):
        zw.consume_ack(self.ob, self.ev["event_id"], NOW_TS)
        self.assertEqual(zw.consume_ack(self.ob, self.ev["event_id"], NOW_TS + 5), "duplicate")

    def test_tombstone_dedupe_after_ack(self):
        zw.consume_ack(self.ob, self.ev["event_id"], NOW_TS)
        zw.tombstone_finished(self.ob, NOW_TS + 1)
        self.assertEqual(self.ob["events"], [])
        self.assertEqual(len(self.ob["tombstones"]), 1)
        # A duplicate ack after tombstoning is STILL a no-op, not "unknown".
        self.assertEqual(zw.consume_ack(self.ob, self.ev["event_id"], NOW_TS + 2), "duplicate")

    def test_failed_events_are_tombstoned_too(self):
        poster = lambda *a: (False, False, "x")  # noqa: E731
        t = NOW_TS
        for _ in range(zw.MAX_ATTEMPTS):
            zw.tick(self.ob, "C0C6R1HLM0C", "tok", t, poster=poster)
            t = zw._next_retry_ts(self.ev) if self.ev["status"] == "pending" else t
        self.assertEqual(self.ev["status"], "failed")
        zw.tombstone_finished(self.ob, t + 1)
        self.assertEqual(self.ob["events"], [])
        self.assertEqual(self.ob["tombstones"][0]["status"], "failed")


class Retention(unittest.TestCase):
    def test_tombstones_age_out_after_30_days(self):
        ob = zw.new_outbox()
        ob["tombstones"] = [
            {"event_id": "old", "kind": "blocked", "ref": "rtask_x", "status": "acked",
             "at": zw._iso(NOW_TS - 31 * 86400)},
            {"event_id": "recent", "kind": "blocked", "ref": "rtask_y", "status": "acked",
             "at": zw._iso(NOW_TS - 1 * 86400)},
        ]
        zw.prune_tombstones(ob, NOW_TS)
        self.assertEqual([t["event_id"] for t in ob["tombstones"]], ["recent"])

    def test_hard_cap_drops_oldest_first_never_touches_pending_events(self):
        ob = zw.new_outbox()
        ref = "rtask_live_deadbeef"
        live = zw.raise_event(ob, "blocked", ref, "k", {ref}, NOW_TS)
        ob["tombstones"] = [{"event_id": f"t{i}", "kind": "blocked", "ref": "rtask_x", "status": "acked",
                              "at": zw._iso(NOW_TS - (zw.TOMBSTONE_HARD_CAP + 10 - i))}
                             for i in range(zw.TOMBSTONE_HARD_CAP + 10)]
        zw.prune_tombstones(ob, NOW_TS)
        self.assertEqual(len(ob["tombstones"]), zw.TOMBSTONE_HARD_CAP)
        self.assertEqual(ob["tombstones"][-1]["event_id"], f"t{zw.TOMBSTONE_HARD_CAP + 9}")  # newest kept
        self.assertEqual(ob["events"], [live])  # pending row untouched regardless of tombstone volume


# ── publisher wiring: the one safety-critical path, proved against a real
# pub.main() tick with a fixture hub/registry, exactly like verify-publisher.py ──
TMP = Path(tempfile.mkdtemp(prefix="herdr-mcp-zw-verify-"))


class Hub(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        doc = {"/herdr?json=1": {"tasks": [], "live": {"connected": True}, "herdr_reachable": True},
               "/api/panes": {"panes": []}, "/api/summary": {"rev": 1, "live_connected": True}}.get(self.path, {})
        body = json.dumps(doc).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


hub = HTTPServer(("127.0.0.1", 0), Hub)
threading.Thread(target=hub.serve_forever, daemon=True).start()

FAKE_DELIVER = TMP / "fake-deliver.sh"
FAKE_DELIVER.write_text('#!/bin/bash\nfor a in "$@"; do printf "%s\\0" "$a"; done > "$FAKE_ARGV"\nexit 0\n')
FAKE_DELIVER.chmod(0o755)

os.environ.update(HERDR_HUB_URL=f"http://127.0.0.1:{hub.server_port}", HERDR_RUN_REGISTRY=str(TMP / "no-registry.sqlite3"),
                   HERDR_STATE_DIR=str(TMP / "state"), HERDR_DELIVER=str(FAKE_DELIVER), FAKE_ARGV=str(TMP / "argv"),
                   HERDR_MCP_OWNER_INBOX="1", HERDR_MCP_INGEST_KEY="k" * 48)
spec = importlib.util.spec_from_file_location("publisher_zw", HERE / "publisher.py")
pub = importlib.util.module_from_spec(spec)
sys.modules["publisher_zw"] = pub
spec.loader.exec_module(pub)


class PublisherWiring(unittest.TestCase):
    def setUp(self):
        (TMP / "argv").unlink(missing_ok=True)
        pub.save_state({"audit_cursor": 0, "results": {}, "pending_acks": []})

    def test_ack_is_consumed_before_delivery_never_typed_never_calls_deliver_owner(self):
        event_id = new_id()
        st = pub.load_state()
        st["zero_wake"] = {"events": [{"event_id": event_id, "kind": "reply_ready", "ref": "oex_x",
                                        "state_key": "accepted", "first_at": zw._iso(NOW_TS), "last_at": zw._iso(NOW_TS),
                                        "attempts": 0, "status": "pending"}], "tombstones": []}
        pub.save_state(st)

        deliver_owner_calls = []
        owner_acks_seen = []
        real_post, real_deliver_owner = pub.post_sync, pub.deliver_owner

        def post(key, body):
            owner_acks_seen.extend(body.get("owner_acks") or [])
            if body["lease"]:
                return {"outbox": [], "commands": [],
                        "owner_outbox": [{"exchange_id": "oex_ack_1", "owner_label": pub.zw.OWNER_LABEL,
                                           "sender": "zero", "body": f"ack {event_id}"}],
                        "audit": [], "audit_cursor": 0, "owner_reply_results": []}
            return {"outbox": [], "commands": [], "owner_outbox": [], "audit": [], "audit_cursor": 0, "owner_reply_results": []}

        pub.post_sync = post
        pub.deliver_owner = lambda item, local: deliver_owner_calls.append(item) or {"exchange_id": item["exchange_id"], "outcome": "delivered"}
        try:
            self.assertEqual(pub.main([]), 0)
        finally:
            pub.post_sync, pub.deliver_owner = real_post, real_deliver_owner

        self.assertEqual(deliver_owner_calls, [], "an ack message must never reach deliver_owner")
        self.assertFalse((TMP / "argv").exists(), "an ack message must never be typed into any pane")
        self.assertEqual(owner_acks_seen, [{"exchange_id": "oex_ack_1", "outcome": "delivered"}])
        st = pub.load_state()
        self.assertEqual(st["zero_wake"]["events"][0]["status"], "acked")

    def test_a_duplicate_ack_is_still_delivered_back_to_the_worker_and_never_typed(self):
        event_id = new_id()
        st = pub.load_state()
        st["zero_wake"] = {"events": [], "tombstones": [{"event_id": event_id, "kind": "reply_ready", "ref": "oex_x",
                                                           "status": "acked", "at": zw._iso(NOW_TS)}]}
        pub.save_state(st)
        deliver_owner_calls = []
        owner_acks_seen = []
        real_post, real_deliver_owner = pub.post_sync, pub.deliver_owner

        def post(key, body):
            owner_acks_seen.extend(body.get("owner_acks") or [])
            if body["lease"]:
                return {"outbox": [], "commands": [],
                        "owner_outbox": [{"exchange_id": "oex_ack_2", "owner_label": pub.zw.OWNER_LABEL,
                                           "sender": "zero", "body": f"ack {event_id}"}],
                        "audit": [], "audit_cursor": 0, "owner_reply_results": []}
            return {"outbox": [], "commands": [], "owner_outbox": [], "audit": [], "audit_cursor": 0, "owner_reply_results": []}

        pub.post_sync = post
        pub.deliver_owner = lambda item, local: deliver_owner_calls.append(item) or {}
        try:
            self.assertEqual(pub.main([]), 0)
        finally:
            pub.post_sync, pub.deliver_owner = real_post, real_deliver_owner
        self.assertEqual(deliver_owner_calls, [])
        self.assertFalse((TMP / "argv").exists())
        self.assertEqual(owner_acks_seen, [{"exchange_id": "oex_ack_2", "outcome": "delivered"}])


if __name__ == "__main__":
    unittest.main(verbosity=1)
