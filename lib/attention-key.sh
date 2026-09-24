#!/usr/bin/env bash
# lib/attention-key.sh — the ONE place the attention controller's dedupe key
# is computed. Shared by attention-tick.sh (the controller) and the hooks
# that now claim the same key before push_wake (agent-hooks/omp-notify.sh,
# agent-hooks/claude-notify.sh) — PR #132 review, item 2 and item 6: two
# independent computations of "the same key" is exactly how they drift, and a
# drifted key is a dedupe that silently stops deduping.
#
# Provides: attention_dedupe_key <pane_id> [registered_birth] [command_text] -> key
#             command_text omitted -> reads prompt_command_text itself (the
#             hooks' path, which have no reason to have read it already);
#             passed explicitly (even "") -> reused as-is, so a caller that
#             already has it (attention_tick, via attention_probe) spends
#             exactly one screen read, not two, on the same pane.
#           attn_track_claim <pane_id> <run_id> <task_id> [prompt_id]
#             -> 0 if THIS call owns delivery (fresh claim, or
#                HERDR_WAKE_LEGACY=1), 1 if someone else already does.
#
# Requires lib/prompt-parse.sh (prompt_command_text) and, for attn_track_claim,
# lib/run-registry.sh (task_for_pane, claim_once) already sourced by the caller
# — same convention as lib/push-wake.sh's own header.
[ -n "${_HERDR_ATTENTION_KEY_SH:-}" ] && return 0
_HERDR_ATTENTION_KEY_SH=1

# Deliberately NOT prompt_id (lib/prompt-parse.sh). prompt_id hashes the whole
# question+options block and is documented to change on a mere repaint, a
# terminal resize rewrapping a long Command: row, or a scroll — none of which
# change WHAT is being approved (that is exactly why grace_realert refuses to
# compare it before re-alerting). Keying dedupe on it meant a repaint alone
# minted a fresh key and re-sent a wake for a prompt nobody had touched.
#
# prompt_command_text, whitespace-collapsed, is the semantic command — stable
# across a repaint of the identical prompt, and still identifies a genuinely
# NEW question (different command) as a different key.
#
# The command alone is not an OCCURRENCE, though: a worker re-running the same
# `git status` two hours later reused the first run's tracking claim, inherited
# its two-hour-old clock, and was escalated and formed on first sight
# (w1Q:p6, 2026-09-24, "No response 6923s"). A first attempt at a fix keyed on
# the pane's answer generation (confirmed approvals + owner_acted count), but
# that generation steps the INSTANT an answer confirms — before the prompt
# visibly clears — so the pane's key changed mid-flight and the very claim
# that suppresses escalation for THIS prompt (`_attn_answered_since`, keyed
# off the OLD key's "since") no longer matched the NEW one: 3 of
# verify-attention-tick.sh's answered/confirmed-approval cases escalated or
# formed anyway.
#
# A second attempt keyed on one edge per HOOK CALL (an unconditional mark on
# every attn_track_claim invocation) — also wrong, the other direction:
# verify-omp-hooks.sh pins that 3 independent hook firings on ONE still-open
# prompt cost exactly one claim/delivery (omp can and does call
# tool_approval_requested/omp-notify.sh more than once for a prompt nobody
# has answered yet — that repeat-firing dedupe is the entire reason
# attn_track_claim exists). Marking an edge per call broke it: 3 firings, 3
# edges, 3 unrelated keys, 3 deliveries.
#
# The key instead carries the pane's latest prompt-appearance EDGE sequence,
# where an edge is a LEVEL TRANSITION, not a call: the task's own registered
# `state` (lib/run-registry.sh, driven by push_wake's `set_task_state ...
# blocked` and agent-edge.sh's `follow_registry` mapping omp's idle/working
# status back to `running` once a prompt is actually answered and the agent
# resumes) already models exactly "still the same blocked period" vs. "a
# fresh one". `attn_track_claim` marks a new edge only when the state is NOT
# already `blocked` at the moment it is called — true for the first firing of
# a new occurrence, false for every repeat firing on a still-open one, since
# the first firing's own push_wake call flips the state to `blocked` before
# any repeat can observe it. attention-tick.sh's own tick loop is
# level-triggered instead (it re-examines the same still-blocked pane every
# interval) and must NEVER mark an edge itself — it only READS the latest
# edge sequence when it computes the same key, so the key it forms is stable
# for as long as the state stays `blocked`, and steps forward only once the
# task has genuinely left and re-entered that state.
attn_mark_edge() {                      # pane_id run_id task_id -> (best-effort, no output)
  local pane="$1" run_id="${2:-}" task_id="${3:-}"
  [ -n "$run_id" ] && [ -n "$task_id" ] || return 0
  command -v task_for_pane >/dev/null 2>&1 || return 0
  local state
  state="$(task_for_pane "$pane" 2>/dev/null | jq -r '.state // empty' 2>/dev/null)"
  [ "$state" = "blocked" ] && return 0   # still the SAME blocked period, not a new edge
  command -v append_event >/dev/null 2>&1 || return 0
  append_event "$run_id" "$task_id" "attn_prompt_edge" \
    "$(jq -nc --arg p "$pane" '{pane:$p}')" >/dev/null 2>&1 || true
}

attention_edge_sequence() {             # pane_id -> latest edge's registry sequence, or 0
  local pane="$1" n
  command -v _sql >/dev/null 2>&1 || { printf '0'; return 0; }
  n="$(_sql "SELECT max(sequence) FROM events WHERE type='attn_prompt_edge' AND json_extract(payload,'\$.pane')=$(_sq "$pane");" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

attention_dedupe_key() {                # pane_id [registered_birth] [command_text] -> key
  local pane="$1" birth="${2:-}" cmd cmd_norm cmd_hash edge
  if [ "$#" -ge 3 ]; then
    cmd="$3"
  else
    cmd="$(prompt_command_text "$pane" 2>/dev/null)"
  fi
  cmd_norm="$(printf '%s' "$cmd" | tr -s '[:space:]' ' ' | sed -E 's/^ +| +$//')"
  cmd_hash="$(printf '%s' "$cmd_norm" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"
  edge="$(attention_edge_sequence "$pane")"
  printf '%s__%s__%s__e%s\n' "$pane" "${birth:-nobirth}" "${cmd_hash:-nohash}" "${edge:-0}"
}

# The registered pane_birth (task_for_pane's own record), NOT a fresh LIVE
# read: a transient herdr CLI hiccup returning empty on one pass and a real
# value on the next must not change the key it feeds into — that is key
# drift by a different name. Empty when the pane is unregistered.
attention_registered_birth() {          # pane_id -> registered pane_birth, or empty
  local task
  task="$(task_for_pane "$1" 2>/dev/null)"
  printf '%s' "$task" | jq -r '.pane_birth // empty' 2>/dev/null
}

attn_track_claim() {                    # pane_id run_id task_id [prompt_id] -> 0 owns it
  local pane="$1" run_id="$2" task_id="$3" pid="${4:-}"
  [ "${HERDR_WAKE_LEGACY:-0}" = "1" ] && return 0
  attn_mark_edge "$pane" "$run_id" "$task_id"
  local birth key
  birth="$(attention_registered_birth "$pane")"
  key="$(attention_dedupe_key "$pane" "$birth")"
  claim_once "attn_track_${key}" "$run_id" "$task_id" "attention_tracking" \
    "$(jq -nc --arg p "$pane" --arg k "$key" --arg pid "$pid" '{pane:$p, key:$k, prompt_id:$pid}')"
}
