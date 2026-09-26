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
// (every action not known read-only, incl. rename_file's `new_name`), and by shape any tool
// whose name says it mutates (write/edit/patch/rename/…) AND carries a
// path-like field. NOT covered here: `eval` (arbitrary code; omp's approval
// layer governs it), bash (lib/command-policy.sh), and tools that write omp's
// own state rather than a path (learn, manage_skill, retain).
const WORKER_TASK_ID = process.env.HERDR_TASK_ID?.trim() ?? "";
const WORKER_RUN_ID = process.env.HERDR_RUN_ID?.trim() ?? "";
const LOAD_HOME = process.env.HOME?.trim() || homedir();
const LOAD_TMPDIR = process.env.TMPDIR?.trim() ?? "";
const LOAD_RUN_STATE_DIR = process.env.HERDR_RUN_STATE_DIR?.trim() ?? "";
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
    const patch = /^\*\*\* (?:(?:Add|Update|Delete) File|Move to):\s*(.+)$/.exec(t);
    if (patch) out.push(unquote(patch[1]));
  }
  return out;
}

const MUTATING_NAME = /(write|edit|patch|notebook|rename|move|delete|remove|mkdir|create|replace|append|save)/;
const LSP_MUTATING_ACTION = /(rename|code_?action|format|fix|organi[sz]e|apply)/;
const LSP_READONLY_ACTION =
  /^(definition|type_?definition|declaration|implementation|references|hover|signature(_help)?|symbols?|document_symbols?|workspace_symbols?|diagnostics|status|incoming_calls|outgoing_calls|call_hierarchy|completion|highlight)$/;

// The raw targets a file-mutating call names; undefined when the tool is not
// file-mutating (it is never checked); a string when it is mutating but its
// targets cannot be read (refused).
interface MutationTargets {
  raw: string[];
  xdContent?: string; // write's content, parsed only for an xd:// target
  globOk?: boolean; // ast_edit expands globs; every other tool takes a path literally
}

function mutationTargets(toolName: string, rec: Record<string, unknown>): MutationTargets | string | undefined {
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
  if (name === "lsp") {
    // omp tiers lsp by a read-only action set it does not export, so this errs
    // the other way: any action not known read-only is checked when it names
    // a file, and a known-mutating one that names none is refused.
    const action = typeof rec.action === "string" ? rec.action.toLowerCase() : "";
    if (LSP_READONLY_ACTION.test(action)) return undefined;
    const targets = pathFields(rec);
    // rename_file / move_file take the destination in `new_name`.
    if (action.includes("file") && typeof rec.new_name === "string" && rec.new_name) targets.push(rec.new_name);
    if (targets.length > 0) return { raw: targets };
    return LSP_MUTATING_ACTION.test(action) ? `lsp ${action} names no file` : undefined;
  }
  if (name === "ast_edit" || name === "astedit") {
    const targets = pathFields(rec);
    return targets.length > 0 ? { raw: targets, globOk: true } : `${toolName} names no path`;
  }
  if (name === "multiedit" || name.startsWith("notebook")) {
    const targets = pathFields(rec);
    return targets.length > 0 ? { raw: targets } : `${toolName} names no path`;
  }
  if (MUTATING_NAME.test(name)) {
    const targets = pathFields(rec);
    return targets.length > 0 ? { raw: targets } : undefined;
  }
  return undefined;
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
// path-utils/write.ts, found by the PR #159 review). It unwraps a copied
// `[path#TAG]` / `[path]`, drops a leading `@` before `/` or `~`, and drops a
// leading `:` before `/`, `~`, `./` or `../`. ast_edit also strips surrounding
// double quotes and splits one entry on `;`, `,` and whitespace. Every form is
// checked, so whichever one omp opens is in scope.
function candidateForms(raw: string, globOk: boolean): string[] {
  const seen = new Set<string>();
  const queue = [raw.trim()];
  while (queue.length > 0 && seen.size < 64) {
    const f = queue.shift() as string;
    if (!f || seen.has(f)) continue;
    seen.add(f);
    const bracket = /^\[(.+?)(?:#[0-9A-Fa-f]{4})?\]$/.exec(f);
    if (bracket) queue.push(bracket[1].trim());
    if (/^@[/~]/.test(f)) queue.push(f.slice(1));
    if (/^:(?:[/~]|\.\.?\/)/.test(f)) queue.push(f.slice(1));
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
  for (const form of candidateForms(raw, targets.globOk === true)) {
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
    const inner = mutationTargets(device, rec) ?? { raw: pathFields(rec) };
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
    const targets = mutationTargets(toolName, input);
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
    const c = ctx && typeof ctx === "object" ? (ctx as Record<string, unknown>).cwd : undefined;
    const cwd = typeof c === "string" && path.isAbsolute(c) ? c : process.cwd();
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
function notifyForPrompt(toolName: string, message: string, command?: string): void {
  if (!notifyAvailable) return;
  const payload: Record<string, unknown> = { tool: toolName, message, cwd: process.cwd() };
  if (command) payload.command = command;
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
const inputByCallId = new Map<string, unknown>();

function cacheBashInput(event: unknown): void {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    const name = typeof e.toolName === "string" ? e.toolName.toLowerCase() : "";
    if ((name !== "bash" && name !== "shell") || typeof e.toolCallId !== "string") return;
    inputByCallId.set(e.toolCallId, e.input);
    while (inputByCallId.size > INPUT_CACHE_MAX) {
      const oldest = inputByCallId.keys().next().value;
      if (oldest === undefined) break;
      inputByCallId.delete(oldest);
    }
  } catch {
    // MUST NOT throw — a throwing tool_call handler blocks the tool.
  }
}

function onToolCall(event: unknown, ctx?: unknown): Block | undefined {
  cacheBashInput(event);
  return pretoolRegistrationBlock(event) ?? workerWriteScopeBlock(event, ctx);
}

function onApprovalRequested(event: unknown): undefined {
  try {
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    const toolName = typeof e.toolName === "string" && e.toolName ? e.toolName : "tool";
    const callId = typeof e.toolCallId === "string" ? e.toolCallId : undefined;
    const input = e.input ?? e.args ?? (callId !== undefined ? inputByCallId.get(callId) : undefined);
    if (callId !== undefined) inputByCallId.delete(callId);
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

function onToolResult(event?: unknown): undefined {
  try {
    // The write-scope guard's scratch files become "created by this session"
    // only when the call that creates them actually succeeded.
    const e = event && typeof event === "object" ? (event as Record<string, unknown>) : {};
    if (typeof e.toolCallId === "string") {
      const created = pendingScratch.get(e.toolCallId);
      pendingScratch.delete(e.toolCallId);
      if (created && e.isError !== true) for (const p of created) scratchCreatedHere.add(p);
    }
    // Reconciliation. Retraction moved to the approval/ask events above:
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
