// The owner inbox switched off: Bebop offers fm:read and fm:reports only. A
// client that asks for a note scope still gets a read-only grant, sees no
// write tool, and the Durable Object refuses a note even for a caller
// claiming the scope.
import { SELF, env, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, expect, it } from "vitest";
import type { HerdrState } from "../src/state";
import type { Env } from "../src/types";
import { accessJwt, BASE, callTool, DOT, oauthToken, queueRaw, queueRawOwner, signedSync, syncBody, toolNames } from "./helpers";

const e = env as unknown as Env;
beforeEach(() => reset());

it("advertises only fm:read and fm:reports, and says so on /healthz before anyone connects", async () => {
  const as: { scopes_supported?: string[] } = await (await SELF.fetch(`${BASE}/.well-known/oauth-authorization-server`)).json();
  expect(as.scopes_supported).toEqual(["fm:read", "fm:reports"]);
  const health = await (await SELF.fetch(`${BASE}/healthz`)).json();
  expect(health).toMatchObject({ service: "bebop", owner_inbox_enabled: false, scopes_offered: ["fm:read", "fm:reports"],
    clients: { dot: ["fm:read", "fm:reports"], duet: ["fm:read", "fm:reports"] }, build_sha: "unstamped" });
});

it("refuses every kind of note in the Durable Object while the owner inbox is off", async () => {
  const caller = { email: "tnt@teamthurber.com", client_id: DOT, client_name: "ChatGPT" };
  const fleet = e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));
  const all = ["fm:read", "fm:request", "fm:decide-note"];
  expect(await runInDurableObject(fleet, (o: HerdrState) => o.sendOwnerMessage(Date.now(), caller, all, "firstmate", "hi", "cm1")))
    .toEqual({ ok: false, reason: "owner_inbox_disabled" });
  expect(await runInDurableObject(fleet, (o: HerdrState) => o.sendOwnerMessage(Date.now(), caller, all, "firstmate", "go", "cm2",
    { kind: "task_request", project: "kb", task_kind: "scout" }))).toEqual({ ok: false, reason: "owner_inbox_disabled" });
  expect(await runInDurableObject(fleet, (o: HerdrState) => o.sendOwnerMessage(Date.now(), caller, all, "firstmate", "a", "cm3",
    { kind: "decision_note", task_id: "task_A" }))).toEqual({ ok: false, reason: "owner_inbox_disabled" });
});

it("never hands out an owner message queued before owner-inbox was switched off", async () => {
  await signedSync(syncBody());
  const fleet = e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));
  const id = await runInDurableObject(fleet, (_o: HerdrState, state) => queueRawOwner(state.storage));
  const reply = (await (await signedSync(syncBody())).json()) as { owner_outbox: unknown[]; audit: { decision: string; reason: string }[] };
  expect(reply.owner_outbox).toHaveLength(0);
  expect(reply.audit.find((a) => a.decision === "cancelled_before_delivery")?.reason).toBe("owner_inbox_disabled");
  const m = await runInDurableObject(fleet, (o: HerdrState) => o.ownerMessageStatus(id, "tnt@teamthurber.com"));
  expect([m?.status, m?.detail]).toEqual(["blocked:owner_inbox_disabled", "owner_inbox_disabled"]);
});

it("offers no note checkbox and grants read only, even when the client asks for fm:request", async () => {
  const q = new URLSearchParams({ response_type: "code", client_id: DOT, redirect_uri: "https://chatgpt.com/connector_platform_oauth_redirect",
    code_challenge: "x".repeat(43), code_challenge_method: "S256", scope: "fm:read fm:request", resource: `${BASE}/mcp` });
  const page = await SELF.fetch(`${BASE}/authorize?${q}`, { headers: { "cf-access-jwt-assertion": await accessJwt("tnt@teamthurber.com") } });
  const html = await page.text();
  expect(html).toContain('value="fm:read"');
  expect(html).not.toContain('value="fm:request"');
  const { access_token, scope } = await oauthToken(["fm:read", "fm:request"]);
  expect(scope).toBe("fm:read");

  const names = await toolNames(access_token);
  expect(names).not.toContain("send_owner_message");
  expect(names).not.toContain("request_task");
  expect(names).toContain("get_status");

  await signedSync(syncBody());
  const status = await callTool<{ your_scopes: string[]; your_client: string; server: { owner_inbox_enabled: boolean } }>(access_token, "get_status");
  expect([status.data.connection?.state, status.data.your_scopes, status.data.your_client, status.data.server.owner_inbox_enabled])
    .toEqual(["connected", ["fm:read"], "dot", false]);
});

it("refuses and audits a message in the Durable Object regardless of the scopes passed in", async () => {
  await signedSync(syncBody());
  const out = await runInDurableObject(e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet")), (o: HerdrState) =>
    o.sendMessage(Date.now(), { email: "tnt@teamthurber.com", client_id: "c", client_name: "Zero" },
      ["herdr:read", "herdr:message"], "task_A", "hi"));
  expect(out).toEqual({ ok: false, reason: "messaging_disabled" });
});

it("never hands out a message queued before messaging was switched off", async () => {
  await signedSync(syncBody());
  const fleet = e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));
  const id = await runInDurableObject(fleet, (_o: HerdrState, state) => queueRaw(state.storage));
  const reply = (await (await signedSync(syncBody())).json()) as { outbox: unknown[]; audit: { decision: string; reason: string }[] };
  expect(reply.outbox).toHaveLength(0);
  expect(reply.audit.find((a) => a.decision === "cancelled_before_delivery")?.reason).toBe("messaging_disabled");
  const m = await runInDurableObject(fleet, (o: HerdrState) => o.messageStatus(id, "tnt@teamthurber.com"));
  expect([m?.status, m?.detail]).toEqual(["refused", "cancelled before delivery: messaging_disabled"]);
});

it("consumer tools are absent and Durable Object calls refuse when the feature is off", async () => {
  const { access_token } = await oauthToken(["fm:read"]);
  const names = await toolNames(access_token);
  expect(names).not.toContain("get_consumer_position");
  expect(names).not.toContain("commit_consumer_position");
  expect(names).not.toContain("rebase_consumer_position");
  expect((await callTool(access_token, "get_consumer_position", { consumer_id: "zero" })).isError).toBe(true);
  const fleet = e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));
  const caller = { email: "tnt@teamthurber.com", client_id: "c", client_name: "Zero" };
  expect((await fleet.getConsumerPosition(Date.now(), caller, ["fm:read"], "zero")).result)
    .toBe("event_consumers_disabled");
  expect((await fleet.commitConsumerPosition(Date.now(), caller, ["fm:read"], "zero", 0, 0, 1)).result)
    .toBe("event_consumers_disabled");
  expect((await fleet.rebaseConsumerPosition(Date.now(), caller, ["fm:read"], "zero", 0, 0, 1, "0".repeat(64), true)).result)
    .toBe("event_consumers_disabled");
  const rows = await runInDurableObject(fleet, (_o: HerdrState, state) =>
    state.storage.sql.exec(`SELECT * FROM event_consumers`).toArray());
  expect(rows).toEqual([]);
});
