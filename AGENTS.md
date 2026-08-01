# AGENTS.md — activating herdr-control

Instructions for an agent (Claude Code, Codex, …) asked to set this up. Written
to be followed top to bottom. Verify each step before moving on; several
failures here are **silent**, and the whole point of this tooling is alerts you
can trust.

Human-facing docs: `README.md` (what it is), `SKILL.md` (what it does and why it
refuses things), `slack-bridge/SETUP.md` (the Slack app).

---

## Rules for this setup

1. **Never overwrite `~/.claude/settings.json`.** It is personal and often holds
   secrets and unrelated config. Use `./install.sh --apply`, which merges only
   its own entries and backs up first. If you must hand-edit, merge — do not
   replace.
2. **Never commit a credential.** Tokens belong in `~/.config/herdr-bridge.env`
   (gitignored, mode 600), which should *reference* a secret manager rather than
   contain literals. `settings.example.json` and `herdr-bridge.env.example` are
   the only files that may show config shape, and they contain placeholders only.
3. **Stop and ask the human** for anything needing a browser or a credential:
   creating the Slack app, generating tokens, enabling Interactivity. You cannot
   do these, and guessing wastes a round trip.
4. **Do not enable the send path until the read path works.** Confirm alerts
   arrive before confirming replies land.

---

## Step 1 — prerequisites

```bash
command -v herdr jq python3 curl tmux sqlite3
herdr status
```

All must exist and `herdr status` must show a running server. `sqlite3` backs
the run registry (`lib/run-registry.sh`) that `spawn-task.sh` and
`herdr-select.sh` depend on — it ships with macOS by default, so this check
rarely fails there, but confirm it explicitly rather than discovering it
mid-run. If herdr is not installed or not running, stop: nothing else can
work.

## Step 2 — configure

```bash
$EDITOR config.sh
```

`config.sh` is the only file with machine defaults (which agent to launch, PATH
for a minimal environment, sort preferences, Codex model tier names). Everything
else is generic. Leave the defaults unless the human asks otherwise.

Two defaults worth knowing about, not changing: `HERDR_POSTURE_FLOOR` (the
loosest approval posture any worker may be spawned at — default `write`;
`lib/posture.sh`) and `HERDR_POLICY_EXTRA_RULES` (site rules for the
command-policy classifier — `lib/command-policy.sh`). Both can only make
things *stricter* than their default, never looser, so there is no failure
mode from leaving them alone.

## Step 3 — wire the hooks

```bash
./install.sh            # dry run — shows what it would change, writes nothing
./install.sh --apply
```

Expected on a fresh machine: three `+` lines (Notification, PostToolUse, Stop).
Expected on a machine already wired: three `=` lines and "nothing to do" — it
matches on aliases, so an existing hook under a different filename is detected
rather than duplicated. **Duplicate hooks double every alert**, so if you see a
`+` for a job that is already wired, investigate before applying.

Verify:

```bash
python3 -c "import json;d=json.load(open('$HOME/.claude/settings.json'));print(list(d['hooks']))"
```

The JSON must still parse. If it does not, restore the `.bak-herdr-*` backup
`install.sh` wrote.

### omp extension (skip if you don't use omp)

The same `./install.sh --apply` above also symlinks `agent-hooks/omp-herdr-control.ts`
into `~/.omp/agent/extensions/herdr-control.ts` (or `$PI_CODING_AGENT_DIR/extensions`
when set) — no separate command to run. It gives an omp session the same four jobs
the Claude hooks above give a Claude session (push-wake, session reconciliation,
mid-session reconciliation, alert retraction), through omp's own extension events
instead of `settings.json`.

Verify the symlink exists and resolves into THIS checkout:

```bash
readlink -f ~/.omp/agent/extensions/herdr-control.ts
```

The output must be `$here/agent-hooks/omp-herdr-control.ts` — `$here` being the
path this checkout lives at (`install.sh`'s own output names it too: `= omp
extension already wired -> ...` on a re-run, or `+ omp extension ... -> ...` on a
fresh install). `! omp extension refusing to overwrite non-symlink file` means a
real file already occupies that path and install.sh left it alone — investigate
before removing anything by hand.

A push wake still only reaches a worker `spawn-task.sh` launched: it needs
`HERDR_PANE_ID` stamped into the worker's environment, and a hand-started omp
session has none, so it stays reconciliation-only — the same limitation a
hand-started Claude session already has.

If the operator does not use omp, skip this entirely: nothing else in this
runbook depends on it, and it does not affect the Claude hook wiring above.

## Step 4 — Slack app (needs the human)

Ask them to follow `slack-bridge/SETUP.md`: create a Socket-Mode app, install it
to the workspace, and provide the **bot** token (`xoxb-…`) and **app-level**
token (`xapp-…`).

Then:

```bash
cp slack-bridge/herdr-bridge.env.example ~/.config/herdr-bridge.env
$EDITOR ~/.config/herdr-bridge.env
chmod 600 ~/.config/herdr-bridge.env
```

Fill in:

| variable | how to get it | why it matters |
|---|---|---|
| `SLACK_BOT_TOKEN` | Slack app → OAuth | posts the alerts |
| `SLACK_APP_TOKEN` | Slack app → Basic Information | Socket Mode connection |
| `HERDR_BRIDGE_ALLOW_USERS` | Slack profile → Copy member ID | **the only authentication** |
| `HERDR_BRIDGE_TEAM` | see below | member ids are unique per *workspace*, not globally |
| `HERDR_BRIDGE_CHANNEL` | optional | pin to one channel; otherwise DMs + any channel the bot is in |

```bash
curl -s -X POST -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  https://slack.com/api/auth.test | jq -r .team_id
```

Set `HERDR_BRIDGE_TEAM` from that. Without it, a user carrying the same member
id in another workspace — reachable through a Slack Connect channel — passes the
allowlist. The daemon warns at startup while it is unset.

## Step 5 — start the bridge

```bash
./slack-bridge/run-bridge.sh          # foreground, for the first run
./install.sh --apply --bridge         # or install it under launchd (macOS)
```

Confirm the startup banner names your workspace:

```
herdr bridge up — allowlist=['U…'] team=T… channel=any deliver=…
```

`team=ANY (unbound)` means `HERDR_BRIDGE_TEAM` did not load — go back to step 4.

## Step 6 — sandbox, if your agent runs sandboxed

Pane resolution needs the herdr socket and the **tmux** socket. Without tmux,
alerts still send but cannot work out which pane asked, so replies have nowhere
to go — and it fails *silently*. See the `_sandbox_note` in
`settings.example.json`.

## Step 7 — verify, in this order

**Read path.** From a pane running an agent:

```bash
./slack-bridge/herdr-notify.sh --dry-run --choices "test alert"
```

`pane=<id>` must be the pane you ran it in. `pane=none` means resolution failed
— check the tmux socket (step 6). Then send one for real (drop `--dry-run`) and
confirm it arrives in Slack.

**Write path.** Reply to that alert in the thread with a number. Because no
prompt is on screen, the correct result is a refusal:

> ⚠️ herdr-select: refusing to press a key into a pane that did not ask a question.

That is a **pass**, not a failure: it proves routing, the allowlist, the
workspace check and the guard all work, without touching a live agent.

**Retraction.** After a real prompt is answered in the terminal, the alert
should disappear from Slack within a tool call or two.

## Step 8 — report honestly

Tell the human which of these you actually observed versus inferred. In
particular, an alert firing on a **live numbered prompt** can only be verified
when a real prompt occurs — if you have not seen one, say so rather than
implying the flow is fully proven.

Same standard for omp and for peer-authority answering: verifying the extension
symlink resolves is not the same as watching a real `omp` approval menu get
answered, and verifying `herdr-select.sh --authority peer` refuses a
not-yet-prompting pane (Step 7's write-path check) is not the same as watching
it correctly REFUSE a live prompt whose command classifies as `escalate` or
`deny`. Report exactly which of these you watched happen versus which you are
inferring from reading the code.

## Step 9 — optional: tab naming + attention

These two need no hook wiring — they are standalone scripts, plus optional
herdr keybindings. Independent of the Slack path above.

```bash
./smart-name.sh --dry-run --all          # see proposed tab names; renames nothing
./attention.sh  --dry-run --focus        # classify agents + the "what next" view
```

`smart-name.sh` needs the `claude` CLI on `PATH` for the model path (set
`SMART_NAME_AI=0` to skip it and use deterministic names only). Verify isolation
did its job: a proposed label must describe the **target** pane's work, not the
repo this script was run from — if a tab is named after *your* current task, the
model context leaked and the isolation flags in `ai_name()` need checking.

To render the `$task`/`$status` sidebar cards and bind the keys, merge
`docs/herdr-config-snippet.toml` into `~/.config/herdr/config.toml`, replace
`__HERDR_CONTROL__`, then `herdr server reload-config`. **Invalid token names
fail silently** — reload reports `partial` and keeps the old layout; run
`herdr config check` and re-verify names if a row never appears.

---

## Troubleshooting

| symptom | cause |
|---|---|
| alert names a pane but replies do nothing | Interactivity not enabled (buttons only); use a threaded number |
| `pane=none` | tmux socket unreachable, or the agent runs outside a herdr pane |
| alert has no options, only the message | prompt not painted yet, or auto-approved before the hook read it; the context block should still show what is on screen |
| every alert arrives twice | two hooks wired for the same job — check `Notification` in settings.json |
| `team=ANY (unbound)` at startup | `HERDR_BRIDGE_TEAM` unset; the workspace check is inert |
| refusal on every reply | expected when no prompt is showing; only a live prompt accepts a choice |
| cannot write files under a `hooks/` directory | agent sandboxes commonly block writes to any path named `hooks/` (a writable `.git/hooks` is code execution on the next git command). This repo uses `agent-hooks/` for that reason — do not rename it back. If you hit this elsewhere, the write needs to happen outside the sandbox |
| omp session never alerts or pushes | check the extension symlink resolves (Step 3's omp subsection); a hand-started omp session (not via `spawn-task.sh`) has no `HERDR_PANE_ID` and is reconciliation-only by design |
| `herdr-select.sh` exits 8 | expected under `--authority peer` when the prompt's command classifies as `escalate`/`deny` — a human needs to answer it, not automation |
| `posture: unknown posture ... falling back to strict` on stderr | a typo in `HERDR_POSTURE_FLOOR` or a per-spawn posture request — fails closed on purpose, fix the name in `config.sh` |
