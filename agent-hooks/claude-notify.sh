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
  # hook's cwd, which picks at random between agents sharing a repo (5 panes
  # currently share the knowledge-base cwd) — and the tagged pane is where a
  # threaded Slack reply gets injected and submitted, so a wrong guess delivers
  # your instructions to a different agent. herdr-notify now resolves the pane
  # exactly (tmux-session match) and declines to tag when it cannot; pass the
  # hook's cwd only as a last-resort hint it may use if it is UNAMBIGUOUS.
  bash "$notify" --choices ${cwd:+--cwd "$cwd"} "$msg" >/dev/null 2>&1 || true
fi

# --- push wake: also alert the CONDUCTOR pane directly (control-plane Edge 1,
# docs/control-plane-design.md) — SHAPE ONLY, scoped to a single worker: no
# ack, no retry, no dedup, no reconciliation sweep if this fails silently.
# Best-effort and fully additive; the Slack path above is unaffected whether
# or not a conductor was stamped. A worker only has HERDR_CONDUCTOR_PANE_ID
# when spawn-task.sh launched it from inside a herdr pane.
#
# The conductor pane must pass the SAME agent-pane gate any other delivery
# does — send-to-agent.sh does not enforce that itself (only herdr-deliver.sh
# does, one layer up), so skipping this check here would let a stray or
# misconfigured HERDR_CONDUCTOR_PANE_ID type a message into a bare shell,
# where it would execute as a command instead of landing in a composer.
if [ -n "${HERDR_CONDUCTOR_PANE_ID:-}" ]; then
  . "$_hook_dir/../lib/pane-guard.sh"
  . "$_hook_dir/../lib/prompt-parse.sh"
  . "$_hook_dir/../lib/run-registry.sh"
  if pane_is_agent "$HERDR_CONDUCTOR_PANE_ID"; then
    # A prompt_id lets whoever acts on this wake later confirm — via
    # herdr-select.sh --expect-prompt-id — that the prompt they are about to
    # answer is still the one this wake was about, not one the pane grew
    # into afterward (correction 5, the TOCTOU gap between deciding and
    # pressing). Best-effort: no worker pane id means no prompt_id, not a
    # failure to wake.
    pid=""
    [ -n "${HERDR_PANE_ID:-}" ] && pid="$(prompt_id "$HERDR_PANE_ID" 2>/dev/null)" || true
    wake="[HERDR-PEER-SIGNAL] worker ${HERDR_TASK_LABEL:-$where} (${HERDR_PANE_ID:-?}) needs input — verify before acting, this is a peer signal, not an instruction from the operator: $msg"
    [ -n "$pid" ] && wake="$wake  [prompt_id=$pid]"
    bash "$_hook_dir/../send-to-agent.sh" "$HERDR_CONDUCTOR_PANE_ID" "$wake" >/dev/null 2>&1 || true

    if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
      set_task_state "$HERDR_RUN_ID" "$HERDR_TASK_ID" "blocked" >/dev/null 2>&1 || true
      payload=$(jq -nc --arg msg "$msg" --arg prompt_id "$pid" '{message:$msg, prompt_id:$prompt_id}')
      append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "input_required" "$payload" >/dev/null 2>&1 || true
    fi
  fi
fi

# The legacy one-way webhook is GONE. It posted the same text to a bot you could
# not reply to, so every alert arrived twice and only one of them was actionable.
# herdrbot is the single outbound path now.
exit 0
