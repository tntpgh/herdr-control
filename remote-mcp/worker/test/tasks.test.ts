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
interface AnswerResult { state: string; local_task: unknown; verified_kind: string }
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
        capability_probe: { secrets_granted: true, kb_http_reachable: true } }],
    }));
    const running = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect([running?.state, running?.local_task_id, running?.branch, running?.capability_probe])
      .toEqual(["running", "task_V", "remote/abc123", { secrets_granted: true, kb_http_reachable: true }]);

    // The Mac's next tick reports the task finished and verified (research:
    // ANSWER.md had an https:// source link) -- the remap in sync() should
    // carry that straight through to get_task_answer's local_task.
    const withLocalTask = snapshot({
      task_config: TASK_CONFIG,
      tasks: [...snapshot().tasks, taskRow("task_V", remoteTaskId, { verified: true, verify_detail: "ANSWER.md has a https:// source link" })],
    });
    await signedSync(syncBody({ snapshot: withLocalTask }));

    const answer = await callTool<AnswerResult>(access_token, "get_task_answer", { task_id: remoteTaskId });
    expect(answer.data.state).toBe("verified");
    const localTask = answer.data.local_task;
    if (!isVerifiedTask(localTask)) throw new Error(`expected local_task with verified/verify_detail, got ${JSON.stringify(localTask)}`);
    expect(localTask.verified).toBe(true);
    expect(localTask.verify_detail).toBe("ANSWER.md has a https:// source link");
    expect(answer.data.verified_kind).toBe("source_link_present");
  });
});

describe("answer_ready gating (research-task-closure defect 3)", () => {
  const hasType = (ev: unknown, type: string): boolean =>
    !!ev && typeof ev === "object" && "type" in ev && ev.type === type;
  it("fires only once ANSWER.md itself is present (has_answer), never on PROOF.md's mere existence (has_result)", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(access_token, "start_task",
      { repo: "knowledge-base", mode: "research", objective: "find X" });
    const remoteTaskId = started.data.task_id;

    const leased = await syncJson(await signedSync(taskConfigBody()));
    const cmd = leased.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "start");
    await signedSync(syncBody({
      lease: false,
      command_acks: [{ command_id: cmd!.command_id, outcome: "accepted", detail: "spawned",
        local_task_id: "task_AR", local_run_id: "run_AR", branch: "remote/arabc", pane_id: "w1:term_ar", agent_id: "term_ar" }],
    }));

    // The worker is still running, its SPEC.md's companion PROOF.md already
    // exists (created empty, same as every task) -- has_result is true, but
    // ANSWER.md has not been written yet (has_answer false). The pre-fix
    // code keyed answer_ready off has_result alone and would have fired
    // here already (rtask_20261004T120322Z_17df2d64: fired from an empty
    // PROOF.md before ANSWER.md existed).
    const before = await callTool<EventsResult>(access_token, "list_events", { since_cursor: 0 });
    const beforeCursor = before.data.cursor;
    const runningNoAnswer = snapshot({ task_config: TASK_CONFIG,
      tasks: [...snapshot().tasks, taskRow("task_AR", remoteTaskId,
        { state: "running", stored_state: "running", completed_at: null, closure_reason: null,
          has_result: true, has_answer: false })] });
    await signedSync(syncBody({ snapshot: runningNoAnswer }));
    const afterEmpty = await callTool<EventsResult>(access_token, "list_events", { since_cursor: beforeCursor });
    expect(afterEmpty.data.events.some((ev) => hasType(ev, "answer_ready"))).toBe(false);

    // ANSWER.md now exists and is non-empty -- has_answer flips true, and
    // THIS is what should fire answer_ready.
    const runningWithAnswer = snapshot({ task_config: TASK_CONFIG,
      tasks: [...snapshot().tasks, taskRow("task_AR", remoteTaskId,
        { state: "running", stored_state: "running", completed_at: null, closure_reason: null,
          has_result: true, has_answer: true })] });
    await signedSync(syncBody({ snapshot: runningWithAnswer }));
    const afterAnswer = await callTool<EventsResult>(access_token, "list_events", { since_cursor: beforeCursor });
    expect(afterAnswer.data.events.some((ev) => hasType(ev, "answer_ready"))).toBe(true);
  });
});

describe("cancel_task / resume_task", () => {
  it("cancels a never-spawned task locally, with no command needed, and refuses it again (already terminal)", async () => {
    await signedSync(taskConfigBody());
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;

    const cancelled = await callTool<CancelTaskResult>(tok, "cancel_task", { task_id: remoteTaskId });
    expect(cancelled.data.state).toBe("cancelled");

    const again = await callTool(tok, "cancel_task", { task_id: remoteTaskId });
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

  it("refuses cancel_task and resume_task from a different client than the one that started the task (H1)", async () => {
    await signedSync(taskConfigBody());
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    // A second client, same email, granted every scope -- scope alone must
    // not be enough; this is a DIFFERENT DCR registration (requester_client).
    const { access_token: otherTok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const cancelled = await callTool(otherTok, "cancel_task", { task_id: started.data.task_id });
    expect(cancelled.data.error).toBe("not_your_task");
    const resumed = await callTool(otherTok, "resume_task", { task_id: started.data.task_id });
    expect(resumed.data.error).toBe("not_your_task");
  });

  it("queues a cancel command for an already-running task, acked to a terminal cancelled state", async () => {
    await signedSync(taskConfigBody());
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_V2", local_run_id: "run_V2", branch: "remote/def456",
      pane_id: "w1:term_v2", agent_id: "term_v2", capability_probe: { secrets_granted: true } }] }));

    const cancelled = await callTool<CancelTaskResult>(tok, "cancel_task", { task_id: remoteTaskId });
    expect(cancelled.data.state).toBe("cancelling");

    const leased2 = await syncJson(await signedSync(taskConfigBody()));
    const cancelCmd = leased2.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "cancel")!;
    expect(cancelCmd.payload).toMatchObject({ local_task_id: "task_V2" });
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: cancelCmd.command_id, outcome: "accepted", detail: "cancelled (canceled)" }] }));
    const final = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(final?.state).toBe("cancelled");
  });

  it("a repeatedly-failing cancel ack is retried up to CANCEL_RETRY_CAP, then gives up loudly instead of flooding (ZR1)", async () => {
    await signedSync(taskConfigBody());
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_zr1", local_run_id: "run_zr1", branch: "remote/zr1",
      pane_id: "w1:term_zr1", agent_id: "term_zr1", capability_probe: {} }] }));

    const cancelled = await callTool<CancelTaskResult>(tok, "cancel_task", { task_id: remoteTaskId });
    expect(cancelled.data.state).toBe("cancelling");

    // The original cancel, plus CANCEL_RETRY_CAP (5) retries, each fail in
    // turn -- 6 failed acks total before the cap is reached. Before ZR1,
    // the FIRST failed ack already silently dropped the cancel: no branch
    // handled it at all, and the row would have stayed 'cancelling'
    // forever with nothing ever retrying it.
    for (let i = 0; i < 6; i++) {
      const l = await syncJson(await signedSync(taskConfigBody()));
      const cancelCmd = l.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "cancel");
      expect(cancelCmd).toBeDefined();
      await signedSync(syncBody({ lease: false,
        command_acks: [{ command_id: cancelCmd!.command_id, outcome: "failed", detail: "pane close failed" }] }));
    }

    const row = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(row?.state).toBe("cancelling"); // never silently resolved; still honestly in-flight

    const events = await runInDurableObject(fleet(), (o: HerdrState) => o.taskEventLog(remoteTaskId, 50));
    expect(events.filter((ev) => ev.type === "cancel_retry_queued").length).toBe(5); // CANCEL_RETRY_CAP
    expect(events.filter((ev) => ev.type === "cancel_stuck").length).toBe(1); // exactly once, never flooded

    // Past the cap: no further retry is queued.
    const lFinal = await syncJson(await signedSync(taskConfigBody()));
    expect(lFinal.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "cancel")).toBeUndefined();
  });

  it("cancelling a task whose start is still being delivered does not revive to running on a late ack (M6)", async () => {
    await signedSync(taskConfigBody());
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;

    // Cancel while the start command is still "delivering" (leased, not yet
    // acked) -- there is no local_task_id yet, so cancelTask cannot queue a
    // real cancel command; it must mark the row cancelling, not cancelled.
    const cancelled = await callTool<CancelTaskResult>(tok, "cancel_task", { task_id: remoteTaskId });
    expect(cancelled.data.state).toBe("cancelling");

    // The start's ack now lands (race: the Mac had already spawned it).
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_race1", local_run_id: "run_race1", branch: "remote/race1",
      pane_id: "w1:term_race1", agent_id: "term_race1", capability_probe: {} }] }));
    const row = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(row?.state).toBe("cancelling");

    const leased2 = await syncJson(await signedSync(taskConfigBody()));
    const cancelCmd = leased2.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "cancel")!;
    expect(cancelCmd.payload).toMatchObject({ local_task_id: "task_race1" });
  });

  it("a task that outran max_minutes stays 'cancelling' until the Mac confirms, then resolves to timed_out (ZR2)", async () => {
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
      o.sync(future, crypto.randomUUID(), body, { revoked: [], hold: false }, { revoked: [], hold: false }, { revoked: [], hold: false }));
    expect(out.ok).toBe(true);
    // ZR2: a spawned agent is not yet confirmed stopped -- 'cancelling',
    // never the TERMINAL 'timed_out' (which every later sync loop
    // excludes), until the Mac's own local state actually says so.
    const row = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(row?.state).toBe("cancelling");
    if (out.ok) expect(out.response.commands.some((c) => c.remote_task_id === remoteTaskId && c.op === "cancel")).toBe(true);

    // The Mac's local state now confirms the task actually stopped (e.g.
    // close-done-workers.sh ran after registry-bridge.sh's cancel landed).
    const closedSnapshot = snapshot({ task_config: { ...TASK_CONFIG, ...cfg },
      tasks: [taskRow("task_V3", remoteTaskId, { state: "cancelled", stored_state: "cancelled", has_result: false })] });
    await signedSync(syncBody({ snapshot: closedSnapshot }));
    // The remap loop recovers the DISTINCT 'timed_out' value from the
    // timeout_detected event recorded above, instead of collapsing it to
    // the generic 'cancelled' mapLocalState alone would report.
    const finalRow = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(finalRow?.state).toBe("timed_out");
  });

  it("an accepted cancel ACK landing before the remap tick also preserves timed_out, not generic cancelled (R2-1)", async () => {
    // Same setup as ZR2 above, but resolved via the OTHER path: the
    // worker's own cancel ack (c.op === "cancel" && a.outcome ===
    // "accepted") landing first, instead of the remap loop reading a
    // closed snapshot. Both paths share the one timeout_detected event;
    // before R2-1 only the remap loop checked it, so whichever path won
    // the race determined whether the task's history shows timed_out or
    // a generic cancelled forever.
    const cfg = { caps: { ...CAPS, max_minutes: 1 } };
    await signedSync(taskConfigBody(cfg));
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody(cfg)));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_R21", local_run_id: "run_R21", branch: "remote/r21",
      pane_id: "w1:term_r21", agent_id: "term_r21", capability_probe: {} }] }));

    const future = Date.now() + 2 * 60_000;
    const body = JSON.stringify(taskConfigBody(cfg));
    const out = await runInDurableObject(fleet(), (o: HerdrState) =>
      o.sync(future, crypto.randomUUID(), body, { revoked: [], hold: false }, { revoked: [], hold: false }, { revoked: [], hold: false }));
    expect(out.ok).toBe(true);
    const cancelCmd = out.ok ? out.response.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "cancel") : undefined;
    expect(cancelCmd).toBeDefined();
    const midRow = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(midRow?.state).toBe("cancelling");

    // The Mac's cancel ack lands directly -- no snapshot, no remap tick.
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: cancelCmd!.command_id, outcome: "accepted",
      detail: "cancelled" }] }));
    const finalRow = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(finalRow?.state).toBe("timed_out");
  });

  it("refuses resume_task on a non-terminal task, then on the same task once cancelled before it ever spawned", async () => {
    await signedSync(taskConfigBody());
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const notTerminal = await callTool(tok, "resume_task", { task_id: started.data.task_id });
    expect(notTerminal.data.error).toBe("not_terminal");

    const cancelled = await callTool<CancelTaskResult>(tok, "cancel_task", { task_id: started.data.task_id });
    expect(cancelled.data.state).toBe("cancelled");
    const neverStarted = await callTool(tok, "resume_task", { task_id: started.data.task_id });
    expect(neverStarted.data.error).toBe("never_started");
  });

  it("resumes a terminal, previously-spawned task into a brand new task_id linked via parent_task_id", async () => {
    await signedSync(taskConfigBody());
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
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

    const resumed = await callTool<ResumeTaskResult>(tok, "resume_task", { task_id: remoteTaskId, text: "one more thing" });
    expect(resumed.isError).toBe(false);
    expect(resumed.data.parent_task_id).toBe(remoteTaskId);
    expect(resumed.data.task_id).not.toBe(remoteTaskId);
    const leased2 = await syncJson(await signedSync(taskConfigBody()));
    const resumeCmd = leased2.commands.find((c) => c.op === "resume" && c.remote_task_id === resumed.data.task_id);
    expect(resumeCmd?.payload).toMatchObject({ local_task_id: "task_V4", branch: "remote/t4", repo: "knowledge-base" });
  });

  it("counts resume_task against max_per_day, refusing once the cap is hit (M1)", async () => {
    const cfg = { caps: { ...CAPS, max_per_day: 1 } };
    await signedSync(taskConfigBody(cfg));
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody(cfg)));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_cap1", local_run_id: "run_cap1", branch: "remote/cap1",
      pane_id: "w1:term_cap1", agent_id: "term_cap1", capability_probe: {} }] }));
    await signedSync(syncBody({ snapshot: snapshot({ task_config: { ...TASK_CONFIG, ...cfg },
      tasks: [...snapshot().tasks, taskRow("task_cap1", remoteTaskId, { closure_reason: "no-follow-on" })] }) }));

    // A plain second start_task is already refused by the existing cap.
    const secondStart = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "y" });
    expect(secondStart.data.error).toBe("too_many_today");

    // resume_task must not be a free pass around the same cap.
    const resumed = await callTool(tok, "resume_task", { task_id: remoteTaskId, text: "again" });
    expect(resumed.data.error).toBe("too_many_today");
  });

  it("a revoked grant also cancels a queued resume command, not just a queued start (M2)", async () => {
    await signedSync(taskConfigBody());
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_rev1", local_run_id: "run_rev1", branch: "remote/rev1",
      pane_id: "w1:term_rev1", agent_id: "term_rev1", capability_probe: {} }] }));
    await signedSync(syncBody({ snapshot: snapshot({ task_config: TASK_CONFIG,
      tasks: [...snapshot().tasks, taskRow("task_rev1", remoteTaskId, { closure_reason: "no-follow-on" })] }) }));

    const resumed = await callTool<ResumeTaskResult>(tok, "resume_task", { task_id: remoteTaskId });
    expect(resumed.isError).toBe(false);
    const childId = resumed.data.task_id;

    const grants = await e.OAUTH_KV.list({ prefix: "grant:tnt@teamthurber.com:" });
    expect(grants.keys.length).toBeGreaterThan(0);
    for (const k of grants.keys) await e.OAUTH_KV.delete(k.name);

    const leased2 = await syncJson(await signedSync(taskConfigBody()));
    expect(leased2.commands.find((c) => c.remote_task_id === childId)).toBeUndefined();
    const childRow = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(childId));
    expect(childRow?.state).toBe("cancelled");
  });

  it("a cancel race on a resume that then expires unacked resolves to cancelled, not stuck forever (N2)", async () => {
    await signedSync(taskConfigBody());
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_n2", local_run_id: "run_n2", branch: "remote/n2",
      pane_id: "w1:term_n2", agent_id: "term_n2", capability_probe: {} }] }));
    await signedSync(syncBody({ snapshot: snapshot({ task_config: TASK_CONFIG,
      tasks: [...snapshot().tasks, taskRow("task_n2", remoteTaskId, { closure_reason: "no-follow-on" })] }) }));

    const resumed = await callTool<ResumeTaskResult>(tok, "resume_task", { task_id: remoteTaskId });
    const childId = resumed.data.task_id;
    // Lease the resume command (delivering, not yet acked).
    await syncJson(await signedSync(taskConfigBody()));

    // Cancel races ahead of the ack: no local_task_id for the child yet, so
    // cancel_task can only mark the row cancelling, not cancelled.
    const cancelled = await callTool<CancelTaskResult>(tok, "cancel_task", { task_id: childId });
    expect(cancelled.data.state).toBe("cancelling");

    // The resume is never acked and its 15-minute delivery TTL expires.
    const future = Date.now() + 16 * 60_000;
    const body = JSON.stringify(taskConfigBody());
    const out = await runInDurableObject(fleet(), (o: HerdrState) =>
      o.sync(future, crypto.randomUUID(), body, { revoked: [], hold: false }, { revoked: [], hold: false }, { revoked: [], hold: false }));
    expect(out.ok).toBe(true);
    const childRow = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(childId));
    expect(childRow?.state).toBe("cancelled");
  });

  it("a late accepted ack after the task already timed out still cancels the agent it proves was spawned (N3)", async () => {
    const cfg = { caps: { ...CAPS, max_minutes: 1 } };
    await signedSync(taskConfigBody(cfg));
    const { access_token: startTok } = await oauthToken(["herdr:read", "herdr:task.start"]);
    const started = await callTool<StartTaskResult>(startTok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody(cfg)));
    const startCmd = leased.commands.find((c) => c.op === "start")!;

    // The remote task's own deadline overruns WHILE the start command is
    // still "delivering" (never acked yet) -- the row goes terminal
    // (timed_out) by a path entirely independent of this command.
    const future = Date.now() + 2 * 60_000;
    const body = JSON.stringify(taskConfigBody(cfg));
    await runInDurableObject(fleet(), (o: HerdrState) =>
      o.sync(future, crypto.randomUUID(), body, { revoked: [], hold: false }, { revoked: [], hold: false }, { revoked: [], hold: false }));
    const beforeAck = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(beforeAck?.state).toBe("timed_out");

    // The Mac's ack for the original start command now lands late, proving
    // it really did spawn an agent -- that agent must be cancelled, not
    // silently ignored as late_ack_ignored used to leave it.
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_n3", local_run_id: "run_n3", branch: "remote/n3",
      pane_id: "w1:term_n3", agent_id: "term_n3", capability_probe: {} }] }));
    const leased2 = await syncJson(await signedSync(taskConfigBody(cfg)));
    const cancelCmd = leased2.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "cancel");
    expect(cancelCmd?.payload).toMatchObject({ local_task_id: "task_n3" });
  });

  it("a revoked grant does not also refuse the sender's own pending cancel command (N4)", async () => {
    await signedSync(taskConfigBody());
    const { access_token: tok } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(tok, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_n4", local_run_id: "run_n4", branch: "remote/n4",
      pane_id: "w1:term_n4", agent_id: "term_n4", capability_probe: {} }] }));

    const cancelled = await callTool<CancelTaskResult>(tok, "cancel_task", { task_id: remoteTaskId });
    expect(cancelled.isError).toBe(false);

    // Revoke the sender's own grant before the cancel is ever delivered.
    const grants = await e.OAUTH_KV.list({ prefix: "grant:tnt@teamthurber.com:" });
    for (const k of grants.keys) await e.OAUTH_KV.delete(k.name);

    const leased2 = await syncJson(await signedSync(taskConfigBody()));
    const cancelCmd = leased2.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "cancel");
    expect(cancelCmd?.payload).toMatchObject({ local_task_id: "task_n4" });
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

describe("per-connection revocation also stops a task already running on the Mac (SPEC fix: Zero's review item 4)", () => {
  it("queues a cancel for a spawned, running remote task once the starting connection's grant is revoked", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_revoke1", local_run_id: "run_revoke1", branch: "remote/revoke1",
      pane_id: "w1:term_revoke1", agent_id: "term_revoke1", capability_probe: { secrets_granted: true } }] }));
    const running = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(running?.state).toBe("running");

    // Revoke the ONLY thing distinguishing this from "a start still queued":
    // the Mac already has a local_task_id for it and reports it running, so
    // the OLD code path (pendingCommandSenders -- only a QUEUED command) had
    // nothing left to re-check.
    const grants = await e.OAUTH_KV.list({ prefix: "grant:tnt@teamthurber.com:" });
    expect(grants.keys.length).toBeGreaterThan(0);
    for (const k of grants.keys) await e.OAUTH_KV.delete(k.name);

    const leased2 = await syncJson(await signedSync(taskConfigBody()));
    const cancelCmd = leased2.commands.find((c) => c.remote_task_id === remoteTaskId && c.op === "cancel");
    expect(cancelCmd).toBeDefined();
    expect(cancelCmd!.payload).toMatchObject({ local_task_id: "task_revoke1" });
    const row = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(row?.state).toBe("cancelling");
  });

  it("a revoked task's 'cancelling' state survives repeated remap ticks while the Mac's local snapshot still says running (F4)", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_f4", local_run_id: "run_f4", branch: "remote/f4",
      pane_id: "w1:term_f4", agent_id: "term_f4", capability_probe: {} }] }));

    const grants = await e.OAUTH_KV.list({ prefix: "grant:tnt@teamthurber.com:" });
    for (const k of grants.keys) await e.OAUTH_KV.delete(k.name);

    // The Mac's own local snapshot still reports this task 'running' --
    // the cancel command the revoke loop is about to queue has not been
    // delivered/acked yet, so nothing has told the Mac to stop it.
    const runningSnapshot = snapshot({ task_config: TASK_CONFIG,
      tasks: [taskRow("task_f4", remoteTaskId, { state: "running", stored_state: "running", has_result: false })] });

    // First tick: the revoke-while-running loop flips the row to
    // cancelling and queues a cancel command.
    await signedSync(syncBody({ snapshot: runningSnapshot }));
    const afterFirst = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(afterFirst?.state).toBe("cancelling");

    // Several MORE ticks, the Mac's own local snapshot STILL reporting
    // 'running' -- before F4, the remap loop ran on the SAME sync() call
    // right after the revoke loop and flipped this straight back to
    // 'running', re-arming the revoke check into a fresh cancel every tick.
    for (let i = 0; i < 3; i++) {
      await signedSync(syncBody({ snapshot: runningSnapshot }));
      const row = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
      expect(row?.state).toBe("cancelling");
    }

    // Only ONE cancel was ever requested across all those ticks -- the
    // revoke loop's own self-guard (state already 'cancelling') stopped
    // re-triggering, which only works because F4 stopped the remap loop
    // from undoing the flip it is guarding against.
    const events = await runInDurableObject(fleet(), (o: HerdrState) => o.taskEventLog(remoteTaskId, 50));
    expect(events.filter((ev) => ev.type === "cancel_requested").length).toBe(1);

    // The Mac's local state finally confirms the cancel landed.
    const cancelledSnapshot = snapshot({ task_config: TASK_CONFIG,
      tasks: [taskRow("task_f4", remoteTaskId, { state: "cancelled", stored_state: "cancelled", has_result: false })] });
    await signedSync(syncBody({ snapshot: cancelledSnapshot }));
    const final = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(final?.state).toBe("cancelled");
  });

  it("does not touch a running task whose OWN sender still holds a live grant", async () => {
    await signedSync(taskConfigBody());
    const { access_token } = await oauthToken(["herdr:read", "herdr:task.start", "herdr:task.cancel"]);
    const started = await callTool<StartTaskResult>(access_token, "start_task", { repo: "knowledge-base", mode: "research", objective: "x" });
    const remoteTaskId = started.data.task_id;
    const leased = await syncJson(await signedSync(taskConfigBody()));
    const startCmd = leased.commands.find((c) => c.op === "start")!;
    await signedSync(syncBody({ lease: false, command_acks: [{ command_id: startCmd.command_id, outcome: "accepted",
      detail: "spawned", local_task_id: "task_keep1", local_run_id: "run_keep1", branch: "remote/keep1",
      pane_id: "w1:term_keep1", agent_id: "term_keep1", capability_probe: {} }] }));

    const leased2 = await syncJson(await signedSync(taskConfigBody()));
    expect(leased2.commands.find((c) => c.remote_task_id === remoteTaskId)).toBeUndefined();
    const row = await runInDurableObject(fleet(), (o: HerdrState) => o.remoteTask(remoteTaskId));
    expect(row?.state).toBe("running");
  });
});
