#!/usr/bin/env bash
# lib/run-registry.sh — the central, durable run/task registry.
#
# Consensus review (2026-07-27, docs/control-plane-design.md) on the naive
# design this replaces: a bare pane_id is not a durable identity — herdr
# reuses pane ids after a pane closes, so a delayed wake or answer can land
# on an unrelated future process. And control-plane state must not live
# inside a worker's repo: a worktree cleanup deletes the queue, and a
# conductor watching ten repos has no single authoritative inbox.
#
# So: every task gets a registered identity (run/task/worker/conductor id,
# plus a pane BIRTH fingerprint — herdr's own terminal_id, unique per pane
# instance and never reused) in ONE central directory, not a file per
# worktree.
#
# Sourced by spawn-task.sh (register) and agent-hooks/claude-notify.sh (read,
# to find the conductor to wake and to log the wake event). Requires: jq.
#
# KNOWN GAPS — this is the SHAPE of a durable registry for a single worker,
# not the full reliability story a multi-worker fleet needs. Documented, not
# solved here (see docs/control-plane-design.md, "designed but not built"):
#   - id generation is date+pid+RANDOM: not collision-proof across concurrent
#     spawns on the same host in the same second
#   - task-file writes are NOT atomic (no lock, no temp-file+rename+fsync)
#   - event sequence numbers are best-effort (count-then-append), not a real
#     monotonic counter under concurrent writers
#   - no consumer checkpoints, no dedup, no reconciliation sweep, no leases
set -uo pipefail

run_state_root() {
  printf '%s\n' "${HERDR_RUN_STATE_DIR:-$HOME/.local/state/herdr/runs}"
}

run_dir()     { printf '%s/%s\n' "$(run_state_root)" "$1"; }        # run_id
tasks_dir()   { printf '%s/tasks\n' "$(run_dir "$1")"; }             # run_id
task_file()   { printf '%s/%s.json\n' "$(tasks_dir "$1")" "$2"; }    # run_id task_id
events_file() { printf '%s/events.jsonl\n' "$(run_dir "$1")"; }      # run_id

gen_id() {                              # <prefix> -> "<prefix>_<ts>_<pid>_<rand>"
  printf '%s_%s_%s_%s\n' "$1" "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$RANDOM"
}

# Register a new task. Writes tasks/<task_id>.json with state=starting.
register_task() {
  local run_id="$1" task_id="$2" worker_id="$3" conductor_id="$4" \
        conductor_pane_id="$5" pane_id="$6" pane_birth="$7" \
        repo="$8" worktree="$9" label="${10}"
  mkdir -p "$(tasks_dir "$run_id")"
  jq -n \
    --argjson schema 1 \
    --arg run_id "$run_id" --arg task_id "$task_id" --arg worker_id "$worker_id" \
    --arg conductor_id "$conductor_id" --arg conductor_pane_id "$conductor_pane_id" \
    --arg pane_id "$pane_id" --arg pane_birth "$pane_birth" \
    --arg repo "$repo" --arg worktree "$worktree" --arg label "$label" \
    --arg state "starting" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:$schema, run_id:$run_id, task_id:$task_id, worker_id:$worker_id,
      conductor_id:$conductor_id, conductor_pane_id:$conductor_pane_id,
      pane_id:$pane_id, pane_birth:$pane_birth, repo:$repo, worktree:$worktree,
      label:$label, state:$state, created_at:$at, updated_at:$at}' \
    > "$(task_file "$run_id" "$task_id")"
}

# Transition a task's lifecycle state and record the transition as an event.
# Suggested states: starting running blocked completed failed cancelled lost
set_task_state() {                      # run_id task_id state
  local run_id="$1" task_id="$2" state="$3" f tmp
  f="$(task_file "$run_id" "$task_id")"
  [ -f "$f" ] || { echo "run-registry: no task file for $run_id/$task_id" >&2; return 1; }
  tmp="${f}.tmp.$$"
  jq --arg state "$state" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.state=$state | .updated_at=$at' "$f" > "$tmp" && mv "$tmp" "$f"
  append_event "$run_id" "$task_id" "state_changed" "{\"state\":\"$state\"}"
}

# Append one event to the run's CENTRAL events.jsonl (not the repo). Sequence
# is best-effort (see KNOWN GAPS above) — good enough to order a single
# worker's own events, not a promise under concurrent writers.
append_event() {                        # run_id task_id type payload_json
  local run_id="$1" task_id="$2" type="$3" payload="${4:-{\}}" ef seq
  ef="$(events_file "$run_id")"
  mkdir -p "$(run_dir "$run_id")"
  seq=$(( $(grep -c . "$ef" 2>/dev/null || echo 0) + 1 ))
  jq -nc --arg run_id "$run_id" --arg task_id "$task_id" --arg type "$type" \
     --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson seq "$seq" \
     --argjson payload "$payload" \
     '{event_id: ($run_id + "_" + ($seq|tostring)), run_id:$run_id, task_id:$task_id,
       sequence:$seq, type:$type, occurred_at:$at, payload:$payload}' \
    >> "$ef"
}

read_task() { cat "$(task_file "$1" "$2")" 2>/dev/null; }   # run_id task_id -> json
