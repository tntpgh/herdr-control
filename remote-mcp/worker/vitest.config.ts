import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { exportJWK, generateKeyPair } from "jose";
import { defineConfig } from "vitest/config";

// A throwaway RSA key stands in for Cloudflare Access: its public half is
// served as the team JWKS through miniflare's outbound hook, its private half
// goes to the tests (as a binding) so they can mint Access assertions.
const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });
const pub = { ...(await exportJWK(publicKey)), kid: "test-kid", alg: "RS256", use: "sig" };
const priv = { ...(await exportJWK(privateKey)), kid: "test-kid", alg: "RS256" };

// Client ID Metadata Documents the OAuth provider fetches for a CIMD
// client_id: the two allow-listed apps, and one stranger that is not on the
// list. Each names the helper's REDIRECT so the full flow can run.
const REDIRECT = "https://chatgpt.com/connector_platform_oauth_redirect";
const CIMD: Record<string, string> = {
  "https://chatgpt.com/oauth/client.json": "ChatGPT",
  "https://claude.ai/oauth/mcp-oauth-client-metadata": "Claude",
  "https://stranger.example/oauth/client.json": "Stranger",
};

// Bindings are fixed per isolate, so each feature mode is a project. `extra`
// adds bindings on top of wrangler.jsonc for one project.
const worker = (ownerInbox: "true" | "false", consumers: "true" | "false" = "false", messaging: "true" | "false" = "false",
  extra: Record<string, string> = {}) =>
  cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: {
      bindings: {
        ACCESS_AUD: "test-aud",
        INGEST_KEY: "k".repeat(48),
        MESSAGING_ENABLED: messaging,
        TASKS_ENABLED: "false",
        OWNER_INBOX_ENABLED: ownerInbox,
        EVENT_CONSUMERS_ENABLED: consumers,
        TEST_ACCESS_PRIVATE_JWK: JSON.stringify(priv),
        ...extra,
      },
      outboundService: (request: Request) => {
        const url = new URL(request.url);
        if (url.hostname === "thurberteam.cloudflareaccess.com" && url.pathname === "/cdn-cgi/access/certs") {
          return Response.json({ keys: [pub] });
        }
        const name = CIMD[request.url];
        if (name) {
          return Response.json({ client_id: request.url, client_name: name, redirect_uris: [REDIRECT],
            token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] });
        }
        return new Response("blocked in tests", { status: 599 });
      },
    },
  });

export default defineConfig({
  test: {
    projects: [
      // messaging=true only to prove the dormant send_message path stays shut
      // to every MCP client even with the old switch on.
      { plugins: [worker("false", "false", "true")], test: { name: "flow", include: ["test/flow.test.ts"] } },
      { plugins: [worker("false")], test: { name: "read-only", include: ["test/readonly.test.ts"] } },
      { plugins: [worker("true")], test: { name: "owner-inbox", include: ["test/owner-inbox.test.ts"] } },
      { plugins: [worker("true")], test: { name: "events", include: ["test/events.test.ts"] } },
      { plugins: [worker("true", "true")], test: { name: "consumers", include: ["test/consumers.test.ts"] } },
      { plugins: [worker("true")], test: { name: "client-identity", include: ["test/client-identity.test.ts"] } },
      // The shipped config serves no alias; this project adds one so the
      // multi-origin path (a future hostname cutover) stays covered.
      { plugins: [worker("true", "false", "false", { ALIAS_URLS: "https://old.teamthurber.com" })],
        test: { name: "firstmate", include: ["test/firstmate.test.ts"] } },
    ],
  },
});
