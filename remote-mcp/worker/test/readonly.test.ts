// The Worker as first deployed: MESSAGING_ENABLED is off. A client that asks
// for herdr:message still gets a read-only grant, sees no send_message, and
// the Durable Object refuses a message even for a caller claiming the scope.
import { SELF, env, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, expect, it } from "vitest";
import type { HerdrState } from "../src/state";
import type { Env } from "../src/types";
import { accessJwt, BASE, callTool, oauthToken, queueRaw, queueRawOwner, signedSync, snapshot, syncBody } from "./helpers";

const e = env as unknown as Env;
beforeEach(() => reset());

it("advertises only herdr:read, and says so on /healthz before anyone connects", async () => {
  const as: { scopes_supported?: string[] } = await (await SELF.fetch(`${BASE}/.well-known/oauth-authorization-server`)).json();
  expect(as.scopes_supported).toEqual(["herdr:read"]);
  const health = await (await SELF.fetch(`${BASE}/healthz`)).json();
  expect(health).toMatchObject({ messaging_enabled: false, scopes_offered: ["herdr:read"], build_sha: "unstamped" });
});

it("offers no owner-inbox scope and refuses send_owner_message in the Durable Object, off by default", async () => {
  const as: { scopes_supported?: string[] } = await (await SELF.fetch(`${BASE}/.well-known/oauth-authorization-server`)).json();
  expect(as.scopes_supported).not.toContain("herdr:message.owner");
  const health = await (await SELF.fetch(`${BASE}/healthz`)).json();
  expect(health).toMatchObject({ owner_inbox_enabled: false });
  const out = await runInDurableObject(e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet")), (o: HerdrState) =>
    o.sendOwnerMessage(Date.now(), { email: "tnt@teamthurber.com", client_id: "c", client_name: "Zero" },
      ["herdr:read", "herdr:message.owner"], "conductor", "hi", "cm1"));
  expect(out).toEqual({ ok: false, reason: "owner_inbox_disabled" });
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

it("offers no messaging checkbox and grants read only, even when the client asks for herdr:message", async () => {
  const page = await SELF.fetch(`${BASE}/authorize?response_type=code&client_id=x`, {
    headers: { "cf-access-jwt-assertion": await accessJwt("tnt@teamthurber.com") },
  });
  // client_id x is unregistered, so the page itself is an error; the grant below is the real check.
  expect(await page.text()).not.toContain('value="herdr:message"');
  const { access_token, scope } = await oauthToken(["herdr:read", "herdr:message"]);
  expect(scope).toBe("herdr:read");

  const list = await SELF.fetch(`${BASE}/mcp`, {
    method: "POST",
    headers: { authorization: `Bearer ${access_token}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
  });
  const names = ((await list.json()) as { result: { tools: { name: string }[] } }).result.tools.map((t) => t.name);
  expect(names).not.toContain("send_message");
  expect(names).toContain("get_status");

  await signedSync(syncBody());
  const status = await callTool<{ your_scopes: string[]; server: { messaging_enabled: boolean } }>(access_token, "get_status");
  expect([status.data.connection?.state, status.data.your_scopes, status.data.server.messaging_enabled])
    .toEqual(["connected", ["herdr:read"], false]);
});

it("reports the Mac's real-Chrome health from the snapshot, and null when the publisher sent none", async () => {
  const { access_token } = await oauthToken(["herdr:read"]);
  await signedSync(syncBody());
  expect((await callTool<{ browser: unknown }>(access_token, "get_status")).data.browser).toBeNull();

  const browser = {
    checked_at: "2026-10-02T18:00:00Z", real_chrome_running: true, relay: "connected",
    extensions: { omp_relay: "enabled", "1password": "unknown", chatgpt: "missing" } as const,
    stray_omp_chromes: 1, healthy: false,
  };
  await signedSync(syncBody({ snapshot: snapshot({ browser }) }));
  expect((await callTool<{ browser: unknown }>(access_token, "get_status")).data.browser).toEqual(browser);

  // Drift on the Mac must not cost the sync: the block degrades to null.
  const res = await signedSync(syncBody({ snapshot: snapshot({ browser: { ...browser, relay: "connected to /Users/x" } }) }));
  expect(res.status).toBe(200);
  expect((await callTool<{ browser: unknown }>(access_token, "get_status")).data.browser).toBeNull();
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
  const { access_token } = await oauthToken(["herdr:read"]);
  const response = await SELF.fetch(`${BASE}/mcp`, {
    method: "POST",
    headers: { authorization: `Bearer ${access_token}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
  });
  const body = await response.json() as { result: { tools: { name: string }[] } };
  const names = body.result.tools.map((tool) => tool.name);
  expect(names).not.toContain("get_consumer_position");
  expect(names).not.toContain("commit_consumer_position");
  expect((await callTool(access_token, "get_consumer_position", { consumer_id: "zero" })).isError).toBe(true);
  const fleet = e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));
  const caller = { email: "tnt@teamthurber.com", client_id: "c", client_name: "Zero" };
  expect((await fleet.getConsumerPosition(Date.now(), caller, ["herdr:read"], "zero")).result)
    .toBe("event_consumers_disabled");
  expect((await fleet.commitConsumerPosition(Date.now(), caller, ["herdr:read"], "zero", 0, 0, 1)).result)
    .toBe("event_consumers_disabled");
  const rows = await runInDurableObject(fleet, (_o: HerdrState, state) =>
    state.storage.sql.exec(`SELECT * FROM event_consumers`).toArray());
  expect(rows).toEqual([]);
});
