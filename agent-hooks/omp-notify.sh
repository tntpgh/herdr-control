#!/usr/bin/env bash
# omp-notify.sh — omp's equivalent of claude-notify.sh: alert when a worker
# needs input, both to Slack and as a push wake to its conductor.
#
# ---- what triggers this ------------------------------------------------------
# omp DOES have a "I am asking the human something" surface, and this hook is
# wired to it: `tool_approval_requested` for the approval menu and
# `tool_execution_start` on the `ask` tool for a question (see
# agent-hooks/omp-herdr-control.ts). omp's own herdr integration drives
# pane.report_agent blocked/idle off the same pair.
#
# This file used to say omp had no such event and hang off `tool_call`, which
# fires before EVERY tool call, approved or not. That premise was wrong, and it
# cost: the script had to VERIFY by screen-scraping its own pane on every tool
# call of every worker — 20 `herdr pane read` RPCs and 10 python spawns each,
# which pushed the herdr socket's p95 from 9ms to 136ms with the fleet working
# and made the TUI itself feel laggy (measured 2026-09-14).
#
# The pane read stays, but only on this path: the EVENT says a human is needed,
# the pane says WHAT is on screen — the option rows Slack shows and the
# prompt_id a later answer is asserted against. An auto-approved tool call now
# never reaches this script at all, so it costs nothing.
#
# Reads one JSON object on stdin: {"tool": "...", "message": "...", "cwd": "..."}
# Always exits 0 — a monitoring hook must never fail the agent it monitors.
set -uo pipefail
_hook_dir=$(cd "$(dirname "$0")" && pwd)
here=$(cd "$_hook_dir/.." && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/push-wake.sh"

input="$(cat 2>/dev/null || true)"
tool="$(printf '%s' "$input" | jq -r '.tool // ""' 2>/dev/null || printf '')"
msg="$(printf '%s' "$input" | jq -r '.message // ""' 2>/dev/null || printf '')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || printf '')"
# Untruncated command (project-contract-plan.md #3b, item 2), when the caller
# has it — agent-hooks/omp-herdr-control.ts sends this only for a bash/shell
# tool_approval_requested, separate from `message` (which stays truncated for
# display). herdr-select.sh reads it back from the input_required event this
# script writes via push_wake, keyed to the same prompt_id.
full_cmd="$(printf '%s' "$input" | jq -r '.command // ""' 2>/dev/null || printf '')"
[ -n "$msg" ] || msg="omp needs your permission${tool:+ to use $tool}"

# The worker's own pane. Without it there is no way to confirm a prompt is real,
# and alerting unverified is exactly the storm this script exists to avoid — so
# no pane means no alert. spawn-task.sh stamps HERDR_PANE_ID into the worker's
# environment; an omp session started by hand outside spawn-task.sh therefore
# stays reconciliation-only (attention.sh, wait-for-blocked.sh, the interval
# sweep), which is the same deal a hand-started Claude session gets for its push
# wake.
pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || exit 0

# Is a prompt actually on screen? Checks BOTH shapes rather than assuming omp's:
# lib/prompt-parse.sh already knows the menu shape (highlight detected via its
# ANSI background-colour escape) and the numbered shape, and a caller here has
# no business caring which one a given omp build renders.
#
# prompt_any_visible answers both from ONE `herdr pane read`. Calling the two
# predicates separately cost two reads per attempt — 20 CLI spawns and 10
# python3 spawns per tool call per worker (~1.86s of CPU, measured 2026-09-14),
# every one of them an RPC into the single-threaded herdr server. With ~8 live
# workers that is what made herdr's own UI feel laggy, for the answer "nothing
# is asking" on the overwhelming majority of tool calls.
_prompt_is_up() { prompt_any_visible "$pane" 2>/dev/null; }

# tool_call fires BEFORE omp paints the approval menu, so a single check would
# usually miss it. Poll briefly. Each attempt costs one `herdr pane read`; the
# sleep is a real settle rather than a busy loop, and this runs detached from the
# agent's turn so the wait costs the agent nothing.
#
# Bounded deliberately: if no prompt has painted within ~1.5s the tool was
# auto-approved and there is nothing to alert about. Waiting longer would only
# delay discovering that.
#
# 5 attempts at 0.3s, not 10 at 0.15s: an approval menu is a BLOCKING prompt —
# once painted it stays until someone answers it — so a coarser poll can only
# delay detection by one interval, never miss it, and it halves the RPCs this
# fires at the herdr server on every tool call of every pane.
found=0
for _ in 1 2 3 4 5; do
  if _prompt_is_up; then found=1; break; fi
  sleep 0.3
done
[ "$found" = 1 ] || exit 0

where="${cwd##*/}"
[ -n "$where" ] && msg="$msg  ·  ${where}"

# ---- outbound Slack alert ---------------------------------------------------
# Same resolution order as claude-notify.sh so a packaged (APM) install and a
# plain checkout both work without editing: explicit override, then this
# checkout, then a deployed herdr-ops skill copy.
for notify in \
  "${HERDR_NOTIFY:-}" \
  "$here/slack-bridge/herdr-notify.sh" \
  "$HOME/.claude/skills/herdr-ops/scripts/slack-bridge/herdr-notify.sh"
do
  [ -n "$notify" ] && [ -f "$notify" ] && break
done
if [ -n "${notify:-}" ] && [ -f "$notify" ]; then
  # --pane, not a cwd hint: unlike the Claude hook we already know exactly which
  # pane asked, because we just confirmed the prompt on it. Passing the pane
  # explicitly avoids herdr-notify having to disambiguate several panes sharing
  # one repo cwd — a wrong guess there sends the operator's reply to a different
  # agent.
  #
  # Gated the same way the conductor wake is (lib/alert-gate.sh, applied inside
  # push_wake): an allow-class, unreserved prompt is one peer-answer.sh takes in
  # seconds, and paging for it is what turned an afternoon of ordinary worker
  # activity into a Slack flood on 2026-09-12. Held, never dropped — if the
  # prompt outlives the grace window the alert is sent after all.
  if human_must_answer "$pane"; then
    bash "$notify" --choices --pane "$pane" "$msg" >/dev/null 2>&1 || true
  else
    grace_realert "$pane" "$(prompt_id "$pane" 2>/dev/null || printf '')" \
      "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" \
      bash "$notify" --choices --pane "$pane" "$msg"
  fi
fi

# ---- push wake to the conductor --------------------------------------------
# All the guards (agent-pane gate, conductor pane-birth revalidation, prompt_id
# capture, delivery-outcome recording) live in lib/push-wake.sh, shared with
# claude-notify.sh so the two cannot drift.
#
# Claimed through the SAME attn_track_<key> the attention controller uses
# (lib/attention-key.sh) before calling push_wake at all — PR #132 review,
# item 6: a firing on a still-open prompt the controller (or an earlier
# firing) already owns must not call push_wake again — that is what turned
# one held prompt into two delivered wakes (item 1). HERDR_WAKE_LEGACY=1 is
# the rollback: every firing calls push_wake again, unclaimed.
. "$here/lib/attention-key.sh"
if attn_track_claim "$pane" "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" "$(prompt_id "$pane" 2>/dev/null)"; then
  push_wake "$msg" "$where" "$full_cmd" >/dev/null 2>&1 || true
fi

exit 0
