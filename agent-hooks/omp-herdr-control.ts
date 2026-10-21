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
//   * the `tool_call` guards, which deliberately return `{block:true}`:
//       - the registration/ownership guard, for a fleet-creating tool that has
//         no live central task registration; and
//       - the write-scope guard, for a REGISTERED WORKER (spawn-task.sh stamped
//         HERDR_TASK_ID + HERDR_RUN_ID) whose file-mutating tool call targets a
//         path outside its registered worktree (see workerWriteScopeBlock).
//     A failed guard is also a block: otherwise a conductor can create
//     invisible nested work, a recycled worker can act as its old generation,
//     and a worker whose registry row cannot be read writes anywhere.
//
// The guards are deliberately narrow. Ordinary tool calls remain governed by
// omp's own approval layer and herdr-select.sh's human-only command policy;
// this extension never adopts Firstmate's approval-bypass posture. A session
// that is not a registered worker (Main, a conductor, Terrence's own) never
// reaches the write-scope guard at all.
// The one exception is opt-in and off: a session launched with
// HERDR_OWNER_APPROVAL=<label> is judged call by call against a human-made
// owner record (enforceOwnerApproval; docs/design/pretool-approval.md §13).

import { spawn, spawnSync } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, renameSync, type Stats, writeFileSync } from "node:fs";
import { homedir } from "node:os";
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
const BASH_WRITE_TARGETS_SH = path.join(ROOT, "lib", "bash-write-targets.sh");
const RESOLVE_SH = path.join(ROOT, "herdr-resolve.sh");
const CONDUCTOR_EXIT_SH = path.join(ROOT, "conductor-exit.sh");
const HUB_PY = path.join(ROOT, "hub.py");
const RESOLVE_HUB_PYTHON_SH = path.join(ROOT, "launchd", "resolve-hub-python.sh");
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
function spawnDetached(args: string[], stdinInput?: string, env?: Record<string, string | undefined>): void {
  try {
    const child = spawn("bash", args, {
      detached: true,
      stdio: [stdinInput === undefined ? "ignore" : "pipe", "ignore", "ignore"],
      ...(env ? { env } : {}),
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

// ---- kill a spawned child's entire process group ---------------------------
// `detached: true` on spawn() makes the child the leader of a new POSIX
// process group (Node calls setpgid before exec), so `-pid` here addresses
// every process in that group — not just the one PID passed to spawn().
// Added 2026-10-10 (PR #273 round 2 security review, finding 2): a plain
// `child.kill()` only ever reaches the direct child; any subprocess THAT
// child is itself synchronously blocked on (a `herdr pane list`, `jq`, or
// sqlite3 call inside lib/reconcile.sh's own sweep) was never signalled and
// survived as an orphan — reproduced live: a `sleep 9999` left running
// under a killed bash wrapper, its inherited stdout pipe keeping the
// wrapper's own 'close' event from ever firing. SIGTERM first; SIGKILL
// after a short grace period if the group is still alive (the review's
// "hard-kill fallback" direction). Both signals route to the GROUP. A
// group that is already gone makes process.kill() throw ESRCH — swallowed
// like every other best-effort signal in this file.
//
// Exported (like shouldAnnounce below) purely so verify-omp-hooks.sh can
// exercise this exact mechanism directly against a forked-sleep stub,
// without waiting out runReconcileAsync's full production kill-timer.
export function killGroup(pid: number): void {
  try {
    process.kill(-pid, "SIGTERM");
  } catch {
    // group already gone
  }
  const killer = setTimeout(() => {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {
      // group already gone
    }
  }, 2_000);
  killer.unref();
}

// ---- async process capture --------------------------------------------------
// Shared by every background refresh below (hub summary, project card):
// run `cmd`, collect stdout up to a bound, call `cb(ok, stdout)` EXACTLY
// once — `ok` is the same bar the old spawnSync call sites used (`r.error
// || r.status !== 0 || !r.stdout` -> false). Never throws, never blocks:
// this is what let onBeforeAgentStart stop doing spawnSync at all
// (2026-10-10 fix/omp-hook-nonblocking — see onBeforeAgentStart's header).
//
// `timeoutMs` is REQUIRED, not optional (2026-10-10, PR #273 round 2
// security review, finding 1): the first version of this helper trusted
// every caller's own command to self-bound — true for the `curl --max-time
// 2` call sites, false for `git rev-parse` (no bound at all). A hung `git`
// (lock contention, a flaky/networked worktree, a corrupted .git) left
// `projectRefreshInFlight` stuck at `true` forever, silently and
// permanently freezing the project card with zero signal — reproduced
// live with a fake `git` that slept. Making the parameter mandatory means
// a future caller cannot repeat that mistake by omission. On timeout,
// `killGroup` reaps the whole process group (see above) and the call
// resolves `ok:false`, same as any other failure. Triggered off `exit`,
// not `close`: see killGroup's header for why `close` is the wrong signal
// to wait on when an orphaned grandchild can hold the pipe open.
function captureOutput(
  cmd: string,
  args: string[],
  opts: { cwd?: string; timeoutMs: number },
  cb: (ok: boolean, stdout: string) => void,
): void {
  let out = "";
  let done = false;
  let timer: NodeJS.Timeout | undefined;
  const finish = (ok: boolean) => {
    if (done) return;
    done = true;
    clearTimeout(timer);
    cb(ok, out);
  };
  try {
    const child = spawn(cmd, args, { cwd: opts.cwd, stdio: ["ignore", "pipe", "ignore"], detached: true });
    child.on("error", () => finish(false));
    child.stdout?.on("error", () => {});
    child.stdout?.on("data", (chunk: Buffer) => {
      if (out.length < 65_536) out += chunk.toString("utf8"); // bounded, see spawnDetached header
    });
    child.on("exit", (code) => finish(code === 0 && out.length > 0));
    if (child.pid) {
      const pid = child.pid;
      timer = setTimeout(() => {
        killGroup(pid);
        finish(false);
      }, opts.timeoutMs);
      timer.unref();
    }
  } catch {
    finish(false);
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

function pretoolRegistrationBlock(event: unknown): { block: true; reason: string } | undefined {
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
      // The guard reads the input to exempt read-only task batches (scout /
      // security-reviewer only); anything it cannot parse stays refused.
      input: JSON.stringify(input),
      stdio: ["pipe", "pipe", "pipe"],
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

// ---- worker write scope ------------------------------------------------------
// Backlog (xi), 2026-09-26: registered worker w2F:p6 (manifest `writes:
// [tmp/**]`) appended to ~/Code/herdr-control/.handoffs/notepad.md with omp's
// edit tool right after the same write as a bash command had been denied, and
// worker w2F:p2 had edited the main checkout's lib/prompt-parse.sh the same
// way. Workers run `--approval-mode write`, so edit/write never prompt, and
// nothing checked them. lib/command-policy.sh judges the bash path; this
// guard judges the edit/write path.
//
// WHO is checked: only a session spawn-task.sh stamped with BOTH HERDR_TASK_ID
// and HERDR_RUN_ID. Both are read ONCE, at module load, so a later in-process
// change to process.env cannot un-register the session. The worktree comes
// from the registry row (read_task, lib/run-registry.sh), never from the
// worker-writable .handoffs/identity.json. HERDR_PANE_ID is NOT an identity:
// herdr sets it in every pane (Main's too) and recycles pane ids. When the env
// names a task but its row can't be read or has no worktree, every
// file-mutating call blocks (fail closed). A session with no HERDR_TASK_ID
// returns before any of this runs.
//
// WHAT is allowed: the resolved target must be inside the worktree's resolved
// path and not under a `.git` or `.env*` segment there. `.handoffs/**` inside
// the worktree stays writable, because workers keep SPEC/PROOF/events there.
// Scratch outside the worktree is allowed only under /tmp or $TMPDIR, and only
// for a file that doesn't exist yet or that this session created (recorded on
// the call's successful tool_result, not when it is checked). Live workers
// write commit messages and probes there, and the rule stops a worker
// rewriting a conductor's /tmp brief or red tests. A file inside the worktree
// that is a hard link (nlink > 1) is refused, since a write goes through it.
// The manifest's `writes` globs are NOT enforced here. They are the output
// scope that lets a curl GET clear review (lib/task-manifest.sh,
// docs/approval-policy.md), every live manifest is `writes: [tmp/**]`, and
// enforcing them would block every implement worker's source edits.
//
// HOW a target resolves: first every form omp itself may rewrite it to
// (candidateForms: a copied `[path#TAG]`, a leading `@` or `:`, and ast_edit's
// quote-strip and `;`/`,`/whitespace split), each checked. Then
// `~` / `~/` → $HOME at load (`~user` is refused);
// relative → the session cwd; `file://` → its path. Both spellings must land in
// scope: (a) as given and (b) with `..` normalized lexically. omp may do
// either before opening, and the kernel follows each symlink before applying
// `..`. Each spelling is walked component by component with every existing
// symlink followed, dangling ones included, because a write through a
// dangling link creates its target. For `archive.zip:member` and
// `db.sqlite:table`, every prefix ending before a `:` is checked too.
// Internal URLs: `agent://` (a peer message) and `proc://` (stdin to the
// worker's own job) write no file. `local://` is omp's per-session artifact dir
// (~/.omp/agent/sessions/<cwd>/<session>/local/); omp itself refuses `..`
// there, and this guard refuses `..`, a leading `/` and `~`. `write
// xd://<device>` runs that device, so its JSON content is judged exactly as a
// direct call to it would be (an unknown device by any path field it carries).
// Every other scheme (`ssh://`, `memory://`, `skill://`, …) is refused.
//
// WHICH tools: write, edit (hashline `[PATH#TAG]` headers and `MV DEST`, both
// possibly indented; apply_patch `*** … File:` / `*** Move to:` lines; patch
// mode `edits[].rename`; any path field), multiedit, ast_edit, notebook*, lsp
// (every action not known read-only, incl. rename_file's `new_name`; `request`
// refused), notepad.ts's notepad_append/priority (on the notepad file they
// write), bash/shell (#184: redirect `>`/`>>`/`>|`/`&>`/`&>>`/`N>`/`N>>`,
// `tee`, heredoc `cat > F <<EOF`, `cp`/`mv`/`install`/`ln` destination,
// `dd of=`, `sed`/`perl -i`, `touch`, `truncate` targets — extracted by
// lib/bash-write-targets.sh, the SAME parser lib/command-policy.sh's
// classify_command uses for the peer-approval side of this guard; a
// target it cannot read statically fails closed, same as everything
// below), `manage_skill` (create/update/delete all write
// `~/.omp/agent/managed-skills/<name>/SKILL.md`, exactly like any other
// file target — the 2026-10-18 incident this fix closes was a worker
// overwriting a skill this way with NO check at all) and `learn` when it
// carries a `skill` block (same managed-skills path), and by shape any tool
// whose name says it mutates (write/edit/patch/rename/…) AND carries a
// path-like field. Beyond that: a tool name this guard has never seen gives
// no verb signal (manage_skill didn't either), so it is judged by what it
// carries — any path-like field fails closed exactly like a write, unless the
// name is on the known-read-only/omp-internal-state allowlist just above
// `mutationTargets` (read, grep, glob, task, retain, recall, …: omp memory
// and delegation, not a host path — docs/design/pretool-approval.md §3).
// NOT covered here: `eval` (arbitrary code; omp's approval layer governs it
// — #174's closed-world design), and plain `learn` (no `skill` block: writes
// the shared mnemopi.db, never a worktree-scoped path).
const WORKER_TASK_ID = process.env.HERDR_TASK_ID?.trim() ?? "";
const WORKER_RUN_ID = process.env.HERDR_RUN_ID?.trim() ?? "";
const LOAD_HOME = process.env.HOME?.trim() || homedir();
const LOAD_TMPDIR = process.env.TMPDIR?.trim() ?? "";
const LOAD_RUN_STATE_DIR = process.env.HERDR_RUN_STATE_DIR?.trim() ?? "";
// Slice (b), bound-bash: default ON, the SAME default config.sh applies
// (`: "${HERDR_BOUND_BASH:=1}"`: unset or empty -> "1"). An OFF default here
// split-brained a worker whose omp env lacks the stamp: this hook never
// treated a deferred bash request as bound and wrote no proposal, so the
// conductor could not answer it. Binding here proves IDENTITY only — the
// canonical command still goes through herdr-select.sh's Path A command-policy
// check (classify_command/conductor_reserved_reason) before any bash/shell
// approval resolves; this flag never changes who may approve or which
// categories are allowed. Otherwise exact "1" only, no trim: an explicit "0"
// is the rollback and matches herdr-select.sh and prompt-occurrence.py.
const HERDR_BOUND_BASH = (process.env.HERDR_BOUND_BASH || "1") === "1";
// ~/.omp/agent/extensions/notepad.ts writes $NOTEPAD_PATH (absolute, or
// relative to the session cwd) when set, else <cwd>/.handoffs/notepad.md or
// the legacy <cwd>/.omc/notepad.md. Its mutating tools are judged on exactly
// those files, whether called directly or as `write xd://notepad_append`.
const LOAD_NOTEPAD_PATH = process.env.NOTEPAD_PATH?.trim() ?? "";
const NOTEPAD_READONLY_TOOLS: Record<string, true> = { notepad_read: true, notepad_stats: true };
const RUN_REGISTRY_SH = path.join(ROOT, "lib", "run-registry.sh");

type Block = { block: true; reason: string };

let registeredWorktreeReal: string | undefined; // cached after the first successful read
const scratchCreatedHere = new Set<string>();
const pendingScratch = new Map<string, string[]>(); // toolCallId -> scratch files it would create

function readRegisteredWorktree(): { worktree: string } | { error: string } {
  if (registeredWorktreeReal) return { worktree: registeredWorktreeReal };
  if (!WORKER_RUN_ID) return { error: "HERDR_TASK_ID is set but HERDR_RUN_ID is not" };
  if (!safeExists(RUN_REGISTRY_SH)) return { error: `${RUN_REGISTRY_SH} is missing` };
  const env: Record<string, string | undefined> = { ...process.env, HOME: LOAD_HOME };
  if (LOAD_RUN_STATE_DIR) env.HERDR_RUN_STATE_DIR = LOAD_RUN_STATE_DIR;
  else delete env.HERDR_RUN_STATE_DIR;
  const r = spawnSync(
    "bash",
    ["-c", '. "$1" && read_task "$2" "$3"', "herdr-write-scope", RUN_REGISTRY_SH, WORKER_RUN_ID, WORKER_TASK_ID],
    { encoding: "utf8", timeout: 5_000, stdio: ["ignore", "pipe", "pipe"], env },
  );
  if (r.error || r.status !== 0) {
    return { error: `the registry read failed (${r.error ? r.error.message : `exit ${r.status}`})` };
  }
  let row: unknown;
  try {
    row = JSON.parse((r.stdout ?? "").trim());
  } catch {
    return { error: `no registry row for run ${WORKER_RUN_ID} task ${WORKER_TASK_ID}` };
  }
  const wt = row && typeof row === "object" ? (row as Record<string, unknown>).worktree : undefined;
  if (typeof wt !== "string" || !path.isAbsolute(wt)) return { error: "the registry row has no absolute worktree" };
  const real = resolveFollowingLinks(wt);
  if (!real || !safeExists(real)) return { error: `the registered worktree ${wt} does not resolve` };
  registeredWorktreeReal = real;
  return { worktree: real };
}

// Prefetched once at module load (session start), same reasoning and shape
// as prefetchRegistryApproval() below: a registered worker's FIRST bash/
// write/edit call must not pay this spawnSync's cost synchronously on top
// of mutationTargets' own bash-write-targets.sh spawn — together they blew
// verify-pretool-shadow.sh's <50ms bash/eval handler budget (measured:
// bash_reserved 53-74ms, the registry spawnSync alone costing tens of ms
// over an unwarmed sqlite3 connection). A tool call that arrives before
// this answers falls back to the synchronous read in readRegisteredWorktree().
//
// Round 7 follow-up (Main review): this spawned NO timeout at all — a
// hung `read_task` (e.g. a wedged python3 interpreter it calls through
// _registry_python/resolve-hub-python.sh) left the child alive forever,
// and because its stdout is PIPED (captured into `out`) rather than
// ignored, the dangling pipe to a still-running grandchild kept the
// WHOLE node/bun process from exiting even though `child.unref()` alone
// was already in place — reproduced live with a fake slow interpreter
// (observed process tree: bun -> bash read_task -> sleep). Fixed with the
// exact same bounded-timeout + process-GROUP kill shape captureOutput
// above already uses for this precise class of bug (PR #273 round 2
// security review, finding 2): `detached: true` so `killGroup` can reach
// a grandchild the direct child is itself synchronously blocked on, not
// just the immediate bash wrapper. Logged and counted, never silent.
const PREFETCH_SPAWN_TIMEOUT_MS = 4_000;
let prefetchRegisteredWorktreeTimedOut = 0;

function prefetchRegisteredWorktree(): void {
  if (registeredWorktreeReal || !WORKER_TASK_ID || !WORKER_RUN_ID) return;
  try {
    if (!safeExists(RUN_REGISTRY_SH)) return;
    const env: Record<string, string | undefined> = { ...process.env, HOME: LOAD_HOME };
    if (LOAD_RUN_STATE_DIR) env.HERDR_RUN_STATE_DIR = LOAD_RUN_STATE_DIR;
    else delete env.HERDR_RUN_STATE_DIR;
    const child = spawn(
      "bash",
      ["-c", '. "$1" && read_task "$2" "$3"', "herdr-write-scope", RUN_REGISTRY_SH, WORKER_RUN_ID, WORKER_TASK_ID],
      { stdio: ["ignore", "pipe", "pipe"], env, detached: true },
    );
    let out = "";
    let done = false;
    let timer: NodeJS.Timeout | undefined;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
    };
    child.on("error", finish);
    child.stdout?.on("data", (d) => { out += String(d); });
    child.on("close", (code) => {
      finish();
      if (registeredWorktreeReal || code !== 0) return;
      try {
        const row: unknown = JSON.parse(out.trim());
        const wt = row && typeof row === "object" ? (row as Record<string, unknown>).worktree : undefined;
        if (typeof wt !== "string" || !path.isAbsolute(wt)) return;
        const real = resolveFollowingLinks(wt);
        if (real && safeExists(real)) registeredWorktreeReal = real;
      } catch {
        // best effort; the synchronous read in readRegisteredWorktree() is the fallback
      }
    });
    if (child.pid) {
      const pid = child.pid;
      timer = setTimeout(() => {
        prefetchRegisteredWorktreeTimedOut++;
        console.error(`herdr: prefetchRegisteredWorktree: bash/read_task did not finish within ${PREFETCH_SPAWN_TIMEOUT_MS}ms — killing its process group (total prefetch timeouts this session: ${prefetchRegisteredWorktreeTimedOut})`);
        killGroup(pid);
        finish();
      }, PREFETCH_SPAWN_TIMEOUT_MS);
      timer.unref();
    }
    child.unref();
  } catch {
    // best effort; the synchronous read is the fallback
  }
}
prefetchRegisteredWorktree();

// mutationTargets()'s own bash-write-targets.sh spawnSync (lib/command-policy.sh,
// #184's write-scope parser, ~5,926 lines) is the other synchronous subprocess
// every registered worker's bash/shell call pays, and it is NOT cacheable the
// way the registry reads above are — its result depends on the exact command
// text. Measured directly (tmp/ scripts, round 2 of this task): the FIRST such
// spawnSync a session issues costs roughly 2x a later one (e.g. ~70ms vs
// ~35-40ms for the same command, repeatable across clean runs) — a real OS/
// CPU-scheduling cost paid by the first process this bash interpreter forks
// after the module's own idle startup gap, not something tied to command
// content or verdict. A single warm spawnSync of the SAME script (trivial
// "true" command, so it exercises the identical source-and-run path without
// being a provable write target) during that idle gap measurably halves the
// first real call's cost in repeated clean-environment testing (~52ms down to
// ~44ms median for the `bash_reserved` probe). Detached/fire-and-forget like
// the prefetch above: its own result is never read, it only warms whatever
// OS/runtime state the next real spawnSync benefits from.
function prefetchBashWriteTargetsWarm(): void {
  if (!WORKER_TASK_ID) return;
  try {
    if (!safeExists(BASH_WRITE_TARGETS_SH)) return;
    const child = spawn("bash", [BASH_WRITE_TARGETS_SH, "true", "."], { stdio: ["ignore", "ignore", "ignore"] });
    child.on("error", () => {});
    child.unref();
  } catch {
    // best effort
  }
}
prefetchBashWriteTargetsWarm();

// The kernel's view of an absolute path: walk it component by component,
// splicing in each symlink's target (dangling or not) before applying the next
// `..`. An absent component is taken as-is, because a write creates it as a
// real entry. undefined = more than 40 links (a loop).
function resolveFollowingLinks(abs: string): string | undefined {
  let pending = abs.split("/").filter(Boolean);
  let cur = "/";
  let hops = 0;
  while (pending.length > 0) {
    const seg = pending.shift() as string;
    if (seg === ".") continue;
    if (seg === "..") {
      cur = path.dirname(cur);
      continue;
    }
    const next = cur === "/" ? `/${seg}` : `${cur}/${seg}`;
    let isLink = false;
    try {
      isLink = lstatSync(next).isSymbolicLink();
    } catch {
      // absent (or unreadable, which the write itself will hit): not a link
    }
    if (!isLink) {
      cur = next;
      continue;
    }
    if (++hops > 40) return undefined;
    const target = readlinkSync(next);
    if (target.startsWith("/")) cur = "/";
    pending = [...target.split("/").filter(Boolean), ...pending];
  }
  return cur;
}

function isUnder(p: string, root: string): boolean {
  return p === root || p.startsWith(root === "/" ? "/" : `${root}/`);
}

function unquote(s: string): string {
  const t = s.trim();
  return t.length >= 2 && (t[0] === '"' || t[0] === "'") && t[t.length - 1] === t[0] ? t.slice(1, -1) : t;
}

const PATH_FIELDS = ["path", "file_path", "filePath", "filepath", "file", "notebook_path", "target", "dest", "destination", "new_path", "newPath"];

function pathFields(rec: Record<string, unknown>): string[] {
  const out: string[] = [];
  for (const k of [...PATH_FIELDS, "paths", "files"]) {
    const v = rec[k];
    if (typeof v === "string" && v.length > 0) out.push(v);
    else if (Array.isArray(v)) for (const x of v) if (typeof x === "string" && x.length > 0) out.push(x);
  }
  return out;
}

// Every file an edit call's `input` touches. omp's hashline parser accepts
// indented ops, so each line is judged on its trimmed form. A trimmed line
// starting `[` is always a section header (body rows start `+`), and a header
// or MV line that doesn't parse refuses the call rather than being skipped. A
// relative MV destination is checked against both the cwd and the moved file's
// directory.
function editInputTargets(text: string): string[] | string {
  const out: string[] = [];
  let lastHeader = "";
  for (const line of text.split(/\r\n|\r|\n/)) {
    const t = line.trim();
    if (t.startsWith("[")) {
      const m = /^\[(.+)#[0-9A-Fa-f]{4}\]$/.exec(t);
      if (!m) return `cannot parse the edit section header ${JSON.stringify(t.slice(0, 120))}`;
      lastHeader = unquote(m[1]);
      out.push(lastHeader);
      continue;
    }
    if (/^mv(\s|$)/i.test(t)) {
      const dest = unquote(t.slice(2));
      if (!dest) return "an MV op names no destination";
      out.push(dest);
      if (lastHeader && !path.isAbsolute(dest) && !/^[~@:[]/.test(dest)) out.push(path.join(path.dirname(lastHeader), dest));
      continue;
    }
    const patch = /^\*{3}\s+(?:(?:Add|Update|Delete|Edit)\s+File|Move\s+to):\s*(.+)$/i.exec(t);
    if (patch) out.push(unquote(patch[1]));
  }
  return out;
}

const MUTATING_NAME = /(write|edit|patch|notebook|rename|move|delete|remove|mkdir|create|replace|append|save)/;
// `request` sends an arbitrary LSP method; the server can answer with a
// workspace/applyEdit that omp applies to any URI, so it counts as mutating.
const LSP_MUTATING_ACTION = /(rename|code_?action|format|fix|organi[sz]e|apply|request)/;
const LSP_READONLY_ACTION =
  /^(definition|type_?definition|declaration|implementation|references|hover|signature(_help)?|symbols?|document_symbols?|workspace_symbols?|diagnostics|status|incoming_calls|outgoing_calls|call_hierarchy|completion|highlight)$/;

// Known read-only or omp-internal-state tools: reaching the fallback below
// with a path-like field is incidental for these (read's/grep's own search
// target, not a write), never a mutation. `retain`/`recall`/`reflect`/
// `report_issue`/`secret_present` and the read-only xd:// devices write
// omp's own shared state (mnemopi.db) or nothing at all, never a
// worktree-scoped path (docs/design/pretool-approval.md §3). `mcp__*` has
// its own existing registration guard (lib/pretool-registration.sh).
const KNOWN_READONLY_OR_INTERNAL: Record<string, true> = {
  read: true, grep: true, glob: true, find: true, ast_grep: true, web_search: true, hub: true, github: true,
  task: true, agent: true, todo: true, wait: true, ask: true, checkpoint: true, rewind: true, resolve: true,
  security_scan: true, new_context: true, context_notes: true, retain: true, recall: true,
  reflect: true, report_issue: true, secret_present: true, fleet_status: true, pr_ready: true,
  handoff_debt: true, single_copy_scan: true, worktree_debt: true, suite_wired: true,
  decisions_open: true, project_status: true,
};

// manage_skill create/update/delete and learn's optional `skill` block both
// name a skill by `name`, resolved the same way manage_skill itself resolves
// it (kebab-case; see its SKILL.md): reject anything with a path separator
// or `..` rather than let a crafted slug pick a different target file.
function managedSkillTarget(skillName: string): string | MutationTargets {
  const n = skillName.trim();
  if (!n) return "names no skill";
  if (n.includes("/") || n.includes("\\") || n === ".." || n.includes("\0")) {
    return `skill name ${JSON.stringify(skillName)} is not a safe slug`;
  }
  return { raw: [path.join(LOAD_HOME, ".omp", "agent", "managed-skills", n, "SKILL.md")] };
}

// The raw targets a file-mutating call names; undefined when the tool is not
// file-mutating (it is never checked); a string when it is mutating but its
// targets cannot be read (refused).
interface MutationTargets {
  raw: string[];
  xdContent?: string; // write's content, parsed only for an xd:// target
  globOk?: boolean; // ast_edit expands globs; every other tool takes a path literally
}

function mutationTargets(toolName: string, rec: Record<string, unknown>, cwd: string): MutationTargets | string | undefined {
  const name = toolName.toLowerCase().replace(/[^a-z0-9_]/g, "");
  if (name === "write") {
    const targets = pathFields(rec);
    if (targets.length === 0) return "write names no path";
    return { raw: targets, xdContent: typeof rec.content === "string" ? rec.content : undefined };
  }
  if (name === "edit") {
    const targets = pathFields(rec);
    for (const k of ["input", "patch", "diff"]) {
      if (typeof rec[k] !== "string") continue;
      const got = editInputTargets(rec[k] as string);
      if (typeof got === "string") return got;
      targets.push(...got);
    }
    // patch mode: {path, edits: [{op, rename, diff}]}; the move target is nested.
    if (Array.isArray(rec.edits)) {
      for (const entry of rec.edits) {
        if (!entry || typeof entry !== "object") continue;
        const e = entry as Record<string, unknown>;
        targets.push(...pathFields(e));
        if (typeof e.rename === "string" && e.rename) targets.push(e.rename);
      }
    }
    return targets.length > 0 ? { raw: targets } : "cannot tell which file this edit touches";
  }
  if (name === "bash" || name === "shell") {
    // #184: reuse lib/command-policy.sh's parser (lib/bash-write-targets.sh,
    // same spawnSync-a-script pattern pretoolRegistrationBlock uses for
    // lib/pretool-registration.sh) rather than reimplementing redirect/verb
    // parsing here — one parser, shared with classify_command's peer-
    // approval rule.
    const command = typeof rec.command === "string" ? rec.command : "";
    if (!command.trim()) return undefined;
    const bashCwd = typeof rec.cwd === "string" && rec.cwd.length > 0 ? rec.cwd : cwd;
    if (!safeExists(BASH_WRITE_TARGETS_SH)) {
      return "herdr bash write-scope parser is unavailable; refusing to judge this command's write targets";
    }
    const r = spawnSync("bash", [BASH_WRITE_TARGETS_SH, command, bashCwd], {
      encoding: "utf8",
      timeout: 5_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (r.error || r.status !== 0) {
      return `bash write-target extraction failed (${r.error ? r.error.message : `exit ${r.status}`})`;
    }
    const targets: string[] = [];
    for (const line of (r.stdout ?? "").split("\n")) {
      const l = line.trimEnd();
      if (!l) continue;
      const tab = l.indexOf("\t");
      if (tab < 0) continue;
      const kind = l.slice(0, tab);
      const val = l.slice(tab + 1);
      if (kind === "COMPUTED") return `bash write target ${JSON.stringify(val)} cannot be verified statically (substitution, unquoted $VAR, glob, or ~user)`;
      if (kind === "UNPARSED") return `bash command cannot be parsed safely (${val})`;
      if (kind === "TARGET") targets.push(val);
    }
    // Every target lib/bash-write-targets.sh emits is already an absolute,
    // lexically-collapsed path (cwd-joined, cd-adjusted there since only it
    // tracks the command's internal `cd DIR &&` chain) — globOk stays false
    // so checkFileTarget resolves it exactly like an edit/write path, same
    // symlink-following, .git/.env exclusion, and scratch-root rules.
    return targets.length > 0 ? { raw: targets } : undefined;
  }
  if (name === "lsp") {
    // omp tiers lsp by a read-only action set it does not export, so this errs
    // the other way: any action not known read-only is checked when it names
    // a file, and a known-mutating one that names none is refused.
    const action = typeof rec.action === "string" ? rec.action.toLowerCase() : "";
    if (LSP_READONLY_ACTION.test(action)) return undefined;
    if (action === "request") return "lsp request can apply a server edit to any file; not available to a worker";
    const targets = pathFields(rec);
    // rename_file / move_file take the destination in `new_name`.
    if (action.includes("file") && typeof rec.new_name === "string" && rec.new_name) targets.push(rec.new_name);
    if (targets.length > 0) return { raw: targets };
    return LSP_MUTATING_ACTION.test(action) ? `lsp ${action} names no file` : undefined;
  }
  if (name.startsWith("notepad_")) {
    if (NOTEPAD_READONLY_TOOLS[name]) return undefined;
    return { raw: LOAD_NOTEPAD_PATH ? [LOAD_NOTEPAD_PATH] : [".handoffs/notepad.md", ".omc/notepad.md"] };
  }
  if (name === "ast_edit" || name === "astedit") {
    const targets = pathFields(rec);
    return targets.length > 0 ? { raw: targets, globOk: true } : `${toolName} names no path`;
  }
  if (name === "multiedit" || name.startsWith("notebook")) {
    const targets = pathFields(rec);
    return targets.length > 0 ? { raw: targets } : `${toolName} names no path`;
  }
  if (name === "manage_skill") {
    // create/update/delete all target the same file by `name`; a worker's
    // `manage_skill` call never has a legitimate reason to resolve inside
    // its own worktree, so this always refuses one (the 2026-10-18 incident
    // this fix closes: see SPEC.md).
    return managedSkillTarget(typeof rec.name === "string" ? rec.name : "");
  }
  if (name === "learn") {
    // Plain learn writes the shared mnemopi.db (not a worktree-scoped path:
    // see KNOWN_READONLY_OR_INTERNAL's `retain`/`recall` note above); a
    // `skill` block additionally mints/updates a managed skill file.
    const skill = rec.skill;
    if (!skill || typeof skill !== "object") return undefined;
    const s = skill as Record<string, unknown>;
    return managedSkillTarget(typeof s.name === "string" ? s.name : "");
  }
  if (name === "memory_edit") {
    // forget/invalidate/update rewrite shared mnemopi memories by id, no path
    // to scope: the same id-addressed shared-state mutation as manage_skill
    // (PR #323 review HIGH). Curation is the conductor's.
    return "memory curation (forget/invalidate/update) is reserved for the conductor";
  }
  if (KNOWN_READONLY_OR_INTERNAL[name]) return undefined;
  if (MUTATING_NAME.test(name)) {
    const targets = pathFields(rec);
    return targets.length > 0 ? { raw: targets } : undefined;
  }
  // An omp tool/xd:// device this guard has never named above: its tool name
  // gives no verb signal either way (manage_skill didn't — the incident this
  // fix closes), so judge it by what it carries. A path-like field fails
  // closed exactly like a write; nothing path-like stays unchecked, same as
  // every tool above that returns undefined.
  const targets = pathFields(rec);
  return targets.length > 0 ? { raw: targets } : undefined;
}

// A file path's absolute spellings (see HOW above), or a refusal string.
function absoluteSpellings(raw: string, cwd: string): string[] | string {
  let p = raw.trim();
  if (/^file:\/\//i.test(p)) {
    try {
      p = fileURLToPath(p);
    } catch {
      return `cannot parse the file URL ${raw}`;
    }
  }
  if (p === "~" || p.startsWith("~/")) p = LOAD_HOME + p.slice(1);
  else if (p.startsWith("~")) return `cannot resolve ${raw} (~user paths are refused)`;
  const abs = path.isAbsolute(p) ? p : `${cwd}/${p}`;
  const bases = [abs];
  for (let i = abs.indexOf(":"); i > 0; i = abs.indexOf(":", i + 1)) bases.push(abs.slice(0, i));
  const out: string[] = [];
  for (const b of bases) {
    for (const spelling of [b, path.resolve(b)]) {
      const r = resolveFollowingLinks(spelling);
      if (!r) return `${raw} is a symlink loop`;
      out.push(r);
    }
  }
  return out;
}

function scratchRoots(): string[] {
  const roots: string[] = [];
  for (const r of ["/tmp", LOAD_TMPDIR]) {
    if (!r || !path.isAbsolute(r)) continue;
    const real = resolveFollowingLinks(r);
    if (real && real !== "/") roots.push(real.replace(/\/+$/, ""));
  }
  return roots;
}

// undefined = allowed; otherwise why not. `newScratch` collects the scratch
// files this call would create, recorded only once the whole call is allowed.
function checkFileTarget(raw: string, globOk: boolean, cwd: string, wt: string, newScratch: string[]): string | undefined {
  const glob = globOk ? /[*?[\]{}]/.exec(raw) : null;
  let target = raw;
  if (glob) {
    // ast_edit takes globs: the literal directory prefix must be in scope, and
    // nothing after the first wildcard may climb out of it.
    const cut = raw.lastIndexOf("/", glob.index);
    if (raw.slice(cut + 1).split("/").includes("..")) return `the glob ${raw} climbs out with ..`;
    target = cut < 0 ? "." : raw.slice(0, cut) || "/";
  }
  const spellings = absoluteSpellings(target, cwd);
  if (typeof spellings === "string") return spellings;
  const roots = scratchRoots();
  for (const resolved of spellings) {
    let st: Stats | undefined;
    try {
      st = lstatSync(resolved);
    } catch {
      st = undefined;
    }
    if (isUnder(resolved, wt)) {
      const rel = resolved.slice(wt.length + 1).toLowerCase().split("/");
      if (rel.includes(".git")) return `${raw} resolves to ${resolved}, inside .git`;
      if (rel.some((s) => s.startsWith(".env"))) return `${raw} resolves to ${resolved}, a .env* file`;
      if (st?.isFile() && st.nlink > 1) return `${raw} resolves to ${resolved}, a hard link (a write reaches its other names)`;
      continue;
    }
    const root = roots.find((r) => resolved !== r && isUnder(resolved, r));
    if (root && !glob) {
      if (st && !scratchCreatedHere.has(resolved)) {
        return `${raw} resolves to ${resolved}, an existing scratch file this session did not create`;
      }
      if (st?.isFile() && st.nlink > 1) return `${raw} resolves to ${resolved}, a hard link`;
      newScratch.push(resolved);
      continue;
    }
    return `${raw} resolves to ${resolved}, outside your worktree`;
  }
  return undefined;
}

// Every spelling omp itself may turn `raw` into before resolving it (omp 18.3.2
// path-utils/write.ts/conflict-detect.ts, found by the PR #159 reviews). It
// unwraps a copied `[path#TAG]` / `[path]`, drops a leading `@` before `/` or
// `~`, drops a leading `:` before `/`, `~`, `./` or `../`, and routes
// `<file>:conflict://N` to the conflict:// handler (refused below). ast_edit
// also turns `\` into `/`, strips surrounding double quotes, and splits one
// entry on `;`, `,` and whitespace with no limit. `\`→`/` is queued for every
// tool, since an extra form can only add a check. Every form is checked, so
// whichever one omp opens is in scope. Past MAX_FORMS the whole target is
// refused rather than judged on a partial list.
const MAX_FORMS = 512;

function candidateForms(raw: string, globOk: boolean): string[] | string {
  const seen = new Set<string>();
  const queue = [raw.trim()];
  while (queue.length > 0) {
    const f = queue.shift() as string;
    if (!f || seen.has(f)) continue;
    if (seen.size >= MAX_FORMS) return `${raw.slice(0, 120)} expands to more than ${MAX_FORMS} path forms`;
    seen.add(f);
    const bracket = /^\[(.+?)(?:#[0-9A-Fa-f]{4})?\]$/.exec(f);
    if (bracket) queue.push(bracket[1].trim());
    if (/^@[/~]/.test(f)) queue.push(f.slice(1));
    if (/^:(?:[/~]|\.\.?\/)/.test(f)) queue.push(f.slice(1));
    const conflict = /^(.+):(conflict:\/\/.+)$/i.exec(f);
    if (conflict) queue.push(conflict[2]);
    if (f.includes("\\") && !/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(f)) queue.push(f.replace(/\\/g, "/"));
    if (globOk) {
      if (f.length >= 2 && f.startsWith('"') && f.endsWith('"')) queue.push(f.slice(1, -1));
      const parts = f.split(/[;,\s]+/).filter(Boolean);
      if (parts.length > 1) queue.push(...parts);
    }
  }
  return [...seen];
}

// undefined = allowed; otherwise why not. Internal URLs first (see HOW above).
function checkTarget(
  raw: string,
  targets: MutationTargets,
  cwd: string,
  wt: string,
  newScratch: string[],
): string | undefined {
  const forms = candidateForms(raw, targets.globOk === true);
  if (typeof forms === "string") return forms;
  for (const form of forms) {
    const why = checkOneForm(form, targets, cwd, wt, newScratch);
    if (why) return form === raw.trim() ? why : `${raw} (as ${form}): ${why}`;
  }
  return undefined;
}

function checkOneForm(
  raw: string,
  targets: MutationTargets,
  cwd: string,
  wt: string,
  newScratch: string[],
): string | undefined {
  const scheme = /^([A-Za-z][A-Za-z0-9+.-]*):\/\//.exec(raw);
  if (!scheme || scheme[1].toLowerCase() === "file") return checkFileTarget(raw, targets.globOk === true, cwd, wt, newScratch);
  const kind = scheme[1].toLowerCase();
  const rest = raw.slice(scheme[0].length);
  if (kind === "agent" || kind === "proc") return undefined;
  if (kind === "local") {
    let decoded = rest;
    try {
      decoded = decodeURIComponent(rest);
    } catch {
      return `cannot decode ${raw}`;
    }
    if (decoded.startsWith("/") || decoded.startsWith("~") || decoded.split(/[/\\]/).includes("..")) {
      return `${raw} leaves the session's local:// dir`;
    }
    return undefined;
  }
  if (kind === "xd") {
    if (targets.xdContent === undefined) return undefined;
    let args: unknown;
    try {
      args = JSON.parse(targets.xdContent);
    } catch {
      return undefined; // a device that takes prose (resolve/reject), not a path
    }
    if (!args || typeof args !== "object") return undefined;
    // `write xd://<tool>` runs <tool>: judge its JSON exactly as a direct call,
    // and a device this file doesn't know by any path field it carries.
    const device = rest.split(/[/?#]/)[0] ?? "";
    const rec = args as Record<string, unknown>;
    const inner = mutationTargets(device, rec, cwd) ?? { raw: pathFields(rec) };
    if (typeof inner === "string") return `${raw}: ${inner}`;
    for (const p of inner.raw) {
      const why = checkTarget(p, inner, cwd, wt, newScratch);
      if (why) return `${raw}: ${why}`;
    }
    return undefined;
  }
  return `${kind}:// is outside your worktree`;
}

function workerWriteScopeBlock(event: unknown, ctx: unknown): Block | undefined {
  if (!WORKER_TASK_ID) return undefined; // not a registered worker: never checked
  let toolName = "tool";
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    toolName = typeof e.toolName === "string" && e.toolName ? e.toolName : "tool";
    const input = e.input && typeof e.input === "object" ? (e.input as Record<string, unknown>) : {};
    const c = ctx && typeof ctx === "object" ? (ctx as Record<string, unknown>).cwd : undefined;
    const cwd = typeof c === "string" && path.isAbsolute(c) ? c : process.cwd();
    const targets = mutationTargets(toolName, input, cwd);
    if (targets === undefined) return undefined;
    // A peer message or a job's stdin names no file, and must still work when
    // the registry is unreadable: it is how a stuck worker reports being stuck.
    if (typeof targets !== "string" && targets.raw.every((r) => /^(agent|proc):\/\//i.test(r.trim()))) return undefined;
    const scope = readRegisteredWorktree();
    const wtNote = "worktree" in scope ? scope.worktree : "(unreadable)";
    const refuse = (why: string): Block => ({
      block: true,
      reason:
        `herdr write-scope: ${toolName} refused — ${why}. You are registered worker ${WORKER_TASK_ID}; ` +
        `write only under your worktree ${wtNote} (scratch: its tmp/, or a NEW file under /tmp). ` +
        "For anything else (the main checkout, another repo, a notepad that isn't yours) ask your " +
        "conductor/operator to do it. Do not retry it through another tool.",
    });
    if (typeof targets === "string") return refuse(targets);
    if ("error" in scope) return refuse(`cannot verify your registered worktree: ${scope.error}`);
    const newScratch: string[] = [];
    for (const raw of targets.raw) {
      const why = checkTarget(raw, targets, cwd, scope.worktree, newScratch);
      if (why) return refuse(why);
    }
    // Recorded as this session's own only once omp reports the call succeeded
    // (onToolResult), so an allowed-but-failed write can't pre-claim a path a
    // conductor creates later.
    if (newScratch.length > 0 && typeof e.toolCallId === "string") {
      pendingScratch.set(e.toolCallId, newScratch);
      while (pendingScratch.size > INPUT_CACHE_MAX) {
        const oldest = pendingScratch.keys().next().value;
        if (oldest === undefined) break;
        pendingScratch.delete(oldest);
      }
    }
    return undefined;
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return { block: true, reason: `herdr write-scope guard failed closed on ${toolName}: ${detail}` };
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
// an approval menu appeared. The one registered `tool_call` handler below does
// only bounded pre-work: cache bash/shell input for the later approval event and
// run the fail-closed registration guard for delegation-shaped tools. Ordinary
// tool calls return undefined and cost zero herdr RPCs here.
function notifyForPrompt(
  toolName: string,
  message: string,
  command?: string,
  callId?: string,
  nativeSession?: string,
  // Set only for a deferred (exclusiveResolver) request: OMP paints NO
  // approval panel in this mode, so the screen probe omp-notify.sh runs for
  // every ordinary approval can never find one. This is the exact identity
  // recordOccurrence already wrote to the registry's `seen` record for this
  // SAME call (the --approval-request-id/--core-arguments-digest/
  // --binding-protocol/--bound-envelope args a few lines up) — passed again
  // here so omp-notify.sh can verify its OWN registry row (never the
  // screen) before alerting, and name the exact occurrence in the alert.
  deferredIdentity?: { approvalRequestId: string; coreArgumentsDigest: string; bindingProtocol: string },
): void {
  if (!notifyAvailable) return;
  const payload: Record<string, unknown> = { tool: toolName, message, cwd: process.cwd() };
  if (command) payload.command = command;
  // Carried only so omp-notify.sh can persist a prompt_occ_screen observation
  // against the SAME occurrence onApprovalRequested already recorded `seen`
  // for (docs/plans/dot-herdr-recovery-slices.md §2: "persist request before
  // probing; failed parsing updates display status instead of discarding the
  // observation") — never a second identity source, since both come from
  // the one onApprovalRequested call below.
  if (callId) payload.call_id = callId;
  if (nativeSession) payload.native_session = nativeSession;
  if (deferredIdentity) {
    payload.deferred = true;
    payload.approval_request_id = deferredIdentity.approvalRequestId;
    payload.core_arguments_digest = deferredIdentity.coreArgumentsDigest;
    payload.binding_protocol = deferredIdentity.bindingProtocol;
  }
  spawnDetached([NOTIFY_SH], JSON.stringify(payload));
}

// omp (verified against the v18.3.0 binary, 2026-09-24) emits
// `tool_approval_requested` with ONLY {sessionId, toolName, toolCallId,
// reason?, approvalMode} — no `input`, no `args`. So `e.input ?? e.args` was
// always undefined: every alert read "omp needs your permission to use bash"
// and the untruncated-command channel (#3b item 2) recorded `command: ""` on
// every input_required event (measured: all of plan:geo-audit's, 2026-09-24),
// which left herdr-select.sh judging the scraped panel and the ownership
// grant unable to ever match. The arguments DO arrive earlier, on `tool_call`
// ({toolName, toolCallId, input}), which omp emits for every call before it
// decides whether approval is needed. Cache bash/shell inputs by toolCallId
// there and look them up here. Bounded (oldest evicted) so a long session
// never grows it; bash/shell only, the one tool whose argument this carries.
//
// Registering on `tool_call` puts this file back in omp's fail-closed
// dispatch (a THROWING tool_call handler blocks the tool), so the cache path is
// a try/catch around a Map write and ordinary calls return undefined. The same
// handler may deliberately return `{block:true}` for delegation-shaped tools
// that fail the central registration/generation check, and for a registered
// worker's file-mutating call outside its worktree (workerWriteScopeBlock).
const INPUT_CACHE_MAX = 32;
// #277: write/edit inputs are cached too, so their approval occurrence records
// the complete payload (digest + proposal) instead of only a clipped panel.
// `at` is the dispatch time and `cwd` the directory relative targets resolve
// against (the same one workerWriteScopeBlock judged).
const APPROVAL_INPUT_TOOLS: Record<string, true> = { bash: true, shell: true, write: true, edit: true };
const inputByCallId = new Map<string, { input: unknown; at: number; cwd: string }>();

function cacheApprovalInput(event: unknown, ctx?: unknown): void {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    const name = typeof e.toolName === "string" ? e.toolName.toLowerCase() : "";
    if (!Object.hasOwn(APPROVAL_INPUT_TOOLS, name) || typeof e.toolCallId !== "string") return;
    const c = ctx && typeof ctx === "object" ? (ctx as Record<string, unknown>).cwd : undefined;
    const cwd = typeof c === "string" && path.isAbsolute(c) ? c : process.cwd();
    inputByCallId.set(e.toolCallId, { input: e.input, at: Date.now(), cwd });
    while (inputByCallId.size > INPUT_CACHE_MAX) {
      const oldest = inputByCallId.keys().next().value;
      if (oldest === undefined) break;
      inputByCallId.delete(oldest);
    }
  } catch {
    // MUST NOT throw — a throwing tool_call handler blocks the tool.
  }
}

// ---- read-only child enforcement ---------------------------------------------
// lib/pretool-registration.sh lets a parent spawn native `task` children only
// when every child is `scout` or `security-reviewer`. The PARENT cannot make
// that safe: omp resolves agent names from many roots (project/user `.omp`,
// extension packages, plugins, marketplace), any of which can redefine
// `scout` with bash, and even the genuine bundled agents also receive
// extension tools (notepad_append, retain), manage_skill, learn and MCP
// proxies, all under a forced `yolo` approval mode (herdr-control #203
// review, findings 1-5). So the guarantee lives HERE, in the child: this
// extension is rebound into every subagent session, and a session running as
// either name may call only this read allowlist, whatever its definition says.
const READONLY_CHILD_AGENTS: Record<string, true> = { scout: true, "security-reviewer": true };
const READONLY_CHILD_TOOLS: Record<string, true> = {
  read: true, find: true, grep: true, glob: true, web_search: true, yield: true, ast_grep: true,
};
// lsp rename/rename_file/code_actions/request/reload can edit files; these cannot.
const READONLY_LSP_ACTIONS: Record<string, true> = {
  diagnostics: true, definition: true, references: true, hover: true, symbols: true,
  type_definition: true, implementation: true, status: true, capabilities: true,
};

function readOnlyChildBlock(event: unknown, ctx?: unknown): Block | undefined {
  const agent = (ctx as { agent?: { kind?: unknown; name?: unknown } } | undefined)?.agent;
  if (!agent || agent.kind !== "sub" || typeof agent.name !== "string") return undefined;
  if (!Object.hasOwn(READONLY_CHILD_AGENTS, agent.name.toLowerCase())) return undefined;
  const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
  const tool = typeof e.toolName === "string" ? e.toolName : "";
  // `read ssh://host/path` runs local ssh with the user's keys (#203 re-review).
  const readPath = tool === "read" && e.input && typeof e.input === "object" ? (e.input as Record<string, unknown>).path : undefined;
  if (Object.hasOwn(READONLY_CHILD_TOOLS, tool) && !(typeof readPath === "string" && /^\s*ssh:/i.test(readPath))) return undefined;
  if (tool === "lsp") {
    const input = e.input && typeof e.input === "object" ? (e.input as Record<string, unknown>) : {};
    if (typeof input.action === "string" && Object.hasOwn(READONLY_LSP_ACTIONS, input.action)) return undefined;
  }
  return {
    block: true,
    reason: `herdr: '${agent.name}' subagents are read-only; '${tool}' is not on their tool allowlist (report findings to the parent instead)`,
  };
}

function onToolCall(event: unknown, ctx?: unknown): Block | undefined {
  cacheApprovalInput(event, ctx);
  const result = readOnlyChildBlock(event, ctx) ?? pretoolRegistrationBlock(event) ?? workerWriteScopeBlock(event, ctx);
  // Owner mode (design §13) is opted into only by the launch-time label; a
  // session without it never reaches this branch.
  if (LOAD_OWNER_LABEL) return result ?? enforceOwnerApproval(event, ctx);
  if (result || !hookApprovalEnforced()) {
    recordShadowVerdict(event, ctx, result);
    return result;
  }
  return runEnforcingCheck(event, ctx, ["--enforce", "--record"], shadowEnv(), (why) => ({
    block: true,
    reason: `herdr hook-approval: refused — ${why}. Nothing ran; tell your conductor. Do not retry it through another tool.`,
  }));
}

// SHADOW MODE (docs/design/pretool-approval.md): for a registered worker only,
// hand the exact tool input to lib/pretool-shadow.sh, which computes the
// hook-time verdict with the same policy the approval menu path uses and
// stores it as a `pretool_verdict` row in pretool-shadow.sqlite3 (never the
// control-plane registry, which it only reads). Detached and
// fire-and-forget: it never blocks, never changes `result` above (the guards'
// return value is passed in only so a guard block is logged as the verdict),
// and never touches the approval menu / herdr-select path. Identity is the
// module-load snapshot (WORKER_TASK_ID/RUN_ID, WORKER_PANE_ID), never a later
// process.env. A non-worker session returns before doing anything.
const PRETOOL_SHADOW_SH = path.join(ROOT, "lib", "pretool-shadow.sh");
const WORKER_PANE_ID = process.env.HERDR_PANE_ID?.trim() ?? "";

function shadowPayload(event: unknown, ctx: unknown, result: Block | undefined): string {
  const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
  const c = ctx && typeof ctx === "object" ? (ctx as Record<string, unknown>).cwd : undefined;
  return JSON.stringify({
    tool: typeof e.toolName === "string" ? e.toolName : "",
    call_id: typeof e.toolCallId === "string" ? e.toolCallId : "",
    input: e.input ?? {},
    cwd: typeof c === "string" ? c : process.cwd(),
    guard_block: result?.reason ?? null,
    t0_ms: Date.now(),
  });
}

function shadowEnv(): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = {
    ...process.env,
    HOME: LOAD_HOME,
    HERDR_TASK_ID: WORKER_TASK_ID,
    HERDR_RUN_ID: WORKER_RUN_ID,
    HERDR_PANE_ID: WORKER_PANE_ID,
  };
  if (LOAD_RUN_STATE_DIR) env.HERDR_RUN_STATE_DIR = LOAD_RUN_STATE_DIR;
  else delete env.HERDR_RUN_STATE_DIR;
  return env;
}

function recordShadowVerdict(event: unknown, ctx: unknown, result: Block | undefined): void {
  if (!WORKER_TASK_ID) return;
  try {
    if (!safeExists(PRETOOL_SHADOW_SH)) return;
    spawnDetached([PRETOOL_SHADOW_SH, "--record"], shadowPayload(event, ctx, result), shadowEnv());
  } catch {
    // MUST NOT throw — a throwing tool_call handler blocks the tool.
  }
}

// ENFORCING MODE — hook approval (docs/design/pretool-approval.md §4, §8).
// Only for a task spawned with `spawn-task.sh --approval hook`, which launches
// omp with --auto-approve (no approval menu ever paints) and records
// approval=hook on the task's REGISTRY ROW. That row is the authority: it is
// read once per session (read_task, cached once it answers) and nothing the
// worker can edit feeds it. HERDR_APPROVAL=hook in the launch environment can
// only TIGHTEN — it turns enforcement on so that an unreadable registry or a
// row that disagrees makes lib/pretool-shadow.sh --enforce refuse every call
// (an auto-approve session must never fall back to "no check at all"). It can
// never turn enforcement off. Every other worker (approval=menu, the default)
// keeps exactly the shadow path above and omp's own approval menu.
//
// The call is judged synchronously on its exact input: allow runs;
// escalate/reserved is blocked with a reason telling the worker it was handed
// to its conductor (or to Terrence) as an action request, unless a one-shot
// grant for these exact bytes was approved (herdr-action.sh), which is then
// consumed; deny/block is refused. Any failure here — a missing lib, a
// timeout, garbage output, an exception — BLOCKS: fail closed.
const LOAD_APPROVAL_ENV = process.env.HERDR_APPROVAL?.trim() ?? "";
// spawn-task.sh --approval hook refuses unless the extension omp will load
// carries this marker (an older hook would leave --auto-approve unjudged).
export const HERDR_HOOK_APPROVAL_PROTOCOL = 1;
let registryApproval: "hook" | "menu" | undefined; // cached once the registry answers
let registryApprovalReadFailed = false; // one failed sync read per session, then the env signal only

// The row is read with a single SELECT and nothing else: no registry_init,
// so no migration/WAL pragma can lose a lock race with another
// writer and turn "hook" into "unknown" (observed: an intermittent failed read
// left a hook row unenforced for that call). A registry that predates schema
// v6 has no approval column and therefore no hook rows: that answer is "menu".
function sqlQuote(v: string): string {
  return `'${v.replace(/'/g, "''")}'`;
}
const REGISTRY_DB = path.join(
  LOAD_RUN_STATE_DIR || path.join(LOAD_HOME, ".local/state/herdr/runs"),
  "registry.sqlite3",
);
const APPROVAL_SQL =
  `SELECT approval FROM tasks WHERE run_id=${sqlQuote(WORKER_RUN_ID)} AND task_id=${sqlQuote(WORKER_TASK_ID)};`;
// A plain path (a `file:` URI would need percent-encoding: '#', '?', '%' in
// HOME or HERDR_RUN_STATE_DIR break it) and a plain SELECT on an ordinary
// connection. NOT -readonly: a read-only connection cannot open a WAL database
// whose -wal/-shm files are absent (SQLite deletes them when the last
// connection closes) — measured: "unable to open database file", which would
// read as "unknown" and leave a row-only hook task unenforced.
const APPROVAL_READ_ARGS = ["-batch", "-noheader", "-cmd", ".timeout 3000", REGISTRY_DB, APPROVAL_SQL];

function parseApprovalRead(status: number | null, stdout: string, stderr: string): "hook" | "menu" | undefined {
  if (status === 0) return stdout.trim() === "hook" ? "hook" : "menu"; // no row = not a hook task
  if (/no such column: approval/.test(stderr)) return "menu";
  return undefined;
}

// Prefetched once at module load (session start) so a menu worker's first tool
// call does not pay the registry read; a tool call that arrives before the
// prefetch answers reads synchronously below.
function prefetchRegistryApproval(): void {
  if (!WORKER_TASK_ID || !WORKER_RUN_ID) return;
  try {
    if (!safeExists(REGISTRY_DB)) return;
    const child = spawn("sqlite3", APPROVAL_READ_ARGS, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.on("error", () => {});
    child.stdout?.on("data", (d) => { out += String(d); });
    child.stderr?.on("data", (d) => { err += String(d); });
    child.on("close", (code) => {
      if (!registryApproval) registryApproval = parseApprovalRead(code, out, err);
    });
    child.unref();
  } catch {
    // best effort; the synchronous read is the fallback
  }
}
prefetchRegistryApproval();

function readRegistryApproval(): "hook" | "menu" | undefined {
  if (registryApproval) return registryApproval;
  if (registryApprovalReadFailed || !WORKER_RUN_ID || !safeExists(REGISTRY_DB)) return undefined;
  for (let attempt = 0; attempt < 3 && !registryApproval; attempt++) {
    const r = spawnSync("sqlite3", APPROVAL_READ_ARGS, { encoding: "utf8", timeout: 4_000, stdio: ["ignore", "pipe", "pipe"] });
    registryApproval = r.error ? undefined : parseApprovalRead(r.status, r.stdout ?? "", r.stderr ?? "");
  }
  // A menu worker must not pay a synchronous registry read on every call while
  // the registry is unhealthy. A worker launched without a menu is still
  // enforced below (argv / env), and the enforcing lib reads the row itself.
  if (!registryApproval) registryApprovalReadFailed = true;
  return registryApproval;
}

// omp's own launch flags: spawn-task.sh --approval hook launches omp with
// --auto-approve (omp's alias: --yolo), and a registered worker launched that
// way is ALWAYS judged by the hook, whatever the registry read says — a failed
// read must never mean "no check at all". The flags are fixed at process start;
// the worker cannot change them. `--approval-mode yolo` is NOT matched: that is
// the operator-chosen yolo POSTURE for a menu spawn (lib/posture.sh), whose
// behaviour this change must not alter.
const LOAD_NO_MENU = process.argv.some((a) => a === "--auto-approve" || a === "--yolo");

function hookApprovalEnforced(): boolean {
  if (!WORKER_TASK_ID) return false;
  if (LOAD_NO_MENU || LOAD_APPROVAL_ENV === "hook") return true;
  try {
    return readRegistryApproval() === "hook";
  } catch {
    return false;
  }
}

// Runs lib/pretool-shadow.sh synchronously on the exact input and turns its
// one-line answer into the hook's. Any failure — a missing lib, a timeout,
// garbage output, an exception — BLOCKS: fail closed.
function runEnforcingCheck(
  event: unknown,
  ctx: unknown,
  args: string[],
  env: Record<string, string | undefined>,
  refuse: (why: string) => Block,
): Block | undefined {
  try {
    if (!safeExists(PRETOOL_SHADOW_SH)) return refuse("the pre-tool check (lib/pretool-shadow.sh) is missing");
    const r = spawnSync("bash", [PRETOOL_SHADOW_SH, ...args], {
      input: shadowPayload(event, ctx, undefined),
      encoding: "utf8",
      timeout: 20_000,
      stdio: ["pipe", "pipe", "pipe"],
      env,
    });
    if (r.error) return refuse(`the pre-tool check failed (${r.error.message})`);
    const line = (r.stdout ?? "").trim().split("\n").pop() ?? "";
    let out: Record<string, unknown>;
    try {
      out = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return refuse(`the pre-tool check gave no verdict (exit ${r.status})`);
    }
    if (r.status === 0 && out.decision === "allow") return undefined;
    const reason = typeof out.reason === "string" && out.reason ? out.reason : "";
    return reason ? { block: true, reason } : refuse(`the pre-tool check refused this call (exit ${r.status})`);
  } catch (error) {
    return refuse(`the pre-tool check threw (${error instanceof Error ? error.message : String(error)})`);
  }
}

// ---- owner/conductor hook approval (docs/design/pretool-approval.md §13) ----
// OPT-IN and off: only a session launched with HERDR_OWNER_APPROVAL=<label>
// is judged here, and nothing in this repo sets that variable. The label is
// read ONCE, at module load, so the session cannot shed it later; it only
// TIGHTENS — it turns the check on, and the check then allows a call only when
// the owner record (owner-approval.sh, human-only) binds this label to this
// pane, this pane's live generation, and THIS omp session id, read from
// ctx.sessionManager (never from env or the payload). Every tool call — eval,
// write and edit included — goes through lib/pretool-shadow.sh --owner; an
// unproven identity refuses every call; omp's own approval layer still runs
// after an allow. A session carrying both a worker task and an owner label is
// refused by the lib. Subagents run as their own sessions, so their calls do
// not match the owner's session and are refused.
const LOAD_OWNER_LABEL = process.env.HERDR_OWNER_APPROVAL?.trim() ?? "";

function sessionIdOf(ctx: unknown): string {
  try {
    const sm = ctx && typeof ctx === "object" ? (ctx as Record<string, unknown>).sessionManager : undefined;
    const get = sm && typeof sm === "object" ? (sm as Record<string, unknown>).getSessionId : undefined;
    const id = typeof get === "function" ? (get as (this: unknown) => unknown).call(sm) : undefined;
    return typeof id === "string" ? id.trim() : "";
  } catch {
    return "";
  }
}

function enforceOwnerApproval(event: unknown, ctx: unknown): Block | undefined {
  const env = shadowEnv();
  env.HERDR_OWNER_APPROVAL = LOAD_OWNER_LABEL;
  env.HERDR_OWNER_SESSION_ID = sessionIdOf(ctx);
  return runEnforcingCheck(event, ctx, ["--enforce", "--owner", "--record"], env, (why) => ({
    block: true,
    reason: `herdr owner-approval: refused — ${why}. Nothing ran; tell Terrence. Do not retry it through another tool.`,
  }));
}

// ---- occurrence correlation (docs/plans/dot-herdr-recovery-slices.md §2) ---
// Carries (run, task, pane, pane_birth, native_session, toolCallId) through
// the approval lifecycle into lib/prompt-occurrence.py, the one deterministic
// fold every consumer (attention-tick.sh, herdr-select.sh, hub.py) reads.
// native_session is THIS session's omp id (sessionIdOf, same mechanism
// enforceOwnerApproval already trusts above) — never from env or payload,
// and stable for the life of this hook module instance, so a late event from
// an old session's residual process cannot resolve a new session's
// occurrence: the key simply would not match.
const PROMPT_OCCURRENCE_PY = path.join(ROOT, "lib", "prompt-occurrence.py");
const promptOccurrenceAvailable = safeExists(PROMPT_OCCURRENCE_PY);

let registeredPaneBirthCache: string | undefined;
function registeredPaneBirth(): string {
  if (registeredPaneBirthCache !== undefined) return registeredPaneBirthCache;
  if (!WORKER_RUN_ID || !WORKER_TASK_ID || !safeExists(REGISTRY_DB)) {
    registeredPaneBirthCache = "";
    return registeredPaneBirthCache;
  }
  try {
    const sql = `SELECT pane_birth FROM tasks WHERE run_id=${sqlQuote(WORKER_RUN_ID)} AND task_id=${sqlQuote(WORKER_TASK_ID)};`;
    const r = spawnSync("sqlite3", ["-batch", "-noheader", "-cmd", ".timeout 3000", REGISTRY_DB, sql],
      { encoding: "utf8", timeout: 4_000, stdio: ["ignore", "pipe", "pipe"] });
    registeredPaneBirthCache = r.status === 0 ? (r.stdout ?? "").trim() : "";
  } catch {
    registeredPaneBirthCache = "";
  }
  return registeredPaneBirthCache;
}

function occurrenceIdentityArgs(callId: string, nativeSession: string): string[] {
  return [
    "--db", REGISTRY_DB, "--run", WORKER_RUN_ID, "--task", WORKER_TASK_ID, "--pane", WORKER_PANE_ID,
    "--birth", registeredPaneBirth(), "--session", nativeSession, "--call-id", callId,
  ];
}

// Synchronous when the interpreter is already cached, deliberately: the
// occurrence must be PERSISTED before the notify/screen-probe path below
// ever runs, or a crash between notify and recording loses the only
// evidence the prompt existed. This is a monitoring path (same contract as
// the rest of this file): any failure here never throws and never blocks
// the tool it observes — but round 6 review (HIGH): it must still be
// VISIBLE, not silently vanish. Round 7 review (HIGH): a COLD cache (the
// first occurrence of a session, before any prior resolution) used to be
// dropped outright — refreshHubPythonAsync() only starts the resolve, it
// does not finish it, so reading hubPythonCache one line later was always
// empty on that first call. Round 8 review (5 findings against the round 7
// fix, all addressed by collapsing to ONE ordered async path instead of a
// separate warm-sync / cold-queue split):
//  1. persist-before-notify: recordOccurrence now returns a Promise that
//     resolves only once this occurrence has actually been attempted
//     (written or definitively failed+logged), so onApprovalRequested can
//     await it before calling notifyForPrompt — a notification can no
//     longer outrun the write it describes.
//  2. group-kill: runOccurrenceAsync spawns `detached: true` and kills via
//     killGroup() (same PR #273 round 2 mechanism captureOutput uses) so a
//     grandchild the interpreter itself blocked on cannot survive a kill
//     and keep stdio open forever.
//  4. one ordered path: the WARM short-circuit (recordOccurrence calling a
//     synchronous spawnSync directly whenever hubPythonCache happened to
//     already be set) is gone. Every occurrence, warm or cold, is pushed
//     onto the SAME FIFO queue; a single drainOccurrenceQueue() — guarded
//     against re-entry — is the only thing that ever calls
//     runOccurrenceAsync, so persistence order is always arrival order,
//     never whichever call happened to race hubPythonCache's assignment.
//  5. count-once: runOccurrenceAsync now checks one shared `settled` guard
//     at the top of every handler (timeout / error / close) so a failure
//     that fires more than one of those (Node can emit both 'error' and
//     'close' for the same spawn failure) is logged and counted exactly
//     once, not twice.
// flushPendingOccurrences's own name is gone with the split it drained;
// drainOccurrenceQueue is its replacement, called directly, by name, from
// refreshHubPythonAsync's callback and from recordOccurrence itself —
// reachable from ensureHub()/onBeforeAgentStart, which is exactly why
// nothing in its closure may contain a *Sync call (it does not:
// runOccurrenceAsync only ever uses `spawn`, never `spawnSync`). An
// earlier version of the round 7 fix instead hid a real spawnSync call
// from the static checker behind an anonymous waiter closure — rejected
// as the same class of problem as the round 6 glob-evasion correction;
// this path has nothing to hide.
const MAX_PENDING_OCCURRENCES = 50;
const OCCURRENCE_SPAWN_TIMEOUT_MS = 4_000;
interface PendingOccurrence { args: string[]; stdin?: string; requireProposal: boolean; resolve: (persisted: boolean) => void; }
const pendingOccurrenceQueue: PendingOccurrence[] = [];
let pendingOccurrenceDropped = 0;
// Round 7 follow-up (Main review): spawn/exit/timeout failures were only
// logged, never counted. Round 8: a single shared `settled` guard inside
// runOccurrenceAsync (not just the old `timedOut` flag) makes sure each
// spawn increments this exactly once even when more than one of its
// handlers fires for the same outcome.
let pendingOccurrenceFailed = 0;

// prompt-occurrence.py (lib/prompt-occurrence.py:main) ALWAYS exits 0 and
// prints exactly one JSON object, by design ("a monitoring CLI must never
// crash its caller") — exit code alone can never tell a durable write from
// an internal failure. Its one success shape, for every subcommand
// (record_seen / record_screen / record_authorized / _resolve), is
// `{"occ_key": <str>, "written": <str>, ...}` with no `error` key; every
// failure path (malformed --input-json, an unhandled exception) instead
// prints `{"error": <str>}` with no `occ_key`. Round 9 review (BLOCK): the
// TS side never read stdout at all, so an exit-0 JSON error looked
// identical to a real persist. This is the one place that tells them apart.
//
// Round 10 review (narrow defect): a non-empty occ_key with no error was
// treated as success regardless of `written`, so a `seen` call that landed
// as record_seen's "mismatch" outcome (lib/prompt-occurrence.py:198-217 —
// the SAME occurrence identity but a DIFFERENT tool or input than whatever
// was recorded first) still resolved persisted=true, and the handler would
// notify the CHANGED command as if it were the one genuinely on record.
// `seen`'s own written values: "seen" (first write), "enriched" (a digest
// landed where none existed yet, same identity), "duplicate" (re-seen,
// same or still-absent digest) all mean this exact occurrence IS durably
// recorded; "mismatch" means a conflicting write happened instead and must
// read as a failure here, same as any other unrecognized/absent value.
// Other subcommands (record_screen/record_authorized/_resolve) are never
// gated on by a caller — only `seen`'s result reaches onApprovalRequested's
// notify branch — so their own `written` shapes are left unchecked, same
// as before.
const SEEN_DURABLE_WRITTEN: Record<string, true> = { seen: true, enriched: true, duplicate: true };
export function parsePersistedResponse(stdout: string, cmd: string, requireProposal = false): boolean {
  try {
    const parsed: unknown = JSON.parse(stdout.trim());
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return false;
    const r = parsed as Record<string, unknown>;
    if (typeof r.occ_key !== "string" || r.occ_key.length === 0 || "error" in r) return false;
    if (cmd !== "seen") return true;
    const durable = typeof r.written === "string" && Object.hasOwn(SEEN_DURABLE_WRITTEN, r.written);
    return durable && (!requireProposal || r.proposal === "written" || r.proposal === "exists");
  } catch {
    return false;
  }
}

// Genuinely async: spawn + event listeners, never spawnSync. Bounded
// lifetime: a hung prompt-occurrence.py (e.g. a stuck sqlite lock) must
// never stall the queue forever — a manual timer (not spawn's own
// `timeout` option, so the log line can say TIMEOUT distinctly from a
// normal non-zero exit) kills the child after OCCURRENCE_SPAWN_TIMEOUT_MS.
// Spawned detached and killed via killGroup() (round 8, finding 2): a
// plain child.kill() only ever reaches prompt-occurrence.py's own PID, not
// any grandchild IT is synchronously blocked on — exactly the orphan class
// PR #273 round 2's killGroup() already exists to close for captureOutput.
// A single `settled` guard (round 8, finding 5) is checked first in every
// handler so a failure that fires more than one of timeout/error/close is
// still counted and resolved exactly once. Always resolves `persisted`
// (never rejects) so a dropped/failed/killed occurrence cannot produce an
// unhandled rejection; every failure is logged AND counted before resolve.
// Round 9 review (BLOCK): resolving `void` on EVERY outcome — including a
// genuine timeout/EACCES/nonzero exit — made the caller's "did this
// persist?" indistinguishable from "did this finish?". `persisted` is now
// explicit: true only for a clean exit whose stdout is a real success
// response (parsePersistedResponse above); every other outcome resolves
// false and still logs the truthful reason.
function runOccurrenceAsync(py: string, args: string[], stdin?: string, requireProposal = false): Promise<boolean> {
  const { promise, resolve } = Promise.withResolvers<boolean>();
  let settled = false;
  let child;
  try {
    child = spawn(py, [PROMPT_OCCURRENCE_PY, ...args], { stdio: [stdin === undefined ? "ignore" : "pipe", "pipe", "pipe"], detached: true });
    if (stdin !== undefined && child.stdin) {
      child.stdin.on("error", () => {});
      child.stdin.end(stdin);
    }
  } catch (e: unknown) {
    pendingOccurrenceFailed++;
    console.error(`herdr: recordOccurrence: spawn threw (total failed this session: ${pendingOccurrenceFailed}) — occurrence NOT recorded: ${e}`);
    resolve(false);
    return promise;
  }
  let stdout = "";
  let stderr = "";
  const liveChild = child;
  const timer = setTimeout(() => {
    if (settled) return;
    settled = true;
    pendingOccurrenceFailed++;
    console.error(`herdr: recordOccurrence: prompt-occurrence.py timed out after ${OCCURRENCE_SPAWN_TIMEOUT_MS}ms (total failed this session: ${pendingOccurrenceFailed}) — killing its process group, occurrence NOT recorded`);
    if (liveChild.pid) killGroup(liveChild.pid);
    resolve(false);
  }, OCCURRENCE_SPAWN_TIMEOUT_MS);
  child.stdout?.on("data", (d: Buffer) => { stdout += d.toString(); });
  child.stderr?.on("data", (d: Buffer) => { stderr += d.toString(); });
  child.on("error", (e: Error) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    pendingOccurrenceFailed++;
    console.error(`herdr: recordOccurrence: spawn error (total failed this session: ${pendingOccurrenceFailed}) — occurrence NOT recorded: ${e}`);
    resolve(false);
  });
  child.on("close", (code: number | null) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    if (code !== 0) {
      pendingOccurrenceFailed++;
      console.error(`herdr: recordOccurrence: prompt-occurrence.py failed (status=${code}, total failed this session: ${pendingOccurrenceFailed}) — occurrence NOT recorded: ${stderr.slice(0, 300)}`);
      resolve(false);
      return;
    }
    if (!parsePersistedResponse(stdout, args[0], requireProposal)) {
      pendingOccurrenceFailed++;
      console.error(`herdr: recordOccurrence: prompt-occurrence.py exited 0 but its response was not a success (total failed this session: ${pendingOccurrenceFailed}) — occurrence NOT recorded: ${stdout.slice(0, 300)}`);
      resolve(false);
      return;
    }
    resolve(true);
  });
  return promise;
}

export function readOccurrenceStateAsync(py: string, args: string[]): Promise<Record<string, unknown>> {
  const { promise, resolve, reject } = Promise.withResolvers<Record<string, unknown>>();
  let settled = false;
  let child;
  try {
    child = spawn(py, [PROMPT_OCCURRENCE_PY, ...args], { stdio: ["ignore", "pipe", "ignore"], detached: true });
  } catch (error) {
    reject(error instanceof Error ? error : new Error(String(error)));
    return promise;
  }
  let stdout = "";
  const timer = setTimeout(() => {
    if (settled) return;
    settled = true;
    if (child.pid) killGroup(child.pid);
    reject(new Error(`prompt-occurrence state lookup timed out after ${OCCURRENCE_SPAWN_TIMEOUT_MS}ms`));
  }, OCCURRENCE_SPAWN_TIMEOUT_MS);
  child.stdout?.on("data", (d: Buffer) => { if (stdout.length < 65_536) stdout += d.toString(); });
  child.on("error", (error: Error) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    reject(error);
  });
  child.on("close", (code: number | null) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    if (code !== 0) return reject(new Error(`prompt-occurrence state lookup exited ${code}`));
    try {
      const parsed: unknown = JSON.parse(stdout.trim());
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        reject(new Error("prompt-occurrence state lookup returned a non-object"));
        return;
      }
      const record = parsed as Record<string, unknown>;
      if (typeof record.error === "string" && record.error) {
        reject(new Error(`prompt-occurrence state lookup failed: ${record.error}`));
        return;
      }
      const validLifecycles = new Set([
        "unknown", "requested", "approved_awaiting_completion",
        "resolved:completed", "resolved:declined", "resolved:withdrawn",
      ]);
      const validAuthorizations = new Set(["none", "approved"]);
      if (typeof record.lifecycle !== "string" || !validLifecycles.has(record.lifecycle)
        || typeof record.authorization !== "string" || !validAuthorizations.has(record.authorization)) {
        reject(new Error("prompt-occurrence state lookup returned an invalid state schema"));
        return;
      }
      resolve(record);
    } catch {
      reject(new Error("prompt-occurrence state lookup returned malformed JSON"));
    }
  });
  return promise;
}

// The ONE path every occurrence goes through, warm or cold (round 8,
// finding 4): a warm recordOccurrence call used to spawnSync directly,
// which could complete and persist before an earlier COLD-queued call's
// async flush got there — an arrival-order violation. Guarded against
// re-entry (occurrenceDrainInFlight) so at most one drain loop runs; it
// stops (without consuming the head of the queue) the moment
// hubPythonCache is empty, leaving every remaining item — and every
// caller still awaiting its resolve() — queued for the next successful
// refreshHubPythonAsync to retrigger this same function.
let occurrenceDrainInFlight = false;
async function drainOccurrenceQueue(): Promise<void> {
  if (occurrenceDrainInFlight) return;
  occurrenceDrainInFlight = true;
  try {
    while (pendingOccurrenceQueue.length) {
      const py = hubPythonCache;
      if (!py) return;
      const item = pendingOccurrenceQueue.shift();
      if (!item) return;
      const persisted = await runOccurrenceAsync(py, item.args, item.stdin, item.requireProposal);
      item.resolve(persisted);
    }
  } finally {
    occurrenceDrainInFlight = false;
  }
}

// `stdin` carries tool input (`--input-json -`): write/edit content must not
// sit in argv, where any local user can read it with ps (#277 review r1).
export function recordOccurrence(args: string[], stdin?: string): Promise<boolean> {
  const { promise, resolve } = Promise.withResolvers<boolean>();
  if (!promptOccurrenceAvailable || !WORKER_RUN_ID || !WORKER_TASK_ID || !WORKER_PANE_ID) {
    resolve(false);
    return promise;
  }
  if (pendingOccurrenceQueue.length >= MAX_PENDING_OCCURRENCES) {
    const dropped = pendingOccurrenceQueue.shift();
    pendingOccurrenceDropped++;
    console.error(`herdr: recordOccurrence: pending-queue cap (${MAX_PENDING_OCCURRENCES}) reached — oldest queued occurrence dropped (total dropped this session: ${pendingOccurrenceDropped})`);
    dropped?.resolve(false); // it will never persist now; its waiter must not hang on it
  }
  pendingOccurrenceQueue.push({ args, stdin, requireProposal: args.includes("--bound-envelope"), resolve });
  if (hubPythonCache) void drainOccurrenceQueue();
  else refreshHubPythonAsync();
  return promise;
}

type BoundApprovalPollScheduler = (
  callback: () => void,
  delayMs: number,
) => ReturnType<typeof setTimeout>;

// Every detached approval-state lookup, including retries, enters through this
// one rejection boundary. The caller has already returned {defer:true}, so an
// unhandled rejection here would otherwise strand OMP's exact approval request
// forever. The injectable scheduler keeps both the immediate and delayed paths
// deterministic in the hook harness without adding a production test switch.
export function launchBoundApprovalPoll(
  poll: () => Promise<void>,
  deny: (error: unknown) => void,
  delayMs = 0,
  scheduler: BoundApprovalPollScheduler = setTimeout,
): void {
  const run = (): void => {
    void poll().catch(deny);
  };
  if (delayMs <= 0) {
    run();
    return;
  }
  scheduler(run, delayMs).unref();
}

// Bounded (same eviction shape as inputByCallId/pendingScratch): which
// in-flight calls this SESSION itself put through the approval menu, and
// whether a decision was recorded for them yet. This is a fast-path only —
// it decides completed-vs-withdrawn without a second durable read, but the
// durable fold (prompt-occurrence.py) independently refuses to trust a
// completion that was never actually approved, so a lost/evicted entry here
// degrades to "no occurrence recorded for this call", never a false
// completion.
const occurrenceByCallId = new Map<string, { nativeSession: string; decided: boolean }>();
function trackOccurrence(callId: string, nativeSession: string, decided: boolean): void {
  occurrenceByCallId.set(callId, { nativeSession, decided });
  while (occurrenceByCallId.size > INPUT_CACHE_MAX) {
    const oldest = occurrenceByCallId.keys().next().value;
    if (oldest === undefined) break;
    occurrenceByCallId.delete(oldest);
  }
}

function onApprovalRequested(event: unknown, ctx?: unknown): { defer: true } | undefined {
  let deferred = false;
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    const toolName = typeof e.toolName === "string" && e.toolName ? e.toolName : "tool";
    const callId = typeof e.toolCallId === "string" ? e.toolCallId : undefined;
    const cached = callId !== undefined ? inputByCallId.get(callId) : undefined;
    const requestId = typeof e.requestId === "string" ? e.requestId : "";
    const coreDigest = typeof e.argumentsDigest === "string" ? e.argumentsDigest : "";
    const coreArgumentsJson = typeof e.argumentsJson === "string" ? e.argumentsJson : "";
    const bindingProtocol = e.bindingProtocol === "omp.tool-approval-binding.v1" ? e.bindingProtocol : "";
    const exclusiveResolver = e.exclusiveResolver === true;
    const approvalSession = typeof e.sessionId === "string" ? e.sessionId : "";
    const context = ctx && typeof ctx === "object" ? ctx as Record<string, unknown> : {};
    const resolveBound = typeof context.resolveToolApproval === "function"
      ? context.resolveToolApproval as (resolution: Record<string, unknown>) => boolean
      : undefined;
    const boundTool = HERDR_BOUND_BASH
      ? /^(write|edit|bash|shell)$/i.test(toolName)
      : /^(write|edit)$/i.test(toolName);
    const coreArgumentsValid = /^sha256:[a-f0-9]{64}$/.test(coreDigest)
      && coreArgumentsJson.length <= 200_000
      && `sha256:${Bun.SHA256.hash(coreArgumentsJson, "hex")}` === coreDigest;
    let coreInput: unknown;
    if (coreArgumentsValid) {
      try { coreInput = JSON.parse(coreArgumentsJson); } catch { coreInput = undefined; }
    }
    deferred = exclusiveResolver && boundTool && Boolean(callId) && Boolean(requestId) && Boolean(bindingProtocol)
      && Boolean(approvalSession)
      && /^sha256:[a-f0-9]{64}$/.test(coreDigest)
      && coreInput !== undefined
      && Boolean(resolveBound);
    // A deferred request must be proposed from OMP's exact canonical effective
    // arguments, never the earlier tool_call cache. The cache remains the
    // compatibility source for ordinary/unbound events.
    const input = deferred ? coreInput : (e.input ?? e.args ?? cached?.input);
    // ceiling: past ~200k chars the input is not recorded (no digest, no
    // proposal), which leaves that approval human-only.
    const inputJson = input !== undefined ? JSON.stringify(input) : undefined;
    const occurrenceStdin = deferred
      ? JSON.stringify({ input, core_arguments_json: coreArgumentsJson })
      : inputJson;
    const recordInput = inputJson !== undefined && inputJson.length <= 200_000;
    // Cache kept, never deleted here: omp can fire tool_approval_requested
    // more than once for ONE still-open prompt (the existing compound-menu
    // fixture pins exactly that repeat-firing shape), and deleting on the
    // first firing silently dropped the SECOND firing's cached input before
    // this fix (docs/plans/dot-herdr-recovery-slices.md §2, prerequisite
    // notes on agent-hooks/omp-herdr-control.ts:925).
    let nativeSession: string | undefined;
    if (callId !== undefined) nativeSession = sessionIdOf(ctx);
    if (callId !== undefined) trackOccurrence(callId, nativeSession, false);
    // `reason` is the approval's own words when omp supplies one; the argument
    // summary is the fallback, and still the more useful line for bash.
    const detail = describeToolCall(toolName, input)
      ?? (typeof e.reason === "string" && e.reason ? truncate(e.reason) : undefined);
    // Round 8 review (finding 1): this used to call recordOccurrence then
    // notifyForPrompt on the very next line, so the notification could
    // race ahead of (or outrun, on a crash) whatever async resolve+write
    // recordOccurrence still had in flight — fixed by awaiting its
    // Promise<boolean> before notifying. Round 8 Main review follow-up: an
    // `async function` handler returns a Promise, which omp's own
    // "never blocks the agent" event-handler contract requires this NOT
    // to do (verify-omp-hooks.sh:958) — this synchronous handler now
    // returns undefined immediately, same as before, and runs the
    // persist-before-notify sequence in a DETACHED, self-contained task
    // with its own try/catch, exactly like every other fire-and-forget
    // path in this file (never awaited by the caller, never throws out).
    //
    // Round 9 review (BLOCK): awaiting the promise was only "attempt
    // before notify" — every failure path (timeout, spawn error/EACCES,
    // nonzero exit, queue eviction, prompt-occurrence.py exiting 0 with a
    // JSON error) used to resolve just like a real success, so the
    // notification fired unconditionally anyway. recordOccurrence now
    // resolves an explicit `persisted` boolean (true only for a verified
    // durable write) and this is the one gate: no identity (callId
    // undefined, nothing was ever attempted) and an attempted-but-failed
    // write both read as `persisted !== true` here and suppress the
    // notification — the failure itself was already logged with its
    // truthful reason and counted inside recordOccurrence/runOccurrenceAsync.
    void (async () => {
      try {
        const persisted = callId !== undefined
          ? await recordOccurrence([
              "seen", ...occurrenceIdentityArgs(callId, nativeSession),
              "--tool", toolName,
              ...(recordInput ? ["--input-json", "-"] : []),
              "--source", "tool_approval_requested",
              ...(deferred ? ["--approval-request-id", requestId, "--core-arguments-digest", coreDigest,
                "--binding-protocol", bindingProtocol, "--bound-envelope"] : []),
              ...(cached ? ["--cwd", cached.cwd, "--dispatched-at-ms", String(cached.at)] : []),
            ], recordInput ? occurrenceStdin : undefined)
          : false;
        if (!persisted) {
          console.error(`herdr: recordOccurrence: occurrence was not durably persisted — suppressing the approval notification for ${toolName} (call ${callId ?? "unknown"})`);
          if (deferred && resolveBound && callId) resolveBound({
            bindingProtocol, requestId, sessionId: approvalSession, toolCallId: callId, toolName,
            argumentsDigest: coreDigest, approved: false, reason: "approval occurrence was not persisted",
          });
          return;
        }
        notifyForPrompt(
          toolName,
          detail ? `${toolName}: ${detail}` : `omp needs your permission to use ${toolName}`,
          rawBashCommand(toolName, input),
          callId,
          nativeSession,
          deferred ? { approvalRequestId: requestId, coreArgumentsDigest: coreDigest, bindingProtocol } : undefined,
        );
        if (deferred && resolveBound && callId) {
          const identity = [
            "state", ...occurrenceIdentityArgs(callId, nativeSession),
          ];
          const deadline = Date.now() + 60 * 60 * 1000;
          const denyPollFailure = (error: unknown): void => {
            resolveBound({
              bindingProtocol, requestId, sessionId: approvalSession, toolCallId: callId, toolName,
              argumentsDigest: coreDigest, approved: false,
              reason: `bound approval poll failed: ${error instanceof Error ? error.message : String(error)}`,
            });
          };
          const poll = async (): Promise<void> => {
            const py = hubPythonCache;
            if (!py) {
              if (Date.now() < deadline) launchBoundApprovalPoll(poll, denyPollFailure, 500);
              else resolveBound({ bindingProtocol, requestId, sessionId: approvalSession, toolCallId: callId,
                toolName, argumentsDigest: coreDigest, approved: false, reason: "bound approval timed out" });
              return;
            }
            const state = await readOccurrenceStateAsync(py, identity);
            const lifecycle = typeof state?.lifecycle === "string" ? state.lifecycle : "";
            if (state?.authorization === "approved" && lifecycle === "approved_awaiting_completion") {
              resolveBound({ bindingProtocol, requestId, sessionId: approvalSession, toolCallId: callId, toolName,
                argumentsDigest: coreDigest, approved: true });
              return;
            }
            if (lifecycle.startsWith("resolved:")) {
              resolveBound({ bindingProtocol, requestId, sessionId: approvalSession, toolCallId: callId, toolName,
                argumentsDigest: coreDigest, approved: false, reason: lifecycle });
              return;
            }
            if (Date.now() < deadline) launchBoundApprovalPoll(poll, denyPollFailure, 500);
            else resolveBound({ bindingProtocol, requestId, sessionId: approvalSession, toolCallId: callId, toolName,
              argumentsDigest: coreDigest, approved: false, reason: "bound approval timed out" });
          };
          launchBoundApprovalPoll(poll, denyPollFailure);
        }
      } catch (error) {
        // The handler already returned {defer:true}; swallowing an unexpected
        // detached failure would strand OMP forever. Resolve this exact binding
        // as denied. A prior one-shot resolution simply returns false.
        if (deferred && resolveBound && callId) resolveBound({
          bindingProtocol, requestId, sessionId: approvalSession, toolCallId: callId, toolName,
          argumentsDigest: coreDigest, approved: false,
          reason: `deferred approval workflow failed: ${error instanceof Error ? error.message : String(error)}`,
        });
      }
    })();
  } catch {
    // MUST NOT throw — see the fail-closed contract at the top of this file.
  }
  return deferred ? { defer: true } : undefined;
}

// The `ask` tool is not an approval, so it emits no approval event — it just
// paints a numbered question and waits. Same alert path, same retraction path
// (tool_execution_end), and the same shape omp's herdr integration uses to
// report `blocked` for it.
function onExecutionStart(event: unknown): undefined {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    // #277 timing evidence: execution start of a call that went through the
    // approval menu (lifecycle unchanged; completion still comes from end).
    const callId = typeof e.toolCallId === "string" ? e.toolCallId : undefined;
    const occ = callId !== undefined ? occurrenceByCallId.get(callId) : undefined;
    if (callId !== undefined && occ?.decided) {
      recordOccurrence(["started", ...occurrenceIdentityArgs(callId, occ.nativeSession)]);
    }
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

// OMP v1 invokes this synchronously adjacent to execution, after approval and
// argument-digest verification. Only the non-mutating filesystem scope guard
// runs here: never replay tool_call handlers that revise input or emit effects.
function onExecutionValidate(event: unknown, ctx?: unknown): Block | undefined {
  return workerWriteScopeBlock(event, ctx);
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

function onApprovalResolved(event?: unknown, ctx?: unknown): undefined {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    const callId = typeof e.toolCallId === "string" ? e.toolCallId : undefined;
    if (callId !== undefined) {
      const approved = e.approved === true;
      const nativeSession = sessionIdOf(ctx);
      trackOccurrence(callId, nativeSession, true);
      // Approval is never completion (plan §2): this moves the occurrence to
      // approved_awaiting_completion, or — for a real Deny — resolves it
      // directly as declined. `false` also covers "no interactive UI" and an
      // abort, so `reason` carries omp's own words rather than this always
      // being read as a human denial.
      //
      // #309: this event fires for EVERY omp-resolved approval, including
      // ones herdr-select.sh/peer-answer.sh pressed by sending keys to the
      // pane — this hook has no way to see who actually pressed the key, so
      // it must never claim "human". The deferred/bound path (herdr-select.sh
      // -> authorize-bound) already records the real actor directly and
      // wins the race (prompt_occ_authorized is first-write-wins), so this
      // call is a no-op there. For the non-bound/keystroke path, hand
      // prompt-occurrence.py an honest "unverified" sentinel; its own
      // record_authorized() correlates against the `approvals` table
      // herdr-select.sh writes BEFORE every keystroke and upgrades to the
      // real decided_by when a fresh matching row exists, never guessing.
      recordOccurrence([
        "authorized", ...occurrenceIdentityArgs(callId, nativeSession),
        "--decided-by", approved ? "unverified" : "unverified_or_abort",
        "--choice", approved ? "approve" : "deny",
      ]);
    }
    retract();
  } catch {
    // see onApprovalRequested().
  }
  return undefined;
}

function onExecutionEnd(event: unknown, ctx?: unknown): undefined {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    // Only `ask` was ever alerted from tool_execution_start, so only `ask`
    // needs the matching retraction; any other tool ending is not a prompt
    // being answered and must not cost a sweep.
    if (e.toolName === "ask") retract();
    const callId = typeof e.toolCallId === "string" ? e.toolCallId : undefined;
    const occ = callId !== undefined ? occurrenceByCallId.get(callId) : undefined;
    if (callId !== undefined && occ) {
      occurrenceByCallId.delete(callId);
      const isError = e.isError === true;
      if (occ.decided) {
        recordOccurrence(["completed", ...occurrenceIdentityArgs(callId, occ.nativeSession),
          ...(isError ? ["--is-error"] : [])]);
      } else {
        // Aborted/skipped before a decision ever reached this store — a
        // withdrawal, never a silent success (plan §2).
        recordOccurrence(["withdrawn", ...occurrenceIdentityArgs(callId, occ.nativeSession),
          "--reason", "execution_end_without_decision"]);
      }
    }
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
// ensureHub() used to call resolveHubPython() -> a synchronous
// `spawnSync("bash", [RESOLVE_HUB_PYTHON_SH], ...)` inside
// onBeforeAgentStart — exactly the pattern PR #273 eliminated everywhere
// else in this handler (2026-10-10 watchdog: 384 ui.loop-blocked
// entries/day; onBeforeAgentStart fires every turn, not once per session).
// Same cache-and-background-refresh shape as hubSummaryCache below:
// onBeforeAgentStart never waits on this. A cold cache this turn means
// ensureHub() simply does not attempt to start a hub THIS turn — harmless,
// since hub.py is normally already up via the launchd agent and this path
// only matters on a machine where it is not, where a LATER turn's cache
// hit (or the launchd agent, or `install.sh --hub --apply`) covers it. A
// cold cache is never treated as "start one unpinned": it is read as "do
// not start a hub this turn," never as permission to spawn bare `python3`.
let hubPythonCache: string | undefined;
let hubPythonRefreshInFlight = false;

function refreshHubPythonAsync(): void {
  if (hubPythonRefreshInFlight) return;
  hubPythonRefreshInFlight = true;
  captureOutput("bash", [RESOLVE_HUB_PYTHON_SH], { timeoutMs: 2_000 }, (ok, out) => {
    hubPythonRefreshInFlight = false;
    const py = ok ? out.trim() : "";
    if (py) {
      hubPythonCache = py;
      if (pendingOccurrenceQueue.length) void drainOccurrenceQueue();
    } else if (pendingOccurrenceQueue.length) {
      console.error(`herdr: recordOccurrence: resolver failed to find a pinned interpreter — ${pendingOccurrenceQueue.length} queued occurrence(s) still pending, will retry on the next recordOccurrence/ensureHub call`);
    }
  });
}

function ensureHub(): void {
  if (!hubAvailable) return;
  refreshHubPythonAsync();
  // FAIL CLOSED, never fall back to bare `python3`: that resolves through
  // this process's PATH with no guarantee of which interpreter answers —
  // the exact ambiguous-runtime bug (CLT /usr/bin/python3 3.9.6 vs. an
  // interactive shell's Homebrew 3.14) this resolver exists to remove.
  const py = hubPythonCache;
  if (!py) return;
  try {
    const child = spawn(py, [HUB_PY, "--port", String(HUB_PORT)], {
      detached: true,
      stdio: ["ignore", "ignore", "ignore"],
    });
    child.on("error", () => {});
    child.unref();
  } catch {
    // never into the agent turn
  }
}

interface HubSummary {
  attention: number;
  handoff_debt: number;
  open_decisions: number;
}

// hubSummary() used to spawnSync a curl (bounded 2s) on EVERY turn — one of
// the three synchronous waits onBeforeAgentStart made on omp's event loop
// (2026-10-10 watchdog: ~/.omp/logs/omp.2026-10-10.25513.log, 384
// ui.loop-blocked entries that day). Converted to cache-and-background-
// refresh: onBeforeAgentStart never waits on this. It calls
// refreshHubSummaryAsync() (fire-and-forget, in-flight-guarded) and reads
// whatever hubSummaryCache already holds — the last summary that actually
// finished fetching, possibly from an earlier turn, possibly undefined if
// none ever has (cold cache reads exactly like a hub that is down).
// `attention` is the UNION (panes + repos owing a handoff); `handoff_debt`
// is the repo half, published separately so the banner can name each with
// its own noun. A hub too old to publish the field reads as 0, same as before.
let hubSummaryCache: HubSummary | undefined;
let hubRefreshInFlight = false;

function refreshHubSummaryAsync(): void {
  if (hubRefreshInFlight) return;
  hubRefreshInFlight = true;
  captureOutput("curl", ["-s", "--max-time", "2", `${HUB_URL}api/summary`], { timeoutMs: 5_000 }, (ok, out) => {
    hubRefreshInFlight = false;
    if (!ok) return;
    try {
      const j: unknown = JSON.parse(out);
      if (!j || typeof j !== "object" || !("attention" in j) || !("open_decisions" in j)) return;
      const attention = Number(j.attention);
      const open_decisions = Number(j.open_decisions);
      const raw_debt = "handoff_debt" in j ? Number(j.handoff_debt) : 0;
      const handoff_debt = Number.isFinite(raw_debt) && raw_debt > 0 ? raw_debt : 0;
      if (Number.isFinite(attention) && Number.isFinite(open_decisions)) {
        hubSummaryCache = { attention, handoff_debt, open_decisions };
      }
    } catch {
      // malformed JSON: leave the previous cache in place, never crash
    }
  });
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

// `refreshProjectSummaryAsync` fetches /api/projects and the git common-dir
// in parallel (both small, bounded reads: curl --max-time 2, a local `git
// rev-parse`) and hands the result to this pure builder — same shape
// projectSummary() used to compute synchronously. Split out so the async
// join below has somewhere to put the result without duplicating the
// row-matching logic.
function buildProjectCard(j: unknown, cwd: string, repoRoot: string | null, fallbackRepoName: string): ProjectCard | undefined {
  if (!j || typeof j !== "object" || !("projects" in j) || !Array.isArray(j.projects)) return undefined;
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
}

// Same cache-and-background-refresh conversion as hubSummary above, for the
// SAME reason (projectSummary used to spawnSync a `git rev-parse` AND a
// curl, sequentially, on every turn — SPEC evidence L1465/L1475). cwd-keyed
// because the cwd a refresh was fetched for might not be the cwd of the
// turn reading the cache (rare — cwd basically never changes mid-session —
// but a stale cache for the WRONG project must never be shown as the
// current one): onBeforeAgentStart only uses projectCardCache when
// projectCardCacheCwd still equals the live cwd. The `git` call below is
// bounded (`timeoutMs: 2_000`, see captureOutput's header) since 2026-10-10
// — PR #273 round 2 security review, finding 1: the first version left it
// unbounded, and a hung `git` (lock contention, a flaky/networked
// worktree, a corrupted .git) left `projectRefreshInFlight` stuck `true`
// forever, silently and permanently freezing this card.
let projectCardCache: ProjectCard | undefined;
let projectCardCacheCwd: string | undefined;
let projectRefreshInFlight = false;

function refreshProjectSummaryAsync(cwd: string): void {
  if (projectRefreshInFlight) return;
  const fallbackRepoName = cwd.split(path.sep).filter(Boolean).pop();
  if (!fallbackRepoName) return;
  projectRefreshInFlight = true;
  let projResult: { ok: boolean; out: string } | undefined;
  let gitResult: { ok: boolean; out: string } | undefined;
  const maybeFinish = () => {
    if (!projResult || !gitResult) return;
    projectRefreshInFlight = false;
    if (!projResult.ok) return;
    try {
      const j: unknown = JSON.parse(projResult.out);
      const commonDir = gitResult.ok ? gitResult.out.trim() : "";
      const repoRoot = commonDir ? path.dirname(commonDir) : null;
      const card = buildProjectCard(j, cwd, repoRoot, fallbackRepoName);
      if (card) {
        projectCardCache = card;
        projectCardCacheCwd = cwd;
      }
    } catch {
      // malformed JSON: leave the previous cache in place, never crash
    }
  };
  captureOutput("curl", ["-s", "--max-time", "2", `${HUB_URL}api/projects`], { timeoutMs: 5_000 }, (ok, out) => {
    projResult = { ok, out };
    maybeFinish();
  });
  captureOutput("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, timeoutMs: 2_000 }, (ok, out) => {
    gitResult = { ok, out };
    maybeFinish();
  });
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
// This handler still returns SYNCHRONOUSLY — the runner is not guaranteed
// to wait on an async handler's eventual resolution before the prompt is
// assembled — but it no longer does any synchronous I/O of its own at all.
// 2026-10-10: the watchdog (~/.omp/logs/omp.2026-10-10.25513.log) showed 384
// ui.loop-blocked entries that day on this handler's three synchronous
// waits — reconcile's spawnSync (bounded 15s; 83 events landed at exactly
// 15.0-15.6s, the registry sweep over hundreds of registered tasks
// routinely exceeding the timeout) stacked with two `curl --max-time 2`
// calls (hub + project summaries). None of the three results were worth
// blocking a turn for: reconcile's own `report` text was NEVER injected
// into the prompt (see "the report lives on a web page", below — its only
// job here is the registry sweep's side effects and its ack), and the hub/
// project summaries are a one-line "something needs you" banner, not
// something that has to be millisecond-fresh. So every one of the three is
// now fire-and-forget (runReconcileAsync / refreshHubSummaryAsync /
// refreshProjectSummaryAsync — each in-flight-guarded so a turn can't pile
// a second sweep on one still running), and this handler reads whatever
// each one LAST finished with. A cold cache (nothing has completed yet)
// reads exactly like a hub that is down: no line, not a block. The ack
// still fires exactly when ackRequired is true, same as before — it is
// just no longer on this turn's critical path (see runReconcileAsync).

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
    if (reconcileAvailable) runReconcileAsync("session");
    refreshHubSummaryAsync();
    const cwd = process.cwd();
    refreshProjectSummaryAsync(cwd);
    const s = hubSummaryCache;
    const project = projectCardCache && projectCardCacheCwd === cwd ? projectCardCache : undefined;
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

// ---- reconcile, shared by both the session and interval callers -------------
// omp-reconcile.sh session used to run via spawnSync with a 15s timeout —
// the single largest synchronous wait onBeforeAgentStart made (see its
// header above). Its stdout (the `report`) was never injected into the
// prompt anyway — the only thing either caller needed from this call was
// the ack side effect — so running it fully async costs the banner
// nothing. One function for both modes (session: before_agent_start,
// interval: tool_result) so the sweep, envelope parse and
// ack-on-ackRequired stay in exactly one place, matching lib/reconcile.sh's
// own one-copy-for-both-hooks rationale.
//
// ONE shared in-flight guard across BOTH modes (2026-10-10, PR #273 round 2
// security review, finding 3): the old spawnSync provided mutual exclusion
// between session and interval reconcile for free by blocking the WHOLE
// event loop — interval mode (triggered from tool_result, which cannot run
// until the loop is unblocked) literally could not start while a session
// sweep was in flight. The first async version of this file used TWO
// separate per-mode guards and lost that: session and interval could run
// as two concurrent omp-reconcile.sh processes, and lib/reconcile.sh's own
// mutex (reconcile_lock_dir) is acquired ONLY by interval mode — session
// mode never takes it, so the two could race to ack_reconcile, and the
// loser's task_states (last-writer-wins, not merged — see
// lib/run-registry.sh ack_reconcile) could clobber the winner's diffing
// baseline. A single shared boolean restores "only one sweep of either
// kind at a time" without needing a cross-process lock, since both callers
// live in this same process.
//
// Killed by PROCESS GROUP, not by PID (2026-10-10, finding 2): a plain
// `child.kill()` only signals the `bash` wrapper itself — not any
// subprocess that wrapper is synchronously blocked ON (a `herdr pane
// list`, `jq`, or sqlite3 call inside lib/reconcile.sh's own sweep —
// exactly the kind of call PROOF.md's #r1 says scales with registry size).
// That subprocess inherits the wrapper's piped stdout, so it also keeps
// the pipe open after the wrapper dies — which is why `finish` is wired to
// `exit` (the direct child terminating) and NOT `close` (every stdio
// stream reaching EOF): `close` can be held open indefinitely by exactly
// the orphan `killGroup` exists to reap. `detached: true` makes the child
// its own process-group leader on POSIX, so `killGroup`'s
// `process.kill(-pid, ...)` reaches the whole group — SIGTERM first,
// SIGKILL after a 2s grace period if anything in the group is still
// alive. The kill-timer itself is a resource backstop only — NOT
// load-bearing for context injection, which never depended on this call
// completing in time. `HERDR_RECONCILE_KILL_MS` overrides the 15s default
// for tests only; production never sets it.
const RECONCILE_KILL_MS = Number(process.env.HERDR_RECONCILE_KILL_MS) || 15_000;
let reconcileInFlight = false;

function runReconcileAsync(mode: "session" | "interval"): void {
  if (reconcileInFlight) return;
  reconcileInFlight = true;
  try {
    const child = spawn("bash", [RECONCILE_SH, mode], { stdio: ["ignore", "pipe", "ignore"], detached: true });
    let out = "";
    let settled = false;
    let killTimer: NodeJS.Timeout | undefined;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(killTimer);
      reconcileInFlight = false;
      try {
        const env = parseEnvelope(out);
        if (env?.ackRequired) spawnDetached([RECONCILE_SH, "ack"], env.raw);
      } catch {
        // no ack -> the envelope replays next pass; still never injected.
      }
    };
    child.on("error", finish);
    child.stdout?.on("error", () => {});
    child.stdout?.on("data", (chunk: Buffer) => {
      // Bounded: an envelope is small; a runaway child must not buffer
      // unbounded output inside the agent process.
      if (out.length < 262_144) out += chunk.toString("utf8");
    });
    child.on("exit", finish);
    if (child.pid) {
      const pid = child.pid;
      killTimer = setTimeout(() => {
        killGroup(pid);
        finish();
      }, RECONCILE_KILL_MS);
      killTimer.unref();
    }
  } catch {
    // spawn() throwing synchronously — same contract as spawnDetached.
    reconcileInFlight = false;
  }
}

function onToolResult(event?: unknown): undefined {
  try {
    // The write-scope guard's scratch files become "created by this session"
    // only when the call that creates them actually succeeded.
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    if (typeof e.toolCallId === "string") {
      const created = pendingScratch.get(e.toolCallId);
      pendingScratch.delete(e.toolCallId);
      // Only a file that now exists was created by this call (an lsp rename of
      // a missing file returns a non-error result and creates nothing).
      if (created && e.isError !== true) {
        for (const p of created) {
          try {
            lstatSync(p);
            scratchCreatedHere.add(p);
          } catch {
            // not created: stays unclaimed
          }
        }
      }
    }
    // Reconciliation. Retraction moved to the approval/ask events above:
    // sweeping here fired it on every tool call in every session, and while
    // any worker sat blocked the queue was non-empty, so it always did work.
    if (reconcileAvailable) runReconcileAsync("interval");
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
  // Patched OMP separates authority from legacy lifecycle observers. Older
  // OMP versions do not expose this method; their approval event has no exact
  // binding/resolver, so the compatibility registration remains human-only.
  if (typeof pi.handleToolApproval === "function") pi.handleToolApproval(onApprovalRequested);
  else pi.on("tool_approval_requested", onApprovalRequested as never);
  pi.on("tool_approval_resolved", onApprovalResolved);
  pi.on("tool_execution_start", onExecutionStart);
  pi.on("tool_execution_validate", onExecutionValidate);
  pi.on("tool_execution_end", onExecutionEnd);
  pi.on("before_agent_start", onBeforeAgentStart);
  pi.on("tool_result", onToolResult);
  pi.on("agent_end", onAgentEnd);
  pi.on("session_stop", onSessionStop);
}
