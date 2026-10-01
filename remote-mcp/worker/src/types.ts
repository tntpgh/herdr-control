import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import type { HerdrState } from "./state";

// Wire contract between publisher.py (the Mac) and this Worker. Bump SCHEMA
// on any breaking change; the Worker refuses snapshots it does not understand.
export const SNAPSHOT_SCHEMA = 1;

export interface Env {
  OAUTH_KV: KVNamespace;
  HERDR_STATE: DurableObjectNamespace<HerdrState>;
  OAUTH_PROVIDER: OAuthHelpers;
  PUBLIC_URL: string; // https://herdr-mcp.teamthurber.com
  ACCESS_TEAM_DOMAIN: string; // thurberteam.cloudflareaccess.com
  ACCESS_AUD: string; // AUD of the path-scoped Access app on /authorize
  ALLOWED_EMAILS: string; // comma-separated; the only humans who may grant a token
  STALE_AFTER_S: string; // no sync for this long => disconnected
  INGEST_KEY: string; // secret: HMAC key shared with publisher.py
}

export interface HubSummary {
  rev: string | null;
  live_connected: boolean;
  herdr_reachable: boolean;
  attention: number | null;
  open_decisions: number | null;
  handoff_debt: number | null;
}

export interface AgentRow {
  agent_id: string; // herdr terminal id: stable for the life of the pane's terminal
  pane_id: string; // herdr location; can be reused by another terminal later
  workspace: string | null;
  tab_id: string | null;
  kind: string | null; // omp, claude, codex, ...
  label: string | null;
  role: "worker" | "conductor" | "session";
  status: string; // idle | working | blocked | done | unknown
  status_since: string | null;
  task_id: string | null;
}

export interface TaskRow {
  task_id: string;
  run_id: string;
  label: string;
  project: string;
  repo: string;
  branch: string;
  state: string;
  stored_state: string | null;
  state_source: string | null;
  created_at: string;
  updated_at: string;
  completed_at: string | null;
  closure_reason: string | null;
  closure_proof: string | null;
  pane_id: string | null;
  agent_id: string | null;
  agent_live: boolean;
  has_result: boolean;
}

export interface BlockerRow {
  task_id: string | null;
  label: string | null;
  pane_id: string | null;
  agent_id: string | null;
  kind: string; // permission | stalled | blocked | input_required
  tool: string | null;
  summary: string | null; // redacted, bounded
  since: string | null;
}

export interface ResultDoc {
  task_id: string;
  source: string; // e.g. .handoffs/PROOF.md
  text: string; // redacted, bounded at the source
  sha256: string;
  source_mtime: string | null;
  truncated_at_source: boolean;
}

export interface DeliveryAck {
  message_id: string;
  outcome: "delivered" | "refused" | "failed" | "retry";
  detail: string;
}

export interface Snapshot {
  schema: number;
  generated_at: string;
  hub: HubSummary;
  agents: AgentRow[];
  tasks: TaskRow[];
  blockers: BlockerRow[];
}

export interface SyncBody {
  snapshot: Snapshot;
  results: ResultDoc[];
  acks: DeliveryAck[];
  audit_cursor: number;
  // false on the publisher's ack-only follow-up sync, whose outbox it never reads:
  // leasing there would mark messages "delivering" that nobody is delivering.
  lease: boolean;
}

export interface OutboxItem {
  message_id: string;
  task_id: string;
  pane_id: string;
  agent_id: string;
  label: string;
  text: string;
  actor: string;
  client_name: string;
  attempts: number;
}

// What a granted token carries (set at /authorize, encrypted by the provider).
export interface GrantProps {
  email: string;
  client_name: string;
  [key: string]: unknown;
}

export const SCOPE_READ = "herdr:read";
export const SCOPE_MESSAGE = "herdr:message";
