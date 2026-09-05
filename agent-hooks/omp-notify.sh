#!/usr/bin/env bash
# omp-notify.sh — omp's equivalent of claude-notify.sh: alert when a worker
# needs input, both to Slack and as a push wake to its conductor.
#
# ---- why this is shaped differently from the Claude hook --------------------
# Claude Code has a `Notification` event that means "I am asking the human
# something", so claude-notify.sh is REACTIVE — it is told. omp has no such
# event. Its nearest surface is `tool_call`, which fires before EVERY tool call,
# approved or not (see agent-hooks/omp-herdr-control.ts).
#
# Alerting straight off `tool_call` would therefore be a signal storm — the
# failure Gemini's review named ("at 10 workers, if 4 hit permission prompts
# simultaneously, the conductor's input buffer floods"), except self-inflicted
# on every single bash call whether or not anyone was ever asked anything.
#
# So this script VERIFIES before it alerts: it polls the worker's own pane for a
# prompt that actually painted, and exits silently when none appears. That makes
# it safe to call on every tool call, and it is also approval-mode-agnostic by
# construction — under `--approval-mode yolo` nothing ever prompts, so nothing
# ever alerts, with no need to know or mirror which mode omp was launched at.
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
_prompt_is_up() {
  prompt_menu_visible "$pane" 2>/dev/null && return 0
  [ -n "$(prompt_options      "$pane" 2>/dev/null)" ] && return 0
  return 1
}

# tool_call fires BEFORE omp paints the approval menu, so a single check would
# usually miss it. Poll briefly. Each attempt costs one `herdr pane read`; the
# sleep is a real settle rather than a busy loop, and this runs detached from the
# agent's turn so the wait costs the agent nothing.
#
# Bounded deliberately: if no prompt has painted within ~1.5s the tool was
# auto-approved and there is nothing to alert about. Waiting longer would only
# delay discovering that.
found=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if _prompt_is_up; then found=1; break; fi
  sleep 0.15
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
  bash "$notify" --choices --pane "$pane" "$msg" >/dev/null 2>&1 || true
fi

# ---- push wake to the conductor --------------------------------------------
# All the guards (agent-pane gate, conductor pane-birth revalidation, prompt_id
# capture, delivery-outcome recording) live in lib/push-wake.sh, shared with
# claude-notify.sh so the two cannot drift.
push_wake "$msg" "$where" >/dev/null 2>&1 || true

exit 0
