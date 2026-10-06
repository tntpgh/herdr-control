// The one Durable Object: latest snapshot, task results, the message queue,
// the remote-task lifecycle (herdr-mcp's start/cancel/resume commands and
// task_events feed), and the audit trail. Single-threaded, so the
// send-message/start-task policy checks and their enqueue happen atomically
// against the same snapshot.
import { DurableObject } from "cloudflare:workers";
import { z } from "zod";
import { emailAllowed } from "./access";
import { connection, DEFAULT_LIMITS, OWNER_LABEL, OWNER_LIMITS, rateLimited, resolveTarget, sanitizeMessage, sanitizeObjective, sanitizeOwnerMessage } from "./policy";
import type { Connection, MessageLimits } from "./policy";
import type { CommandAck, CommandItem, CommandOp, DeliveryGate, Env, OutboxItem, OwnerAck, OwnerOutboxItem, OwnerReplySync, ResultDoc, Sender, Snapshot, TaskCaps, TaskRow } from "./types";
import { SCOPE_OWNER_MESSAGE, SCOPE_READ, SCOPE_TASK_CANCEL, SCOPE_TASK_IMPLEMENT, SCOPE_TASK_START, SNAPSHOT_SCHEMA } from "./types";

const str = z.string().max(4000);
const ExtState = z.enum(["enabled", "disabled", "missing", "unknown"]);
const nstr = str.nullable();
const SyncSchema = z.object({
  snapshot: z.object({
    schema: z.literal(SNAPSHOT_SCHEMA),
    generated_at: str,
    hub: z.object({
      rev: nstr, live_connected: z.boolean(), herdr_reachable: z.boolean(),
      attention: z.number().nullable(), open_decisions: z.number().nullable(), handoff_debt: z.number().nullable(),
    }),
    agents: z.array(z.object({
      agent_id: str, pane_id: str, workspace: nstr, tab_id: nstr, kind: nstr, label: nstr,
      role: z.enum(["worker", "conductor", "session"]), status: str, status_since: nstr, task_id: nstr,
    })).max(500),
    tasks: z.array(z.object({
      task_id: str, run_id: str, label: str, project: str, repo: str, branch: str, state: str,
      stored_state: nstr, state_source: nstr, created_at: str, updated_at: str, completed_at: nstr,
      closure_reason: nstr, closure_proof: nstr, pane_id: nstr, agent_id: nstr, agent_live: z.boolean(), has_result: z.boolean(),
      has_answer: z.boolean().optional(),
      remote_task_id: nstr.optional(), verified: z.boolean().nullable().optional(), verify_detail: nstr.optional(),
    })).max(2000),
    blockers: z.array(z.object({
      task_id: nstr, label: nstr, pane_id: nstr, agent_id: nstr, kind: str, tool: nstr, summary: nstr, since: nstr,
    })).max(500),
    task_config: z.object({
      mac_enabled: z.boolean(),
      repos: z.array(str).max(200),
      modes: z.object({
        research: z.object({ job_class: str, secrets: z.enum(["grant", "default"]), git: z.enum(["none", "commit-only", "push-own-branch"]), writes: z.array(str).max(50), net_read: z.array(str).max(50) }),
        implement: z.object({ job_class: str, secrets: z.enum(["grant", "default"]), git: z.enum(["none", "commit-only", "push-own-branch"]), writes: z.array(str).max(50), net_read: z.array(str).max(50) }),
      }),
      caps: z.object({ max_concurrent: z.number().int().min(1).max(100), max_per_day: z.number().int().min(1).max(1000), max_minutes: z.number().int().min(1).max(1440) }),
    }).nullable().optional(),
    // A bad browser block becomes null rather than failing the whole sync
    // (results, acks and command acks ride in the same body).
    browser: z.object({
      checked_at: z.string().max(40), real_chrome_running: z.boolean(),
      relay: z.string().regex(/^(connected|no-extension|down|http-\d{3})$/),
      extensions: z.object({ omp_relay: ExtState, "1password": ExtState, chatgpt: ExtState }),
      stray_omp_chromes: z.number().int().min(0).max(1000), healthy: z.boolean(),
    }).nullable().optional().catch(null),
    // label + liveness only -- never pane_id/cwd (README "What leaves the Mac").
    owners: z.array(z.object({ label: str, live: z.boolean() })).max(200).nullable().optional(),
  }),
  results: z.array(z.object({
    task_id: str, source: str, text: z.string().max(70_000), sha256: str, source_mtime: nstr, truncated_at_source: z.boolean(),
  })).max(400),
  acks: z.array(z.object({
    message_id: str, outcome: z.enum(["delivered", "refused", "failed", "retry"]), detail: str,
  })).max(200),
  command_acks: z.array(z.object({
    command_id: str, outcome: z.enum(["accepted", "refused", "failed"]), detail: str,
    local_task_id: str.optional(), local_run_id: str.optional(), branch: str.optional(),
    pane_id: str.optional(), agent_id: str.optional(), capability_probe: z.record(z.string(), z.boolean()).optional(),
  })).max(200).optional(),
  owner_acks: z.array(z.object({
    exchange_id: str, outcome: z.enum(["delivered", "blocked"]), reason: str.optional(),
  })).max(200).optional(),
  owner_replies: z.array(z.object({
    exchange_id: str, owner_label: str, body: z.string().max(70_000), responded_at: str,
    artifact_revision: str, session: str,
  })).max(200).optional(),
  audit_cursor: z.number().int().min(0),
  lease: z.boolean(),
});

export interface AuditRow {
  seq: number;
  at: string;
  actor: string;
  client_id: string;
  tool: string;
  target: string;
  decision: string; // allowed | refused | queued | delivered | refused_at_delivery | failed | expired | retry
  reason: string;
  message_id: string;
  detail: string;
}

export interface SyncResponse {
  outbox: OutboxItem[];
  commands: CommandItem[];
  owner_outbox: OwnerOutboxItem[];
  audit: AuditRow[];
  audit_cursor: number;
  // #225 review H1: per-reply outcome, so the Mac can tell "the Worker
  // accepted this reply" (move to replies/sent/) apart from "the Worker
  // silently dropped it" (state.ts ~1028-1031's own continue, because the
  // row's status was not 'delivered') -- a 200 response alone was being
  // read as universal acceptance, which let a dropped reply get pruned at
  // 30 days without the Worker ever having seen it. outcome is one of
  // "accepted" | "duplicate" (status already 'replied' AND the stored
  // reply_body matches this resend -- #225 review round 3 N3) |
  // "ignored:replied" (status already 'replied' but with a DIFFERENT
  // body: the owner changed their mind after the Worker stored the
  // first reply) | `ignored:${status}` (row missing/label mismatch ->
  // "ignored:missing", otherwise the row's own status, e.g.
  // "ignored:queued"). owner_label is always the REQUESTED label from
  // the reply itself (#225 review round 3 N1), echoed back so the Mac
  // can key results by (owner_label, exchange_id) -- matching by
  // exchange_id alone would let a reply misfiled under the wrong label
  // directory be matched against a DIFFERENT exchange's real result.
  owner_reply_results: { exchange_id: string; owner_label: string; outcome: string }[];
}

export type SyncOutcome = { ok: true; response: SyncResponse } | { ok: false; status: number; reason: string };

export interface Caller {
  email: string;
  client_id: string;
  client_name: string;
}

export interface MessageRecord {
  message_id: string;
  created_at: string;
  updated_at: string;
  expires_at: string;
  status: string; // queued | delivering | delivered | refused | failed | expired
  detail: string;
  attempts: number;
  target: { task_id: string; label: string; agent_id: string };
  text_chars: number;
}

export type SendOutcome =
  | { ok: true; message: MessageRecord }
  | { ok: false; reason: string; candidates?: string[] };

export interface OwnerMessageRecord {
  exchange_id: string;
  created_at: string;
  updated_at: string;
  status: string; // queued | delivered | blocked:<reason> | replied
  detail: string;
  attempts: number;
  owner_label: string;
  delivered_at: string | null;
  body_chars: number;
}

export type SendOwnerMessageOutcome =
  | { ok: true; exchange_id: string; state: string }
  | { ok: false; reason: string };

export interface OwnerReplyRecord {
  exchange_id: string;
  owner_label: string;
  session: string;
  responded_at: string;
  artifact_revision: string;
  body: string;
}

export interface View {
  snapshot: Snapshot | null;
  connection: Connection;
}

// The remote task lifecycle states a client is ever shown (SPEC). Anything
// in this set never leaves it (mirrors lib/run-registry.sh's own terminal
// set, one layer up): queued/starting/running/waiting_approval/blocked are
// the only states a command or a local-state remap may still move out of.
const REMOTE_TERMINAL: Record<string, true> = {
  finished: true, verified: true, failed: true, cancelled: true, lost: true, timed_out: true,
};

// Used only until the Mac's first sync carries a real task_config (fresh
// deploy, or a publisher that predates HERDR_MCP_TASKS) -- mirrors
// remote-mcp/task-allowlist.json's own caps so a cold-started Worker still
// enforces something sane rather than nothing.
const DEFAULT_TASK_CAPS = { max_concurrent: 4, max_per_day: 40, max_minutes: 60 };

export interface RemoteTaskRecord {
  remote_task_id: string;
  requester: string;
  mode: string;
  repo: string;
  objective: string;
  state: string;
  created_at: string;
  updated_at: string;
  local_task_id: string | null;
  local_run_id: string | null;
  branch: string | null;
  pane_id: string | null;
  agent_id: string | null;
  parent_remote_task_id: string | null;
  capability_probe: Record<string, boolean>;
}

export type StartTaskOutcome = { ok: true; remote_task_id: string; state: "queued" } | { ok: false; reason: string };
export type CancelTaskOutcome = { ok: true; state: string } | { ok: false; reason: string };
export type ResumeTaskOutcome =
  | { ok: true; remote_task_id: string; parent_remote_task_id: string; state: "queued" }
  | { ok: false; reason: string };

export interface TaskEventRow {
  cursor: number;
  remote_task_id: string;
  type: string;
  at: string;
  // Typed `object`, not `Record<string, unknown>`: see CommandItem.payload's
  // comment in types.ts -- the latter breaks RPC Stubify discriminant
  // narrowing for every caller of listEvents/waitForEvents/taskEventLog.
  detail: object;
  // Envelope (HERDR-REPLAYABLE-EVENTS-PLAN.md Phase 1, "canonical event
  // envelope"): event_id is null for the Worker's own unkeyed lifecycle
  // events (recordTaskEvent), set for a producer-keyed event
  // (owner.reply_ready); subject is {kind,id} when one resource exists
  // (never parsed from `detail` -- a typed column, so authorization never
  // depends on parsing JSON).
  event_id: string | null;
  schema_version: number;
  source: string;
  subject: { kind: string; id: string } | null;
}

// list_events/wait_for_events' own page shape: replay_floor_cursor,
// latest_cursor, scanned_through_cursor and a typed gap/scope result,
// never inferred from MIN(cursor) or from the last VISIBLE row's cursor
// (plan section 5) -- scanned_through_cursor is the last RAW row examined,
// so a page containing only unauthorized/filtered rows still advances.
export interface EventPage {
  events: TaskEventRow[];
  scanned_through_cursor: number;
  latest_cursor: number;
  replay_floor_cursor: number;
  scope_hash: string;
  result: "ok" | "cursor_pruned" | "cursor_scope_mismatch";
}

export interface ConsumerPosition {
  result: "ok" | "event_consumers_disabled" | "insufficient_scope" | "invalid_arguments"
    | "consumer_not_found" | "cursor_scope_mismatch" | "cursor_pruned"
    | "committed_cursor_mismatch" | "lease_epoch_mismatch" | "cursor_backwards" | "cursor_past_latest"
    | "consumer_limit_reached";
  consumer_id?: string;
  committed_cursor?: number;
  lease_epoch?: number;
  authorization_scope_hash?: string;
  current_authorization_scope_hash?: string;
  scope_hash?: string;
  updated_at?: string;
  last_error?: string | null;
  failure_count?: number;
  latest_cursor?: number;
  replay_floor_cursor?: number;
}

type ConsumerRow = {
  committed_cursor: number;
  lease_epoch: number;
  authorization_scope_hash: string;
  updated_at: number;
  last_error: string | null;
  failure_count: number;
};

// A started remote task's own (actor, client_id), the way pendingSenders()
// reports it for messages -- but tagged with the SCOPE the sender needed to
// queue it, so grantGate (index.ts) can check the right scope per mode
// instead of one hardcoded scope for every queue.
export interface ScopedSender extends Sender {
  scope: string;
}


const LEASE_MS = 90_000;
const MESSAGE_TTL_MS = 15 * 60_000;
const NONCE_TTL_MS = 15 * 60_000;
// Each publisher tick (~15s) that leases a message counts one attempt; a
// permission prompt or a typing human makes it retry, so 40 covers the TTL.
const MAX_ATTEMPTS = 40;
// ZR1 (ZERO-REVIEW-213-01 item 1): how many times sync() re-queues a cancel
// command after the Mac reports the PREVIOUS one failed, before giving up
// and leaving a single cancel_stuck event instead of an unbounded flood --
// same shape, same cap, as registry-bridge.sh's own CANCEL_STUCK_THRESHOLD.
const CANCEL_RETRY_CAP = 5;
// Pre-send approval prompts retry on later ticks. Already-typed notices
// wait for a reply/expiry instead: re-leasing would type them twice.
const APPROVAL_RETRY_CAP = 10;
const AUDIT_KEEP_MS = 180 * 86_400_000;
// Every tool call by one client (allowed or refused) counts. A ChatGPT session
// makes a handful of calls per turn; these only bite a loop or a leaked token.
const CALLS_PER_MINUTE = 60;
const CALLS_PER_DAY = 2000;

const iso = (ms: number) => new Date(ms).toISOString();

// A caller-bound opaque token for list_events/wait_for_events' cursor
// contract (plan section 5, "a cursor is bound to a stable authorization/
// filter scope hash"). FNV-1a, not crypto.subtle: sync() and listEvents()
// are deliberately synchronous (no awaits between a SELECT and the UPDATE/
// INSERT it gates, which is what makes the owner-reply acceptance
// transaction atomic without an explicit DO transaction -- see sync()).
// Not security-sensitive: it only needs to change when (email, client_id)
// changes, not to resist a determined attacker who already holds a token
// scoped to that identity.
function scopeHash(caller: { email: string; client_id: string }): string {
  let h = 0x811c9dc5;
  const s = `${caller.email}\n${caller.client_id}`;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

// Namespaces an event_id by producer and tenant/owner scope (plan section
// 1: "event_id is namespaced by tenant and producer... D1 enforces
// uniqueness on (tenant_id, event_id)"). This deployment has no separate
// multi-tenant/account concept (one DO, one operator) -- the owner
// exchange's own (sender_actor, sender_client) pair IS the tenant/owner
// scope boundary here, the same pair listEvents already gates
// owner_private visibility on, so reusing scopeHash for it costs nothing
// new and stays short/non-PII (no raw email baked into a value that can
// end up in a log line). producer is "srv" for every Worker-owned event in
// this MVP (owner-reply acceptance is the only keyed producer); "pub" is
// reserved for a future Mac-local-source producer (Phase 2) so the two
// axes can never collide even if a subject_id were ever reused across them.
// Exported (not just used internally) so a test can construct the exact
// production id shape directly and prove two different tenants never
// collide under the same subject_id, without duplicating the hash here.
export function namespacedEventId(producer: "srv" | "pub", tenant: { email: string; client_id: string },
    type: string, subjectId: string, suffix: string): string {
  return `${producer}:${scopeHash(tenant)}:${type}:${subjectId}:${suffix}`;
}

// Maps a local registry task's own state (synced each tick in
// snapshot.tasks, whose vocabulary is lib/run-registry.sh's lifecycle) onto
// the richer set a remote-task client is shown (SPEC). "blocked" splits
// into waiting_approval (a LIVE permission prompt -- snapshot.blockers
// carries kind:"permission" for exactly that) vs plain blocked (something
// else, e.g. stalled) -- the registry itself has only one state for both.
function mapLocalState(t: Pick<TaskRow, "state" | "verified">, livePermission: boolean): string {
  switch (t.state) {
    case "completed": return t.verified ? "verified" : "finished";
    case "cancelled": return "cancelled";
    case "failed": case "lost": return "failed";
    case "blocked": return livePermission ? "waiting_approval" : "blocked";
    case "starting": return "starting";
    default: return "running";
  }
}

export class HerdrState extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)`);
    // Pre-tasks-feature shape was PRIMARY KEY(task_id): one row per task,
    // always .handoffs/PROOF.md. Migrated here (not a fresh CREATE, since a
    // deployed DO already holds live PROOF.md rows) to PRIMARY KEY(task_id,
    // source) so a remote task can carry several named documents
    // (ANSWER.md, other .handoffs/* artifacts, the omp transcript) the way
    // get_task_result's `path` argument expects. Detected from sqlite_master's
    // own DDL text, not a flag, so a half-applied retry is still idempotent.
    const resultsDDL = this.sql.exec<{ sql: string }>(`SELECT sql FROM sqlite_master WHERE type='table' AND name='results'`).toArray()[0];
    if (resultsDDL && !resultsDDL.sql.includes("PRIMARY KEY (task_id, source)")) {
      this.sql.exec(`ALTER TABLE results RENAME TO results_v1`);
      this.sql.exec(`CREATE TABLE results (task_id TEXT NOT NULL, source TEXT NOT NULL, text TEXT NOT NULL,
        sha256 TEXT NOT NULL, source_mtime TEXT, truncated_at_source INTEGER NOT NULL, synced_at INTEGER NOT NULL,
        PRIMARY KEY (task_id, source))`);
      this.sql.exec(`INSERT INTO results SELECT task_id, source, text, sha256, source_mtime, truncated_at_source, synced_at FROM results_v1`);
      this.sql.exec(`DROP TABLE results_v1`);
    }
    this.sql.exec(`CREATE TABLE IF NOT EXISTS results (task_id TEXT NOT NULL, source TEXT NOT NULL, text TEXT NOT NULL,
      sha256 TEXT NOT NULL, source_mtime TEXT, truncated_at_source INTEGER NOT NULL, synced_at INTEGER NOT NULL,
      PRIMARY KEY (task_id, source))`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS messages (message_id TEXT PRIMARY KEY, created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, actor TEXT NOT NULL, client_id TEXT NOT NULL,
      client_name TEXT NOT NULL, task_id TEXT NOT NULL, pane_id TEXT NOT NULL, agent_id TEXT NOT NULL, label TEXT NOT NULL,
      text TEXT NOT NULL, status TEXT NOT NULL, detail TEXT NOT NULL, attempts INTEGER NOT NULL, lease_until INTEGER NOT NULL)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS messages_by_status ON messages(status, created_at)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS audit (seq INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
      actor TEXT NOT NULL, client_id TEXT NOT NULL, tool TEXT NOT NULL, target TEXT NOT NULL, decision TEXT NOT NULL,
      reason TEXT NOT NULL, message_id TEXT NOT NULL, detail TEXT NOT NULL)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS audit_by_client ON audit(client_id, actor, at)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS nonces (nonce TEXT PRIMARY KEY, seen_at INTEGER NOT NULL)`);
    // start_task/cancel_task/resume_task's own correlation row -- the local
    // task, once spawned, is a perfectly normal registry task synced through
    // the EXISTING snapshot.tasks array; this table only carries what that
    // array cannot: the requester, the sanitized objective, and the mapping
    // from the client's remote_task_id to the Mac's local_task_id.
    this.sql.exec(`CREATE TABLE IF NOT EXISTS remote_tasks (remote_task_id TEXT PRIMARY KEY,
      requester_email TEXT NOT NULL, requester_client TEXT NOT NULL, requester_client_name TEXT NOT NULL DEFAULT '',
      mode TEXT NOT NULL, repo TEXT NOT NULL, objective TEXT NOT NULL,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      local_task_id TEXT NOT NULL DEFAULT '', local_run_id TEXT NOT NULL DEFAULT '', branch TEXT NOT NULL DEFAULT '',
      pane_id TEXT NOT NULL DEFAULT '', agent_id TEXT NOT NULL DEFAULT '',
      state TEXT NOT NULL DEFAULT 'queued', parent_remote_task_id TEXT NOT NULL DEFAULT '',
      capability_probe TEXT NOT NULL DEFAULT '{}')`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS remote_tasks_by_local ON remote_tasks(local_task_id) WHERE local_task_id<>''`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS remote_tasks_by_state ON remote_tasks(state, created_at)`);
    // Worker -> Mac directives, leased exactly like the message outbox
    // (status queued -> delivering -> done; lease_until/attempts/expires_at
    // the same shape, same 15-minute TTL -- a Mac that never acks one gives
    // up the remote task rather than holding it open forever).
    this.sql.exec(`CREATE TABLE IF NOT EXISTS commands (command_id TEXT PRIMARY KEY, op TEXT NOT NULL,
      remote_task_id TEXT NOT NULL, payload TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'queued', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL DEFAULT 0, lease_until INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0,
      outcome TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '')`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS commands_by_status ON commands(status, created_at)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS commands_by_remote_task ON commands(remote_task_id, op, status)`);
    // list_events/wait_for_events' own monotonic feed, one remote task's
    // lifecycle at a time (task_started, state_changed, approval_needed,
    // answer_ready, finished, verified, failed, cancelled, timed_out).
    this.sql.exec(`CREATE TABLE IF NOT EXISTS task_events (cursor INTEGER PRIMARY KEY AUTOINCREMENT,
      remote_task_id TEXT NOT NULL, type TEXT NOT NULL, at INTEGER NOT NULL, detail TEXT NOT NULL DEFAULT '{}')`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS task_events_by_task ON task_events(remote_task_id, cursor)`);
    // Replayable-events envelope (HERDR-REPLAYABLE-EVENTS-PLAN.md Phase 1):
    // event_id is the stable idempotency key a producer supplies (null for
    // the Worker's own unkeyed lifecycle events, which never need dedupe);
    // subject_kind/subject_id are the typed nullable join the plan asks for
    // (remote_task_id already serves that role for task events, so this is
    // only populated beyond it for non-task subjects like an owner
    // exchange); visibility/sender_actor/sender_client gate who may ever
    // read a private event back out (listEvents/waitForEvents), never the
    // publisher ingestion path -- this branch adds no channel through which
    // the publisher can set any of these, so it cannot forge a
    // Worker-owned event (OWNERSHIP.md). Detected via PRAGMA table_info,
    // same idempotent-retry shape as the `results` PRIMARY KEY migration
    // above; ADD COLUMN only, no rebuild needed.
    const teCols = this.sql.exec<{ name: string }>(`PRAGMA table_info(task_events)`).toArray().map((r) => r.name);
    if (!teCols.includes("event_id")) {
      this.sql.exec(`ALTER TABLE task_events ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1`);
      this.sql.exec(`ALTER TABLE task_events ADD COLUMN event_id TEXT`);
      this.sql.exec(`ALTER TABLE task_events ADD COLUMN source TEXT NOT NULL DEFAULT 'worker_internal'`);
      this.sql.exec(`ALTER TABLE task_events ADD COLUMN subject_kind TEXT NOT NULL DEFAULT ''`);
      this.sql.exec(`ALTER TABLE task_events ADD COLUMN subject_id TEXT NOT NULL DEFAULT ''`);
      this.sql.exec(`ALTER TABLE task_events ADD COLUMN visibility TEXT NOT NULL DEFAULT 'public'`);
      this.sql.exec(`ALTER TABLE task_events ADD COLUMN sender_actor TEXT NOT NULL DEFAULT ''`);
      this.sql.exec(`ALTER TABLE task_events ADD COLUMN sender_client TEXT NOT NULL DEFAULT ''`);
      this.sql.exec(`ALTER TABLE task_events ADD COLUMN correlation_id TEXT NOT NULL DEFAULT ''`);
      this.sql.exec(`UPDATE task_events SET subject_kind='remote_task', subject_id=remote_task_id, correlation_id=remote_task_id
        WHERE remote_task_id<>''`);
    }
    this.sql.exec(`CREATE UNIQUE INDEX IF NOT EXISTS task_events_event_id ON task_events(event_id) WHERE event_id IS NOT NULL`);
    // Same tenant boundary as owner_private events: exact sender actor/client.
    // A hash is a scope-change detector, never an authorization lookup key.
    // srv is the existing Worker producer namespace; no publisher API is added.
    this.sql.exec(`CREATE TABLE IF NOT EXISTS event_consumers (
      producer TEXT NOT NULL DEFAULT 'srv', sender_actor TEXT NOT NULL, sender_client TEXT NOT NULL,
      consumer_id TEXT NOT NULL, committed_cursor INTEGER NOT NULL DEFAULT 0 CHECK(committed_cursor >= 0),
      lease_epoch INTEGER NOT NULL DEFAULT 1 CHECK(lease_epoch >= 1),
      authorization_scope_hash TEXT NOT NULL, updated_at INTEGER NOT NULL,
      last_error TEXT, failure_count INTEGER NOT NULL DEFAULT 0 CHECK(failure_count >= 0),
      PRIMARY KEY(producer, sender_actor, sender_client, consumer_id))`);
    // send_owner_message's own queue, independent of `messages` (different
    // rate limit, different target shape -- a named owning session, never a
    // task's agent -- different ack vocabulary: delivered/blocked/replied,
    // no "refused"/"failed"/"expired"). UNIQUE(sender_actor, sender_client,
    // client_msg_id) is the dedupe key SPEC asks for: a repeat send with the
    // same client_msg_id must return the ORIGINAL exchange_id, never queue
    // twice. The reply_* columns are filled in once, by sendOwnerReply's own
    // validated sync() path -- never by the sender.
    this.sql.exec(`CREATE TABLE IF NOT EXISTS owner_messages (exchange_id TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
      sender_actor TEXT NOT NULL, sender_client TEXT NOT NULL, sender_client_name TEXT NOT NULL DEFAULT '',
      client_msg_id TEXT NOT NULL, owner_label TEXT NOT NULL, body TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'queued', detail TEXT NOT NULL DEFAULT '',
      attempts INTEGER NOT NULL DEFAULT 0, lease_until INTEGER NOT NULL DEFAULT 0, delivered_at INTEGER,
      reply_body TEXT NOT NULL DEFAULT '', reply_session TEXT NOT NULL DEFAULT '',
      reply_artifact_revision TEXT NOT NULL DEFAULT '', replied_at INTEGER)`);
    this.sql.exec(`CREATE UNIQUE INDEX IF NOT EXISTS owner_messages_dedupe
      ON owner_messages(sender_actor, sender_client, client_msg_id)`);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS owner_messages_by_status ON owner_messages(status, created_at)`);
  }

  private staleAfterS(): number {
    const n = Number(this.env.STALE_AFTER_S);
    return Number.isFinite(n) && n > 0 ? n : 90;
  }

  private audit(nowMs: number, row: Omit<AuditRow, "seq" | "at">): void {
    this.sql.exec(
      `INSERT INTO audit (at, actor, client_id, tool, target, decision, reason, message_id, detail) VALUES (?,?,?,?,?,?,?,?,?)`,
      nowMs, row.actor, row.client_id, row.tool, row.target.slice(0, 300), row.decision, row.reason.slice(0, 300),
      row.message_id, row.detail.slice(0, 500),
    );
  }

  // Parsed once per sync, not once per tool call (a snapshot can be ~2 MB).
  private cached: { lastMs: number; snapshot: Snapshot | null } | null = null;

  view(nowMs: number): View {
    const syncRow = this.sql.exec<{ v: string }>(`SELECT v FROM kv WHERE k='last_sync_ms'`).toArray()[0];
    const last = syncRow ? Number(syncRow.v) : null;
    if (last === null) return { snapshot: null, connection: connection(null, null, nowMs, this.staleAfterS()) };
    if (this.cached?.lastMs !== last) {
      const snapRow = this.sql.exec<{ v: string }>(`SELECT v FROM kv WHERE k='snapshot'`).toArray()[0];
      this.cached = { lastMs: last, snapshot: snapRow ? (JSON.parse(snapRow.v) as Snapshot) : null };
    }
    const conn = connection(this.cached.snapshot, last, nowMs, this.staleAfterS());
    this.noteConnectionTransition(nowMs, conn.state);
    return { snapshot: this.cached.snapshot, connection: conn };
  }

  // disconnected/reconnected (SPEC item 5) can only be OBSERVED, never
  // scheduled: a Worker has no background clock, only requests. Whichever
  // tool call happens to be the first to see the connection cross the
  // staleAfterS threshold (either direction) records the transition, once,
  // as a global event (remote_task_id '' -- it is not about any one task).
  private noteConnectionTransition(nowMs: number, state: string): void {
    const up = state === "connected" || state === "degraded" ? "up" : "down";
    const row = this.sql.exec<{ v: string }>(`SELECT v FROM kv WHERE k='conn_bucket'`).toArray()[0];
    if (row?.v === up) return;
    this.sql.exec(`INSERT OR REPLACE INTO kv (k, v) VALUES ('conn_bucket', ?)`, up);
    if (row) this.recordTaskEvent(nowMs, "", up === "up" ? "reconnected" : "disconnected", { state });
  }

  result(taskId: string, source = ".handoffs/PROOF.md"): (ResultDoc & { synced_at: string }) | null {
    const r = this.sql.exec<{ task_id: string; source: string; text: string; sha256: string; source_mtime: string | null;
      truncated_at_source: number; synced_at: number }>(`SELECT * FROM results WHERE task_id=? AND source=?`, taskId, source).toArray()[0];
    if (!r) return null;
    return { ...r, truncated_at_source: r.truncated_at_source === 1, synced_at: iso(r.synced_at) };
  }

  // Every document synced for one task -- get_task_answer's "artifacts"
  // listing (SPEC: ".handoffs/ files with size/sha256"). Includes every
  // source the Mac ever sent, including the "omp:transcript" pseudo-source
  // (not a real .handoffs/ file); callers that want only real files filter
  // on source.startsWith(".handoffs/") themselves.
  resultSources(taskId: string): { source: string; size: number; sha256: string; synced_at: string }[] {
    return this.sql.exec<{ source: string; size: number; sha256: string; synced_at: number }>(
      `SELECT source, length(text) AS size, sha256, synced_at FROM results WHERE task_id=? ORDER BY source`, taskId,
    ).toArray().map((r) => ({ ...r, synced_at: iso(r.synced_at) }));
  }

  // Bounds every client's call volume, and with it audit growth. Over the
  // limit, one "throttled" row is written per window and later calls in that
  // window are refused without a row, so a flood cannot grow storage.
  private throttled(nowMs: number, caller: Caller, tool: string): string | null {
    const count = (sinceMs: number) => this.sql.exec<{ n: number }>(
      `SELECT COUNT(*) AS n FROM audit WHERE client_id=? AND actor=? AND at > ?`, caller.client_id, caller.email, sinceMs,
    ).one().n;
    const window = count(nowMs - 60_000) >= CALLS_PER_MINUTE ? 60_000 : count(nowMs - 86_400_000) >= CALLS_PER_DAY ? 86_400_000 : 0;
    if (!window) return null;
    const reason = `rate_limited (${window === 60_000 ? `${CALLS_PER_MINUTE}/minute` : `${CALLS_PER_DAY}/day`})`;
    const noted = this.sql.exec(`SELECT 1 FROM audit WHERE client_id=? AND actor=? AND decision='throttled' AND at > ?`,
      caller.client_id, caller.email, nowMs - window).toArray().length > 0;
    if (!noted) {
      this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool, target: "", decision: "throttled", reason,
        message_id: "", detail: "" });
    }
    return reason;
  }

  // One audited decision per tool call: throttle first, then the scope verdict
  // the caller computed. Returns the refusal reason, or null when allowed.
  admitToolCall(nowMs: number, caller: Caller, tool: string, target: string, scopeRefusal: string | null): string | null {
    const limited = this.throttled(nowMs, caller, tool);
    if (limited) return limited;
    this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool, target,
      decision: scopeRefusal ? "refused" : "allowed", reason: scopeRefusal ?? "", message_id: "", detail: "" });
    return scopeRefusal;
  }

  // A call the MCP SDK refused before any handler ran (unknown tool, schema).
  recordRejectedCall(nowMs: number, caller: Caller, tool: string, target: string, reason: string): void {
    if (this.throttled(nowMs, caller, tool)) return;
    this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool, target, decision: "refused", reason,
      message_id: "", detail: "" });
  }

  sendMessage(nowMs: number, caller: Caller, scopes: string[], target: string, rawText: string): SendOutcome {
    const refuse = (reason: string, candidates?: string[]): SendOutcome => {
      this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "send_message", target,
        decision: "refused", reason, message_id: "", detail: `chars=${rawText.length}` });
      return candidates ? { ok: false, reason, candidates } : { ok: false, reason };
    };
    const limited = this.throttled(nowMs, caller, "send_message");
    if (limited) return { ok: false, reason: limited };
    if (this.env.MESSAGING_ENABLED !== "true") return refuse("messaging_disabled");
    if (!scopes.includes("herdr:message")) return refuse("missing_scope herdr:message");
    const { snapshot, connection: conn } = this.view(nowMs);
    if (!snapshot || conn.state === "disconnected" || conn.state === "never_connected") {
      return refuse(`not_connected (${conn.state})`);
    }
    const text = sanitizeMessage(rawText);
    if (!text.ok) return refuse(text.reason);
    const res = resolveTarget(snapshot, target);
    if (!res.ok) return refuse(res.reason, res.candidates);
    const recent = this.sql.exec<{ created_at: number }>(
      `SELECT created_at FROM messages WHERE actor=? AND created_at > ?`, caller.email, nowMs - 3_600_000,
    ).toArray().map((r) => r.created_at);
    const tooMany = rateLimited(recent, nowMs, this.messageLimits(nowMs));
    if (tooMany) return refuse(tooMany);

    const t = res.task;
    const id = `msg_${iso(nowMs).replace(/[-:.]/g, "").slice(0, 15)}Z_${crypto.randomUUID().slice(0, 8)}`;
    this.sql.exec(
      `INSERT INTO messages (message_id, created_at, updated_at, expires_at, actor, client_id, client_name, task_id,
        pane_id, agent_id, label, text, status, detail, attempts, lease_until) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'queued','',0,0)`,
      id, nowMs, nowMs, nowMs + MESSAGE_TTL_MS, caller.email, caller.client_id, caller.client_name.slice(0, 80),
      t.task_id, t.pane_id!, t.agent_id!, t.label, text.text,
    );
    this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "send_message", target,
      decision: "queued", reason: "", message_id: id, detail: `task=${t.task_id} chars=${text.text.length}` });
    return { ok: true, message: this.messageStatus(id, caller.email)! };
  }

  messageStatus(id: string, actor: string): MessageRecord | null {
    const m = this.sql.exec<{ message_id: string; created_at: number; updated_at: number; expires_at: number; status: string;
      detail: string; attempts: number; task_id: string; label: string; agent_id: string; text: string }>(
      `SELECT * FROM messages WHERE message_id=? AND actor=?`, id, actor,
    ).toArray()[0];
    if (!m) return null;
    return {
      message_id: m.message_id, created_at: iso(m.created_at), updated_at: iso(m.updated_at), expires_at: iso(m.expires_at),
      status: m.status, detail: m.detail, attempts: m.attempts,
      target: { task_id: m.task_id, label: m.label, agent_id: m.agent_id }, text_chars: m.text.length,
    };
  }

  // Every sender with a message that could still be leased: the Worker checks
  // each one's OAuth grant before the sync that would hand the message out.
  pendingSenders(nowMs: number): Sender[] {
    return this.sql.exec<{ actor: string; client_id: string }>(
      `SELECT DISTINCT actor, client_id FROM messages WHERE status IN ('queued','delivering') AND expires_at > ?`, nowMs).toArray();
  }

  sendOwnerMessage(nowMs: number, caller: Caller, scopes: string[], ownerLabel: string, rawBody: string,
      clientMsgId: string): SendOwnerMessageOutcome {
    const refuse = (reason: string): SendOwnerMessageOutcome => {
      this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "send_owner_message", target: ownerLabel,
        decision: "refused", reason, message_id: "", detail: `chars=${rawBody.length}` });
      return { ok: false, reason };
    };
    const limited = this.throttled(nowMs, caller, "send_owner_message");
    if (limited) return { ok: false, reason: limited };
    if (this.env.OWNER_INBOX_ENABLED !== "true") return refuse("owner_inbox_disabled");
    if (!scopes.includes(SCOPE_OWNER_MESSAGE)) return refuse(`missing_scope ${SCOPE_OWNER_MESSAGE}`);
    if (!clientMsgId || clientMsgId.length > 200) return refuse("bad_client_msg_id");
    // Dedup BEFORE any other validation: a retried send with the same id
    // must return the ORIGINAL outcome even if, say, this retry's body
    // would itself fail to sanitize -- the caller is retrying, not asking
    // a new question (SPEC: "a repeat returns the original exchange_id
    // and state").
    const existing = this.sql.exec<{ exchange_id: string; status: string }>(
      `SELECT exchange_id, status FROM owner_messages WHERE sender_actor=? AND sender_client=? AND client_msg_id=?`,
      caller.email, caller.client_id, clientMsgId).toArray()[0];
    if (existing) return { ok: true, exchange_id: existing.exchange_id, state: existing.status };
    if (!OWNER_LABEL.test(ownerLabel)) return refuse("owner_label_invalid");
    const { snapshot, connection: conn } = this.view(nowMs);
    if (!snapshot || conn.state === "disconnected" || conn.state === "never_connected") {
      return refuse(`not_connected (${conn.state})`);
    }
    if (!(snapshot.owners ?? []).some((o) => o.label === ownerLabel)) return refuse("owner_not_registered");
    const text = sanitizeOwnerMessage(rawBody);
    if (!text.ok) return refuse(text.reason);
    const recent = this.sql.exec<{ created_at: number }>(
      `SELECT created_at FROM owner_messages WHERE sender_actor=? AND created_at > ?`, caller.email, nowMs - 3_600_000,
    ).toArray().map((r) => r.created_at);
    const tooMany = rateLimited(recent, nowMs, OWNER_LIMITS);
    if (tooMany) return refuse(tooMany);

    const id = `oex_${iso(nowMs).replace(/[-:.]/g, "").slice(0, 15)}Z_${crypto.randomUUID().slice(0, 8)}`;
    this.sql.exec(
      `INSERT INTO owner_messages (exchange_id, created_at, updated_at, expires_at, sender_actor, sender_client,
        sender_client_name, client_msg_id, owner_label, body, status, detail, attempts, lease_until)
       VALUES (?,?,?,?,?,?,?,?,?,?,'queued','',0,0)`,
      id, nowMs, nowMs, nowMs + MESSAGE_TTL_MS, caller.email, caller.client_id, caller.client_name.slice(0, 80),
      clientMsgId, ownerLabel, text.text,
    );
    this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "send_owner_message", target: ownerLabel,
      decision: "queued", reason: "", message_id: id, detail: `chars=${text.text.length}` });
    return { ok: true, exchange_id: id, state: "queued" };
  }

  ownerMessageStatus(exchangeId: string, actor: string): OwnerMessageRecord | null {
    const m = this.sql.exec<{ exchange_id: string; created_at: number; updated_at: number; status: string; detail: string;
      attempts: number; owner_label: string; delivered_at: number | null; body: string }>(
      `SELECT exchange_id, created_at, updated_at, status, detail, attempts, owner_label, delivered_at, body
       FROM owner_messages WHERE exchange_id=? AND sender_actor=?`, exchangeId, actor,
    ).toArray()[0];
    if (!m) return null;
    return {
      exchange_id: m.exchange_id, created_at: iso(m.created_at), updated_at: iso(m.updated_at),
      status: m.status, detail: m.detail, attempts: m.attempts, owner_label: m.owner_label,
      delivered_at: m.delivered_at === null ? null : iso(m.delivered_at), body_chars: m.body.length,
    };
  }

  // Only the ORIGINAL sender may read a reply (SPEC item 4). A non-sender
  // (or a wrong exchange_id) gets the identical null -- never a distinct
  // "forbidden" that would confirm the exchange_id exists to someone else.
  ownerReply(exchangeId: string, actor: string): OwnerReplyRecord | null {
    const m = this.sql.exec<{ owner_label: string; status: string; reply_body: string; reply_session: string;
      reply_artifact_revision: string; replied_at: number | null }>(
      `SELECT owner_label, status, reply_body, reply_session, reply_artifact_revision, replied_at
       FROM owner_messages WHERE exchange_id=? AND sender_actor=?`, exchangeId, actor,
    ).toArray()[0];
    if (!m || m.status !== "replied" || m.replied_at === null) return null;
    return {
      exchange_id: exchangeId, owner_label: m.owner_label, session: m.reply_session,
      responded_at: iso(m.replied_at), artifact_revision: m.reply_artifact_revision, body: m.reply_body,
    };
  }

  // Re-check grants for pending delivery AND confirmed deliveries awaiting
  // a reply. The reply path must not extend access after grant revocation.
  pendingOwnerSenders(nowMs: number): Sender[] {
    return this.sql.exec<{ actor: string; client_id: string }>(
      `SELECT DISTINCT sender_actor AS actor, sender_client AS client_id FROM owner_messages
       WHERE status='delivered' OR (status IN ('queued','delivering') AND expires_at > ?)`, nowMs).toArray();
  }

  // Caps in force this tick: the Mac's own pushed config when we have one
  // synced, else the conservative built-in default (cold start only).
  private taskCaps(nowMs: number): TaskCaps {
    return this.view(nowMs).snapshot?.task_config?.caps ?? DEFAULT_TASK_CAPS;
  }

  // Immutable-duplicate check (plan section 1): a null eventId (every
  // existing internal lifecycle call site, via recordTaskEvent below)
  // always inserts -- those events were never retried input, only the
  // Worker's own one-shot state transitions. A non-null eventId is the
  // stable transition id a producer supplies; a second insert attempt
  // under the SAME id is compared field-for-field (not hashed -- sync()
  // has no await between the SELECT and the owner_messages UPDATE it
  // gates, which is what makes that acceptance atomic, so the comparator
  // here stays synchronous too) against what is already stored: an exact
  // match is "the same retried call, already durable" (duplicate_same_
  // payload, no second row); a mismatch is a hard integrity error
  // (rejected:duplicate_payload_mismatch, no second row either) -- never
  // silently coerced into one or the other.
  private insertEvent(nowMs: number, e: { eventId: string | null; remoteTaskId: string; type: string; source: string;
      subjectKind: string; subjectId: string; visibility: "public" | "owner_private"; senderActor: string;
      senderClient: string; correlationId: string; data: Record<string, unknown> }):
      { outcome: "accepted" | "duplicate_same_payload" | "rejected:duplicate_payload_mismatch"; cursor: number | null } {
    const dataJson = JSON.stringify(e.data).slice(0, 2000);
    if (e.eventId) {
      const existing = this.sql.exec<{ cursor: number; type: string; subject_kind: string; subject_id: string; detail: string }>(
        `SELECT cursor, type, subject_kind, subject_id, detail FROM task_events WHERE event_id=?`, e.eventId).toArray()[0];
      if (existing) {
        const same = existing.type === e.type && existing.subject_kind === e.subjectKind
          && existing.subject_id === e.subjectId && existing.detail === dataJson;
        return { outcome: same ? "duplicate_same_payload" : "rejected:duplicate_payload_mismatch", cursor: same ? existing.cursor : null };
      }
    }
    this.sql.exec(`INSERT INTO task_events (remote_task_id, type, at, detail, schema_version, event_id, source,
        subject_kind, subject_id, visibility, sender_actor, sender_client, correlation_id)
      VALUES (?,?,?,?,1,?,?,?,?,?,?,?,?)`,
      e.remoteTaskId, e.type, nowMs, dataJson, e.eventId, e.source, e.subjectKind, e.subjectId, e.visibility,
      e.senderActor, e.senderClient, e.correlationId);
    const cursor = this.sql.exec<{ c: number }>(`SELECT last_insert_rowid() AS c`).one().c;
    return { outcome: "accepted", cursor };
  }

  private recordTaskEvent(nowMs: number, remoteTaskId: string, type: string, detail: Record<string, unknown> = {}): void {
    this.insertEvent(nowMs, { eventId: null, remoteTaskId, type, source: "worker_internal",
      subjectKind: remoteTaskId ? "remote_task" : "", subjectId: remoteTaskId, visibility: "public",
      senderActor: "", senderClient: "", correlationId: remoteTaskId, data: detail });
  }

  startTask(nowMs: number, caller: Caller, scopes: string[], repo: string, mode: "research" | "implement", rawObjective: string): StartTaskOutcome {
    const refuse = (reason: string): StartTaskOutcome => {
      this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "start_task", target: `${mode}:${repo}`,
        decision: "refused", reason, message_id: "", detail: "" });
      return { ok: false, reason };
    };
    const limited = this.throttled(nowMs, caller, "start_task");
    if (limited) return { ok: false, reason: limited };
    const neededScope = mode === "research" ? SCOPE_TASK_START : mode === "implement" ? SCOPE_TASK_IMPLEMENT : null;
    if (!neededScope) return refuse("bad_mode (research|implement)");
    if (!scopes.includes(neededScope)) return refuse(`missing_scope ${neededScope}`);
    if (this.env.TASKS_ENABLED !== "true") return refuse("tasks_disabled");
    const { snapshot, connection: conn } = this.view(nowMs);
    const cfg = snapshot?.task_config ?? null;
    if (!cfg || !cfg.mac_enabled) return refuse("tasks_disabled_on_mac");
    if (conn.state === "disconnected" || conn.state === "never_connected") return refuse(`not_connected (${conn.state})`);
    if (!cfg.repos.includes(repo)) return refuse(`repo_not_allowed (${repo})`);
    const text = sanitizeObjective(rawObjective);
    if (!text.ok) return refuse(text.reason);
    const caps = cfg.caps;
    const concurrent = this.sql.exec<{ n: number }>(
      `SELECT COUNT(*) AS n FROM remote_tasks WHERE state NOT IN ('finished','verified','failed','cancelled','lost','timed_out')`).one().n;
    if (concurrent >= caps.max_concurrent) return refuse(`too_many_concurrent (max ${caps.max_concurrent})`);
    const today = this.sql.exec<{ n: number }>(
      `SELECT COUNT(*) AS n FROM remote_tasks WHERE created_at > ?`, nowMs - 86_400_000).one().n;
    if (today >= caps.max_per_day) return refuse(`too_many_today (max ${caps.max_per_day})`);

    const id = `rtask_${iso(nowMs).replace(/[-:.]/g, "").slice(0, 15)}Z_${crypto.randomUUID().slice(0, 8)}`;
    this.sql.exec(`INSERT INTO remote_tasks (remote_task_id, requester_email, requester_client, requester_client_name,
        mode, repo, objective, created_at, updated_at, state) VALUES (?,?,?,?,?,?,?,?,?,'queued')`,
      id, caller.email, caller.client_id, caller.client_name.slice(0, 80), mode, repo, text.text, nowMs, nowMs);
    this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
      `cmd_${crypto.randomUUID().slice(0, 12)}`, "start", id, JSON.stringify({ repo, mode, objective: text.text }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
    this.recordTaskEvent(nowMs, id, "task_started", { repo, mode, requester: caller.email });
    this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "start_task", target: `${mode}:${repo}`,
      decision: "queued", reason: "", message_id: "", detail: `remote_task_id=${id}` });
    return { ok: true, remote_task_id: id, state: "queued" };
  }

  cancelTask(nowMs: number, caller: Caller, scopes: string[], remoteTaskId: string): CancelTaskOutcome {
    const refuse = (reason: string): CancelTaskOutcome => {
      this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "cancel_task", target: remoteTaskId,
        decision: "refused", reason, message_id: "", detail: "" });
      return { ok: false, reason };
    };
    if (!scopes.includes(SCOPE_TASK_CANCEL)) return refuse(`missing_scope ${SCOPE_TASK_CANCEL}`);
    const row = this.sql.exec<{ state: string; local_task_id: string; requester_email: string; requester_client: string }>(
      `SELECT state, local_task_id, requester_email, requester_client FROM remote_tasks WHERE remote_task_id=?`, remoteTaskId).toArray()[0];
    if (!row) return refuse("not_found");
    // Consent text says "a task this connection started" -- the only
    // exception SPEC makes is the Mac-driven timeout cancel, which never
    // goes through this tool.
    if (row.requester_email !== caller.email || row.requester_client !== caller.client_id) return refuse("not_your_task");
    if (REMOTE_TERMINAL[row.state]) return refuse(`already_terminal (${row.state})`);
    if (row.state === "cancelling") return refuse("already_cancelling");
    const pendingStart = this.sql.exec<{ command_id: string }>(
      `SELECT command_id FROM commands WHERE remote_task_id=? AND op IN ('start','resume') AND status='queued'`,
      remoteTaskId).toArray()[0];
    if (!row.local_task_id && pendingStart) {
      // Still sitting in the Worker's queue, never leased to the Mac: safe
      // to cancel immediately and retire that command so a lease in flight
      // right now cannot still hand it over after this decision was made.
      this.sql.exec(`UPDATE remote_tasks SET state='cancelled', updated_at=? WHERE remote_task_id=?`, nowMs, remoteTaskId);
      this.sql.exec(`UPDATE commands SET status='done', outcome='refused', detail='cancelled before it was spawned', updated_at=?
        WHERE command_id=?`, nowMs, pendingStart.command_id);
      this.recordTaskEvent(nowMs, remoteTaskId, "cancelled", { by: caller.email });
      this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "cancel_task", target: remoteTaskId,
        decision: "allowed", reason: "", message_id: "", detail: "cancelled before spawn" });
      return { ok: true, state: "cancelled" };
    }
    // Either already spawned (local_task_id known), or its start/resume
    // command is already leased/delivering and the Mac's ack hasn't arrived
    // yet -- either way this cannot be declared cancelled outright (M6): if
    // the Mac's ack later reports accepted, the sync handler queues the real
    // cancel itself once it finally learns local_task_id, instead of
    // reviving this row to running.
    if (row.local_task_id) {
      this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
        `cmd_${crypto.randomUUID().slice(0, 12)}`, "cancel", remoteTaskId, JSON.stringify({ local_task_id: row.local_task_id }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
    }
    this.sql.exec(`UPDATE remote_tasks SET state='cancelling', updated_at=? WHERE remote_task_id=?`, nowMs, remoteTaskId);
    this.recordTaskEvent(nowMs, remoteTaskId, "cancel_requested", { by: caller.email });
    this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "cancel_task", target: remoteTaskId,
      decision: "allowed", reason: "", message_id: "", detail: row.local_task_id ? "cancel queued for the Mac" : "cancel queued; its start is still in flight" });
    return { ok: true, state: "cancelling" };
  }

  resumeTask(nowMs: number, caller: Caller, scopes: string[], remoteTaskId: string, rawText: string | undefined): ResumeTaskOutcome {
    const refuse = (reason: string): ResumeTaskOutcome => {
      this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "resume_task", target: remoteTaskId,
        decision: "refused", reason, message_id: "", detail: "" });
      return { ok: false, reason };
    };
    if (!scopes.includes(SCOPE_TASK_CANCEL)) return refuse(`missing_scope ${SCOPE_TASK_CANCEL}`);
    if (this.env.TASKS_ENABLED !== "true") return refuse("tasks_disabled");
    const row = this.sql.exec<{ state: string; mode: string; repo: string; local_task_id: string; local_run_id: string;
      branch: string; objective: string; requester_email: string; requester_client: string }>(
      `SELECT state, mode, repo, local_task_id, local_run_id, branch, objective, requester_email, requester_client
       FROM remote_tasks WHERE remote_task_id=?`, remoteTaskId).toArray()[0];
    if (!row) return refuse("not_found");
    // H1 GAP #1: resuming another client's task must not be possible, and
    // must not fall back to implement mode for a row this client never
    // consented to -- refuse before ever looking at mode or state.
    if (row.requester_email !== caller.email || row.requester_client !== caller.client_id) return refuse("not_your_task");
    if (!REMOTE_TERMINAL[row.state]) return refuse(`not_terminal (${row.state})`);
    if (!row.local_task_id) return refuse("never_started");
    const neededScope = row.mode === "research" ? SCOPE_TASK_START : row.mode === "implement" ? SCOPE_TASK_IMPLEMENT : null;
    if (!neededScope) return refuse(`bad_mode (${row.mode})`);
    if (!scopes.includes(neededScope)) return refuse(`missing_scope ${neededScope}`);
    const { snapshot, connection: conn } = this.view(nowMs);
    const cfg = snapshot?.task_config ?? null;
    if (!cfg || !cfg.mac_enabled) return refuse("tasks_disabled_on_mac");
    if (conn.state === "disconnected" || conn.state === "never_connected") return refuse(`not_connected (${conn.state})`);
    if (!cfg.repos.includes(row.repo)) return refuse(`repo_not_allowed (${row.repo})`);
    const caps = cfg.caps;
    const concurrent = this.sql.exec<{ n: number }>(
      `SELECT COUNT(*) AS n FROM remote_tasks WHERE state NOT IN ('finished','verified','failed','cancelled','lost','timed_out')`).one().n;
    if (concurrent >= caps.max_concurrent) return refuse(`too_many_concurrent (max ${caps.max_concurrent})`);
    const today = this.sql.exec<{ n: number }>(
      `SELECT COUNT(*) AS n FROM remote_tasks WHERE created_at > ?`, nowMs - 86_400_000).one().n;
    if (today >= caps.max_per_day) return refuse(`too_many_today (max ${caps.max_per_day})`);
    let text = "";
    if (rawText) {
      const cleaned = sanitizeObjective(rawText);
      if (!cleaned.ok) return refuse(cleaned.reason);
      text = cleaned.text;
    }
    const newId = `rtask_${iso(nowMs).replace(/[-:.]/g, "").slice(0, 15)}Z_${crypto.randomUUID().slice(0, 8)}`;
    this.sql.exec(`INSERT INTO remote_tasks (remote_task_id, requester_email, requester_client, requester_client_name,
        mode, repo, objective, created_at, updated_at, state, parent_remote_task_id)
        VALUES (?,?,?,?,?,?,?,?,?,'queued',?)`,
      newId, caller.email, caller.client_id, caller.client_name.slice(0, 80), row.mode, row.repo, row.objective, nowMs, nowMs, remoteTaskId);
    this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
      `cmd_${crypto.randomUUID().slice(0, 12)}`, "resume", newId,
      JSON.stringify({ local_task_id: row.local_task_id, local_run_id: row.local_run_id, branch: row.branch, repo: row.repo, mode: row.mode, text }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
    this.recordTaskEvent(nowMs, newId, "task_started", { resumed_from: remoteTaskId, requester: caller.email });
    this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "resume_task", target: remoteTaskId,
      decision: "queued", reason: "", message_id: "", detail: `remote_task_id=${newId}` });
    return { ok: true, remote_task_id: newId, parent_remote_task_id: remoteTaskId, state: "queued" };
  }

  // follow_up resolves to this, then reuses sendMessage verbatim (same
  // scope check, same rate limit, same envelope) -- SPEC: "= send_message to
  // that task". null when the remote task has never actually been spawned
  // (no live pane to target yet).
  remoteTaskLocalId(remoteTaskId: string): string | null {
    const r = this.sql.exec<{ local_task_id: string }>(`SELECT local_task_id FROM remote_tasks WHERE remote_task_id=?`, remoteTaskId).toArray()[0];
    return r && r.local_task_id ? r.local_task_id : null;
  }

  remoteTask(remoteTaskId: string): RemoteTaskRecord | null {
    const r = this.sql.exec<{ remote_task_id: string; requester_email: string; mode: string; repo: string; objective: string;
      state: string; created_at: number; updated_at: number; local_task_id: string; local_run_id: string; branch: string;
      pane_id: string; agent_id: string; parent_remote_task_id: string; capability_probe: string }>(
      `SELECT * FROM remote_tasks WHERE remote_task_id=?`, remoteTaskId).toArray()[0];
    if (!r) return null;
    return {
      remote_task_id: r.remote_task_id, requester: r.requester_email, mode: r.mode, repo: r.repo, objective: r.objective,
      state: r.state, created_at: iso(r.created_at), updated_at: iso(r.updated_at),
      local_task_id: r.local_task_id || null, local_run_id: r.local_run_id || null, branch: r.branch || null,
      pane_id: r.pane_id || null, agent_id: r.agent_id || null, parent_remote_task_id: r.parent_remote_task_id || null,
      capability_probe: JSON.parse(r.capability_probe || "{}") as Record<string, boolean>,
    };
  }

  // Every sender with a QUEUED start OR resume command that could still be
  // leased -- the Worker re-checks the ORIGINAL caller's grant before
  // handing either to the Mac, same reasoning as pendingSenders() for
  // messages (SPEC: revoking a connection "must stop that connection's
  // tasks from being started"). Tagged with the scope that mode needed,
  // since research and implement are different scopes.
  pendingCommandSenders(nowMs: number): ScopedSender[] {
    return this.sql.exec<{ actor: string; client_id: string; mode: string }>(
      `SELECT DISTINCT rt.requester_email AS actor, rt.requester_client AS client_id, rt.mode AS mode
       FROM remote_tasks rt JOIN commands c ON c.remote_task_id = rt.remote_task_id
       WHERE c.op IN ('start','resume') AND c.status='queued' AND c.expires_at > ?`, nowMs).toArray()
      .map((r) => ({ actor: r.actor, client_id: r.client_id, scope: r.mode === "research" ? SCOPE_TASK_START : SCOPE_TASK_IMPLEMENT }));
  }

  // Every sender with an ALREADY-RUNNING remote task (spawned, with a
  // local_task_id, not yet terminal or already cancelling) -- the pending-
  // command check above only ever sees a QUEUED start/resume; a task past
  // that point has no command for cmdGate to see without this (SPEC fix:
  // Zero's review item 4 -- "revoke stops in-flight tasks too", not only
  // ones still waiting to be delivered).
  activeTaskSenders(): ScopedSender[] {
    return this.sql.exec<{ actor: string; client_id: string; mode: string }>(
      `SELECT DISTINCT requester_email AS actor, requester_client AS client_id, mode AS mode
       FROM remote_tasks WHERE local_task_id<>'' AND state IN ('running','starting','waiting_approval','blocked')`).toArray()
      .map((r) => ({ actor: r.actor, client_id: r.client_id, scope: r.mode === "research" ? SCOPE_TASK_START : SCOPE_TASK_IMPLEMENT }));
  }

  // get_task_answer's "progress" field: this one remote task's own recent
  // history, newest first (unlike listEvents' global ascending cursor feed).
  taskEventLog(remoteTaskId: string, limit: number): TaskEventRow[] {
    return this.sql.exec<{ cursor: number; remote_task_id: string; type: string; at: number; detail: string;
      event_id: string | null; schema_version: number; source: string; subject_kind: string; subject_id: string }>(
      `SELECT cursor, remote_task_id, type, at, detail, event_id, schema_version, source, subject_kind, subject_id
       FROM task_events WHERE remote_task_id=? ORDER BY cursor DESC LIMIT ?`,
      remoteTaskId, limit,
    ).toArray().map((r) => ({ cursor: r.cursor, remote_task_id: r.remote_task_id, type: r.type, at: iso(r.at),
      detail: JSON.parse(r.detail || "{}") as object, event_id: r.event_id, schema_version: r.schema_version,
      source: r.source, subject: r.subject_kind ? { kind: r.subject_kind, id: r.subject_id } : null }));
  }

  // Durable pruning bookkeeping (plan section 5): the highest cursor that
  // MAY have been deleted by sync()'s own non-prefix prune (terminal-task
  // events older than 30 days -- it can delete an old row for one task
  // while a much OLDER row for a still-active task survives, so MIN(cursor)
  // is never a safe floor). Monotonic: only ever raised, never lowered.
  private replayFloorCursor(): number {
    const row = this.sql.exec<{ v: string }>(`SELECT v FROM kv WHERE k='replay_floor_cursor'`).toArray()[0];
    return row ? Number(row.v) : 0;
  }

  private raiseReplayFloor(candidateMax: number | null): void {
    if (candidateMax === null || candidateMax <= this.replayFloorCursor()) return;
    this.sql.exec(`INSERT OR REPLACE INTO kv (k, v) VALUES ('replay_floor_cursor', ?)`, String(candidateMax));
  }

  // MAX(retained cursor) falls after pruning. SQLite's AUTOINCREMENT sequence
  // survives deletion, so the stream watermark never moves backwards.
  private latestEventCursor(): number {
    return this.sql.exec<{ seq: number }>(`SELECT seq FROM sqlite_sequence WHERE name='task_events'`).toArray()[0]?.seq ?? 0;
  }

  // Hash before the synchronous critical section: no await separates reading
  // the row/floor/watermark from the conditional UPDATE. Scope ordering and
  // duplicate scope strings are immaterial; identity and grant changes are not.
  private async consumerScopeHash(caller: Caller, scopes: string[]): Promise<string> {
    const input = JSON.stringify(["srv", caller.email, caller.client_id, [...new Set(scopes)].sort()]);
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
    return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
  }

  private consumerPosition(nowMs: number, caller: Caller, consumerId: string, hash: string,
      commit: { expected: number; cursor: number; epoch: number; rebaseScope?: string } | null): ConsumerPosition {
    return this.ctx.storage.transactionSync(() => {
      let row = this.sql.exec<ConsumerRow>(`SELECT committed_cursor, lease_epoch, authorization_scope_hash,
        updated_at, last_error, failure_count FROM event_consumers
        WHERE producer='srv' AND sender_actor=? AND sender_client=? AND consumer_id=?`,
        caller.email, caller.client_id, consumerId).toArray()[0];
      if (!row && commit) return { result: "consumer_not_found" };
      if (!row) {
        const count = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM event_consumers
          WHERE producer='srv' AND sender_actor=? AND sender_client=?`, caller.email, caller.client_id).one().n;
        if (count >= 32) return { result: "consumer_limit_reached" };
        this.sql.exec(`INSERT INTO event_consumers
          (sender_actor, sender_client, consumer_id, authorization_scope_hash, updated_at) VALUES (?,?,?,?,?)`,
          caller.email, caller.client_id, consumerId, hash, nowMs);
        row = { committed_cursor: 0, lease_epoch: 1, authorization_scope_hash: hash,
          updated_at: nowMs, last_error: null, failure_count: 0 };
      }
      const out: ConsumerPosition = {
        result: "ok", consumer_id: consumerId, committed_cursor: row.committed_cursor, lease_epoch: row.lease_epoch,
        authorization_scope_hash: row.authorization_scope_hash, scope_hash: scopeHash(caller),
        current_authorization_scope_hash: hash,
        updated_at: iso(row.updated_at), last_error: row.last_error, failure_count: row.failure_count,
        latest_cursor: this.latestEventCursor(), replay_floor_cursor: this.replayFloorCursor(),
      };
      const rebase = commit?.rebaseScope !== undefined;
      if (rebase && commit!.rebaseScope !== hash) return { ...out, result: "cursor_scope_mismatch" };
      if (!rebase && row.authorization_scope_hash !== hash) return { ...out, result: "cursor_scope_mismatch" };
      // Unlike ad-hoc list_events(since_cursor=0), a durable unread consumer
      // cannot treat zero as "everything retained" and silently miss a gap.
      if (!rebase && row.committed_cursor < out.replay_floor_cursor!) return { ...out, result: "cursor_pruned" };
      if (!commit) return out;
      if (row.lease_epoch !== commit.epoch) return { ...out, result: "lease_epoch_mismatch" };
      if (row.committed_cursor !== commit.expected) return { ...out, result: "committed_cursor_mismatch" };
      if (commit.cursor < row.committed_cursor) return { ...out, result: "cursor_backwards" };
      if (commit.cursor > out.latest_cursor!) return { ...out, result: "cursor_past_latest" };
      if (rebase && commit.cursor < out.replay_floor_cursor!) return { ...out, result: "cursor_pruned" };
      if (!rebase && commit.cursor === row.committed_cursor) return out;
      // Rebase is an explicit reconciliation assertion, not an ordinary ACK.
      // Fence workers holding the pre-reconciliation generation even if R=0.
      const epoch = row.lease_epoch + (rebase ? 1 : 0);
      const changed = this.sql.exec(`UPDATE event_consumers
        SET committed_cursor=?, updated_at=?, authorization_scope_hash=?, lease_epoch=?
        WHERE producer='srv' AND sender_actor=? AND sender_client=? AND consumer_id=?
          AND committed_cursor=? AND lease_epoch=? AND authorization_scope_hash=?`,
        commit.cursor, nowMs, hash, epoch, caller.email, caller.client_id, consumerId,
        commit.expected, commit.epoch, row.authorization_scope_hash).rowsWritten;
      if (changed !== 1) throw new Error("consumer conditional update lost inside transaction");
      if (rebase) this.audit(nowMs, { actor: caller.email, client_id: caller.client_id,
        tool: "rebase_consumer_position", target: consumerId, decision: "reconciled",
        reason: row.authorization_scope_hash !== hash ? "scope_rebound" : "checkpoint_rebased", message_id: "",
        detail: JSON.stringify({ from: row.committed_cursor, to: commit.cursor, epoch,
          previous_scope: row.authorization_scope_hash, current_scope: hash }) });
      return { ...out, result: "ok", committed_cursor: commit.cursor, updated_at: iso(nowMs),
        authorization_scope_hash: hash, lease_epoch: epoch };
    });
  }

  async getConsumerPosition(nowMs: number, caller: Caller, scopes: string[], consumerId: string): Promise<ConsumerPosition> {
    if (this.env.EVENT_CONSUMERS_ENABLED !== "true") return { result: "event_consumers_disabled" };
    if (!scopes.includes(SCOPE_READ)) return { result: "insufficient_scope" };
    if (!consumerId || consumerId.length > 200) return { result: "invalid_arguments" };
    const hash = await this.consumerScopeHash(caller, scopes);
    return this.consumerPosition(nowMs, caller, consumerId, hash, null);
  }

  async commitConsumerPosition(nowMs: number, caller: Caller, scopes: string[], consumerId: string,
      expectedCommittedCursor: number, newCursor: number, leaseEpoch: number): Promise<ConsumerPosition> {
    if (this.env.EVENT_CONSUMERS_ENABLED !== "true") return { result: "event_consumers_disabled" };
    if (!scopes.includes(SCOPE_READ)) return { result: "insufficient_scope" };
    if (!consumerId || consumerId.length > 200
        || ![expectedCommittedCursor, newCursor, leaseEpoch].every((n) => Number.isSafeInteger(n) && n >= 0)) {
      return { result: "invalid_arguments" };
    }
    const hash = await this.consumerScopeHash(caller, scopes);
    return this.consumerPosition(nowMs, caller, consumerId, hash,
      { expected: expectedCommittedCursor, cursor: newCursor, epoch: leaseEpoch });
  }

  async rebaseConsumerPosition(nowMs: number, caller: Caller, scopes: string[], consumerId: string,
      expectedCommittedCursor: number, resumeCursor: number, leaseEpoch: number,
      currentAuthorizationScopeHash: string, reconciled: boolean): Promise<ConsumerPosition> {
    if (this.env.EVENT_CONSUMERS_ENABLED !== "true") return { result: "event_consumers_disabled" };
    if (!scopes.includes(SCOPE_READ)) return { result: "insufficient_scope" };
    if (!consumerId || consumerId.length > 200 || reconciled !== true
        || !/^[0-9a-f]{64}$/.test(currentAuthorizationScopeHash)
        || ![expectedCommittedCursor, resumeCursor, leaseEpoch].every((n) => Number.isSafeInteger(n) && n >= 0)) {
      return { result: "invalid_arguments" };
    }
    const hash = await this.consumerScopeHash(caller, scopes);
    return this.consumerPosition(nowMs, caller, consumerId, hash,
      { expected: expectedCommittedCursor, cursor: resumeCursor, epoch: leaseEpoch, rebaseScope: currentAuthorizationScopeHash });
  }

  // The global feed, scope-bound (plan section 5 + section 7): sinceCursor
  // is rejected as cursor_pruned below the durable replay floor (never
  // trusted bare -- a stale cursor under a false "still complete" read
  // would silently drop events); sinceScopeHash (echoed back every call as
  // scope_hash) is rejected as cursor_scope_mismatch the instant the
  // caller's own authorization identity changes, so a cursor minted under
  // one identity can never be replayed as if it were another's. Owner-
  // private rows (owner.reply_ready) are filtered to the original sender
  // only (plan section 7: "owner exchange events are visible only ... to
  // the original sender/client"); scanned_through_cursor is the last RAW
  // row examined, not the last VISIBLE one, so a page of entirely filtered
  // rows still advances a watcher's pagination instead of looping or
  // silently truncating it (plan section 5, "filtered pagination advances
  // with scanned_through_cursor").
  listEvents(sinceCursor: number, sinceScopeHash: string | null, caller: Caller, limit: number): EventPage {
    const hash = scopeHash(caller);
    const latest = this.latestEventCursor();
    const floor = this.replayFloorCursor();
    if (sinceScopeHash && sinceScopeHash !== hash) {
      return { events: [], scanned_through_cursor: sinceCursor, latest_cursor: latest, replay_floor_cursor: floor,
        scope_hash: hash, result: "cursor_scope_mismatch" };
    }
    if (sinceCursor > 0 && sinceCursor < floor) {
      return { events: [], scanned_through_cursor: sinceCursor, latest_cursor: latest, replay_floor_cursor: floor,
        scope_hash: hash, result: "cursor_pruned" };
    }
    const rows = this.sql.exec<{ cursor: number; remote_task_id: string; type: string; at: number; detail: string;
      event_id: string | null; schema_version: number; source: string; subject_kind: string; subject_id: string;
      visibility: string; sender_actor: string; sender_client: string }>(
      `SELECT cursor, remote_task_id, type, at, detail, event_id, schema_version, source, subject_kind, subject_id,
         visibility, sender_actor, sender_client
       FROM task_events WHERE cursor > ? ORDER BY cursor LIMIT ?`, sinceCursor, limit,
    ).toArray();
    const visible = rows.filter((r) => r.visibility !== "owner_private"
      || (r.sender_actor === caller.email && r.sender_client === caller.client_id));
    return {
      events: visible.map((r) => ({ cursor: r.cursor, remote_task_id: r.remote_task_id, type: r.type, at: iso(r.at),
        detail: JSON.parse(r.detail || "{}") as object, event_id: r.event_id, schema_version: r.schema_version,
        source: r.source, subject: r.subject_kind ? { kind: r.subject_kind, id: r.subject_id } : null })),
      scanned_through_cursor: rows.length ? rows[rows.length - 1]!.cursor : sinceCursor,
      latest_cursor: latest, replay_floor_cursor: floor, scope_hash: hash, result: "ok",
    };
  }

  // Holds the request open until a new event lands or timeoutS elapses --
  // the "notification" a ChatGPT-style client can actually receive without
  // true server push (SPEC item 5). timeoutS is already clamped <= 25 by the
  // tool's own input schema before this is ever called. A pruned/scope-
  // mismatched page returns immediately (nothing to wait out); an ok page
  // with zero VISIBLE events still advances the poll cursor to
  // scanned_through_cursor, so a long run of another caller's filtered
  // owner events never makes this loop re-scan the same rows every 500ms.
  async waitForEvents(sinceCursor: number, sinceScopeHash: string | null, caller: Caller, timeoutS: number): Promise<EventPage> {
    const deadline = Date.now() + timeoutS * 1000;
    let cursor = sinceCursor;
    for (;;) {
      const out = this.listEvents(cursor, sinceScopeHash, caller, 200);
      if (out.result !== "ok" || out.events.length > 0 || Date.now() >= deadline) return out;
      cursor = out.scanned_through_cursor;
      const { promise, resolve } = Promise.withResolvers<void>();
      setTimeout(resolve, 500);
      await promise;
    }
  }


  // One table for every HMAC-signed request (sync and admin): a nonce is used once.
  private takeNonce(nowMs: number, nonce: string): boolean {
    this.sql.exec(`DELETE FROM nonces WHERE seen_at < ?`, nowMs - NONCE_TTL_MS);
    if (this.sql.exec(`SELECT 1 FROM nonces WHERE nonce=?`, nonce).toArray().length) return false;
    this.sql.exec(`INSERT INTO nonces (nonce, seen_at) VALUES (?, ?)`, nonce, nowMs);
    return true;
  }

  // Mac-side grant administration (scripts/grants.py): consume the nonce and
  // audit the action before the Worker performs it.
  admitAdmin(nowMs: number, nonce: string, op: string, target: string): boolean {
    if (!this.takeNonce(nowMs, nonce)) return false;
    this.audit(nowMs, { actor: "mac-admin", client_id: "", tool: `admin_${op}`, target, decision: "allowed", reason: "signed", message_id: "", detail: "" });
    return true;
  }

  // The limits in force now: the override if one is set and not expired,
  // else the defaults. An expired override simply stops applying.
  messageLimits(nowMs: number): MessageLimits {
    const row = this.sql.exec<{ v: string }>(`SELECT v FROM kv WHERE k='msg_limits'`).toArray()[0];
    if (row) {
      const o = JSON.parse(row.v) as { per_minute: number; per_hour: number; until_ms: number | null; reason: string };
      if (o.until_ms === null || o.until_ms > nowMs) {
        return { per_minute: o.per_minute, per_hour: o.per_hour, source: "override",
          until: o.until_ms === null ? null : iso(o.until_ms), reason: o.reason };
      }
    }
    return { ...DEFAULT_LIMITS, source: "default", until: null, reason: "" };
  }

  // Called only by /admin/limits after admitAdmin; bounds are checked there.
  setMessageLimits(nowMs: number, o: { per_minute: number; per_hour: number; until_ms: number | null; reason: string } | null): MessageLimits {
    if (o === null) this.sql.exec(`DELETE FROM kv WHERE k='msg_limits'`);
    else this.sql.exec(`INSERT OR REPLACE INTO kv (k, v) VALUES ('msg_limits', ?)`, JSON.stringify(o));
    return this.messageLimits(nowMs);
  }

  // Messages this user queued in the last minute / hour (for get_status).
  messagesUsed(nowMs: number, actor: string): { last_minute: number; last_hour: number } {
    const recent = this.sql.exec<{ created_at: number }>(
      `SELECT created_at FROM messages WHERE actor=? AND created_at > ?`, actor, nowMs - 3_600_000).toArray();
    return { last_minute: recent.filter((r) => nowMs - r.created_at < 60_000).length, last_hour: recent.length };
  }

  // Publisher sync: store the snapshot, apply delivery/command acks, re-check
  // every undelivered message and queued command against today's policy,
  // enforce task deadlines, remap local task state onto the richer remote
  // vocabulary, expire, lease the outbox and the command queue, and hand
  // back new audit rows for the Mac's local copy.
  sync(nowMs: number, nonce: string, rawBody: string, gate: DeliveryGate, cmdGate: DeliveryGate, ownerGate: DeliveryGate): SyncOutcome {
    if (!this.takeNonce(nowMs, nonce)) return { ok: false, status: 409, reason: "replayed_nonce" };
    let json: unknown;
    try { json = JSON.parse(rawBody); } catch { return { ok: false, status: 400, reason: "bad_json" }; }
    const parsed = SyncSchema.safeParse(json);
    if (!parsed.success) return { ok: false, status: 400, reason: `bad_shape: ${parsed.error.issues[0]?.path.join(".")}` };
    const body = parsed.data;

    this.sql.exec(`INSERT OR REPLACE INTO kv (k, v) VALUES ('snapshot', ?)`, JSON.stringify(body.snapshot));
    this.sql.exec(`INSERT OR REPLACE INTO kv (k, v) VALUES ('last_sync_ms', ?)`, String(nowMs));
    this.cached = { lastMs: nowMs, snapshot: body.snapshot };
    for (const r of body.results) {
      this.sql.exec(`INSERT OR REPLACE INTO results (task_id, source, text, sha256, source_mtime, truncated_at_source, synced_at)
        VALUES (?,?,?,?,?,?,?)`, r.task_id, r.source, r.text, r.sha256, r.source_mtime, r.truncated_at_source ? 1 : 0, nowMs);
    }

    const sys = { actor: "publisher", client_id: "", tool: "delivery" };
    for (const a of body.acks) {
      const m = this.sql.exec<{ status: string; target: string }>(
        `SELECT status, task_id AS target FROM messages WHERE message_id=?`, a.message_id).toArray()[0];
      if (!m || m.status !== "delivering") continue;
      const status = a.outcome === "retry" ? "queued" : a.outcome;
      this.sql.exec(`UPDATE messages SET status=?, detail=?, updated_at=?, lease_until=0 WHERE message_id=?`,
        status, a.detail.slice(0, 300), nowMs, a.message_id);
      this.audit(nowMs, { ...sys, target: m.target, decision: a.outcome === "refused" ? "refused_at_delivery" : a.outcome,
        reason: a.detail, message_id: a.message_id, detail: "" });
    }

    // start_task/cancel_task/resume_task's own acks: the Mac tells us what a
    // leased command actually did (spawned / refused / failed), which is how
    // a remote_tasks row first learns its local_task_id and pane.
    for (const a of body.command_acks ?? []) {
      const c = this.sql.exec<{ status: string; op: CommandOp; remote_task_id: string }>(
        `SELECT status, op, remote_task_id FROM commands WHERE command_id=?`, a.command_id).toArray()[0];
      if (!c || c.status !== "delivering") continue;
      this.sql.exec(`UPDATE commands SET status='done', outcome=?, detail=?, updated_at=? WHERE command_id=?`,
        a.outcome, a.detail.slice(0, 300), nowMs, a.command_id);
      this.audit(nowMs, { ...sys, target: c.remote_task_id, decision: a.outcome === "accepted" ? "allowed" : "refused_at_delivery",
        reason: a.detail, message_id: "", detail: c.op });
      if (a.outcome === "accepted" && (c.op === "start" || c.op === "resume")) {
        const cur = this.sql.exec<{ state: string }>(`SELECT state FROM remote_tasks WHERE remote_task_id=?`, c.remote_task_id).toArray()[0];
        if (cur?.state === "cancelling") {
          // A cancel raced ahead of this ack (M6/R4): the task DID spawn, so
          // stamp its identity -- the Mac needs local_task_id to actually
          // close the pane -- but never revive a cancelling row to running;
          // queue the real cancel now that local_task_id is finally known
          // (any cancel queued earlier, before it was known, is a no-op on
          // the Mac and is superseded by this one).
          this.sql.exec(`UPDATE remote_tasks SET local_task_id=?, local_run_id=?, branch=?, pane_id=?, agent_id=?,
              capability_probe=?, updated_at=? WHERE remote_task_id=?`,
            a.local_task_id ?? "", a.local_run_id ?? "", a.branch ?? "", a.pane_id ?? "", a.agent_id ?? "",
            JSON.stringify(a.capability_probe ?? {}), nowMs, c.remote_task_id);
          if (a.local_task_id) {
            this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
              `cmd_${crypto.randomUUID().slice(0, 12)}`, "cancel", c.remote_task_id,
              JSON.stringify({ local_task_id: a.local_task_id }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
          }
          this.recordTaskEvent(nowMs, c.remote_task_id, "cancel_requested", { reason: "cancelled while the start was still in flight" });
        } else if (cur && REMOTE_TERMINAL[cur.state]) {
          // Already terminal some other way (e.g. its lease expired and was
          // marked failed before this late ack arrived, or a revoke
          // cancelled it before delivery while the Mac was mid-spawn):
          // never revive it, but if the ack proves the Mac actually
          // spawned an agent, that agent is still running with nothing
          // tracking it unless a cancel reaches it (N3).
          this.recordTaskEvent(nowMs, c.remote_task_id, "late_ack_ignored", { outcome: a.outcome, already: cur.state });
          if (a.local_task_id) {
            this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
              `cmd_${crypto.randomUUID().slice(0, 12)}`, "cancel", c.remote_task_id,
              JSON.stringify({ local_task_id: a.local_task_id }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
          }
        } else {
          this.sql.exec(`UPDATE remote_tasks SET local_task_id=?, local_run_id=?, branch=?, pane_id=?, agent_id=?,
              state='running', capability_probe=?, updated_at=? WHERE remote_task_id=?`,
            a.local_task_id ?? "", a.local_run_id ?? "", a.branch ?? "", a.pane_id ?? "", a.agent_id ?? "",
            JSON.stringify(a.capability_probe ?? {}), nowMs, c.remote_task_id);
          this.recordTaskEvent(nowMs, c.remote_task_id, "state_changed", { state: "running" });
          if (c.op === "start" && a.capability_probe) this.recordTaskEvent(nowMs, c.remote_task_id, "capability_probe", a.capability_probe);
        }
      } else if (a.outcome !== "accepted" && (c.op === "start" || c.op === "resume")) {
        this.sql.exec(`UPDATE remote_tasks SET state='failed', updated_at=? WHERE remote_task_id=?`, nowMs, c.remote_task_id);
        this.recordTaskEvent(nowMs, c.remote_task_id, "failed", { reason: a.detail });
      } else if (c.op === "cancel" && a.outcome === "accepted") {
        // R2-1 (round-2 review of ZR2): the ack landing here races the
        // remap loop that normally recovers 'timed_out' from a
        // timeout_detected event -- if THIS ack lands first, it used to
        // always write the generic 'cancelled', permanently losing the
        // distinct timed_out value (the remap loop never runs again once
        // the row is already terminal). Same lookup the remap loop uses.
        const finalState = this.sql.exec<{ n: number }>(
          `SELECT COUNT(*) AS n FROM task_events WHERE remote_task_id=? AND type='timeout_detected'`,
          c.remote_task_id).one().n > 0 ? "timed_out" : "cancelled";
        this.sql.exec(`UPDATE remote_tasks SET state=?, updated_at=? WHERE remote_task_id=?`, finalState, nowMs, c.remote_task_id);
        this.recordTaskEvent(nowMs, c.remote_task_id, finalState, {});
      } else if (c.op === "cancel" && a.outcome !== "accepted") {
        // ZR1 (ZERO-REVIEW-213-01 item 1): a FAILED cancel ack used to hit
        // no branch at all here -- the command was still marked 'done'
        // above (line 746), but the explicit cancel attempt it reported
        // failing was then silently dropped: remote_tasks.state stayed
        // 'cancelling' forever, with nothing ever retrying it. Re-queue a
        // fresh cancel for the same local_task_id (same shape as the Z4
        // revoke-while-running loop's own INSERT below), capped at
        // CANCEL_RETRY_CAP like registry-bridge.sh's own cancel retries,
        // so a cancel that can never land becomes one visible
        // cancel_stuck event instead of an unbounded flood.
        const curRow = this.sql.exec<{ state: string; local_task_id: string }>(
          `SELECT state, local_task_id FROM remote_tasks WHERE remote_task_id=?`, c.remote_task_id).toArray()[0];
        if (curRow && !REMOTE_TERMINAL[curRow.state] && curRow.local_task_id) {
          const retries = this.sql.exec<{ n: number }>(
            `SELECT COUNT(*) AS n FROM task_events WHERE remote_task_id=? AND type='cancel_retry_queued'`, c.remote_task_id).one().n;
          if (retries < CANCEL_RETRY_CAP) {
            this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
              `cmd_${crypto.randomUUID().slice(0, 12)}`, "cancel", c.remote_task_id,
              JSON.stringify({ local_task_id: curRow.local_task_id }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
            this.recordTaskEvent(nowMs, c.remote_task_id, "cancel_retry_queued", { attempt: retries + 1, reason: a.detail });
          } else {
            const stuck = this.sql.exec<{ n: number }>(
              `SELECT COUNT(*) AS n FROM task_events WHERE remote_task_id=? AND type='cancel_stuck'`, c.remote_task_id).one().n;
            if (stuck === 0) this.recordTaskEvent(nowMs, c.remote_task_id, "cancel_stuck", { attempts: retries });
          }
        }
      }
    }

    // Owner acks retain the delivered/blocked contract. Approval prompts
    // retry; already-typed, unconfirmed notices wait for a reply until expiry.
    for (const a of body.owner_acks ?? []) {
      const m = this.sql.exec<{ status: string; owner_label: string; attempts: number; expires_at: number }>(
        `SELECT status, owner_label, attempts, expires_at FROM owner_messages WHERE exchange_id=?`, a.exchange_id).toArray()[0];
      if (!m || m.status !== "delivering") continue;
      if (a.outcome === "delivered") {
        this.sql.exec(`UPDATE owner_messages SET status='delivered', delivered_at=?, detail='', updated_at=?, lease_until=0 WHERE exchange_id=?`,
          nowMs, nowMs, a.exchange_id);
        this.audit(nowMs, { ...sys, target: m.owner_label, decision: "delivered", reason: "", message_id: a.exchange_id, detail: "" });
        continue;
      }
      const reason = a.reason ?? "unknown";
      if (reason === "deliver_failed:4"
          || (reason === "owner_at_approval_prompt" && m.attempts < APPROVAL_RETRY_CAP)) {
        this.sql.exec(`UPDATE owner_messages SET status='queued', detail=?, updated_at=?, lease_until=? WHERE exchange_id=?`,
          reason, nowMs, reason === "deliver_failed:4" ? m.expires_at : 0, a.exchange_id);
        this.audit(nowMs, { ...sys, target: m.owner_label,
          decision: reason === "deliver_failed:4" ? "notice_unconfirmed" : "retry",
          reason, message_id: a.exchange_id, detail: `attempt ${m.attempts}` });
        continue;
      }
      this.sql.exec(`UPDATE owner_messages SET status=?, detail=?, updated_at=?, lease_until=0 WHERE exchange_id=?`,
        `blocked:${reason}`, reason, nowMs, a.exchange_id);
      this.audit(nowMs, { ...sys, target: m.owner_label, decision: "blocked", reason, message_id: a.exchange_id, detail: "" });
    }

    // A reply the owner wrote on the Mac. "header must match the exchange"
    // (SPEC item 4): the reported owner_label must equal THIS exchange's own
    // target (the Mac's directory-scoped knowledge, re-validated here).
    // rc 4 and pre-send rc 5 both follow a successful body-file write.
    // Accept matching replies while those exchanges are non-terminal,
    // without claiming notice delivery or requiring another notice lease.
    const ownerReplyResults: { exchange_id: string; owner_label: string; outcome: string }[] = [];
    for (const r of body.owner_replies ?? []) {
      // #225 review round 3 N1: a reply file under the WRONG label
      // directory (same exchange_id, different owner_label claim) must
      // never be matched against the right one by exchange_id alone --
      // echo back the REQUESTED owner_label on every result so the Mac
      // can key by (owner_label, exchange_id), not exchange_id alone.
      const m = this.sql.exec<{ owner_label: string; status: string; detail: string; reply_body: string | null;
        sender_actor: string; sender_client: string; expires_at: number }>(
        `SELECT owner_label, status, detail, reply_body, sender_actor, sender_client, expires_at FROM owner_messages WHERE exchange_id=?`,
        r.exchange_id).toArray()[0];
      if (!m || m.owner_label !== r.owner_label) {
        ownerReplyResults.push({ exchange_id: r.exchange_id, owner_label: r.owner_label, outcome: "ignored:missing" });
        continue;
      }
      if (m.status === "replied") {
        // #225 review round 3 N3: "duplicate" must mean the Worker
        // actually stored THIS text, not merely that the exchange was
        // already replied to -- an owner who changes their mind and
        // re-sends a DIFFERENT body must never have the second file
        // silently treated as equivalent to the first (which is all the
        // Worker ever recorded). Only an exact re-send of the stored
        // body is a true duplicate (a retried tick, or a resend after a
        // lost ack); any other second body is ignored:replied, which the
        // Mac routes to replies/rejected/, never sent/.
        const outcome = m.reply_body === r.body ? "duplicate" : "ignored:replied";
        ownerReplyResults.push({ exchange_id: r.exchange_id, owner_label: r.owner_label, outcome });
        continue;
      }
      const earlyReply = (m.detail === "deliver_failed:4" || m.detail === "owner_at_approval_prompt")
        && (m.status === "queued" || m.status === "delivering");
      // Undelivered exchanges use sync-time expiry, not the file's claimed
      // responded_at. Confirmed deliveries retain post-delivery reply behavior.
      if (m.status !== "delivered" && !(earlyReply && m.expires_at > nowMs)) {
        ownerReplyResults.push({ exchange_id: r.exchange_id, owner_label: r.owner_label, outcome: `ignored:${m.status}` });
        continue;
      }
      // Even a confirmed notice is not permission to accept after revocation.
      const refusal = this.env.OWNER_INBOX_ENABLED !== "true" ? "owner_inbox_disabled"
        : !emailAllowed(this.env, m.sender_actor)
          || ownerGate.revoked.some((s) => s.actor === m.sender_actor && s.client_id === m.sender_client)
          ? "sender_revoked" : null;
      if (refusal || ownerGate.hold) {
        const outcome = refusal ? `ignored:blocked:${refusal}`
          : m.status === "delivered" ? "retry:grant_lookup_hold" : `ignored:${m.status}`;
        ownerReplyResults.push({ exchange_id: r.exchange_id, owner_label: r.owner_label, outcome });
        continue;
      }
      const respondedMs = Date.parse(r.responded_at);
      // Plan section 3: "conditionally update owner_messages AND insert
      // owner.reply_ready in the same transaction, using a stable
      // transition ID derived from the exchange and accepted reply
      // revision" -- reached ONLY from the branch above (a guarded/no-op
      // update, every branch above this one, emits nothing). This is a
      // SQLite-backed Durable Object (ctx.storage.sql), never D1 -- "D1"
      // in the plan doc is legacy wording from an earlier draft.
      // Wrapped in an explicit transactionSync so insertEvent's RETURN
      // VALUE, not just its side effect, gates whether status='replied'
      // ever commits (Zero's read-only review at be289f8 state.ts:1261:
      // the old code called insertEvent and ignored what it returned, so
      // a rejected:duplicate_payload_mismatch -- an event_id collision --
      // still committed the UPDATE and reported "accepted", with no
      // durable event and no retry path to repair it). A bad outcome
      // throws inside the closure, which rolls back BOTH the UPDATE and
      // the audit row: the exchange stays 'delivered' and the Mac's next
      // sync tick re-reports the same reply, this time (if the collision
      // has cleared) succeeding for real.
      let outcome: string;
      try {
        outcome = this.ctx.storage.transactionSync(() => {
          this.sql.exec(`UPDATE owner_messages SET status='replied', reply_body=?, reply_session=?,
              reply_artifact_revision=?, replied_at=?, updated_at=? WHERE exchange_id=?`,
            r.body, r.session, r.artifact_revision, Number.isFinite(respondedMs) ? respondedMs : nowMs, nowMs, r.exchange_id);
          this.audit(nowMs, { ...sys, target: m.owner_label, decision: "replied", reason: "", message_id: r.exchange_id, detail: "" });
          // data carries owner_label only -- never reply_body (plan
          // section 4: "the events carry no reply text"); visibility
          // owner_private restricts it to this exchange's own sender
          // (listEvents/waitForEvents).
          const result = this.insertEvent(nowMs, {
            eventId: namespacedEventId("srv", { email: m.sender_actor, client_id: m.sender_client },
              "owner.reply_ready", r.exchange_id, r.artifact_revision || "none"),
            remoteTaskId: "", type: "owner.reply_ready", source: "owner_inbox",
            subjectKind: "owner_exchange", subjectId: r.exchange_id, visibility: "owner_private",
            senderActor: m.sender_actor, senderClient: m.sender_client, correlationId: r.exchange_id,
            data: { owner_label: m.owner_label },
          });
          if (result.outcome !== "accepted" && result.outcome !== "duplicate_same_payload") {
            throw new Error(`event_conflict:${result.outcome}`);
          }
          return "accepted";
        });
      } catch {
        outcome = "rejected:event_conflict";
      }
      ownerReplyResults.push({ exchange_id: r.exchange_id, owner_label: r.owner_label, outcome });
    }

    // A queued message was valid when it was sent, not necessarily now. Before
    // anything is leased, refuse what the off switch, the allowlist, or a
    // revoked grant no longer permits. A message already leased this tick is
    // in the publisher's hands; a retry brings it back here first.
    const enabled = this.env.MESSAGING_ENABLED === "true";
    const revoked = new Set(gate.revoked.map((s) => `${s.actor}\n${s.client_id}`));
    for (const m of this.sql.exec<{ message_id: string; task_id: string; actor: string; client_id: string }>(
      `SELECT message_id, task_id, actor, client_id FROM messages
       WHERE status='queued' OR (status='delivering' AND lease_until < ?)`, nowMs).toArray()) {
      const why = !enabled ? "messaging_disabled"
        : !emailAllowed(this.env, m.actor) ? "sender_not_allowed"
        : revoked.has(`${m.actor}\n${m.client_id}`) ? "sender_grant_revoked" : null;
      if (!why) continue;
      this.sql.exec(`UPDATE messages SET status='refused', detail=?, updated_at=?, lease_until=0 WHERE message_id=?`,
        `cancelled before delivery: ${why}`, nowMs, m.message_id);
      this.audit(nowMs, { actor: m.actor, client_id: m.client_id, tool: "delivery", target: m.task_id,
        decision: "cancelled_before_delivery", reason: why, message_id: m.message_id, detail: "" });
    }

    // Same re-check for every queued/overdue owner message: the off switch,
    // an allowlist removal, or a revoked grant stops it before the Mac ever
    // sees it -- SPEC item 6, exact wording: "the state becomes
    // blocked:sender_revoked" (both reasons collapse to that one name; the
    // off switch itself is reported separately since it is not about the
    // sender at all).
    const ownerEnabled = this.env.OWNER_INBOX_ENABLED === "true";
    const ownerRevoked = new Set(ownerGate.revoked.map((s) => `${s.actor}\n${s.client_id}`));
    for (const m of this.sql.exec<{ exchange_id: string; owner_label: string; sender_actor: string; sender_client: string }>(
      `SELECT exchange_id, owner_label, sender_actor, sender_client FROM owner_messages
       WHERE status='queued' OR (status='delivering' AND lease_until < ?)`, nowMs).toArray()) {
      const why = !ownerEnabled ? "owner_inbox_disabled"
        : !emailAllowed(this.env, m.sender_actor) ? "sender_revoked"
        : ownerRevoked.has(`${m.sender_actor}\n${m.sender_client}`) ? "sender_revoked" : null;
      if (!why) continue;
      this.sql.exec(`UPDATE owner_messages SET status=?, detail=?, updated_at=?, lease_until=0 WHERE exchange_id=?`,
        `blocked:${why}`, why, nowMs, m.exchange_id);
      this.audit(nowMs, { actor: m.sender_actor, client_id: m.sender_client, tool: "delivery", target: m.owner_label,
        decision: "cancelled_before_delivery", reason: why, message_id: m.exchange_id, detail: "" });
    }

    // Same re-check for every queued/overdue command: a revoked grant must
    // stop that connection's QUEUED tasks (SPEC) before the Mac ever sees
    // them, and the off switch / disabled-on-Mac state refuses everyone's.
    const tasksEnabled = this.env.TASKS_ENABLED === "true" && (body.snapshot.task_config?.mac_enabled ?? false);
    const cmdRevoked = new Set(cmdGate.revoked.map((s) => `${s.actor}\n${s.client_id}`));
    for (const c of this.sql.exec<{ command_id: string; remote_task_id: string; op: string }>(
      `SELECT command_id, remote_task_id, op FROM commands
       WHERE status='queued' OR (status='delivering' AND lease_until < ?)`, nowMs).toArray()) {
      const rt = this.sql.exec<{ requester_email: string; requester_client: string }>(
        `SELECT requester_email, requester_client FROM remote_tasks WHERE remote_task_id=?`, c.remote_task_id).toArray()[0];
      if (!rt) continue;
      // N4: op='cancel' is exempt from every sender refusal here, not only
      // the tasks-disabled switch. A cancel only ever lowers risk; refusing
      // one because the sender's email was later removed from the
      // allowlist or their grant was revoked would block the Worker's own
      // timeout cancel and the user's pending cancels while the Mac's
      // deadline is still the only thing stopping the agent.
      const why = c.op === "cancel" ? null
        : !tasksEnabled ? "tasks_disabled"
        : !emailAllowed(this.env, rt.requester_email) ? "sender_not_allowed"
        : cmdRevoked.has(`${rt.requester_email}\n${rt.requester_client}`) ? "sender_grant_revoked" : null;
      if (!why) continue;
      this.sql.exec(`UPDATE commands SET status='done', outcome='refused', detail=?, updated_at=?, lease_until=0 WHERE command_id=?`,
        `cancelled before delivery: ${why}`, nowMs, c.command_id);
      if (c.op === "start" || c.op === "resume") {
        this.sql.exec(`UPDATE remote_tasks SET state='cancelled', updated_at=? WHERE remote_task_id=?`, nowMs, c.remote_task_id);
        this.recordTaskEvent(nowMs, c.remote_task_id, "cancelled", { reason: why });
      }
      this.audit(nowMs, { actor: rt.requester_email, client_id: rt.requester_client, tool: "delivery", target: c.remote_task_id,
        decision: "cancelled_before_delivery", reason: why, message_id: "", detail: c.op });
    }

    // Z4 (SPEC fix: Zero's review item 4): a sender's grant can be revoked
    // (or their email removed from the allowlist) while their task is
    // ALREADY RUNNING on the Mac, not only while a start/resume is still
    // queued -- the loop above only ever re-checks commands, so a task with
    // no pending command never got this check at all. Same cancel-command
    // shape as cancelTask() itself: this never fails the task outright,
    // only asks the Mac to stop it, and the state flip to 'cancelling'
    // self-guards against queuing the same cancel twice on the next tick.
    // This loop itself checks no separate tasksEnabled flag -- the
    // sender_not_allowed arm (ALLOWED_EMAILS) always applies, and the
    // sender_grant_revoked arm already inherits env.TASKS_ENABLED from
    // cmdGate's own construction in ingest() (activeTaskSenders() is fed
    // through the SAME grantGate call as pendingCommandSenders()): when
    // tasks are globally off, grantGate reports nothing revoked, the same
    // "ride to the deadline backstop" semantics the kill switch already
    // documents, not a second one invented here.
    for (const rt of this.sql.exec<{ remote_task_id: string; local_task_id: string; requester_email: string; requester_client: string }>(
      `SELECT remote_task_id, local_task_id, requester_email, requester_client FROM remote_tasks
       WHERE local_task_id<>'' AND state IN ('running','starting','waiting_approval','blocked')`).toArray()) {
      const why = !emailAllowed(this.env, rt.requester_email) ? "sender_not_allowed"
        : cmdRevoked.has(`${rt.requester_email}\n${rt.requester_client}`) ? "sender_grant_revoked" : null;
      if (!why) continue;
      this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
        `cmd_${crypto.randomUUID().slice(0, 12)}`, "cancel", rt.remote_task_id,
        JSON.stringify({ local_task_id: rt.local_task_id, reason: why }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
      this.sql.exec(`UPDATE remote_tasks SET state='cancelling', updated_at=? WHERE remote_task_id=?`, nowMs, rt.remote_task_id);
      this.recordTaskEvent(nowMs, rt.remote_task_id, "cancel_requested", { reason: why });
      this.audit(nowMs, { actor: rt.requester_email, client_id: rt.requester_client, tool: "delivery", target: rt.remote_task_id,
        decision: "revoked_while_running", reason: why, message_id: "", detail: "cancel" });
    }

    for (const m of this.sql.exec<{ message_id: string; task_id: string; detail: string; attempts: number }>(
      `SELECT message_id, task_id, detail, attempts FROM messages
       WHERE status IN ('queued','delivering') AND (expires_at <= ? OR (attempts >= ? AND lease_until < ?))`,
      nowMs, MAX_ATTEMPTS, nowMs).toArray()) {
      const status = m.attempts >= MAX_ATTEMPTS ? "failed" : "expired";
      const why = m.attempts >= MAX_ATTEMPTS ? `gave up after ${m.attempts} attempts` : "not delivered within 15 minutes";
      this.sql.exec(`UPDATE messages SET status=?, detail=?, updated_at=? WHERE message_id=?`,
        status, `${why}${m.detail ? `; last: ${m.detail}` : ""}`.slice(0, 300), nowMs, m.message_id);
      this.audit(nowMs, { ...sys, target: m.task_id, decision: status, reason: why, message_id: m.message_id, detail: m.detail });
    }

    for (const c of this.sql.exec<{ command_id: string; remote_task_id: string; op: string; detail: string; attempts: number }>(
      `SELECT command_id, remote_task_id, op, detail, attempts FROM commands
       WHERE status IN ('queued','delivering') AND (expires_at <= ? OR (attempts >= ? AND lease_until < ?))`,
      nowMs, MAX_ATTEMPTS, nowMs).toArray()) {
      const status = c.attempts >= MAX_ATTEMPTS ? "failed" : "expired";
      const why = c.attempts >= MAX_ATTEMPTS ? `gave up after ${c.attempts} attempts` : "not delivered within 15 minutes";
      this.sql.exec(`UPDATE commands SET status='done', outcome=?, detail=?, updated_at=? WHERE command_id=?`,
        status, `${why}${c.detail ? `; last: ${c.detail}` : ""}`.slice(0, 300), nowMs, c.command_id);
      if (c.op === "start" || c.op === "resume") {
        const cur = this.sql.exec<{ state: string }>(`SELECT state FROM remote_tasks WHERE remote_task_id=?`, c.remote_task_id).toArray()[0];
        // N2: a cancel that raced ahead of the ack (M6) leaves the row
        // 'cancelling' with no local_task_id to key a real cancel command
        // on. If the start/resume itself then expires or exhausts its
        // attempts instead of ever being acked, that row must resolve to
        // 'cancelled' (the caller's actual intent), not get stuck
        // forever excluded from both this loop and the deadline sweep
        // below (both exclude 'cancelling').
        const final = cur?.state === "cancelling" ? "cancelled" : "failed";
        this.sql.exec(`UPDATE remote_tasks SET state=?, updated_at=? WHERE remote_task_id=?`, final, nowMs, c.remote_task_id);
        this.recordTaskEvent(nowMs, c.remote_task_id, final, { reason: why });
      }
      this.audit(nowMs, { ...sys, target: c.remote_task_id, decision: status, reason: why, message_id: "", detail: c.detail });
    }

    // An unconfirmed notice is never leased again and ends with its rc 4
    // reason at expiry. Other undelivered exchanges retain their old caps.
    for (const m of this.sql.exec<{ exchange_id: string; owner_label: string; detail: string; attempts: number }>(
      `SELECT exchange_id, owner_label, detail, attempts FROM owner_messages
       WHERE status IN ('queued','delivering') AND (expires_at <= ?
         OR (detail <> 'deliver_failed:4' AND attempts >= ? AND lease_until < ?))`,
      nowMs, MAX_ATTEMPTS, nowMs).toArray()) {
      const rc = m.detail === "deliver_failed:4" ? "4" : m.attempts >= MAX_ATTEMPTS ? "max_attempts" : "timeout";
      const why = `deliver_failed:${rc}`;
      const note = rc === "max_attempts" ? `gave up after ${m.attempts} attempts` : "not delivered within 15 minutes";
      this.sql.exec(`UPDATE owner_messages SET status=?, detail=?, updated_at=? WHERE exchange_id=?`,
        `blocked:${why}`, `${note}${m.detail ? `; last: ${m.detail}` : ""}`.slice(0, 300), nowMs, m.exchange_id);
      this.audit(nowMs, { ...sys, target: m.owner_label, decision: "blocked", reason: why, message_id: m.exchange_id, detail: m.detail });
    }

    // Local -> remote state remap, once per still-open remote task, every
    // tick: this is how a researching/implementing task's state reaches
    // verified, finished, waiting_approval, or answer_ready without the Mac
    // ever needing to know the richer remote vocabulary.
    const livePermission = new Set(body.snapshot.blockers.filter((b) => b.kind === "permission" && b.task_id).map((b) => b.task_id as string));
    const localTasks = new Map(body.snapshot.tasks.map((t) => [t.task_id, t]));
    for (const rt of this.sql.exec<{ remote_task_id: string; state: string; local_task_id: string }>(
      `SELECT remote_task_id, state, local_task_id FROM remote_tasks
       WHERE local_task_id<>'' AND state NOT IN ('finished','verified','failed','cancelled','lost','timed_out')`).toArray()) {
      const t = localTasks.get(rt.local_task_id);
      if (!t) continue;
      const mapped = mapLocalState(t, livePermission.has(rt.local_task_id));
      // F4 (REVIEW-213): 'cancelling' is a REMOTE-side intent the Mac has
      // not yet confirmed -- its own local snapshot can still say
      // 'running' for several ticks (the cancel command is leased, not
      // yet delivered/acked). Remapping unconditionally off
      // mapLocalState() here used to flip 'cancelling' straight back to
      // 'running' on THIS SAME sync() call's remap pass, undoing the
      // revoke-while-running loop's own flip above every tick and
      // re-arming it -- a fresh cancel command, a fresh cancel_requested
      // event, a fresh revoked_while_running audit row, every ~15s,
      // forever. Only skip the remap while 'cancelling' AND the local
      // state has not yet resolved to anything terminal; once it has
      // (the Mac's own state finally confirms finished/cancelled/etc,
      // whether via a normal completion racing the cancel or the cancel
      // itself landing), let it through so 'cancelling' can actually
      // resolve.
      if (rt.state === "cancelling" && !REMOTE_TERMINAL[mapped]) {
        // still in flight -- nothing to do until the Mac confirms.
      } else if (mapped !== rt.state) {
        // ZR2 (ZERO-REVIEW-213-01 item 2): preserve the distinct
        // 'timed_out' value through this remap, rather than collapsing a
        // timeout-triggered cancel into the generic 'cancelled' the
        // underlying local state (and therefore mapLocalState) always
        // reports once the Mac confirms it stopped.
        const finalState = mapped === "cancelled" && rt.state === "cancelling"
          && this.sql.exec<{ n: number }>(
            `SELECT COUNT(*) AS n FROM task_events WHERE remote_task_id=? AND type='timeout_detected'`, rt.remote_task_id).one().n > 0
          ? "timed_out" : mapped;
        this.sql.exec(`UPDATE remote_tasks SET state=?, updated_at=? WHERE remote_task_id=?`, finalState, nowMs, rt.remote_task_id);
        this.recordTaskEvent(nowMs, rt.remote_task_id, finalState === "waiting_approval" ? "approval_needed" : "state_changed", { state: finalState });
      }
      // research-task-closure defect 3: has_result is PROOF.md's mere
      // existence (created empty alongside every task's SPEC.md, so it was
      // already true before a research task had written anything at all);
      // has_answer is ANSWER.md itself, present and non-empty -- the
      // actual condition a client's answer_ready should mean.
      if (t.has_answer) {
        const already = this.sql.exec<{ n: number }>(
          `SELECT COUNT(*) AS n FROM task_events WHERE remote_task_id=? AND type='answer_ready'`, rt.remote_task_id).one().n;
        if (already === 0) this.recordTaskEvent(nowMs, rt.remote_task_id, "answer_ready", {});
      }
    }

    // A remote task that outran its mode's max_minutes is cancelled the same
    // way cancel_task cancels one -- the queued cancel command is what
    // actually closes the Mac's pane (SPEC: enforced on the Mac AND here).
    const caps = this.taskCaps(nowMs);
    for (const rt of this.sql.exec<{ remote_task_id: string; created_at: number; local_task_id: string }>(
      `SELECT remote_task_id, created_at, local_task_id FROM remote_tasks
       WHERE state NOT IN ('finished','verified','failed','cancelled','lost','timed_out','cancelling')`).toArray()) {
      if (nowMs - rt.created_at < caps.max_minutes * 60_000) continue;
      // ZR2 (ZERO-REVIEW-213-01 item 2): a deadline firing used to write
      // the TERMINAL 'timed_out' state immediately, before the Mac had
      // confirmed anything actually stopped -- excluded from every later
      // sync loop (including this very loop's own WHERE clause, and the
      // command_acks loop's cancel-outcome handling) the instant it was
      // written. An unspawned task (no local_task_id: nothing is running,
      // the same "nothing to confirm" case the cancelled_before_delivery
      // path above already treats as immediately terminal) is the one
      // case safe to mark 'timed_out' directly; everything else goes
      // through 'cancelling' like any other cancel, resolved by the
      // remap loop above once the Mac confirms -- which recovers the
      // distinct 'timed_out' value from the timeout_detected event
      // recorded here, rather than losing it to a generic 'cancelled'.
      if (!rt.local_task_id) {
        this.sql.exec(`UPDATE remote_tasks SET state='timed_out', updated_at=? WHERE remote_task_id=?`, nowMs, rt.remote_task_id);
        this.recordTaskEvent(nowMs, rt.remote_task_id, "timed_out", { max_minutes: caps.max_minutes });
        continue;
      }
      this.sql.exec(`UPDATE remote_tasks SET state='cancelling', updated_at=? WHERE remote_task_id=?`, nowMs, rt.remote_task_id);
      this.recordTaskEvent(nowMs, rt.remote_task_id, "timeout_detected", { max_minutes: caps.max_minutes });
      this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
        `cmd_${crypto.randomUUID().slice(0, 12)}`, "cancel", rt.remote_task_id,
        JSON.stringify({ local_task_id: rt.local_task_id, reason: "timed_out" }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
    }

    const due = body.lease && !gate.hold ? this.sql.exec<{ message_id: string; task_id: string; pane_id: string; agent_id: string; label: string;
      text: string; actor: string; client_name: string; attempts: number }>(
      `SELECT message_id, task_id, pane_id, agent_id, label, text, actor, client_name, attempts FROM messages
       WHERE (status='queued' OR (status='delivering' AND lease_until < ?)) AND expires_at > ? ORDER BY created_at LIMIT 20`,
      nowMs, nowMs).toArray() : [];
    for (const m of due) {
      this.sql.exec(`UPDATE messages SET status='delivering', attempts=attempts+1, lease_until=?, updated_at=? WHERE message_id=?`,
        nowMs + LEASE_MS, nowMs, m.message_id);
    }

    const dueCommands = body.lease && !cmdGate.hold ? this.sql.exec<{ command_id: string; op: CommandOp; remote_task_id: string;
      payload: string; attempts: number }>(
      `SELECT command_id, op, remote_task_id, payload, attempts FROM commands
       WHERE (status='queued' OR (status='delivering' AND lease_until < ?)) AND expires_at > ? ORDER BY created_at LIMIT 20`,
      nowMs, nowMs).toArray() : [];
    for (const c of dueCommands) {
      this.sql.exec(`UPDATE commands SET status='delivering', attempts=attempts+1, lease_until=?, updated_at=? WHERE command_id=?`,
        nowMs + LEASE_MS, nowMs, c.command_id);
    }

    const dueOwners = body.lease && !ownerGate.hold ? this.sql.exec<{ exchange_id: string; owner_label: string; client_msg_id: string;
      body: string; sender_actor: string; sender_client_name: string; attempts: number }>(
      `SELECT exchange_id, owner_label, client_msg_id, body, sender_actor, sender_client_name, attempts FROM owner_messages
       WHERE ((status='queued' AND lease_until <= ?) OR (status='delivering' AND lease_until < ?))
         AND detail <> 'deliver_failed:4' AND expires_at > ? ORDER BY created_at LIMIT 20`,
      nowMs, nowMs, nowMs).toArray() : [];
    for (const m of dueOwners) {
      this.sql.exec(`UPDATE owner_messages SET status='delivering', attempts=attempts+1, lease_until=?, updated_at=? WHERE exchange_id=?`,
        nowMs + LEASE_MS, nowMs, m.exchange_id);
    }

    this.sql.exec(`DELETE FROM audit WHERE at < ?`, nowMs - AUDIT_KEEP_MS);
    this.sql.exec(`DELETE FROM messages WHERE status IN ('delivered','refused','failed','expired') AND updated_at < ?`, nowMs - 30 * 86_400_000);
    this.sql.exec(`DELETE FROM results WHERE synced_at < ?`, nowMs - 30 * 86_400_000);
    this.sql.exec(`DELETE FROM commands WHERE status='done' AND updated_at < ?`, nowMs - 30 * 86_400_000);
    // Non-prefix prune (plan section 5): this can delete an old row for
    // one terminal task while a much OLDER row for a still-active task
    // survives, so MIN(cursor) afterward is never a safe replay floor --
    // capture the highest cursor THIS delete may remove and raise the
    // durable floor before it runs, never after (a crash between the two
    // would otherwise let a stale cursor read past a gap it can't see).
    // Owner events (subject_kind='owner_exchange') carry remote_task_id=''
    // and so never match the terminal-task subquery; they expire on age
    // alone, the same 30-day window Terrence chose for the event log
    // (hub form 20261004T205923-8776, retention=30d).
    const pruneCutoff = nowMs - 30 * 86_400_000;
    const prunable = `at < ? AND (subject_kind='owner_exchange' OR remote_task_id IN
      (SELECT remote_task_id FROM remote_tasks WHERE state IN ('finished','verified','failed','cancelled','lost','timed_out')))`;
    const pruneMax = this.sql.exec<{ c: number | null }>(`SELECT MAX(cursor) AS c FROM task_events WHERE ${prunable}`,
      pruneCutoff).one().c;
    this.raiseReplayFloor(pruneMax);
    this.sql.exec(`DELETE FROM task_events WHERE ${prunable}`, pruneCutoff);
    this.sql.exec(`DELETE FROM remote_tasks WHERE state IN ('finished','verified','failed','cancelled','lost','timed_out') AND updated_at < ?`,
      nowMs - 30 * 86_400_000);

    this.sql.exec(`DELETE FROM owner_messages WHERE (status='delivered' OR status='replied' OR status LIKE 'blocked:%') AND updated_at < ?`,
      nowMs - 30 * 86_400_000);

    const audit = this.sql.exec<{ seq: number; at: number; actor: string; client_id: string; tool: string; target: string;
      decision: string; reason: string; message_id: string; detail: string }>(
      `SELECT * FROM audit WHERE seq > ? ORDER BY seq LIMIT 500`, body.audit_cursor).toArray()
      .map((r) => ({ ...r, at: iso(r.at) }));
    const cursor = audit.length ? audit[audit.length - 1]!.seq : body.audit_cursor;
    return {
      ok: true,
      response: {
        outbox: due.map((m) => ({ ...m, attempts: m.attempts + 1 })),
        commands: dueCommands.map((c) => ({ ...c, payload: JSON.parse(c.payload) as object, attempts: c.attempts + 1 })),
        owner_outbox: dueOwners.map((m) => ({
          exchange_id: m.exchange_id, owner_label: m.owner_label, client_msg_id: m.client_msg_id, body: m.body,
          sender: m.sender_actor, client_name: m.sender_client_name, attempts: m.attempts + 1,
        })),
        audit, audit_cursor: cursor,
        owner_reply_results: ownerReplyResults,
      },
    };
  }
}
