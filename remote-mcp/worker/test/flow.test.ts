import { SELF, env, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { sign } from "../src/ingest";
import type { HerdrState, MessageRecord } from "../src/state";
import type { BlockerRow, Env } from "../src/types";
import { accessJwt, BASE, callTool, oauthToken, signedSync, snapshot, syncBody } from "./helpers";

const e = env as unknown as Env; // the pool's env carries this Worker's bindings
const fleet = () => e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));

interface SyncReply { outbox: { message_id: string; text: string; pane_id: string }[]; audit: { tool: string; decision: string }[] }
const syncJson = async (r: Response): Promise<SyncReply> => r.json();

// Every test starts from empty storage: no snapshot, no messages, no grants.
beforeEach(() => reset());

describe("discovery and the auth boundary", () => {
  it("advertises RFC 9728 resource metadata and an S256 + RFC 9207 authorization server", async () => {
    const prm: Record<string, unknown> = await (await SELF.fetch(`${BASE}/.well-known/oauth-protected-resource/mcp`)).json();
    expect(prm.resource).toBe(`${BASE}/mcp`);
    expect(prm.authorization_servers).toEqual([BASE]);
    const as: Record<string, unknown> = await (await SELF.fetch(`${BASE}/.well-known/oauth-authorization-server`)).json();
    expect(as.issuer).toBe(BASE);
    expect(as.code_challenge_methods_supported).toContain("S256");
    expect(as.authorization_response_iss_parameter_supported).toBe(true);
    expect(as.registration_endpoint).toBe(`${BASE}/oauth/register`);
    expect(as.scopes_supported).toEqual(["herdr:read", "herdr:message"]);
  });

  it("answers /mcp without a token with a 401 that points at the metadata", async () => {
    const res = await SELF.fetch(`${BASE}/mcp`, { method: "POST", body: "{}" });
    expect(res.status).toBe(401);
    expect(res.headers.get("www-authenticate")).toContain("resource_metadata=");
  });

  it("refuses /authorize without an Access assertion, with a wrong audience, or for a non-allowlisted email", async () => {
    const q = "response_type=code&client_id=x&redirect_uri=https%3A%2F%2Fchatgpt.com%2Fx&code_challenge=abc&code_challenge_method=S256";
    expect((await SELF.fetch(`${BASE}/authorize?${q}`)).status).toBe(403);
    const wrongAud = await accessJwt("tnt@teamthurber.com", "some-other-app");
    expect((await SELF.fetch(`${BASE}/authorize?${q}`, { headers: { "cf-access-jwt-assertion": wrongAud } })).status).toBe(403);
    const outsider = await accessJwt("someone@teamthurber.com");
    expect((await SELF.fetch(`${BASE}/authorize?${q}`, { headers: { "cf-access-jwt-assertion": outsider } })).status).toBe(403);
  });

  it("issues a token only for the scopes ticked on the consent page", async () => {
    expect((await oauthToken(["herdr:read"])).scope).toBe("herdr:read");
  });
});

describe("publisher ingest", () => {
  it("matches the known-answer HMAC vector that verify-publisher.py also asserts", async () => {
    expect(await sign("k".repeat(48), "1790000000", "00112233445566778899aabbccddeeff", '{"a":1}'))
      .toBe("f4935fd023e944e2419e58698ab59de978615dd4d41b4d68a4177bbb17482a89");
  });

  it("rejects a bad signature, a stale timestamp and a replayed nonce", async () => {
    expect((await signedSync(syncBody(), { key: "x".repeat(48) })).status).toBe(401);
    expect((await signedSync(syncBody(), { ts: Math.floor(Date.now() / 1000) - 1000 })).status).toBe(401);
    const nonce = "abcdefabcdefabcdefabcdefabcdef00";
    expect((await signedSync(syncBody(), { nonce })).status).toBe(200);
    expect((await signedSync(syncBody(), { nonce })).status).toBe(409);
  });

  it("refuses a snapshot whose schema it does not understand", async () => {
    expect((await signedSync(syncBody({ snapshot: { ...snapshot(), schema: 2 } }))).status).toBe(400);
  });
});

describe("read tools", () => {
  it("reports never_connected, then connected after a sync, then disconnected once the Mac goes quiet", async () => {
    const { access_token } = await oauthToken(["herdr:read"]);
    expect((await callTool(access_token, "get_status")).data.connection?.state).toBe("never_connected");
    expect((await signedSync(syncBody())).status).toBe(200);
    expect((await callTool(access_token, "get_status")).data.connection?.state).toBe("connected");
    const later = await runInDurableObject(fleet(), (o: HerdrState) => o.view(Date.now() + 91_000));
    expect(later.connection.state).toBe("disconnected");
    expect(later.connection.last_sync_at).not.toBeNull();
  });

  it("lists tasks by filter with stable ids and the messageable flag", async () => {
    await signedSync(syncBody());
    const { access_token } = await oauthToken(["herdr:read"]);
    type Tasks = { tasks: { task_id: string; messageable: boolean }[] };
    const active = (await callTool<Tasks>(access_token, "list_tasks", { filter: "active" })).data.tasks;
    expect(active.map((t) => [t.task_id, t.messageable])).toEqual(expect.arrayContaining([["task_A", true], ["task_S", false]]));
    expect(active.find((t) => t.task_id === "task_B")).toBeUndefined();
    const attention = (await callTool<Tasks>(access_token, "list_tasks", { filter: "attention" })).data.tasks;
    expect(attention.map((t) => t.task_id)).toEqual(["task_D2"]);
    const one = (await callTool<{ blockers: BlockerRow[] }>(access_token, "get_task", { task_id: "task_D2" })).data;
    expect(one.blockers).toHaveLength(1);
  });

  it("pages a task result within the bound", async () => {
    await signedSync(syncBody({ results: [{ task_id: "task_B", source: ".handoffs/PROOF.md", text: "x".repeat(10_000),
      sha256: "h", source_mtime: null, truncated_at_source: false }] }));
    const { access_token } = await oauthToken(["herdr:read"]);
    type R = { result: { returned_chars: number; next_offset: number | null; total_chars: number } };
    const r1 = (await callTool<R>(access_token, "get_task_result", { task_id: "task_B", max_chars: 4000 })).data.result;
    expect([r1.returned_chars, r1.next_offset, r1.total_chars]).toEqual([4000, 4000, 10_000]);
    const r3 = (await callTool<R>(access_token, "get_task_result", { task_id: "task_B", offset: 8000, max_chars: 4000 })).data.result;
    expect([r3.returned_chars, r3.next_offset]).toEqual([2000, null]);
    expect((await callTool(access_token, "get_task_result", { task_id: "task_B", max_chars: 50_000 })).isError).toBe(true);
  });
});

describe("send_message", () => {
  it("refuses without the herdr:message scope and audits the refusal", async () => {
    await signedSync(syncBody());
    const { access_token } = await oauthToken(["herdr:read"]);
    const r = await callTool(access_token, "send_message", { target: "task_A", text: "hi" });
    expect([r.isError, r.data.error]).toEqual([true, "missing_scope"]);
    const { audit } = await syncJson(await signedSync(syncBody()));
    expect(audit.some((a) => a.tool === "send_message" && a.decision === "refused")).toBe(true);
  });

  it("enforces target scope: unknown, ambiguous, terminal, dead pane, agent without a task", async () => {
    await signedSync(syncBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:message"]);
    const reason = async (target: string) => (await callTool(access_token, "send_message", { target, text: "hello" })).data.error;
    expect(await reason("nope")).toBe("unknown_target");
    expect(await reason("review:dup")).toBe("ambiguous_target");
    expect(await reason("task_B")).toBe("task_not_messageable");
    expect(await reason("task_S")).toBe("task_not_messageable");
    expect(await reason("term_c")).toBe("agent_has_no_task");
  });

  it("refuses while the Mac is disconnected", async () => {
    await signedSync(syncBody());
    const out = await runInDurableObject(fleet(), (o: HerdrState) =>
      o.sendMessage(Date.now() + 120_000, { email: "tnt@teamthurber.com", client_id: "c", client_name: "Zero" },
        ["herdr:read", "herdr:message"], "task_A", "hi"));
    expect(out).toMatchObject({ ok: false, reason: "not_connected (disconnected)" });
  });

  it("queues a sanitized one-line message, leases it to the publisher once, and records delivery", async () => {
    await signedSync(syncBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:message"]);
    const sent = await callTool<{ message: MessageRecord }>(access_token, "send_message",
      { target: "implement:feat/a", text: "line one\n\x1b[2Jline two\r" });
    expect([sent.data.message.status, sent.data.message.target.task_id]).toEqual(["queued", "task_A"]);

    const first = await syncJson(await signedSync(syncBody()));
    expect(first.outbox.map((m) => [m.text, m.pane_id])).toEqual([["line one [2Jline two", "w1:term_a"]]);
    expect((await syncJson(await signedSync(syncBody()))).outbox).toHaveLength(0);

    const id = sent.data.message.message_id;
    await signedSync(syncBody({ acks: [{ message_id: id, outcome: "delivered", detail: "exit 0" }] }));
    const status = await callTool<{ message: MessageRecord }>(access_token, "get_message_status", { message_id: id });
    expect(status.data.message.status).toBe("delivered");
  });

  it("re-offers a message acked as retry on the next leasing sync, not to the ack-only sync", async () => {
    await signedSync(syncBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:message"]);
    const sent = await callTool<{ message: MessageRecord }>(access_token, "send_message", { target: "task_A", text: "hi" });
    const id = sent.data.message.message_id;
    expect((await syncJson(await signedSync(syncBody()))).outbox).toHaveLength(1);

    const ackOnly = await syncJson(await signedSync(syncBody({ lease: false,
      acks: [{ message_id: id, outcome: "retry", detail: "permission prompt showing" }] })));
    expect(ackOnly.outbox).toHaveLength(0);
    const status = await callTool<{ message: MessageRecord }>(access_token, "get_message_status", { message_id: id });
    expect(status.data.message.status).toBe("queued");
    expect((await syncJson(await signedSync(syncBody()))).outbox.map((m) => m.message_id)).toEqual([id]);
  });

  it("rate-limits a burst", async () => {
    await signedSync(syncBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:message"]);
    const outcomes: string[] = [];
    for (let i = 0; i < 6; i++) {
      outcomes.push((await callTool(access_token, "send_message", { target: "task_A", text: `n${i}` })).data.error ?? "ok");
    }
    expect(outcomes).toEqual(["ok", "ok", "ok", "ok", "ok", "rate_limited"]);
  });
});
