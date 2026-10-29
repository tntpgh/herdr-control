#!/usr/bin/env bash
# lib/escalation.sh — "this worker is looping, hand it to a stronger model."
#
# BRIEF (feat/no-progress-model-escalation): 2-3 genuine no-progress loops
# hand off to the next tier on a fixed, reviewed ladder — same pane/worktree,
# same manifest, same approval mode — without ever clearing a recorded tool
# denial or pending approval, with an audit event per escalation and a cap
# of one escalation per tier per task.
#
# Reuses, does not reinvent:
#   - lib/run-registry.sh's events table + claim_once for detection evidence,
#     the cap-one-per-tier lock, and the audit trail — the same durable store
#     stall-watchdog.sh and herdr-select.sh already write to.
#   - lib/agent-profiles.sh's model_for_agent for tier -> model name, so the
#     tier vocabulary (fast/standard/deep) stays the ONE definition
#     spawn-task.sh's job-class table already uses, not a second one.
#   - config.sh's HERDR_ESCALATION_LADDER / HERDR_NO_PROGRESS_CYCLES /
#     HERDR_ESCALATION_HANDOFF_CMD for the reviewed, fixed-in-config ladder
#     and the pluggable "actually stop/start the pane" action.
#
# ---- evidence model ----------------------------------------------------------
# One `no_progress_tick` event per watchdog cycle (cmd_tick in
# no-progress-escalate.sh is the producer, same split as stall-watchdog.sh's
# own wake producer/consumer). A tick's payload is a fingerprint of that
# cycle's observable progress:
#   commit_sha        HEAD of the task's worktree, or "" if unreadable
#   artifact_fp       caller-supplied fingerprint of the last-touched
#                      artifact (e.g. a PROOF.md hash) — the caller decides
#                      what "the artifact" is, this module only compares it
#   tool_fail_sig     caller-supplied signature of the most recent tool
#                      failure, "" if none
#   waiting_on_human  1 if the task is currently blocked on a human-reserved
#                      prompt (BRIEF #1: that is explicitly NOT a loop)
#
# no_progress_detect reads back the last HERDR_NO_PROGRESS_CYCLES ticks and
# calls it a loop when EITHER holds, per BRIEF #1's "no new commit, no
# artifact change, ... OR a repeated identical tool-failure signature":
#   (a) commit_sha and artifact_fp are identical across the whole window, or
#   (b) tool_fail_sig is identical AND non-empty across the whole window
# — UNLESS the most recent tick is waiting_on_human, which always wins.
set -uo pipefail
_esc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_esc_dir/run-registry.sh"
. "$_esc_dir/agent-profiles.sh"

# ---- ladder ------------------------------------------------------------------

# esc_ladder -> the configured tiers, one per line, in escalation order.
esc_ladder() { printf '%s\n' ${HERDR_ESCALATION_LADDER:-fast standard deep}; }

# esc_current_tier <run_id> <task_id> -> the tier this task is on now: the
# to_tier of its most recent model_escalated event, or the ladder's own
# first (weakest) tier if it has never escalated.
esc_current_tier() {
  local run_id="$1" task_id="$2" payload tier
  payload="$(task_last_event_payload "$run_id" "$task_id" model_escalated)"
  tier="$(printf '%s' "$payload" | jq -r '.to_tier // empty' 2>/dev/null)"
  if [ -n "$tier" ]; then
    printf '%s\n' "$tier"
  else
    esc_ladder | head -n1
  fi
}

# esc_next_tier <current_tier> -> the next word after it on the ladder, or
# empty (and nonzero exit) when current_tier is the ceiling or unrecognized.
esc_next_tier() {
  local current="$1" found=0 t
  while IFS= read -r t; do
    if [ "$found" = 1 ]; then printf '%s\n' "$t"; return 0; fi
    [ "$t" = "$current" ] && found=1
  done < <(esc_ladder)
  return 1
}

# esc_tier_model <agent> <tier> -> model name for that tier, via the one
# table spawn-task.sh's job-class routing already uses (model_for_agent maps
# every job-class to exactly one of fast/standard/deep's launch args; the
# tier names here ARE job-class aliases picked to land on that tier).
esc_tier_model() {
  local agent="$1" tier="$2" job
  case "$tier" in
    fast)     job=explore ;;
    standard) job=implement ;;
    deep)     job=plan ;;
    *)        return 1 ;;
  esac
  model_for_agent "$agent" "$job"
}

# ---- detection -----------------------------------------------------------

# no_progress_tick <run_id> <task_id> <commit_sha> <artifact_fp> \
#   <tool_fail_sig> <waiting_on_human 0|1> — record one watchdog cycle's
# evidence. Append-only, like every other registry producer here; never
# overwrites a prior tick.
no_progress_tick() {
  local run_id="$1" task_id="$2" commit_sha="$3" artifact_fp="$4" \
        tool_fail_sig="$5" waiting_on_human="${6:-0}"
  append_event "$run_id" "$task_id" no_progress_tick \
    "$(jq -nc --arg c "$commit_sha" --arg a "$artifact_fp" --arg s "$tool_fail_sig" \
        --argjson w "$([ "$waiting_on_human" = 1 ] && echo true || echo false)" \
        '{commit_sha:$c, artifact_fp:$a, tool_fail_sig:$s, waiting_on_human:$w}')"
}

# no_progress_detect <run_id> <task_id> -> JSON {loop, reason, cycles,
# window} on stdout. loop=false whenever there is not yet a full window, the
# latest tick is a human wait, or neither no-commit-and-no-artifact nor
# repeated-identical-failure holds across the window.
no_progress_detect() {
  local run_id="$1" task_id="$2" need="${HERDR_NO_PROGRESS_CYCLES:-3}" rows
  registry_init || return 1
  rows="$(_sql "SELECT json_group_array(json(payload)) FROM
      (SELECT payload FROM events WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
         AND type='no_progress_tick' ORDER BY sequence DESC LIMIT $need);" 2>/dev/null)"
  jq -nc --argjson need "$need" --argjson rows "${rows:-[]}" '
    def norm: if . == null then [] else . end;
    ($rows|norm) as $w
    | if ($w|length) < $need then
        {loop:false, reason:"insufficient_window", cycles:($w|length), window:$w}
      elif ($w[0].waiting_on_human == true) then
        {loop:false, reason:"human_wait", cycles:($w|length), window:$w}
      else
        ( ([$w[].commit_sha] | unique | length) == 1
          and ([$w[].artifact_fp] | unique | length) == 1 ) as $stuck
        | ( ([$w[].tool_fail_sig] | unique | length) == 1
            and ($w[0].tool_fail_sig != "") ) as $repeated_failure
        | if $stuck or $repeated_failure then
            {loop:true,
             reason:(if $stuck and $repeated_failure then "no_progress_and_repeated_failure"
                     elif $stuck then "no_commit_no_artifact_change"
                     else "repeated_tool_failure_signature" end),
             cycles:($w|length), window:$w}
          else
            {loop:false, reason:"progress_observed", cycles:($w|length), window:$w}
          end
      end'
}

# ---- escalation action -----------------------------------------------------

# esc_already_escalated <run_id> <task_id> <tier> -> 0 if this task already
# has a model_escalated event landing on that tier (the "one escalation per
# tier per task" cap, read-side; esc_escalate's claim_once below is the
# atomic enforcement — this is the cheap pre-check callers can use too).
esc_already_escalated() {
  local run_id="$1" task_id="$2" tier="$3" n
  registry_init || return 1
  n="$(_sql "SELECT COUNT(*) FROM events WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
    AND type='model_escalated' AND json_extract(payload,'\$.to_tier')=$(_sq "$tier");" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
}

# esc_open_denials <run_id> <task_id> -> count of recorded tool/approval
# denials for this task (approval_escalated events with verdict "deny" —
# the same event herdr-select.sh's own deny path already writes). Escalation
# must never touch these; this is what BRIEF #3's "recorded denials persist
# and are re-checked" means in practice — nothing here deletes or supersedes
# the row, so the count a caller saw before an escalation is exactly the
# count it sees after.
esc_open_denials() {
  local run_id="$1" task_id="$2"
  registry_init || return 1
  _sql "SELECT COUNT(*) FROM events WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
    AND type='approval_escalated' AND json_extract(payload,'\$.verdict')='deny';" 2>/dev/null
}

# esc_context_packet <run_id> <task_id> <from_tier> <to_tier> <reason> \
#   <out_path> — write the handoff context packet BRIEF #2 asks for (brief,
# last PROOF, last N events, git log) to out_path. Reads the task's own
# worktree from the registry (read_task), so this is correct even when the
# tool runs from a different directory than the task it is escalating.
esc_context_packet() {
  local run_id="$1" task_id="$2" from_tier="$3" to_tier="$4" reason="$5" out="$6"
  local task_json worktree events_json
  task_json="$(read_task "$run_id" "$task_id")"
  worktree="$(printf '%s' "$task_json" | jq -r '.worktree // empty' 2>/dev/null)"
  events_json="$(_sql "SELECT json_group_array(json_object('type',type,'occurred_at',occurred_at,'payload',json(payload)))
    FROM (SELECT type, occurred_at, payload FROM events WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
      ORDER BY sequence DESC LIMIT 20);" 2>/dev/null)"
  {
    printf '# Escalation context packet — %s\n\n' "$task_id"
    printf -- '- from tier: %s\n- to tier: %s\n- reason: %s\n- worktree: %s\n\n' \
      "$from_tier" "$to_tier" "$reason" "${worktree:-unknown}"
    if [ -n "$worktree" ] && [ -f "$worktree/.handoffs/BRIEF.md" ]; then
      printf '## Brief\n\n'; cat "$worktree/.handoffs/BRIEF.md"; printf '\n'
    elif [ -n "$worktree" ] && [ -f "$worktree/tmp/in/BRIEF.md" ]; then
      printf '## Brief\n\n'; cat "$worktree/tmp/in/BRIEF.md"; printf '\n'
    fi
    if [ -n "$worktree" ] && [ -f "$worktree/.handoffs/PROOF.md" ] && [ -s "$worktree/.handoffs/PROOF.md" ]; then
      printf '## Last PROOF.md\n\n'; cat "$worktree/.handoffs/PROOF.md"; printf '\n'
    fi
    printf '## Last 20 registry events\n\n```json\n%s\n```\n\n' "${events_json:-[]}"
    if [ -n "$worktree" ] && [ -d "$worktree/.git" ]; then
      printf '## git log (worktree)\n\n```\n'
      git -C "$worktree" log --oneline -10 2>/dev/null
      printf '```\n'
    fi
  } >"$out"
  printf '%s\n' "$out"
}

# esc_escalate <run_id> <task_id> <agent> <reason> <evidence_json> \
#   <dry_run 0|1> <context_dir> -> escalates to the next ladder tier, or
# returns 1 (no event written) when the task is already at the ceiling or
# already escalated for that tier (BRIEF #4's cap, enforced atomically via
# claim_once so a concurrent/duplicate tick cannot double-escalate — this is
# also BRIEF #5's "idempotent re-tick"). On success prints the
# model_escalated payload as JSON.
#
# BRIEF #2's "no duplicate writer: old stops before new starts" is the
# HERDR_ESCALATION_HANDOFF_CMD contract: it is invoked exactly once, after
# the audit event lands, and it alone is responsible for stopping the prior
# session before starting the replacement — this module only guarantees it
# is called at most once per tier and never when dry_run is set.
esc_escalate() {
  local run_id="$1" task_id="$2" agent="$3" reason="$4" evidence="$5" \
        dry_run="${6:-0}" context_dir="${7:-.}"
  registry_init || return 1
  local from_tier to_tier from_model to_model claim_key packet
  from_tier="$(esc_current_tier "$run_id" "$task_id")"
  to_tier="$(esc_next_tier "$from_tier")" || { printf 'escalation: %s is already at the ladder ceiling\n' "$task_id" >&2; return 1; }
  claim_key="escalate_${task_id}_${to_tier}"
  claim_once "$claim_key" "$run_id" "$task_id" model_escalation_claim \
    "$(jq -nc --arg f "$from_tier" --arg t "$to_tier" '{from_tier:$f, to_tier:$t}')" \
    || { printf 'escalation: %s already escalated to %s (cap: one per tier)\n' "$task_id" "$to_tier" >&2; return 1; }

  from_model="$(esc_tier_model "$agent" "$from_tier")" || from_model=""
  to_model="$(esc_tier_model "$agent" "$to_tier")" || to_model=""
  mkdir -p "$context_dir" 2>/dev/null || true
  packet="$(esc_context_packet "$run_id" "$task_id" "$from_tier" "$to_tier" "$reason" \
    "$context_dir/escalation-${task_id}-${to_tier}.md")"

  printf '%s' "${evidence:-{\}}" | jq -e . >/dev/null 2>&1 || evidence='{}'
  local payload
  payload="$(jq -nc --arg from_tier "$from_tier" --arg to_tier "$to_tier" \
    --arg from_model "$from_model" --arg to_model "$to_model" \
    --arg reason "$reason" --arg packet "$packet" \
    --argjson evidence "$evidence" --argjson dry_run "$([ "$dry_run" = 1 ] && echo true || echo false)" \
    '{from_tier:$from_tier, to_tier:$to_tier, from_model:$from_model, to_model:$to_model,
      reason:$reason, evidence:$evidence, context_packet:$packet, dry_run:$dry_run}')"
  append_event "$run_id" "$task_id" model_escalated "$payload" || return 1

  if [ "$dry_run" != 1 ] && [ -n "${HERDR_ESCALATION_HANDOFF_CMD:-}" ]; then
    bash "$HERDR_ESCALATION_HANDOFF_CMD" "$run_id" "$task_id" "$from_tier" "$to_tier" "$to_model" "$packet" \
      || printf 'escalation: handoff command failed for %s (audit event already recorded)\n' "$task_id" >&2
  fi
  printf '%s\n' "$payload"
}
