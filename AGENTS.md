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
command -v herdr jq python3 curl tmux
herdr status
```

All must exist and `herdr status` must show a running server. If herdr is not
installed or not running, stop: nothing else can work.

## Step 2 — configure

```bash
$EDITOR config.sh
```

`config.sh` is the only file with machine defaults (which agent to launch, PATH
for a minimal environment, sort preferences, Codex model tier names). Everything
else is generic. Leave the defaults unless the human asks otherwise.

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
