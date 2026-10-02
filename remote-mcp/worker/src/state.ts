// The one Durable Object: latest snapshot, task results, the message queue,
// the remote-task lifecycle (herdr-mcp's start/cancel/resume commands and
// task_events feed), and the audit trail. Single-threaded, so the
// send-message/start-task policy checks and their enqueue happen atomically
// against the same snapshot.
import { DurableObject } from "cloudflare:workers";
import { z } from "zod";
import { emailAllowed } from "./access";
import { connection, DEFAULT_LIMITS, rateLimited, resolveTarget, sanitizeMessage, sanitizeObjective } from "./policy";
import type { Connection, MessageLimits } from "./policy";
import type { CommandAck, CommandItem, CommandOp, DeliveryGate, Env, OutboxItem, ResultDoc, Sender, Snapshot, TaskCaps, TaskRow } from "./types";
import { SCOPE_TASK_CANCEL, SCOPE_TASK_IMPLEMENT, SCOPE_TASK_START, SNAPSHOT_SCHEMA } from "./types";

const str = z.string().max(4000);
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
      remote_task_id: nstr, verified: z.boolean().nullable(), verify_detail: nstr,
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
    }).nullable(),
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
  })).max(200),
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
  audit: AuditRow[];
  audit_cursor: number;
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
}

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
const AUDIT_KEEP_MS = 180 * 86_400_000;
// Every tool call by one client (allowed or refused) counts. A ChatGPT session
// makes a handful of calls per turn; these only bite a loop or a leaked token.
const CALLS_PER_MINUTE = 60;
const CALLS_PER_DAY = 2000;

const iso = (ms: number) => new Date(ms).toISOString();

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

  // Caps in force this tick: the Mac's own pushed config when we have one
  // synced, else the conservative built-in default (cold start only).
  private taskCaps(nowMs: number): TaskCaps {
    return this.view(nowMs).snapshot?.task_config?.caps ?? DEFAULT_TASK_CAPS;
  }

  private recordTaskEvent(nowMs: number, remoteTaskId: string, type: string, detail: Record<string, unknown> = {}): void {
    this.sql.exec(`INSERT INTO task_events (remote_task_id, type, at, detail) VALUES (?,?,?,?)`,
      remoteTaskId, type, nowMs, JSON.stringify(detail).slice(0, 2000));
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
    const row = this.sql.exec<{ state: string; local_task_id: string }>(
      `SELECT state, local_task_id FROM remote_tasks WHERE remote_task_id=?`, remoteTaskId).toArray()[0];
    if (!row) return refuse("not_found");
    if (REMOTE_TERMINAL[row.state]) return refuse(`already_terminal (${row.state})`);
    if (!row.local_task_id) {
      // Never actually spawned: purely local. Also retire the queued start
      // command so a lease that is in flight right now cannot still hand it
      // to the Mac after this decision was made.
      this.sql.exec(`UPDATE remote_tasks SET state='cancelled', updated_at=? WHERE remote_task_id=?`, nowMs, remoteTaskId);
      this.sql.exec(`UPDATE commands SET status='done', outcome='refused', detail='cancelled before it was spawned', updated_at=?
        WHERE remote_task_id=? AND op='start' AND status='queued'`, nowMs, remoteTaskId);
      this.recordTaskEvent(nowMs, remoteTaskId, "cancelled", { by: caller.email });
      this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "cancel_task", target: remoteTaskId,
        decision: "allowed", reason: "", message_id: "", detail: "cancelled before spawn" });
      return { ok: true, state: "cancelled" };
    }
    this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
      `cmd_${crypto.randomUUID().slice(0, 12)}`, "cancel", remoteTaskId, JSON.stringify({ local_task_id: row.local_task_id }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
    this.sql.exec(`UPDATE remote_tasks SET state='cancelling', updated_at=? WHERE remote_task_id=?`, nowMs, remoteTaskId);
    this.recordTaskEvent(nowMs, remoteTaskId, "cancel_requested", { by: caller.email });
    this.audit(nowMs, { actor: caller.email, client_id: caller.client_id, tool: "cancel_task", target: remoteTaskId,
      decision: "allowed", reason: "", message_id: "", detail: "cancel queued for the Mac" });
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
    const row = this.sql.exec<{ state: string; mode: string; repo: string; local_task_id: string; local_run_id: string; branch: string; objective: string }>(
      `SELECT state, mode, repo, local_task_id, local_run_id, branch, objective FROM remote_tasks WHERE remote_task_id=?`, remoteTaskId).toArray()[0];
    if (!row) return refuse("not_found");
    if (!REMOTE_TERMINAL[row.state]) return refuse(`not_terminal (${row.state})`);
    if (!row.local_task_id) return refuse("never_started");
    const { snapshot, connection: conn } = this.view(nowMs);
    const cfg = snapshot?.task_config ?? null;
    if (!cfg || !cfg.mac_enabled) return refuse("tasks_disabled_on_mac");
    if (conn.state === "disconnected" || conn.state === "never_connected") return refuse(`not_connected (${conn.state})`);
    const caps = cfg.caps;
    const concurrent = this.sql.exec<{ n: number }>(
      `SELECT COUNT(*) AS n FROM remote_tasks WHERE state NOT IN ('finished','verified','failed','cancelled','lost','timed_out')`).one().n;
    if (concurrent >= caps.max_concurrent) return refuse(`too_many_concurrent (max ${caps.max_concurrent})`);
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
      JSON.stringify({ local_task_id: row.local_task_id, local_run_id: row.local_run_id, branch: row.branch, repo: row.repo, text }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
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

  // Every sender with a QUEUED start command that could still be leased --
  // the Worker re-checks the ORIGINAL caller's grant before handing a start
  // to the Mac, same reasoning as pendingSenders() for messages (SPEC:
  // revoking a connection "must stop that connection's tasks from being
  // started"). Tagged with the scope that mode needed, since research and
  // implement are different scopes.
  pendingCommandSenders(nowMs: number): ScopedSender[] {
    return this.sql.exec<{ actor: string; client_id: string; mode: string }>(
      `SELECT DISTINCT rt.requester_email AS actor, rt.requester_client AS client_id, rt.mode AS mode
       FROM remote_tasks rt JOIN commands c ON c.remote_task_id = rt.remote_task_id
       WHERE c.op='start' AND c.status='queued' AND c.expires_at > ?`, nowMs).toArray()
      .map((r) => ({ actor: r.actor, client_id: r.client_id, scope: r.mode === "research" ? SCOPE_TASK_START : SCOPE_TASK_IMPLEMENT }));
  }

  // get_task_answer's "progress" field: this one remote task's own recent
  // history, newest first (unlike listEvents' global ascending cursor feed).
  taskEventLog(remoteTaskId: string, limit: number): TaskEventRow[] {
    return this.sql.exec<{ cursor: number; remote_task_id: string; type: string; at: number; detail: string }>(
      `SELECT cursor, remote_task_id, type, at, detail FROM task_events WHERE remote_task_id=? ORDER BY cursor DESC LIMIT ?`,
      remoteTaskId, limit,
    ).toArray().map((r) => ({ cursor: r.cursor, remote_task_id: r.remote_task_id, type: r.type, at: iso(r.at),
      detail: JSON.parse(r.detail || "{}") as object }));
  }

  listEvents(sinceCursor: number, limit: number): { cursor: number; events: TaskEventRow[] } {
    const rows = this.sql.exec<{ cursor: number; remote_task_id: string; type: string; at: number; detail: string }>(
      `SELECT cursor, remote_task_id, type, at, detail FROM task_events WHERE cursor > ? ORDER BY cursor LIMIT ?`, sinceCursor, limit,
    ).toArray();
    return {
      cursor: rows.length ? rows[rows.length - 1]!.cursor : sinceCursor,
      events: rows.map((r) => ({ cursor: r.cursor, remote_task_id: r.remote_task_id, type: r.type, at: iso(r.at),
        detail: JSON.parse(r.detail || "{}") as object })),
    };
  }

  // Holds the request open until a new event lands or timeoutS elapses --
  // the "notification" a ChatGPT-style client can actually receive without
  // true server push (SPEC item 5). timeoutS is already clamped <= 25 by the
  // tool's own input schema before this is ever called.
  async waitForEvents(sinceCursor: number, timeoutS: number): Promise<{ cursor: number; events: TaskEventRow[] }> {
    const deadline = Date.now() + timeoutS * 1000;
    for (;;) {
      const out = this.listEvents(sinceCursor, 200);
      if (out.events.length > 0 || Date.now() >= deadline) return out;
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
  sync(nowMs: number, nonce: string, rawBody: string, gate: DeliveryGate, cmdGate: DeliveryGate): SyncOutcome {
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
    for (const a of body.command_acks) {
      const c = this.sql.exec<{ status: string; op: CommandOp; remote_task_id: string }>(
        `SELECT status, op, remote_task_id FROM commands WHERE command_id=?`, a.command_id).toArray()[0];
      if (!c || c.status !== "delivering") continue;
      this.sql.exec(`UPDATE commands SET status='done', outcome=?, detail=?, updated_at=? WHERE command_id=?`,
        a.outcome, a.detail.slice(0, 300), nowMs, a.command_id);
      this.audit(nowMs, { ...sys, target: c.remote_task_id, decision: a.outcome === "accepted" ? "allowed" : "refused_at_delivery",
        reason: a.detail, message_id: "", detail: c.op });
      if (a.outcome === "accepted" && (c.op === "start" || c.op === "resume")) {
        this.sql.exec(`UPDATE remote_tasks SET local_task_id=?, local_run_id=?, branch=?, pane_id=?, agent_id=?,
            state='running', capability_probe=?, updated_at=? WHERE remote_task_id=?`,
          a.local_task_id ?? "", a.local_run_id ?? "", a.branch ?? "", a.pane_id ?? "", a.agent_id ?? "",
          JSON.stringify(a.capability_probe ?? {}), nowMs, c.remote_task_id);
        this.recordTaskEvent(nowMs, c.remote_task_id, "state_changed", { state: "running" });
        if (c.op === "start" && a.capability_probe) this.recordTaskEvent(nowMs, c.remote_task_id, "capability_probe", a.capability_probe);
      } else if (a.outcome !== "accepted" && (c.op === "start" || c.op === "resume")) {
        this.sql.exec(`UPDATE remote_tasks SET state='failed', updated_at=? WHERE remote_task_id=?`, nowMs, c.remote_task_id);
        this.recordTaskEvent(nowMs, c.remote_task_id, "failed", { reason: a.detail });
      } else if (c.op === "cancel" && a.outcome === "accepted") {
        this.sql.exec(`UPDATE remote_tasks SET state='cancelled', updated_at=? WHERE remote_task_id=?`, nowMs, c.remote_task_id);
        this.recordTaskEvent(nowMs, c.remote_task_id, "cancelled", {});
      }
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
      const why = !tasksEnabled ? "tasks_disabled"
        : !emailAllowed(this.env, rt.requester_email) ? "sender_not_allowed"
        : cmdRevoked.has(`${rt.requester_email}\n${rt.requester_client}`) ? "sender_grant_revoked" : null;
      if (!why) continue;
      this.sql.exec(`UPDATE commands SET status='done', outcome='refused', detail=?, updated_at=?, lease_until=0 WHERE command_id=?`,
        `cancelled before delivery: ${why}`, nowMs, c.command_id);
      if (c.op === "start") {
        this.sql.exec(`UPDATE remote_tasks SET state='cancelled', updated_at=? WHERE remote_task_id=?`, nowMs, c.remote_task_id);
        this.recordTaskEvent(nowMs, c.remote_task_id, "cancelled", { reason: why });
      }
      this.audit(nowMs, { actor: rt.requester_email, client_id: rt.requester_client, tool: "delivery", target: c.remote_task_id,
        decision: "cancelled_before_delivery", reason: why, message_id: "", detail: c.op });
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
      if (c.op === "start") {
        this.sql.exec(`UPDATE remote_tasks SET state='failed', updated_at=? WHERE remote_task_id=?`, nowMs, c.remote_task_id);
        this.recordTaskEvent(nowMs, c.remote_task_id, "failed", { reason: why });
      }
      this.audit(nowMs, { ...sys, target: c.remote_task_id, decision: status, reason: why, message_id: "", detail: c.detail });
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
      if (mapped !== rt.state) {
        this.sql.exec(`UPDATE remote_tasks SET state=?, updated_at=? WHERE remote_task_id=?`, mapped, nowMs, rt.remote_task_id);
        this.recordTaskEvent(nowMs, rt.remote_task_id, mapped === "waiting_approval" ? "approval_needed" : "state_changed", { state: mapped });
      }
      if (t.has_result) {
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
      this.sql.exec(`UPDATE remote_tasks SET state='timed_out', updated_at=? WHERE remote_task_id=?`, nowMs, rt.remote_task_id);
      this.recordTaskEvent(nowMs, rt.remote_task_id, "timed_out", { max_minutes: caps.max_minutes });
      if (rt.local_task_id) {
        this.sql.exec(`INSERT INTO commands (command_id, op, remote_task_id, payload, created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?)`,
          `cmd_${crypto.randomUUID().slice(0, 12)}`, "cancel", rt.remote_task_id,
          JSON.stringify({ local_task_id: rt.local_task_id, reason: "timed_out" }), nowMs, nowMs, nowMs + MESSAGE_TTL_MS);
      }
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

    this.sql.exec(`DELETE FROM audit WHERE at < ?`, nowMs - AUDIT_KEEP_MS);
    this.sql.exec(`DELETE FROM messages WHERE status IN ('delivered','refused','failed','expired') AND updated_at < ?`, nowMs - 30 * 86_400_000);
    this.sql.exec(`DELETE FROM results WHERE synced_at < ?`, nowMs - 30 * 86_400_000);
    this.sql.exec(`DELETE FROM commands WHERE status='done' AND updated_at < ?`, nowMs - 30 * 86_400_000);
    this.sql.exec(`DELETE FROM task_events WHERE at < ? AND remote_task_id IN
      (SELECT remote_task_id FROM remote_tasks WHERE state IN ('finished','verified','failed','cancelled','lost','timed_out'))`,
      nowMs - 30 * 86_400_000);
    this.sql.exec(`DELETE FROM remote_tasks WHERE state IN ('finished','verified','failed','cancelled','lost','timed_out') AND updated_at < ?`,
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
        audit, audit_cursor: cursor,
      },
    };
  }
}
