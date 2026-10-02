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
import { DEFAULT_LIMITS, MAX_LIMITS, offeredScopes, serverInfo } from "./policy";
import type { ScopedSender } from "./state";
import type { DeliveryGate, Env, GrantProps, Sender } from "./types";
import { SCOPE_MESSAGE, SCOPE_READ, SCOPE_TASK_CANCEL, SCOPE_TASK_IMPLEMENT, SCOPE_TASK_START } from "./types";

export { HerdrState } from "./state";

const escape = (v: string) => v.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const SCOPE_TEXT: Record<string, string> = {
  [SCOPE_READ]: "Read fleet status: agents, tasks, blockers, task results.",
  [SCOPE_MESSAGE]: "Send one-line notes to live task agents (audited, rate-limited, never an approval or command).",
  [SCOPE_TASK_START]: "Start read-only research tasks (no git writes, no push) and read their answers.",
  [SCOPE_TASK_IMPLEMENT]: "Start implement tasks that commit and push their own branch, and read their answers.",
  [SCOPE_TASK_CANCEL]: "Cancel or resume a task this connection started.",
};

function consentPage(d: ConsentDescription, handle: string, email: string, offered: string[]): string {
  const origin = d.clientDomain
    ? `Published by <strong>${escape(d.clientDomain)}</strong>.`
    : "This app registered itself; its name is not verified.";
  const boxes = offered.map((s) => {
    // read is pre-ticked; every other scope (message, task.*) must be ticked deliberately.
    const checked = s === SCOPE_READ ? "checked" : "";
    return `<label><input type="checkbox" name="scope" value="${s}" ${checked}> <code>${s}</code> — ${escape(SCOPE_TEXT[s]!)}</label>`;
  }).join("<br>");
  const notes = [
    !offered.includes(SCOPE_MESSAGE) ? "Messaging agents is turned off on this server." : "",
    !offered.includes(SCOPE_TASK_START) && !offered.includes(SCOPE_TASK_IMPLEMENT) ? "Starting tasks is turned off on this server." : "",
  ].filter(Boolean).join(" ");
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>herdr-mcp: authorize ${escape(d.clientName)}</title>
<style>body{font:15px system-ui;background:#111;color:#eee;max-width:640px;margin:40px auto;padding:0 16px}
code{color:#9cf}label{display:block;margin:8px 0}button{font:inherit;padding:6px 16px;margin-right:8px}</style>
<h1>Allow <em>${escape(d.clientName)}</em> to use herdr-mcp?</h1>
<p>${origin} Tokens go to <strong>${escape(d.redirectHost)}</strong>.</p>
${d.redirectIsLoopback ? "<p><strong>This sends access to an app on a local computer.</strong> Continue only if you just started this sign-in.</p>" : ""}
<p>Signed in as ${escape(email)} (Cloudflare Access). Read and message scopes can never run commands, press keys, or answer approvals; the task scopes below can start a sandboxed worker in an allow-listed repo, nothing more.</p>
<form method="post" action="/authorize">
<input type="hidden" name="handle" value="${escape(handle)}">
${boxes}
${notes ? `<p>${notes}</p>` : ""}
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

// Does this (actor, client_id) still hold a live grant with the scope its own
// queued item needs? Checked right before delivery/leasing, so a revoked or
// expired grant stops a message already queued (scope herdr:message) or a
// task command already queued (scope herdr:task.start/implement, per
// request -- a research start and an implement start need different
// scopes, so this takes the scope per-request rather than one for all).
// (KV listing can lag a deletion by up to ~60 s.)
async function grantGate(env: Env, enabled: boolean, requests: ScopedSender[], nowMs: number): Promise<DeliveryGate> {
  if (!enabled || requests.length === 0) return { revoked: [], hold: false };
  try {
    const revoked: Sender[] = [];
    for (const actor of new Set(requests.map((r) => r.actor))) {
      const liveScopesByClient = new Map<string, Set<string>>();
      let cursor: string | undefined;
      do {
        const page = await env.OAUTH_PROVIDER.listUserGrants(actor, { cursor });
        for (const g of page.items) {
          if (g.expiresAt !== undefined && g.expiresAt * 1000 <= nowMs) continue;
          const scopes = liveScopesByClient.get(g.clientId) ?? new Set<string>();
          for (const s of g.scope) scopes.add(s);
          liveScopesByClient.set(g.clientId, scopes);
        }
        cursor = page.cursor;
      } while (cursor);
      for (const r of requests.filter((req) => req.actor === actor)) {
        if (!liveScopesByClient.get(r.client_id)?.has(r.scope)) revoked.push({ actor: r.actor, client_id: r.client_id });
      }
    }
    return { revoked, hold: false };
  } catch (error) {
    // Fail closed without losing queued work: deliver/lease nothing this tick.
    console.error("herdr-mcp: grant check failed; holding the queue", error);
    return { revoked: [], hold: true };
  }
}

async function ingest(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return text("Method not allowed", 405);
  const check = await verifyIngest(request, env.INGEST_KEY, Math.floor(Date.now() / 1000));
  if (!check.ok) return Response.json({ error: check.reason }, { status: check.status });
  const stub = env.HERDR_STATE.get(env.HERDR_STATE.idFromName("fleet"));
  const now = Date.now();
  const msgSenders: ScopedSender[] = (await stub.pendingSenders(now)).map((s) => ({ ...s, scope: SCOPE_MESSAGE }));
  const gate = await grantGate(env, env.MESSAGING_ENABLED === "true", msgSenders, now);
  const cmdGate = await grantGate(env, env.TASKS_ENABLED === "true",
    [...(await stub.pendingCommandSenders(now)), ...(await stub.activeTaskSenders())], now);
  const out = await stub.sync(Date.now(), check.nonce, check.body, gate, cmdGate);
  if (!out.ok) return Response.json({ error: out.reason }, { status: out.status });
  return Response.json(out.response, { headers: { "cache-control": "no-store" } });
}

// Mac-only grant administration, signed with the same INGEST_KEY as /ingest
// (the Mac already holds it; no user token can reach this). One grant can be
// revoked without touching ALLOWED_EMAILS. Bodies:
//   {"op":"list","user":"<email>"}
//   {"op":"revoke","user":"<email>","grant_id":"<id>"}
// Revocation deletes the grant and its tokens; queued messages from it are
// then cancelled by deliveryGate on the next sync.
async function adminGrants(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return text("Method not allowed", 405);
  const check = await verifyIngest(request, env.INGEST_KEY, Math.floor(Date.now() / 1000));
  if (!check.ok) return Response.json({ error: check.reason }, { status: check.status });
  let body: { op?: unknown; user?: unknown; grant_id?: unknown };
  try { body = JSON.parse(check.body); } catch { return Response.json({ error: "bad_json" }, { status: 400 }); }
  const { op, user, grant_id: grantId } = body;
  if ((op !== "list" && op !== "revoke") || typeof user !== "string" || !user || user.length > 320) {
    return Response.json({ error: "bad_request" }, { status: 400 });
  }
  if (op === "revoke" && (typeof grantId !== "string" || !/^[\w:-]{1,200}$/.test(grantId))) {
    return Response.json({ error: "bad_grant_id" }, { status: 400 });
  }
  const stub = env.HERDR_STATE.get(env.HERDR_STATE.idFromName("fleet"));
  const target = op === "revoke" ? `${user} ${grantId as string}` : user;
  if (!(await stub.admitAdmin(Date.now(), check.nonce, op, target))) {
    return Response.json({ error: "replayed_nonce" }, { status: 409 });
  }
  const grants = [];
  let cursor: string | undefined;
  do {
    const page = await env.OAUTH_PROVIDER.listUserGrants(user, { cursor });
    grants.push(...page.items.map((g) => ({ grant_id: g.id, client_id: g.clientId, scope: g.scope,
      created_at: new Date(g.createdAt * 1000).toISOString(),
      expires_at: g.expiresAt === undefined ? null : new Date(g.expiresAt * 1000).toISOString() })));
    cursor = page.cursor;
  } while (cursor);
  if (op === "list") return Response.json({ user, grants }, { headers: { "cache-control": "no-store" } });
  if (!grants.some((g) => g.grant_id === grantId)) return Response.json({ error: "no_such_grant" }, { status: 404 });
  await env.OAUTH_PROVIDER.revokeGrant(grantId as string, user);
  return Response.json({ revoked: grantId, user }, { headers: { "cache-control": "no-store" } });
}

// Mac-only message-limit administration, same signing as /admin/grants.
//   {"op":"get"}
//   {"op":"set","per_minute":N,"per_hour":N,"minutes":N|null,"reason":"…"}
//   {"op":"reset"}                       back to DEFAULT_LIMITS
// "minutes" makes the override temporary (a boost); null keeps it until reset.
// Values above MAX_LIMITS are refused, never clamped, so a typo can't
// silently become the ceiling.
async function adminLimits(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return text("Method not allowed", 405);
  const check = await verifyIngest(request, env.INGEST_KEY, Math.floor(Date.now() / 1000));
  if (!check.ok) return Response.json({ error: check.reason }, { status: check.status });
  let body: { op?: unknown; per_minute?: unknown; per_hour?: unknown; minutes?: unknown; reason?: unknown };
  try { body = JSON.parse(check.body); } catch { return Response.json({ error: "bad_json" }, { status: 400 }); }
  const { op } = body;
  if (op !== "get" && op !== "set" && op !== "reset") return Response.json({ error: "bad_request" }, { status: 400 });
  const int = (v: unknown, max: number) => typeof v === "number" && Number.isInteger(v) && v >= 1 && v <= max;
  if (op === "set") {
    const { per_minute: pm, per_hour: ph, minutes, reason } = body;
    if (!int(pm, MAX_LIMITS.per_minute) || !int(ph, MAX_LIMITS.per_hour) || (pm as number) > (ph as number)) {
      return Response.json({ error: "out_of_bounds", max: MAX_LIMITS }, { status: 400 });
    }
    if (minutes !== null && !int(minutes, 7 * 24 * 60)) return Response.json({ error: "bad_minutes (1..10080 or null)" }, { status: 400 });
    if (typeof reason !== "string" || !reason.trim() || reason.length > 200) return Response.json({ error: "reason_required" }, { status: 400 });
  }
  const stub = env.HERDR_STATE.get(env.HERDR_STATE.idFromName("fleet"));
  const target = op === "set" ? `${String(body.per_minute)}/min ${String(body.per_hour)}/h for ${String(body.minutes ?? "until reset")}m: ${String(body.reason)}` : "";
  const now = Date.now();
  if (!(await stub.admitAdmin(now, check.nonce, `limits_${op}`, target))) {
    return Response.json({ error: "replayed_nonce" }, { status: 409 });
  }
  const limits = op === "get" ? await stub.messageLimits(now)
    : op === "reset" ? await stub.setMessageLimits(now, null)
    : await stub.setMessageLimits(now, { per_minute: body.per_minute as number, per_hour: body.per_hour as number,
        until_ms: body.minutes === null ? null : now + (body.minutes as number) * 60_000, reason: (body.reason as string).trim() });
  return Response.json({ limits, defaults: DEFAULT_LIMITS, max: MAX_LIMITS }, { headers: { "cache-control": "no-store" } });
}

const defaultHandler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/authorize") return authorize(request, env);
    if (pathname === "/ingest/sync") return ingest(request, env);
    if (pathname === "/admin/grants") return adminGrants(request, env);
    if (pathname === "/admin/limits") return adminLimits(request, env);
    if (pathname === "/" || pathname === "/healthz") {
      return Response.json({ service: "herdr-mcp", mcp: `${env.PUBLIC_URL}/mcp`, auth: "OAuth 2.1 + PKCE", ...serverInfo(env) },
        { headers: { "cache-control": "no-store" } });
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
