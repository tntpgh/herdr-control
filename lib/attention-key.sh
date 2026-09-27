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
# The key carries the pane's blocked PERIOD, from the same prompt_period
# (lib/prompt-parse.sh) that salts prompt_id: the registry sequence of the
# latest time a task on this pane LEFT `blocked`. It is stable for every repeat
# firing and every tick while a prompt stays open, and steps forward once the
# prompt is answered and the task has genuinely left `blocked`.
#
# It used to be a START marker instead (attn_prompt_edge, written by the
# hook's first firing when the task was not yet `blocked`). That raced every
# other reader at the one moment they all look: live 2026-09-26 (events
# 37680/37682), this controller's tick keyed the prompt before the hook marked
# its edge, the two claims got different keys, and the conductor was woken
# twice for one prompt. It also missed re-asks whenever agent-edge.sh had
# already flipped the task to `blocked` before the hook ran. A close is
# written long before the next prompt paints, so both readers agree.

attention_dedupe_key() {                # pane_id [registered_birth] [command_text] -> key
  local pane="$1" birth="${2:-}" cmd cmd_norm cmd_hash period
  if [ "$#" -ge 3 ]; then
    cmd="$3"
  else
    cmd="$(prompt_command_text "$pane" 2>/dev/null)"
  fi
  cmd_norm="$(printf '%s' "$cmd" | tr -s '[:space:]' ' ' | sed -E 's/^ +| +$//')"
  cmd_hash="$(printf '%s' "$cmd_norm" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"
  period="$(prompt_period "$pane")"
  printf '%s__%s__%s__p%s\n' "$pane" "${birth:-nobirth}" "${cmd_hash:-nohash}" "${period:-0}"
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
  local birth key
  birth="$(attention_registered_birth "$pane")"
  key="$(attention_dedupe_key "$pane" "$birth")"
  claim_once "attn_track_${key}" "$run_id" "$task_id" "attention_tracking" \
    "$(jq -nc --arg p "$pane" --arg k "$key" --arg pid "$pid" '{pane:$p, key:$k, prompt_id:$pid}')"
}
