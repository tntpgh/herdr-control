// omp-herdr-control.ts — the same four herdr-control jobs Claude Code gets via
// ~/.claude/settings.json hooks (agent-hooks/claude-notify.sh,
// agent-hooks/session-reconcile.sh, agent-hooks/interval-reconcile.sh,
// herdr-resolve.sh), wired into omp's extension system instead. Both
// integrations call the SAME shell scripts — Claude via `bash <script>` hook
// commands in settings.json, omp via this file's default-exported factory —
// so there is exactly one place that knows how to notify/reconcile/retract,
// not two drifting copies that can disagree.
//
// install.sh SYMLINKS this file into ~/.omp/agent/extensions/herdr-control.ts
// (never copies it), and omp's loader resolves that symlink to its REALPATH
// before dynamic-importing it — so `import.meta.url` below already names
// this file INSIDE the checkout, not the ~/.omp symlink, and an edit here is
// live on the next omp session start with no reinstall.
//
// This extension has two classes of handlers:
//   * observability handlers below, which must never throw into the agent; and
//   * the `tool_call` registration/ownership guard, which deliberately returns
//     `{block:true}` for a fleet-creating tool that has no live central task
//     registration. A failed guard is also a block: otherwise a conductor can
//     create invisible nested work and a recycled worker can act as its old
//     generation.
//
// The guard is deliberately narrow. Ordinary tool calls remain governed by
// omp's own approval layer and herdr-select.sh's human-only command policy;
// this extension never adopts Firstmate's approval-bypass posture.

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

// ---- locate the checkout ---------------------------------------------------
// HERDR_CONTROL_DIR overrides everything below it — lets a dev harness (or a
// future second checkout) point this extension at a tree other than the one
// it physically resides in, without re-symlinking ~/.omp/agent/extensions.
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = process.env.HERDR_CONTROL_DIR?.trim() || path.dirname(HERE);

const NOTIFY_SH = path.join(ROOT, "agent-hooks", "omp-notify.sh");
const RECONCILE_SH = path.join(ROOT, "agent-hooks", "omp-reconcile.sh");
const PRETOOL_REGISTRATION_SH = path.join(ROOT, "lib", "pretool-registration.sh");
const RESOLVE_SH = path.join(ROOT, "herdr-resolve.sh");
const CONDUCTOR_EXIT_SH = path.join(ROOT, "conductor-exit.sh");
const HUB_PY = path.join(ROOT, "hub.py");
const HUB_PORT = Number(process.env.HERDR_HUB_PORT) || 8600;
const HUB_URL = `http://127.0.0.1:${HUB_PORT}/`;

// Same root lib/run-registry.sh uses for the control plane — never inside a
// repo or worktree, so a `git worktree remove` or a repo clean can't delete
// state this file needs to keep working. Not the registry's own SQLite file:
// this is one small keyed record with exactly one writer per machine (omp
// itself, at most one SessionStart at a time), the same shape
// notepad-mnemopi-sync-cursors.json already is — a table would buy nothing a
// JSON file plus an atomic write does not already give it.
const ATTENTION_CURSOR_PATH = path.join(
  process.env.HERDR_RUN_STATE_DIR?.trim() || path.join(process.env.HOME ?? "", ".local/state/herdr/runs"),
  "attention-announce-cursor.json",
);
// project-contract-plan.md §2 surface 2 (the ambient card). One JSON object,
// keyed by project slug, so a session that visits several projects across a
// day keeps each project's own "have I already said this" state instead of
// one cursor being clobbered by whichever project was looked at last.
const PROJECT_CURSOR_PATH = path.join(
  process.env.HERDR_RUN_STATE_DIR?.trim() || path.join(process.env.HOME ?? "", ".local/state/herdr/runs"),
  "project-announce-cursor.json",
);

// existsSync can throw on a permission-denied ancestor directory, which is
// exactly the kind of environment surprise this file must survive without
// taking every omp session down with it (see the module header). Missing or
// unreadable both mean "not available" — nothing more.
function safeExists(p: string): boolean {
  try {
    return existsSync(p);
  } catch {
    return false;
  }
}

// Checked once at load (module hot-reloads on file change, per omp's loader,
// so a sibling script that shows up later is picked up on the next reload —
// no restart-and-hope needed). If a script this session depends on isn't
// there yet, the corresponding job degrades to a silent no-op instead of
// shelling out to a path that doesn't exist.
const notifyAvailable = safeExists(NOTIFY_SH);
const reconcileAvailable = safeExists(RECONCILE_SH);
const resolveAvailable = safeExists(RESOLVE_SH);
const hubAvailable = safeExists(HUB_PY);

// ---- fire-and-forget spawn --------------------------------------------------
// Every non-blocking call in this file (Notification, interval reconcile,
// both retraction call sites) goes through here. `detached: true` + unref()
// means the child outlives this handler and is never awaited; stdio is
// "ignore" on stdout/stderr and piped on stdin ONLY when there is input to
// send, so neither the child's output nor a broken pipe on ITS side can
// propagate back into the agent turn that triggered it.
//
// The 'error' listeners are not optional cleanup: an EventEmitter with no
// 'error' listener THROWS when one fires (e.g. `bash` itself missing from
// PATH, or — for stdin — the child exiting before it reads, which raises
// EPIPE on the write). spawn() is async, so that throw would otherwise
// surface as an unhandled rejection well after this function already
// returned: a delayed, hard-to-attribute crash of exactly the kind the
// fail-closed tool_call contract (see header) exists to prevent.
function spawnDetached(args: string[], stdinInput?: string): void {
  try {
    const child = spawn("bash", args, {
      detached: true,
      stdio: [stdinInput === undefined ? "ignore" : "pipe", "ignore", "ignore"],
    });
    child.on("error", () => {});
    if (stdinInput !== undefined && child.stdin) {
      child.stdin.on("error", () => {});
      child.stdin.write(stdinInput);
      child.stdin.end();
    }
    child.unref();
  } catch {
    // spawn() throwing synchronously isn't documented behavior, but nothing
    // in this file may ever throw back into the agent it's observing.
  }
}

// ---- Notification: tool_approval_requested / ask --------------------------
// omp's docs (docs/extensions.md, docs/hooks.md) both show the SAME shape for
// this event — `event.toolName: string` and `event.input: Record<string,
// unknown>` — so this reads those fields directly instead of guessing across
// plausible names. It is still defensive (typeof checks, never asserts),
// because the result only feeds Slack message text — cosmetic, not anything
// gating behavior — so "best effort, never throw" is still the contract.
//
// The bug this replaces: the old version only ever sent the tool's NAME
// ("omp tool call: bash") with no arguments at all, so a Slack approval
// alert could not be acted on without switching to the pane — you were
// asked to approve "bash" with no idea which command. describeToolCall
// pulls the part of `input` a human actually needs to decide: the command
// for bash, the path for file tools, the pattern for search tools, and the
// raw (truncated) input JSON for anything unrecognized — never silently
// dropping an unfamiliar tool's arguments.
const MAX_DETAIL_LEN = 300;

function truncate(s: string, max = MAX_DETAIL_LEN): string {
  const flat = s.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max)}…` : flat;
}

function describeToolCall(toolName: string, input: unknown): string | undefined {
  const rec = input && typeof input === "object" ? (input as Record<string, unknown>) : {};
  const str = (v: unknown): string | undefined => (typeof v === "string" && v.length > 0 ? v : undefined);
  switch (toolName.toLowerCase()) {
    case "bash":
    case "shell":
      return (str(rec.command) && truncate(str(rec.command)!)) || undefined;
    case "write":
    case "read":
    case "edit":
    case "multiedit":
      return str(rec.file_path ?? rec.path);
    case "grep": {
      const pattern = str(rec.pattern);
      if (!pattern) return undefined;
      const p = str(rec.path);
      return truncate(p ? `${pattern}  (${p})` : pattern);
    }
    case "glob":
      return str(rec.pattern);
    default: {
      try {
        const json = JSON.stringify(rec);
        return json && json !== "{}" ? truncate(json) : undefined;
      } catch {
        return undefined;
      }
    }
  }
}

// The UNTRUNCATED command behind a bash/shell approval (project-contract-plan.md
// #3b, item 2) — never truncated, unlike describeToolCall's `detail` above.
// herdr-select.sh needs the model's own complete argument text to classify a
// command whose TUI panel wrapped across rows and scraped back wrong (measured:
// 45 of 103 human escalations were exactly that). Only for bash/shell; every
// other tool has no single "command" concept worth carrying separately.
function rawBashCommand(toolName: string, input: unknown): string | undefined {
  if (toolName.toLowerCase() !== "bash" && toolName.toLowerCase() !== "shell") return undefined;
  const rec = input && typeof input === "object" ? (input as Record<string, unknown>) : {};
  return typeof rec.command === "string" && rec.command.length > 0 ? rec.command : undefined;
}

// Firstmate's guard classifies delegation by shape rather than a fixed list.
// Keep the same exclusions for observer/todo tools. MCP tools are not blanket
// safe: only read-only observer-shaped MCP names bypass the pretool block, and
// unknown or delegation-shaped MCP tools fail closed before any server code runs.
// The shell guard remains the authority for registry, pane-generation, and
// worktree ownership; this local check only avoids starting a shell for ordinary
// tool calls.
const NON_FLEET_TOOLS: Record<string, true> = {
  taskoutput: true,
  taskstop: true,
  taskget: true,
  tasklist: true,
  cronlist: true,
  bashoutput: true,
  killshell: true,
  taskupdate: true,
};

const SAFE_MCP_OBSERVER_PREFIXES = [
  "read",
  "get",
  "list",
  "search",
  "fetch",
  "lookup",
  "inspect",
  "show",
  "find",
  "grep",
  "glob",
  "status",
  "metadata",
];

function isSafeMcpObserverTool(normalized: string): boolean {
  if (!normalized.startsWith("mcp__")) return false;
  const leaf = normalized.split("__").filter(Boolean).pop() ?? "";
  return SAFE_MCP_OBSERVER_PREFIXES.some((prefix) => leaf === prefix || leaf.startsWith(`${prefix}_`));
}

function isFleetCreatingTool(toolName: string): boolean {
  const normalized = toolName.toLowerCase().replace(/[^a-z0-9_:-]/g, "");
  if (NON_FLEET_TOOLS[normalized]) return false;
  if (normalized.startsWith("mcp__")) return !isSafeMcpObserverTool(normalized);
  return [
    "agent",
    "subagent",
    "task",
    "workflow",
    "cron",
    "schedul",
    "worktree",
    "delegate",
    "spawn",
    "dispatch",
    "handoff",
    "remote",
    "sendmessage",
    "monitor",
  ].some((stem) => normalized.includes(stem));
}

function onToolCall(event: unknown): { block: true; reason: string } | undefined {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    const toolName = typeof e.toolName === "string" ? e.toolName : "";
    if (!isFleetCreatingTool(toolName)) return undefined;
    if (!safeExists(PRETOOL_REGISTRATION_SH)) {
      return { block: true, reason: "herdr pretool guard is unavailable; refusing unregistered fleet work" };
    }
    const input = e.input && typeof e.input === "object" ? (e.input as Record<string, unknown>) : {};
    const cwd = typeof input.cwd === "string" && input.cwd.length > 0 ? input.cwd : process.cwd();
    const result = spawnSync("bash", [PRETOOL_REGISTRATION_SH, toolName, cwd], {
      encoding: "utf8",
      timeout: 5_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (result.status === 0) return undefined;
    const detail = `${result.stderr ?? ""}\n${result.stdout ?? ""}`.replace(/\s+/g, " ").trim();
    return {
      block: true,
      reason: detail.slice(0, 500) || "herdr pretool registration/ownership check refused the fleet-creating tool",
    };
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return { block: true, reason: `herdr pretool guard failed closed: ${detail}` };
  }
}

// Fires ONLY when omp actually needs a human: `tool_approval_requested` (the
// approval menu) and `tool_execution_start` for the `ask` tool (the numbered
// question prompt). Both are documented observability events
// (docs/extensions.md: "emitted by wrapper.ts only when a tool requires
// approval and an approval handler is registered"), and omp's own herdr
// integration (~/.omp/agent/extensions/herdr-omp-agent-state.ts) already
// drives pane.report_agent blocked/idle off exactly this pair.
//
// Notification deliberately does NOT use `tool_call`: that event fires before
// every approved call and would force a screen scrape just to discover whether
// an approval menu appeared. The narrow `onToolCall` guard above is different:
// it runs only for delegation-shaped tools and synchronously checks the
// central registration/generation record before omp can create invisible work.
// Approval notifications remain attached only to events emitted when omp
// actually needs a human, so ordinary calls cost zero herdr RPCs here.
function notifyForPrompt(toolName: string, message: string, command?: string): void {
  if (!notifyAvailable) return;
  const payload: Record<string, unknown> = { tool: toolName, message, cwd: process.cwd() };
  if (command) payload.command = command;
  spawnDetached([NOTIFY_SH], JSON.stringify(payload));
}

function onApprovalRequested(event: unknown): undefined {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    const toolName = typeof e.toolName === "string" && e.toolName ? e.toolName : "tool";
    const input = e.input ?? e.args;
    // `reason` is the approval's own words when omp supplies one; the argument
    // summary is the fallback, and still the more useful line for bash.
    const detail = describeToolCall(toolName, input)
      ?? (typeof e.reason === "string" && e.reason ? truncate(e.reason) : undefined);
    notifyForPrompt(
      toolName,
      detail ? `${toolName}: ${detail}` : `omp needs your permission to use ${toolName}`,
      rawBashCommand(toolName, input),
    );
  } catch {
    // MUST NOT throw — see the fail-closed contract at the top of this file.
  }
  return undefined;
}

// The `ask` tool is not an approval, so it emits no approval event — it just
// paints a numbered question and waits. Same alert path, same retraction path
// (tool_execution_end), and the same shape omp's herdr integration uses to
// report `blocked` for it.
function onExecutionStart(event: unknown): undefined {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    if (e.toolName !== "ask") return undefined;
    const args = e.args && typeof e.args === "object" ? (e.args as Record<string, unknown>) : {};
    const questions = Array.isArray(args.questions) ? args.questions : [];
    const first = questions.find(
      (q: unknown) => q && typeof q === "object" && typeof (q as Record<string, unknown>).question === "string",
    ) as Record<string, unknown> | undefined;
    const q = typeof first?.question === "string" ? truncate(first.question) : "waiting for user input";
    notifyForPrompt("ask", `ask: ${q}`);
  } catch {
    // see onApprovalRequested().
  }
  return undefined;
}

// Retraction is now edge-triggered too: the prompt was answered (in the
// terminal, from Slack, or by a peer), so the alert for it is stale THE
// MOMENT omp says so. It used to run on every tool_result, which meant a
// pane-list, a pane read, two prompt parses and — until this branch — an
// `op read` for the Slack token, on every tool call of every session, for as
// long as any worker anywhere sat blocked.
function retract(): void {
  if (resolveAvailable) spawnDetached([RESOLVE_SH]);
}

function onApprovalResolved(): undefined {
  try {
    retract();
  } catch {
    // see onApprovalRequested().
  }
  return undefined;
}

function onExecutionEnd(event: unknown): undefined {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    // Only `ask` was ever alerted from tool_execution_start, so only `ask`
    // needs the matching retraction; any other tool ending is not a prompt
    // being answered and must not cost a sweep.
    if (e.toolName === "ask") retract();
  } catch {
    // see onApprovalRequested().
  }
  return undefined;
}

// ---- reconcile envelope ------------------------------------------------------
// omp-reconcile.sh session/interval print ONE JSON envelope: {report,
// ack_required, conductor_id, task_states, last_event_seq}. `report` is the
// human text to inject; when ack_required is true the WHOLE envelope must be
// fed back to `omp-reconcile.sh ack` — but only AFTER the injection was
// actually accepted. That ordering is this file's half of the fix for the
// silently-eaten interval reports: the old shim spawned the interval pass
// with stdout ignored while the script checkpointed the report as delivered,
// so every mid-session report was consumed unseen and the next session said
// "no changes". Now nothing is acknowledged until it demonstrably reached
// the session; a crash between delivery and ack redelivers (duplicate, never
// loss), and ack_reconcile's MAX() cursor makes a replayed ack harmless.
interface ReconcileEnvelope {
  report: string;
  ackRequired: boolean;
  raw: string;
}

// Non-JSON stdout is treated as a plain-text report with nothing to ack —
// the shape an older omp-reconcile.sh printed (which acknowledged inline
// before printing). Injecting it unacked is exactly right for that version.
function parseEnvelope(stdout: string): ReconcileEnvelope | undefined {
  const raw = stdout.trim();
  if (!raw) return undefined;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed && typeof parsed === "object" && typeof (parsed as Record<string, unknown>).report === "string") {
      const rec = parsed as Record<string, unknown>;
      return { report: (rec.report as string).trim(), ackRequired: rec.ack_required === true, raw };
    }
  } catch {
    // fall through to plain-text compatibility below
  }
  return { report: raw, ackRequired: false, raw };
}

// ---- the report lives on a web page, not in the prompt ----------------------
// Terrence, 2026-09-05: "I hate seeing a huge amount of info in the
// herdr-reconcile window when we enter something … should be a web page on
// localhost, not in our prompts." So: the full wake-persistence report (task
// states + up to 20 event lines) is never injected. hub.py serves the
// registry, the decisions inbox and the rest at HUB_URL; the extension starts
// it when the port is free (idempotent — a second copy exits when the port is
// taken; launchd normally has it up already). What still reaches the model is
// at most ONE line, at session start only, and only when something needs a
// human: tasks needing attention or an open decision form. The envelope is
// acked exactly as before, so the conductor's cursor advances and the page —
// not the next prompt — carries the history.
function ensureHub(): void {
  if (!hubAvailable) return;
  try {
    const child = spawn("python3", [HUB_PY, "--port", String(HUB_PORT)], {
      detached: true,
      stdio: ["ignore", "ignore", "ignore"],
    });
    child.on("error", () => {});
    child.unref();
  } catch {
    // never into the agent turn
  }
}

// {attention, open_decisions} from the hub, or undefined when it is not up
// yet (first start on a machine without the launchd agent) — bounded so a
// slow hub costs the session start at most 2s.
//
// `attention` is the UNION (panes + repos owing a handoff); `handoff_debt` is
// the repo half of it, published separately so this banner can name each with
// its own noun instead of calling a repo a task. A hub too old to publish the
// field reads as 0 and the line is exactly what it was before.
function hubSummary(): { attention: number; handoff_debt: number; open_decisions: number } | undefined {
  try {
    const r = spawnSync("curl", ["-s", "--max-time", "2", `${HUB_URL}api/summary`], { encoding: "utf8" });
    if (r.error || r.status !== 0 || !r.stdout) return undefined;
    const j: unknown = JSON.parse(r.stdout);
    if (!j || typeof j !== "object" || !("attention" in j) || !("open_decisions" in j)) return undefined;
    const attention = Number(j.attention);
    const open_decisions = Number(j.open_decisions);
    const raw_debt = "handoff_debt" in j ? Number(j.handoff_debt) : 0;
    const handoff_debt = Number.isFinite(raw_debt) && raw_debt > 0 ? raw_debt : 0;
    return Number.isFinite(attention) && Number.isFinite(open_decisions)
      ? { attention, handoff_debt, open_decisions }
      : undefined;
  } catch {
    return undefined;
  }
}

// ---- project ambient card (project-contract-plan.md §2, surface 2) ---------
// The cwd's own project card — worker state, next step, needs_wake — from the
// SAME /api/projects join the hub page and the `project_status` tool read.
// undefined when the hub is down, the endpoint is unrecognised (an older
// hub), or cwd matches no known project — a session outside any project's
// repo says nothing, same as a fresh machine before this feature existed.
interface ProjectCard {
  project: string;
  next_step: string | null;
  needs_wake: boolean;
  workers: number;
  open_prs: number;
  open_decisions: number;
}

// A spawned worker runs in ~/.herdr/worktrees/<repo>/<branch...>, so its
// basename is a branch leaf, not the repo — matching by basename alone (the
// original cut) matched no project for exactly the sessions this card exists
// for. Match by PATH instead: cwd is inside a project's own `repo`, or
// inside one of its tasks' `worktree`; `git rev-parse --git-common-dir`'s
// parent resolves a linked worktree back to the MAIN checkout, which
// /api/projects keys tasks by. The basename check survives as a last resort
// for a project registered before this field existed (no worktree on any of
// its task rows).
function isUnderPath(cwd: string, base: unknown): boolean {
  return typeof base === "string" && base.length > 0 && (cwd === base || cwd.startsWith(`${base}/`));
}

function taskWorktreeMatches(task: unknown, cwd: string): boolean {
  return !!task && typeof task === "object" && "worktree" in task && isUnderPath(cwd, task.worktree);
}

function isProjectRowFor(
  p: unknown,
  cwd: string,
  repoRoot: string | null,
  fallbackRepoName: string,
): p is { project: unknown; repo?: unknown; next_step?: unknown; needs_wake?: unknown; tasks?: unknown; prs?: unknown; open_decisions?: unknown } {
  if (!p || typeof p !== "object" || !("project" in p)) return false;
  if ("repo" in p && isUnderPath(cwd, p.repo)) return true;
  if (repoRoot && "repo" in p && p.repo === repoRoot) return true;
  if ("tasks" in p && Array.isArray(p.tasks) && p.tasks.some((t) => taskWorktreeMatches(t, cwd))) return true;
  if (p.project === fallbackRepoName) return true;
  return "repo" in p && typeof p.repo === "string" && p.repo.endsWith(`/${fallbackRepoName}`);
}

function gitCommonDirRepoRoot(cwd: string): string | null {
  const r = spawnSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, encoding: "utf8" });
  if (r.error || r.status !== 0 || !r.stdout) return null;
  const commonDir = r.stdout.trim();
  return commonDir ? path.dirname(commonDir) : null;
}

function projectSummary(cwd: string): ProjectCard | undefined {
  try {
    const fallbackRepoName = cwd.split(path.sep).filter(Boolean).pop();
    if (!fallbackRepoName) return undefined;
    const r = spawnSync("curl", ["-s", "--max-time", "2", `${HUB_URL}api/projects`], { encoding: "utf8" });
    if (r.error || r.status !== 0 || !r.stdout) return undefined;
    const j: unknown = JSON.parse(r.stdout);
    if (!j || typeof j !== "object" || !("projects" in j) || !Array.isArray(j.projects)) return undefined;
    const repoRoot = gitCommonDirRepoRoot(cwd);
    const row = j.projects.find((p: unknown) => isProjectRowFor(p, cwd, repoRoot, fallbackRepoName));
    if (!row) return undefined;
    return {
      project: typeof row.project === "string" ? row.project : fallbackRepoName,
      next_step: typeof row.next_step === "string" ? row.next_step : null,
      needs_wake: row.needs_wake === true,
      workers: Array.isArray(row.tasks) ? row.tasks.length : 0,
      open_prs: Array.isArray(row.prs) ? row.prs.length : 0,
      open_decisions: Array.isArray(row.open_decisions) ? row.open_decisions.length : 0,
    };
  } catch {
    return undefined;
  }
}

interface ProjectAnnounceCursor {
  signature: string;
  announced_at: number;
}

function readProjectCursors(): Record<string, ProjectAnnounceCursor> {
  try {
    const raw = readFileSync(PROJECT_CURSOR_PATH, "utf8");
    const j: unknown = JSON.parse(raw);
    return j && typeof j === "object" ? (j as Record<string, ProjectAnnounceCursor>) : {};
  } catch {
    return {};
  }
}

function writeProjectCursors(all: Record<string, ProjectAnnounceCursor>): void {
  try {
    mkdirSync(path.dirname(PROJECT_CURSOR_PATH), { recursive: true });
    const tmp = `${PROJECT_CURSOR_PATH}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(all), "utf8");
    renameSync(tmp, PROJECT_CURSOR_PATH);
  } catch {
    // Worst case: the next turn re-announces something already seen once.
  }
}

// Same "announce on change, or after the remind floor" rule as
// shouldAnnounce above, applied to one project's signature instead of the
// fleet-wide tuple — kept as its own pure function for the same reason:
// unit-testable without a real cursor file or a real hub.
export function shouldAnnounceProject(
  signature: string,
  cursor: ProjectAnnounceCursor | undefined,
  now: number,
  remindAfterMs: number,
): boolean {
  if (!cursor) return true;
  if (cursor.signature !== signature) return true;
  return now - cursor.announced_at >= remindAfterMs;
}


// ---- announce throttle -------------------------------------------------------
// Terrence, 2026-09-22: "less noise, more of the right kind" — measured
// against this exact banner, which repeated the SAME unresolved count on
// every single turn of a multi-hour session, not once per session as the
// comment above this file's SessionStart handler says it should. In THIS
// harness `before_agent_start` fires more often than "once per session"
// (each turn re-triggers it), so a static count re-announced itself dozens
// of times — the same information every time, at the cost of a line in
// every prompt.
//
// The fix is not "announce less often on a timer" — a stuck problem must
// stay visible, and a fixed interval either nags while nothing changed or
// goes quiet while something did. It is "announce on CHANGE": the exact
// same tuple as last time says nothing new, so it says nothing at all,
// until either the numbers move (worse, better, or a different mix — all
// worth knowing) or REMIND_AFTER_MS has passed since the last time a human
// was actually told, so a genuinely stuck problem cannot go silent forever
// just because nothing about it happened to change.
const REMIND_AFTER_MS = (Number(process.env.HERDR_ATTENTION_REMIND_S) || 2 * 60 * 60) * 1000;

interface AnnounceCursor {
  tasks: number;
  handoff_debt: number;
  open_decisions: number;
  announced_at: number; // epoch ms
}

// Best-effort throughout, like every other read in this file: a missing,
// corrupt, or unreadable cursor means "nothing announced yet", which is the
// same as a fresh machine — never a reason to fail closed and go silent.
function readAnnounceCursor(): AnnounceCursor | undefined {
  try {
    const raw = readFileSync(ATTENTION_CURSOR_PATH, "utf8");
    const j = JSON.parse(raw) as Partial<AnnounceCursor>;
    if (
      typeof j.tasks !== "number" ||
      typeof j.handoff_debt !== "number" ||
      typeof j.open_decisions !== "number" ||
      typeof j.announced_at !== "number"
    ) {
      return undefined;
    }
    return j as AnnounceCursor;
  } catch {
    return undefined;
  }
}

// temp-write + rename in the SAME directory as the target: the rename is
// what makes this atomic (same filesystem, single syscall to replace the
// old content), matching lib/record_store.py's write_atomic — a truncating
// write here would leave a 0-byte cursor on a crash mid-write, and an
// unreadable/empty cursor already degrades safely (see readAnnounceCursor),
// but there is no reason to manufacture the failure this avoids for free.
function writeAnnounceCursor(c: AnnounceCursor): void {
  try {
    mkdirSync(path.dirname(ATTENTION_CURSOR_PATH), { recursive: true });
    const tmp = `${ATTENTION_CURSOR_PATH}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(c), "utf8");
    renameSync(tmp, ATTENTION_CURSOR_PATH);
  } catch {
    // Worst case: the next turn re-announces something already seen once.
    // That is exactly the pre-throttle behaviour — a failure here can only
    // return to the old noise level, never to silence on a real problem.
  }
}

// ---- SessionStart: before_agent_start --------------------------------------
// Runs SYNCHRONOUSLY (an async hook's output is not guaranteed to land before
// the first prompt is assembled), bounded by `timeout` so a hung or missing
// omp-reconcile.sh degrades to "nothing injected". The ack fires just before
// returning: for this event the runner keeps the first returned message, so
// a constructed return IS the accepted delivery. A timeout or parse failure
// exits earlier and leaves the envelope unacked for redelivery.

// Pure decision, isolated from the filesystem and the clock so it is
// unit-testable without a real cursor file or a real hub: given the current
// counts, what was last announced (or undefined, never), and now, should
// this turn say anything at all.
export function shouldAnnounce(
  current: { tasks: number; handoff_debt: number; open_decisions: number },
  cursor: AnnounceCursor | undefined,
  now: number,
  remindAfterMs: number,
): boolean {
  if (!cursor) return true; // never announced before — first time is always news
  const same =
    cursor.tasks === current.tasks &&
    cursor.handoff_debt === current.handoff_debt &&
    cursor.open_decisions === current.open_decisions;
  if (!same) return true; // the numbers moved — better, worse, or a different mix, always worth a line
  return now - cursor.announced_at >= remindAfterMs; // unchanged: only past the remind floor
}

function onBeforeAgentStart():
  | { message: { customType: string; content: string; display: boolean } }
  | undefined {
  try {
    ensureHub();
    if (reconcileAvailable) {
      const result = spawnSync("bash", [RECONCILE_SH, "session"], {
        encoding: "utf8",
        timeout: 15_000,
        stdio: ["ignore", "pipe", "ignore"],
      });
      if (!result.error) {
        const env = parseEnvelope(result.stdout ?? "");
        if (env?.ackRequired) spawnDetached([RECONCILE_SH, "ack"], env.raw);
      }
    }
    const s = hubSummary();
    const cwd = process.cwd();
    const project = projectSummary(cwd);
    // Worth a line only when there is something outstanding — a healthy
    // project (no next step, no wake) says nothing, same as the fleet card
    // when nothing needs a human.
    const projectWorthAnnouncing = project !== undefined && (project.next_step !== null || project.needs_wake);
    const now = Date.now();
    const parts: string[] = [];

    if (s && s.attention + s.open_decisions > 0) {
      // `attention` carries both halves; subtract the one with its own noun
      // so neither is dropped and neither is miscalled. Clamped at 0 so a
      // hub mid-deploy (new field, old count, or the reverse) can only
      // understate the task half, never print a negative.
      const current = {
        tasks: Math.max(0, s.attention - s.handoff_debt),
        handoff_debt: s.handoff_debt,
        open_decisions: s.open_decisions,
      };
      if (shouldAnnounce(current, readAnnounceCursor(), now, REMIND_AFTER_MS)) {
        writeAnnounceCursor({ ...current, announced_at: now });
        if (current.tasks) parts.push(`${current.tasks} task(s) need attention`);
        if (current.handoff_debt) parts.push(`${current.handoff_debt} repo(s) owe a handoff`);
        if (current.open_decisions) parts.push(`${current.open_decisions} decision(s) open`);
      }
    } else {
      // Nothing needs a human right now. Reset the cursor to zero (rather
      // than leaving whatever was last announced) so that if the SAME count
      // reappears later — the queue drained, then filled back up to the
      // identical number — it is treated as fresh news, not as "unchanged
      // since an hour ago", which it is not: something resolved in between.
      writeAnnounceCursor({ tasks: 0, handoff_debt: 0, open_decisions: 0, announced_at: now });
    }

    if (project && projectWorthAnnouncing) {
      const signature = `${project.next_step ?? ""}|${project.needs_wake}|${project.workers}|${project.open_prs}`;
      const cursors = readProjectCursors();
      if (shouldAnnounceProject(signature, cursors[project.project], now, REMIND_AFTER_MS)) {
        cursors[project.project] = { signature, announced_at: now };
        writeProjectCursors(cursors);
        const wakeNote = project.needs_wake ? " — needs you, no live worker" : "";
        parts.push(
          `project ${project.project}: next — ${project.next_step ?? "nothing outstanding"}${wakeNote} ` +
            `(${project.workers} worker(s), ${project.open_prs} PR(s))`,
        );
      }
    } else if (project) {
      // Resolved since the last announcement — drop its cursor so a future
      // regression to the SAME signature reads as fresh news, not stale.
      const cursors = readProjectCursors();
      if (project.project in cursors) {
        delete cursors[project.project];
        writeProjectCursors(cursors);
      }
    }

    if (parts.length === 0) return undefined;
    return {
      message: {
        customType: "herdr-reconcile",
        content: `hub: ${parts.join(", ")} — ${HUB_URL}`,
        display: true,
      },
    };
  } catch {
    return undefined;
  }
}

// ---- PostToolUse: tool_result -----------------------------------------------
// Same two jobs Claude's PostToolUse wiring does: throttled mid-session
// reconciliation and alert retraction (answering a prompt in the terminal
// must not leave a stale Slack alert sitting there looking live).
//
// The interval pass is spawned fire-and-forget for the AGENT (the handler
// returns immediately; a slow sweep costs the turn nothing) but its stdout
// is COLLECTED so the envelope can be acked: the registry cursor advances
// and the page picks the history up. Nothing is injected into context —
// mid-session, the conductor learns about worker state from push-wakes
// ([HERDR-PEER-SIGNAL], omp-notify.sh) and from the status page, not from a
// 20-line report typed into the next turn. The child is deliberately NOT
// detached/unref'd: a piped-stdout child needs its parent reading.
function runIntervalReconcile(): void {
  try {
    const child = spawn("bash", [RECONCILE_SH, "interval"], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    child.on("error", () => {});
    let out = "";
    child.stdout?.on("error", () => {});
    child.stdout?.on("data", (chunk: Buffer) => {
      // Bounded: an envelope is small; a runaway child must not buffer
      // unbounded output inside the agent process.
      if (out.length < 262_144) out += chunk.toString("utf8");
    });
    child.on("close", () => {
      try {
        const env = parseEnvelope(out);
        if (env?.ackRequired) spawnDetached([RECONCILE_SH, "ack"], env.raw);
      } catch {
        // no ack -> the envelope replays next interval; still never injected.
      }
    });
  } catch {
    // spawn() throwing synchronously — same contract as spawnDetached.
  }
}

function onToolResult(): undefined {
  try {
    // Reconciliation only. Retraction moved to the approval/ask events above:
    // sweeping here fired it on every tool call in every session, and while
    // any worker sat blocked the queue was non-empty, so it always did work.
    if (reconcileAvailable) runIntervalReconcile();
  } catch {
    // omp swallows tool_result handler errors (unlike tool_call), but this
    // stays defensive for consistency — see the header contract.
  }
  return undefined;
}

// ---- Stop: agent_end ---------------------------------------------------------
// Backstop retraction. tool_approval_resolved / tool_execution_end already
// retract at the moment a prompt is answered, but a turn can end with an
// alert still queued — a pane killed mid-prompt, or a resolve that lost its
// race — so the turn boundary sweeps once more.
function onAgentEnd(): undefined {
  try {
    if (resolveAvailable) spawnDetached([RESOLVE_SH]);
  } catch {
    // see onToolResult() above.
  }
  return undefined;
}

// Conductor exit. A conductor that saves its session and lessons then stops
// used to leave every finished worker's pane open and its registry row
// `running` (2026-09-24: a closed conductor tab left four workers whose PRs
// had merged hours earlier). At the FIRST stop, if this pane conducts workers
// whose PRs have merged, tell it once to run conductor-exit.sh. Advisory,
// never a block: closing panes is cheap to do by hand later, and a stop that
// fails for another reason must not be turned into two problems. A pane with
// no HERDR_PANE_ID, or no closable workers, costs one short subprocess and
// says nothing.
let exitNudged = false;
function onSessionStop(): { continue: true; additionalContext: string } | undefined {
  try {
    if (exitNudged) return undefined;
    const pane = process.env.HERDR_PANE_ID?.trim();
    if (!pane || !safeExists(CONDUCTOR_EXIT_SH)) return undefined;
    const r = spawnSync("bash", [CONDUCTOR_EXIT_SH, `--conductor=${pane}`, "--summary"], {
      encoding: "utf8",
      timeout: 20_000,
    });
    const [closable, held] = (r.stdout ?? "").trim().split(/\s+/).map((n) => Number.parseInt(n, 10));
    if (!(closable > 0)) return undefined;
    exitNudged = true;
    return {
      continue: true,
      additionalContext:
        `<system-reminder>\nBefore finishing: this pane (${pane}) conducts ${closable} worker(s) whose PR has merged` +
        `${held > 0 ? ` and ${held} still open or unshipped` : ""}. Close the shipped ones through the gate:\n\n` +
        `  bash ${CONDUCTOR_EXIT_SH}            # dry run: shows ship/HOLD per worker\n` +
        `  bash ${CONDUCTOR_EXIT_SH} --apply    # closes only merged-PR workers, proof = PR URL + merge sha\n\n` +
        `Held workers stay open; name them in your handoff. This reminder fires once.\n</system-reminder>`,
    };
  } catch {
    return undefined; // see onToolResult(): a hook must never throw into the session.
  }
}

export default function (pi: HookAPI): void {
  pi.on("tool_call", onToolCall);
  pi.on("tool_approval_requested", onApprovalRequested);
  pi.on("tool_approval_resolved", onApprovalResolved);
  pi.on("tool_execution_start", onExecutionStart);
  pi.on("tool_execution_end", onExecutionEnd);
  pi.on("before_agent_start", onBeforeAgentStart);
  pi.on("tool_result", onToolResult);
  pi.on("agent_end", onAgentEnd);
  pi.on("session_stop", onSessionStop);
}
