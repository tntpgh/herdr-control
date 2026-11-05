#!/usr/bin/env bash
# Notification event -> conductor push wake. Fires when Claude needs input /
# hits a permission prompt / goes idle.
set -uo pipefail
_hook_dir=$(cd "$(dirname "$0")" && pwd)

input="$(cat)"
msg="$(printf '%s' "$input" | jq -r '.message // .title // "Claude needs your attention"')"

# Decide what is worth a wake: drop the known-noisy idle nag, pass everything
# else (permission prompts, questions, errors). A false wake is cheap; a
# swallowed question stalls an agent until someone happens to look.
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
# Notification's own payload has no tool_name/tool_input — read
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

# --- push wake: alert the CONDUCTOR pane directly (control-plane Edge 1,
# docs/control-plane-design.md).
#
# Every guard — the agent-pane gate, the conductor pane-birth revalidation that
# closes the recycled-pane misdelivery, the prompt_id capture, and the
# delivery-outcome recording that replaced the old fire-and-forget `|| true` —
# now lives in lib/push-wake.sh, shared with agent-hooks/omp-notify.sh. Two
# copies of a safety check is two places for it to rot, which is the same reason
# lib/agent-profiles.sh exists.
#
# A worker only has HERDR_CONDUCTOR_PANE_ID when spawn-task.sh launched it
# from inside a herdr pane.
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
  else
    # Claim lost to the attention controller: record the hook's row anyway
    # (lib/push-wake.sh record-only), no second wake.
    push_wake "$msg" "$where" "" "" record-only >/dev/null 2>&1 || true
  fi
fi
exit 0
