// Replayable events (HERDR-REPLAYABLE-EVENTS-PLAN.md Phase 1): the
// versioned envelope on task_events, the immutable-duplicate check, the
// owner-reply-acceptance transaction's atomic owner.reply_ready insert, and
// list_events/wait_for_events' scope-bound, pruning-aware cursor contract.
// Every "fails without this change" claim in PROOF.md traces to a test
// here; see .handoffs/tmp/baseline-vs-branch.out for the before/after run.
import { env, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { EventPage, HerdrState } from "../src/state";
import type { Env } from "../src/types";
import { callTool, oauthToken, signedSync, snapshot, syncBody } from "./helpers";

const e = env as unknown as Env;
const fleet = () => e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));

const ownerSnapshot = (labels: { label: string; live: boolean }[] = [{ label: "conductor", live: true }]) =>
  snapshot({ owners: labels });

interface SyncReply { owner_reply_results: { exchange_id: string; owner_label: string; outcome: string }[] }
const syncJson = async (r: Response): Promise<SyncReply> => r.json();

// A listEvents/waitForEvents caller identity. client_name is irrelevant to
// scope (only email+client_id gate owner-private visibility); used across
// every test in this file, so always the same shape.
const caller = (email: string, clientId: string) => ({ email, client_id: clientId, client_name: "test" });

// The three internal (`private`) HerdrState methods this suite reaches
// directly -- the same "validated DO method, no live token can reach this
// edge case" pattern owner-inbox.test.ts already uses for `ownerReply`.
// Typed narrowly instead of `as any`: TS privacy is compile-time only, and
// `runInDurableObject` already crosses the DO/RPC boundary at runtime.
interface InternalEventHooks {
  insertEvent(nowMs: number, e: { eventId: string | null; remoteTaskId: string; type: string; source: string;
    subjectKind: string; subjectId: string; visibility: "public" | "owner_private"; senderActor: string;
    senderClient: string; correlationId: string; data: Record<string, unknown> }):
    { outcome: "accepted" | "duplicate_same_payload" | "rejected:duplicate_payload_mismatch"; cursor: number | null };
  recordTaskEvent(nowMs: number, remoteTaskId: string, type: string, detail?: Record<string, unknown>): void;
  raiseReplayFloor(candidateMax: number | null): void;
}
const internal = (o: HerdrState) => o as unknown as InternalEventHooks;

// The REAL (email, client_id) that sent an exchange -- never guessed: a real
// OAuth client (oauthToken's DCR flow) gets a provider-generated client_id,
// not a fixed test string, and owner-private visibility is gated on exactly
// that pair. Reads storage directly (DurableObjectStorage, not an RPC
// method), the same way queueRaw/queueRawOwner in helpers.ts do.
async function senderOf(exchangeId: string): Promise<{ email: string; client_id: string; client_name: string }> {
  const row = await runInDurableObject(fleet(), (_o: HerdrState, state) =>
    state.storage.sql.exec<{ sender_actor: string; sender_client: string }>(
      `SELECT sender_actor, sender_client FROM owner_messages WHERE exchange_id=?`, exchangeId).toArray()[0]);
  if (!row) throw new Error(`no owner_messages row for ${exchangeId}`);
  return caller(row.sender_actor, row.sender_client);
}

beforeEach(() => reset());

// A delivered owner exchange, ready for a reply -- exactly owner-inbox.test.ts's own fixture.
async function deliveredExchange(access_token: string, clientMsgId = "cm1") {
  const sent = await callTool<{ exchange_id: string }>(access_token, "send_owner_message",
    { owner_label: "conductor", body: "hi", client_msg_id: clientMsgId });
  await signedSync(syncBody({ snapshot: ownerSnapshot() })); // lease
  await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_acks: [{ exchange_id: sent.data.exchange_id, outcome: "delivered" }] }));
  return sent.data.exchange_id;
}

// Delivers and replies to a fresh owner exchange in one shot; returns its exchange_id.
async function deliveredExchangeAndReply(access_token: string, clientMsgId: string): Promise<string> {
  const id = await deliveredExchange(access_token, clientMsgId);
  await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [
    { exchange_id: id, owner_label: "conductor", body: "reply body", responded_at: new Date().toISOString(),
      artifact_revision: "", session: "w1:p1" },
  ] }));
  return id;
}

describe("owner.reply_ready: envelope and acceptance", () => {
  it("is minted atomically with the status transition, carries no reply text, and is visible only to the original sender", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const id = await deliveredExchange(access_token);

    const reply = { exchange_id: id, owner_label: "conductor", body: "the secret answer is 42",
      responded_at: new Date().toISOString(), artifact_revision: "sha256:abc", session: "w5B:pG" };
    const first = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [reply] })));
    expect(first.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "accepted" }]);

    const mine = await senderOf(id);
    const page = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, mine, 500));
    const ev = page.events.find((x) => x.type === "owner.reply_ready");
    expect(ev).toBeDefined();
    expect(ev?.subject).toEqual({ kind: "owner_exchange", id });
    expect(ev?.source).toBe("owner_inbox");
    expect(ev?.event_id).toBe(`hev:worker:owner_reply:${id}:sha256:abc`);
    // SPEC item 4: "the events carry no reply text" -- data is owner_label only.
    expect(JSON.stringify(ev?.detail)).not.toContain("secret answer");
    expect(ev?.detail).toEqual({ owner_label: "conductor" });

    // Plan section 7: visible only within the tenant and to the original sender/client.
    const intruder = caller("intruder@teamthurber.com", "c-other");
    const theirPage = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, intruder, 500));
    expect(theirPage.events.some((x) => x.type === "owner.reply_ready")).toBe(false);
    // A different CLIENT under the SAME email is equally excluded (sender is actor+client, not actor alone).
    const otherClient = caller("tnt@teamthurber.com", "c-different");
    const otherClientPage = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, otherClient, 500));
    expect(otherClientPage.events.some((x) => x.type === "owner.reply_ready")).toBe(false);
  });

  it("a retried sync recovers the SAME event (no second row, same cursor) -- duplicate_same_payload", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const id = await deliveredExchange(access_token);
    const reply = { exchange_id: id, owner_label: "conductor", body: "ok", responded_at: new Date().toISOString(),
      artifact_revision: "rev1", session: "w1:p1" };

    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [reply] }));
    const mine = await senderOf(id);
    const after1 = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, mine, 500));
    const firstEvent = after1.events.find((x) => x.type === "owner.reply_ready");
    expect(firstEvent).toBeDefined();
    const firstCursor = firstEvent?.cursor;

    // A lost ack: the SAME sync is retried verbatim (status is already 'replied',
    // so this exercises the owner_messages-level duplicate branch, not insertEvent
    // directly -- which is exactly the real retry path).
    const retry = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [reply] })));
    expect(retry.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "duplicate" }]);

    const after2 = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, mine, 500));
    const replyReadyEvents = after2.events.filter((x) => x.type === "owner.reply_ready");
    expect(replyReadyEvents).toHaveLength(1); // never minted twice
    expect(replyReadyEvents[0]?.cursor).toBe(firstCursor); // the SAME durable event, not a new one
  });

  it("a guarded/no-op update (body differs, or the exchange was never delivered) emits no event", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const id = await deliveredExchange(access_token);
    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [
      { exchange_id: id, owner_label: "conductor", body: "v1", responded_at: new Date().toISOString(),
        artifact_revision: "", session: "w1:p1" },
    ] }));
    const mine = await senderOf(id);
    const before = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, mine, 500));
    expect(before.events.filter((x) => x.type === "owner.reply_ready")).toHaveLength(1);

    // Owner changes their mind -- ignored:replied, never a second event (already pinned by owner-inbox.test.ts's own test).
    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [
      { exchange_id: id, owner_label: "conductor", body: "v2 -- changed my mind", responded_at: new Date().toISOString(),
        artifact_revision: "", session: "w1:p1" },
    ] }));
    const after = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, mine, 500));
    expect(after.events.filter((x) => x.type === "owner.reply_ready")).toHaveLength(1); // still exactly one -- the no-op minted nothing
  });

  it("a mismatched duplicate under the same event id is rejected, not silently accepted or overwritten", async () => {
    // Direct call: no legitimate caller can ever reuse one exchange's event_id
    // with a different payload (it's derived from exchange_id+artifact_revision,
    // and an exchange can only ever transition delivered->replied once) -- this
    // proves the generic dedupe mechanism itself, the way owner-inbox.test.ts
    // proves edge cases no live token can reach.
    const nowMs = Date.now();
    const insert = (data: Record<string, unknown>) => runInDurableObject(fleet(), (o: HerdrState) =>
      internal(o).insertEvent(nowMs, { eventId: "hev:test:collision", remoteTaskId: "", type: "owner.reply_ready",
        source: "owner_inbox", subjectKind: "owner_exchange", subjectId: "oex_x", visibility: "owner_private",
        senderActor: "tnt@teamthurber.com", senderClient: "c", correlationId: "oex_x", data }));
    const first = await insert({ owner_label: "conductor" });
    expect(first.outcome).toBe("accepted");
    const same = await insert({ owner_label: "conductor" });
    expect(same.outcome).toBe("duplicate_same_payload");
    expect(same.cursor).toBe(first.cursor);
    const mismatched = await insert({ owner_label: "other-tab" });
    expect(mismatched.outcome).toBe("rejected:duplicate_payload_mismatch");
    expect(mismatched.cursor).toBeNull();

    const mine = caller("tnt@teamthurber.com", "c");
    const page = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, mine, 500));
    expect(page.events.filter((x) => x.event_id === "hev:test:collision")).toHaveLength(1); // never duplicated or corrupted
  });

  it("publisher-originated input cannot forge owner.reply_ready or any other event: there is no field that sets type/event_id/visibility", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    // A hostile publisher reply payload trying to smuggle envelope-shaped
    // extras onto the one field it can reach (owner_replies) -- SyncSchema
    // (zod, no .passthrough()) strips unknown keys; the Worker's own
    // insertEvent call for owner.reply_ready reads type/source/visibility/
    // sender from ITS OWN constants and the validated owner_messages row,
    // never from the request body.
    const id = await deliveredExchange(access_token);
    const forged = {
      exchange_id: id, owner_label: "conductor", body: "hi", responded_at: new Date().toISOString(),
      artifact_revision: "", session: "w1:p1",
      // Not part of OwnerReplySync -- dropped by zod before this ever reaches sync()'s body.owner_replies.
      type: "task.finished", event_id: "hev:forged", visibility: "public", source: "owner_inbox",
    };
    const res = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [forged] })));
    expect(res.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "accepted" }]);

    const mine = await senderOf(id);
    const page = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, mine, 500));
    expect(page.events.some((x) => x.event_id === "hev:forged")).toBe(false); // the forged id never landed
    const ev = page.events.find((x) => x.type === "owner.reply_ready");
    expect(ev?.event_id).toBe(`hev:worker:owner_reply:${id}:none`); // the Worker's own derivation, not the attacker's
  });

  it("old-publisher/new-Worker skew: a legacy sync body (no new fields at all) still completes the transaction and mints the event", async () => {
    // SyncSchema itself is unchanged by this branch -- the envelope lives
    // entirely in task_events (D1), invisible to the publisher's wire
    // contract -- so a publisher that predates this branch (sends exactly
    // the fields syncBody() already sent before Phase 1) still works.
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const id = await deliveredExchange(access_token, "legacy1");
    const res = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [
      { exchange_id: id, owner_label: "conductor", body: "legacy reply", responded_at: new Date().toISOString(),
        artifact_revision: "", session: "w1:p1" },
    ] })));
    expect(res.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "accepted" }]);
    const mine = await senderOf(id);
    const page = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, mine, 500));
    expect(page.events.some((x) => x.type === "owner.reply_ready" && x.subject?.id === id)).toBe(true);
  });
});

describe("list_events/wait_for_events: pruning, scope and pagination", () => {
  const reader = caller("tnt@teamthurber.com", "c");

  it("an old cursor below the durable replay floor returns cursor_pruned, not a silently-empty ok page", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    // Raise the floor directly (same shape sync()'s own non-prefix prune
    // uses): a plain MIN(cursor) read would be misleading here on purpose.
    await runInDurableObject(fleet(), (o: HerdrState) => {
      internal(o).recordTaskEvent(Date.now(), "rt_old", "state_changed", { state: "running" });
      internal(o).raiseReplayFloor(50);
    });
    const page = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(1, null, reader, 100));
    expect(page.result).toBe("cursor_pruned");
    expect(page.events).toHaveLength(0);
    expect(page.replay_floor_cursor).toBe(50);
    // since_cursor=0 is never pruned (the documented "everything retained" start).
    const fromZero = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, reader, 100));
    expect(fromZero.result).toBe("ok");
  });

  it("a cursor replayed under a changed authorization scope returns cursor_scope_mismatch, not an empty ok page", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const first = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, reader, 100));
    expect(first.result).toBe("ok");
    const staleHash = "ffffffff"; // never matches reader's real scope_hash
    const mismatched = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, staleHash, reader, 100));
    expect(mismatched.result).toBe("cursor_scope_mismatch");
    // The caller's OWN scope_hash, echoed back, matches on the next call.
    const resumed = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, first.scope_hash, reader, 100));
    expect(resumed.result).toBe("ok");
  });

  it("scanned_through_cursor advances through a page of entirely-filtered (another sender's) owner events, so catch-up never stalls", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    for (let i = 0; i < 5; i++) await deliveredExchangeAndReply(access_token, `other${i}`);
    const after = caller("someone-else@teamthurber.com", "c2");
    const page = await runInDurableObject(fleet(), (o: HerdrState) => o.listEvents(0, null, after, 100));
    expect(page.events).toHaveLength(0); // none of the 5 owner.reply_ready events are theirs
    expect(page.scanned_through_cursor).toBeGreaterThan(0); // but the page still advanced past them
    expect(page.scanned_through_cursor).toBe(page.latest_cursor);
  });

  it("watcher recipe: catches up a reply created before startup, then observes a later one via wait_for_events", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const pre = await deliveredExchangeAndReply(access_token, "pre-watcher");

    // 1. Capture cursor and scope.
    const start = await callTool<EventPage>(access_token, "list_events", { since_cursor: 0, limit: 1 }); // limit=1 forces multi-page catch-up below
    expect(start.data.scope_hash).toBeTruthy();

    // 2. Multi-page catch-up until caught up to latest_cursor, finding the pre-existing reply.
    let cursor = start.data.scanned_through_cursor;
    let found = start.data.events.some((ev) => ev.type === "owner.reply_ready" && ev.subject?.id === pre);
    for (let i = 0; i < 20 && cursor < start.data.latest_cursor; i++) {
      const page = await callTool<EventPage>(access_token, "list_events",
        { since_cursor: cursor, since_scope_hash: start.data.scope_hash, limit: 2 });
      if (page.data.events.some((ev) => ev.type === "owner.reply_ready" && ev.subject?.id === pre)) found = true;
      cursor = page.data.scanned_through_cursor;
    }
    expect(found).toBe(true);

    // 3. A later reply, observed via wait_for_events from the caught-up cursor.
    const laterPromise = callTool<EventPage>(access_token, "wait_for_events",
      { since_cursor: cursor, since_scope_hash: start.data.scope_hash, timeout_s: 1 });
    const later = await deliveredExchangeAndReply(access_token, "post-watcher");
    const waited = await laterPromise;
    expect(waited.data.events.some((ev) => ev.type === "owner.reply_ready" && ev.subject?.id === later)).toBe(true);

    // 4. Fetch the reply separately (never carried in the event itself).
    const reply = await callTool<{ reply: { body: string } }>(access_token, "get_owner_reply", { exchange_id: later });
    expect(reply.data.reply.body).toBe("reply body");
  });
});
