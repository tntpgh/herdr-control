import { env, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { HerdrState } from "../src/state";
import type { Env } from "../src/types";
import { callTool, oauthToken, signedSync, snapshot, syncBody } from "./helpers";

const e = env as unknown as Env;
const fleet = () => e.HERDR_STATE.get(e.HERDR_STATE.idFromName("fleet"));

interface SyncReply {
  commands: { command_id: string; op: string; remote_task_id: string; payload: Record<string, unknown> }[];
  audit: { tool: string; decision: string; reason: string }[];
}
const syncJson = async (r: Response): Promise<SyncReply> => r.json();

// Result shapes for the new tools, so test code reads a typed field instead
// of inline-casting the generic Record<string, unknown> callTool returns
// (ts-no-inline-cast-access) -- same pattern flow.test.ts already uses for
// send_message's MessageRecord.
interface StartTaskResult { task_id: string; state: string }
interface CancelTaskResult { task_id: string; state: string }
interface ResumeTaskResult { task_id: string; parent_task_id: string; state: string }
interface AnswerResult { state: string; local_task: unknown }
interface EventsResult { cursor: number; events: unknown[] }

const CAPS = { max_concurrent: 1, max_per_day: 10, max_minutes: 60 };
const MODE = { job_class: "research", secrets: "grant" as const, git: "none" as const, writes: [], net_read: [] };
const TASK_CONFIG = {
  mac_enabled: true, repos: ["knowledge-base"], caps: CAPS,
  modes: { research: MODE, implement: { ...MODE, job_class: "implement", secrets: "default" as const, git: "push-own-branch" as const } },
};
const taskConfigBody = (overrides: Partial<typeof TASK_CONFIG> = {}) =>
  syncBody({ snapshot: snapshot({ task_config: { ...TASK_CONFIG, ...overrides } }) });

// A local task row for a task the Mac has reported as spawned/finished, to
// merge into snapshot.tasks so get_task_answer's local_task/verified can be
// exercised -- the shape mirrors helpers.ts's own internal snapshot() task().
function taskRow(id: string, remoteTaskId: string | null, overrides: Record<string, unknown> = {}) {
  const now = new Date().toISOString();
  return {
    task_id: id, run_id: `run_${id}`, label: `remote/${id}`, project: "knowledge-base", repo: "knowledge-base",
    branch: `remote/${id}`, state: "completed", stored_state: "completed", state_source: "live",
    created_at: now, updated_at: now, completed_at: now, closure_reason: "no-follow-on", closure_proof: null,
    pane_id: null, agent_id: null, agent_live: false, has_result: true,
    remote_task_id: remoteTaskId, verified: null, verify_detail: null,
    ...overrides,
  };
}

// get_task_answer's local_task is `unknown` (Record<string, unknown> field);
// narrow with `in` rather than an inline cast (ts-no-inline-cast-access).
function isVerifiedTask(x: unknown): x is { verified: boolean; verify_detail: string } {
  return !!x && typeof x === "object" && "verified" in x && "verify_detail" in x;
}

beforeEach(() => reset());

describe("list_capabilities", () => {
  it("answers null/false before any sync has carried a task_config", async () => {
    const { access_token } = await oauthToken(["herdr:read"]);
    const r = await callTool(access_token, "list_capabilities");
    expect([r.data.mac_enabled, r.data.repos, r.data.modes, r.data.caps]).toEqual([false, [], null, null]);
  });

  it("echoes the Mac's own synced allowlist/caps, never a hand-duplicated table", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read"]);
    const r = await callTool(access_token, "list_capabilities");
    expect([r.data.mac_enabled, r.data.repos, r.data.caps]).toEqual([true, ["knowledge-base"], CAPS]);
    expect(r.data.tasks_enabled).toBe(true);
  });
});

describe("start_task: scope gating", () => {
  it("does not offer start_task to a read-only token (neither task scope granted)", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read"]);
    const r = await callTool(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    expect(r.isError).toBe(true);
  });

  it("herdr:task.start alone cannot start an implement-mode task", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const r = await callTool(access_token, "start_task", { repo: "knowledge-base", mode: "implement", objective: "x" });
    expect([r.isError, r.data.error]).toEqual([true, "insufficient_scope"]);
  });

  it("herdr:task.implement alone cannot start a research-mode task", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.implement"]);
    const r = await callTool(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    expect([r.isError, r.data.error]).toEqual([true, "insufficient_scope"]);
  });
});

describe("start_task: refusals", () => {
  it("refuses while disconnected (stale sync)", async () => {
    await signedSync(taskConfigBody());
    const out = await runInDurableObject(fleet(), (o: HerdrState) =>
      o.startTask(Date.now() + 120_000, { email: "tnt@teamthurber.com", client_id: "c", client_name: "Zero" },
        ["herdr:task.start"], "knowledge-base", "research", "x"));
    expect(out).toMatchObject({ ok: false, reason: "not_connected (disconnected)" });
  });

  it("refuses a repo off the Mac's allowlist", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const r = await callTool(access_token, "start_task", { repo: "not-a-repo", mode: "research", objective: "x" });
    expect(r.data.error).toBe("repo_not_allowed");
  });

  it("refuses while tasks are off on the Mac even if TASKS_ENABLED is true here", async () => {
    await signedSync(taskConfigBody({ mac_enabled: false }));
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const r = await callTool(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    expect(r.data.error).toBe("tasks_disabled_on_mac");
  });

  it("refuses the Nth concurrent start past the Mac's own cap (max_concurrent=1 here)", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const first = await callTool(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "one" });
    expect(first.isError).toBe(false);
    const second = await callTool(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "two" });
    expect(second.data.error).toBe("too_many_concurrent");
  });

  it("sanitizes the objective before it is ever stored (no @, no brackets)", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const r = await callTool<StartTaskResult>(access_token, "start_task",
      { repo: "knowledge-base", mode: "research", objective: "find [X] and tell @owner about it" });
    const stored = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(r.data.task_id));
    expect(stored?.objective).not.toContain("[");
    expect(stored?.objective).not.toContain("]");
    expect(stored?.objective).not.toContain("@owner");
    expect(stored?.objective).toContain("\uff20owner");
  });
});

describe("start_task: happy path through to get_task_answer", () => {
  it("queues a start command, the Mac's ack moves it to running, and the local task's `verified` surfaces", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(access_token, "start_task",
      { repo: "knowledge-base", mode: "research", objective: "find X" });
    const remoteTaskId = started.data.task_id;
    expect(started.data.state).toBe("queued");

    const leased = await syncJson(await signedSync(taskConfigBody()));
    const cmd = leased.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "start");
    expect(cmd).toBeTruthy();
    expect(cmd!.payload).toMatchObject({ repo: "knowledge-base", mode: "research" });

    await signedSync(syncBody({
      lease: false,
      command_acks: [{ command_id: cmd!.command_id, outcome: "accepted", detail: "spawned",
        local_task_id: "task_V", local_run_id: "run_V", branch: "remote/abc123", pane_id: "w1:term_v", agent_id: "term_v",
        capability_probe: { secrets_granted: true, kb_reachable: true } }],
    }));
    const running = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect([running?.state, running?.local_task_id, running?.branch, running?.capability_probe])
      .toEqual(["running", "task_V", "remote/abc123", { secrets_granted: true, kb_reachable: true }]);

    // The Mac's next tick reports the task finished and verified (research:
    // ANSWER.md had a source link) -- the remap in sync() should carry that
    // straight through to get_task_answer's local_task.
    const withLocalTask = snapshot({
      task_config: TASK_CONFIG,
      tasks: [...snapshot().tasks, taskRow("task_V", remoteTaskId, { verified: true, verify_detail: "ANSWER.md has a source link" })],
    });
    await signedSync(syncBody({ snapshot: withLocalTask }));

    const answer = await callTool<AnswerResult>(access_token, "get_task_answer", { task_id: remoteTaskId });
    expect(answer.data.state).toBe("verified");
    const localTask = answer.data.local_task;
    if (!isVerifiedTask(localTask)) throw new Error(`expected local_task with verified/verify_detail, got ${JSON.stringify(localTask)}`);
    expect(localTask.verified).toBe(true);
    expect(localTask.verify_detail).toBe("ANSWER.md has a source link");
  });
});

describe("cancel_task / resume_task", () => {
  it("cancels a never-spawned task locally, with no command needed, and refuses it again (already terminal)", async () => {
    await signedSync(taskConfigBody());
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;

    const { access_token: cancelTok } = await oauthToken(["herdr:read", "herdr:task.cancel"]);
    const cancelled = await callTool<CancelTaskResult>(cancelTok, "cancel_task", { task_id: remoteTaskId });
    expect(cancelled.data.state).toBe("cancelled");

    const again = await callTool(cancelTok, "cancel_task", { task_id: remoteTaskId });
    expect(again.data.error).toBe("already_terminal");

    // The queued start command must not reach the Mac on the next lease.
    const leased = await syncJson(await signedSync(taskConfigBody()));
    expect(leased.commands.find((c) => c.remote_task_id === remoteTaskId)).toBeUndefined();
  });

  it("does not offer cancel_task to a token without herdr:task.cancel", async () => {
    await signedSync(taskConfigBody());
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const { access_token: readOnly } = await oauthToken(["herdr:read"]);
    const r = await callTool(readOnly, "cancel_task", { task_id: started.data.task_id });
    expect(r.isError).toBe(true);
  });

  it("queues a cancel command for an already-running task, acked to a terminal cancelled state", async () => {
    await signedSync(taskConfigBody());
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_V2", local_run_id: "run_V2", branch: "remote/def456",
      pane_id: "w1:term_v2", agent_id: "term_v2", capability_probe: { secrets_granted: true } }] }));

    const { access_token: cancelTok } = await oauthToken(["herdr:read", "herdr:task.cancel"]);
    const cancelled = await callTool<CancelTaskResult>(cancelTok, "cancel_task", { task_id: remoteTaskId });
    expect(cancelled.data.state).toBe("cancelling");

    const leased2 = await syncJson(await signedSync(taskConfigBody()));
    const cancelCmd = leased2.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "cancel")!;
    expect(cancelCmd.payload).toMatchObject({ local_task_id: "task_V2" });
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: cancelCmd.command_id, outcome: "accepted", detail: "cancelled (canceled)" }] }));
    const final = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(final?.state).toBe("cancelled");
  });

  it("auto-cancels (timed_out) a task that outran max_minutes, queuing a cancel command", async () => {
    const cfg = { caps: { ...CAPS, max_minutes: 1 } };
    await signedSync(taskConfigBody(cfg));
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody(cfg)));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_V3", local_run_id: "run_V3", branch: "remote/t3",
      pane_id: "w1:term_v3", agent_id: "term_v3", capability_probe: {} }] }));

    // Fast-forward past max_minutes by driving sync() with a later nowMs
    // directly (no real clock wait): created_at was stamped at "now", so a
    // sync far enough in the future must see it as overrun.
    const future = Date.now() + 2 * 60_000;
    const body = JSON.stringify(taskConfigBody(cfg));
    const out = await runInDurableObject(fleet(), (o: HerdrState) =>
      o.sync(future, crypto.randomUUID(), body, { revoked: [], hold: false }, { revoked: [], hold: false }));
    expect(out.ok).toBe(true);
    const row = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(row?.state).toBe("timed_out");
    if (out.ok) expect(out.response.commands.some((c) => c.remote_task_id === remoteTaskId && c.op === "cancel")).toBe(true);
  });

  it("refuses resume_task on a non-terminal task, then on the same task once cancelled before it ever spawned", async () => {
    await signedSync(taskConfigBody());
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const { access_token: cancelTok } = await oauthToken(["herdr:read", "herdr:task.cancel"]);
    const notTerminal = await callTool(cancelTok, "resume_task", { task_id: started.data.task_id });
    expect(notTerminal.data.error).toBe("not_terminal");

    const cancelled = await callTool<CancelTaskResult>(cancelTok, "cancel_task", { task_id: started.data.task_id });
    expect(cancelled.data.state).toBe("cancelled");
    const neverStarted = await callTool(cancelTok, "resume_task", { task_id: started.data.task_id });
    expect(neverStarted.data.error).toBe("never_started");
  });

  it("resumes a terminal, previously-spawned task into a brand new task_id linked via parent_task_id", async () => {
    await signedSync(taskConfigBody());
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_V4", local_run_id: "run_V4", branch: "remote/t4",
      pane_id: "w1:term_v4", agent_id: "term_v4", capability_probe: {} }] }));
    await signedSync(syncBody({ snapshot: snapshot({ task_config: TASK_CONFIG,
      tasks: [...snapshot().tasks, taskRow("task_V4", remoteTaskId, { closure_reason: "no-follow-on" })] }) }));
    const beforeResume = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(beforeResume?.state).toBe("finished");

    const { access_token: cancelTok } = await oauthToken(["herdr:read", "herdr:task.cancel"]);
    const resumed = await callTool<ResumeTaskResult>(cancelTok, "resume_task", { task_id: remoteTaskId, text: "one more thing" });
    expect(resumed.isError).toBe(false);
    expect(resumed.data.parent_task_id).toBe(remoteTaskId);
    expect(resumed.data.task_id).not.toBe(remoteTaskId);
    const leased2 = await syncJson(await signedSync(taskConfigBody()));
    const resumeCmd = leased2.commands.find((c) => c.op === "resume" && c.remote_task_id === resumed.data.task_id);
    expect(resumeCmd?.payload).toMatchObject({ local_task_id: "task_V4", branch: "remote/t4", repo: "knowledge-base" });
  });
});

describe("follow_up", () => {
  it("refuses a remote task that was never actually spawned", async () => {
    await signedSync(taskConfigBody());
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const { access_token: msgTok } = await oauthToken(["herdr:read", "herdr:message"]);
    const r = await callTool(msgTok, "follow_up", { task_id: started.data.task_id, text: "hi" });
    expect(r.data.error).toBe("not_found");
  });

  it("delegates to send_message once a local task is live", async () => {
    const customSnapshot = snapshot({ task_config: TASK_CONFIG });
    await signedSync(syncBody({ snapshot: customSnapshot }));
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    // local_task_id "task_A" is already present in helpers.ts's snapshot() as
    // a live, messageable task -- reuse it rather than inventing a new row.
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_A", local_run_id: "run_A", branch: "remote/t5",
      pane_id: "w1:term_a", agent_id: "term_a", capability_probe: {} }] }));
    await signedSync(syncBody({ snapshot: customSnapshot }));
    const { access_token: msgTok } = await oauthToken(["herdr:read", "herdr:message"]);
    const r = await callTool(msgTok, "follow_up", { task_id: remoteTaskId, text: "one more thing" });
    expect(r.isError).toBe(false);
  });
});

describe("events", () => {
  it("list_events is a monotonic cursor feed", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    await callTool(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const first = await callTool<EventsResult>(access_token, "list_events", { since_cursor: 0 });
    expect(first.data.events.length).toBeGreaterThan(0);
    const second = await callTool<EventsResult>(access_token, "list_events", { since_cursor: first.data.cursor });
    expect(second.data.events).toEqual([]);
  });

  it("wait_for_events returns immediately when an event is already pending since cursor", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    await callTool(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const r = await callTool<EventsResult>(access_token, "wait_for_events", { since_cursor: 0, timeout_s: 20 });
    expect(r.data.events.length).toBeGreaterThan(0);
  });

  it("wait_for_events times out with no events when nothing new happens", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read"]);
    const current = await callTool<EventsResult>(access_token, "list_events", { since_cursor: 0 });
    const started = Date.now();
    const r = await callTool<EventsResult>(access_token, "wait_for_events", { since_cursor: current.data.cursor, timeout_s: 1 });
    expect(r.data.events).toEqual([]);
    expect(Date.now() - started).toBeGreaterThanOrEqual(900);
  });
});

describe("per-connection revocation stops queued starts (SPEC item 6)", () => {
  it("cancels a queued start command once the starting connection's grant is revoked", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const grants = await e.OAUTH_KV.list({ prefix: "grant:tnt@teamthurber.com:" });
    expect(grants.keys.length).toBeGreaterThan(0);
    for (const k of grants.keys) await e.OAUTH_KV.delete(k.name);

    const leased = await syncJson(await signedSync(taskConfigBody()));
    expect(leased.commands.find((c) => c.remote_task_id === remoteTaskId)).toBeUndefined();
    const row = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(row?.state).toBe("cancelled");
  });
});
