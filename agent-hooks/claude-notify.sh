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

# Decide what is worth a Slack ping.
#
# This used to be `grep -qi permission || exit 0` — pass ONLY messages containing
# the literal word "permission". That silently dropped every question-shaped
# notification ("Claude is waiting for your input", an AskUserQuestion prompt,
# anything the agent actually asked), which is the case you most want to answer
# from your phone. It went fully silent once sessions ran in auto /
# bypass-permissions mode: there, permission prompts stop being raised at all, so
# the one message shape that passed the gate stopped occurring — and the bridge
# looked dead while every part of it was healthy (process up for 7 days, tokens
# valid, hooks registered, outbound path posting fine).
#
# Inverted: drop the known-noisy idle nag, pass everything else. A false ping is
# cheap; a swallowed question stalls an agent until someone happens to look.
lower="$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]')"
case "$lower" in
  *permission*)                ;;          # permission prompt — always alert
  *"waiting for your input"*)  exit 0 ;;   # pure idle nag — mobile push covers it
  *"is idle"*)                 exit 0 ;;
  *)                           ;;          # questions, errors, anything else — alert
esac

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
  # hook's cwd, which picks at random between agents sharing a repo (several
  # panes can share one repo's cwd) — and the tagged pane is where a
  # threaded Slack reply gets injected and submitted, so a wrong guess delivers
  # your instructions to a different agent. herdr-notify now resolves the pane
  # exactly (tmux-session match) and declines to tag when it cannot; pass the
  # hook's cwd only as a last-resort hint it may use if it is UNAMBIGUOUS.
  bash "$notify" --choices ${cwd:+--cwd "$cwd"} "$msg" >/dev/null 2>&1 || true
fi

# --- push wake: also alert the CONDUCTOR pane directly (control-plane Edge 1,
# docs/control-plane-design.md).
#
# Every guard — the agent-pane gate, the conductor pane-birth revalidation that
# closes the recycled-pane misdelivery, the prompt_id capture, and the
# delivery-outcome recording that replaced the old fire-and-forget `|| true` —
# now lives in lib/push-wake.sh, shared with agent-hooks/omp-notify.sh. Two
# copies of a safety check is two places for it to rot, which is the same reason
# lib/agent-profiles.sh exists.
#
# Best-effort and fully additive: the Slack path above is unaffected whether or
# not a conductor was stamped. A worker only has HERDR_CONDUCTOR_PANE_ID when
# spawn-task.sh launched it from inside a herdr pane.
#
# stderr stays silenced here on purpose — a hook must not narrate into the
# session transcript. A failed wake is not lost by that: push_wake records
# `wake_result` with the real outcome in the registry, which is what the
# reconciliation sweep reports and what an operator can query later.
if [ -n "${HERDR_CONDUCTOR_PANE_ID:-}" ]; then
  . "$_hook_dir/../lib/pane-guard.sh"
  . "$_hook_dir/../lib/prompt-parse.sh"
  . "$_hook_dir/../lib/run-registry.sh"
  . "$_hook_dir/../lib/push-wake.sh"
  push_wake "$msg" "$where" >/dev/null 2>&1 || true
fi

# The legacy one-way webhook is GONE. It posted the same text to a bot you could
# not reply to, so every alert arrived twice and only one of them was actionable.
# herdrbot is the single outbound path now.
exit 0
