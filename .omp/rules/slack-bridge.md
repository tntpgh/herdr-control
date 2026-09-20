---
description: Creating the Slack Socket-Mode app, filling in herdr-bridge.env, and starting slack-bridge/run-bridge.sh.
globs: ["slack-bridge/**"]
---
# Slack Bridge Setup

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
# Same reason as slack-bridge/herdr-notify.sh's own comment — never put the
# bot token in argv, where any same-user process can read it via `ps`, or
# let it land in shell history: pipe it in via curl --config on stdin.
printf 'header = "Authorization: Bearer %s\n"' "$SLACK_BOT_TOKEN" \
  | curl -s -X POST --config - https://slack.com/api/auth.test | jq -r .team_id
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
</content>
<parameter name="i">Write slack-bridge.md rule file