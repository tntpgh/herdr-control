// The MCP surface: seven read tools (herdr:read) and send_message
// (herdr:message, listed only when the server has messaging on AND the token
// holds the scope). Stateless Streamable HTTP: one server per request, bound
// to the caller's verified grant. No tool can run a command, press a key,
// answer an approval, or reach the Mac's local hub; the Worker only holds
// what the publisher pushed.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { CfWorkerJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/cfworker";
import { z } from "zod";
import { insufficientScope } from "@cloudflare/workers-oauth-provider";
import type { OAuthResourceAuth } from "@cloudflare/workers-oauth-provider";
import { emailAllowed } from "./access";
import { messageable, MAX_MESSAGE_CHARS, offeredScopes, serverInfo } from "./policy";
import type { Caller, View } from "./state";
import type { Env, GrantProps, TaskRow } from "./types";
import { SCOPE_MESSAGE, SCOPE_READ, SCOPE_TASK_CANCEL, SCOPE_TASK_IMPLEMENT, SCOPE_TASK_START } from "./types";

export const SERVER_VERSION = "0.1.0";
const MAX_RESULT_CHUNK = 16_000;

const TERMINAL: Record<string, true> = { completed: true, cancelled: true, lost: true, gone: true, error: true };
const ATTENTION: Record<string, true> = { blocked: true, stalled: true };

type ToolResult = { content: { type: "text"; text: string }[]; structuredContent?: Record<string, unknown>; isError?: boolean };

function ok(data: Record<string, unknown>): ToolResult {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 1) }], structuredContent: data };
}

function fail(code: string, message: string, extra: Record<string, unknown> = {}): ToolResult {
  const data = { error: code, message, ...extra };
  return { content: [{ type: "text", text: JSON.stringify(data) }], structuredContent: data, isError: true };
}

function publicTask(t: TaskRow) {
  return { ...t, messageable: messageable(t) };
}

export function buildServer(env: Env, caller: Caller, scopes: string[]): McpServer {
  const server = new McpServer(
    { name: "herdr-mcp", version: SERVER_VERSION },
    {
      jsonSchemaValidator: new CfWorkerJsonSchemaValidator(),
      instructions:
        "Read-only view of Terrence's herdr agent fleet (tasks, agents, blockers, results), synced from his Mac every ~15s" +
        (scopes.includes(SCOPE_MESSAGE) ? ", plus send_message to a live task's agent (delivered as a peer note, never as an approval or command)" : "") +
        (scopes.includes(SCOPE_TASK_START) || scopes.includes(SCOPE_TASK_IMPLEMENT)
          ? ", plus start_task to spawn a sandboxed worker in an allow-listed repo (list_capabilities first)" : "") +
        ". Every response carries `connection`; when connection.state is 'disconnected' the data is the last known state, " +
        "not live. get_status is the cheap, harmless first call.",
    },
  );
  const stub = env.HERDR_STATE.get(env.HERDR_STATE.idFromName("fleet"));
  const now = () => Date.now();
  const canRead = scopes.includes(SCOPE_READ);

  // Every call is throttled and audited in the DO before it runs. `needs` is
  // the set of scopes any one of which admits the call (the provider's
  // requiredScopes is advertised, not enforced).
  async function gate(tool: string, target: string, needs: string[] = [SCOPE_READ]): Promise<View | ToolResult> {
    const scopeRefusal = needs.some((s) => scopes.includes(s)) ? null : `missing_scope ${needs.join("|")}`;
    const refused = await stub.admitToolCall(now(), caller, tool, target, scopeRefusal);
    if (refused) {
      return refused.startsWith("rate_limited")
        ? fail("rate_limited", `Refused: ${refused}. Slow down; the fleet only changes every ~15s.`)
        : fail("insufficient_scope", `This token lacks ${needs.join(" or ")}. Reconnect and grant it.`);
    }
    return stub.view(now());
  }
  const isView = (v: View | ToolResult): v is View => "connection" in v;

  const ro = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };

  server.registerTool("get_status", {
    title: "Fleet connection and summary",
    description: "Connection state (connected | degraded | disconnected | never_connected) with last sync time, plus fleet counts.",
    inputSchema: {},
    annotations: ro,
  }, async () => {
    const v = await gate("get_status", "");
    if (!isView(v)) return v;
    const s = v.snapshot;
    const tasks = s?.tasks ?? [];
    return ok({
      connection: v.connection,
      as_of: s?.generated_at ?? null,
      counts: s ? {
        agents: s.agents.length,
        agents_by_status: s.agents.reduce<Record<string, number>>((a, x) => ({ ...a, [x.status]: (a[x.status] ?? 0) + 1 }), {}),
        tasks_active: tasks.filter((t) => !TERMINAL[t.state]).length,
        tasks_needing_attention: tasks.filter((t) => ATTENTION[t.state]).length,
        blockers: s.blockers.length,
        open_decisions: s.hub.open_decisions,
        handoff_debt: s.hub.handoff_debt,
      } : null,
      your_scopes: scopes,
      server: serverInfo(env),
      // Present when messaging is on: the limits in force and how many of them
      // this user has used (all their clients together).
      message_limits: serverInfo(env).messaging_enabled
        ? { ...(await stub.messageLimits(now())), used: await stub.messagesUsed(now(), caller.email) } : null,
    });
  });

  server.registerTool("list_agents", {
    title: "List agents",
    description: "Every agent pane herdr knows about. agent_id is stable for the life of the pane's terminal; pane_id is a location that can be reused.",
    inputSchema: {
      status: z.enum(["idle", "working", "blocked", "done", "unknown"]).optional().describe("Only agents in this status."),
    },
    annotations: ro,
  }, async ({ status }) => {
    const v = await gate("list_agents", status ?? "");
    if (!isView(v)) return v;
    const agents = (v.snapshot?.agents ?? []).filter((a) => !status || a.status === status);
    return ok({ connection: v.connection, as_of: v.snapshot?.generated_at ?? null, agents });
  });

  server.registerTool("list_tasks", {
    title: "List tasks",
    description: "Registered herdr tasks, newest first. task_id is stable forever. filter: active (default; not terminal), attention (blocked or stalled), done (terminal), all.",
    inputSchema: {
      filter: z.enum(["active", "attention", "done", "all"]).default("active"),
      project: z.string().max(100).optional().describe("Exact project name, e.g. knowledge-base."),
      updated_since: z.string().max(40).optional().describe("ISO 8601; only tasks updated at or after this time."),
      limit: z.number().int().min(1).max(100).default(50),
    },
    annotations: ro,
  }, async ({ filter, project, updated_since, limit }) => {
    const v = await gate("list_tasks", `${filter}${project ? `:${project}` : ""}`);
    if (!isView(v)) return v;
    const since = updated_since ? Date.parse(updated_since) : NaN;
    if (updated_since && Number.isNaN(since)) return fail("bad_argument", "updated_since is not an ISO 8601 time.");
    const rows = (v.snapshot?.tasks ?? [])
      .filter((t) => filter === "all" || (filter === "active" ? !TERMINAL[t.state] : filter === "done" ? TERMINAL[t.state] : ATTENTION[t.state]))
      .filter((t) => !project || t.project === project)
      .filter((t) => Number.isNaN(since) || Date.parse(t.updated_at) >= since)
      .sort((a, b) => b.updated_at.localeCompare(a.updated_at));
    return ok({
      connection: v.connection, as_of: v.snapshot?.generated_at ?? null,
      total: rows.length, truncated: rows.length > limit, tasks: rows.slice(0, limit).map(publicTask),
      coverage: "Snapshot holds every non-terminal task plus terminal tasks updated in the last 14 days.",
    });
  });

  server.registerTool("get_task", {
    title: "Get one task",
    description: "Status of one task by task_id, with its agent and current blockers.",
    inputSchema: { task_id: z.string().min(1).max(200) },
    annotations: ro,
  }, async ({ task_id }) => {
    const v = await gate("get_task", task_id);
    if (!isView(v)) return v;
    const t = v.snapshot?.tasks.find((x) => x.task_id === task_id);
    if (!t) return fail("not_found", "No such task in the current snapshot.", { connection: v.connection });
    return ok({
      connection: v.connection, as_of: v.snapshot!.generated_at, task: publicTask(t),
      agent: v.snapshot!.agents.find((a) => a.agent_id === t.agent_id) ?? null,
      blockers: v.snapshot!.blockers.filter((b) => b.task_id === t.task_id),
    });
  });

  server.registerTool("list_blockers", {
    title: "List blockers",
    description: "What is holding agents up right now: permission prompts, stalls, blocked tasks. summary is redacted and truncated. Read-only: there is deliberately no way to answer an approval from here.",
    inputSchema: {},
    annotations: ro,
  }, async () => {
    const v = await gate("list_blockers", "");
    if (!isView(v)) return v;
    return ok({ connection: v.connection, as_of: v.snapshot?.generated_at ?? null, blockers: v.snapshot?.blockers ?? [] });
  });

  server.registerTool("get_task_result", {
    title: "Get a task's result",
    description: `A task's closure (reason, proof) and one of its written documents, redacted, paged by offset; ` +
      `max_chars <= ${MAX_RESULT_CHUNK}. path defaults to .handoffs/PROOF.md; a remote task's answer is ` +
      `.handoffs/ANSWER.md (get_task_answer's "artifacts" lists every path actually synced for a task).`,
    inputSchema: {
      task_id: z.string().min(1).max(200),
      path: z.string().min(1).max(200).default(".handoffs/PROOF.md"),
      offset: z.number().int().min(0).default(0),
      max_chars: z.number().int().min(1).max(MAX_RESULT_CHUNK).default(4000),
    },
    annotations: ro,
  }, async ({ task_id, path, offset, max_chars }) => {
    const v = await gate("get_task_result", task_id);
    if (!isView(v)) return v;
    const t = v.snapshot?.tasks.find((x) => x.task_id === task_id);
    const r = await stub.result(task_id, path);
    if (!t && !r) return fail("not_found", "No such task.", { connection: v.connection });
    const text = r?.text ?? "";
    const chunk = text.slice(offset, offset + max_chars);
    const next = offset + chunk.length < text.length ? offset + chunk.length : null;
    return ok({
      connection: v.connection, task_id, state: t?.state ?? null, completed_at: t?.completed_at ?? null,
      closure_reason: t?.closure_reason ?? null, closure_proof: t?.closure_proof ?? null,
      result: r ? {
        source: r.source, sha256: r.sha256, source_mtime: r.source_mtime, synced_at: r.synced_at,
        total_chars: text.length, offset, returned_chars: chunk.length, next_offset: next,
        truncated_at_source: r.truncated_at_source, text: chunk,
        note: "The result file belongs to the task's worktree; a later task on the same branch can overwrite it (compare source_mtime with completed_at).",
      } : null,
    });
  });

  server.registerTool("get_message_status", {
    title: "Get message status",
    description: "Delivery status of a message you sent: queued | delivering | delivered | refused | failed | expired.",
    inputSchema: { message_id: z.string().min(1).max(100) },
    annotations: ro,
  }, async ({ message_id }) => {
    const v = await gate("get_message_status", message_id, [SCOPE_READ, SCOPE_MESSAGE]);
    if (!isView(v)) return v;
    const m = await stub.messageStatus(message_id, caller.email);
    return m ? ok({ connection: v.connection, message: m }) : fail("not_found", "No message with that id was sent by you.");
  });

  server.registerTool("list_capabilities", {
    title: "List task capabilities",
    description: "What start_task can do right now: allow-listed repos, each mode's git/secrets/write policy, and " +
      "today's caps (max_concurrent/max_per_day/max_minutes -- there is no separate $/token budget). Each task runs " +
      "in its own herdr pane via spawn-task.sh, under the same macOS user as every other session on that machine " +
      "(no separate OS user, container, or filesystem sandbox) -- isolation comes from its own git worktree/branch " +
      "and the Mac's own command-approval policy gating what it can run, not from the pane itself. Pre-flight " +
      "check before start_task; answers from the Mac's own tracked allowlist file (remote-mcp/task-allowlist.json), " +
      "never a hand-duplicated table.",
    inputSchema: {},
    annotations: ro,
  }, async () => {
    const v = await gate("list_capabilities", "");
    if (!isView(v)) return v;
    const cfg = v.snapshot?.task_config ?? null;
    return ok({
      connection: v.connection, tasks_enabled: serverInfo(env).tasks_enabled, mac_enabled: cfg?.mac_enabled ?? false,
      repos: cfg?.repos ?? [], modes: cfg?.modes ?? null, caps: cfg?.caps ?? null, your_scopes: scopes,
    });
  });

  server.registerTool("get_task_answer", {
    title: "Get a remote task's answer",
    description: "State, objective, progress (recent events), artifacts (every .handoffs/ file synced for it, with " +
      "size/sha256 -- fetch one with get_task_result's path argument), the omp session's latest assistant reply, and " +
      "(once answer_ready) the written answer, .handoffs/ANSWER.md. local_task.verified (and verified_kind: " +
      "source_link_present for research, pushed_sha_matches for implement) is a FORMAT/CLOSURE check the Mac ran " +
      "against the task's own completion claim -- never a semantic read of whether the answer is actually correct.",
    inputSchema: { task_id: z.string().min(1).max(100) },
    annotations: ro,
  }, async ({ task_id }) => {
    const v = await gate("get_task_answer", task_id);
    if (!isView(v)) return v;
    const rt = await stub.remoteTask(task_id);
    if (!rt) return fail("not_found", "No such remote task.", { connection: v.connection });
    const localTask = rt.local_task_id ? v.snapshot?.tasks.find((t) => t.task_id === rt.local_task_id) : undefined;
    const artifacts = rt.local_task_id
      ? (await stub.resultSources(rt.local_task_id)).filter((r) => r.source.startsWith(".handoffs/")) : [];
    const answer = rt.local_task_id ? await stub.result(rt.local_task_id, ".handoffs/ANSWER.md") : null;
    const reply = rt.local_task_id ? await stub.result(rt.local_task_id, "omp:transcript") : null;
    const progress = (await stub.taskEventLog(task_id, 50)).map((e) => ({ type: e.type, at: e.at, detail: e.detail }));
    return ok({
      connection: v.connection, task_id: rt.remote_task_id, state: rt.state, mode: rt.mode, repo: rt.repo,
      objective: rt.objective, created_at: rt.created_at, updated_at: rt.updated_at,
      parent_task_id: rt.parent_remote_task_id, capability_probe: rt.capability_probe,
      // Z3 (SPEC fix: Zero's review item 3): a static function of mode, not a
      // registry column -- what "verified" WOULD mean if/when it is true,
      // independent of the task's current state.
      verified_kind: rt.mode === "research" ? "source_link_present" : "pushed_sha_matches",
      local_task: localTask ? publicTask(localTask) : null, progress,
      artifacts: artifacts.map((a) => ({ path: a.source, size: a.size, sha256: a.sha256, synced_at: a.synced_at })),
      latest_reply: reply ? reply.text.slice(0, MAX_RESULT_CHUNK) : null,
      answer: answer ? {
        sha256: answer.sha256, synced_at: answer.synced_at, total_chars: answer.text.length,
        text: answer.text.slice(0, MAX_RESULT_CHUNK),
        note: answer.text.length > MAX_RESULT_CHUNK ? "Truncated; page the rest with get_task_result(path='.handoffs/ANSWER.md')." : "",
      } : null,
    });
  });

  server.registerTool("list_events", {
    title: "List task lifecycle events",
    description: "Global event feed across every remote task: task_started, state_changed, approval_needed, " +
      "capability_probe, answer_ready, finished, verified, failed, cancelled, timed_out, disconnected/reconnected. " +
      "since_cursor=0 for everything retained (30 days); cursor is monotonic and never reused.",
    inputSchema: { since_cursor: z.number().int().min(0).default(0), limit: z.number().int().min(1).max(500).default(100) },
    annotations: ro,
  }, async ({ since_cursor, limit }) => {
    const v = await gate("list_events", String(since_cursor));
    if (!isView(v)) return v;
    const { cursor, events } = await stub.listEvents(since_cursor, limit);
    return ok({
      connection: v.connection, cursor,
      events: events.map((e) => ({ cursor: e.cursor, task_id: e.remote_task_id || null, type: e.type, at: e.at, detail: e.detail })),
    });
  });

  server.registerTool("wait_for_events", {
    title: "Wait for a new task lifecycle event",
    description: "Holds the call open until a new event lands or timeout_s elapses, then returns whatever arrived " +
      "(possibly nothing). The closest thing to a push notification this server can give an MCP client -- true " +
      "server push is not possible over Streamable HTTP here, so poll this instead of list_events in a tight loop.",
    inputSchema: { since_cursor: z.number().int().min(0).default(0), timeout_s: z.number().int().min(1).max(25).default(20) },
    annotations: ro,
  }, async ({ since_cursor, timeout_s }) => {
    const v = await gate("wait_for_events", String(since_cursor));
    if (!isView(v)) return v;
    const { cursor, events } = await stub.waitForEvents(since_cursor, timeout_s);
    return ok({
      connection: v.connection, cursor,
      events: events.map((e) => ({ cursor: e.cursor, task_id: e.remote_task_id || null, type: e.type, at: e.at, detail: e.detail })),
    });
  });

  if (scopes.includes(SCOPE_MESSAGE)) {
    server.registerTool("send_message", {
      title: "Send a message to a task's agent",
      description:
        `Queue a one-line note (<= ${MAX_MESSAGE_CHARS} chars; newlines and control characters are collapsed) for the live agent ` +
        "working a task. target = task_id, agent_id, or the task's label. Only tasks with messageable=true accept messages; " +
        "the Mac must be connected. The agent receives it prefixed as a remote collaborator's note, not as an operator " +
        "instruction, and it is never typed into a permission prompt. Requires herdr:message. Poll get_message_status.",
      inputSchema: {
        target: z.string().min(1).max(200),
        text: z.string().min(1).max(MAX_MESSAGE_CHARS * 2),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    }, async ({ target, text }) => {
      const out = await stub.sendMessage(now(), caller, scopes, target, text);
      if (!out.ok) {
        // Fleet details (connection, candidate task ids) only for a token that may read them.
        const extra = canRead
          ? { connection: (await stub.view(now())).connection, ...(out.candidates ? { candidates: out.candidates } : {}) }
          : {};
        return fail(out.reason.split(" ")[0]!, `Refused: ${out.reason}.`, extra);
      }
      return ok({ message: out.message });
    });

    server.registerTool("follow_up", {
      title: "Send a follow-up note to a remote task",
      description: "= send_message, addressed by the remote task's task_id instead of a local task_id/label. " +
        "Refused if that remote task was never actually spawned (no live pane to message yet). Requires herdr:message.",
      inputSchema: { task_id: z.string().min(1).max(100), text: z.string().min(1).max(MAX_MESSAGE_CHARS * 2) },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    }, async ({ task_id, text }) => {
      const localId = await stub.remoteTaskLocalId(task_id);
      if (!localId) return fail("not_found", "That remote task was never spawned (no live pane to message).");
      const out = await stub.sendMessage(now(), caller, scopes, localId, text);
      if (!out.ok) {
        const extra = canRead
          ? { connection: (await stub.view(now())).connection, ...(out.candidates ? { candidates: out.candidates } : {}) }
          : {};
        return fail(out.reason.split(" ")[0]!, `Refused: ${out.reason}.`, extra);
      }
      return ok({ message: out.message });
    });
  }

  if (scopes.includes(SCOPE_TASK_START) || scopes.includes(SCOPE_TASK_IMPLEMENT)) {
    server.registerTool("start_task", {
      title: "Start a remote task",
      description: "Spawn a sandboxed worker in an allow-listed repo (list_capabilities shows which, and each mode's " +
        "policy). mode=research: no edit/write tools are registered at all (read/bash/grep/glob/todo/web_search/ask " +
        "only), no git push, runs with the read-only credential vault. mode=implement: commits and pushes its OWN " +
        "branch, never main, never deploys. " +
        "Capped (list_capabilities shows max_concurrent/max_per_day/max_minutes); a task that outruns max_minutes is " +
        "cancelled automatically. Returns task_id immediately in state queued, before the Mac has acted on it. " +
        "Poll get_task_answer, or list_events/wait_for_events.",
      inputSchema: {
        repo: z.string().min(1).max(100),
        mode: z.enum(["research", "implement"]),
        objective: z.string().min(1).max(4000),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    }, async ({ repo, mode, objective }) => {
      const needs = mode === "implement" ? [SCOPE_TASK_IMPLEMENT] : [SCOPE_TASK_START];
      const v = await gate("start_task", `${mode}:${repo}`, needs);
      if (!isView(v)) return v;
      const out = await stub.startTask(now(), caller, scopes, repo, mode, objective);
      if (!out.ok) return fail(out.reason.split(" ")[0]!, `Refused: ${out.reason}.`, { connection: v.connection });
      return ok({ connection: v.connection, task_id: out.remote_task_id, state: out.state });
    });
  }

  if (scopes.includes(SCOPE_TASK_CANCEL)) {
    server.registerTool("cancel_task", {
      title: "Cancel a remote task",
      description: "Cancel a remote task before it finishes. Refused (not a no-op) if it is already terminal " +
        "(finished/verified/failed/cancelled/lost/timed_out).",
      inputSchema: { task_id: z.string().min(1).max(100) },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
    }, async ({ task_id }) => {
      const v = await gate("cancel_task", task_id, [SCOPE_TASK_CANCEL]);
      if (!isView(v)) return v;
      const out = await stub.cancelTask(now(), caller, scopes, task_id);
      if (!out.ok) return fail(out.reason.split(" ")[0]!, `Refused: ${out.reason}.`, { connection: v.connection });
      return ok({ connection: v.connection, task_id, state: out.state });
    });

    server.registerTool("resume_task", {
      title: "Resume a finished remote task",
      description: "Re-enter the same repo/branch/worktree as a brand new remote task (new task_id, linked via " +
        "parent_task_id), optionally with a follow-up note. Only a terminal task can be resumed; the registry " +
        "forbids terminal -> running on the SAME task_id, which is why this always returns a new one.",
      inputSchema: { task_id: z.string().min(1).max(100), text: z.string().max(MAX_MESSAGE_CHARS * 2).optional() },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    }, async ({ task_id, text }) => {
      const v = await gate("resume_task", task_id, [SCOPE_TASK_CANCEL]);
      if (!isView(v)) return v;
      const out = await stub.resumeTask(now(), caller, scopes, task_id, text);
      if (!out.ok) return fail(out.reason.split(" ")[0]!, `Refused: ${out.reason}.`, { connection: v.connection });
      return ok({ connection: v.connection, task_id: out.remote_task_id, parent_task_id: out.parent_remote_task_id, state: out.state });
    });
  }

  return server;
}

// apiHandler for OAuthProvider: ctx.props / ctx.auth come from the verified token.
export const mcpHandler = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const c = ctx as ExecutionContext & { props: GrantProps; auth: OAuthResourceAuth };
    const caller: Caller = { email: c.props.email, client_id: c.auth?.clientId ?? "", client_name: c.props.client_name };
    // Refusals before the server is built are audited too (throttled like every call).
    const refuse = async (reason: string, res: Response) => {
      await env.HERDR_STATE.get(env.HERDR_STATE.idFromName("fleet")).recordRejectedCall(Date.now(), caller, "mcp", "", reason);
      return res;
    };
    // Re-checked on every request, so removing an email cuts off grants already issued.
    if (!emailAllowed(env, c.props.email)) {
      return refuse("access_revoked",
        Response.json({ error: "access_revoked", error_description: "This account is no longer allowed." }, { status: 403 }));
    }
    const offered = offeredScopes(env);
    const scopes = (c.auth?.scope ?? []).filter((s) => offered.includes(s));
    if (!scopes.includes(SCOPE_READ) && !scopes.includes(SCOPE_MESSAGE) && !scopes.includes(SCOPE_TASK_START)
        && !scopes.includes(SCOPE_TASK_IMPLEMENT) && !scopes.includes(SCOPE_TASK_CANCEL)) {
      return refuse("insufficient_scope", insufficientScope(c.auth, [SCOPE_READ]));
    }
    const calls = toolCalls(await request.clone().text());
    const server = buildServer(env, caller, scopes);
    const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    await server.connect(transport);
    const response = await transport.handleRequest(request);
    if (calls.size) await auditRejected(env, caller, calls, response.clone());
    return response;
  },
};

// tools/call requests in a JSON-RPC body, by id: what was asked for, for the audit.
function toolCalls(raw: string): Map<string | number, { tool: string; target: string }> {
  const calls = new Map<string | number, { tool: string; target: string }>();
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { return calls; }
  for (const m of Array.isArray(parsed) ? parsed : [parsed]) {
    if (!m || typeof m !== "object" || !("method" in m) || m.method !== "tools/call" || !("id" in m)) continue;
    const params = "params" in m && m.params && typeof m.params === "object" ? m.params : {};
    const tool = "name" in params && typeof params.name === "string" ? params.name.slice(0, 80) : "?";
    const args = "arguments" in params && params.arguments && typeof params.arguments === "object" ? params.arguments : {};
    const target = Object.values(args).find((v): v is string => typeof v === "string") ?? "";
    if (typeof m.id === "string" || typeof m.id === "number") calls.set(m.id, { tool, target: target.slice(0, 200) });
  }
  return calls;
}

// Every handler returns structuredContent and audits itself. A tools/call
// answered WITHOUT it was refused by the SDK before any handler ran (unknown
// tool, schema violation), so it is audited here instead.
async function auditRejected(env: Env, caller: Caller, calls: Map<string | number, { tool: string; target: string }>,
  response: Response): Promise<void> {
  let body: unknown;
  try { body = await response.json(); } catch { return; }
  const stub = env.HERDR_STATE.get(env.HERDR_STATE.idFromName("fleet"));
  for (const r of Array.isArray(body) ? body : [body]) {
    if (!r || typeof r !== "object" || !("id" in r) || (typeof r.id !== "string" && typeof r.id !== "number")) continue;
    const call = calls.get(r.id);
    if (!call) continue;
    const result = "result" in r && r.result && typeof r.result === "object" ? r.result : null;
    if (result && "structuredContent" in result) continue;
    const why = "error" in r && r.error && typeof r.error === "object" && "message" in r.error ? String(r.error.message)
      : result && "content" in result && Array.isArray(result.content) ? String(result.content[0]?.text ?? "") : "no result";
    await stub.recordRejectedCall(Date.now(), caller, call.tool, call.target, `rejected_before_handler: ${why.slice(0, 200)}`);
  }
}
