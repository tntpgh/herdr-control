#!/usr/bin/env bash
# Notification event -> herdrbot DM. Fires when Claude needs input / hits a
# permission prompt / goes idle.
#
# The old one-way webhook is gone, and with it the .omc-config.json lookup that
# gated this whole hook: keeping `[ -n "$url" ] || exit 0` after removing the
# only use of $url would have made every alert depend on a webhook nothing sends
# to — a config change would then kill notifications silently. herdr-notify owns
# its own credentials (the bridge env file), so there is nothing to read here.
set -uo pipefail

input="$(cat)"
msg="$(printf '%s' "$input" | jq -r '.message // .title // "Claude needs your attention"')"

# Only ping on actual permission prompts. Drop the idle "waiting for your input"
# nag — mobile push already covers that, and it fires for every idle session.
printf '%s' "$msg" | grep -qi 'permission' || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
where="${cwd##*/}"
[ -n "$where" ] && msg="$msg  ·  ${where}"

# --- 2-way: also alert through herdrbot (tagged with the pane so a threaded
# reply routes back). Runs ALONGSIDE the webhook for now. Best-effort. ---
# Find herdr-notify in whichever layout is installed. Checked in order:
#   1. $HERDR_NOTIFY            — explicit override, wins over everything
#   2. ../slack-bridge/...      — this repo, when the hook runs from the checkout
#   3. ~/.claude/skills/...     — an APM-deployed herdr-ops skill
# Resolving rather than hardcoding is what lets the same hook serve a plain
# clone and a packaged install without editing.
_hook_dir=$(cd "$(dirname "$0")" && pwd)
for notify in \
  "${HERDR_NOTIFY:-}" \
  "$_hook_dir/../slack-bridge/herdr-notify.sh" \
  "$HOME/.claude/skills/herdr-ops/scripts/slack-bridge/herdr-notify.sh"
do
  [ -n "$notify" ] && [ -f "$notify" ] && break
done
if [ -n "${notify:-}" ] && [ -f "$notify" ]; then
  # --choices: this fires on permission prompts, which is exactly when the agent
  # is showing a numbered list. Send the actual options so the alert can be
  # answered from Slack instead of only announcing that something is stuck.
  # Do NOT resolve the pane here. This used to take the FIRST pane matching the
  # hook's cwd, which picks at random between agents sharing a repo (5 panes
  # currently share the knowledge-base cwd) — and the tagged pane is where a
  # threaded Slack reply gets injected and submitted, so a wrong guess delivers
  # your instructions to a different agent. herdr-notify now resolves the pane
  # exactly (tmux-session match) and declines to tag when it cannot; pass the
  # hook's cwd only as a last-resort hint it may use if it is UNAMBIGUOUS.
  bash "$notify" --choices ${cwd:+--cwd "$cwd"} "$msg" >/dev/null 2>&1 || true
fi

# The legacy one-way webhook is GONE. It posted the same text to a bot you could
# not reply to, so every alert arrived twice and only one of them was actionable.
# herdrbot is the single outbound path now.
exit 0
