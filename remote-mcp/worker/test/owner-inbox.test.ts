// send_owner_message / get_owner_message_status / get_owner_reply: a note to a
// NAMED OWNING SESSION (register-owner.sh), never a spawned task's agent. The
// body never reaches a pane as typed text -- only owner_acks/owner_replies
// (what the Mac's publisher.py reports back) can move an exchange out of
// 'queued', so every blocked state here is driven through sync(), exactly as
// the real publisher would report it.
import { SELF, env, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { HerdrState, OwnerMessageRecord, OwnerReplyRecord } from "../src/state";
import type { Env } from "../src/types";
import { callTool, oauthToken, queueRawOwner, signedSync, snapshot, syncBody } from "./helpers";

const e = env as unknown as Env;
const fleet = () => e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));

interface SyncReply { owner_outbox: { exchange_id: string; owner_label: string; body: string }[];
  audit: { tool: string; decision: string; reason: string; message_id: string }[];
  owner_reply_results: { exchange_id: string; owner_label: string; outcome: string }[] }
const syncJson = async (r: Response): Promise<SyncReply> => r.json();

const ownerSnapshot = (labels: { label: string; live: boolean }[] = [{ label: "conductor", live: true }]) =>
  snapshot({ owners: labels });

beforeEach(() => reset());

describe("send_owner_message", () => {
  it("does not offer send_owner_message to a read-only token, and audits a call to it anyway", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read"]);
    const r = await callTool(access_token, "send_owner_message", { owner_label: "conductor", body: "hi", client_msg_id: "cm1" });
    expect(r.isError).toBe(true);
    const { audit } = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    expect(audit.filter((a) => a.tool === "send_owner_message").map((a) => a.decision)).toEqual(["refused"]);
  });

  it("refuses an unregistered or syntactically-invalid owner label without ever queuing", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const reason = async (owner_label: string) =>
      (await callTool(access_token, "send_owner_message", { owner_label, body: "hi", client_msg_id: `cm-${owner_label}` })).data.error;
    expect(await reason("no-such-owner")).toBe("owner_not_registered");
    expect(await reason("Bad_Label")).toBe("owner_label_invalid");
    expect((await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })))).owner_outbox).toHaveLength(0);
  });

  it("refuses while the Mac is disconnected", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const out = await runInDurableObject(fleet(), (o: HerdrState) =>
      o.sendOwnerMessage(Date.now() + 120_000, { email: "tnt@teamthurber.com", client_id: "c", client_name: "Zero" },
        ["herdr:read", "herdr:message.owner"], "conductor", "hi", "cm1"));
    expect(out.ok).toBe(false);
    if (out.ok) throw new Error("unreachable");
    expect(out.reason).toMatch(/^not_connected/);
  });

  it("queues, leases once to the publisher, and records delivered on ack", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const sent = await callTool<{ exchange_id: string; state: string }>(access_token, "send_owner_message",
      { owner_label: "conductor", body: "line one\nline two", client_msg_id: "cm1" });
    expect(sent.data.state).toBe("queued");
    const id = sent.data.exchange_id;

    const first = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    expect(first.owner_outbox.map((m) => [m.exchange_id, m.owner_label, m.body])).toEqual([[id, "conductor", "line one\nline two"]]);
    expect((await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })))).owner_outbox).toHaveLength(0);

    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_acks: [{ exchange_id: id, outcome: "delivered" }] }));
    const status = await callTool<{ owner_message: OwnerMessageRecord }>(access_token, "get_owner_message_status", { exchange_id: id });
    expect(status.data.owner_message.status).toBe("delivered");
  });

  it("dedupes a retried client_msg_id: returns the ORIGINAL exchange_id and state, even with a different body", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const first = await callTool<{ exchange_id: string; state: string }>(access_token, "send_owner_message",
      { owner_label: "conductor", body: "first body", client_msg_id: "same-id" });
    const retry = await callTool<{ exchange_id: string; state: string }>(access_token, "send_owner_message",
      { owner_label: "no-such-owner", body: "this would fail validation", client_msg_id: "same-id" });
    expect(retry.data).toEqual(first.data);
    expect((await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })))).owner_outbox).toHaveLength(1);
  });

  it("rate-limits a burst at 10/minute, independent of the generic per-client throttle", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const outcomes: string[] = [];
    for (let i = 0; i < 11; i++) {
      outcomes.push((await callTool(access_token, "send_owner_message",
        { owner_label: "conductor", body: `n${i}`, client_msg_id: `cm${i}` })).data.error ?? "ok");
    }
    expect(outcomes).toEqual([...Array(10).fill("ok"), "rate_limited"]);
  });

  it("rate-limits at 120/hour even when no single minute is over 10", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const zero = { email: "tnt@teamthurber.com", client_id: "c", client_name: "Zero" };
    const scopes = ["herdr:read", "herdr:message.owner"];
    const now = Date.now();
    const out = await runInDurableObject(fleet(), (o: HerdrState) => {
      const r: string[] = [];
      // 119 sends 29s apart (at most 3 in any minute) ending 99s ago, then two now.
      for (let i = 0; i < 119; i++) {
        const at = now - 99_000 - (118 - i) * 29_000;
        const s = o.sendOwnerMessage(at, zero, scopes, "conductor", `h${i}`, `ch${i}`);
        r.push(s.ok ? "ok" : s.reason);
      }
      for (const k of ["a", "b"]) {
        const s = o.sendOwnerMessage(now, zero, scopes, "conductor", k, `cn-${k}`);
        r.push(s.ok ? "ok" : s.reason);
      }
      return r;
    });
    expect(out.slice(0, 120)).toEqual(Array(120).fill("ok"));
    expect(out[120]).toBe("rate_limited (120/hour)");
  });

  it("reports the owner limits, not the send_message limits, in list_capabilities", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const caps = await callTool<{ owner_inbox: { limits: { per_minute: number; per_hour: number } } }>(access_token, "list_capabilities");
    expect(caps.data.owner_inbox.limits).toEqual({ per_minute: 10, per_hour: 120 });
  });

  it("cancels a queued owner message, never leasing it, once its sender's grant is revoked", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const sent = await callTool<{ exchange_id: string }>(access_token, "send_owner_message",
      { owner_label: "conductor", body: "hi", client_msg_id: "cm1" });
    const grants = await e.OAUTH_KV.list({ prefix: "grant:tnt@teamthurber.com:" });
    expect(grants.keys.length).toBeGreaterThan(0);
    for (const k of grants.keys) await e.OAUTH_KV.delete(k.name);

    const reply = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    expect(reply.owner_outbox).toHaveLength(0);
    const m = await runInDurableObject(fleet(), (o: HerdrState) => o.ownerMessageStatus(sent.data.exchange_id, "tnt@teamthurber.com"));
    expect([m?.status, m?.detail]).toEqual(["blocked:sender_revoked", "sender_revoked"]);
  });

  it("cancels a queued owner message whose sender has left the allowlist, and still delivers others", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const kept = await callTool<{ exchange_id: string }>(access_token, "send_owner_message",
      { owner_label: "conductor", body: "kept", client_msg_id: "cm1" });
    const gone = await runInDurableObject(fleet(), (_o: HerdrState, state) => queueRawOwner(state.storage, "conductor", "former@teamthurber.com"));

    const reply = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })));
    expect(reply.owner_outbox.map((m) => m.exchange_id)).toEqual([kept.data.exchange_id]);
    const m = await runInDurableObject(fleet(), (o: HerdrState) => o.ownerMessageStatus(gone, "former@teamthurber.com"));
    expect([m?.status, m?.detail]).toEqual(["blocked:sender_revoked", "sender_revoked"]);
  });
});

describe("blocked states reported by the publisher's own ack", () => {
  const reasons = ["owner_not_registered", "owner_pane_gone", "owner_identity_changed", "deliver_failed:5", "deliver_failed:7"];
  for (const reason of reasons) {
    it(`finalizes blocked:${reason} on first report`, async () => {
      await signedSync(syncBody({ snapshot: ownerSnapshot() }));
      const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
      const sent = await callTool<{ exchange_id: string }>(access_token, "send_owner_message",
        { owner_label: "conductor", body: "hi", client_msg_id: `cm-${reason}` });
      await signedSync(syncBody({ snapshot: ownerSnapshot() })); // lease it
      await signedSync(syncBody({ snapshot: ownerSnapshot(), lease: false, owner_acks: [{ exchange_id: sent.data.exchange_id, outcome: "blocked", reason }] }));
      const status = await callTool<{ owner_message: OwnerMessageRecord }>(access_token, "get_owner_message_status", { exchange_id: sent.data.exchange_id });
      expect(status.data.owner_message.status).toBe(`blocked:${reason}`);
    });
  }

  it("retries owner_at_approval_prompt on later ticks, then finalizes blocked after the retry cap", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const sent = await callTool<{ exchange_id: string }>(access_token, "send_owner_message",
      { owner_label: "conductor", body: "hi", client_msg_id: "cm1" });
    const id = sent.data.exchange_id;

    // 9 lease+approval-prompt-ack round trips: each must requeue, not finalize.
    for (let i = 0; i < 9; i++) {
      const outbox = (await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot() })))).owner_outbox;
      expect(outbox.map((m) => m.exchange_id)).toEqual([id]);
      await signedSync(syncBody({ snapshot: ownerSnapshot(), lease: false, owner_acks: [{ exchange_id: id, outcome: "blocked", reason: "owner_at_approval_prompt" }] }));
      const status = await callTool<{ owner_message: OwnerMessageRecord }>(access_token, "get_owner_message_status", { exchange_id: id });
      expect(status.data.owner_message.status).toBe("queued");
    }
    // The 10th attempt exhausts APPROVAL_RETRY_CAP: stays blocked.
    await signedSync(syncBody({ snapshot: ownerSnapshot() })); // lease, attempts -> 10
    await signedSync(syncBody({ snapshot: ownerSnapshot(), lease: false, owner_acks: [{ exchange_id: id, outcome: "blocked", reason: "owner_at_approval_prompt" }] }));
    const final = await callTool<{ owner_message: OwnerMessageRecord }>(access_token, "get_owner_message_status", { exchange_id: id });
    expect(final.data.owner_message.status).toBe("blocked:owner_at_approval_prompt");
  });
});

describe("busy-pane owner notice retries", () => {
  const actor = "tnt@teamthurber.com";
  const gate = { revoked: [], hold: false };
  async function tick(now: number, over: Parameters<typeof syncBody>[0] = {},
      revoked: { actor: string; client_id: string }[] = [], hold = false) {
    const out = await runInDurableObject(fleet(), (o: HerdrState) =>
      o.sync(now, crypto.randomUUID(), JSON.stringify(syncBody({ snapshot: ownerSnapshot(), ...over })),
        gate, gate, { revoked, hold }));
    if (!out.ok) throw new Error(out.reason);
    return out.response;
  }
  const status = (id: string) =>
    runInDurableObject(fleet(), (o: HerdrState) => o.ownerMessageStatus(id, actor));
  const busy = (id: string) => ({ exchange_id: id, outcome: "blocked" as const, reason: "deliver_failed:4" });
  const reply = (id: string) => ({ exchange_id: id, owner_label: "conductor", body: "owner answer",
    responded_at: new Date().toISOString(), artifact_revision: "r1", session: "opaque-session" });
  async function queued() {
    return runInDurableObject(fleet(), (_o: HerdrState, state) => queueRawOwner(state.storage));
  }

  it("backs off without marking delivered, then delivers on the next eligible tick", async () => {
    const id = await queued();
    const now = Date.now();
    expect((await tick(now)).owner_outbox.map((m) => m.exchange_id)).toEqual([id]);
    const ack = await tick(now + 1, { owner_acks: [busy(id)] });
    expect(ack.owner_outbox).toEqual([]);
    expect((await status(id))?.status).toBe("queued");
    expect(ack.audit.filter((a) => a.message_id === id).map((a) => a.decision)).toEqual(["retry"]);
    expect((await tick(now + 15_000)).owner_outbox).toEqual([]);
    expect((await tick(now + 15_001)).owner_outbox.map((m) => [m.exchange_id, m.attempts])).toEqual([[id, 2]]);
    await tick(now + 15_002, { lease: false, owner_acks: [{ exchange_id: id, outcome: "delivered" }] });
    expect((await status(id))?.status).toBe("delivered");
    expect((await tick(now + 100_000)).owner_outbox).toEqual([]);
  });

  it("caps exponential backoff at 60s and terminates the tenth busy attempt as deliver_failed:4", async () => {
    const id = await queued();
    let now = Date.now();
    for (let attempt = 1; attempt <= 10; attempt++) {
      expect((await tick(now)).owner_outbox.map((m) => [m.exchange_id, m.attempts])).toEqual([[id, attempt]]);
      await tick(now + 1, { lease: false, owner_acks: [busy(id)] });
      expect((await status(id))?.status).toBe(attempt < 10 ? "queued" : "blocked:deliver_failed:4");
      if (attempt < 10) {
        const delay = Math.min(15_000 * 2 ** (attempt - 1), 60_000);
        expect((await tick(now + delay)).owner_outbox).toEqual([]);
        now += delay + 1;
      }
    }
    expect((await tick(now + 120_000)).owner_outbox).toEqual([]);
    const late = await tick(now + 120_001, { owner_acks: [busy(id)], owner_replies: [reply(id)] });
    expect(late.owner_reply_results)
      .toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "ignored:blocked:deliver_failed:4" }]);
    expect((await status(id))?.status).toBe("blocked:deliver_failed:4");
  });

  for (const phase of ["queued", "delivering", "last-ack"] as const) {
    it(`accepts a reply during ${phase} retry without another notice lease`, async () => {
      const id = await queued();
      const now = Date.now();
      await tick(now);
      await tick(now + 1, { lease: false, owner_acks: [busy(id)] });
      if (phase !== "queued") await tick(now + 15_001);
      if (phase === "last-ack") {
        await runInDurableObject(fleet(), (_o: HerdrState, state) =>
          state.storage.sql.exec("UPDATE owner_messages SET attempts=10 WHERE exchange_id=?", id).toArray());
      }
      const out = await tick(now + 15_002, {
        owner_replies: [reply(id)], ...(phase === "last-ack" ? { owner_acks: [busy(id)] } : {}),
      });
      expect(out.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "accepted" }]);
      expect(out.owner_outbox).toEqual([]);
      expect((await status(id))?.status).toBe("replied");
      expect(await runInDurableObject(fleet(), (o: HerdrState) => o.ownerReply(id, actor)))
        .toMatchObject({ body: "owner answer" });
      expect((await tick(now + 15_003, { owner_replies: [reply(id)] })).owner_reply_results)
        .toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "duplicate" }]);
    });
  }

  it("keeps a reply transient when grant lookup holds the final busy ack, then accepts it", async () => {
    const id = await queued();
    const now = Date.now();
    await tick(now);
    await tick(now + 1, { lease: false, owner_acks: [busy(id)] });
    await tick(now + 15_001);
    await runInDurableObject(fleet(), (_o: HerdrState, state) =>
      state.storage.sql.exec("UPDATE owner_messages SET attempts=10 WHERE exchange_id=?", id).toArray());
    const held = await tick(now + 15_002, { owner_acks: [busy(id)], owner_replies: [reply(id)] }, [], true);
    expect(held.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "ignored:queued" }]);
    expect((await status(id))?.status).toBe("queued");
    const recovered = await tick(now + 15_003, { owner_replies: [reply(id)] });
    expect(recovered.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "accepted" }]);
    expect(recovered.owner_outbox).toEqual([]);
  });

  it("does not let a busy-retry reply bypass sender revocation or a mismatched owner", async () => {
    const id = await queued();
    const now = Date.now();
    await tick(now);
    await tick(now + 1, { lease: false, owner_acks: [busy(id)] });
    const mismatch = await tick(now + 2, { lease: false, owner_replies: [{ ...reply(id), owner_label: "other" }] });
    expect(mismatch.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "other", outcome: "ignored:missing" }]);
    const revoked = await tick(now + 3, { owner_replies: [reply(id)] }, [{ actor, client_id: "c" }]);
    expect(revoked.owner_reply_results[0]?.outcome).not.toBe("accepted");
    expect((await status(id))?.status).toBe("blocked:sender_revoked");
    expect(await runInDurableObject(fleet(), (o: HerdrState) => o.ownerReply(id, actor))).toBeNull();
  });
});

describe("get_owner_reply", () => {
  async function deliveredExchange(access_token: string) {
    const sent = await callTool<{ exchange_id: string }>(access_token, "send_owner_message",
      { owner_label: "conductor", body: "hi", client_msg_id: "cm1" });
    await signedSync(syncBody({ snapshot: ownerSnapshot() })); // lease
    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_acks: [{ exchange_id: sent.data.exchange_id, outcome: "delivered" }] }));
    return sent.data.exchange_id;
  }

  it("syncs a reply, readable only by the original sender", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const id = await deliveredExchange(access_token);

    const replyBody = { exchange_id: id, owner_label: "conductor", body: "ok, done", responded_at: new Date().toISOString(),
      artifact_revision: "sha256:abc", session: "w5B:pG" };
    const first = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [replyBody] })));
    // #225 review H1: the Mac only moves a reply to replies/sent/ once it
    // sees "accepted" (or "duplicate") here -- a 200 alone is not enough.
    expect(first.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "accepted" }]);

    const mine = await callTool<{ reply: OwnerReplyRecord }>(access_token, "get_owner_reply", { exchange_id: id });
    expect(mine.data.reply).toMatchObject({ exchange_id: id, owner_label: "conductor", body: "ok, done", session: "w5B:pG" });
    const status = await callTool<{ owner_message: OwnerMessageRecord }>(access_token, "get_owner_message_status", { exchange_id: id });
    expect(status.data.owner_message.status).toBe("replied");

    // A retried tick (a crash, or a lost ack) resends the exact same
    // file: the Worker must say "duplicate", not drop it silently, so
    // the Mac still moves it to replies/sent/ rather than resending it
    // forever.
    const retry = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [replyBody] })));
    expect(retry.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "duplicate" }]);

    // ALLOWED_EMAILS is a single address in this deployment, so "someone
    // else" cannot be reached through the real OAuth flow; call the
    // validated DO method directly, the same way readonly.test.ts probes
    // edge cases a live token can never reach.
    const theirs = await runInDurableObject(fleet(), (o: HerdrState) => o.ownerReply(id, "intruder@teamthurber.com"));
    expect(theirs).toBeNull();
  });

  it("reports ignored:replied (not duplicate) when a resend's body differs from what was stored (REVIEW-225-r2 N3)", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const id = await deliveredExchange(access_token);

    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [
      { exchange_id: id, owner_label: "conductor", body: "v1: approve", responded_at: new Date().toISOString(),
        artifact_revision: "", session: "w1:p1" },
    ] }));
    // The owner changes their mind and re-sends a DIFFERENT body for the
    // same exchange -- the Worker only ever stored v1; this must NEVER
    // be reported as "duplicate" (which the Mac reads as "safe to treat
    // as sent"), since the Mac would then move v2 into replies/sent/ as
    // if it had been delivered, with no record it was actually dropped.
    const second = await syncJson(await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [
      { exchange_id: id, owner_label: "conductor", body: "v2: actually, REJECT -- changed my mind",
        responded_at: new Date().toISOString(), artifact_revision: "", session: "w1:p1" },
    ] })));
    expect(second.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "ignored:replied" }]);

    const mine = await callTool<{ reply: OwnerReplyRecord }>(access_token, "get_owner_reply", { exchange_id: id });
    expect(mine.data.reply.body).toBe("v1: approve"); // the Worker's stored copy is still v1, untouched by v2
  });

  it("reports ignored:queued for a reply that arrives before the message is delivered", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const sent = await callTool<{ exchange_id: string }>(access_token, "send_owner_message",
      { owner_label: "conductor", body: "hi", client_msg_id: "cm-queued" });
    const id = sent.data.exchange_id;
    // Not yet leased/delivered: status is still 'queued'. #225 review H1's
    // realistic path -- an approval-prompt retry can put a DELIVERED
    // message back to 'queued' the same way.
    const reply = await syncJson(await signedSync(syncBody({
      snapshot: ownerSnapshot(),
      lease: false, // isolates the owner_replies outcome from this same call also leasing the message
      owner_replies: [{ exchange_id: id, owner_label: "conductor", body: "too early", responded_at: new Date().toISOString(),
        artifact_revision: "", session: "w1:p1" }],
    })));
    expect(reply.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "ignored:queued" }]);
    const status = await callTool<{ owner_message: OwnerMessageRecord }>(access_token, "get_owner_message_status", { exchange_id: id });
    expect(status.data.owner_message.status).toBe("queued"); // untouched, not silently consumed
  });

  it("ignores a reply whose own owner_label does not match the exchange's real target (header mismatch)", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot([{ label: "conductor", live: true }, { label: "other-tab", live: true }]) }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const id = await deliveredExchange(access_token);

    const reply = await syncJson(await signedSync(syncBody({
      snapshot: ownerSnapshot([{ label: "conductor", live: true }, { label: "other-tab", live: true }]),
      owner_replies: [{ exchange_id: id, owner_label: "other-tab", body: "spoofed", responded_at: new Date().toISOString(),
        artifact_revision: "", session: "w1:pX" }],
    })));
    expect(reply.owner_reply_results).toEqual([{ exchange_id: id, owner_label: "other-tab", outcome: "ignored:missing" }]);

    const status = await callTool<{ owner_message: OwnerMessageRecord }>(access_token, "get_owner_message_status", { exchange_id: id });
    expect(status.data.owner_message.status).toBe("delivered");
    const getReply = await callTool<{ error?: string }>(access_token, "get_owner_reply", { exchange_id: id });
    expect(getReply.data.error).toBe("not_found");
  });

  it("refuses a late reply from reviving an already-cancelled blocked:sender_revoked message (REVIEW-219 M3)", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const sent = await callTool<{ exchange_id: string }>(access_token, "send_owner_message",
      { owner_label: "conductor", body: "hi", client_msg_id: "cm-m3" });
    const id = sent.data.exchange_id;

    // Leased (status -> delivering), as if the Mac picked it up this tick
    // but the ack for "delivered" never made it back (a crash, a dropped
    // sync, or simply the next tick running first).
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));

    // The sender's grant is pulled before that ack ever arrives.
    const grants = await e.OAUTH_KV.list({ prefix: "grant:tnt@teamthurber.com:" });
    for (const k of grants.keys) await e.OAUTH_KV.delete(k.name);

    // Past the 90s lease: the revoke-sweep now sees status='delivering' AND
    // lease_until < now, and cancels it to blocked:sender_revoked -- the
    // same path the "cancels a queued owner message" test exercises for a
    // still-'queued' row, here through the 'delivering, lease expired' half
    // of that same WHERE clause. Direct DO call (not signedSync/HTTP): the
    // HTTP route always uses the real Date.now(), and this needs to land
    // past the lease without a real 90s wait.
    const future = Date.now() + 120_000;
    const pendingOwners = await runInDurableObject(fleet(), (o: HerdrState) => o.pendingOwnerSenders(future));
    await runInDurableObject(fleet(), (o: HerdrState) =>
      o.sync(future, crypto.randomUUID(), JSON.stringify(syncBody({ snapshot: ownerSnapshot() })),
        { revoked: [], hold: false }, { revoked: [], hold: false }, { revoked: pendingOwners, hold: false }));
    const cancelled = await runInDurableObject(fleet(), (o: HerdrState) => o.ownerMessageStatus(id, "tnt@teamthurber.com"));
    expect([cancelled?.status, cancelled?.detail]).toEqual(["blocked:sender_revoked", "sender_revoked"]);

    // The owner, unaware the message was just revoked server-side, still
    // writes a reply to the file they already had open locally. M3: this
    // must never resurrect the exchange back to 'replied'.
    const lateOutcome = await runInDurableObject(fleet(), (o: HerdrState) =>
      o.sync(future + 1_000, crypto.randomUUID(), JSON.stringify(syncBody({
        snapshot: ownerSnapshot(),
        owner_replies: [{ exchange_id: id, owner_label: "conductor", body: "late reply", responded_at: new Date().toISOString(),
          artifact_revision: "", session: "w1:p1" }],
      })), { revoked: [], hold: false }, { revoked: [], hold: false }, { revoked: [], hold: false }));
    // #225 review H1: the Mac must be told this was dropped, not accepted
    // -- "ignored:blocked:..." (the status column's real value), never a
    // bare 200 the Mac would read as proof of delivery.
    expect(lateOutcome.ok && lateOutcome.response.owner_reply_results)
      .toEqual([{ exchange_id: id, owner_label: "conductor", outcome: "ignored:blocked:sender_revoked" }]);

    const after = await runInDurableObject(fleet(), (o: HerdrState) => o.ownerMessageStatus(id, "tnt@teamthurber.com"));
    expect([after?.status, after?.detail]).toEqual(["blocked:sender_revoked", "sender_revoked"]);
    const reply = await runInDurableObject(fleet(), (o: HerdrState) => o.ownerReply(id, "tnt@teamthurber.com"));
    expect(reply).toBeNull();
  });
});
