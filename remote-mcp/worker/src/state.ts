// The one Durable Object: latest snapshot, task results, the message queue,
// and the audit trail. Single-threaded, so the send-message policy check and
// the enqueue happen atomically against the same snapshot.
import { DurableObject } from "cloudflare:workers";
import { z } from "zod";
import { connection, rateLimited, resolveTarget, sanitizeMessage } from "./policy";
import type { Connection } from "./policy";
import type { Env, OutboxItem, ResultDoc, Snapshot } from "./types";
import { SNAPSHOT_SCHEMA } from "./types";

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
    })).max(2000),
    blockers: z.array(z.object({
      task_id: nstr, label: nstr, pane_id: nstr, agent_id: nstr, kind: str, tool: nstr, summary: nstr, since: nstr,
    })).max(500),
  }),
  results: z.array(z.object({
    task_id: str, source: str, text: z.string().max(70_000), sha256: str, source_mtime: nstr, truncated_at_source: z.boolean(),
  })).max(400),
  acks: z.array(z.object({
    message_id: str, outcome: z.enum(["delivered", "refused", "failed", "retry"]), detail: str,
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
  audit: AuditRow[];
  audit_cursor: number;
}

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

export class HerdrState extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS results (task_id TEXT PRIMARY KEY, source TEXT NOT NULL, text TEXT NOT NULL,
      sha256 TEXT NOT NULL, source_mtime TEXT, truncated_at_source INTEGER NOT NULL, synced_at INTEGER NOT NULL)`);
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
    return { snapshot: this.cached.snapshot, connection: connection(this.cached.snapshot, last, nowMs, this.staleAfterS()) };
  }

  result(taskId: string): (ResultDoc & { synced_at: string }) | null {
    const r = this.sql.exec<{ task_id: string; source: string; text: string; sha256: string; source_mtime: string | null;
      truncated_at_source: number; synced_at: number }>(`SELECT * FROM results WHERE task_id=?`, taskId).toArray()[0];
    if (!r) return null;
    return { ...r, truncated_at_source: r.truncated_at_source === 1, synced_at: iso(r.synced_at) };
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
    const tooMany = rateLimited(recent, nowMs);
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

  // Publisher sync: store the snapshot, apply delivery acks, expire, lease the
  // outbox, and hand back new audit rows for the Mac's local copy.
  sync(nowMs: number, nonce: string, rawBody: string): { ok: true; response: SyncResponse } | { ok: false; status: number; reason: string } {
    this.sql.exec(`DELETE FROM nonces WHERE seen_at < ?`, nowMs - NONCE_TTL_MS);
    if (this.sql.exec(`SELECT 1 FROM nonces WHERE nonce=?`, nonce).toArray().length) {
      return { ok: false, status: 409, reason: "replayed_nonce" };
    }
    this.sql.exec(`INSERT INTO nonces (nonce, seen_at) VALUES (?, ?)`, nonce, nowMs);
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

    const due = body.lease ? this.sql.exec<{ message_id: string; task_id: string; pane_id: string; agent_id: string; label: string;
      text: string; actor: string; client_name: string; attempts: number }>(
      `SELECT message_id, task_id, pane_id, agent_id, label, text, actor, client_name, attempts FROM messages
       WHERE (status='queued' OR (status='delivering' AND lease_until < ?)) AND expires_at > ? ORDER BY created_at LIMIT 20`,
      nowMs, nowMs).toArray() : [];
    for (const m of due) {
      this.sql.exec(`UPDATE messages SET status='delivering', attempts=attempts+1, lease_until=?, updated_at=? WHERE message_id=?`,
        nowMs + LEASE_MS, nowMs, m.message_id);
    }

    this.sql.exec(`DELETE FROM audit WHERE at < ?`, nowMs - AUDIT_KEEP_MS);
    this.sql.exec(`DELETE FROM messages WHERE status IN ('delivered','refused','failed','expired') AND updated_at < ?`, nowMs - 30 * 86_400_000);
    this.sql.exec(`DELETE FROM results WHERE synced_at < ?`, nowMs - 30 * 86_400_000);

    const audit = this.sql.exec<{ seq: number; at: number; actor: string; client_id: string; tool: string; target: string;
      decision: string; reason: string; message_id: string; detail: string }>(
      `SELECT * FROM audit WHERE seq > ? ORDER BY seq LIMIT 500`, body.audit_cursor).toArray()
      .map((r) => ({ ...r, at: iso(r.at) }));
    const cursor = audit.length ? audit[audit.length - 1]!.seq : body.audit_cursor;
    return {
      ok: true,
      response: { outbox: due.map((m) => ({ ...m, attempts: m.attempts + 1 })), audit, audit_cursor: cursor },
    };
  }
}
