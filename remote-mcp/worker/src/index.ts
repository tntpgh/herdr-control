// herdr-mcp: an OAuth 2.1 authorization server + MCP resource in one Worker.
//
//   /mcp                     MCP (Streamable HTTP), bearer token required
//   /authorize               consent; Cloudflare Access (Google SSO) in front,
//                            Access JWT re-verified here, email allowlisted
//   /oauth/token, /register  handled by @cloudflare/workers-oauth-provider
//   /.well-known/*           RFC 9728 / RFC 8414 discovery (provider)
//   /ingest/sync             the Mac publisher's HMAC-signed push
import OAuthProvider, { AuthorizationError, CimdFetchError, OAuthError } from "@cloudflare/workers-oauth-provider";
import type { ConsentDescription } from "@cloudflare/workers-oauth-provider";
import { emailAllowed, verifyAccess } from "./access";
import { verifyIngest } from "./ingest";
import { mcpHandler } from "./mcp";
import { offeredScopes } from "./policy";
import type { Env, GrantProps } from "./types";
import { SCOPE_MESSAGE, SCOPE_READ } from "./types";

export { HerdrState } from "./state";

const escape = (v: string) => v.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const SCOPE_TEXT: Record<string, string> = {
  [SCOPE_READ]: "Read fleet status: agents, tasks, blockers, task results.",
  [SCOPE_MESSAGE]: "Send one-line notes to live task agents (audited, rate-limited, never an approval or command).",
};

function consentPage(d: ConsentDescription, handle: string, email: string, offered: string[]): string {
  const origin = d.clientDomain
    ? `Published by <strong>${escape(d.clientDomain)}</strong>.`
    : "This app registered itself; its name is not verified.";
  const boxes = offered.map((s) => {
    // read is pre-ticked; message must be ticked deliberately.
    const checked = s === SCOPE_READ ? "checked" : "";
    return `<label><input type="checkbox" name="scope" value="${s}" ${checked}> <code>${s}</code> — ${escape(SCOPE_TEXT[s]!)}</label>`;
  }).join("<br>") + (offered.includes(SCOPE_MESSAGE) ? "" : "<p>Messaging agents is turned off on this server, so this connection is read-only.</p>");
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>herdr-mcp: authorize ${escape(d.clientName)}</title>
<style>body{font:15px system-ui;background:#111;color:#eee;max-width:640px;margin:40px auto;padding:0 16px}
code{color:#9cf}label{display:block;margin:8px 0}button{font:inherit;padding:6px 16px;margin-right:8px}</style>
<h1>Allow <em>${escape(d.clientName)}</em> to use herdr-mcp?</h1>
<p>${origin} Tokens go to <strong>${escape(d.redirectHost)}</strong>.</p>
${d.redirectIsLoopback ? "<p><strong>This sends access to an app on a local computer.</strong> Continue only if you just started this sign-in.</p>" : ""}
<p>Signed in as ${escape(email)} (Cloudflare Access). Nothing here can run commands, press keys, or answer approvals.</p>
<form method="post" action="/authorize">
<input type="hidden" name="handle" value="${escape(handle)}">
${boxes}
<p><button name="decision" value="approve">Allow</button><button name="decision" value="deny">Deny</button></p>
</form>`;
}

const text = (body: string, status: number) =>
  new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });

async function authorize(request: Request, env: Env): Promise<Response> {
  const who = await verifyAccess(request, env);
  if (!who) return text("Not authorized: a Cloudflare Access session for an allowed account is required.", 403);
  const oauth = env.OAUTH_PROVIDER;
  try {
    if (request.method === "GET") {
      const req = await oauth.parseAuthRequest(request);
      const details = await oauth.describeConsent(req);
      const consent = await oauth.beginConsent(req);
      consent.headers.set("content-type", "text/html; charset=utf-8");
      return new Response(consentPage(details, consent.handle, who.email, offeredScopes(env)), { headers: consent.headers });
    }
    if (request.method === "POST") {
      const form = await request.formData();
      const handle = String(form.get("handle") ?? "");
      if (form.get("decision") !== "approve") {
        const denied = await oauth.denyConsent(request, handle);
        return new Response(null, { status: 302, headers: denied.headers });
      }
      const offered = offeredScopes(env);
      const picked = form.getAll("scope").map(String).filter((s) => offered.includes(s));
      if (picked.length === 0) return text("Pick at least one scope.", 400);
      const approved = await oauth.approveConsent(request, handle, { scope: picked });
      const details = await oauth.describeConsent(approved.request);
      const { redirectTo } = await oauth.completeAuthorization({
        request: approved.request,
        userId: who.email,
        metadata: { access_sub: who.sub, client_name: details.clientName },
        scope: approved.request.scope,
        props: { email: who.email, client_name: details.clientName },
      });
      approved.headers.set("location", redirectTo);
      return new Response(null, { status: 302, headers: approved.headers });
    }
    return text("Method not allowed", 405);
  } catch (error) {
    if (error instanceof AuthorizationError && error.redirectTo) return Response.redirect(error.redirectTo, 302);
    if (error instanceof AuthorizationError) return text(error.description ?? "Authorization request rejected.", 400);
    if (error instanceof CimdFetchError) return text("This app could not be verified.", 400);
    throw error;
  }
}

async function ingest(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return text("Method not allowed", 405);
  const check = await verifyIngest(request, env.INGEST_KEY, Math.floor(Date.now() / 1000));
  if (!check.ok) return Response.json({ error: check.reason }, { status: check.status });
  const stub = env.HERDR_STATE.get(env.HERDR_STATE.idFromName("fleet"));
  const out = await stub.sync(Date.now(), check.nonce, check.body);
  if (!out.ok) return Response.json({ error: out.reason }, { status: out.status });
  return Response.json(out.response, { headers: { "cache-control": "no-store" } });
}

const defaultHandler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/authorize") return authorize(request, env);
    if (pathname === "/ingest/sync") return ingest(request, env);
    if (pathname === "/" || pathname === "/healthz") {
      return text("herdr-mcp: MCP endpoint is /mcp (OAuth 2.1). See /.well-known/oauth-protected-resource/mcp.", 200);
    }
    return text("Not found", 404);
  },
};

export function makeProvider(publicUrl: string, scopes: string[]): OAuthProvider<Env> {
  return new OAuthProvider<Env>({
    apiRoute: "/mcp",
    apiHandler: mcpHandler,
    defaultHandler,
    authorizeEndpoint: "/authorize",
    tokenEndpoint: "/oauth/token",
    clientRegistrationEndpoint: "/oauth/register",
    scopesSupported: scopes,
    requiredScopes: [SCOPE_READ],
    resourceMetadata: {
      resource: `${publicUrl}/mcp`,
      authorization_servers: [publicUrl],
      resource_name: "herdr-mcp (Team Thurber agent fleet status)",
    },
    accessTokenTTL: 3600,
    refreshTokenTTL: 30 * 86_400,
    refreshTokenIdleTTL: 7 * 86_400,
    clientIdMetadataDocumentEnabled: true,
    // invalid_grant also revokes the grant, so a removed email loses it for good.
    tokenExchangeCallback: ({ grantType, props, env }) => {
      const email = (props as GrantProps).email;
      if (grantType === "refresh_token" && !emailAllowed(env, email)) {
        throw new OAuthError("invalid_grant", { description: "This account is no longer allowed to use herdr-mcp." });
      }
    },
  });
}

// The provider is configured once per isolate from vars, which only change on deploy.
let provider: OAuthProvider<Env> | null = null;

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    provider ??= makeProvider(env.PUBLIC_URL, offeredScopes(env));
    return provider.fetch(request, env, ctx);
  },
};
