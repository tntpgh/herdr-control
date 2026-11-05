// Pure policy: connection state, scopes and client grants, the tool
// catalog, message text rules, rate limits. No I/O, so every rule here is
// unit-tested directly.
import type { Env, Snapshot, TaskRow } from "./types";
import { FM_DECIDE_NOTE, FM_PEER, FM_READ, FM_REPORTS, FM_REQUEST, SCOPE_OWNER_MESSAGE, SCOPE_READ } from "./types";

// The scopes this deployment will grant and honour. A token's scopes are
// always intersected with this, so turning a switch off takes effect on the
// next request, not when existing tokens expire. Read and reports are always
// offered; every scope that queues a note for Firstmate needs the owner
// inbox switch, because the inbox is the only route a note can take.
export function offeredScopes(env: Env): string[] {
  const scopes = [FM_READ, FM_REPORTS];
  if (env.OWNER_INBOX_ENABLED === "true") scopes.push(FM_REQUEST, FM_DECIDE_NOTE, FM_PEER);
  return scopes;
}

// The only OAuth clients that may hold any scope at all, by their
// Client-ID Metadata Document URL (the provider fetches and verifies the
// document, so the id is the app's own HTTPS URL, not a self-declared name).
// Dot and Duet get the same ceiling: they are the same assistant role
// reached from different tools (ChatGPT, Claude.ai), so either may relay the
// captain's decisions as a decision note -- a note Firstmate judges, never
// the captain's answer. Any other client -- including every Dynamic Client
// Registration -- is refused at consent and at /mcp. Widening a client is a
// code change and a security review.
export interface ClientGrant { label: string; scopes: readonly string[] }
export const CLIENT_GRANTS: Readonly<Record<string, ClientGrant>> = {
  "https://chatgpt.com/oauth/client.json": { label: "dot", scopes: [FM_READ, FM_REPORTS, FM_REQUEST, FM_DECIDE_NOTE, FM_PEER] },
  "https://claude.ai/oauth/mcp-oauth-client-metadata": { label: "duet", scopes: [FM_READ, FM_REPORTS, FM_REQUEST, FM_DECIDE_NOTE, FM_PEER] },
};

export function clientGrant(clientId: string): ClientGrant | null {
  return Object.hasOwn(CLIENT_GRANTS, clientId) ? CLIENT_GRANTS[clientId]! : null;
}

export function clientLabel(clientId: string): string {
  return clientGrant(clientId)?.label ?? "unknown";
}

// herdr-mcp scopes on tokens granted before the fm:* cutover, honoured only
// while LEGACY_HERDR_SCOPES is "true". herdr:message.owner never maps to
// fm:decide-note: a structured decision note is new, so it needs a fresh
// consent. Every other herdr scope (message, task.*) maps to nothing.
export const LEGACY_SCOPE_MAP: Readonly<Record<string, readonly string[]>> = {
  [SCOPE_READ]: [FM_READ, FM_REPORTS],
  [SCOPE_OWNER_MESSAGE]: [FM_REQUEST, FM_PEER],
};

// What a token may actually do right now: its granted scopes (legacy ones
// mapped while the switch is on), intersected with what this deployment
// offers and with the client's ceiling. Empty for any client not in
// CLIENT_GRANTS -- default deny.
export function effectiveScopes(env: Env, clientId: string, granted: readonly string[]): string[] {
  const ceiling = clientGrant(clientId)?.scopes;
  if (!ceiling) return [];
  const legacy = env.LEGACY_HERDR_SCOPES === "true";
  const held = new Set<string>();
  for (const s of granted) {
    if (s.startsWith("fm:")) held.add(s);
    else if (legacy && Object.hasOwn(LEGACY_SCOPE_MAP, s)) for (const m of LEGACY_SCOPE_MAP[s]!) held.add(m);
  }
  const offered = offeredScopes(env);
  return offered.filter((s) => held.has(s) && ceiling.includes(s));
}

// Every tool the MCP server can expose, with the scopes any one of which
// admits it and its own per-client rate limit (on top of the global
// per-client throttle in state.ts). A tool is registered for a caller only
// when one of its scopes is effective, and the gate re-checks both before
// it runs. write: the call queues something (its own audit row records the
// outcome); every other tool only reads.
export interface ToolPolicy {
  scopes: readonly string[];
  per_minute: number;
  per_hour: number;
  write: boolean;
}
const read = (per_minute: number, per_hour: number, scopes: readonly string[] = [FM_READ]): ToolPolicy =>
  ({ scopes, per_minute, per_hour, write: false });
export const TOOL_CATALOG: Readonly<Record<string, ToolPolicy>> = {
  get_status: read(20, 600),
  get_posture: read(20, 600),
  list_agents: read(20, 600),
  list_tasks: read(20, 600),
  get_task: read(30, 900),
  list_blockers: read(20, 600),
  list_decisions: read(20, 600),
  get_decision: read(30, 900),
  list_events: read(20, 600),
  wait_for_events: read(10, 300),
  get_consumer_position: read(10, 120),
  commit_consumer_position: read(10, 120),
  rebase_consumer_position: read(10, 120),
  get_task_result: read(30, 600, [FM_REPORTS]),
  list_reports: read(20, 300, [FM_REPORTS]),
  get_report: read(30, 600, [FM_REPORTS]),
  send_owner_message: { scopes: [FM_REQUEST], per_minute: 10, per_hour: 120, write: true },
  request_task: { scopes: [FM_REQUEST], per_minute: 2, per_hour: 12, write: true },
  answer_decision: { scopes: [FM_DECIDE_NOTE], per_minute: 4, per_hour: 30, write: true },
  get_owner_message_status: read(30, 900, [FM_REQUEST, FM_DECIDE_NOTE]),
  get_owner_reply: read(30, 900, [FM_REQUEST, FM_DECIDE_NOTE]),
  send_peer_message: { scopes: [FM_PEER], per_minute: 10, per_hour: 120, write: true },
  list_peer_messages: read(20, 600, [FM_PEER]),
};

export function toolPolicy(tool: string): ToolPolicy | null {
  return Object.hasOwn(TOOL_CATALOG, tool) ? TOOL_CATALOG[tool]! : null;
}

export function toolAllowed(tool: string, scopes: readonly string[]): boolean {
  return toolPolicy(tool)?.scopes.some((s) => scopes.includes(s)) ?? false;
}

// What this deployment is and allows, so anyone can check it before
// connecting (/healthz) and after (get_status). Contains no secret.
export interface ServerInfo {
  build_sha: string;
  owner_inbox_enabled: boolean;
  legacy_herdr_scopes: boolean;
  scopes_offered: string[];
  clients: Record<string, string[]>;
}

export function serverInfo(env: Env): ServerInfo {
  const offered = offeredScopes(env);
  const clients: Record<string, string[]> = {};
  for (const g of Object.values(CLIENT_GRANTS)) clients[g.label] = offered.filter((s) => g.scopes.includes(s));
  return { build_sha: env.BUILD_SHA, owner_inbox_enabled: env.OWNER_INBOX_ENABLED === "true",
    legacy_herdr_scopes: env.LEGACY_HERDR_SCOPES === "true", scopes_offered: offered, clients };
}

export type ConnectionState = "connected" | "degraded" | "disconnected" | "never_connected";

export interface Connection {
  state: ConnectionState;
  last_sync_at: string | null;
  age_seconds: number | null;
  stale_after_seconds: number;
  herdr_live: boolean | null;
  hub_rev: string | null;
  note: string;
}

export function connection(snapshot: Snapshot | null, lastSyncMs: number | null, nowMs: number, staleAfterS: number): Connection {
  if (!snapshot || lastSyncMs === null) {
    return {
      state: "never_connected", last_sync_at: null, age_seconds: null, stale_after_seconds: staleAfterS,
      herdr_live: null, hub_rev: null, note: "The Mac publisher has never synced. No herdr data is available.",
    };
  }
  const age = Math.max(0, Math.round((nowMs - lastSyncMs) / 1000));
  const base = {
    last_sync_at: new Date(lastSyncMs).toISOString(), age_seconds: age, stale_after_seconds: staleAfterS,
    herdr_live: snapshot.hub.live_connected, hub_rev: snapshot.hub.rev,
  };
  if (age > staleAfterS) {
    return { ...base, state: "disconnected",
      note: `No sync from the Mac for ${age}s. Everything below is the last known state as of last_sync_at, not live. Messages are refused until it reconnects.` };
  }
  if (!snapshot.hub.live_connected) {
    return { ...base, state: "degraded",
      note: "The Mac is syncing but the hub has lost its live herdr connection; task states are registry-only and may lag." };
  }
  return { ...base, state: "connected", note: "Live." };
}

// A task may receive a message only while a live agent is working it.
export const MESSAGEABLE_STATES: Record<string, true> = {
  starting: true, running: true, blocked: true, stalled: true, ready_review: true,
};

export function messageable(task: TaskRow): boolean {
  return MESSAGEABLE_STATES[task.state] === true && task.agent_live && !!task.pane_id && !!task.agent_id;
}

export type Resolution =
  | { ok: true; task: TaskRow }
  | { ok: false; reason: string; candidates?: string[] };

// target = a task_id, an agent_id, or a task label (the "named agent").
// Exactly one match, and it must be messageable; anything else is refused.
export function resolveTarget(snapshot: Snapshot, target: string): Resolution {
  const t = target.trim();
  if (!t) return { ok: false, reason: "empty_target" };
  const byId = snapshot.tasks.find((x) => x.task_id === t);
  const byAgent = byId ? undefined : snapshot.tasks.filter((x) => x.agent_id === t && messageable(x));
  let hits: TaskRow[];
  if (byId) hits = [byId];
  else if (byAgent && byAgent.length) hits = byAgent;
  else hits = snapshot.tasks.filter((x) => x.label === t && messageable(x));
  if (hits.length === 0) {
    const agent = snapshot.agents.find((a) => a.agent_id === t || a.label === t);
    if (agent && !agent.task_id) return { ok: false, reason: "agent_has_no_task" };
    const anyLabel = snapshot.tasks.some((x) => x.label === t);
    return { ok: false, reason: anyLabel ? "task_not_messageable" : "unknown_target" };
  }
  if (hits.length > 1) return { ok: false, reason: "ambiguous_target", candidates: hits.map((h) => h.task_id) };
  const task = hits[0]!;
  if (!messageable(task)) return { ok: false, reason: "task_not_messageable" };
  return { ok: true, task };
}

export const MAX_MESSAGE_CHARS = 2000;

// Delivery types the text into an agent's composer and presses Enter, so the
// text must be exactly one line of visible characters: no control bytes (ESC
// sequences, CR/LF that would submit early), no format characters (bidi
// overrides, zero-width, tag characters) that hide text from the human
// watching the pane, and no square brackets, which could close the
// publisher's "[REMOTE NOTE …]" envelope and forge a second one. The
// publisher re-applies the same rule before framing.
//
// Every bracket shape could imitate the envelope: all opening/closing
// punctuation (\p{Ps}/\p{Pe}: 【〔⟦❲⦋⸢⁅⌈﴾…, fullwidth already folded by NFKC)
// becomes ( / ), except ASCII { } kept for code; the bracket-piece symbols
// (⎛…⎳, category Sm) become spaces.
const OPEN_LIKE = /[^\P{Ps}{]/gu;
const CLOSE_LIKE = /[^\P{Pe}}]/gu;
const BRACKET_PIECES = /[\u239b-\u23b3]/gu;
// omp (and Claude Code) expand "@path" in a submitted prompt into that file's
// contents with no tool call and no approval (round-3 review H1). The ASCII
// "@" becomes the fullwidth "＠", which reads the same and no mention parser
// matches. Applied after NFKC, which would fold it back.
const AT = /@/g;
// Invisible or non-printing: every \p{C} (control, format, surrogate, private
// use, unassigned), line/paragraph separators, combining marks (incl.
// variation selectors; NFKC has already composed accented letters), and the
// blank letters/symbols that are not \p{C}: Hangul fillers and Braille blank.
const INVISIBLE = /[\p{C}\p{Zl}\p{Zp}\p{Mn}\p{Me}\u115f\u1160\u3164\uffa0\u2800]+/gu;

export function sanitizeMessage(text: string): { ok: true; text: string } | { ok: false; reason: string } {
  const cleaned = text.normalize("NFKC")
    .replace(INVISIBLE, " ")
    .replace(OPEN_LIKE, "(").replace(CLOSE_LIKE, ")").replace(BRACKET_PIECES, " ")
    .replace(AT, "\uff20")
    .replace(/\s+/g, " ").trim();
  if (!cleaned) return { ok: false, reason: "empty_text" };
  if (cleaned.length > MAX_MESSAGE_CHARS) return { ok: false, reason: `text_too_long (max ${MAX_MESSAGE_CHARS})` };
  return { ok: true, text: cleaned };
}

// start_task's objective is embedded as a fenced UNTRUSTED block in the
// spawned worker's own SPEC.md (remote-mcp/tasks.py), not typed into a
// terminal composer, so (via cleanMultiline below) its newlines survive --
// unlike sanitizeMessage. Invisible/format characters are still hidden,
// every bracket shape neutralised (so the objective cannot forge SPEC.md's
// own "## UNTRUSTED" fencing), and "@path" defused (omp/Claude Code would
// otherwise expand it into that file's contents with no tool call and no
// approval -- round-3 review H1, the same hazard sanitizeMessage exists for).
export const MAX_OBJECTIVE_CHARS = 4000;

// Shared by sanitizeObjective and sanitizeOwnerMessage: both embed multi-line
// untrusted text into a FILE (SPEC.md's fenced block / the inbox markdown
// doc), never type it into a pane composer, so -- unlike sanitizeMessage --
// newlines survive. Everything else is identical: NFKC, invisible/format
// characters to spaces, every bracket shape neutralised, "@" defused.
function cleanMultiline(text: string): string {
  // Split on "\n" FIRST: INVISIBLE matches \p{C}, which includes the
  // newline itself, so cleaning the whole string in one pass (as
  // sanitizeMessage does) would silently collapse every line break. Clean
  // each line in isolation, then rejoin, so the newlines the comment above
  // promises actually survive.
  return text.normalize("NFKC").split("\n")
    .map((line) => line
      .replace(INVISIBLE, " ")
      .replace(OPEN_LIKE, "(").replace(CLOSE_LIKE, ")").replace(BRACKET_PIECES, " ")
      .replace(AT, "\uff20")
      .replace(/[ \t]+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function sanitizeObjective(text: string): { ok: true; text: string } | { ok: false; reason: string } {
  const cleaned = cleanMultiline(text);
  if (!cleaned) return { ok: false, reason: "empty_objective" };
  if (cleaned.length > MAX_OBJECTIVE_CHARS) return { ok: false, reason: `objective_too_long (max ${MAX_OBJECTIVE_CHARS})` };
  return { ok: true, text: cleaned };
}

// send_owner_message's body: same multi-line cleaning as an objective, but
// capped at the existing message size (SPEC: "size cap reuses the existing
// message cap"), since this reaches a human/agent inbox, not a spawned
// worker's SPEC.md.
export function sanitizeOwnerMessage(text: string): { ok: true; text: string } | { ok: false; reason: string } {
  const cleaned = cleanMultiline(text);
  if (!cleaned) return { ok: false, reason: "empty_body" };
  if (cleaned.length > MAX_MESSAGE_CHARS) return { ok: false, reason: `body_too_long (max ${MAX_MESSAGE_CHARS})` };
  return { ok: true, text: cleaned };
}

// Messages per user (all clients together). The defaults apply unless the Mac
// has set an override (scripts/limits.py → /admin/limits), optionally until a
// time, after which the defaults come back on their own.
export const DEFAULT_LIMITS = { per_minute: 5, per_hour: 30 } as const;
// ceiling: no override may exceed these. Raising the ceiling itself is a code
// change and a security review, not an admin call.
export const MAX_LIMITS = { per_minute: 30, per_hour: 300 } as const;

// send_owner_message: fixed and NOT admin-adjustable (Terrence's decision,
// form 20261002T142819-8748: "separate, lower limits" for this route; raised
// from 2/20 to 10/120 on his 2026-10-04 approval) -- changing these is a code
// change and a security review, exactly like MAX_LIMITS above, not an
// scripts/limits.py-style runtime override. Still well under the generic
// per-client throttle (CALLS_PER_MINUTE=60 in state.ts), so it binds first.
export const OWNER_LIMITS = { per_minute: 10, per_hour: 120 } as const;

// register-owner.sh's own label regex, re-checked here so a send targeting a
// syntactically-invalid label is refused the same way an unregistered one is.
export const OWNER_LABEL = /^[a-z0-9][a-z0-9-]{1,40}$/;

export interface MessageLimits {
  per_minute: number;
  per_hour: number;
  source: "default" | "override";
  until: string | null; // override expiry (ISO), null = until reset
  reason: string;
}

export function rateLimited(recentMs: number[], nowMs: number, limits: Pick<MessageLimits, "per_minute" | "per_hour">): string | null {
  const minute = recentMs.filter((t) => nowMs - t < 60_000).length;
  const hour = recentMs.filter((t) => nowMs - t < 3_600_000).length;
  if (minute >= limits.per_minute) return `rate_limited (${limits.per_minute}/minute)`;
  if (hour >= limits.per_hour) return `rate_limited (${limits.per_hour}/hour)`;
  return null;
}
