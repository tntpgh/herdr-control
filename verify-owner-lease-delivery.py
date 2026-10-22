#!/usr/bin/env python3
"""Offline scratch-DB proofs for lib/owner_lease_delivery.py and its
off-by-default wiring in remote-mcp/publisher.py. No live registry, pane,
network or herdr call: the hub and the deliver script are faked."""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))  # publisher imports sanitize
import owner_lease as ol  # noqa: E402
import owner_lease_delivery as old  # noqa: E402

FAILS: list[str] = []
T0 = 1_800_000_000.0
TTL = 600
P1, B1 = "w1:p1", "term_aaa"
P2, B2 = "w1:p2", "term_bbb"


def case(name, cond):
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def scratch(max_open=2):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "owner.sqlite3")
    c = ol.connect(path)
    ol.migrate(c)
    ol.register_owner(c, "kb", "tntpgh/knowledge-base", max_open=max_open, now=T0)
    c.close()
    return path


def state(path, rid):
    c = ol.connect(path)
    try:
        r = c.execute("SELECT state, generation, detail FROM owner_requests WHERE request_id=?", (rid,)).fetchone()
        return r
    finally:
        c.close()


def holder_acquires(path, pane, birth, now):
    c = ol.connect(path)
    try:
        return ol.acquire(c, "kb", pane, birth, TTL, now)
    finally:
        c.close()


def main():
    # --- activation boundary ---
    case("off by default: no flag -> no gate", old.from_env({}) is None)
    case("flag without DB -> no gate", old.from_env({old.FLAG: "1"}) is None)
    case("DB without flag -> no gate", old.from_env({old.DB_ENV: "/x"}) is None)
    try:
        old.DeliveryGate("/nonexistent/owner.sqlite3")
        case("missing DB fails closed (never created)", False)
    except FileNotFoundError:
        case("missing DB fails closed (never created)", not os.path.exists("/nonexistent/owner.sqlite3"))

    # --- normal path ---
    path = scratch()
    g = old.DeliveryGate(path)
    case("no lease -> blocked owner_no_lease, nothing queued",
         g.admit("kb", P1, B1, "oex_1", T0).reason == "owner_no_lease" and state(path, "oex_1") is None)
    gen1 = holder_acquires(path, P1, B1, T0)
    a = g.admit("kb", P1, B1, "oex_1", T0 + 1)
    case("holder == registered pane: admitted QUEUED in its generation (not yet delivering)",
         a.ok and a.generation == gen1 and state(path, "oex_1")[0] == "queued")
    case("CRASH before typing: same-generation queued request is re-admitted",
         g.admit("kb", P1, B1, "oex_1", T0 + 1.5).ok and state(path, "oex_1")[0] == "queued")
    case("begin_notice moves queued -> delivering immediately before typing",
         g.begin_notice("kb", P1, B1, gen1, "oex_1", T0 + 1.8) == "delivering")
    case("CRASH after begin_notice: delivering is ambiguous and never re-admitted",
         g.admit("kb", P1, B1, "oex_1", T0 + 1.9).reason == "owner_lease_duplicate:delivering")
    case("delivered keeps delivering (typed notice is not a reply)",
         g.settle("kb", P1, B1, gen1, "oex_1", "delivered", now=T0 + 2) == "delivering")
    case("reply in the current generation -> replied", g.on_reply("kb", "oex_1", T0 + 3) == "replied")
    case("NO FALSE COMPLETION: replied is not evidence", state(path, "oex_1")[0] == "replied")
    try:
        g.record_evidence("kb", "oex_1", "  ", T0 + 4)
        case("evidence needs a non-empty ref", False)
    except ValueError:
        case("evidence needs a non-empty ref", state(path, "oex_1")[0] == "replied")
    case("explicit evidence ref -> evidence",
         g.record_evidence("kb", "oex_1", "PROOF.md@abc123", T0 + 5) == "evidence")
    case("duplicate id never regains authority",
         g.admit("kb", P1, B1, "oex_1", T0 + 6).reason == "owner_lease_duplicate:evidence")
    try:
        g.on_reply("kb", "oex_never", T0 + 6)
        unknown = g.on_reply("kb", "oex_never", T0 + 6) == "unknown"
    except Exception:
        unknown = False
    case("reply for an unknown exchange credits nothing", unknown)

    # --- fenced / denied / held ---
    case("registered pane is not the lease holder -> fenced, nothing queued",
         g.admit("kb", P2, B2, "oex_2", T0 + 7).reason == "owner_lease_fenced" and state(path, "oex_2") is None)
    case("same pane, different birth -> fenced", g.admit("kb", P1, "term_zzz", "oex_2", T0 + 7).reason == "owner_lease_fenced")
    a3 = g.admit("kb", P1, B1, "oex_3", T0 + 8)
    g.begin_notice("kb", P1, B1, a3.generation, "oex_3", T0 + 8)
    g.settle("kb", P1, B1, a3.generation, "oex_3", "blocked", "owner_at_approval_prompt", T0 + 9)
    case("approval prompt (pre-send) -> blocked retry:approval", state(path, "oex_3")[:3:2] == ("blocked", old.RETRY_APPROVAL))
    case("retryable pre-send block goes back to QUEUED next tick",
         g.admit("kb", P1, B1, "oex_3", T0 + 10).ok and state(path, "oex_3")[0] == "queued"
         and g.begin_notice("kb", P1, B1, a3.generation, "oex_3", T0 + 10) == "delivering")
    a4 = g.admit("kb", P1, B1, "oex_4", T0 + 11)
    g.begin_notice("kb", P1, B1, a4.generation, "oex_4", T0 + 11)
    g.settle("kb", P1, B1, a4.generation, "oex_4", "blocked", "deliver_failed:4", T0 + 12)
    case("post-type uncertainty -> blocked and NEVER re-admitted (no retype)",
         g.admit("kb", P1, B1, "oex_4", T0 + 13).reason == "owner_lease_duplicate:blocked")
    case("queue bound: max_open=2 open requests -> owner_queue_full",
         g.admit("kb", P1, B1, "oex_5", T0 + 14).reason == "owner_queue_full" and state(path, "oex_5") is None)
    case("blocked delivery is not a reply", g.on_reply("kb", "oex_4", T0 + 14) == "not_delivering")

    # --- stale generation ---
    gen2 = holder_acquires(path, P2, B2, T0 + TTL + 20)  # P1's lease expired; P2 takes over
    case("new generation disposes older open requests stale", gen2 == gen1 + 1 and state(path, "oex_3")[0] == "stale")
    case("STALE: reply to the superseded generation credits nothing", g.on_reply("kb", "oex_3", T0 + TTL + 21) == "stale"
         and state(path, "oex_3")[0] == "stale")
    case("old holder can no longer be admitted", g.admit("kb", P1, B1, "oex_6", T0 + TTL + 22).reason == "owner_lease_fenced")
    case("settle by the old generation is refused (unrecorded)",
         g.settle("kb", P1, B1, gen1, "oex_3", "blocked", "x", T0 + TTL + 22) == "unrecorded")
    a7 = g.admit("kb", P2, B2, "oex_7", T0 + TTL + 23)
    case("new holder admitted in the new generation", a7.ok and a7.generation == gen2
         and g.begin_notice("kb", P2, B2, gen2, "oex_7", T0 + TTL + 23) == "delivering")
    case("settle refusal is surfaced as 'unrecorded' (stale generation)",
         g.settle("kb", P2, B2, gen1, "oex_7", "blocked", "x", T0 + TTL + 23) == "unrecorded")

    # --- lease lifetime at begin_notice ---
    lt = scratch()
    gl = old.DeliveryGate(lt)
    c = ol.connect(lt)
    ol.acquire(c, "kb", P1, B1, old.MIN_LEASE_REMAINING_S + 10, T0)
    c.close()
    al = gl.admit("kb", P1, B1, "oex_l", T0)
    case("lease with >= timeout+margin left: begin_notice delivers",
         gl.begin_notice("kb", P1, B1, al.generation, "oex_l", T0 + 5) == "delivering")
    al2 = gl.admit("kb", P1, B1, "oex_l2", T0 + 20)
    case("LIFETIME: expires>now but < 120s timeout + 60s margin left -> lease_too_short, stays queued",
         gl.begin_notice("kb", P1, B1, al2.generation, "oex_l2", T0 + 20) == "lease_too_short"
         and state(lt, "oex_l2")[0] == "queued")
    c = ol.connect(lt)
    ol.acquire(c, "kb", P1, B1, 600, T0 + 21)  # holder renews
    c.close()
    case("after renewal the queued request proceeds",
         gl.begin_notice("kb", P1, B1, al2.generation, "oex_l2", T0 + 22) == "delivering")
    gl.close()

    # --- restart ---
    g.close()
    g2 = old.DeliveryGate(path)
    case("RESTART: durable state survives a new gate instance", g2.state("oex_7") == "delivering")
    a9 = g2.admit("kb", P2, B2, "oex_9", T0 + TTL + 23.5)
    g2.close()
    g3 = old.DeliveryGate(path)
    case("RESTART: queued (never typed) request recovers after restart",
         g3.admit("kb", P2, B2, "oex_9", T0 + TTL + 23.6).ok and a9.ok and g3.state("oex_9") == "queued")
    g3.close()
    g2 = old.DeliveryGate(path)
    case("RESTART: replay of a delivered id gets no authority",
         g2.admit("kb", P2, B2, "oex_7", T0 + TTL + 24).reason == "owner_lease_duplicate:delivering")
    case("RESTART: reply after restart credits once", g2.on_reply("kb", "oex_7", T0 + TTL + 25) == "replied"
         and g2.on_reply("kb", "oex_7", T0 + TTL + 26) == "not_delivering")

    # --- disabled (rollback) fails closed ---
    c = ol.connect(path)
    ol.disable(c, T0 + TTL + 30)
    c.close()
    case("disabled contract: delivery blocked owner_lease_disabled, nothing queued",
         g2.admit("kb", P2, B2, "oex_8", T0 + TTL + 31).reason == "owner_lease_disabled" and g2.state("oex_8") is None)
    g2.close()

    # --- publisher wiring (fake hub + fake deliver; no network) ---
    tmp = Path(tempfile.mkdtemp())
    fake = tmp / "deliver.sh"
    fake.write_text('#!/bin/bash\necho "$1" >> "$FAKE_LOG"\nexit "${FAKE_RC:-0}"\n')
    fake.chmod(0o755)
    os.environ.update(HERDR_STATE_DIR=str(tmp / "state"), HERDR_DELIVER=str(fake), FAKE_LOG=str(tmp / "log"),
                      HERDR_RUN_REGISTRY=str(tmp / "none.sqlite3"), HERDR_MCP_OWNER_INBOX="1",
                      HERDR_HUB_URL="http://127.0.0.1:9")
    for k in (old.FLAG, old.DB_ENV):
        os.environ.pop(k, None)
    spec = importlib.util.spec_from_file_location("publisher_lease", HERE / "remote-mcp" / "publisher.py")
    pub = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pub)
    pub.INBOX_ROOT = tmp / "inbox"
    pub.hub_get = lambda _p: {"panes": [{"pane_id": P1, "birth": B1, "agent": "omp"}]}
    local = {"owners": {"kb": {"pane_id": P1, "pane_birth": B1}}}
    item = lambda eid: {"exchange_id": eid, "owner_label": "kb", "sender": "tnt", "body": "hello"}
    delivered = lambda: (tmp / "log").read_text().count("\n") if (tmp / "log").exists() else 0

    case("publisher, flag OFF: legacy delivery unchanged, no gate loaded",
         pub.owner_lease_gate() is None and pub.deliver_owner(item("oex_p1"), local)["outcome"] == "delivered" and delivered() == 1)
    lpath = scratch(max_open=10)
    os.environ.update({old.FLAG: "1", old.DB_ENV: lpath})
    pub._OWNER_LEASE_GATE = None
    r = pub.deliver_owner(item("oex_p2"), local)
    case("publisher, flag ON, no lease: blocked BEFORE body write or notice",
         r == {"exchange_id": "oex_p2", "outcome": "blocked", "reason": "owner_no_lease"} and delivered() == 1
         and not (tmp / "inbox" / "kb" / "messages" / "oex_p2.md").exists())
    holder_acquires(lpath, P1, B1, __import__("time").time())
    r = pub.deliver_owner(item("oex_p3"), local)
    case("publisher, flag ON, holder matches: delivered and recorded delivering",
         r["outcome"] == "delivered" and delivered() == 2 and state(lpath, "oex_p3")[0] == "delivering")
    # crash after body write, before typing: request queued, body on disk
    gq = old.DeliveryGate(lpath)
    gq.admit("kb", P1, B1, "oex_pc", __import__("time").time())
    gq.close()
    pub.write_inbox_message("kb", "oex_pc", "tnt", "hello")
    r = pub.deliver_owner(item("oex_pc"), local)
    case("publisher CRASH RECOVERY: queued + same body -> delivered once",
         r["outcome"] == "delivered" and delivered() == 3 and state(lpath, "oex_pc")[0] == "delivering")
    gq = old.DeliveryGate(lpath)
    gq.admit("kb", P1, B1, "oex_pm", __import__("time").time())
    gq.close()
    pub.write_inbox_message("kb", "oex_pm", "tnt", "ORIGINAL body")
    r = pub.deliver_owner(item("oex_pm"), local)  # replay carries body "hello"
    case("publisher CHANGED-BODY REPLAY: same id, different payload -> blocked, no notice",
         r.get("reason") == "owner_payload_mismatch" and delivered() == 3
         and state(lpath, "oex_pm")[:3:2] == ("blocked", "owner_payload_mismatch"))
    r = pub.deliver_owner({**item("oex_pm"), "sender": "someone-else", "body": "ORIGINAL body"}, local)
    case("publisher: changed sender with original body is also refused", r.get("reason", "").startswith("owner_lease_duplicate") and delivered() == 3)
    r = pub.deliver_owner(item("oex_p3"), local)
    case("publisher: re-delivery of the same exchange refused (no second notice)",
         r["reason"] == "owner_lease_duplicate:delivering" and delivered() == 3)
    os.environ["FAKE_RC"] = "4"
    r = pub.deliver_owner(item("oex_p4"), local)
    case("publisher: rc 4 recorded blocked, not delivered",
         r["reason"] == "deliver_failed:4" and state(lpath, "oex_p4")[0] == "blocked")
    delivered_before_missing = delivered()
    os.environ.pop("FAKE_RC")
    os.environ[old.DB_ENV] = str(tmp / "missing.sqlite3")
    pub._OWNER_LEASE_GATE = None
    try:
        pub.deliver_owner(item("oex_p5"), local)
        case("publisher, flag ON, missing DB: tick fails, never ungated", False)
    except FileNotFoundError:
        case("publisher, flag ON, missing DB: tick fails, never ungated", delivered() == delivered_before_missing)

    print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
