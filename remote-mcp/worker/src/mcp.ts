// The MCP surface: seven read tools (herdr:read) and send_message
// (herdr:message). Stateless Streamable HTTP: one server per request, bound to
// the caller's verified grant. No tool can run a command, press a key, answer
// an approval, or reach the Mac's local hub; the Worker only holds what the
// publisher pushed.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { CfWorkerJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/cfworker";
import { z } from "zod";
import { insufficientScope } from "@cloudflare/workers-oauth-provider";
import type { OAuthResourceAuth } from "@cloudflare/workers-oauth-provider";
import { messageable, MAX_MESSAGE_CHARS } from "./policy";
import type { Caller, View } from "./state";
import type { Env, GrantProps, TaskRow } from "./types";
import { SCOPE_MESSAGE, SCOPE_READ } from "./types";

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
        "Read-only view of Terrence's herdr agent fleet (tasks, agents, blockers, results), synced from his Mac every ~15s, " +
        "plus send_message to a live task's agent. Every response carries `connection`; when connection.state is " +
        "'disconnected' the data is the last known state, not live. Messages are delivered as a peer note, never as an " +
        "approval or command.",
    },
  );
  const stub = env.HERDR_STATE.get(env.HERDR_STATE.idFromName("fleet"));
  const now = () => Date.now();
  const canRead = scopes.includes(SCOPE_READ);

  // Every call is audited; reads without herdr:read are refused (the
  // provider's requiredScopes is advertised, not enforced).
  async function gate(tool: string, target: string): Promise<View | ToolResult> {
    if (!canRead) {
      await stub.recordToolCall(now(), caller, tool, target, "refused", "missing_scope herdr:read");
      return fail("insufficient_scope", "This token lacks herdr:read. Reconnect and grant it.");
    }
    await stub.recordToolCall(now(), caller, tool, target, "allowed", "");
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
    description: `A task's closure (reason, proof) and its written result (.handoffs/PROOF.md), redacted, paged by offset; max_chars <= ${MAX_RESULT_CHUNK}.`,
    inputSchema: {
      task_id: z.string().min(1).max(200),
      offset: z.number().int().min(0).default(0),
      max_chars: z.number().int().min(1).max(MAX_RESULT_CHUNK).default(4000),
    },
    annotations: ro,
  }, async ({ task_id, offset, max_chars }) => {
    const v = await gate("get_task_result", task_id);
    if (!isView(v)) return v;
    const t = v.snapshot?.tasks.find((x) => x.task_id === task_id);
    const r = await stub.result(task_id);
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
    const v = await gate("get_message_status", message_id);
    if (!isView(v)) return v;
    const m = await stub.messageStatus(message_id, caller.email);
    return m ? ok({ connection: v.connection, message: m }) : fail("not_found", "No message with that id was sent by you.");
  });

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
      const v = await stub.view(now());
      return fail(out.reason.split(" ")[0]!, `Refused: ${out.reason}.`, {
        connection: v.connection, ...(out.candidates ? { candidates: out.candidates } : {}),
      });
    }
    return ok({ message: out.message });
  });

  return server;
}

// apiHandler for OAuthProvider: ctx.props / ctx.auth come from the verified token.
export const mcpHandler = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const c = ctx as ExecutionContext & { props: GrantProps; auth: OAuthResourceAuth };
    const scopes = c.auth?.scope ?? [];
    if (!scopes.includes(SCOPE_READ) && !scopes.includes(SCOPE_MESSAGE)) {
      return insufficientScope(c.auth, [SCOPE_READ]);
    }
    const caller: Caller = { email: c.props.email, client_id: c.auth.clientId ?? "", client_name: c.props.client_name };
    const server = buildServer(env, caller, scopes);
    const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    await server.connect(transport);
    return transport.handleRequest(request);
  },
};
