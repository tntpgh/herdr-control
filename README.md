# herdr-control

Small, dependency-light shell tools that drive the **layout** of a
[herdr](https://github.com/) session — the terminal workspace manager for AI
coding agents — instead of just the messages inside it:

- **route** an agent session into its own tab of the right project's workspace,
- **open** a project's workspace on demand (reuse it if it's already open),
- **sort** a space's tabs by the state of the branch each one is on,
- **colour** a tab by what it needs from you,
- **name** each tab after the task its dominant pane is actually doing, and
- **surface** the one agent that needs you next, with an honest waiting-reason.

They're plain `bash` + `python3` over herdr's control socket. No install step,
no framework — clone, edit one config file, run.

## Why

With several agents running across repos in one herdr server, tabs pile up in
creation order and you lose track of which branch needs a decision versus which
is already merged. These scripts put the tabs that need you on top and let you
spin an agent into the correct workspace with one command.

## Requirements

- `herdr` ≥ 0.7 running (the scripts talk to `~/.config/herdr/herdr.sock`)
- `bash`, `python3`, `jq`, `git`
- `gh` (GitHub CLI), authenticated — optional; only `sort-tabs.sh` uses it, to
  tell *reviewed* / *merged* / *waiting* apart. Without it, set
  `HERDR_SORT_NO_GH=1` for git-only ranking.

## Setup

```bash
git clone <this-repo> herdr-control && cd herdr-control
$EDITOR config.sh          # the ONE file with your specifics — see below
./install.sh               # show what would be wired into Claude Code
./install.sh --apply       # wire it
# optional: put them on PATH
ln -s "$PWD"/*.sh ~/.local/bin/
```

### What `install.sh` does

The scripts here do nothing until something *calls* them, and that wiring lives
in `~/.claude/settings.json`. `install.sh` registers three hooks:

| event | script | why |
|---|---|---|
| `Notification` | `agent-hooks/claude-notify.sh` | alert you when an agent needs input |
| `PostToolUse` | `herdr-resolve.sh` | retract alerts you answered in the terminal |
| `Stop` | `herdr-resolve.sh` | backstop for the same |
| `SessionStart` | `agent-hooks/session-reconcile.sh` | report task-state changes missed while no conductor was watching, and detect `lost` tasks — see below |
| `PostToolUse` | `agent-hooks/interval-reconcile.sh` | same sweep + report, throttled to run at most once per `HERDR_RECONCILE_INTERVAL_S` (default 300s) — the mid-session counterpart to `SessionStart`'s one-time pass |

It **edits `settings.json` in place and never replaces it** — that file is
personal and routinely holds secrets and unrelated config. It merges only the
entries above, writes a timestamped `.bak-herdr-*` first, validates the result
before swapping it in, and is **idempotent**: a job already wired under a
different script name is detected and skipped rather than duplicated, so you do
not end up with every alert firing twice.

Run it with no arguments for a dry run. Add `--bridge` to also install the
launchd daemon (macOS) from `slack-bridge/com.herdr-control.bridge.plist.template`.

`install.sh` also symlinks the omp side of the same wiring: `agent-hooks/omp-herdr-control.ts` into `~/.omp/agent/extensions/herdr-control.ts` (or `$PI_CODING_AGENT_DIR/extensions` when set) — omp's own auto-discovery root, so it applies globally and cwd-independently, the same way `~/.claude/settings.json` does for Claude. One symlink gives an omp session the same four jobs the hook table above gives a Claude session (push-wake, session reconciliation, mid-session reconciliation, alert retraction), mapped onto omp's `tool_call` / `before_agent_start` / `tool_result` / `agent_end` extension events instead. It never copies the file — an edit here is live on the next omp session with no reinstall — refuses to clobber a real (non-symlink) file already at that path, and is idempotent and `--repoint`-aware exactly like the Claude hooks above. To disable it without uninstalling, add `disabledExtensions: [extension-module:herdr-control]` to `~/.omp/agent/config.yml`.

**`config.sh` is the only file you edit** — it holds every machine/personal
default (which agent to launch, PATH for a minimal environment, the metadata
label, sort preferences). Everything else is generic. Each value is also
overridable as an environment variable per run.

## Usage

```bash
# Route: open (or reuse) the project's workspace, new tab, run an agent in it
./spawn-agent.sh ~/src/app fix-bug              # your default agent
./spawn-agent.sh ~/src/app audit codex          # a specific agent
./ensure-workspace.sh ~/src/app                 # just print the workspace id

# Task: a worktree opened as a SUB-TAB in the repo's space, at the model the
# job-class maps to (plan→opus/deep, implement→sonnet/std, explore→haiku/fast)
./spawn-task.sh ~/src/app fix-comps implement          # claude sonnet
./spawn-task.sh ~/src/app arch review codex            # codex, deep model
./spawn-task.sh ~/src/app fix-parser implement omp     # omp, sonnet (verified 2026-07-31)
./spawn-task.sh ~/src/app fix-comps implement --dry-run # preview, no changes

# Sort: reorder tabs by branch state, needs-you first
./sort-tabs.sh                                   # the focused workspace
./sort-tabs.sh --all --dry-run                   # every workspace, show the plan
./sort-tabs.sh w2 --mark                         # also recolour by state

# Colour: assert a tab's status (+ optional badge)
./mark-tab.sh w2:t3 waiting "merge decision?"

# Name: rename tabs after the work their dominant pane is doing
./smart-name.sh                                  # the focused tab
./smart-name.sh --all --dry-run                  # every tab, show the plan
./smart-name.sh --no-ai --all                    # deterministic names only, no model

# Surface: honest per-agent waiting-reason + "what needs me next"
./attention.sh --focus                           # the one thing to look at next
./attention.sh --dry-run                          # classify every agent, change nothing
```

### Sort ranking (top → bottom, attention-first)

| rank | state | how it's detected |
|------|-------|-------------------|
| 1 | `waiting` | open PR awaiting review / changes requested (`gh`) |
| 2 | `active` | uncommitted changes in the tree |
| 3 | `committed` | clean, no approving PR |
| 4 | `reviewed` | PR approved, not yet merged (`gh`) |
| 5 | `merged` | PR merged (`gh`) |
| 6 | `other` | not a git repo / detached HEAD |

`HERDR_SORT_DONE_FIRST=1` flips it; `HERDR_SORT_NO_GH=1` drops the `gh` calls.

### Bind sort to a key (optional)

In `~/.config/herdr/config.toml`, then `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+shift+o"          # ctrl+b then shift+O
type = "shell"                  # runs detached; sort needs no TTY
command = "bash /path/to/herdr-layout/sort-tabs.sh --all"
```

## Wake persistence across conductor sessions

`spawn-task.sh` registers every task in a durable run registry
(`lib/run-registry.sh`, under `~/.local/state/herdr/runs/`) and
`agent-hooks/claude-notify.sh` pushes a wake to the conductor pane the moment a
worker needs input. But push only works while the conductor session that
spawned the worker is still running — close that session and its background
`wake-on-evidence.sh` poller dies with it, so a reopened session starts blind
to anything that happened in the meantime.

The registry itself is one SQLite database (`registry.sqlite3`, WAL mode)
under that directory now, not a JSON file per task plus an append-only
`events.jsonl` per run — the file layout it replaced. Four things the files
could not do without reimplementing a database badly: a real monotonic event
sequence (`AUTOINCREMENT`, not `grep -c` a file and then append — two writers
racing on that produced the *same* sequence number and neither noticed),
dedup via `UNIQUE(event_id)` so an at-least-once retry doesn't log an event
twice, a state change and its event-log entry landing in ONE transaction
instead of two writes that could diverge, and a consumer cursor over the
*event stream* itself, not just task state, so "replay every event exactly
once" is actually expressible. `task_id` is now a primary key, so a colliding
id fails loudly instead of silently overwriting a live worker's registration,
and legal state transitions are enforced — `completed → running` is refused,
not merely unusual. Whatever was already on disk from the old layout is
imported once, non-destructively, the first time the registry runs; nothing
is deleted.

The shared sweep+report logic (`lib/reconcile.sh`) fixes that from two hooks:

- **`agent-hooks/session-reconcile.sh`** (`SessionStart`, once per session) —
  reports every task whose state changed to `completed` / `failed` /
  `blocked` / `lost` since *this conductor* last checked in, via a checkpoint
  stored beside the registry, not in any repo, so a worktree cleanup can't
  reset it and a reported task is never re-announced.
- **`agent-hooks/interval-reconcile.sh`** (`PostToolUse`, throttled) — the
  same sweep + report, but running *during* a long-lived session instead of
  only at its start, so a worker that goes `lost` or completes an hour into
  an open session doesn't wait for the next restart to be noticed. Activity-
  gated, not a real timer: an idle session with no tool calls gets no
  reconciliation until its next tool call. Tune the interval with
  `HERDR_RECONCILE_INTERVAL_S` (default 300s, in `config.sh`).

Both do the reconciliation half of "push + reconciliation": a task still
`starting`/`running`/`blocked` whose registered pane no longer exists, or
whose live `terminal_id` no longer matches the fingerprint recorded at spawn
(pane ids get recycled), is marked `lost` rather than silently staying
"running" forever.

### Pane-recycling is also closed on the delivery side

Reconciliation catches a recycled pane on its own schedule; `claude-notify.sh`
(push wake) and `herdr-select.sh` (answering a prompt) close the same gap
*at the moment of delivery*, which is where it actually matters — pane ids
free up and get reissued while a session is running, and a wake or a keypress
aimed at a bare pane id can land in whatever unrelated process now holds that
id. Both re-read the target pane's live `terminal_id` and compare it against
the fingerprint the run registry recorded at spawn (the worker's own pane for
`herdr-select.sh`, the conductor's pane — via `spawn-task.sh`'s new
`conductor_pane_birth` — for `claude-notify.sh`), refusing on any mismatch.
Enforced automatically whenever the pane is registered; a pane spawned outside
the registry (e.g. `spawn-agent.sh`) has nothing to check against, so it's
unaffected. See `lib/pane-guard.sh`'s `require_pane_birth_match`.

### omp workers push too

Everything above talks about Claude Code because that was the only
integration for a while. `install.sh` now wires the identical four jobs into
an omp session too — see "What `install.sh` does" above for the symlink —
mapped onto omp's own event names: `tool_call` → alert + push-wake,
`before_agent_start` → session reconciliation injected as a message,
`tool_result` → throttled mid-session reconciliation + alert retraction,
`agent_end` → retraction backstop. Same shared code underneath
(`lib/push-wake.sh`, `lib/reconcile.sh`) as the Claude hooks — Claude and omp
cannot drift into two different notions of "the worker needs you."

omp has no event that means "I am asking the human something" the way
Claude's `Notification` does — only `tool_call`, which fires before *every*
tool call, approved or not. Alerting straight off that would be a signal
storm, so `agent-hooks/omp-notify.sh` polls the worker's own pane for a
prompt that actually painted and stays silent when none appears — safe to
call on every tool call, and approval-mode-agnostic by construction: under
`yolo` nothing ever prompts, so nothing ever alerts.

**Only reaches workers `spawn-task.sh` launched.** The push wake needs
`HERDR_PANE_ID` stamped into the worker's environment; an omp session started
by hand has none, so it stays reconciliation-only (`attention.sh`,
`wait-for-blocked.sh`, the interval sweep) — the same deal a hand-started
Claude session gets.

## Approval posture and command policy

`spawn-task.sh` composes two independent floors, both set in `config.sh`,
both of which only ever get *stricter* for one spawn, never looser:

- **Approval posture** (`lib/posture.sh`) — `yolo` (no gate) < `write`
  (auto-approve file edits, still prompt before executing — the default
  `HERDR_POSTURE_FLOOR`) < `strict` (prompt before everything).
  `compose_posture` returns the more restrictive of the machine floor and a
  per-spawn request; an unrecognized posture name fails *closed* to `strict`,
  loudly, rather than being ignored. `lib/agent-profiles.sh` translates the
  resolved posture into each agent's own verified flag —
  `claude --permission-mode acceptEdits|manual|bypassPermissions`,
  `omp --approval-mode write|always-ask|yolo`. **codex gets no posture flag
  at all** — its approval surface isn't a single documented enum the way the
  other two are, and a guessed flag would either break the spawn or silently
  fail to enforce anything while looking like it did. `posture_is_enforced_for
  codex` returns false so a caller can say so rather than imply a guarantee.
- **Command policy** (`lib/command-policy.sh`) — classifies the shell command
  behind an approval prompt as `allow` / `escalate` / `deny`: recursive `rm`,
  `git push --force`, `DROP`/`TRUNCATE TABLE`, `mkfs` and fork-bombs,
  `curl | sh`, plus your own rules via `HERDR_POLICY_EXTRA_RULES` in
  `config.sh` (newline-separated, tab-separated
  `<escalate|deny><TAB><regex><TAB><reason>` — there is no operator verdict
  meaning "allow", so a site rule can only tighten). This is what
  `herdr-select.sh --authority peer` checks before letting one agent
  auto-answer another agent's prompt on your behalf: anything short of
  `allow` is refused (exit code 8) and left for you. Classification can only
  see what's on screen — a command that scrolled away can't be judged, which
  is why `--authority peer` is opt-in and `human` (the default) still records
  the verdict but never enforces it.

See `SKILL.md`'s "The safety model" for the full list of what refuses and why.

## Name tabs by their work, and see who needs you (`smart-name.sh` + `attention.sh`)

Two tabs both reading "Main" tell you nothing. These give a tab a name that says
what it's *for*, and give the sidebar an honest read on which agent is stuck.

**`smart-name.sh` — tabs that say what the work is.** It looks at a tab's
dominant pane (focused agent → any agent → focused command → first pane) and
renames the tab to a 2–4 word task label. Known processes are named instantly
with no model call — `Run Tests`, `Dev Server`, `View Logs`, `Remote Shell`,
`Database Shell`. An agent doing ambiguous work is summarised by a cheap model.
The idea is from [iurysza/herdr-tab-smart-rename](https://github.com/iurysza/herdr-tab-smart-rename);
this is a pure-bash, Claude-native take — no Bun, no plugin.

- **Manual names win.** A tab is only renamed when its label is a herdr
  auto-name (`Main` / a number) or a name *this tool* set last time. A name you
  typed is never touched — `--force` overrides, `--reset` hands a tab back.
- **The model is a bare summariser, not an agent.** `claude -p` is normally a
  full Claude Code agent that would read the *launcher's* project and name the
  tab after the wrong repo. smart-name strips it back with `--system-prompt`,
  `--setting-sources ""`, no tools, no MCP, run from an empty dir — so the label
  comes only from the target pane's screen. Set `SMART_NAME_AI=0` for
  deterministic-only (no key, no network, no cost); `SMART_NAME_MODEL` picks the
  model (default `haiku` — naming is trivial).
- **Untrusted by construction.** The pane scrape is sanitized (ANSI stripped,
  `$HOME` folded, common secret shapes redacted, capped) and the prompt tells
  the model the context is evidence, never instructions.

**`attention.sh` — an honest waiting-reason, and one next action.** For every
agent pane it publishes a `$status` sidebar token and (where herdr has no real
status of its own) sets the tab colour, classified with strict precedence:

| reason | meaning |
|---|---|
| `permission` | a numbered prompt is on screen — answer it now |
| `waiting` | screen unchanged past `HERDR_STALL_SECS`, no prompt (sub-reason: `waiting for input` / `stalled Ns`) |
| `working` | screen changed since the last pass |
| `idle` | not an agent / a quiet shell |

Its doctrine, borrowed from [caioniehues/herdmates](https://github.com/caioniehues/herdmates),
is **never show a wrong reason** — when a state isn't clear it degrades to a
plain `waiting` rather than guessing. A live agent's own status hook always wins
the colour; the token is display-only and always safe. `--focus` prints the
single most-urgent agent, then the short queue behind it — the "what do I look at
next" view, in one line.

**Sidebar + keys.** The `$task` and `$status` tokens only render if you tell the
sidebar about them. Merge [`docs/herdr-config-snippet.toml`](docs/herdr-config-snippet.toml)
into `~/.config/herdr/config.toml` (`herdr server reload-config`) — it adds the
agent-card rows and binds `prefix+t` (name this tab), `prefix+alt+t` (name all),
and `prefix+a` (the focus popup). Invalid token names fail *silently* (reload
reports `partial`); if a row never appears, run `herdr config check`.

Both are cheap to run on a timer. A herdr `type = "shell"` keybinding, a `loop`,
or a cron that calls `attention.sh` every minute keeps the sidebar honest without
a daemon.

## Answer agents from Slack (optional, two-way)

`herdr-deliver.sh` delivers a message to an agent (or `--blocked` = the one that's
waiting). The `slack-bridge/` builds a **two-way** conversation with a Slack bot:

- **Outbound** — `herdr-notify.sh --pane <id> "<text>"` posts an alert to your DM
  as the bot and records `ts→pane`.
- **Inbound** — a Socket-Mode daemon (`slack-herdr-bridge.py`, run via
  `run-bridge.sh`) routes your reply to a pane: (1) a reply **threaded** under an
  alert → that alert's pane; (2) an explicit `w8:p2 <text>` prefix; (3) the single
  blocked agent. Fail-closed to an allowlist of your Slack user id(s).

So a blocked worker DMs you and you answer *in the thread* — it lands in the right
pane, from your phone, no terminal. One-time Slack-app setup in
`slack-bridge/SETUP.md`. Wire `herdr-notify.sh` into your agent's notify hook to
replace a one-way webhook.

## How it works (worth knowing before you review)

A few herdr API facts these rely on, since they aren't obvious from the CLI:

- **A project maps to a workspace by pane `cwd`**, not the workspace `worktree`
  field (empty unless it's a herdr-managed worktree) or its label (cosmetic).
  `herdr pane list` carries `cwd` + `tab_id` + `workspace_id` per pane.
- **Tab order is the array order** from `herdr tab list` — `.number` is a stable
  per-tab id, not a position, so never sort on it.
- **Reordering uses the socket method `tab.move {tab_id, insert_index}`, which
  has no CLI verb** — `herdr-rpc.py` speaks the socket directly and matches the
  reply id past interleaved event lines.
- **There is no arbitrary tab colour.** A tab shows its pane's `agent_status`
  (`idle|working|blocked`), so `mark-tab.sh` maps a "need" onto that fixed set,
  plus an optional text badge (`state-label`). Note it's an assertion, not a
  lock — a live agent's own status hook can overwrite the pane it occupies.
- **Only agent *sessions* become tabs.** In-process sub-agents are not panes.

## Files

| file | role |
|------|------|
| `config.sh` | **your config** — the only file to edit |
| `ensure-workspace.sh` | focus-or-create a project's workspace |
| `spawn-agent.sh` | new tab in a project's workspace, run an agent |
| `spawn-task.sh` | worktree as a sub-tab, launched at the job-class's model |
| `sort-tabs.sh` | reorder tabs by branch state |
| `mark-tab.sh` | set a tab's status/colour + badge |
| `smart-name.sh` | rename tabs after the task their dominant pane is doing |
| `attention.sh` | honest per-agent waiting-reason + `--focus` next-action view |
| `herdr-deliver.sh` | deliver+submit a message to an agent (or `--blocked`) |
| `send-to-agent.sh` | robust type+submit into a pane (delivery primitive) |
| `herdr-select.sh` | answer a prompt — numbered digit or omp's arrow menu — by pressing the right key(s); `--authority peer\|human` gates auto-answer through command policy |
| `herdr-resolve.sh` | retract Slack alerts whose prompt was answered elsewhere |
| `wake-on-evidence.sh` | poll a peer's `.omc/handoffs/events.jsonl` for a marker, then wake |
| `install.sh` | wire the hooks into Claude Code and the omp extension symlink (idempotent, dry-run by default) |
| `verify-run-registry.sh` | 42-check verification of the SQLite run registry — sequencing, dedup, transactions, migration from the old file layout |
| `verify-posture.sh` | 49-check verification of the posture ladder — composition, fail-closed unknowns, per-agent flag translation |
| `verify-command-policy.sh` | 25-check verification of the command-policy classifier — floor rules, normalization, operator rules |
| `verify-select-policy.sh` | 29-check verification of `herdr-select.sh --authority peer` against a stubbed herdr — runs the real script, not a reimplementation |
| `verify-omp-hooks.sh` | 21-check verification of the omp extension's four event handlers against a stubbed pane |
| `agent-hooks/claude-notify.sh` | the `Notification` hook that raises the alert |
| `agent-hooks/session-reconcile.sh` | the `SessionStart` hook: reconcile the run registry (detect `lost` tasks) and report state changes missed since this conductor last checked in |
| `agent-hooks/interval-reconcile.sh` | the throttled `PostToolUse` hook: same sweep + report, mid-session |
| `agent-hooks/omp-herdr-control.ts` | omp extension module (symlinked by `install.sh`) mapping `tool_call`/`before_agent_start`/`tool_result`/`agent_end` to the same four jobs the Claude hooks do |
| `agent-hooks/omp-notify.sh` | omp's equivalent of `claude-notify.sh` — polls for a painted prompt before alerting, silent otherwise, so it's safe on every `tool_call` |
| `agent-hooks/omp-reconcile.sh` | omp's equivalent of `session-reconcile.sh` + `interval-reconcile.sh`, invoked from `before_agent_start`/`tool_result` |
| | *(named `agent-hooks/`, not `hooks/`, on purpose — see below)* |
| `settings.example.json` | the hook wiring alone, with placeholders — merge, don't copy |
| `SKILL.md` | what the tools do, and why several of them refuse things |
| `AGENTS.md` | step-by-step activation for an agent to follow, with verification |
| `lib/agent-profiles.sh` | known-agent process names, job-class→model routing, per-agent capabilities (`numbered-prompt`/`menu-prompt`/`summariser`/`push-hook`), and posture→flag translation — single source of truth; add a new agent here |
| `lib/pane-guard.sh` | "is this pane safe to send input to?" — shared gate, plus `require_pane_birth_match` (recycled-pane refusal) |
| `lib/prompt-parse.sh` | read the options / context an agent is showing, plus `prompt_id` |
| `lib/pane-name.sh` | pane id → "Space — Tab", for alerts a human reads |
| `lib/posture.sh` | the approval posture ladder (`yolo`<`write`<`strict`) — `compose_posture` only ever tightens a per-spawn request against `HERDR_POSTURE_FLOOR` |
| `lib/command-policy.sh` | classifies the shell command behind a prompt (`allow`/`escalate`/`deny`) — the gate `herdr-select.sh --authority peer` enforces before auto-answering |
| `lib/run-registry.sh` | central run/task registry — one SQLite database (`registry.sqlite3`, WAL) for identity, lifecycle, sequenced+deduped events, checkpoints, and the approval decided/attempted/confirmed lifecycle; imports the old JSON/JSONL layout once, non-destructively (see `docs/control-plane-design.md`) |
| `lib/push-wake.sh` | shared push-wake delivery + outcome recording (pane-birth check, `prompt_id` capture, `wake_attempted`/`wake_result`) — used by `claude-notify.sh` and `omp-notify.sh` alike |
| `lib/reconcile.sh` | the reconciliation sweep + report, shared by `session-reconcile.sh` and `interval-reconcile.sh` |
| `docs/control-plane-design.md` | conductor/worker control-plane design — what's built vs. only designed, plus multi-agent portability status |
| `docs/herdr-config-snippet.toml` | sidebar rows + keybindings for the two tools above |
| `slack-bridge/` | two-way Slack bot: outbound alerts + reply routing |
| `herdr-rpc.py` | socket JSON-RPC for verbless methods (`tab.move`) |

### Why `agent-hooks/` and not `hooks/`

Please don't rename it back. Agent sandboxes commonly block **writes to any
directory named `hooks/`** — a sensible guard, since a writable `.git/hooks` is
arbitrary code execution on the next git command, and the sandbox can't tell a
git hook directory from any other. Observed behaviour with a folder called
`hooks/`: creating and modifying files inside it is denied, while deleting is
allowed.

That breaks more than editing. **`git clone` has to create the file**, so a
sandboxed agent can't even check this repo out cleanly — which is precisely the
reader `AGENTS.md` is written for. The name also says what these are: hooks for
your coding agent, not git hooks.

## License

MIT — see [LICENSE](LICENSE).
