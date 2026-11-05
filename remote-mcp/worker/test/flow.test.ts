import { SELF, env, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { sign } from "../src/ingest";
import type { HerdrState } from "../src/state";
import type { BlockerRow, Env } from "../src/types";
import { accessJwt, BASE, callTool, DOT, oauthToken, queueRaw, signedPost, signedSync, syncBody, snapshot, toolNames } from "./helpers";
import { mcpHandler } from "../src/mcp";

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
    expect(as.scopes_supported).toEqual(["fm:read", "fm:reports"]);
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

  it("issues a token only for the scopes ticked on the consent page that this server offers", async () => {
    expect((await oauthToken(["fm:read"])).scope).toBe("fm:read");
    // fm:request is not offered while the owner inbox is off.
    expect((await oauthToken(["fm:read", "fm:request"])).scope).toBe("fm:read");
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

  it("refuses a body with no Content-Length before reading it", async () => {
    const stream = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode("{}")); c.close(); } });
    const res = await SELF.fetch(`${BASE}/ingest/sync`, {
      method: "POST", body: stream, duplex: "half",
      headers: { "x-herdr-ts": String(Math.floor(Date.now() / 1000)), "x-herdr-nonce": "ab".repeat(16), "x-herdr-sig": "0".repeat(64) },
    } as RequestInit);
    expect(res.status).toBe(411);
  });
});

describe("read tools", () => {
  it("reports never_connected, then connected after a sync, then disconnected once the Mac goes quiet", async () => {
    const { access_token } = await oauthToken(["fm:read"]);
    expect((await callTool(access_token, "get_status")).data.connection?.state).toBe("never_connected");
    expect((await signedSync(syncBody())).status).toBe(200);
    expect((await callTool(access_token, "get_status")).data.connection?.state).toBe("connected");
    const later = await runInDurableObject(fleet(), (o: HerdrState) => o.view(Date.now() + 91_000));
    expect(later.connection.state).toBe("disconnected");
    expect(later.connection.last_sync_at).not.toBeNull();
  });

  it("lists tasks by filter with stable ids and Firstmate's typed fields", async () => {
    const pr = "https://github.com/tntpgh/knowledge-base/pull/7";
    const snap = snapshot();
    snap.tasks[0] = { ...snap.tasks[0]!, pr_url: pr, kind: "ship", mode: "implement", yolo: false };
    snap.tasks[1] = { ...snap.tasks[1]!, closure_proof: pr };
    await signedSync(syncBody({ snapshot: snap }));
    const { access_token } = await oauthToken(["fm:read"]);
    type Task = { task_id: string; pr_url: string | null; kind: string | null; yolo: boolean | null };
    const active = (await callTool<{ tasks: Task[] }>(access_token, "list_tasks", { filter: "active" })).data.tasks;
    expect(active.find((t) => t.task_id === "task_A")).toMatchObject({ pr_url: pr, kind: "ship", yolo: false });
    expect(active.find((t) => t.task_id === "task_S")).toMatchObject({ pr_url: null, kind: null, yolo: null });
    expect(active.find((t) => t.task_id === "task_B")).toBeUndefined();
    // An older publisher carried the PR only in closure_proof.
    const done = (await callTool<{ tasks: Task[] }>(access_token, "list_tasks", { filter: "done" })).data.tasks;
    expect(done.map((t) => [t.task_id, t.pr_url])).toEqual([["task_B", pr]]);
    const attention = (await callTool<{ tasks: Task[] }>(access_token, "list_tasks", { filter: "attention" })).data.tasks;
    expect(attention.map((t) => t.task_id)).toEqual(["task_D2"]);
    const one = (await callTool<{ blockers: BlockerRow[] }>(access_token, "get_task", { task_id: "task_D2" })).data;
    expect(one.blockers).toHaveLength(1);
  });

  it("pages a task result within the bound", async () => {
    await signedSync(syncBody({ results: [{ task_id: "task_B", source: "firstmate:card", text: "x".repeat(10_000),
      sha256: "h", source_mtime: null, truncated_at_source: false }] }));
    const { access_token } = await oauthToken(["fm:read", "fm:reports"]);
    type R = { result: { returned_chars: number; next_offset: number | null; total_chars: number } };
    const r1 = (await callTool<R>(access_token, "get_task_result", { task_id: "task_B", max_chars: 4000 })).data.result;
    expect([r1.returned_chars, r1.next_offset, r1.total_chars]).toEqual([4000, 4000, 10_000]);
    const r3 = (await callTool<R>(access_token, "get_task_result", { task_id: "task_B", offset: 8000, max_chars: 4000 })).data.result;
    expect([r3.returned_chars, r3.next_offset]).toEqual([2000, null]);
    expect((await callTool(access_token, "get_task_result", { task_id: "task_B", max_chars: 50_000 })).isError).toBe(true);
  });
});

describe("herdr-mcp's bypass tools are gone", () => {
  it("never offers send_message or the remote-task tools, refuses and audits a call, and leases nothing queued earlier", async () => {
    await signedSync(syncBody());
    const { access_token } = await oauthToken(["fm:read", "fm:reports"]);
    const names = await toolNames(access_token);
    for (const gone of ["send_message", "follow_up", "start_task", "cancel_task", "resume_task", "list_capabilities",
      "get_task_answer", "get_message_status"]) expect(names).not.toContain(gone);
    expect((await callTool(access_token, "send_message", { target: "task_A", text: "hi" })).isError).toBe(true);

    // Messaging's own switch is on in this project: a message queued under
    // the old policy still never reaches the Mac, because no token can hold
    // herdr:message any more.
    await runInDurableObject(fleet(), (_o: HerdrState, state) => queueRaw(state.storage));
    const reply = await syncJson(await signedSync(syncBody()));
    expect(reply.outbox).toHaveLength(0);
    expect(reply.audit.filter((a) => a.tool === "send_message").map((a) => a.decision)).toEqual(["refused"]);
  });
});

describe("grant administration from the Mac (/admin/grants)", () => {
  interface Listed { grants: { grant_id: string; client_id: string; scope: string[] }[] }
  const USER = "tnt@teamthurber.com";

  it("revokes one connection, leaving the other working", async () => {
    await signedSync(syncBody());
    const dot = await oauthToken(["fm:read"]);
    const first: Listed = await (await signedPost("/admin/grants", { op: "list", user: USER })).json();
    expect(first.grants).toHaveLength(1);
    const dotGrant = first.grants[0]!.grant_id;
    const duet = await oauthToken(["fm:read"], USER, "duet");

    const res = await signedPost("/admin/grants", { op: "revoke", user: USER, grant_id: dotGrant });
    expect(res.status).toBe(200);

    const after: Listed = await (await signedPost("/admin/grants", { op: "list", user: USER })).json();
    expect(after.grants.map((g) => g.client_id)).toEqual([duet.client_id]);
    expect((await callTool(duet.access_token, "get_status")).isError).toBe(false);
    const dead = await SELF.fetch(`${BASE}/mcp`, { method: "POST", headers: { authorization: `Bearer ${dot.access_token}`,
      "content-type": "application/json", accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) });
    expect(dead.status).toBe(401);

    const reply = await syncJson(await signedSync(syncBody()));
    expect(reply.audit.filter((a) => a.tool.startsWith("admin_")).map((a) => [a.tool, a.decision]))
      .toEqual([["admin_list", "allowed"], ["admin_revoke", "allowed"], ["admin_list", "allowed"]]);
  });

  it("refuses unsigned, wrongly signed, replayed and malformed admin requests", async () => {
    const unsigned = await SELF.fetch(`${BASE}/admin/grants`, { method: "POST", body: JSON.stringify({ op: "list", user: USER }) });
    expect(unsigned.status).toBe(401);
    expect((await signedPost("/admin/grants", { op: "list", user: USER }, { key: "w".repeat(48) })).status).toBe(401);
    const nonce = "ab".repeat(16);
    expect((await signedPost("/admin/grants", { op: "list", user: USER }, { nonce })).status).toBe(200);
    expect((await signedPost("/admin/grants", { op: "list", user: USER }, { nonce })).status).toBe(409);
    expect((await signedPost("/admin/grants", { op: "delete_all", user: USER })).status).toBe(400);
    expect((await signedPost("/admin/grants", { op: "revoke", user: USER, grant_id: "../x" })).status).toBe(400);
    expect((await signedPost("/admin/grants", { op: "revoke", user: USER, grant_id: "nope" })).status).toBe(404);
  });
});

describe("dormant message limits from the Mac (/admin/limits)", () => {
  type Limits = { per_minute: number; per_hour: number; source: string; until: string | null };
  it("refuses values above the ceiling or malformed, never clamping, and audits accepted changes", async () => {
    const bad = [
      { op: "set", per_minute: 31, per_hour: 100, minutes: 60, reason: "x" },
      { op: "set", per_minute: 10, per_hour: 301, minutes: 60, reason: "x" },
      { op: "set", per_minute: 10, per_hour: 5, minutes: 60, reason: "x" },
      { op: "set", per_minute: 10, per_hour: 100, minutes: 60, reason: " " },
      { op: "set", per_minute: 10, per_hour: 100, minutes: 0, reason: "x" },
      { op: "set", per_minute: 1.5, per_hour: 100, minutes: null, reason: "x" },
      { op: "raise_ceiling" },
    ];
    for (const b of bad) expect((await signedPost("/admin/limits", b)).status).toBe(400);
    const unsigned = await SELF.fetch(`${BASE}/admin/limits`, { method: "POST", body: JSON.stringify({ op: "reset" }) });
    expect(unsigned.status).toBe(401);
    const got: { limits: Limits } = await (await signedPost("/admin/limits", { op: "get" })).json();
    expect(got.limits.source).toBe("default");

    await signedPost("/admin/limits", { op: "set", per_minute: 10, per_hour: 100, minutes: null, reason: "steady" });
    const { audit } = await syncJson(await signedSync(syncBody()));
    expect(audit.filter((a) => a.tool.startsWith("admin_limits")).map((a) => a.tool))
      .toEqual(["admin_limits_get", "admin_limits_set"]);
  });
});

describe("abuse bounds", () => {
  it("throttles a client past 60 calls a minute and audits the throttle once", async () => {
    // A tool outside the catalog, so only the global throttle applies.
    const zero = { email: "tnt@teamthurber.com", client_id: "c-loop", client_name: "Zero" };
    const verdicts = await runInDurableObject(fleet(), (o: HerdrState) =>
      Array.from({ length: 70 }, () => o.admitToolCall(Date.now(), zero, "probe", "", null)));
    expect([verdicts.slice(0, 60).every((v) => v === null), verdicts[60], verdicts[69]])
      .toEqual([true, "rate_limited (60/minute)", "rate_limited (60/minute)"]);
    const other = await runInDurableObject(fleet(), (o: HerdrState) =>
      o.admitToolCall(Date.now(), { ...zero, client_id: "c-other" }, "probe", "", null));
    expect(other).toBeNull();
    const { audit } = await syncJson(await signedSync(syncBody()));
    expect(audit.filter((a) => a.decision === "throttled")).toHaveLength(1);
    expect(audit).toHaveLength(62);
  });

  it("refuses /mcp for a grant whose email has left the allowlist, and audits the refusal", async () => {
    const ctx = { props: { email: "former@teamthurber.com", client_name: "Zero" }, auth: { scope: ["fm:read"], clientId: DOT },
      waitUntil() {}, passThroughOnException() {} };
    const res = await mcpHandler.fetch(new Request(`${BASE}/mcp`, { method: "POST", body: "{}" }), e, ctx as unknown as ExecutionContext);
    expect(res.status).toBe(403);
    const audit = (await (await signedSync(syncBody())).json() as { audit: { tool: string; decision: string; reason: string }[] }).audit;
    expect(audit.map((a) => [a.tool, a.decision, a.reason])).toEqual([["mcp", "refused", "access_revoked"]]);
  });
});
