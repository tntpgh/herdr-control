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

// Fires before EVERY tool call, not just ones that end up blocked —
// omp-notify.sh does its own bounded poll for a live approval menu and exits
// 0 silently when none actually appeared, so an auto-approved call produces
// zero alert. That contract is what makes calling it unconditionally here
// cheap and safe rather than a flood of noise.
function onToolCall(event: unknown): undefined {
  try {
    if (notifyAvailable) {
      const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
      const toolName = typeof e.toolName === "string" && e.toolName ? e.toolName : "tool";
      const detail = describeToolCall(toolName, e.input);
      const message = detail ? `${toolName}: ${detail}` : `omp tool call: ${toolName}`;
      const payload = JSON.stringify({
        tool: toolName,
        message,
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

// ---- SessionStart: before_agent_start --------------------------------------
// The only handler here that runs SYNCHRONOUSLY and returns injected
// context — matching why Claude's install.sh wires session-reconcile.sh
// with async:false: the report has to be captured BEFORE the first turn's
// prompt is assembled, and an async ("defer") hook's output is not
// guaranteed to arrive in time, which would silently defeat the whole point
// of wake persistence. Bounded by `timeout` so a hung or missing
// omp-reconcile.sh degrades to "nothing injected", never a stalled session
// start.
//
// The ack fires here, just before returning the message: for this event the
// runner keeps the first returned message, so a successfully constructed
// return IS the accepted injection. A spawnSync timeout or parse failure
// exits earlier, leaving the report unacked for redelivery.
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
    const env = parseEnvelope(result.stdout ?? "");
    if (!env || !env.report) return undefined; // nothing new — same no-op Claude gets
    if (env.ackRequired) spawnDetached([RECONCILE_SH, "ack"], env.raw);
    return {
      message: {
        customType: "herdr-reconcile",
        content: env.report,
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
// is COLLECTED, not ignored: when the sweep emits a report, it is injected
// through pi.sendMessage — the supported context-injection API for
// mid-session content — and only a sendMessage that did not throw
// acknowledges the envelope. The child is deliberately NOT detached/unref'd
// here: a piped-stdout child needs its parent reading, and this one's whole
// purpose is to be read.
function runIntervalReconcile(pi: HookAPI): void {
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
        if (!env || !env.report) return;
        if (typeof pi.sendMessage !== "function") return; // never acked -> redelivered
        pi.sendMessage({
          customType: "herdr-reconcile",
          content: env.report,
          display: true,
        });
        // sendMessage returned without throwing: the entry is persisted to
        // the session and participates in LLM context. That is the
        // "accepted injection" the acknowledgment was waiting for.
        if (env.ackRequired) spawnDetached([RECONCILE_SH, "ack"], env.raw);
      } catch {
        // sendMessage threw -> no ack -> the report replays next interval.
      }
    });
  } catch {
    // spawn() throwing synchronously — same contract as spawnDetached.
  }
}

function onToolResult(pi: HookAPI): undefined {
  try {
    if (reconcileAvailable) runIntervalReconcile(pi);
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
  pi.on("tool_result", () => onToolResult(pi));
  pi.on("agent_end", onAgentEnd);
}
