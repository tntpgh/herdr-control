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
#
# conductor_pane_birth mirrors pane_birth but for the CONDUCTOR's pane, not
# the worker's: the push-wake edge (agent-hooks/claude-notify.sh) delivers
# INTO conductor_pane_id, and that pane id is exactly as recyclable as the
# worker's — a fingerprint recorded only for the worker side would leave the
# conductor-delivery direction with nothing to revalidate against.
register_task() {
  local run_id="$1" task_id="$2" worker_id="$3" conductor_id="$4" \
        conductor_pane_id="$5" conductor_pane_birth="$6" pane_id="$7" pane_birth="$8" \
        repo="$9" worktree="${10}" label="${11}"
  local f tmp
  f="$(task_file "$run_id" "$task_id")"
  tmp="${f}.tmp.$$"
  # Atomic write, same pattern as set_task_state/write_checkpoint below: jq
  # writes to a pid-suffixed temp file in the SAME directory, then mv (an
  # atomic rename on POSIX filesystems) into place. This used to be a bare
  # `jq -n ... > "$(task_file ...)"`, which truncates the target to zero
  # bytes BEFORE jq produces any output — a concurrent reader racing the
  # write window (task_for_pane, the reconcile sweep) could observe a
  # truncated/empty task file instead of either "not registered yet" (fine)
  # or the complete record (fine). Neither mkdir -p nor the write itself was
  # checked either, so a failure here (disk full, permissions) used to
  # silently leave no usable task file with no error anywhere; both are
  # checked now.
  if mkdir -p "$(tasks_dir "$run_id")" && jq -n \
    --argjson schema 1 \
    --arg run_id "$run_id" --arg task_id "$task_id" --arg worker_id "$worker_id" \
    --arg conductor_id "$conductor_id" --arg conductor_pane_id "$conductor_pane_id" \
    --arg conductor_pane_birth "$conductor_pane_birth" \
    --arg pane_id "$pane_id" --arg pane_birth "$pane_birth" \
    --arg repo "$repo" --arg worktree "$worktree" --arg label "$label" \
    --arg state "starting" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:$schema, run_id:$run_id, task_id:$task_id, worker_id:$worker_id,
      conductor_id:$conductor_id, conductor_pane_id:$conductor_pane_id,
      conductor_pane_birth:$conductor_pane_birth,
      pane_id:$pane_id, pane_birth:$pane_birth, repo:$repo, worktree:$worktree,
      label:$label, state:$state, created_at:$at, updated_at:$at}' \
    > "$tmp" && mv "$tmp" "$f"; then
    return 0
  else
    rm -f "$tmp"
    echo "run-registry: failed to write task file for $run_id/$task_id" >&2
    return 1
  fi
}

# Transition a task's lifecycle state and record the transition as an event.
# Suggested states: starting running blocked completed failed cancelled lost
set_task_state() {                      # run_id task_id state
  local run_id="$1" task_id="$2" state="$3" f tmp
  f="$(task_file "$run_id" "$task_id")"
  [ -f "$f" ] || { echo "run-registry: no task file for $run_id/$task_id" >&2; return 1; }
  tmp="${f}.tmp.$$"
  # append_event must NOT fire on a failed state write — it used to run
  # unconditionally as a separate statement, so a torn/failed jq or mv left
  # events.jsonl permanently claiming a transition that never actually
  # landed in the task file. The two sources of truth this registry is
  # built around could silently diverge with no error surfaced anywhere.
  if jq --arg state "$state" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.state=$state | .updated_at=$at' "$f" > "$tmp" && mv "$tmp" "$f"; then
    append_event "$run_id" "$task_id" "state_changed" "{\"state\":\"$state\"}"
  else
    rm -f "$tmp"
    echo "run-registry: failed to write state for $run_id/$task_id — event NOT logged" >&2
    return 1
  fi
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

# Find the most-recently-updated registered task whose WORKER pane is this
# pane id — used to revalidate a pane's birth fingerprint immediately before
# acting on it (herdr-select.sh's keypress; see lib/pane-guard.sh's
# require_pane_birth_match). Returns the task json, or empty if this pane was
# never registered (e.g. spawned via spawn-agent.sh, which does not use the
# registry) — a caller with nothing to validate against must fall back to
# its prior behavior, not invent a refusal.
task_for_pane() {                       # pane_id -> task json (latest updated_at) or empty
  local pane="$1" best="" best_ts=""
  while IFS= read -r tf; do
    [ -n "$tf" ] && [ -f "$tf" ] || continue
    local j p ts
    j="$(cat "$tf" 2>/dev/null)"
    printf '%s' "$j" | jq -e . >/dev/null 2>&1 || continue
    p=$(printf '%s' "$j" | jq -r '.pane_id // empty')
    [ "$p" = "$pane" ] || continue
    ts=$(printf '%s' "$j" | jq -r '.updated_at // empty')
    if [ -z "$best_ts" ] || [[ "$ts" > "$best_ts" ]]; then
      best="$j"; best_ts="$ts"
    fi
  done < <(all_task_files)
  printf '%s' "$best"
}

# All registered task files across every run, oldest run dirs included — the
# reconciliation sweep (agent-hooks/session-reconcile.sh) needs every task,
# not just the ones from the run_id a caller happens to know about.
all_task_files() {                      # -> one task-file path per line
  find "$(run_state_root)" -mindepth 3 -maxdepth 3 -path '*/tasks/*.json' 2>/dev/null
}

# Prune terminal-state task files older than a max age. Nothing else in this
# registry ever removes a task file — all_task_files() above walks every
# task that has ever been registered, forever, so run_state_root grows
# without bound on a long-lived host. Deliberately narrow: a file is removed
# only if BOTH its state is one of the true TERMINAL states from
# set_task_state's suggested list (completed/failed/cancelled/lost —
# starting/running/blocked are left alone; "blocked" in particular can still
# resolve, it's not a dead end) AND its updated_at is older than
# max_age_days. This is not a general GC subsystem: it doesn't touch
# events.jsonl, run directories, or checkpoints, just individual task files
# whose terminal transition happened long enough ago that no reader still
# needs them.
prune_completed_tasks() {               # max_age_days -> removes old terminal task files
  local max_age_days="$1" cutoff
  # Same idiom as task_for_pane's `[[ "$ts" > "$best_ts" ]]`: ISO-8601 UTC
  # timestamps (this registry's only timestamp format, see date -u
  # +%Y-%m-%dT%H:%M:%SZ throughout) sort lexicographically in the same order
  # they sort chronologically, so a plain string compare against a cutoff
  # computed the same way avoids parsing timestamps back into epoch seconds
  # (and the BSD/GNU `date` flag differences that would come with it).
  cutoff=$(date -u -v-"${max_age_days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "-${max_age_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  [ -n "$cutoff" ] || { echo "run-registry: prune_completed_tasks could not compute cutoff date" >&2; return 1; }
  while IFS= read -r tf; do
    [ -n "$tf" ] && [ -f "$tf" ] || continue
    local j state updated_at
    j="$(cat "$tf" 2>/dev/null)"
    printf '%s' "$j" | jq -e . >/dev/null 2>&1 || continue   # skip a torn write
    state=$(printf '%s' "$j" | jq -r '.state // empty')
    case "$state" in
      completed|failed|cancelled|lost) ;;
      *) continue ;;
    esac
    updated_at=$(printf '%s' "$j" | jq -r '.updated_at // empty')
    [ -n "$updated_at" ] && [[ "$updated_at" < "$cutoff" ]] && rm -f "$tf"
  done < <(all_task_files)
}

# ---- consumer checkpoints (SessionStart reconciliation) ---------------------
# A conductor session that reads the registry needs to remember what it has
# already reported, or a reopened session re-announces the same completions
# forever. That cursor is CONDUCTOR state, not task state — it lives beside
# the registry (never inside a worktree: cleanup must not reset it) and is
# keyed by conductor_id, one file per conductor so two conductors watching
# the same host don't clobber each other's progress.
checkpoints_dir() { printf '%s/checkpoints\n' "$(run_state_root)"; }
checkpoint_file() { printf '%s/%s.json\n' "$(checkpoints_dir)" "$1"; }  # conductor_id

read_checkpoint() {                     # conductor_id -> json object (default {})
  local f c
  f="$(checkpoint_file "$1")"
  c="$(cat "$f" 2>/dev/null)"
  if [ -z "$c" ] || ! printf '%s' "$c" | jq -e . >/dev/null 2>&1; then
    printf '{}'
  else
    printf '%s' "$c"
  fi
}

write_checkpoint() {                    # conductor_id json -> writes atomically
  local f tmp
  f="$(checkpoint_file "$1")"
  tmp="${f}.tmp.$$"
  # checkpoint_age_s (below) reads this file's mtime as "when did this
  # conductor last actually check the registry", and interval-reconcile.sh
  # throttles its expensive work against that age. If this write fails
  # (disk full, permissions) the mtime never advances, so the throttle
  # fails OPEN — it treats itself as perpetually due — rather than closed.
  # Not dangerous on its own, but previously silent: nothing printed
  # anywhere, so a stuck checkpoint looked identical to a healthy one with
  # nothing new to report. mkdir -p and the write are both checked now, and
  # either failing prints one diagnostic line to stderr.
  if mkdir -p "$(checkpoints_dir)" && printf '%s' "$2" > "$tmp" && mv "$tmp" "$f"; then
    return 0
  else
    rm -f "$tmp"
    echo "run-registry: failed to write checkpoint for $1 — checkpoint_age_s will grow unbounded" >&2
    return 1
  fi
}

# Seconds since a conductor's checkpoint was last written, or a large number
# if it has never been written. write_checkpoint runs on EVERY reconciliation
# pass (even a no-op one), so its mtime doubles as "when did this conductor
# last actually check the registry" — agent-hooks/interval-reconcile.sh
# throttles its expensive work (a live `herdr pane list` + a full task scan)
# against this instead of keeping a second timestamp file to stay in sync
# with.
checkpoint_age_s() {                    # conductor_id -> integer seconds
  local f mtime now
  f="$(checkpoint_file "$1")"
  [ -f "$f" ] || { printf '999999999\n'; return 0; }
  mtime=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0)
  now=$(date -u +%s)
  printf '%s\n' "$(( now - mtime ))"
}

# ---- interval-reconcile lock ------------------------------------------------
# A plain directory under run_state_root, used by
# agent-hooks/interval-reconcile.sh as an mkdir-based mutex around the
# throttled reconciliation pass. checkpoint_age_s-vs-interval is a
# check-then-act throttle, not atomic on its own — two PostToolUse hook
# firings close together can both observe "due" and both proceed, doubling
# the herdr pane list + full task scan and racing on the same task-file
# writes. mkdir is atomic on POSIX filesystems (exactly one caller ever
# wins the "did not exist, now does" transition), so it makes a
# dependency-free mutex without needing flock or a PID file.
reconcile_lock_dir() { printf '%s/reconcile.lock\n' "$(run_state_root)"; }
