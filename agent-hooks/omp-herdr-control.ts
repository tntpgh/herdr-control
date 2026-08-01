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
// THE ONE RULE THAT MATTERS: omp's tool_call dispatch is FAIL-CLOSED — per
// its own docs, "if handler throws, wrapper fails closed and blocks
// execution", and emitToolCall does NOT swallow handler errors the way it
// swallows errors from every other event below. A monitoring shim that can
// wedge the agent it watches is strictly worse than no shim at all, so every
// handler here is wrapped in an exhaustive try/catch and NEVER returns
// anything but undefined — there is no code path in this file that can
// escalate into a blocked tool call. The other three handlers keep the same
// defensive posture on principle, even though the runner swallows their
// errors, so nobody has to re-derive "is this one safe" event by event.

import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
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
const RESOLVE_SH = path.join(ROOT, "herdr-resolve.sh");

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

// ---- Notification: tool_call -----------------------------------------------
// omp's tool_call event shape isn't documented precisely enough to type
// exactly, so this narrows defensively across the plausible field names
// (`tool.name`, `toolCall.name`, `toolName`, `name`) instead of asserting
// one. The result only feeds the Slack message text — cosmetic, not
// anything gating behavior — so "best guess, never throw" is the right
// contract for it, unlike everything else in this file.
function extractToolName(event: unknown): string {
  if (!event || typeof event !== "object") return "tool";
  const nested = "tool" in event ? event.tool : "toolCall" in event ? event.toolCall : undefined;
  if (nested && typeof nested === "object" && "name" in nested && typeof nested.name === "string") {
    return nested.name;
  }
  if ("toolName" in event && typeof event.toolName === "string") return event.toolName;
  if ("name" in event && typeof event.name === "string") return event.name;
  return "tool";
}

// Fires before EVERY tool call, not just ones that end up blocked —
// omp-notify.sh does its own bounded poll for a live approval menu and exits
// 0 silently when none actually appeared, so an auto-approved call produces
// zero alert. That contract is what makes calling it unconditionally here
// cheap and safe rather than a flood of noise.
function onToolCall(event: unknown): undefined {
  try {
    if (notifyAvailable) {
      const toolName = extractToolName(event);
      const payload = JSON.stringify({
        tool: toolName,
        message: `omp tool call: ${toolName}`,
        cwd: process.cwd(),
      });
      spawnDetached([NOTIFY_SH], payload);
    }
  } catch {
    // MUST NOT throw — see the fail-closed contract at the top of this file.
  }
  // Always undefined: this handler only ever observes, it never blocks or
  // rewrites a tool call. Spelled out explicitly (rather than falling off
  // the end of the function) so a future edit can't accidentally start
  // returning a block/reason/input object from a code path meant to be a
  // pure side-effecting notifier.
  return undefined;
}

// ---- SessionStart: before_agent_start --------------------------------------
// The only handler here that runs SYNCHRONOUSLY and returns injected
// context — matching why Claude's install.sh wires session-reconcile.sh
// with async:false: the report has to be captured BEFORE the first turn's
// prompt is assembled, and an async ("defer") hook's output is not
// guaranteed to arrive in time, which would silently defeat the whole point
// of wake persistence. Bounded by `timeout` so a hung or missing
// omp-reconcile.sh degrades to "nothing injected", never a stalled session
// start.
function onBeforeAgentStart():
  | { message: { customType: string; content: string; display: boolean } }
  | undefined {
  try {
    if (!reconcileAvailable) return undefined;
    const result = spawnSync("bash", [RECONCILE_SH, "session"], {
      encoding: "utf8",
      timeout: 15_000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (result.error) return undefined; // bash or the script missing/unreadable
    const report = (result.stdout ?? "").trim();
    if (!report) return undefined; // nothing new — same no-op Claude gets
    return {
      message: {
        customType: "herdr-reconcile",
        content: report,
        display: true,
      },
    };
  } catch {
    return undefined;
  }
}

// ---- PostToolUse: tool_result -----------------------------------------------
// Same two jobs Claude's PostToolUse wiring does: throttled mid-session
// reconciliation (omp-reconcile.sh self-throttles off its own checkpoint
// file, so calling it after every tool result costs about one stat on the
// common no-op tick) and alert retraction (answering a prompt in the
// terminal must not leave a stale Slack alert sitting there looking live).
function onToolResult(): undefined {
  try {
    if (reconcileAvailable) spawnDetached([RECONCILE_SH, "interval"]);
    if (resolveAvailable) spawnDetached([RESOLVE_SH]);
  } catch {
    // omp swallows tool_result handler errors (unlike tool_call), but this
    // stays defensive for consistency — see the header contract.
  }
  return undefined;
}

// ---- Stop: agent_end ---------------------------------------------------------
// Backstop retraction. PostToolUse above already retracts after every tool
// call, but a turn can end without one more tool call firing — e.g. the
// agent's final message answers the human directly with no further tool
// use. Without this, an alert from the turn's last tool call could outlive
// the turn itself.
function onAgentEnd(): undefined {
  try {
    if (resolveAvailable) spawnDetached([RESOLVE_SH]);
  } catch {
    // see onToolResult() above.
  }
  return undefined;
}

export default function (pi: HookAPI): void {
  pi.on("tool_call", onToolCall);
  pi.on("before_agent_start", onBeforeAgentStart);
  pi.on("tool_result", onToolResult);
  pi.on("agent_end", onAgentEnd);
}
