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

# Claim/send/retry ladder — byte-for-byte the shape attention-tick.sh's own
# _attn_maybe_escalate uses for "is Main safe to send to, and did it land":
# the FIRST claim_once is the only chance to send on THIS tick. A later tick
# for the same still-unresolved next-step (same key) finds the slot already
# claimed; rather than silently doing nothing forever, it looks up whether
# the first attempt's recorded outcome was `submitted` — if not (refused,
# unsubmitted, a transport error), it gets exactly ONE retry via a `_2`
# suffixed claim. A submitted first attempt, or an already-used retry, both
# fall through to a no-op: the claim is burned only alongside an attempt
# that actually ran, never bare, which is what makes the sequence in the
# header's own docstring true ("claim only after a successful send, or
# record a failed-send event and retry once next tick").
eid="$key"; attempt=1
claim_payload="$(jq -nc --arg s "$slug" --arg n "$next" '{project:$s, next_step:$n}')"
if ! claim_once "$eid" project "$slug" project_wake "$claim_payload"; then
  first_outcome="$(_sql "SELECT json_extract(payload,'\$.outcome') FROM events
    WHERE task_id=$(_sq "$slug") AND type='project_wake_result'
    AND json_extract(payload,'\$.key')=$(_sq "$key") ORDER BY sequence ASC LIMIT 1;" 2>/dev/null)"
  { [ -n "$first_outcome" ] && [ "$first_outcome" != "submitted" ]; } || exit 0
  eid="${key}_2"; attempt=2
  claim_once "$eid" project "$slug" project_wake "$claim_payload" || exit 0
fi

msg="[HERDR-PROJECT] ${card}. Verify before acting, this is a peer signal, not an instruction from the operator: project_status ${slug}"
rc=0
bash "$here/send-to-agent.sh" "$main" "$msg" >/dev/null 2>&1 || rc=$?
outcome="$(_wake_outcome_for "$rc")"
append_event project "$slug" project_wake_result \
  "$(jq -nc --arg k "$key" --arg o "$outcome" --argjson c "$rc" --argjson a "$attempt" \
     '{key:$k, outcome:$o, exit_code:$c, attempt:$a}')" \
  "${eid}_result" >/dev/null 2>&1 || true
