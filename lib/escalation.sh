#!/usr/bin/env bash
# lib/escalation.sh — "this worker is looping, hand it to a stronger model."
#
# BRIEF + BRIEF-R2 (feat/no-progress-model-escalation): 2-3 genuine
# no-progress loops hand off to the next tier on a fixed, reviewed ladder —
# same pane/worktree, same manifest, same approval mode — without ever
# clearing a recorded tool denial or pending approval, with an audit event
# per escalation and a cap of one escalation per tier per task. R2: the
# hook is REAL (quiesce the old pane, verify it stopped, spawn the
# successor through spawn-task.sh, all idempotent/bounded-retry), not an
# optional external command left unset.
#
# Reuses, does not reinvent:
#   - lib/run-registry.sh's events table + claim_once for detection evidence,
#     the cap-one-per-tier lock, and the audit trail — the same durable store
#     stall-watchdog.sh and herdr-select.sh already write to.
#   - lib/agent-profiles.sh's model_for_agent for tier -> model name, so the
#     tier vocabulary (fast/standard/deep) stays the ONE definition
#     spawn-task.sh's job-class table already uses, not a second one.
#   - lib/pane-guard.sh's pane_is_agent for the real "is the old writer
#     still alive" check, and spawn-task.sh itself (not a reimplementation)
#     to actually create the successor in the SAME worktree/branch.
#   - config.sh's HERDR_ESCALATION_LADDER / HERDR_NO_PROGRESS_CYCLES /
#     HERDR_ESCALATION_HOOK_RETRIES for the reviewed, fixed-in-config ladder
#     and the bound on the real hook's retry loop.
#   - stall-watchdog.sh IS the resident watchdog this wires into (see its
#     `_sw_escalation_tick`) — no second daemon.
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
. "$_esc_dir/pane-guard.sh"

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
# tier per task" cap, read-side; the claim_once at the bottom of esc_escalate
# is the atomic enforcement — this is the cheap pre-check that also lets a
# dry run or a detect-only caller ask "would this be a no-op" for free).
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
# count it sees after. R2's own proof goes further — see
# verify-no-progress-escalation.sh's denial case, which re-runs the real
# `conductor_reserved_reason`/`classify_command` classifier against the
# denied command AFTER the handoff and asserts it is STILL refused, not
# just that this count held steady.
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

# ---- the real quiesce-before-spawn hook -------------------------------------
# Three injection points, same shape as stall-watchdog.sh's own SW_SEND/
# SW_NOTIFY: a real default wired to the real binary, overridable by a test
# or an operator. Each is invoked via `bash "$VAR" args` so the override
# need not be executable, matching the house precedent.
#   HERDR_ESC_PANE_ALIVE_CMD <pane_id>          -> exit 0 if an agent is
#                                                   still running there
#   HERDR_ESC_PANE_CLOSE_CMD <pane_id>           -> ask herdr to close it
#   HERDR_ESC_SPAWN_CMD <repo> <branch> <job> <agent>
#                                                 -> spawn the successor
#                                                   (prints nothing load-
#                                                   bearing; esc_escalate
#                                                   looks the new task up
#                                                   in the registry by
#                                                   label afterward)

_esc_pane_alive() {
  local pane="$1"
  if [ -n "${HERDR_ESC_PANE_ALIVE_CMD:-}" ]; then
    bash "$HERDR_ESC_PANE_ALIVE_CMD" "$pane"
    return $?
  fi
  pane_is_agent "$pane"
}

_esc_pane_close() {
  local pane="$1"
  if [ -n "${HERDR_ESC_PANE_CLOSE_CMD:-}" ]; then
    bash "$HERDR_ESC_PANE_CLOSE_CMD" "$pane"
    return $?
  fi
  herdr pane close "$pane" >/dev/null 2>&1
}

_esc_spawn_successor() {                # repo branch job agent
  if [ -n "${HERDR_ESC_SPAWN_CMD:-}" ]; then
    bash "$HERDR_ESC_SPAWN_CMD" "$@"
    return $?
  fi
  bash "$_esc_dir/../spawn-task.sh" --no-focus "$@" >/dev/null 2>&1
}

# _esc_quiesce_old_writer <run_id> <task_id> -> 0 once the task's own pane
# is confirmed NOT running an agent (BRIEF-R2 #2: "it stops, and you verify
# it stopped"). A pane already dead (no pane_id recorded, or pane_is_agent
# already false) is a no-op success — this is what makes a retried call
# idempotent: it never re-closes an already-closed pane, it only verifies.
_esc_quiesce_old_writer() {
  local run_id="$1" task_id="$2" task_json pane bound i
  task_json="$(read_task "$run_id" "$task_id")"
  pane="$(printf '%s' "$task_json" | jq -r '.pane_id // empty' 2>/dev/null)"
  [ -n "$pane" ] || return 0
  _esc_pane_alive "$pane" || return 0
  _esc_pane_close "$pane"
  bound="${HERDR_ESCALATION_QUIESCE_POLLS:-5}"
  for ((i = 0; i < bound; i++)); do
    _esc_pane_alive "$pane" || {
      append_event "$run_id" "$task_id" writer_quiesced \
        "$(jq -nc --arg p "$pane" '{pane:$p}')" >/dev/null 2>&1
      return 0
    }
  done
  printf 'escalation: %s pane %s still alive after close + %s checks\n' "$task_id" "$pane" "$bound" >&2
  return 1
}

# esc_tier_job <tier> -> the job-class esc_tier_model already uses for it,
# and also the label prefix spawn-task.sh will register the successor
# under (spawn-task.sh: label="${job}:${branch}") — reusing that existing
# field is what lets the next function look a successor up idempotently
# without a second table.
esc_tier_job() {
  case "$1" in
    fast)     printf 'explore\n' ;;
    standard) printf 'implement\n' ;;
    deep)     printf 'plan\n' ;;
    *)        return 1 ;;
  esac
}

# _esc_find_successor <branch> <to_tier> -> task_id of a non-terminal task
# already registered on this exact branch at this tier's label, or empty.
# This is the idempotency check BRIEF-R2 #3 asks for ("a re-run doesn't
# double-spawn"): a prior attempt that spawned the successor but was
# interrupted (hub's 25s subprocess timeout, a crash) before emitting
# model_escalated leaves exactly this row behind, and the retry finds it
# instead of spawning a second one.
_esc_find_successor() {
  local branch="$1" to_tier="$2" job label
  job="$(esc_tier_job "$to_tier")" || return 1
  label="${job}:${branch}"
  _sql "SELECT task_id FROM tasks WHERE branch=$(_sq "$branch") AND label=$(_sq "$label")
    AND state NOT IN ('completed','failed','cancelled','lost','gone')
    ORDER BY rowid DESC LIMIT 1;" 2>/dev/null
}

# _esc_spawn_next_tier <run_id> <task_id> <agent> <to_tier> -> prints the
# successor's task_id on success. Idempotent: checks _esc_find_successor
# BEFORE calling the spawn command, and again after (spawn-task.sh itself
# reuses an existing worktree/branch rather than erroring — see its own
# "worktree: create or reuse" section — so a retried spawn call is safe
# even if the first one actually landed but this process never saw it).
_esc_spawn_next_tier() {
  local run_id="$1" task_id="$2" agent="$3" to_tier="$4" task_json repo branch job existing
  task_json="$(read_task "$run_id" "$task_id")"
  repo="$(printf '%s' "$task_json" | jq -r '.repo // empty' 2>/dev/null)"
  branch="$(printf '%s' "$task_json" | jq -r '.branch // empty' 2>/dev/null)"
  [ -n "$repo" ] && [ -n "$branch" ] || { printf 'escalation: %s has no repo/branch recorded — cannot spawn a successor\n' "$task_id" >&2; return 1; }
  job="$(esc_tier_job "$to_tier")" || return 1

  existing="$(_esc_find_successor "$branch" "$to_tier")"
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing"
    return 0
  fi

  _esc_spawn_successor "$repo" "$branch" "$job" "$agent" || return 1

  existing="$(_esc_find_successor "$branch" "$to_tier")"
  [ -n "$existing" ] || { printf 'escalation: spawn command exited 0 but no successor task is registered for %s/%s\n' "$branch" "$to_tier" >&2; return 1; }
  printf '%s\n' "$existing"
}

# esc_escalate <run_id> <task_id> <agent> <reason> <evidence_json> \
#   <dry_run 0|1> <context_dir> -> escalates to the next ladder tier.
#
# Ordering (BRIEF-R2 #2/#3): quiesce-and-verify the old pane, THEN spawn the
# successor (idempotently), and ONLY on real success does the audit event
# (`model_escalated`) get written and the tier's claim_once get consumed —
# a failed attempt leaves no trace that would stop a later retry, and the
# whole quiesce+spawn step is retried up to HERDR_ESCALATION_HOOK_RETRIES
# times within this call before giving up for this tick (the next tick's
# own call retries again, picking up via the idempotent checks above —
# this is also how a hub subprocess timeout mid-hook is survived: nothing
# committed, nothing lost, next cycle just tries again).
#
# "No duplicate writer" is enforced by construction, not by a separate
# mutex: _esc_spawn_next_tier is never reached until
# _esc_quiesce_old_writer has POLLED and CONFIRMED the old pane is no
# longer running an agent, so there is no window in this call where both
# the old and new writer pane are alive. A concurrent SECOND call for the
# same task cannot happen in practice — the resident stall watchdog itself
# dedupes its own wake-per-fingerprint before ever reaching the tick hook
# (stall-watchdog.sh's own claim_once on signal+fingerprint) — so no
# additional cross-process lock is added for a race that does not occur
# in the one real caller (ladder rule: justify complexity against a
# concrete failure mode, not a speculative one).
#
# dry_run NEVER quiesces, spawns, claims the tier, or writes
# `model_escalated` (BRIEF-R2 #4: "must not mutate the live ladder or
# consume tiers") — it writes a separate `model_escalation_dry_run` event
# carrying what WOULD happen, and nothing esc_already_escalated/claim_once
# look at, so an arbitrary number of dry runs never blocks the real thing.
esc_escalate() {
  local run_id="$1" task_id="$2" agent="$3" reason="$4" evidence="$5" \
        dry_run="${6:-0}" context_dir="${7:-.}"
  registry_init || return 1
  local from_tier to_tier
  from_tier="$(esc_current_tier "$run_id" "$task_id")"
  to_tier="$(esc_next_tier "$from_tier")" || { printf 'escalation: %s is already at the ladder ceiling\n' "$task_id" >&2; return 1; }
  esc_already_escalated "$run_id" "$task_id" "$to_tier" && { printf 'escalation: %s already escalated to %s (cap: one per tier)\n' "$task_id" "$to_tier" >&2; return 1; }

  printf '%s' "${evidence:-{\}}" | jq -e . >/dev/null 2>&1 || evidence='{}'
  local from_model to_model
  from_model="$(esc_tier_model "$agent" "$from_tier")" || from_model=""
  to_model="$(esc_tier_model "$agent" "$to_tier")" || to_model=""
  mkdir -p "$context_dir" 2>/dev/null || true
  local packet
  packet="$(esc_context_packet "$run_id" "$task_id" "$from_tier" "$to_tier" "$reason" \
    "$context_dir/escalation-${task_id}-${to_tier}.md")"

  if [ "$dry_run" = 1 ]; then
    local dry_payload
    dry_payload="$(jq -nc --arg from_tier "$from_tier" --arg to_tier "$to_tier" \
      --arg from_model "$from_model" --arg to_model "$to_model" \
      --arg reason "$reason" --arg packet "$packet" --argjson evidence "$evidence" \
      '{from_tier:$from_tier, to_tier:$to_tier, from_model:$from_model, to_model:$to_model,
        reason:$reason, evidence:$evidence, context_packet:$packet}')"
    append_event "$run_id" "$task_id" model_escalation_dry_run "$dry_payload" >/dev/null 2>&1
    printf '%s\n' "$dry_payload"
    return 0
  fi

  local bound attempt successor_task=""
  bound="${HERDR_ESCALATION_HOOK_RETRIES:-3}"
  for ((attempt = 1; attempt <= bound; attempt++)); do
    if _esc_quiesce_old_writer "$run_id" "$task_id"; then
      successor_task="$(_esc_spawn_next_tier "$run_id" "$task_id" "$agent" "$to_tier")" && [ -n "$successor_task" ] && break
    fi
    successor_task=""
  done

  if [ -z "$successor_task" ]; then
    append_event "$run_id" "$task_id" model_escalation_hook_failed \
      "$(jq -nc --arg t "$to_tier" --argjson attempts "$bound" '{to_tier:$t, attempts:$attempts}')" >/dev/null 2>&1
    printf 'escalation: hook failed for %s -> %s after %s attempt(s)\n' "$task_id" "$to_tier" "$bound" >&2
    return 1
  fi

  # The commit point: claimed ONLY after a verified quiesce + a confirmed
  # successor. A second successful caller (race, or a retried tick after
  # this one's event already landed) finds the claim taken and does
  # nothing further — the successor it would have "spawned" already exists
  # per _esc_find_successor, so there is no double-spawn either way.
  claim_once "escalate_${task_id}_${to_tier}" "$run_id" "$task_id" model_escalation_claim \
    "$(jq -nc --arg f "$from_tier" --arg t "$to_tier" '{from_tier:$f, to_tier:$t}')" || {
    printf '%s\n' "$(jq -nc --arg t "$to_tier" --arg s "$successor_task" '{to_tier:$t, successor_task_id:$s, already_claimed:true}')"
    return 0
  }

  local payload
  payload="$(jq -nc --arg from_tier "$from_tier" --arg to_tier "$to_tier" \
    --arg from_model "$from_model" --arg to_model "$to_model" \
    --arg reason "$reason" --arg packet "$packet" --arg successor "$successor_task" \
    --argjson evidence "$evidence" \
    '{from_tier:$from_tier, to_tier:$to_tier, from_model:$from_model, to_model:$to_model,
      reason:$reason, evidence:$evidence, context_packet:$packet, successor_task_id:$successor,
      dry_run:false}')"
  append_event "$run_id" "$task_id" model_escalated "$payload" || return 1
  printf '%s\n' "$payload"
}
