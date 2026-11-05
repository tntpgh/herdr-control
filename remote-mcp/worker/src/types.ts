import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import type { HerdrState } from "./state";

// Wire contract between publisher.py (the Mac) and this Worker. Bump SCHEMA
// on any breaking change; the Worker refuses snapshots it does not understand.
export const SNAPSHOT_SCHEMA = 1;

export interface Env {
  OAUTH_KV: KVNamespace;
  HERDR_STATE: DurableObjectNamespace<HerdrState>;
  OAUTH_PROVIDER: OAuthHelpers;
  // The canonical origin: https://bebop.teamthurber.com. Issuer, resource
  // and metadata URLs follow the request's host (index.ts serves one OAuth
  // provider per origin), so this is the name clients are told to use.
  PUBLIC_URL: string;
  // Comma-separated extra origins served during a hostname cutover (empty
  // since the herdr-mcp alias was dropped). Tokens are bound to the origin
  // that issued them, so a client keeps working on its old host until it
  // reconnects at PUBLIC_URL. Any other host is refused.
  ALIAS_URLS?: string;
  // "true" maps herdr:* scopes on tokens granted before the fm:* cutover to
  // their fm:* equivalents (policy.ts LEGACY_SCOPE_MAP); anything else honors
  // fm:* only. Off since every client re-consented at bebop.
  LEGACY_HERDR_SCOPES?: string;
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
  // "true" lets consent grant herdr:message.owner and lists send_owner_message/
  // get_owner_message_status/get_owner_reply. A separate route from
  // herdr:message: it targets a NAMED long-lived owning session (conductor,
  // dedicated tab), never a task's agent, writes the body to a FILE on the
  // Mac (never types it into a pane), and carries its own, lower rate limit.
  // Same all-or-nothing shape as the other two switches: off hides the scope
  // and tool, and the Durable Object refuses even a token granted while it
  // was on. The Mac has its own switch, HERDR_MCP_OWNER_INBOX, set only by
  // install.sh --remote-mcp-owner-inbox.
  OWNER_INBOX_ENABLED: string;
  // Build-only: durable event checkpoints. Only literal "true" registers
  // the tools; the Durable Object checks the switch again on every call.
  EVENT_CONSUMERS_ENABLED?: string;
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
  // Start/resume require a receiver that verifies and durably binds the
  // command receipt before launch. Missing/other versions fail closed.
  authorization_protocol?: number;
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

// The Mac's real Chrome (chrome-relay.py): the browser Zero's ChatGPT
// extension and omp's browser relay both live in. Enums and counts only.
export type ExtensionState = "enabled" | "disabled" | "missing" | "unknown"; // unknown: unreadable from launchd
export interface BrowserSummary {
  checked_at: string;
  real_chrome_running: boolean;
  relay: string; // connected | no-extension | down (no omp session has started it)
  extensions: { omp_relay: ExtensionState; "1password": ExtensionState; chatgpt: ExtensionState };
  stray_omp_chromes: number;
  healthy: boolean;
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
  // research-task-closure defect 3: has_result is PROOF.md's mere
  // existence (created empty alongside every task's SPEC.md); has_answer
  // is the narrower signal answer_ready actually needs -- ANSWER.md
  // present AND non-empty. Optional: a publisher that predates this field
  // sends neither, which must degrade to "no answer_ready" rather than a
  // validation failure.
  has_answer?: boolean;
  // Set once a herdr-mcp start_task/resume_task command actually spawned
  // this task (remote-mcp/tasks.py); empty/null for every task not started
  // remotely. verified/verify_detail are the Mac's own check of the client's
  // done condition against a FINISHED task -- never re-derived here.
  remote_task_id?: string | null;
  verified?: boolean | null;
  verify_detail?: string | null;
  // Firstmate's own typed fields (fm_publisher.py). pr_url is the task's PR,
  // never a path; kind is scout|ship|...; yolo is whether the task runs
  // without per-command approval. All optional: an older publisher sends none.
  pr_url?: string | null;
  kind?: string | null;
  mode?: string | null;
  yolo?: boolean | null;
}

// Firstmate's attention posture, from fm-inbox.sh ready. present: the
// captain is attended and Firstmate answers live; away/quiet: notes queue
// and wait; unknown: the Mac could not read it this tick.
export type FirstmatePosture = "present" | "away" | "quiet" | "unknown";
export interface FirstmateSummary {
  posture: FirstmatePosture;
  can_receive: boolean;
  observed_at: string | null;
}

export interface DecisionOption {
  key: string;
  text: string;
  recommended: boolean;
}
export interface DecisionCall {
  call: string;
  text: string;
  options: DecisionOption[];
  recommendation: string | null;
}
// A captain hold: a question only the captain answers. answer_decision
// records a NOTE about one for Firstmate; nothing here is ever resolved
// remotely.
export interface DecisionRow {
  task_id: string;
  title: string;
  repo: string | null;
  question: string;
  calls: DecisionCall[];
  recommendation: string | null;
  bucket: string | null;
  since: string | null;
  age_days: number | null;
  origin: string | null;
  report_id: string | null;
}

// One scout/ship report Firstmate published; the body is a ResultDoc with
// task_id=report_id and source "report.md". Never a path.
export interface ReportRow {
  report_id: string;
  kind: string;
  title: string | null;
  task_id: string | null;
  updated_at: string | null;
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
  // null when the Mac could not read it this tick; absent from an older publisher.
  browser?: BrowserSummary | null;
  // The owner registry (register-owner.sh), label + a liveness bool ONLY --
  // never the pane id or a path (README "What leaves the Mac"). Absent/null
  // means no owner is registered, or an older publisher: send_owner_message
  // then refuses every target with owner_not_registered.
  owners?: { label: string; live: boolean }[] | null;
  // Firstmate-only blocks (fm_publisher.py); absent from an older publisher.
  firstmate?: FirstmateSummary | null;
  decisions?: DecisionRow[] | null;
  reports?: ReportRow[] | null;
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
  // Outcomes of this sync's owner_outbox leased on an earlier tick -- same
  // idea as acks/command_acks, a separate array because send_owner_message's
  // queue is independent (its own table, its own rate limit) and an ack here
  // is always "delivered" or "blocked:<reason>", never "refused"/"failed"
  // (SPEC: explicit blocked:<reason> states, never a silent fallback).
  owner_acks?: OwnerAck[];
  // A reply the owner wrote to ~/.local/state/herdr/inbox/<label>/replies/
  // <exchange_id>.md, picked up and reported once. owner_label/session are
  // the Mac's OWN knowledge of who this reply came from (the registration's
  // directory/session), never trusted from the file's own claimed header.
  owner_replies?: OwnerReplySync[];
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

// Worker -> Mac: one owner message leased for delivery. The publisher writes
// `body` to ~/.local/state/herdr/inbox/<owner_label>/messages/<exchange_id>.md
// (never typed into a pane) and delivers only the fixed notice text itself.
export interface OwnerOutboxItem {
  exchange_id: string;
  owner_label: string;
  client_msg_id: string;
  body: string;
  sender: string; // the validated grant email, never free text
  // The verified OAuth client_id that authenticated this call (caller.client_id,
  // set server-side from the resource token -- never from client_name, which is
  // self-declared at DCR registration and never trustworthy as an identity).
  // Distinguishes two connections under the SAME sender email (e.g. duet vs.
  // zero), which client_name alone cannot: any client can claim any client_name.
  sender_client: string;
  client_name: string;
  attempts: number;
  // What this note is. message: free text; task_request: a request that
  // Firstmate run a task (meta: project, task_kind, objective); decision_note:
  // a remote note about a captain hold (meta: task_id). Every kind is a note
  // Firstmate judges -- none is ever auto-actioned or the captain's word.
  kind: OwnerNoteKind;
  meta: Record<string, string>;
  // The Worker's own label for sender_client (policy.ts CLIENT_GRANTS), or
  // "unknown". The publisher prefers it over its local labels file.
  sender_label: string;
}

export type OwnerNoteKind = "message" | "task_request" | "decision_note";

export interface OwnerAck {
  exchange_id: string;
  outcome: "delivered" | "blocked";
  // One of the SPEC blocked states (owner_not_registered, owner_pane_gone,
  // owner_identity_changed, owner_at_approval_prompt, deliver_failed:<rc>);
  // required when outcome is "blocked", ignored otherwise.
  reason?: string;
}

export interface OwnerReplySync {
  exchange_id: string;
  owner_label: string; // the Mac's own registration directory, never file-claimed
  body: string;
  responded_at: string;
  artifact_revision: string;
  session: string; // the registration's live agent_session, as recorded by the Mac
}

// Worker -> Mac directive: start/cancel/resume, leased like a message (the
// Mac polls for these via /ingest/sync's reply, acts, and reports the
// outcome back as a CommandAck on its next sync -- never a separate route,
// so the Mac never listens and the push model stays one-directional).
export type CommandOp = "start" | "cancel" | "resume";
export interface CommandAuthorization {
  // Recursively key-sorted, compact UTF-8 JSON, signed exactly as sent.
  // This proves the existing OAuth task delegation, never a human's
  // exact-command approval or a decision by the assigned supervisor.
  claims: string;
  signature: string;
}
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
  authorization?: CommandAuthorization;
}
export interface CommandAck {
  command_id: string;
  // held is an unfinished/uncertain start or resume, never an approval or
  // successful launch. It must not retire the command or discard mapping.
  outcome: "accepted" | "refused" | "failed" | "held";
  detail: string;
  local_task_id?: string;
  local_run_id?: string;
  branch?: string;
  pane_id?: string;
  agent_id?: string;
  // Reported once, from start_task's own spawn: did this task's manifest
  // actually reach what it needs (e.g. {kb: true}) -- real, not assumed.
  capability_probe?: Record<string, boolean>;
  // Receipt-to-ack recovery (dot-herdr-recovery-slices.md §3): present only
  // when the Mac sourced this ack from the registry's durable
  // revision/acked_revision CAS (either the live path or pending_acks()
  // recovery), never invented by the Worker. Echoed back verbatim in
  // SyncResponse.command_ack_results so the Mac can CAS-confirm the EXACT
  // revision it sent, never a guessed or stale one.
  revision?: number;
}

// Who queued a message: the grant's user (email) and the OAuth client.
// `kind` narrows an owner-note revocation to the notes that needed a scope
// the sender no longer holds (absent: every note from that sender).
export interface Sender {
  actor: string;
  client_id: string;
  kind?: OwnerNoteKind;
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

// Firstmate scopes (Phase 2). Least privilege, one per kind of effect:
export const FM_READ = "fm:read"; // fleet status, tasks, decisions, posture, events
export const FM_REPORTS = "fm:reports"; // report and task-result bodies
export const FM_REQUEST = "fm:request"; // notes to Firstmate: messages, task requests
export const FM_DECIDE_NOTE = "fm:decide-note"; // notes about a captain decision
export const FM_PEER = "fm:peer"; // app-to-app peer notes
export const FM_SCOPES = [FM_READ, FM_REPORTS, FM_REQUEST, FM_DECIDE_NOTE, FM_PEER] as const;

// herdr-mcp scopes. Never offered any more: herdr:read and
// herdr:message.owner on tokens granted before the cutover map to fm:*
// while LEGACY_HERDR_SCOPES is on; the rest name dormant Durable Object
// paths (send_message, start_task) that Phase 3 removes.
export const SCOPE_READ = "herdr:read";
export const SCOPE_MESSAGE = "herdr:message";
export const SCOPE_TASK_START = "herdr:task.start";
export const SCOPE_TASK_IMPLEMENT = "herdr:task.implement";
export const SCOPE_TASK_CANCEL = "herdr:task.cancel";
export const SCOPE_OWNER_MESSAGE = "herdr:message.owner";
