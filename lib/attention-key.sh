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
attention_dedupe_key() {                # pane_id [registered_birth] [command_text] -> key
  local pane="$1" birth="${2:-}" cmd cmd_norm cmd_hash
  if [ "$#" -ge 3 ]; then
    cmd="$3"
  else
    cmd="$(prompt_command_text "$pane" 2>/dev/null)"
  fi
  cmd_norm="$(printf '%s' "$cmd" | tr -s '[:space:]' ' ' | sed -E 's/^ +| +$//')"
  cmd_hash="$(printf '%s' "$cmd_norm" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"
  printf '%s__%s__%s\n' "$pane" "${birth:-nobirth}" "${cmd_hash:-nohash}"
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
