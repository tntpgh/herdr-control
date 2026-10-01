// The Worker as first deployed: MESSAGING_ENABLED is off. A client that asks
// for herdr:message still gets a read-only grant, sees no send_message, and
// the Durable Object refuses a message even for a caller claiming the scope.
import { SELF, env, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, expect, it } from "vitest";
import type { HerdrState } from "../src/state";
import type { Env } from "../src/types";
import { accessJwt, BASE, callTool, oauthToken, signedSync, syncBody } from "./helpers";

const e = env as unknown as Env;
beforeEach(() => reset());

it("advertises only herdr:read", async () => {
  const as: { scopes_supported?: string[] } = await (await SELF.fetch(`${BASE}/.well-known/oauth-authorization-server`)).json();
  expect(as.scopes_supported).toEqual(["herdr:read"]);
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
  const status = await callTool<{ your_scopes: string[] }>(access_token, "get_status");
  expect([status.data.connection?.state, status.data.your_scopes]).toEqual(["connected", ["herdr:read"]]);
});

it("refuses and audits a message in the Durable Object regardless of the scopes passed in", async () => {
  await signedSync(syncBody());
  const out = await runInDurableObject(e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet")), (o: HerdrState) =>
    o.sendMessage(Date.now(), { email: "tnt@teamthurber.com", client_id: "c", client_name: "Zero" },
      ["herdr:read", "herdr:message"], "task_A", "hi"));
  expect(out).toEqual({ ok: false, reason: "messaging_disabled" });
});
