# herdr-control

Small, dependency-light shell tools that drive the **layout** of a
[herdr](https://github.com/) session — the terminal workspace manager for AI
coding agents — instead of just the messages inside it:

- **route** an agent session into its own tab of the right project's workspace,
- **open** a project's workspace on demand (reuse it if it's already open),
- **sort** a space's tabs by the state of the branch each one is on, and
- **colour** a tab by what it needs from you.

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

It **edits `settings.json` in place and never replaces it** — that file is
personal and routinely holds secrets and unrelated config. It merges only the
entries above, writes a timestamped `.bak-herdr-*` first, validates the result
before swapping it in, and is **idempotent**: a job already wired under a
different script name is detected and skipped rather than duplicated, so you do
not end up with every alert firing twice.

Run it with no arguments for a dry run. Add `--bridge` to also install the
launchd daemon (macOS) from `slack-bridge/com.herdr-control.bridge.plist.template`.

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
./spawn-task.sh ~/src/app fix-comps implement --dry-run # preview, no changes

# Sort: reorder tabs by branch state, needs-you first
./sort-tabs.sh                                   # the focused workspace
./sort-tabs.sh --all --dry-run                   # every workspace, show the plan
./sort-tabs.sh w2 --mark                         # also recolour by state

# Colour: assert a tab's status (+ optional badge)
./mark-tab.sh w2:t3 waiting "merge decision?"
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
| `herdr-deliver.sh` | deliver+submit a message to an agent (or `--blocked`) |
| `send-to-agent.sh` | robust type+submit into a pane (delivery primitive) |
| `herdr-select.sh` | answer a numbered prompt by pressing that option's key |
| `herdr-resolve.sh` | retract Slack alerts whose prompt was answered elsewhere |
| `wake-on-evidence.sh` | poll a peer's `.omc/handoffs/events.jsonl` for a marker, then wake |
| `install.sh` | wire the hooks into Claude Code (idempotent, dry-run by default) |
| `agent-hooks/claude-notify.sh` | the `Notification` hook that raises the alert |
| | *(named `agent-hooks/`, not `hooks/`, on purpose — see below)* |
| `settings.example.json` | the hook wiring alone, with placeholders — merge, don't copy |
| `SKILL.md` | what the tools do, and why several of them refuse things |
| `AGENTS.md` | step-by-step activation for an agent to follow, with verification |
| `lib/pane-guard.sh` | "is this pane safe to send input to?" — shared gate |
| `lib/prompt-parse.sh` | read the options / context an agent is showing |
| `lib/pane-name.sh` | pane id → "Space — Tab", for alerts a human reads |
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
