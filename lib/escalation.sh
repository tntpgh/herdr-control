#!/usr/bin/env bash
# lib/escalation.sh — "this worker is looping, hand it to a stronger model."
#
# BRIEF + R2 + R3 (feat/no-progress-model-escalation): 2-3 genuine
# no-progress loops hand off to the next tier on a fixed, reviewed ladder —
# same pane/worktree, same manifest, same approval mode — without ever
# clearing a recorded tool denial or pending approval, with an audit event
# per escalation and a cap of one escalation per tier per task. R2 made the
# hook real (quiesce, verify, spawn through spawn-task.sh). R3 (root audit
# of 7bb9fba) fixes five gaps that review found in that real hook:
#
#   1. The attempt lock is now acquired BEFORE the first side effect
#      (quiesce), not just claimed at the commit point — see
#      `_esc_acquire_lock`/`_esc_release_lock`, a releasable SQLite lease
#      (BEGIN IMMEDIATE, same idiom as set_task_state below), not the
#      permanent one-shot `claim_once` used for the final commit.
#   2. Both incarnations are pinned, not inferred from pane liveness or a
#      branch+label guess alone: the OLD writer is quiesced only after its
#      recorded `pane_birth` (herdr's terminal_id) is confirmed live and
#      matching — a recycled pane_id is treated as "already gone", never
#      closed; the NEW writer's task_id is pinned in a
#      `writer_successor_pinned` event the first time it is identified, and
#      every later check (this call's own retries, or a separate later
#      call) resolves through that pinned id, not a fresh branch+label scan.
#   3. Liveness/birth checks are 3-way (alive / confirmed-gone /
#      indeterminate), not boolean — herdr being unreachable mid-check
#      fails the attempt closed (task preserved, nothing closed, nothing
#      spawned) instead of being silently read as "already gone".
#   4. The ladder is fast(haiku) -> standard(sonnet) -> deep(opus) ->
#      frontier(codex's $HERDR_CODEX_DEEP) — four REAL tiers read from the
#      one existing model table (lib/agent-profiles.sh's model_for_agent),
#      never an invented "stronger opus". frontier is a cross-family jump
#      (claude -> codex) because opus is claude's ceiling; whatever
#      $HERDR_CODEX_DEEP currently resolves to (today gpt-5.6-sol:high;
#      becomes gpt-6-sol:high the moment PR #378 merges, no code change
#      needed here) IS "the available model ID" — nothing here hardcodes a
#      version string.
#   5. A genuine tool/approval DENIAL is tracked separately from a
#      repeated tool-FAILURE signature and can never by itself cause a
#      loop verdict — escalating in response to a denial would look like
#      routing around it with a stronger model, which BRIEF #3 and this
#      round's review both forbid. When a real loop (stuck progress) fires
#      WHILE a denial is open, the denial is carried forward explicitly
#      (`denial_carried_forward` event + a "do not retry" section in the
#      context packet), not merely left alone and hoped a stateless
#      classifier rerun would still refuse it.
#   6. "Waiting on a human" is read from the registry's own pending
#      `input_required` state (`esc_task_awaiting_human`), not just the
#      `conductor_prompt` stall-watchdog signal — a prompt the task is
#      still blocked on is an intentional hold regardless of which signal
#      happened to trigger this watchdog cycle.
#
# Reuses, does not reinvent:
#   - lib/run-registry.sh's events table + claim_once for detection
#     evidence, the cap-one-per-tier commit, and the audit trail.
#   - lib/agent-profiles.sh's model_for_agent for tier -> model name.
#   - lib/pane-guard.sh's pane_is_agent/pane_birth_now for the real
#     liveness/incarnation checks, and spawn-task.sh itself (never
#     reimplemented) to create the successor in the SAME worktree/branch.
#   - The exact `BEGIN IMMEDIATE; ...; COMMIT; SELECT changes();` lease
#     idiom lib/run-registry.sh's own set_task_state/set_task_conductor and
#     lib/owner-identity.sh already use for compare-and-swap.
#   - stall-watchdog.sh IS the resident watchdog this wires into (see its
#     `_sw_escalation_tick`) — no second daemon.
#
# ---- evidence model ----------------------------------------------------------
# One `no_progress_tick` event per watchdog cycle. A tick's payload:
#   commit_sha        HEAD of the task's worktree, or "" if unreadable
#   artifact_fp       caller-supplied fingerprint of the last-touched
#                      artifact — the caller decides what "the artifact" is
#   tool_fail_sig     signature of a repeated TOOL EXECUTION failure (never
#                      a policy/approval denial — see denial_sig)
#   denial_sig        signature of a tool/approval DENIAL on this cycle
#                      (stall-watchdog's `denied` signal), carried for
#                      context only — NEVER a loop trigger by itself
#   waiting_on_human  1 if the task is blocked on a human-reserved prompt —
#                      true when EITHER the caller says so (e.g. the
#                      `conductor_prompt` signal) OR the registry itself
#                      shows an open `input_required` (no_progress_tick
#                      ORs this in automatically via esc_task_awaiting_human)
#
# no_progress_detect reads back the last HERDR_NO_PROGRESS_CYCLES ticks:
#   (a) commit_sha and artifact_fp identical across the whole window, or
#   (b) tool_fail_sig identical AND non-empty across the whole window
# — UNLESS the most recent tick is waiting_on_human, which always wins.
# denial_sig never participates in (a)/(b); its presence is surfaced as
# `held_denial` in the verdict for the caller to carry forward.
set -uo pipefail
_esc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_esc_dir/run-registry.sh"
. "$_esc_dir/agent-profiles.sh"
. "$_esc_dir/pane-guard.sh"

# ---- ladder ------------------------------------------------------------------

# esc_ladder -> the configured tiers, one per line, in escalation order.
esc_ladder() { printf '%s\n' ${HERDR_ESCALATION_LADDER:-fast standard deep frontier}; }

# esc_spawn_job <run_id> <task_id> -> the job-class embedded in this
# task's own label (spawn-task.sh: label="${job}:${branch}"), or empty
# (nonzero exit) if this task has no such label (e.g. a raw-command spawn
# with no job-class at all).
esc_spawn_job() {
  local run_id="$1" task_id="$2" label
  registry_init || return 1
  label="$(_sql "SELECT label FROM tasks WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id");" 2>/dev/null)"
  [ -n "$label" ] && [ "${label#*:}" != "$label" ] || return 1
  printf '%s\n' "${label%%:*}"
}

# esc_job_tier <job-class> -> the ladder tier that job-class's recorded
# MODEL belongs to, using the exact same synonym groups
# lib/agent-profiles.sh's model_for_agent case statement uses for
# fast/standard/deep (explore|quick|mechanical / implement|debug|code|docs
# / plan|architect|design) — deliberately NOT a call to model_for_agent
# itself, because every agent branch there ends in a catch-all default
# (`claude:*) sonnet`, `codex:*) $HERDR_CODEX_STD`, ...) that would
# silently fold an UNRECOGNIZED job-class into "standard"'s model and
# look like a false match. `review` and `deep-review` are deliberately
# left unmapped too (they run at a different effort/model than any ladder
# tier's own exact model) — R4 review: "fail closed if unknown", never
# guess the weakest tier for a job this ladder doesn't recognize.
esc_job_tier() {
  case "$1" in
    explore|quick|mechanical)   printf 'fast\n' ;;
    implement|debug|code|docs)  printf 'standard\n' ;;
    plan|architect|design)      printf 'deep\n' ;;
    *)                          return 1 ;;
  esac
}

# esc_starting_tier <run_id> <task_id> -> the tier this task actually
# started on, derived from its own spawn record (esc_spawn_job + the
# model_for_agent groupings esc_job_tier mirrors) — never assumed to be
# the ladder's weakest tier. Fails (empty, nonzero) when the job-class is
# missing or unrecognized, so a caller that can't verify where a task
# started refuses to escalate rather than guessing fast (R4 review D: a
# worker already on sonnet must never be treated as starting on haiku and
# "escalated" sideways to the sonnet it is already running).
esc_starting_tier() {
  local run_id="$1" task_id="$2" job
  job="$(esc_spawn_job "$run_id" "$task_id")" || return 1
  esc_job_tier "$job"
}

# esc_current_tier <run_id> <task_id> -> the tier this task is on now: the
# to_tier of its most recent model_escalated event, or — for a task that
# has never escalated — its ACTUAL starting tier via esc_starting_tier
# (never the ladder's first word as a blind assumption). Fails (empty,
# nonzero) when neither is available, so the caller fails closed instead
# of escalating from an unverifiable position.
esc_current_tier() {
  local run_id="$1" task_id="$2" payload tier
  payload="$(task_last_event_payload "$run_id" "$task_id" model_escalated)"
  tier="$(printf '%s' "$payload" | jq -r '.to_tier // empty' 2>/dev/null)"
  if [ -n "$tier" ]; then
    printf '%s\n' "$tier"
    return 0
  fi
  esc_starting_tier "$run_id" "$task_id"
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

# esc_tier_job <tier> -> the job-class esc_tier_model uses for it, and the
# label prefix spawn-task.sh registers the successor under
# (spawn-task.sh: label="${job}:${branch}") — reusing that existing field
# is what lets a successor's spawn-record job-class be mapped back to a
# tier (esc_job_tier) without a second table. frontier uses
# "deep-review", NOT "plan": it resolves to the SAME target model as
# deep for every agent model_for_agent already defines deep-review for
# (claude:deep-review = opus, codex:deep-review = $HERDR_CODEX_DEEP)
# while keeping its OWN distinct label ("deep-review:branch" vs deep's
# "plan:branch") — sharing "plan" between the two tiers would make a
# successor spawned for one indistinguishable from the other by label
# alone (R5 no longer discovers successors by label at all, but
# esc_job_tier's reverse mapping and esc_starting_tier still rely on
# each tier having its own unambiguous job-class).
esc_tier_job() {
  case "$1" in
    fast)     printf 'explore\n' ;;
    standard) printf 'implement\n' ;;
    deep)     printf 'plan\n' ;;
    frontier) printf 'deep-review\n' ;;
    *)        return 1 ;;
  esac
}

# esc_tier_agent <base_agent> <tier> -> which agent FAMILY that tier
# launches under. Every tier keeps the caller's own family EXCEPT
# `frontier`, which always resolves to codex: opus is claude's ceiling (no
# invented "stronger opus"), so the one real step beyond it is the
# strongest model this config actually names for ANY family — codex's
# $HERDR_CODEX_DEEP, read through the same model_for_agent table
# spawn-task.sh itself uses, never duplicated or hardcoded here.
esc_tier_agent() {
  local base="$1" tier="$2"
  case "$tier" in
    frontier) printf 'codex\n' ;;
    *)        printf '%s\n' "$base" ;;
  esac
}

# esc_tier_model <agent> <tier> -> model name for that tier, via the one
# table spawn-task.sh's job-class routing already uses. Caller passes the
# RESOLVED agent (esc_tier_agent's output), not necessarily the task's
# original family.
esc_tier_model() {
  local agent="$1" tier="$2" job
  job="$(esc_tier_job "$tier")" || return 1
  model_for_agent "$agent" "$job"
}

# ---- detection -----------------------------------------------------------

# esc_task_awaiting_human <run_id> <task_id> -> 0 if the registry's own
# event history shows a currently OPEN input_required for this task — the
# most recent `input_required` is newer than the most recent handling event
# (owner_acted/brief_delivered/reply_delivered/approval_reviewed/
# stall_acked — the same vocabulary stall-watchdog.sh's own
# `_sw_owner_acted_since`/`_sw_acked_since` already treat as "handled").
# This is registry-grounded and signal-independent: it is true regardless
# of which stall-watchdog signal triggered the current wake, fixing R3
# review's "the conductor_prompt-only exclusion is probably too narrow".
esc_task_awaiting_human() {
  local run_id="$1" task_id="$2" last_req last_act
  registry_init || return 1
  last_req="$(_sql "SELECT COALESCE(MAX(sequence),0) FROM events
    WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id") AND type='input_required';" 2>/dev/null)"
  [ "${last_req:-0}" -gt 0 ] || return 1
  last_act="$(_sql "SELECT COALESCE(MAX(sequence),0) FROM events
    WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
    AND type IN ('owner_acted','brief_delivered','reply_delivered','approval_reviewed','stall_acked');" 2>/dev/null)"
  [ "${last_req:-0}" -gt "${last_act:-0}" ]
}

# no_progress_tick <run_id> <task_id> <commit_sha> <artifact_fp> \
#   <tool_fail_sig> <waiting_on_human 0|1> [<denial_sig>] — record one
# watchdog cycle's evidence. Append-only. waiting_on_human is OR'd with
# esc_task_awaiting_human regardless of what the caller passed, so this is
# the one place the broadened human-wait check applies to every producer
# (the resident watchdog AND the standalone CLI) without duplicating it.
no_progress_tick() {
  local run_id="$1" task_id="$2" commit_sha="$3" artifact_fp="$4" \
        tool_fail_sig="$5" waiting_on_human="${6:-0}" denial_sig="${7:-}"
  esc_task_awaiting_human "$run_id" "$task_id" && waiting_on_human=1
  append_event "$run_id" "$task_id" no_progress_tick \
    "$(jq -nc --arg c "$commit_sha" --arg a "$artifact_fp" --arg s "$tool_fail_sig" --arg ds "$denial_sig" \
        --argjson w "$([ "$waiting_on_human" = 1 ] && echo true || echo false)" \
        '{commit_sha:$c, artifact_fp:$a, tool_fail_sig:$s, denial_sig:$ds, waiting_on_human:$w}')"
}

# no_progress_detect <run_id> <task_id> -> JSON {loop, reason, cycles,
# held_denial, window}. loop is computed from commit/artifact-stuck OR a
# repeated non-empty tool_fail_sig ONLY — denial_sig never contributes, so
# a genuinely denied action repeating never drives escalation by itself
# (R3 review: escalating on a denial alone would look like routing around
# it). held_denial reports whether the LATEST tick carries a denial_sig,
# for the caller to carry forward alongside a real loop, independent of
# whether the denial influenced the loop verdict.
no_progress_detect() {
  local run_id="$1" task_id="$2" need="${HERDR_NO_PROGRESS_CYCLES:-3}" rows
  registry_init || return 1
  rows="$(_sql "SELECT json_group_array(json(payload)) FROM
      (SELECT payload FROM events WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
         AND type='no_progress_tick' ORDER BY sequence DESC LIMIT $need);" 2>/dev/null)"
  jq -nc --argjson need "$need" --argjson rows "${rows:-[]}" '
    def norm: if . == null then [] else . end;
    ($rows|norm) as $w
    | ($w[0].denial_sig // "" | length > 0) as $held_denial
    | if ($w|length) < $need then
        {loop:false, reason:"insufficient_window", cycles:($w|length), held_denial:$held_denial, window:$w}
      elif ($w[0].waiting_on_human == true) then
        {loop:false, reason:"human_wait", cycles:($w|length), held_denial:$held_denial, window:$w}
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
             cycles:($w|length), held_denial:$held_denial, window:$w}
          else
            {loop:false, reason:"progress_observed", cycles:($w|length), held_denial:$held_denial, window:$w}
          end
      end'
}

# ---- escalation action -----------------------------------------------------

# esc_already_escalated <run_id> <task_id> <tier> -> 0 if this task already
# has a model_escalated event landing on that tier — the cheap pre-check;
# the lock + claim_once below are the atomic enforcement.
esc_already_escalated() {
  local run_id="$1" task_id="$2" tier="$3" n
  registry_init || return 1
  n="$(_sql "SELECT COUNT(*) FROM events WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
    AND type='model_escalated' AND json_extract(payload,'\$.to_tier')=$(_sq "$tier");" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
}

# esc_open_denials <run_id> <task_id> -> count of recorded approval/tool
# denials for this task (approval_escalated events with verdict "deny").
# Escalation never touches these — see esc_carry_forward_denials, which
# makes the hold EXPLICIT rather than relying on this count alone.
esc_open_denials() {
  local run_id="$1" task_id="$2"
  registry_init || return 1
  _sql "SELECT COUNT(*) FROM events WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
    AND type='approval_escalated' AND json_extract(payload,'\$.verdict')='deny';" 2>/dev/null
}

# esc_denial_reasons <run_id> <task_id> -> JSON array of {reason,command}
# for every recorded deny, oldest first — the exact prior denial(s), not a
# fresh classifier guess.
esc_denial_reasons() {
  local run_id="$1" task_id="$2"
  registry_init || return 1
  _sql "SELECT json_group_array(json_object('reason', json_extract(payload,'\$.reason'),
      'command', json_extract(payload,'\$.command')))
    FROM (SELECT payload FROM events WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
      AND type='approval_escalated' AND json_extract(payload,'\$.verdict')='deny' ORDER BY sequence);" 2>/dev/null
}

# esc_carry_forward_denials <run_id> <task_id> <to_tier> -> if there are
# open denials, write ONE `denial_carried_forward` event pinning their
# exact reasons/commands and `no_auto_retry:true` into the handoff, and
# print the same JSON (empty array means nothing to carry). R3 review: "a
# global classifier rerun does NOT count as keeping an exact prior tool
# denial" — this is the task-scoped, persisted record that does.
esc_carry_forward_denials() {
  local run_id="$1" task_id="$2" to_tier="$3" denials
  denials="$(esc_denial_reasons "$run_id" "$task_id")"
  [ "$denials" != "[]" ] && [ -n "$denials" ] || { printf '[]\n'; return 0; }
  append_event "$run_id" "$task_id" denial_carried_forward \
    "$(jq -nc --arg t "$to_tier" --argjson d "$denials" \
        '{to_tier:$t, denials:$d, no_auto_retry:true}')" >/dev/null 2>&1
  printf '%s\n' "$denials"
}

# esc_context_packet <run_id> <task_id> <from_tier> <to_tier> <reason> \
#   <out_path> — write the handoff context packet (brief, last PROOF, last
# N events, git log, and — when there are open denials — an explicit
# "do not retry" section) to out_path.
esc_context_packet() {
  local run_id="$1" task_id="$2" from_tier="$3" to_tier="$4" reason="$5" out="$6"
  local task_json worktree events_json denials
  task_json="$(read_task "$run_id" "$task_id")"
  worktree="$(printf '%s' "$task_json" | jq -r '.worktree // empty' 2>/dev/null)"
  events_json="$(_sql "SELECT json_group_array(json_object('type',type,'occurred_at',occurred_at,'payload',json(payload)))
    FROM (SELECT type, occurred_at, payload FROM events WHERE run_id=$(_sq "$run_id") AND task_id=$(_sq "$task_id")
      ORDER BY sequence DESC LIMIT 20);" 2>/dev/null)"
  denials="$(esc_denial_reasons "$run_id" "$task_id")"
  {
    printf '# Escalation context packet — %s\n\n' "$task_id"
    printf -- '- from tier: %s\n- to tier: %s\n- reason: %s\n- worktree: %s\n\n' \
      "$from_tier" "$to_tier" "$reason" "${worktree:-unknown}"
    if [ "$denials" != "[]" ] && [ -n "$denials" ]; then
      printf '## HELD — do not retry without new authority\n\n'
      printf '%s' "$denials" | jq -r '.[] | "- denied: " + (.reason // "unspecified") + (if .command then " (" + .command + ")" else "" end)'
      printf '\n'
    fi
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

# ---- serialization lock (R3 #1, R4 residual (a)) ----------------------------
# A RELEASABLE, FENCED, RENEWABLE SQLite lease — acquired BEFORE the first
# escalation side effect (quiesce) and held for the whole quiesce+spawn
# attempt — distinct from claim_once's PERMANENT one-shot commit at the
# end. Every acquire gets a strictly monotonic `fence` (global MAX+1,
# never reused even across releases/expiries); a background renewer
# (`_esc_start_lock_renewer`) refreshes `renewed_at` every
# HERDR_ESCALATION_LOCK_STALE_S/3 seconds for the WHOLE duration of the
# attempt, including while a single external call (close/spawn) is still
# blocked — R4 review: "the 300s lock can expire while the hook is still
# running... that must NOT let a second writer in." A plain TTL with no
# renewal would let a slow-but-alive holder's lock expire and be stolen
# mid-attempt; this one only ever goes stale if the holder's renewer
# itself stops (crash, or the holder already finished). If the renewer
# ever finds its OWN fence is no longer the live claimed row (stolen —
# only possible if renewal genuinely lapsed past the TTL), it writes a
# lost-marker and stops; `_esc_lock_still_held` is checked before EACH
# subsequent side effect (quiesce, spawn) so a holder that did lose the
# race aborts before doing anything further, rather than racing a thief.
# Same `BEGIN IMMEDIATE; ...; COMMIT; SELECT changes();` idiom
# lib/run-registry.sh's own set_task_state uses for compare-and-swap.
_esc_lock_schema() {
  _sql "CREATE TABLE IF NOT EXISTS escalation_locks (
    fence INTEGER NOT NULL, task_id TEXT NOT NULL, to_tier TEXT NOT NULL, state TEXT NOT NULL,
    holder TEXT NOT NULL DEFAULT '', locked_at TEXT NOT NULL, renewed_at TEXT NOT NULL,
    PRIMARY KEY (task_id, to_tier, fence));" >/dev/null 2>&1
}
_esc_acquire_lock() {                   # task_id to_tier -> prints fence, rc 0 if WE acquired it
  local task_id="$1" to_tier="$2" stale="${HERDR_ESCALATION_LOCK_STALE_S:-300}" holder now out fence got_holder
  registry_init || return 1
  _esc_lock_schema
  holder="$$_$(_now_iso)_$RANDOM"
  now="$(_now_iso)"
  out="$(_sql "BEGIN IMMEDIATE;
    UPDATE escalation_locks SET state='expired'
      WHERE task_id=$(_sq "$task_id") AND to_tier=$(_sq "$to_tier") AND state='claimed'
        AND (strftime('%s','now') - strftime('%s',renewed_at)) > $stale;
    INSERT INTO escalation_locks (fence, task_id, to_tier, state, holder, locked_at, renewed_at)
      SELECT COALESCE((SELECT MAX(fence) FROM escalation_locks),0)+1,
        $(_sq "$task_id"), $(_sq "$to_tier"), 'claimed', $(_sq "$holder"), $(_sq "$now"), $(_sq "$now")
      WHERE NOT EXISTS (SELECT 1 FROM escalation_locks
        WHERE task_id=$(_sq "$task_id") AND to_tier=$(_sq "$to_tier") AND state='claimed');
    COMMIT;
    SELECT fence, holder FROM escalation_locks
      WHERE task_id=$(_sq "$task_id") AND to_tier=$(_sq "$to_tier") AND state='claimed'
      ORDER BY fence DESC LIMIT 1;" 2>/dev/null)"
  fence="$(printf '%s' "$out" | cut -d'|' -f1)"
  got_holder="$(printf '%s' "$out" | cut -d'|' -f2)"
  [ -n "$fence" ] && [ "$got_holder" = "$holder" ] || return 1
  printf '%s\n' "$fence"
}
_esc_renew_lock() {                     # task_id to_tier fence -> 0 if still the live claimed row
  local changed
  changed="$(_sql "UPDATE escalation_locks SET renewed_at=$(_sq "$(_now_iso)")
    WHERE task_id=$(_sq "$1") AND to_tier=$(_sq "$2") AND fence=$3 AND state='claimed';
    SELECT changes();" 2>/dev/null)"
  [ "${changed:-0}" = 1 ]
}
_esc_release_lock() {                   # task_id to_tier fence
  _sql "UPDATE escalation_locks SET state='released'
    WHERE task_id=$(_sq "$1") AND to_tier=$(_sq "$2") AND fence=$3 AND state='claimed';" >/dev/null 2>&1
}
_esc_lock_lost_marker() {               # task_id to_tier fence -> marker path
  printf '%s/escalation-lock-lost-%s-%s-%s' "${TMPDIR:-/tmp}" "$1" "$2" "$3"
}
# _esc_start_lock_renewer <task_id> <to_tier> <fence> -> prints the
# renewer's pid. Runs as a background subshell (inherits the already-
# sourced functions) for the lifetime of one escalation attempt; must be
# paired with `_esc_stop_lock_renewer`.
_esc_start_lock_renewer() {
  local task_id="$1" to_tier="$2" fence="$3" stale interval marker
  stale="${HERDR_ESCALATION_LOCK_STALE_S:-300}"
  interval=$((stale / 3)); [ "$interval" -ge 1 ] || interval=1
  marker="$(_esc_lock_lost_marker "$task_id" "$to_tier" "$fence")"
  rm -f "$marker"
  ( while sleep "$interval"; do
      _esc_renew_lock "$task_id" "$to_tier" "$fence" >/dev/null 2>&1 || { : > "$marker"; exit 0; }
    done ) >/dev/null 2>&1 </dev/null &
  printf '%s\n' "$!"
}
_esc_stop_lock_renewer() {              # renewer_pid
  [ -n "${1:-}" ] || return 0
  kill "$1" >/dev/null 2>&1
  wait "$1" 2>/dev/null
  return 0
}
_esc_lock_still_held() {                # task_id to_tier fence -> 0 unless known lost
  [ ! -f "$(_esc_lock_lost_marker "$1" "$2" "$3")" ]
}

# ---- the real quiesce-before-spawn hook -------------------------------------
# Injection points, same shape as stall-watchdog.sh's own SW_SEND/
# SW_NOTIFY: a real default wired to the real binary, overridable by a test
# or an operator — invoked via `bash "$VAR" args` so the override need not
# be executable.
#   HERDR_ESC_PANE_ALIVE_CMD <pane_id>  -> exit 0 alive / 1 confirmed gone /
#                                          2 indeterminate (herdr itself
#                                          unreachable — fail closed, never
#                                          read as "gone")
#   HERDR_ESC_PANE_BIRTH_CMD <pane_id>  -> prints the live terminal_id on
#                                          stdout (empty = pane gone);
#                                          exit 0 resolved, 1 = herdr
#                                          unreachable (indeterminate)
#   HERDR_ESC_PANE_CLOSE_CMD <pane_id>  -> ask herdr to close it
#   HERDR_ESC_SPAWN_CMD <repo> <branch> <job> <agent>
#                                        -> spawn the successor (prints
#                                           nothing load-bearing; looked up
#                                           in the registry afterward)

_esc_pane_alive() {
  local pane="$1"
  if [ -n "${HERDR_ESC_PANE_ALIVE_CMD:-}" ]; then
    bash "$HERDR_ESC_PANE_ALIVE_CMD" "$pane"
    return $?
  fi
  herdr pane list >/dev/null 2>&1 || return 2
  pane_is_agent "$pane" 2>/dev/null && return 0
  return 1
}

_esc_pane_birth_now() {
  local pane="$1"
  if [ -n "${HERDR_ESC_PANE_BIRTH_CMD:-}" ]; then
    bash "$HERDR_ESC_PANE_BIRTH_CMD" "$pane"
    return $?
  fi
  pane_birth_now "$pane"
}

_esc_pane_close() {
  local pane="$1"
  if [ -n "${HERDR_ESC_PANE_CLOSE_CMD:-}" ]; then
    bash "$HERDR_ESC_PANE_CLOSE_CMD" "$pane"
    return $?
  fi
  herdr pane close "$pane" >/dev/null 2>&1
}

# _esc_spawn_successor <repo> <branch> <job> <agent> -> prints the
# RECEIPT task_id on stdout, rc 0 only if one was actually parsed out of
# the spawn command's own output (R5: "bind to the actual spawn receipt
# ... no lookup by branch+label"). A real spawn-task.sh prints
# `HERDR_SPAWN_RECEIPT task_id=... run_id=...` as its LAST line on every
# real (non-dry-run) success path; HERDR_ESC_SPAWN_CMD overrides (tests,
# operators) must emit the same line to be trusted the same way. Missing
# or unparseable output is NOT "assume it worked and go look it up" — the
# caller treats this as a hook failure like any other and holds the task
# for the conductor (R3's existing retry-then-fail-closed path).
_esc_spawn_successor() {
  local out task_id
  if [ -n "${HERDR_ESC_SPAWN_CMD:-}" ]; then
    out="$(bash "$HERDR_ESC_SPAWN_CMD" "$@" 2>/dev/null)" || return 1
  else
    out="$(bash "$_esc_dir/../spawn-task.sh" --no-focus "$@" 2>/dev/null)" || return 1
  fi
  task_id="$(printf '%s\n' "$out" | sed -n 's/^HERDR_SPAWN_RECEIPT task_id=\([^ ]*\) run_id=.*/\1/p' | tail -n1)"
  [ -n "$task_id" ] || return 1
  printf '%s\n' "$task_id"
}

# _esc_quiesce_old_writer <run_id> <task_id> -> 0 once the OLD incarnation
# (task_id + recorded pane_birth, not just pane_id) is confirmed gone
# (R3 #2/#3). Three outcomes, never conflated:
#   - no pane recorded, or the recorded pane_birth no longer matches the
#     LIVE pane's birth (a different occupant, or none) -> that incarnation
#     is already gone; success, nothing closed.
#   - liveness/birth genuinely indeterminate (herdr unreachable) -> fail
#     closed: nothing closed, task preserved, caller retries later.
#   - confirmed alive and the same incarnation -> close it, then POLL
#     (also 3-way) until confirmed gone or the poll bound is exhausted.
_esc_quiesce_old_writer() {
  local run_id="$1" task_id="$2" task_json pane pane_birth bound i rc live_birth birth_rc
  task_json="$(read_task "$run_id" "$task_id")"
  pane="$(printf '%s' "$task_json" | jq -r '.pane_id // empty' 2>/dev/null)"
  pane_birth="$(printf '%s' "$task_json" | jq -r '.pane_birth // empty' 2>/dev/null)"
  [ -n "$pane" ] || return 0

  if [ -n "$pane_birth" ]; then
    live_birth="$(_esc_pane_birth_now "$pane")"; birth_rc=$?
    if [ "$birth_rc" != 0 ]; then
      printf 'escalation: %s pane %s birth could not be verified (herdr unreachable) — not closing, task preserved\n' "$task_id" "$pane" >&2
      return 1
    fi
    if [ "$live_birth" != "$pane_birth" ]; then
      append_event "$run_id" "$task_id" writer_quiesced \
        "$(jq -nc --arg p "$pane" --arg ob "$pane_birth" --arg lb "$live_birth" \
            '{pane:$p, reason:"pane_recycled_or_gone", old_pane_birth:$ob, live_birth:$lb}')" >/dev/null 2>&1
      return 0
    fi
  fi

  _esc_pane_alive "$pane"; rc=$?
  if [ "$rc" = 1 ]; then return 0; fi
  if [ "$rc" != 0 ]; then
    printf 'escalation: %s pane %s liveness could not be verified (herdr unreachable) — not closing, task preserved\n' "$task_id" "$pane" >&2
    return 1
  fi

  _esc_pane_close "$pane"
  bound="${HERDR_ESCALATION_QUIESCE_POLLS:-5}"
  for ((i = 0; i < bound; i++)); do
    _esc_pane_alive "$pane"; rc=$?
    if [ "$rc" = 1 ]; then
      append_event "$run_id" "$task_id" writer_quiesced \
        "$(jq -nc --arg p "$pane" --arg b "$pane_birth" '{pane:$p, pane_birth:$b}')" >/dev/null 2>&1
      return 0
    fi
    if [ "$rc" != 0 ]; then
      printf 'escalation: %s pane %s liveness could not be verified mid-poll (herdr unreachable) — task preserved, will retry\n' "$task_id" "$pane" >&2
      return 1
    fi
  done
  printf 'escalation: %s pane %s still alive after close + %s checks\n' "$task_id" "$pane" "$bound" >&2
  return 1
}

# _esc_spawn_next_tier <run_id> <task_id> <agent> <to_tier> -> prints the
# successor's task_id on success, having PINNED it (old+new task_id,
# old+new pane_id/pane_birth) in a `writer_successor_pinned` event the
# first time it is identified. Every call after that resolves through
# the pin, not a fresh discovery — satisfies R3 #2's "pin the old and
# new task and session incarnation".
#
# R5: the FIRST-ever discovery binds STRICTLY to the spawn's own
# receipt (_esc_spawn_successor's stdout) — never a branch+label scan of
# the registry, at any filter. A timestamp filter (the R4 residual (b)
# approach this replaces) is still a SELECT over a shared table: an
# unrelated task created at the exact same instant as the request, or
# any time after it, on that same branch+label, would still match and
# be silently adopted as if we had spawned it. The receipt has no such
# window — it is the literal return value of the exact spawn call this
# attempt made, correlated by process, not by scanning shared state
# afterward. A missing or unparseable receipt is NOT "assume it worked
# and go look it up" — fail closed, hold the task for the conductor
# (same path as any other hook failure).
#
# _esc_task_json <task_id> -> that task's registry row as JSON, resolving
# its run_id first (task_id alone is globally unique — same pattern
# stall-watchdog.sh's cmd_ack already uses — so this is correct for a
# successor task_id discovered here, which may belong to a different
# run_id than the task escalating it).
_esc_task_json() {
  local task_id="$1" run_id
  registry_init || return 1
  run_id="$(_sql "SELECT run_id FROM tasks WHERE task_id=$(_sq "$task_id") LIMIT 1;" 2>/dev/null)"
  [ -n "$run_id" ] || return 1
  read_task "$run_id" "$task_id"
}

_esc_spawn_next_tier() {
  local run_id="$1" task_id="$2" agent="$3" to_tier="$4" \
        task_json repo branch job existing old_pane old_pane_birth \
        pinned pinned_tier pinned_task succ_json succ_state succ_pane succ_birth
  task_json="$(read_task "$run_id" "$task_id")"
  repo="$(printf '%s' "$task_json" | jq -r '.repo // empty' 2>/dev/null)"
  branch="$(printf '%s' "$task_json" | jq -r '.branch // empty' 2>/dev/null)"
  old_pane="$(printf '%s' "$task_json" | jq -r '.pane_id // empty' 2>/dev/null)"
  old_pane_birth="$(printf '%s' "$task_json" | jq -r '.pane_birth // empty' 2>/dev/null)"
  [ -n "$repo" ] && [ -n "$branch" ] || { printf 'escalation: %s has no repo/branch recorded — cannot spawn a successor\n' "$task_id" >&2; return 1; }
  job="$(esc_tier_job "$to_tier")" || return 1

  pinned="$(task_last_event_payload "$run_id" "$task_id" writer_successor_pinned)"
  pinned_tier="$(printf '%s' "$pinned" | jq -r '.to_tier // empty' 2>/dev/null)"
  if [ "$pinned_tier" = "$to_tier" ]; then
    pinned_task="$(printf '%s' "$pinned" | jq -r '.successor_task_id // empty' 2>/dev/null)"
    if [ -n "$pinned_task" ] && [ -n "$(_esc_task_json "$pinned_task" 2>/dev/null)" ]; then
      printf '%s\n' "$pinned_task"
      return 0
    fi
    # A previously pinned successor vanished from the registry entirely —
    # fall through and re-derive rather than silently fabricating one.
  fi

  existing="$(_esc_spawn_successor "$repo" "$branch" "$job" "$agent")" || {
    printf 'escalation: %s/%s spawn produced no verifiable receipt — holding for the conductor rather than adopting an unrelated branch+label match\n' "$task_id" "$to_tier" >&2
    return 1
  }
  succ_json="$(_esc_task_json "$existing")"
  [ -n "$succ_json" ] || {
    printf 'escalation: %s/%s spawn receipt %s does not resolve to a registered task — holding for the conductor\n' "$task_id" "$to_tier" "$existing" >&2
    return 1
  }
  succ_state="$(printf '%s' "$succ_json" | jq -r '.state // empty' 2>/dev/null)"
  case "$succ_state" in
    completed|failed|cancelled|lost|gone)
      printf 'escalation: %s/%s spawn receipt %s resolved to a terminal task (%s) — holding for the conductor\n' "$task_id" "$to_tier" "$existing" "$succ_state" >&2
      return 1
      ;;
  esac

  succ_pane="$(printf '%s' "$succ_json" | jq -r '.pane_id // empty' 2>/dev/null)"
  succ_birth="$(printf '%s' "$succ_json" | jq -r '.pane_birth // empty' 2>/dev/null)"
  append_event "$run_id" "$task_id" writer_successor_pinned \
    "$(jq -nc --arg t "$to_tier" --arg s "$existing" --arg op "$old_pane" --arg ob "$old_pane_birth" \
        --arg np "$succ_pane" --arg nb "$succ_birth" \
        '{to_tier:$t, successor_task_id:$s, old_pane_id:$op, old_pane_birth:$ob,
          successor_pane_id:$np, successor_pane_birth:$nb}')" >/dev/null 2>&1
  printf '%s\n' "$existing"
}

# esc_escalate <run_id> <task_id> <agent> <reason> <evidence_json> \
#   <dry_run 0|1> <context_dir> -> escalates to the next ladder tier.
#
# Order of operations (R3 #1): acquire the releasable lock before QUIESCE
# — the first action that touches a live pane or spawns a process. (The
# context packet write just above that, and the from_tier/to_tier/model
# resolution before it, are local reads/a file write, not a live side
# effect on the task's pane or process, so the lock does not need to cover
# them — an earlier version of this comment overstated that ordering.) A
# concurrent second attempt for the same
# (task_id, to_tier) finds the lock held and returns immediately with NO
# side effect of its own (see verify case K: a nested attempt fired from
# inside the fake spawn hook, mid-flight of the first attempt, is refused
# before it ever calls close/spawn). The lock is released on failure (so
# the next watchdog cycle retries cleanly) and stays claimed on success
# (harmless — esc_already_escalated's pre-check blocks every future
# attempt for that tier before it would ever be consulted again).
#
# Only on real success (quiesce confirmed + successor pinned) does the
# audit event (`model_escalated`) get written and claim_once consume the
# tier. A failed attempt leaves no trace that would stop a later retry,
# bounded within this call by HERDR_ESCALATION_HOOK_RETRIES.
#
# dry_run NEVER acquires the lock, quiesces, spawns, claims the tier, or
# writes `model_escalated` — it writes a separate `model_escalation_dry_run`
# event, so an arbitrary number of dry runs never blocks the real thing.
esc_escalate() {
  local run_id="$1" task_id="$2" agent="$3" reason="$4" evidence="$5" \
        dry_run="${6:-0}" context_dir="${7:-.}"
  registry_init || return 1
  local from_tier to_tier to_agent
  from_tier="$(esc_current_tier "$run_id" "$task_id")" || {
    printf 'escalation: %s has no verifiable starting tier (missing or unrecognized job-class in its spawn record) — refusing to escalate rather than guessing\n' "$task_id" >&2
    return 1
  }
  to_tier="$(esc_next_tier "$from_tier")" || { printf 'escalation: %s is already at the ladder ceiling\n' "$task_id" >&2; return 1; }
  esc_already_escalated "$run_id" "$task_id" "$to_tier" && { printf 'escalation: %s already escalated to %s (cap: one per tier)\n' "$task_id" "$to_tier" >&2; return 1; }

  printf '%s' "${evidence:-{\}}" | jq -e . >/dev/null 2>&1 || evidence='{}'
  to_agent="$(esc_tier_agent "$agent" "$to_tier")"
  local from_model to_model
  from_model="$(esc_tier_model "$agent" "$from_tier")" || from_model=""
  to_model="$(esc_tier_model "$to_agent" "$to_tier")" || to_model=""
  mkdir -p "$context_dir" 2>/dev/null || true
  local packet
  packet="$(esc_context_packet "$run_id" "$task_id" "$from_tier" "$to_tier" "$reason" \
    "$context_dir/escalation-${task_id}-${to_tier}.md")"

  if [ "$dry_run" = 1 ]; then
    local dry_payload
    dry_payload="$(jq -nc --arg from_tier "$from_tier" --arg to_tier "$to_tier" \
      --arg from_model "$from_model" --arg to_model "$to_model" --arg to_agent "$to_agent" \
      --arg reason "$reason" --arg packet "$packet" --argjson evidence "$evidence" \
      '{from_tier:$from_tier, to_tier:$to_tier, from_model:$from_model, to_model:$to_model,
        to_agent:$to_agent, reason:$reason, evidence:$evidence, context_packet:$packet}')"
    append_event "$run_id" "$task_id" model_escalation_dry_run "$dry_payload" >/dev/null 2>&1
    printf '%s\n' "$dry_payload"
    return 0
  fi

  local fence
  fence="$(_esc_acquire_lock "$task_id" "$to_tier")" || {
    printf 'escalation: %s/%s is locked by a concurrent attempt\n' "$task_id" "$to_tier" >&2
    return 1
  }
  local renewer_pid
  renewer_pid="$(_esc_start_lock_renewer "$task_id" "$to_tier" "$fence")"

  local bound attempt successor_task=""
  bound="${HERDR_ESCALATION_HOOK_RETRIES:-3}"
  for ((attempt = 1; attempt <= bound; attempt++)); do
    _esc_lock_still_held "$task_id" "$to_tier" "$fence" || {
      printf 'escalation: %s/%s lock (fence %s) was lost mid-attempt (renewal lapsed past the TTL) — aborting before any further side effect, task preserved\n' "$task_id" "$to_tier" "$fence" >&2
      break
    }
    if _esc_quiesce_old_writer "$run_id" "$task_id"; then
      _esc_lock_still_held "$task_id" "$to_tier" "$fence" || {
        printf 'escalation: %s/%s lock (fence %s) was lost between quiesce and spawn — aborting before spawn, task preserved\n' "$task_id" "$to_tier" "$fence" >&2
        break
      }
      successor_task="$(_esc_spawn_next_tier "$run_id" "$task_id" "$to_agent" "$to_tier")" && [ -n "$successor_task" ] && break
    fi
    successor_task=""
  done
  _esc_stop_lock_renewer "$renewer_pid"

  if [ -z "$successor_task" ]; then
    _esc_release_lock "$task_id" "$to_tier" "$fence"
    append_event "$run_id" "$task_id" model_escalation_hook_failed \
      "$(jq -nc --arg t "$to_tier" --argjson attempts "$bound" '{to_tier:$t, attempts:$attempts}')" >/dev/null 2>&1
    printf 'escalation: hook failed for %s -> %s after %s attempt(s)\n' "$task_id" "$to_tier" "$bound" >&2
    return 1
  fi

  # R3 #5: a genuine open denial is carried forward EXPLICITLY alongside a
  # real loop — never the trigger by itself (no_progress_detect already
  # guarantees that), but surfaced here so the successor's own context
  # packet and the audit trail both say "do not retry" in so many words.
  local held_denials
  held_denials="$(esc_carry_forward_denials "$run_id" "$task_id" "$to_tier")"

  # The pinned successor/old-incarnation record (R3 #2), read back so the
  # final audit event carries it without re-deriving anything.
  local pin old_pane_birth succ_pane succ_birth
  pin="$(task_last_event_payload "$run_id" "$task_id" writer_successor_pinned)"
  old_pane_birth="$(printf '%s' "$pin" | jq -r '.old_pane_birth // empty' 2>/dev/null)"
  succ_pane="$(printf '%s' "$pin" | jq -r '.successor_pane_id // empty' 2>/dev/null)"
  succ_birth="$(printf '%s' "$pin" | jq -r '.successor_pane_birth // empty' 2>/dev/null)"

  # The commit point: claimed ONLY after a verified quiesce + a confirmed,
  # pinned successor. A second successful caller (race, or a retried tick
  # after this one's event already landed) finds the claim taken and does
  # nothing further.
  claim_once "escalate_${task_id}_${to_tier}" "$run_id" "$task_id" model_escalation_claim \
    "$(jq -nc --arg f "$from_tier" --arg t "$to_tier" '{from_tier:$f, to_tier:$t}')" || {
    _esc_release_lock "$task_id" "$to_tier" "$fence"
    printf '%s\n' "$(jq -nc --arg t "$to_tier" --arg s "$successor_task" '{to_tier:$t, successor_task_id:$s, already_claimed:true}')"
    return 0
  }
  _esc_release_lock "$task_id" "$to_tier" "$fence"

  local payload
  payload="$(jq -nc --arg from_tier "$from_tier" --arg to_tier "$to_tier" \
    --arg from_model "$from_model" --arg to_model "$to_model" --arg to_agent "$to_agent" \
    --arg reason "$reason" --arg packet "$packet" --arg successor "$successor_task" \
    --arg old_pane_birth "$old_pane_birth" --arg successor_pane "$succ_pane" --arg successor_pane_birth "$succ_birth" \
    --argjson evidence "$evidence" --argjson held_denials "${held_denials:-[]}" \
    '{from_tier:$from_tier, to_tier:$to_tier, from_model:$from_model, to_model:$to_model, to_agent:$to_agent,
      reason:$reason, evidence:$evidence, context_packet:$packet, successor_task_id:$successor,
      old_pane_birth:$old_pane_birth, successor_pane_id:$successor_pane, successor_pane_birth:$successor_pane_birth,
      held_denials:$held_denials, dry_run:false}')"
  append_event "$run_id" "$task_id" model_escalated "$payload" || return 1
  printf '%s\n' "$payload"
}
