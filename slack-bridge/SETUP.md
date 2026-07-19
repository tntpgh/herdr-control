# Slack → herdr reply bridge — setup

Answer the orchestrator (or any worker) from Slack: reply in a channel and it
lands in the right herdr agent. Outbound pings already work (OMC/OMX walk
profile); this adds the inbound leg. The one part only you can do is creating the
Slack app (below) — everything else is built.

## 1. Create the Slack app (~5 min, one time)

1. Go to <https://api.slack.com/apps> → **Create New App** → **From scratch**.
   Name it e.g. `herdr-bridge`, pick your workspace.
2. **Socket Mode** (left nav) → toggle **Enable Socket Mode**. When prompted,
   generate an **app-level token** with the **`connections:write`** scope. Copy
   the `xapp-…` token → this is `SLACK_APP_TOKEN`.
3. **OAuth & Permissions** → **Bot Token Scopes**, add:
   `chat:write`, `channels:history`, `groups:history`, `im:history`,
   `mpim:history` (the `*:history` scopes let it read your replies).
4. **Event Subscriptions** → **Enable Events** → under **Subscribe to bot
   events** add: `message.channels`, `message.groups`, `message.im`,
   `message.mpim`. Save.
5. **Install App** (top of OAuth page) → **Install to Workspace** → authorize.
   Copy the **Bot User OAuth Token** (`xoxb-…`) → this is `SLACK_BOT_TOKEN`.
6. In Slack, invite the bot to the channel you'll use: `/invite @herdr-bridge`.
   (Or just DM the bot.)
7. Get your **member id**: your avatar → Profile → the `⋯` menu → **Copy member
   ID** (looks like `U0…`). That's your `HERDR_BRIDGE_ALLOW_USERS`.

## 2. Store the two tokens in 1Password (Secrets vault)

The op service account is read-only, so add these items yourself, in the
**Secrets** vault, field **credential**:

- `herdr-slack-bridge-bot`   → the `xoxb-…` token
- `herdr-slack-bridge-app`   → the `xapp-…` token

## 3. Configure

```bash
cp <this-dir>/herdr-bridge.env.example ~/.config/herdr-bridge.env
# edit ~/.config/herdr-bridge.env: set HERDR_BRIDGE_ALLOW_USERS to your U0… id
# (and optionally HERDR_BRIDGE_CHANNEL). The two op:// refs are already correct.
```

## 4. Run

```bash
bash <this-dir>/run-bridge.sh          # builds a venv on first run, then starts
```
Run it in a herdr pane (so it survives with the server), or under launchd for
always-on. On start it prints `herdr bridge up — allowlist=[…] …`.

## Use it

In the channel (or a DM to the bot):

- `yes, use option B` → delivered to the single **blocked** agent (what the orch
  is waiting on). If none or several are blocked, it tells you and asks for a
  pane id.
- `w8:p2 continue; skip the migration` → delivered to that specific pane/tab.

The bot reacts in-thread: `:white_check_mark: delivered to w8:p2` or a `:warning:`
with the reason. Pair it with `mark-tab.sh <pane> waiting` + your existing Slack
notify so a worker that needs you pings your phone, and you answer right there.

## Limits (v1)

- Delivers **text** to the agent's prompt. It does not drive an AskUserQuestion
  arrow-menu — if a worker is sitting on a multiple-choice menu, type the choice
  as text (the agent's "Other/free-form" path), or SSH in for that one.
- Fail-closed: no allowlist → refuses to start. Keep the app private to your
  workspace and don't add scopes beyond the above.
