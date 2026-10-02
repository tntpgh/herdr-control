import { SELF, env } from "cloudflare:test";
import { importJWK, SignJWT } from "jose";
import { sign } from "../src/ingest";
import type { Snapshot, SyncBody } from "../src/types";

export const BASE = "https://herdr-mcp.teamthurber.com";
export const REDIRECT = "https://chatgpt.com/connector_platform_oauth_redirect";
const testEnv = env as unknown as { TEST_ACCESS_PRIVATE_JWK: string; INGEST_KEY: string };

export async function accessJwt(email: string, aud = "test-aud"): Promise<string> {
  const key = await importJWK(JSON.parse(testEnv.TEST_ACCESS_PRIVATE_JWK), "RS256");
  return new SignJWT({ email })
    .setProtectedHeader({ alg: "RS256", kid: "test-kid" })
    .setIssuer("https://thurberteam.cloudflareaccess.com")
    .setAudience(aud)
    .setSubject(`sub-${email}`)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key);
}

const b64url = (buf: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

// Full OAuth 2.1 authorization-code + PKCE flow, the way ChatGPT runs it:
// DCR, /authorize behind Access, consent, code exchange with `resource`.
export async function oauthToken(scopes: string[], email = "tnt@teamthurber.com"): Promise<{ access_token: string; scope: string }> {
  const reg = await SELF.fetch(`${BASE}/oauth/register`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ redirect_uris: [REDIRECT], client_name: "Zero", token_endpoint_auth_method: "none",
      grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] }),
  });
  if (reg.status !== 201) throw new Error(`register ${reg.status} ${await reg.text()}`);
  const { client_id } = (await reg.json()) as { client_id: string };
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(32)).buffer);
  const challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  const q = new URLSearchParams({
    response_type: "code", client_id, redirect_uri: REDIRECT, scope: scopes.join(" "), state: "st8",
    code_challenge: challenge, code_challenge_method: "S256", resource: `${BASE}/mcp`,
  });
  const jwt = await accessJwt(email);
  const page = await SELF.fetch(`${BASE}/authorize?${q}`, { headers: { "cf-access-jwt-assertion": jwt } });
  if (page.status !== 200) throw new Error(`authorize GET ${page.status} ${await page.text()}`);
  const html = await page.text();
  const handle = /name="handle" value="([^"]+)"/.exec(html)?.[1];
  const cookie = page.headers.getSetCookie().map((c: string) => c.split(";")[0]).join("; ");
  const form = new URLSearchParams({ handle: handle!, decision: "approve" });
  for (const s of scopes) form.append("scope", s);
  const post = await SELF.fetch(`${BASE}/authorize`, {
    method: "POST", redirect: "manual",
    headers: { "cf-access-jwt-assertion": jwt, cookie, origin: BASE, "content-type": "application/x-www-form-urlencoded" },
    body: form,
  });
  if (post.status !== 302) throw new Error(`authorize POST ${post.status} ${await post.text()}`);
  const loc = new URL(post.headers.get("location")!);
  const code = loc.searchParams.get("code")!;
  const tok = await SELF.fetch(`${BASE}/oauth/token`, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: REDIRECT, client_id,
      code_verifier: verifier, resource: `${BASE}/mcp` }),
  });
  if (tok.status !== 200) throw new Error(`token ${tok.status} ${await tok.text()}`);
  return (await tok.json()) as { access_token: string; scope: string };
}

let rpcId = 0;
// T is the shape the test expects; the tests then assert on it, so a wrong
// guess fails loudly rather than reading undefined silently.
export async function callTool<T = Record<string, unknown>>(token: string, name: string, args: Record<string, unknown> = {}):
  Promise<{ data: T & { error?: string; connection?: { state: string; last_sync_at: string | null } }; isError: boolean }> {
  const res = await SELF.fetch(`${BASE}/mcp`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method: "tools/call", params: { name, arguments: args } }),
  });
  const raw: unknown = await res.json();
  if (!raw || typeof raw !== "object" || !("result" in raw) || !raw.result || typeof raw.result !== "object") {
    throw new Error(`tools/call ${name}: ${res.status} ${JSON.stringify(raw)}`);
  }
  const result = raw.result;
  const data = "structuredContent" in result ? result.structuredContent : undefined;
  const isError = "isError" in result && result.isError === true;
  // Tool input-validation errors come back as isError text with no structured content.
  const typed = (data ?? { error: "invalid_arguments" }) as T & { error?: string; connection?: { state: string; last_sync_at: string | null } };
  return { data: typed, isError };
}

export async function signedPost(path: string, body: unknown, opts: { nonce?: string; ts?: number; key?: string } = {}) {
  const raw = JSON.stringify(body);
  const ts = String(opts.ts ?? Math.floor(Date.now() / 1000));
  const nonce = opts.nonce ?? [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
  const sig = await sign(opts.key ?? testEnv.INGEST_KEY, ts, nonce, raw);
  return SELF.fetch(`${BASE}${path}`, {
    method: "POST", headers: { "content-type": "application/json", "x-herdr-ts": ts, "x-herdr-nonce": nonce, "x-herdr-sig": sig },
    body: raw,
  });
}

export const signedSync = (body: SyncBody, opts: { nonce?: string; ts?: number; key?: string } = {}) =>
  signedPost("/ingest/sync", body, opts);

export function snapshot(overrides: Partial<Snapshot> = {}): Snapshot {
  const now = new Date().toISOString();
  const task = (id: string, label: string, state: string, agent: string | null, live: boolean) => ({
    task_id: id, run_id: `run_${id}`, label, project: "knowledge-base", repo: "knowledge-base", branch: label,
    state, stored_state: state, state_source: "live", created_at: now, updated_at: now, completed_at: null,
    closure_reason: null, closure_proof: null, pane_id: agent ? `w1:${agent}` : null, agent_id: agent, agent_live: live, has_result: false,
    remote_task_id: null, verified: null, verify_detail: null,
  });
  return {
    schema: 1,
    generated_at: now,
    hub: { rev: "abc1234", live_connected: true, herdr_reachable: true, attention: 1, open_decisions: 0, handoff_debt: 0 },
    agents: [
      { agent_id: "term_a", pane_id: "w1:term_a", workspace: "kb", tab_id: "w1:t1", kind: "omp", label: "implement:feat/a",
        role: "worker", status: "working", status_since: now, task_id: "task_A" },
      { agent_id: "term_c", pane_id: "w1:term_c", workspace: "thurber-os", tab_id: "w1:t0", kind: "omp", label: null,
        role: "conductor", status: "idle", status_since: now, task_id: null },
    ],
    tasks: [
      task("task_A", "implement:feat/a", "running", "term_a", true),
      task("task_B", "implement:feat/b", "completed", null, false),
      task("task_D1", "review:dup", "running", "term_d1", true),
      task("task_D2", "review:dup", "blocked", "term_d2", true),
      task("task_S", "implement:feat/stale-pane", "running", "term_s", false),
    ],
    blockers: [{ task_id: "task_D2", label: "review:dup", pane_id: "w1:term_d2", agent_id: "term_d2", kind: "permission",
      tool: "bash", summary: "bash: git push origin feat/x", since: now }],
    task_config: null,
    ...overrides,
  };
}

export function syncBody(over: Partial<SyncBody> = {}): SyncBody {
  return { snapshot: snapshot(), results: [], acks: [], command_acks: [], audit_cursor: 0, lease: true, ...over };
}

// A message already sitting in the queue, as if sent under an earlier policy
// (messaging on, sender still allowed). Returns its id.
export function queueRaw(storage: DurableObjectStorage, actor = "tnt@teamthurber.com", clientId = "c"): string {
  const id = `msg_${crypto.randomUUID()}`;
  const now = Date.now();
  storage.sql.exec(`INSERT INTO messages VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, id, now, now, now + 900_000,
    actor, clientId, "Zero", "task_A", "w1:term_a", "term_a", "implement:feat/a", "hi", "queued", "", 0, 0);
  return id;
}
