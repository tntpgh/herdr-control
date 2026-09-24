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
_hook_dir=$(cd "$(dirname "$0")" && pwd)

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

# --- surface WHAT is being approved, not just THAT something needs approval.
# Notification's own payload has no tool_name/tool_input (see header) — read
# the cache claude-pretooluse-cache.sh's PreToolUse hook just wrote for this
# same session_id instead. Freshness-gated to ~10s: PreToolUse and a
# permission-triggered Notification fire back-to-back for the SAME call, so a
# fresh cache hit is that call; anything older is a stale leftover from a
# previous (possibly auto-approved) tool call and would mislabel an unrelated
# prompt — an idle nag or an AskUserQuestion — with the wrong command. Missing
# cache, missing jq, or a session with no prior tool call are all silent
# no-ops: this only ever adds detail, never blocks the base alert.
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
if [ -n "$session_id" ]; then
  cache_dir="${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}/last-tool"
  cache_file="$cache_dir/$session_id.json"
  if [ -f "$cache_file" ]; then
    cache_age=$(( $(date +%s) - $(jq -r '.ts // 0' "$cache_file" 2>/dev/null || echo 0) ))
    if [ "$cache_age" -ge 0 ] && [ "$cache_age" -le 10 ]; then
      . "$_hook_dir/../lib/tool-summary.sh"
      tool_name=$(jq -r '.tool // empty' "$cache_file" 2>/dev/null)
      tool_input=$(jq -c '.input // {}' "$cache_file" 2>/dev/null || printf '{}')
      if [ -n "$tool_name" ]; then
        summary="$(tool_summary_line "$tool_name" "$tool_input")"
        [ -n "$summary" ] && msg="$msg"$'\n'"\`${summary}\`"
      fi
    fi
  fi
fi

# --- 2-way: also alert through herdrbot (tagged with the pane so a threaded
# reply routes back). Runs ALONGSIDE the webhook for now. Best-effort. ---
# Find herdr-notify in whichever layout is installed. Checked in order:
#   1. $HERDR_NOTIFY            — explicit override, wins over everything
#   2. ../slack-bridge/...      — this repo, when the hook runs from the checkout
#   3. ~/.claude/skills/...     — an APM-deployed herdr-ops skill
# Resolving rather than hardcoding is what lets the same hook serve a plain
# clone and a packaged install without editing.
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
  # Gated the same way the conductor wake is (lib/alert-gate.sh, applied inside
  # push_wake): an allow-class, unreserved prompt is one an automated peer takes
  # in seconds, and paging for it is the noise that teaches its reader to ignore
  # the channel (2026-09-12). Held, never dropped. With no HERDR_PANE_ID there is
  # nothing to classify and the gate says "tell a person", so a hand-started
  # Claude session alerts exactly as it always did.
  . "$_hook_dir/../lib/prompt-parse.sh"
  . "$_hook_dir/../lib/run-registry.sh"   # append_event, for alert_grace_expired
  . "$_hook_dir/../lib/alert-gate.sh"
  if [ -z "${HERDR_PANE_ID:-}" ] || human_must_answer "${HERDR_PANE_ID}"; then
    bash "$notify" --choices ${cwd:+--cwd "$cwd"} "$msg" >/dev/null 2>&1 || true
  else
    grace_realert "${HERDR_PANE_ID}" "$(prompt_id "${HERDR_PANE_ID}" 2>/dev/null || printf '')" \
      "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" \
      bash "$notify" --choices ${cwd:+--cwd "$cwd"} "$msg"
  fi
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
# Claimed through the SAME attn_track_<key> the attention controller uses
# (lib/attention-key.sh) before calling push_wake at all — PR #132 review,
# item 6: a firing on a still-open prompt the controller (or an earlier
# firing) already owns must not call push_wake again (item 1's double-wake).
# HERDR_WAKE_LEGACY=1 is the rollback: every firing calls push_wake again,
# unclaimed. No HERDR_PANE_ID to build a key from is not a refusal — that
# population (a hand-started session outside spawn-task.sh) had no per-key
# dedupe before this either, so push_wake runs exactly as it always did.
if [ -n "${HERDR_CONDUCTOR_PANE_ID:-}" ]; then
  . "$_hook_dir/../lib/pane-guard.sh"
  . "$_hook_dir/../lib/prompt-parse.sh"
  . "$_hook_dir/../lib/run-registry.sh"
  . "$_hook_dir/../lib/push-wake.sh"
  . "$_hook_dir/../lib/attention-key.sh"
  _cn_pane="${HERDR_PANE_ID:-}"
  if [ -z "$_cn_pane" ] || attn_track_claim "$_cn_pane" "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" "$(prompt_id "$_cn_pane" 2>/dev/null)"; then
    push_wake "$msg" "$where" >/dev/null 2>&1 || true
  fi
fi

# The legacy one-way webhook is GONE. It posted the same text to a bot you could
# not reply to, so every alert arrived twice and only one of them was actionable.
# herdrbot is the single outbound path now.
exit 0
