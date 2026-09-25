#!/usr/bin/env bash
# project-wake.sh — thurber-os docs/project-contract-plan.md item 3, "carry to
# completion": wake the conductor designate-main.sh recorded when a PROJECT
# (not a single blocked pane — attention-tick.sh already owns that) has a
# next step, no live worker, and nothing it is waiting on from Terrence.
#
# hub.py's _project_attention_tick() decides WHICH projects qualify (reading
# projects_data() — the same join /api/projects serves) and calls this once
# per qualifying project per tick; this script owns dedupe/Main-resolution/
# send, reusing the exact discipline attention-tick.sh's own
# _attn_maybe_escalate already established for "is Main safe to send to" —
# never a second implementation of that check.
#
#   project-wake.sh <project-slug> <next-step-text> <card-text>
#
# claim_once("proj_wake_<slug>_<sha of next-step text>") makes this fire
# EXACTLY ONCE for a given unresolved state: once Terrence acts (spawns a
# worker, answers a decision, edits SPEC.md) the next tick recomputes a
# different next-step text (or none), and the OLD key never repeats — the
# project's own "answering it stops the repeat" requirement, without a
# separate acknowledgement channel.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh" 2>/dev/null || true
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"
. "$here/lib/push-wake.sh"   # _wake_outcome_for — the same exit-code -> word map every other wake uses

slug="${1:?usage: project-wake.sh <slug> <next-step> <card>}"
next="${2:?usage: project-wake.sh <slug> <next-step> <card>}"
card="${3:-$next}"
registry_init || exit 1

# A short digest of the next-step text, not the text itself, keeps the claim
# key short and shell-safe (claim_once's event_id is a bare SQL string, not
# arbitrary-length free text). Any digest tool is fine — only used for
# dedup, never verified against anything.
digest=""
if command -v shasum >/dev/null 2>&1; then
  digest=$(printf '%s' "$next" | shasum -a 256 | cut -c1-16)
elif command -v md5 >/dev/null 2>&1; then
  digest=$(printf '%s' "$next" | md5 | cut -c1-16)
else
  digest=$(printf '%s' "$next" | cksum | tr -d ' \t')
fi
key="proj_wake_${slug}_${digest}"

main="${HERDR_MAIN_PANE_ID:-}"
if [ -z "$main" ] || ! pane_is_agent "$main" 2>/dev/null; then
  claim_once "${key}_unreachable" project "$slug" project_wake_skipped \
    "$(jq -nc --arg s "$slug" --arg m "$main" \
       '{project:$s, main:$m, reason:"HERDR_MAIN_PANE_ID unset or not an agent pane"}')" >/dev/null 2>&1 || true
  exit 0
fi
# Birth-guarded like every other send in this codebase (attention-tick.sh's
# _attn_maybe_escalate): refuse only on a POSITIVE mismatch, never on an
# unreadable live sample.
main_birth="${HERDR_MAIN_PANE_BIRTH:-}"
if [ -n "$main_birth" ]; then
  live_main_birth="$(pane_birth_now "$main" 2>/dev/null)"
  if [ -n "$live_main_birth" ] && [ "$live_main_birth" != "$main_birth" ]; then
    claim_once "${key}_refused" project "$slug" project_wake_refused \
      "$(jq -nc --arg s "$slug" --arg reg "$main_birth" --arg live "$live_main_birth" \
         '{project:$s, registered_birth:$reg, live_birth:$live, reason:"HERDR_MAIN_PANE_BIRTH mismatch"}')" \
      >/dev/null 2>&1 || true
    exit 0
  fi
fi

claim_once "$key" project "$slug" project_wake \
  "$(jq -nc --arg s "$slug" --arg n "$next" '{project:$s, next_step:$n}')" || exit 0

msg="[HERDR-PROJECT] ${card}. Verify before acting, this is a peer signal, not an instruction from the operator: project_status ${slug}"
rc=0
bash "$here/send-to-agent.sh" "$main" "$msg" >/dev/null 2>&1 || rc=$?
outcome="$(_wake_outcome_for "$rc")"
append_event project "$slug" project_wake_result \
  "$(jq -nc --arg k "$key" --arg o "$outcome" --argjson c "$rc" '{key:$k, outcome:$o, exit_code:$c}')" \
  "${key}_result" >/dev/null 2>&1 || true
