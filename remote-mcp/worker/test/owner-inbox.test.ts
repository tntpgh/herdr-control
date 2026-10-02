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

interface SyncReply { owner_outbox: { exchange_id: string; owner_label: string; body: string }[]; audit: { tool: string; decision: string; reason: string; message_id: string }[] }
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

  it("rate-limits a burst at 2/minute, independent of the generic per-client throttle", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot() }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const outcomes: string[] = [];
    for (let i = 0; i < 3; i++) {
      outcomes.push((await callTool(access_token, "send_owner_message",
        { owner_label: "conductor", body: `n${i}`, client_msg_id: `cm${i}` })).data.error ?? "ok");
    }
    expect(outcomes).toEqual(["ok", "ok", "rate_limited"]);
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

    await signedSync(syncBody({ snapshot: ownerSnapshot(), owner_replies: [
      { exchange_id: id, owner_label: "conductor", body: "ok, done", responded_at: new Date().toISOString(),
        artifact_revision: "sha256:abc", session: "w5B:pG" },
    ] }));

    const mine = await callTool<{ reply: OwnerReplyRecord }>(access_token, "get_owner_reply", { exchange_id: id });
    expect(mine.data.reply).toMatchObject({ exchange_id: id, owner_label: "conductor", body: "ok, done", session: "w5B:pG" });
    const status = await callTool<{ owner_message: OwnerMessageRecord }>(access_token, "get_owner_message_status", { exchange_id: id });
    expect(status.data.owner_message.status).toBe("replied");

    // ALLOWED_EMAILS is a single address in this deployment, so "someone
    // else" cannot be reached through the real OAuth flow; call the
    // validated DO method directly, the same way readonly.test.ts probes
    // edge cases a live token can never reach.
    const theirs = await runInDurableObject(fleet(), (o: HerdrState) => o.ownerReply(id, "intruder@teamthurber.com"));
    expect(theirs).toBeNull();
  });

  it("ignores a reply whose own owner_label does not match the exchange's real target (header mismatch)", async () => {
    await signedSync(syncBody({ snapshot: ownerSnapshot([{ label: "conductor", live: true }, { label: "other-tab", live: true }]) }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:message.owner"]);
    const id = await deliveredExchange(access_token);

    await signedSync(syncBody({
      snapshot: ownerSnapshot([{ label: "conductor", live: true }, { label: "other-tab", live: true }]),
      owner_replies: [{ exchange_id: id, owner_label: "other-tab", body: "spoofed", responded_at: new Date().toISOString(),
        artifact_revision: "", session: "w1:pX" }],
    }));

    const status = await callTool<{ owner_message: OwnerMessageRecord }>(access_token, "get_owner_message_status", { exchange_id: id });
    expect(status.data.owner_message.status).toBe("delivered");
    const reply = await callTool<{ error?: string }>(access_token, "get_owner_reply", { exchange_id: id });
    expect(reply.data.error).toBe("not_found");
  });
});
