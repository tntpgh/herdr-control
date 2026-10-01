import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { exportJWK, generateKeyPair } from "jose";
import { defineConfig } from "vitest/config";

// A throwaway RSA key stands in for Cloudflare Access: its public half is
// served as the team JWKS through miniflare's outbound hook, its private half
// goes to the tests (as a binding) so they can mint Access assertions.
const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });
const pub = { ...(await exportJWK(publicKey)), kid: "test-kid", alg: "RS256", use: "sig" };
const priv = { ...(await exportJWK(privateKey)), kid: "test-kid", alg: "RS256" };

// The same Worker twice: as deployed first (messaging off, read-only) and with
// messaging switched on. vars are fixed per isolate, so each mode is a project.
const worker = (messaging: "true" | "false") =>
  cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: {
      bindings: {
        ACCESS_AUD: "test-aud",
        INGEST_KEY: "k".repeat(48),
        MESSAGING_ENABLED: messaging,
        TEST_ACCESS_PRIVATE_JWK: JSON.stringify(priv),
      },
      outboundService: (request: Request) => {
        const url = new URL(request.url);
        if (url.hostname === "thurberteam.cloudflareaccess.com" && url.pathname === "/cdn-cgi/access/certs") {
          return Response.json({ keys: [pub] });
        }
        return new Response("blocked in tests", { status: 599 });
      },
    },
  });

export default defineConfig({
  test: {
    projects: [
      { plugins: [worker("false")], test: { name: "read-only", include: ["test/readonly.test.ts"] } },
      { plugins: [worker("true")], test: { name: "messaging", include: ["test/flow.test.ts"] } },
    ],
  },
});
