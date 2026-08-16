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

Two layers, cleanly split — **Herdr-Plugin Layer** (pure herdr-socket calls;
optionally installable as `herdr-plugin.toml`) and **Outside-Herdr Layer**
(reacts to Claude Code's/omp's own hook systems, which herdr's plugin
manifest can't see). Full definition and the test for where a new idea
belongs: [As a herdr plugin](#as-a-herdr-plugin-instead-of-manual-keybindings-herdr-plugintoml)
below.

## Tools this repo uses (and how to swap them)

Nothing here talks a herdr **plugin** protocol — every script is a thin
wrapper over the `herdr` CLI (JSON on stdout) plus a short list of ordinary
Unix tools. That's deliberate: no build step, no runtime to install, and
every dependency below either degrades cleanly or has a documented swap
point, so this stays usable on a machine that doesn't look like the one it
was written on.

**Required** — `install.sh` checks `jq`/`python3`/`herdr`/`curl` itself and
refuses to wire anything up if one is missing:

| tool | why |
|---|---|
| `herdr` ≥ 0.7, running | everything talks to its control socket (`~/.config/herdr/herdr.sock`) |
| `bash` | every script |
| `python3` | JSON parsing where a one-liner would be unreadable (`wait-for-blocked.sh`'s pane-scan), `smart-name.sh`'s pane-scrape sanitizer |
| `jq` | JSON parsing everywhere else — the dominant tool here |
| `git` | repo-root resolution, worktrees, `sort-tabs.sh`'s branch-state ranking |
| `curl` | Slack bridge outbound calls (`herdr-notify.sh`, `herdr-resolve.sh`) |
| `sqlite3` | `lib/run-registry.sh`'s task registry (WAL mode). Ships with macOS; on Linux, install it (`apt install sqlite3` / equivalent) — nothing here vendors or bundles it |

**Optional — real functionality lost, nothing breaks:**

| tool | what needs it | without it |
|---|---|---|
| `gh` (authenticated) | `sort-tabs.sh`'s *reviewed*/*merged*/*waiting* PR-state ranking | set `HERDR_SORT_NO_GH=1` for git-only ranking (dirty/committed/clean) |
| `fzf` | `--pick` on `open-project.sh`/`quick-action.sh`, quick-action `type: select` | every headless, by-name invocation works unchanged — `--pick` is a convenience layer over the same lookup |
| `tmux` | conductor-id fallback (`lib/reconcile.sh`), Slack-reply thread-context detection (`herdr-notify.sh`) | falls through to its next identity source; not a hard dependency of anything |
| `bun` | `preview.sh`'s `open` subcommand (drives the omp browser plugin) | every other `preview.sh` action is unaffected |
| `system_profiler` | `preview.sh`'s display-profile auto-detection (macOS) | fails **open** to `wide`, never silently narrow |
| `timeout` / `gtimeout` / `perl` | `smart-name.sh`'s AI-summary call gets a real timeout | tries all three in order, in that file — see the note below before assuming any one of them is on PATH |

> **Lesson learned shipping this repo's own `verify-quick-actions.sh`:** a
> bare `timeout` command is NOT a safe assumption even on a dev machine — an
> agent-harness shell can define it as a builtin that silently doesn't exist
> in any subprocess, and stock macOS ships neither `timeout` nor `gtimeout`
> at all (GNU coreutils only). `smart-name.sh` already got this right with a
> three-tier fallback (`timeout` → `gtimeout` → a `perl -e 'alarm ...'`
> emulation); check `command -v` for all three before relying on any of them
> in a NEW script, don't assume the first one you tried works everywhere.

**Bring your own agent CLI.** `spawn-agent.sh`/`spawn-task.sh` don't hardcode
one binary — `HERDR_DEFAULT_AGENT` in `config.sh` picks the default
(`omp` as of 2026-08-16), and `lib/agent-profiles.sh` is the ONE place that
knows how to launch a recognized agent (`cli_for_agent`) and which model a
job-class maps to for it (`model_for_agent`). `claude` and `codex` are MODEL
FAMILIES, not CLI binaries, today: both route through the omp harness with
`--models` set so Ctrl+P can swap the live pane between them — nothing
spawned from this toolchain launches a bare `claude`/`codex` process by
default anymore. `omc` is the one exception (it IS its own harness — Claude
Code plus OMC's hook/skill system — not a bare CLI to wrap). Anything else
already works as a **literal command**, just without job-class model
routing — `spawn-task.sh ~/app fix-bug quick "my-other-tool --flag"` runs
`my-other-tool --flag` verbatim in the new tab/worktree. To give a new agent
the same `plan`/`implement`/`explore` → model mapping the built-in ones get,
add it to `lib/agent-profiles.sh` — nowhere else needs to change; every
script that launches an agent goes through that one file.

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
./spawn-task.sh ~/src/app fix-worker implement          # claude sonnet
./spawn-task.sh ~/src/app arch review codex            # codex, deep model
./spawn-task.sh ~/src/app fix-parser implement omp     # omp, sonnet (verified 2026-07-31)
./spawn-task.sh ~/src/app fix-worker implement --dry-run # preview, no changes

# Spread: multi-pane tab from a declarative layout (case by case, opt-in)
./spread-tab.sh ~/src/app dev                    # auto-picks a layout, see below
./spread-tab.sh --layout example-dev ~/src/app dev --dry-run  # preview the plan

# Open: a WHOLE project workspace by name — every tab, every pane (Projects)
./open-project.sh your-project                   # headless, by name
./open-project.sh --pick                          # fuzzy-pick (needs fzf)

# Act: a fuzzy one-off command launcher, run where you launched it (Quick Actions)
./quick-action.sh --pick                          # fuzzy-pick (needs fzf)
./quick-action.sh "Verify Suite"                  # by name, headless

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

# Wait: block (in the background) until any/some agent needs input, then report
./wait-for-blocked.sh                             # poll every 15s, up to 60min, any pane
./wait-for-blocked.sh 10 30 w1:p2 w2:p1            # 10s/30 polls, only these two panes
```

### Multi-pane layouts, case by case (`spread-tab.sh`)

`spawn-agent.sh`/`spawn-task.sh` only ever build ONE pane per tab — enough for
an agent session, not for "editor + dev server + log tail" in one glance.
`spread-tab.sh` builds a whole tab from a small JSON layout file instead,
chaining real `herdr pane split` calls (never guessed ids, same discipline as
every other script here) off the pane before it.

Nothing is forced globally — a project opts in by dropping ONE file, cheapest
override wins:

1. `spread-tab.sh --layout foo ...` → `layouts/foo.json`
2. `layouts/<project-dir-name>.json`, auto-picked by the repo's own name
3. `layouts/default.json` — a single plain pane, today's status quo, so every
   project with no layout of its own behaves exactly as before

```json
[
  { "cmd": "claude", "focus": true },
  { "split": "down", "ratio": 0.3, "cmd": "npm run dev" }
]
```

Only `layouts/default.json` and `layouts/example-dev.json` ship here — the 3
repo-specific layouts from this feature's first cut turned out to want a
WHOLE workspace-open, not a tab added to one already open, so they moved to
`projects/*.json` — see
[Projects](#projects-a-whole-workspace-by-name-open-projectsh) below, which
is where you'll actually find them now.

| layout | what it's for |
|---|---|
| `layouts/default.json` | a single plain pane — today's status quo, what any project with no override gets |
| `layouts/example-dev.json` | generic editor + `git log --graph` pane, the schema-reference example |

Fields: `cmd` (omit for a plain shell), `cwd` (relative to the layout's own
root unless it starts with `/` or `~`), `env` (`{"K":"V"}`, forwarded straight
to herdr's own `--env` — no shell string of our own to quote-escape), `split`
(`right`|`down`, ignored on the first pane), `ratio`, `focus` (bool; at most
one pane should set it). Unknown keys are a hard error, not a silently
ignored typo. Full schema doc lives in `lib/layout.sh`'s header.

**No `wait_for`/output-pattern step, on purpose.** `spawn-task.sh`'s own
coordination-scaffold comment already found that `herdr wait output --match`
false-fires on a command's own kick-off echo quoting the marker — that's why
task completion is signalled through `.omc/handoffs/events.jsonl` +
`wake-on-evidence.sh` instead. A layout pane that genuinely needs to wait on
another pane should use that same events-file pattern; the layout engine
stays a pure "build the panes" primitive and never reintroduces a bug already
found and designed around once.

`verify-layout.sh` is the stub-herdr suite for this (argument composition,
response-id threading, cwd/env/focus resolution, failure propagation, and
`spread-tab.sh`'s layout-resolution order) — same technique as
`verify-select-policy.sh`.

### Projects: a whole workspace by name (`open-project.sh`)

`spread-tab.sh` adds ONE tab to a workspace you already have (or are
creating). `open-project.sh` is the bigger hammer: open (create-or-reuse) a
whole workspace and build EVERY tab a project declares, by name, headlessly
or via an `fzf` browser (`--pick`).

```json
{
  "name": "example-sentinel",
  "description": "PATTERN: agent pane + an ambient git-status sentinel",
  "working_dir": "~/Code/your-project",
  "tabs": [
    { "label": "work", "panes": [ {"cmd": "claude", "focus": true}, ... ] }
  ]
}
```

`tabs[].panes` is exactly a `spread-tab.sh` layout — same fields, same
`layout_validate`/`layout_apply` underneath (`lib/layout.sh`, unchanged); a
project only adds the envelope (`name`/`description`/`working_dir`) and a
list of tabs, opening one tab per entry via `lib/project.sh`'s `project_open`.

Two tiers, shown together, resolved by name — see
[Private vs. public](#private-vs-public) below for the full convention:

1. **personal** — `${XDG_CONFIG_HOME:-~/.config}/herdr-control/projects/*.json`.
   YOUR real projects, real paths, real descriptions. Not tracked by this
   repo. Wins on a name collision with a shipped example.
2. **example** — `projects/*.json` in this repo, tracked. GENERIC patterns
   (`example-sentinel.json`: agent + an always-visible sentinel;
   `example-ci-gate.json`: agent + a one-shot check on open; `herdr-control.json`:
   this repo dogfooding itself) with placeholder `working_dir`s
   (`~/Code/your-project`) — copy one into your personal tier and edit it,
   don't run it verbatim.

**Known gap vs. what inspired this** (see Credits): a fresh workspace's own
auto-created root tab is left empty rather than reused by the project's first
tab — closing that would mean `ensure-workspace.sh` handing back the pane id
it just created, which its create-or-reuse contract doesn't do today. Documented
in `lib/project.sh`'s header rather than silently glossed over. Opening an
*existing* (reused) workspace has no such artifact.

`verify-projects.sh` covers `project_validate`/`project_open` (one workspace
create regardless of tab count, focus on tab 0 only, `~`-expansion, mid-loop
failure propagation) plus `open-project.sh`'s dry-run/unknown-name/`--pick`/
two-tier-resolution behaviour (personal discovered, tagged, and winning a
name collision — not asserted, actually exercised against an isolated XDG
config dir so the suite never depends on this machine's real personal
projects) — same stub-herdr technique as `verify-layout.sh`, with
`ensure-workspace.sh` exercised for real, not reimplemented.

### Quick Actions: a fuzzy one-off launcher (`quick-action.sh`)

Not everything belongs in an always-open pane — `bash scripts/ci.sh` or "run
the verify suite" is a one-shot check, not something worth a permanently
running split. `quick-action.sh` fuzzy-picks (or headlessly runs, by name) a
one-off command in the directory you launched it from. Unlike everything else
in this repo, it never touches the herdr socket — it works even while herdr's
control socket is down or version-mismatched.

Actions are JSON files in two tiers, shown together — global
(`${XDG_CONFIG_HOME:-~/.config}/herdr-control/quick-actions/*.json`, tagged
`(global)`) and repo-local (`<cwd>/.herdr-control/quick-actions/*.json`,
tagged `(project)` or `(project, UNTRUSTED)` — see Trust gate below); on a
name collision the repo-local one wins, a deliberate override of a
same-named global action. See [Private vs. public](#private-vs-public)
below for why this repo's own tracked example —
`.herdr-control/quick-actions/verify-suite.json`, dogfooded here — stays
generic (it verifies THIS repo, nothing private).

**Trust gate.** A repo-local action is shell code that arrives with
whatever repo you clone or `cd` into — not something you personally
authored, unlike your global actions. It refuses to run until you
explicitly approve it, by content hash:

```bash
./quick-action.sh --trust "Build"      # prints the exact command, asks y/N
./quick-action.sh "Build"              # now runs
```

Approval is recorded in `$XDG_STATE_HOME/herdr-control/trusted-actions`,
keyed by (path, sha256 of the file's content) — editing an already-trusted
action's command re-requires approval, same as changing what you approved.
Global actions need no trust step: you wrote them yourself. This is why a
fresh clone of this repo can't run its own dogfooded `Verify Suite` action
immediately — `--trust` it once, same as anyone else's repo.

```json
{"name": "Verify Suite", "command": "for v in verify-*.sh; do ...; done"}
{"name": "Open Repo", "type": "select", "command": "open https://github.com/tntpgh/$HERDR_CONTROL_VALUE",
 "options": [{"label": "herdr-control", "value": "herdr-control"}]}
{"name": "Search Google", "type": "form", "form": {"prompt": "Search for"},
 "command": "open \"https://www.google.com/search?q=$HERDR_CONTROL_VALUE\""}
```

`type` defaults to `command`. `select`/`form` expose the chosen/typed text as
`$HERDR_CONTROL_VALUE` (plus `$HERDR_CONTROL_WORKDIR`, the launch directory);
a command that never references it gets the value appended as a final
shell-quoted argument instead — so a bare `open https://google.com/search?q=`
style command still works without editing it.

`verify-quick-actions.sh` (37 checks) covers discovery (global+repo-local
merge, correct scope tags including `UNTRUSTED`), local-wins-a-collision
precedence, the full trust-gate lifecycle (refuse untrusted → `--trust`
prompt requires a literal `YES` → runs → editing revokes trust →
re-trusting restores it), unknown-name/unknown-type/no-options errors, both
substitution paths (referenced vs. appended), a `$(...)`/backtick/`;`
injection canary proving a form value is expanded exactly once and stays
inert, and `$HERDR_CONTROL_WORKDIR` — every `fzf` call under
`FZF_DEFAULT_OPTS=--filter=...` so the suite runs headless and exits
instead of blocking on a TTY that isn't there.

### Private vs. public

The general rule, applied twice (Projects, Quick Actions) and worth naming
once instead of repeating per-feature: **anything that names a REAL private
repo, path, or workflow lives in your own machine-local config, never in
this tracked repo. Anything tracked here is a PATTERN — generic, portable,
meant to be copied and edited, not run verbatim.**

| | your real usage (private) | what ships here (public) |
|---|---|---|
| **Projects** | `${XDG_CONFIG_HOME:-~/.config}/herdr-control/projects/*.json` — real `working_dir`s, real descriptions of your actual repos | `projects/*.json` — `example-*.json` files, placeholder `working_dir: ~/Code/your-project`, description says "PATTERN:" up front |
| **Quick Actions** | `${XDG_CONFIG_HOME:-~/.config}/herdr-control/quick-actions/*.json` — your own cross-project shortcuts | `.herdr-control/quick-actions/*.json` — THIS repo's own actions (`verify-suite.json`), inherently public since they're about the tool itself |

This wasn't the design from the start — the first cut of Projects shipped
two of the author's real private-repo templates straight into
`projects/*.json`, with real paths and one-line descriptions of the actual
repos. Not a secret (no credentials, no internal URLs), but non-portable and
more than a public tool repo should say about someone's other private work.
Fixed by
moving the real files to the personal tier unchanged and replacing the
shipped copies with `example-sentinel.json` / `example-ci-gate.json` —
same USEFUL patterns (ambient sentinel pane; one-shot check-on-open), same
quality, zero private content. Quick Actions never had this problem: its
repo-local tier is inherently about the repo it lives in, so dogfooding
`verify-suite.json` here was never a privacy question, only a "does this
belong to everyone who clones this repo" one — and it does.

**The security review this doesn't replace.** This split keeps *business
context* (which repos you have, what they do) out of the tracked repo. It
is not a secret-scanning policy — that's the shared pre-commit hook
(content-based, scans every staged diff regardless of which file it's in)
plus periodically re-running a real history sweep (`git log --all -p`
against AWS/GitHub/OpenAI/Slack token shapes and PEM headers) before
treating a private repo as public-ready. Do both; they catch different
things.

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
command = "bash /path/to/herdr-control/sort-tabs.sh --all"
```

### As a herdr plugin, instead of manual keybindings (`herdr-plugin.toml`)

The section above binds one key to one script by hand, in **your** herdr
`config.toml`. `herdr-plugin.toml` at this repo's root is the same five
socket-only tools (`open-project.sh`, `quick-action.sh`, `sort-tabs.sh`,
`smart-name.sh`, `attention.sh --focus`) registered as real herdr plugin
actions instead — install once, get keybinding-ready ids and a
`herdr plugin log list` audit trail for free. The two `--pick` tools go
through an extra hop (`pick-pane-open.sh`, below) that the other three
don't need:

```bash
herdr plugin link .                        # local dev, from this repo
# or: herdr plugin install tntpgh/herdr-control
herdr plugin action list --plugin tntpgh.herdr-control
herdr plugin action invoke tntpgh.herdr-control.projects
```

```toml
[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "tntpgh.herdr-control.projects"
```

**This repo has three tiers, not two — traced by grepping who sources what
and who touches which env vars, not asserted from memory:**

- **Shared Foundation** — pure herdr-socket primitives with NO opinion about
  where they're called from: `lib/pane-guard.sh` (is this pane a live agent,
  has it been recycled), `lib/pane-name.sh`, `lib/prompt-parse.sh`,
  `lib/agent-profiles.sh` (agent launch flags — knows nothing about hooks),
  `lib/repo-root.sh`, `ensure-workspace.sh`, `lib/layout.sh`, `lib/project.sh`.
  Consumed by entry points in BOTH tiers below — `ensure-workspace.sh`
  alone is called by `spawn-agent.sh`/`spawn-task.sh` (Outside-Herdr) AND
  `lib/project.sh`/`spread-tab.sh` (Herdr-Plugin). No tier owns these; they
  answer questions ("is this a real agent pane," "which workspace does this
  repo belong to") that are true regardless of who's asking.
- **Herdr-Plugin Layer** — entry points that talk ONLY to herdr's own
  socket: `open-project.sh`, `quick-action.sh`, `sort-tabs.sh`,
  `smart-name.sh`, `attention.sh`, `mark-tab.sh`, `pick-pane-open.sh`.
  Exactly what `herdr-plugin.toml` registers (as both `[[actions]]` and
  `[[panes]]`).
- **Outside-Herdr Layer** — entry points that react to an AGENT CLI's own
  hook/extension system, which herdr's plugin manifest has no way to see:
  `spawn-agent.sh`/`spawn-task.sh`, every `agent-hooks/*`, `herdr-select.sh`,
  `herdr-deliver.sh`, `herdr-resolve.sh`, `send-to-agent.sh`,
  `wait-for-blocked.sh`, the Slack bridge — plus the libs ONLY they touch:
  `lib/run-registry.sh`, `lib/push-wake.sh`, `lib/reconcile.sh`,
  `lib/posture.sh`, `lib/command-policy.sh` (confirmed by grep: these three
  are the only files anywhere in the repo that reference
  `HERDR_TASK_LABEL`/`HERDR_RUN_ID`/`HERDR_CONDUCTOR`/`registry_db`/
  `hookSpecificOutput`). Wired through `~/.claude/settings.json` hooks and
  the omp extension module, exactly as `install.sh` sets them up today.

**No function call ever crosses between the two entry-point tiers.** The
ONLY channel is herdr's own PERSISTED pane metadata —
`agent_status`/tokens, set via `herdr pane report-agent`/`report-metadata`
— and both tiers write to it AND read from it (traced by grep, not
assumed): `spawn-agent.sh`/`spawn-task.sh` (Outside-Herdr) stamp
`--state working` at launch; `attention.sh`/`smart-name.sh`/`mark-tab.sh`
(Herdr-Plugin) update it from live pane observation; `wait-for-blocked.sh`
(Outside-Herdr) and `sort-tabs.sh`/`herdr-deliver.sh` both read it back.
herdr itself is the shared bulletin board — which is exactly WHY the
Outside-Herdr Layer can't become a herdr plugin: its actual INPUT (the
Notification/tool_call hook firing) never becomes a herdr socket call at
all, only the derived FACT (`agent_status: working`) does, after the
Outside-Herdr code has already reacted to it.

`install.sh`'s Claude/omp wiring stays the install path for the
Outside-Herdr Layer; `herdr-plugin.toml` is an ADDITIONAL, optional path
for the Herdr-Plugin Layer only, not a replacement for `install.sh`. When
you're deciding where a new idea belongs, this is the test: does it need to
know something only the agent CLI's own hook/extension system can tell it
(Outside-Herdr), does it only ever read/write herdr's own workspace-tab-pane
state (Herdr-Plugin), or is it a primitive answer either tier could need
(Shared Foundation)?

**No `[[build]]` step, on purpose too.** Every action here is already-shipped
bash — `command` arrays skip the shell entirely (herdr's own docs: no
expansion "unless your command starts a shell itself"), so `["bash",
"sort-tabs.sh"]` is the complete, correct invocation with nothing to
compile. herdr-plus needs a `[[build]]` step and a prebuilt-binary fallback
because it ships a Go binary; a plugin that's already a finished bash
script has no equivalent problem to solve.

**Actions get no TTY; `--pick` needs one, so it hops through a pane.**
Herdr runs an action's `command` on the server, headless — fine for
`sort-tabs.sh`/`smart-name.sh`/`attention.sh --focus`, which never prompt,
but fatal for `open-project.sh --pick`/`quick-action.sh --pick`, which run
`fzf`. Both actions instead invoke `pick-pane-open.sh <entrypoint-id>`,
which opens the matching `[[panes]]` entry (`projects-pick`/
`quick-actions-pick`) — panes DO get a real terminal — and forwards the
triggering pane/workspace's cwd via `--cwd` (pattern and the underlying
`--cwd`-sets-real-process-cwd behavior confirmed against the installed
`jt.command-palette` plugin's `open.sh`/`herdr-plugin.toml`, not asserted).
That `--cwd` forward is why `quick-action.sh` can rely on a bare `$PWD` for
its repo-local tier with no herdr-specific override variable: by the time
it runs inside the pane, `$PWD` already IS the repo the user triggered the
action from. `open-project.sh` has no cwd-dependent tier, so for it this is
about consistency and correctness, not a bug fix.
`verify-pick-pane-open.sh` (19 checks) proves the dispatcher's argv against
a stubbed `herdr` binary — entrypoint routing, `--cwd` forwarded from
`focused_pane_cwd`/`workspace_cwd`/`$HERDR_WORKSPACE_CWD` in that order,
and silently dropped (not forwarded) when the resolved path doesn't exist
or the context JSON is malformed.

**Not yet live-verified.** This machine's herdr CLI (protocol 19) is newer
than its running server (protocol 17), so every live socket call — including
`herdr plugin link`/`install` and an actual `herdr plugin pane open` —
currently fails with `protocol_mismatch`. The manifest is written and
cross-checked against herdr's published plugin docs (manifest shape,
`command`/`[[panes]]` argv semantics, plugin-root-as-cwd) and a real
installed plugin using the identical action→pane dispatch pattern
(`jt.command-palette`), not against a real install of THIS plugin.
`pick-pane-open.sh`'s own herdr invocation is proven correct in isolation
(`verify-pick-pane-open.sh`, above); what remains unverified is herdr
actually accepting that invocation and opening the pane. Restart the herdr
server, then `herdr plugin link .` from this repo to prove that part too.

A promising extension **not yet built**: herdr plugins get a `[[startup]]`
hook that fires once when herdr's own server (re)starts — independent of
whether ANY Claude/omp session is open, unlike `SessionStart`/
`before_agent_start` today. That could give reconciliation a trigger that
doesn't need a conductor session to exist at all, closing the exact gap
"Wake persistence across conductor sessions" below describes. Not wired up:
`lib/reconcile.sh`'s `run_reconciliation` currently shapes its own output
for a Claude-hook JSON envelope specifically; a startup hook needs it to
support a plain-log output mode first, and that's real work, not a manifest
edit.

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

**`wait-for-blocked.sh` — the same signal, shaped for a background job
instead of a sidebar.** `attention.sh` is something YOU run to check the
room; `wait-for-blocked.sh` is something a conductor session backgrounds
(`run_in_background`) and gets woken by — it polls `herdr pane list` for
`agent_status: blocked`, and once it finds one (any pane, or only the ones
you name — pass pane ids to watch just "your" workers) it prints the pane,
its workspace, and the last 12 lines of the actual prompt, then exits 0. No
hit within the poll budget exits 3, so a caller can tell "found one" from
"gave up" without parsing output. This is the poll half of "push +
reconciliation" for a session with no push hook wired (a hand-started
session, or before `install.sh` has run) — see "Wake persistence across
conductor sessions" above for the push half.


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
- **A friendly name (`lib/pane-name.sh`'s `pane_display_name`, used by
  `herdr-notify.sh` and `attention.sh`) silently falls back to the raw pane
  id (`w1:p2`) whenever `herdr pane list`/`workspace list`/`tab list` fail —
  on purpose ("an alert with an ugly name beats no alert"), not a naming
  bug. Confirmed live 2026-08-05: this machine's `herdr` CLI (protocol 19)
  running against a stale server (protocol 17) makes EVERY socket call fail,
  so every friendly name in every notification degrades to a raw id right
  now, machine-wide — restarting the herdr server is the fix, not new code.
  If a name looks ugly and you don't know why, check `herdr pane list`'s
  own exit code before suspecting `pane_display_name`.

## Files

| file | role |
|------|------|
| `config.sh` | **your config** — the only file to edit |
| `herdr-plugin.toml` | registers the herdr-socket-only tools (Projects, Quick Actions, sort/name/attention) as real herdr plugin actions, `--pick` tools via a pane — not yet live-verified, see its own header |
| `pick-pane-open.sh` | dispatches an `[[actions]]` `--pick` invocation to its matching `[[panes]]` entry (herdr actions get no TTY; panes do) |
| `ensure-workspace.sh` | focus-or-create a project's workspace |
| `spawn-agent.sh` | new tab in a project's workspace, run an agent |
| `spawn-task.sh` | worktree as a sub-tab, launched at the job-class's model |
| `spread-tab.sh` | multi-pane tab from a declarative layout, case by case |
| `lib/layout.sh` | layout engine `spread-tab.sh` drives (pane split/create + real-id threading) |
| `open-project.sh` | open a WHOLE project workspace by name — every tab, every pane |
| `lib/project.sh` | multi-tab engine `open-project.sh` drives, looping `lib/layout.sh` once per tab |
| `projects/*.json` | project templates (`working_dir` + tabs), one file per project |
| `quick-action.sh` | fuzzy one-off command launcher, global + repo-local, no herdr socket needed |
| `sort-tabs.sh` | reorder tabs by branch state |
| `mark-tab.sh` | set a tab's status/colour + badge |
| `smart-name.sh` | rename tabs after the task their dominant pane is doing |
| `attention.sh` | honest per-agent waiting-reason + `--focus` next-action view |
| `wait-for-blocked.sh` | blocks (for a background job) until any/some agent pane needs input, then reports it — `shift 2`'s all-or-nothing bash semantics used to break the single-argument form (`wait-for-blocked.sh 30`), see `verify-wait-for-blocked.sh` |
| `herdr-deliver.sh` | deliver+submit a message to an agent (or `--blocked`) |
| `send-to-agent.sh` | robust type+submit into a pane (delivery primitive); `--submit-only` presses/confirms text ALREADY in the composer (e.g. an operator typed directly and the Enter didn't land) |
| `herdr-select.sh` | answer a prompt — numbered digit or omp's arrow menu — by pressing the right key(s); `--authority peer\|human` gates auto-answer through command policy |
| `herdr-resolve.sh` | retract Slack alerts whose prompt was answered elsewhere |
| `wake-on-evidence.sh` | poll a peer's `.omc/handoffs/events.jsonl` for a marker, then wake |
| `install.sh` | wire the hooks into Claude Code and the omp extension symlink (idempotent, dry-run by default) |
| `verify-run-registry.sh` | 42-check verification of the SQLite run registry — sequencing, dedup, transactions, migration from the old file layout |
| `verify-posture.sh` | 49-check verification of the posture ladder — composition, fail-closed unknowns, per-agent flag translation |
| `verify-command-policy.sh` | 56-check verification of the command-policy classifier — floor rules, normalization, operator rules, credential/production escalation, curl\|sh-class bypasses, obfuscation/backslash-escape/heredoc coverage |
| `verify-select-policy.sh` | 44-check verification of `herdr-select.sh --authority peer` against a stubbed herdr — runs the real script, not a reimplementation |
| `verify-omp-hooks.sh` | 41-check verification of the omp extension's four event handlers against a stubbed pane |
| `verify-layout.sh` | 40-check verification of `lib/layout.sh` + `spread-tab.sh` against a stubbed herdr — argument composition, id threading, cwd/env/focus/label resolution, `~`-expansion to `$HOME`, ratio type/range validation, failure propagation, layout-resolution order |
| `verify-projects.sh` | 27-check verification of `lib/project.sh` + `open-project.sh` against a stubbed herdr (`ensure-workspace.sh` exercised for real) — one workspace per project, one tab-create per project tab, focus on tab 0 only, `~`-expansion, mid-loop failure propagation |
| `verify-quick-actions.sh` | 37-check verification of `quick-action.sh` — global+repo-local discovery/scoping (including `UNTRUSTED`), local-wins-a-collision precedence, the full trust-gate lifecycle, unknown name/type/no-options errors, select/form value substitution + unreferenced-value append fallback, a command-injection canary — no herdr stub needed |
| `verify-pick-pane-open.sh` | 19-check verification of `pick-pane-open.sh` (the `--pick`-actions-need-a-TTY dispatcher) against a stubbed herdr — entrypoint routing, `--cwd` forwarding/fallback order, silently dropped on a nonexistent path or malformed context JSON |
| `verify-wait-for-blocked.sh` | 16-check verification of `wait-for-blocked.sh` against a stubbed herdr — argument-count regression coverage (0/1/2/3+ args), watch-list scoping, blocked/timeout reporting, missing-`herdr` exit code |
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

## Credits

Ideas taken from elsewhere, reimplemented natively in this repo's own
bash+python+jq stack (not installed as external dependencies) so
herdr-control stays one self-contained package under our own control:

- **[iurysza/herdr-tab-smart-rename](https://github.com/iurysza/herdr-tab-smart-rename)**
  — the idea behind `smart-name.sh` (rename a tab after the work its
  dominant pane is doing). This is a pure-bash, Claude-native take — no Bun,
  no plugin.
- **[caioniehues/herdmates](https://github.com/caioniehues/herdmates)** — the
  doctrine behind `attention.sh`: never show a wrong waiting-reason; degrade
  to a plain `waiting` rather than guess.
- **[yuk1ty/herdr-spreader](https://github.com/yuk1ty/herdr-spreader)** —
  evaluated as a declarative-YAML-layout tool for herdr; not adopted as a
  dependency (its `wait_for` output-matching reintroduces a false-fire bug
  `spawn-task.sh` already found and designed around), but confirmed the shape
  of `herdr`'s own `tab create`/`pane split` JSON responses against its
  working Rust implementation while building `lib/layout.sh`.
- **[cloudmanic/herdr-plus](https://github.com/cloudmanic/herdr-plus)** — the
  source of the Projects (open a whole declarative workspace by name,
  headlessly or via a fuzzy picker) and Quick Actions (a fuzzy one-off
  launcher, global + repo-local, command/select/form, unreferenced-value
  append fallback) ideas behind `open-project.sh`/`lib/project.sh` and
  `quick-action.sh`. Reimplemented in bash+jq+fzf instead of installed as a
  Go plugin — no Go toolchain dependency, and the whole feature set ships in
  this one repo instead of a separate plugin install/upgrade lifecycle.

## License

MIT — see [LICENSE](LICENSE).
