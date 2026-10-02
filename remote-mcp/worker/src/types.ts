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
  // "true" lets consent grant herdr:message and lets send_message run. Anything
  // else is a read-only server: the scope is never granted, the tool is never
  // listed, and tokens granted while it was on stop working for messages.
  MESSAGING_ENABLED: string;
  // "true" lets consent grant herdr:task.start/implement/cancel and lists
  // start_task/list_capabilities/get_task_answer/follow_up/cancel_task/
  // resume_task/list_events/wait_for_events. The Mac has its OWN switch
  // (HERDR_MCP_TASKS, publisher.py) reported each sync as
  // snapshot.task_config.mac_enabled: either off refuses a new start and
  // cancels everything still queued -- same two-switch shape as messaging.
  TASKS_ENABLED: string;
  INGEST_KEY: string; // secret: HMAC key shared with publisher.py
  BUILD_SHA: string; // commit deployed; "unstamped" when not deployed by provision.sh
}

// remote-mcp/task-allowlist.json, pushed verbatim each sync so the Worker can
// pre-validate a start_task call (repo, caps) before it ever reaches the Mac,
// and so list_capabilities can answer from the same source of truth the
// launch itself reads -- never a hand-duplicated table. The Mac's own copy of
// that file is what is actually enforced; this is a cache, not the ceiling.
export interface TaskModeConfig {
  job_class: string;
  secrets: "grant" | "default";
  git: "none" | "commit-only" | "push-own-branch";
  writes: string[];
  net_read: string[];
}
export interface TaskCaps {
  max_concurrent: number;
  max_per_day: number;
  max_minutes: number;
}
export interface TaskConfig {
  mac_enabled: boolean; // this sync's HERDR_MCP_TASKS switch state on the Mac
  repos: string[];
  modes: { research: TaskModeConfig; implement: TaskModeConfig };
  caps: TaskCaps;
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
  // Set once a herdr-mcp start_task/resume_task command actually spawned
  // this task (remote-mcp/tasks.py); empty/null for every task not started
  // remotely. verified/verify_detail are the Mac's own check of the client's
  // done condition against a FINISHED task -- never re-derived here.
  remote_task_id?: string | null;
  verified?: boolean | null;
  verify_detail?: string | null;
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
  // null until the Mac has synced at least once with HERDR_MCP_TASKS set;
  // absent entirely means this deployment predates the task config field
  // (an older publisher.py), which the Worker now actually treats the same
  // as null (both the zod schema and this type mark it optional).
  task_config?: TaskConfig | null;
}

export interface SyncBody {
  snapshot: Snapshot;
  results: ResultDoc[];
  acks: DeliveryAck[];
  // Outcomes of commands this sync's outbox leased on an earlier tick
  // (start/cancel/resume) -- same shape of idea as `acks` for messages, a
  // separate array because the two queues are independent and a command
  // outcome carries fields (local_task_id, branch, pane_id, a capability
  // probe) a message delivery ack never does.
  command_acks?: CommandAck[];
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

// Worker -> Mac directive: start/cancel/resume, leased like a message (the
// Mac polls for these via /ingest/sync's reply, acts, and reports the
// outcome back as a CommandAck on its next sync -- never a separate route,
// so the Mac never listens and the push model stays one-directional).
export type CommandOp = "start" | "cancel" | "resume";
export interface CommandItem {
  command_id: string;
  op: CommandOp;
  remote_task_id: string;
  // start: {repo, mode, objective}; cancel: {local_task_id, reason?};
  // resume: {local_task_id, local_run_id, branch, repo, text} -- everything
  // the Mac needs to re-enter the existing worktree without a second lookup.
  // Typed `object`, not `Record<string, unknown>`: the latter's `unknown`
  // value type breaks Cloudflare's RPC Stubify<T> discriminant narrowing on
  // SyncOutcome's `ok` field for every caller of stub.sync() (confirmed by
  // bisection -- swapping this one field's type is what flips it). The Mac
  // only ever reads this JSON-decoded, never indexes it generically here.
  payload: object;
}
export interface CommandAck {
  command_id: string;
  outcome: "accepted" | "refused" | "failed";
  detail: string;
  local_task_id?: string;
  local_run_id?: string;
  branch?: string;
  pane_id?: string;
  agent_id?: string;
  // Reported once, from start_task's own spawn: did this task's manifest
  // actually reach what it needs (e.g. {kb: true}) -- real, not assumed.
  capability_probe?: Record<string, boolean>;
}

// Who queued a message: the grant's user (email) and the OAuth client.
export interface Sender {
  actor: string;
  client_id: string;
}

// The Worker's grant check, handed to the DO's sync. `revoked`: senders whose
// grant no longer holds herdr:message. `hold`: the check could not run, so
// lease nothing this tick (messages stay queued until they expire).
export interface DeliveryGate {
  revoked: Sender[];
  hold: boolean;
}

// What a granted token carries (set at /authorize, encrypted by the provider).
export interface GrantProps {
  email: string;
  client_name: string;
  [key: string]: unknown;
}

export const SCOPE_READ = "herdr:read";
export const SCOPE_MESSAGE = "herdr:message";
export const SCOPE_TASK_START = "herdr:task.start";
export const SCOPE_TASK_IMPLEMENT = "herdr:task.implement";
export const SCOPE_TASK_CANCEL = "herdr:task.cancel";
