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
# instance and never reused) in ONE central store, not a file per worktree.
#
# ---- why SQLite, and not the JSON-file + JSONL spool this replaced ---------
# The file layout ("tasks/<task_id>.json" plus an append-only "events.jsonl"
# per run) satisfied "durable" and failed "reliable". Review correction 4
# named the exact gaps, and every one of them is a property a filesystem
# cannot give you without reimplementing a database badly:
#
#   * sequence numbers were count-then-append (`grep -c` the file, add one).
#     Two writers racing produce the SAME sequence, and neither notices.
#   * no dedup. An at-least-once producer that retried wrote the event twice.
#   * the consumer checkpoint tracked TASK STATE only, never the event stream,
#     so "replay every event exactly once" was impossible by construction —
#     a task changing state twice between two sweeps reported once.
#   * atomicity was per-file temp+rename. That makes ONE file consistent; it
#     cannot make a state change and its event log entry land together, which
#     is precisely the divergence a prior fix had to paper over by refusing to
#     log an event when the state write failed.
#
# SQLite gives all four as primitives: AUTOINCREMENT is a real monotonic
# counter, UNIQUE(event_id) is dedup, a transaction makes the state change and
# its event atomic *together*, and a cursor column is an event-stream
# checkpoint. WAL mode plus busy_timeout make concurrent hook firings safe
# instead of merely unlikely. It is also not a new dependency: sqlite3 ships
# with macOS.
#
# Sourced by spawn-task.sh (register), agent-hooks/claude-notify.sh and
# agent-hooks/omp-notify.sh (read + log), lib/reconcile.sh (sweep),
# lib/pane-guard.sh (task_for_pane), herdr-select.sh (approval lifecycle).
# Requires: sqlite3, jq.
set -uo pipefail

# ---- location ---------------------------------------------------------------
# HERDR_RUN_STATE_DIR keeps its old meaning (the registry root) so an operator
# override and every doc that mentions it still work; the database simply
# lives inside it. Never inside a worktree: worktree cleanup must not be able
# to delete the control plane.
run_state_root() {
  printf '%s\n' "${HERDR_RUN_STATE_DIR:-$HOME/.local/state/herdr/runs}"
}

registry_db() { printf '%s/registry.sqlite3\n' "$(run_state_root)"; }

# ---- SQL plumbing -----------------------------------------------------------
# Quote a value as a SQLite string literal by doubling embedded single quotes.
#
# This is the ONLY way a caller-supplied value may reach a statement. It is
# security-relevant, not stylistic: spawn-task.sh already shipped a verified
# shell-injection through an unescaped task label (a branch name containing a
# single quote), and a registry that interpolates a label straight into SQL
# reintroduces the same class one layer down — a label of
#   x'); DROP TABLE tasks; --
# would otherwise be executed. Doubling the quote is SQLite's own literal
# escape, so the value can contain quotes, newlines, semicolons, anything.
_sq() {
  local s=${1//\'/\'\'}
  printf "'%s'" "$s"
}

# Every connection sets busy_timeout and synchronous itself: they are
# per-connection, not stored in the file, and each call here is a fresh
# sqlite3 process. busy_timeout is what turns "two PostToolUse hooks fired at
# once" from an SQLITE_BUSY error into a short block — the old code had no
# equivalent and simply corrupted its own sequence numbers instead.
# synchronous=FULL because a control plane's whole job is to still be correct
# after the laptop slept or the process was killed; it costs an fsync per
# commit on a table that sees a handful of writes per minute.
#
# busy_timeout is set through the CLI's `.timeout` DOT-COMMAND, not
# `PRAGMA busy_timeout=N`, and that distinction is load-bearing: the PRAGMA
# form is a getter-setter and RETURNS A ROW, so it prints "5000" onto stdout
# ahead of the actual result. Every reader here then saw "5000\n<real value>"
# — read_task returned a number jq could not index, checkpoint_age_s parsed
# 5000 as an age, and set_task_state compared the literal string "5000
# starting" against its transition table and refused every legal move. The
# dot-command sets the same timeout and emits nothing. (`PRAGMA
# synchronous=FULL` is a pure setter and is silent, so it can stay inline.)
_sql() {
  sqlite3 -batch -noheader -cmd ".timeout ${HERDR_REGISTRY_BUSY_MS:-5000}" "$(registry_db)" \
    "PRAGMA synchronous=FULL; $*"
}

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---- schema -----------------------------------------------------------------
# Guarded per process, not per call: each script invocation is a fresh shell,
# so this runs at most once per process even though the DDL is idempotent.
_HERDR_REGISTRY_READY=0

_registry_schema_version() { printf '3\n'; }

registry_init() {
  [ "$_HERDR_REGISTRY_READY" = 1 ] && return 0
  local root db
  root="$(run_state_root)"
  db="$(registry_db)"
  mkdir -p "$root" || {
    printf 'run-registry: cannot create registry root %s\n' "$root" >&2
    return 1
  }
  # Task/run/worker/conductor identity plus every reconciliation event lives
  # here — same "force 0700, don't trust a first-runner's umask" reasoning
  # as the Slack bridge's state dir (see herdr-notify.sh's reg_dir comment).
  chmod 700 "$root" 2>/dev/null || true

  # journal_mode is persisted in the database header, so it is set here rather
  # than in _sql — WAL is what lets the reconcile sweep read while a hook
  # writes, instead of the two serializing on a whole-file lock.
  if ! sqlite3 -batch "$db" "
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=${HERDR_REGISTRY_BUSY_MS:-5000};

CREATE TABLE IF NOT EXISTS schema_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- task_id is the PRIMARY KEY, deliberately. Id generation is
-- timestamp+pid+RANDOM and this file's previous header admitted it is 'not
-- collision-proof across concurrent spawns in the same second'. Under the old
-- file layout a collision silently OVERWROTE the earlier task's registration,
-- quietly detaching a live worker from its pane-birth fingerprint (which
-- disables recycled-pane refusal for it — a safety regression that produced no
-- error). As a primary key the same collision now fails the INSERT loudly and
-- register_task reports it.
CREATE TABLE IF NOT EXISTS tasks (
  task_id              TEXT PRIMARY KEY,
  run_id               TEXT NOT NULL,
  worker_id            TEXT NOT NULL DEFAULT '',
  conductor_id         TEXT NOT NULL DEFAULT '',
  conductor_pane_id    TEXT NOT NULL DEFAULT '',
  conductor_pane_birth TEXT NOT NULL DEFAULT '',
  pane_id              TEXT NOT NULL DEFAULT '',
  pane_birth           TEXT NOT NULL DEFAULT '',
  -- herdr's own agent_session (a claude/codex session id herdr reports
  -- natively; empty for omp today, and possibly empty briefly right after
  -- spawn before the agent has reported in). This is the identity that
  -- SURVIVES a herdr server crash+restart, unlike pane_birth/terminal_id,
  -- which herdr reissues for every pane it re-enumerates on reconnect even
  -- though the underlying agent process never died — see
  -- lib/reconcile.sh's corroboration check.
  agent_session        TEXT NOT NULL DEFAULT '',
  repo                 TEXT NOT NULL DEFAULT '',
  worktree             TEXT NOT NULL DEFAULT '',
  label                TEXT NOT NULL DEFAULT '',
  state                TEXT NOT NULL,
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS tasks_by_pane  ON tasks(pane_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS tasks_by_state ON tasks(state, updated_at);

-- sequence is a REAL monotonic counter (AUTOINCREMENT never reuses a value,
-- even after deletes), replacing count-then-append. event_id is UNIQUE so a
-- caller that retries an at-least-once delivery can pass the same id and get
-- dedup instead of a duplicate row.
CREATE TABLE IF NOT EXISTS events (
  sequence    INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id    TEXT NOT NULL UNIQUE,
  run_id      TEXT NOT NULL,
  task_id     TEXT NOT NULL DEFAULT '',
  type        TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  payload     TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS events_by_task ON events(task_id, sequence);

-- last_event_seq is the piece review correction 4 called out as missing: a
-- cursor over the EVENT STREAM, not just over task state. task_states keeps
-- the existing per-task 'already reported this transition' map so the report
-- behaviour operators are used to is unchanged.
CREATE TABLE IF NOT EXISTS checkpoints (
  conductor_id   TEXT PRIMARY KEY,
  last_event_seq INTEGER NOT NULL DEFAULT 0,
  task_states    TEXT NOT NULL DEFAULT '{}',
  updated_at     TEXT NOT NULL
);

-- The approval lifecycle review correction 6 asked for: 'an answer needs three
-- separate records: decision recorded / delivery attempted / delivery
-- confirmed-or-timed-out. Recording a choice before pressing must not imply it
-- was delivered.' Three nullable timestamps, so the difference between
-- 'decided but never delivered' and 'delivered and confirmed' is a queryable
-- fact rather than an inference from a log line.
CREATE TABLE IF NOT EXISTS approvals (
  approval_id    TEXT PRIMARY KEY,
  run_id         TEXT NOT NULL DEFAULT '',
  task_id        TEXT NOT NULL DEFAULT '',
  pane_id        TEXT NOT NULL DEFAULT '',
  prompt_id      TEXT NOT NULL DEFAULT '',
  choice         TEXT NOT NULL DEFAULT '',
  choice_text    TEXT NOT NULL DEFAULT '',
  decided_by     TEXT NOT NULL DEFAULT '',
  authority      TEXT NOT NULL DEFAULT '',
  policy_verdict TEXT NOT NULL DEFAULT '',
  command        TEXT NOT NULL DEFAULT '',
  decided_at     TEXT NOT NULL,
  attempted_at   TEXT,
  confirmed_at   TEXT,
  outcome        TEXT,
  detail         TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS approvals_by_pane ON approvals(pane_id, decided_at DESC);

INSERT OR IGNORE INTO schema_meta(key, value)
  VALUES ('schema_version', '$(_registry_schema_version)');
" >/dev/null 2>&1; then
    printf 'run-registry: failed to initialize %s\n' "$db" >&2
    return 1
  fi

  _HERDR_REGISTRY_READY=1
  _migrate_schema_v3
  _migrate_legacy_files
  return 0
}

# ---- schema v2 -> v3: add tasks.agent_session -------------------------------
# CREATE TABLE IF NOT EXISTS above only shapes a BRAND NEW database; an
# existing one (schema_version '2') already has a `tasks` table without this
# column, and IF NOT EXISTS is a no-op against it. Idempotent and safe to run
# on every registry_init() call: checks pragma_table_info before ALTERing, and
# schema_meta's INSERT OR REPLACE makes re-running after a partial failure
# harmless (it will just retry the ALTER, which itself no-ops once the column
# exists).
_migrate_schema_v3() {
  local has_col
  has_col=$(_sql "SELECT 1 FROM pragma_table_info('tasks') WHERE name='agent_session';" 2>/dev/null)
  if [ -z "$has_col" ]; then
    _sql "ALTER TABLE tasks ADD COLUMN agent_session TEXT NOT NULL DEFAULT '';" >/dev/null 2>&1
  fi
  _sql "INSERT OR REPLACE INTO schema_meta(key, value) VALUES ('schema_version', '3');" >/dev/null 2>&1
}

# ---- one-time import of the pre-SQLite file layout --------------------------
# A registry holding LIVE task state cannot simply be abandoned: dropping a
# running worker's registration is not a clean slate, it silently disables
# recycled-pane refusal for that worker (pane-guard.sh treats an unregistered
# pane as 'nothing to check against' and passes it through). So the old files
# are imported once, then left on disk untouched — deleting an operator's prior
# state is not this function's business, and keeping it makes the migration
# reversible by hand.
_migrate_legacy_files() {
  local root marker
  root="$(run_state_root)"
  marker=$(_sql "SELECT value FROM schema_meta WHERE key='legacy_import';" 2>/dev/null)
  [ -n "$marker" ] && return 0

  local tf j n=0
  while IFS= read -r tf; do
    [ -n "$tf" ] && [ -f "$tf" ] || continue
    j="$(cat "$tf" 2>/dev/null)"
    printf '%s' "$j" | jq -e . >/dev/null 2>&1 || continue   # skip a torn write
    local ti ri
    ti=$(printf '%s' "$j" | jq -r '.task_id // empty')
    ri=$(printf '%s' "$j" | jq -r '.run_id  // empty')
    [ -n "$ti" ] && [ -n "$ri" ] || continue
    # INSERT OR IGNORE: re-running the import must never clobber a task that
    # has since been updated through the new code path.
    _sql "INSERT OR IGNORE INTO tasks
      (task_id, run_id, worker_id, conductor_id, conductor_pane_id, conductor_pane_birth,
       pane_id, pane_birth, repo, worktree, label, state, created_at, updated_at)
      VALUES ($(_sq "$ti"), $(_sq "$ri"),
        $(_sq "$(printf '%s' "$j" | jq -r '.worker_id // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.conductor_id // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.conductor_pane_id // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.conductor_pane_birth // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.pane_id // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.pane_birth // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.repo // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.worktree // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.label // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.state // "lost"')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.created_at // ""')"),
        $(_sq "$(printf '%s' "$j" | jq -r '.updated_at // ""')"));" >/dev/null 2>&1 && n=$((n+1))
  done < <(find "$root" -mindepth 3 -maxdepth 3 -path '*/tasks/*.json' 2>/dev/null)

  # Legacy events keep their original event_id (`<run_id>_<seq>`), so the
  # UNIQUE constraint dedups them if this ever runs twice. Their sequence is
  # reassigned by AUTOINCREMENT — the old numbers were not trustworthy under
  # concurrency anyway, which is the whole reason for this migration.
  local ef line
  while IFS= read -r ef; do
    [ -n "$ef" ] && [ -f "$ef" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s' "$line" | jq -e . >/dev/null 2>&1 || continue
      local eid
      eid=$(printf '%s' "$line" | jq -r '.event_id // empty')
      [ -n "$eid" ] || continue
      _sql "INSERT OR IGNORE INTO events (event_id, run_id, task_id, type, occurred_at, payload)
        VALUES ($(_sq "$eid"),
          $(_sq "$(printf '%s' "$line" | jq -r '.run_id // ""')"),
          $(_sq "$(printf '%s' "$line" | jq -r '.task_id // ""')"),
          $(_sq "$(printf '%s' "$line" | jq -r '.type // "unknown"')"),
          $(_sq "$(printf '%s' "$line" | jq -r '.occurred_at // ""')"),
          $(_sq "$(printf '%s' "$line" | jq -c '.payload // {}')"));" >/dev/null 2>&1
    done < "$ef"
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name 'events.jsonl' 2>/dev/null)

  local cf cid
  while IFS= read -r cf; do
    [ -n "$cf" ] && [ -f "$cf" ] || continue
    cid="$(basename "$cf" .json)"
    j="$(cat "$cf" 2>/dev/null)"
    printf '%s' "$j" | jq -e . >/dev/null 2>&1 || continue
    _sql "INSERT OR IGNORE INTO checkpoints (conductor_id, last_event_seq, task_states, updated_at)
      VALUES ($(_sq "$cid"), 0, $(_sq "$(printf '%s' "$j" | jq -c .)"), $(_sq "$(_now_iso)"));" >/dev/null 2>&1
  done < <(find "$root/checkpoints" -maxdepth 1 -name '*.json' 2>/dev/null)

  _sql "INSERT OR REPLACE INTO schema_meta(key,value) VALUES ('legacy_import','$(_now_iso)');" >/dev/null 2>&1
  [ "$n" -gt 0 ] && printf 'run-registry: imported %s legacy task record(s) into %s\n' "$n" "$(registry_db)" >&2
  return 0
}

gen_id() {                              # <prefix> -> "<prefix>_<ts>_<pid>_<rand>"
  printf '%s_%s_%s_%s\n' "$1" "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$RANDOM"
}

# ---- task records -----------------------------------------------------------
# One JSON object per task, built in SQL so every reader sees identical field
# names whether it asked for one task or all of them.
_task_json_select() {
  printf "%s" "SELECT json_object(
    'schema', 3, 'run_id', run_id, 'task_id', task_id, 'worker_id', worker_id,
    'conductor_id', conductor_id, 'conductor_pane_id', conductor_pane_id,
    'conductor_pane_birth', conductor_pane_birth, 'pane_id', pane_id,
    'pane_birth', pane_birth, 'agent_session', agent_session, 'repo', repo,
    'worktree', worktree, 'label', label,
    'state', state, 'created_at', created_at, 'updated_at', updated_at) FROM tasks"
}

# conductor_pane_birth mirrors pane_birth but for the CONDUCTOR's pane, not
# the worker's: the push-wake edge (agent-hooks/claude-notify.sh) delivers
# INTO conductor_pane_id, and that pane id is exactly as recyclable as the
# worker's — a fingerprint recorded only for the worker side would leave the
# conductor-delivery direction with nothing to revalidate against.
register_task() {
  local run_id="$1" task_id="$2" worker_id="$3" conductor_id="$4" \
        conductor_pane_id="$5" conductor_pane_birth="$6" pane_id="$7" pane_birth="$8" \
        repo="$9" worktree="${10}" label="${11}"
  registry_init || return 1
  local at; at="$(_now_iso)"

  # Plain INSERT, not INSERT OR REPLACE: a task_id collision must be a visible
  # failure, not a silent overwrite of a live worker's registration. See the
  # tasks table comment in registry_init.
  if _sql "INSERT INTO tasks
      (task_id, run_id, worker_id, conductor_id, conductor_pane_id, conductor_pane_birth,
       pane_id, pane_birth, repo, worktree, label, state, created_at, updated_at)
      VALUES ($(_sq "$task_id"), $(_sq "$run_id"), $(_sq "$worker_id"), $(_sq "$conductor_id"),
        $(_sq "$conductor_pane_id"), $(_sq "$conductor_pane_birth"), $(_sq "$pane_id"),
        $(_sq "$pane_birth"), $(_sq "$repo"), $(_sq "$worktree"), $(_sq "$label"),
        'starting', $(_sq "$at"), $(_sq "$at"));" >/dev/null 2>&1; then
    append_event "$run_id" "$task_id" "registered" \
      "$(jq -nc --arg p "$pane_id" --arg l "$label" '{pane_id:$p, label:$l}')" >/dev/null 2>&1
    return 0
  fi
  printf 'run-registry: failed to register task %s (duplicate task_id, or database unwritable)\n' "$task_id" >&2
  return 1
}

# ---- lifecycle --------------------------------------------------------------
# Legal transitions. Review correction 2 listed enforcement as missing —
# "nothing stops `completed` -> `running`". That is not a cosmetic gap once
# anything trusts the state: a terminal task silently returning to `running`
# would be swept for liveness again and could be re-reported forever, and the
# approvals table below records decisions against a task whose state is
# supposed to be settled. So the table is enforced, and an illegal transition
# is refused with a diagnostic rather than written.
#
# `blocked` is deliberately NOT terminal even though it is reported like one:
# a worker waiting on a prompt resolves back to `running` all the time.
_legal_transition() {                   # from to -> 0 if allowed
  local from="$1" to="$2"
  [ "$from" = "$to" ] && return 0       # idempotent re-assert, always fine
  case "$from" in
    ''|starting) case "$to" in running|blocked|completed|failed|cancelled|lost) return 0 ;; esac ;;
    running)     case "$to" in blocked|completed|failed|cancelled|lost) return 0 ;; esac ;;
    blocked)     case "$to" in running|completed|failed|cancelled|lost) return 0 ;; esac ;;
    # Terminal. Nothing leaves these; `lost` in particular must not be
    # resurrected by a stale hook firing after the sweep already buried it.
    completed|failed|cancelled|lost) return 1 ;;
  esac
  return 1
}

set_task_state() {                      # run_id task_id state
  local run_id="$1" task_id="$2" state="$3"
  registry_init || return 1
  local attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    local cur
    cur=$(_sql "SELECT state FROM tasks WHERE task_id=$(_sq "$task_id") AND run_id=$(_sq "$run_id");" 2>/dev/null)
    if [ -z "$cur" ]; then
      printf 'run-registry: no task record for %s/%s\n' "$run_id" "$task_id" >&2
      return 1
    fi
    if ! _legal_transition "$cur" "$state"; then
      printf 'run-registry: refusing illegal transition %s -> %s for %s/%s\n' \
        "$cur" "$state" "$run_id" "$task_id" >&2
      return 1
    fi
    [ "$cur" = "$state" ] && return 0

    # The state change and its event land in ONE transaction, AND that
    # transaction is compare-and-swap on the "$cur" we just read (WHERE
    # ... AND state=$cur). Without the CAS guard, two reconcile sweeps
    # racing (e.g. a herdr-restart storm firing SessionStart AND the
    # PostToolUse interval hook back to back) both read the same "cur",
    # both pass the legality check above, and both used to COMMIT —
    # observed live as duplicate state_changed/lost_detected event pairs
    # for one task at the same timestamp. Gating the event INSERT on
    # `(SELECT changes())>0` (evaluated against the UPDATE immediately
    # above it, before the INSERT's own execution changes it again) makes
    # the loser's INSERT a no-op in the SAME transaction, instead of a
    # second write needing its own compensating check.
    local at eid changed
    at="$(_now_iso)"
    eid="$(gen_id ev)"
    changed=$(_sql "BEGIN IMMEDIATE;
      UPDATE tasks SET state=$(_sq "$state"), updated_at=$(_sq "$at")
        WHERE task_id=$(_sq "$task_id") AND run_id=$(_sq "$run_id") AND state=$(_sq "$cur");
      INSERT INTO events (event_id, run_id, task_id, type, occurred_at, payload)
        SELECT $(_sq "$eid"), $(_sq "$run_id"), $(_sq "$task_id"), 'state_changed', $(_sq "$at"),
          $(_sq "$(jq -nc --arg s "$state" --arg f "$cur" '{state:$s, from:$f}')")
        WHERE (SELECT changes()) > 0;
      COMMIT;
      SELECT changes();" 2>/dev/null)
    [ "$changed" = "1" ] && return 0
    # A concurrent writer already moved this row between our read and our
    # write. Loop: if they wrote the state we also wanted, the next
    # iteration's idempotent-reassert check (cur = state) returns success;
    # if they wrote something else, the legality check re-runs against the
    # NEW reality instead of blindly retrying a now-stale transition.
  done
  printf 'run-registry: state write for %s/%s lost the compare-and-swap race 3 times (concurrent writer contention)\n' \
    "$run_id" "$task_id" >&2
  return 1
}

# set_task_agent_session <run_id> <task_id> <agent_session>
#
# Best-effort metadata capture, deliberately NOT a lifecycle transition (no
# event, no state check) — herdr reports agent_session natively for
# claude/codex once the CLI has actually started, which is AFTER
# register_task() runs (spawn-task.sh registers the task the moment the pane
# EXISTS, before the agent inside it does). Call this once the agent is
# confirmed up (spawn-task.sh does so right where it flips starting->running)
# and again opportunistically from a reconcile sweep for any task still
# missing one — capturing it late is still useful, since it corroborates
# identity across the NEXT herdr restart, not this one. Empty is a legitimate,
# permanent answer for omp today; never treat empty as a caller mistake.
set_task_agent_session() {
  local run_id="$1" task_id="$2" agent_session="${3:-}"
  registry_init || return 1
  [ -n "$agent_session" ] || return 0
  _sql "UPDATE tasks SET agent_session=$(_sq "$agent_session")
    WHERE task_id=$(_sq "$task_id") AND run_id=$(_sq "$run_id") AND agent_session='';" >/dev/null 2>&1
}

# rebaseline_pane_birth <run_id> <task_id> <new_pane_birth> [reason]
#
# Corrects a task's recorded pane_birth fingerprint WITHOUT touching state or
# going through the lifecycle state machine — for when a pane's identity is
# corroborated as the SAME live agent process despite herdr minting it a new
# terminal_id. A herdr crash+restart reissues terminal_id for every pane it
# re-enumerates on reconnect; the process underneath never died, so this is a
# false-positive CLOSE, not a resurrection. Deliberately not set_task_state():
# `lost` stays genuinely terminal and non-resurrectable for real pane deaths
# (that invariant is the whole point of review correction 2) — this only ever
# runs on a task that was never marked lost in the first place, preventing the
# false positive instead of reopening a buried one. Logs an audited
# pane_birth_rebaselined event so the correction is a queryable fact, the same
# way an incident repair should be, not a silent field edit.
rebaseline_pane_birth() {
  local run_id="$1" task_id="$2" new_birth="$3" reason="${4:-}"
  registry_init || return 1
  local old_birth
  old_birth=$(_sql "SELECT pane_birth FROM tasks WHERE task_id=$(_sq "$task_id") AND run_id=$(_sq "$run_id");" 2>/dev/null)
  [ -n "$old_birth" ] || return 1
  [ "$old_birth" = "$new_birth" ] && return 0     # already current
  local at changed
  at="$(_now_iso)"
  changed=$(_sql "BEGIN IMMEDIATE;
    UPDATE tasks SET pane_birth=$(_sq "$new_birth"), updated_at=$(_sq "$at")
      WHERE task_id=$(_sq "$task_id") AND run_id=$(_sq "$run_id") AND pane_birth=$(_sq "$old_birth");
    COMMIT;
    SELECT changes();" 2>/dev/null)
  [ "$changed" = "1" ] || return 1
  append_event "$run_id" "$task_id" "pane_birth_rebaselined" \
    "$(jq -nc --arg old "$old_birth" --arg new "$new_birth" --arg reason "$reason" \
      '{old_pane_birth:$old, new_pane_birth:$new, reason:$reason}')" >/dev/null 2>&1
}

# append_event <run_id> <task_id> <type> [payload_json] [event_id]
#
# Supplying event_id makes the append IDEMPOTENT — the UNIQUE constraint turns
# a retry into a no-op instead of a duplicate row. That is what lets a caller
# implement at-least-once delivery (review correction 6) without the consumer
# having to dedup: retry with the same id as many times as you like.
append_event() {
  local run_id="$1" task_id="${2:-}" type="$3" payload="${4:-{\}}" eid="${5:-}"
  registry_init || return 1
  [ -n "$eid" ] || eid="$(gen_id ev)"
  printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || payload='{}'
  if _sql "INSERT OR IGNORE INTO events (event_id, run_id, task_id, type, occurred_at, payload)
      VALUES ($(_sq "$eid"), $(_sq "$run_id"), $(_sq "$task_id"), $(_sq "$type"),
        $(_sq "$(_now_iso)"), $(_sq "$payload"));" >/dev/null 2>&1; then
    return 0
  fi
  printf 'run-registry: failed to append event %s for %s/%s\n' "$type" "$run_id" "$task_id" >&2
  return 1
}

read_task() {                           # run_id task_id -> json (empty if absent)
  registry_init || return 1
  _sql "$(_task_json_select) WHERE run_id=$(_sq "$1") AND task_id=$(_sq "$2");" 2>/dev/null
}

# Find the most-recently-updated registered task whose WORKER pane is this
# pane id — used to revalidate a pane's birth fingerprint immediately before
# acting on it (herdr-select.sh's keypress; see lib/pane-guard.sh's
# require_pane_birth_match). Returns the task json, or empty if this pane was
# never registered (e.g. spawned via spawn-agent.sh, which does not use the
# registry) — a caller with nothing to validate against must fall back to
# its prior behavior, not invent a refusal.
task_for_pane() {                       # pane_id -> task json or empty
  registry_init || return 1
  _sql "$(_task_json_select) WHERE pane_id=$(_sq "$1") ORDER BY updated_at DESC LIMIT 1;" 2>/dev/null
}

# Find the most-recently-updated registered task working in this worktree —
# the lookup a completion recorder needs when the pane is already gone (the
# exact case that used to permanently mark a finished worker `lost`): the
# worktree path survives the pane, so completion evidence found on its branch
# can still be matched back to the registration it belongs to.
task_for_worktree() {                   # worktree_path -> task json or empty
  registry_init || return 1
  _sql "$(_task_json_select) WHERE worktree=$(_sq "$1") ORDER BY updated_at DESC LIMIT 1;" 2>/dev/null
}

# Every registered task as one compact JSON object per line.
#
# Replaces the old all_task_files(), which emitted FILE PATHS its caller then
# had to cat, JSON-validate (a torn write was a real possibility), and re-read
# field by field. One query returns every task consistently, and there is no
# torn-write case left to skip.
all_tasks_json() {
  registry_init || return 1
  _sql "$(_task_json_select) ORDER BY updated_at;" 2>/dev/null
}

# Remove terminal-state tasks older than max_age_days, and the events that
# belong to them. Nothing else prunes, so this is the only thing keeping the
# registry from growing forever on a long-lived host.
#
# Deliberately narrow, unchanged from the file-layout version: only the true
# TERMINAL states (completed/failed/cancelled/lost) are eligible —
# starting/running/blocked are left alone, and `blocked` in particular can
# still resolve, it is not a dead end. Date arithmetic is SQLite's own
# (julianday), which removes the BSD-vs-GNU `date -v`/`date -d` fallback pair
# the old implementation needed.
prune_completed_tasks() {               # max_age_days
  local days="$1"
  registry_init || return 1
  case "$days" in ''|*[!0-9]*) printf 'run-registry: prune_completed_tasks needs an integer day count\n' >&2; return 1 ;; esac
  _sql "BEGIN IMMEDIATE;
    DELETE FROM events WHERE task_id IN (
      SELECT task_id FROM tasks
       WHERE state IN ('completed','failed','cancelled','lost')
         AND julianday(updated_at) < julianday('now', '-${days} days'));
    DELETE FROM tasks
     WHERE state IN ('completed','failed','cancelled','lost')
       AND julianday(updated_at) < julianday('now', '-${days} days');
    COMMIT;" >/dev/null 2>&1
}

# ---- consumer checkpoints ---------------------------------------------------
# A conductor session that reads the registry needs to remember what it has
# already reported, or a reopened session re-announces the same completions
# forever. That cursor is CONDUCTOR state, not task state — it lives with the
# registry (never inside a worktree: cleanup must not reset it) and is keyed by
# conductor_id so two conductors watching the same host don't clobber each
# other's progress.
read_checkpoint() {                     # conductor_id -> task_states json (default {})
  registry_init || return 1
  local c
  c=$(_sql "SELECT task_states FROM checkpoints WHERE conductor_id=$(_sq "$1");" 2>/dev/null)
  if [ -z "$c" ] || ! printf '%s' "$c" | jq -e . >/dev/null 2>&1; then
    printf '{}'
  else
    printf '%s' "$c"
  fi
}

write_checkpoint() {                    # conductor_id task_states_json
  registry_init || return 1
  local j="$2"
  printf '%s' "$j" | jq -e . >/dev/null 2>&1 || j='{}'
  # updated_at advances on EVERY write, including a no-op pass, because
  # checkpoint_age_s below reads it as "when did this conductor last actually
  # check the registry" and interval-reconcile.sh throttles against that.
  if _sql "INSERT INTO checkpoints (conductor_id, last_event_seq, task_states, updated_at)
      VALUES ($(_sq "$1"), 0, $(_sq "$j"), $(_sq "$(_now_iso)"))
      ON CONFLICT(conductor_id) DO UPDATE SET
        task_states=excluded.task_states, updated_at=excluded.updated_at;" >/dev/null 2>&1; then
    return 0
  fi
  printf 'run-registry: failed to write checkpoint for %s — checkpoint_age_s will grow unbounded\n' "$1" >&2
  return 1
}

# Seconds since a conductor's checkpoint was last written, or a large number if
# it never has been. Computed in SQL rather than from a file mtime, so it
# survives the store being a database instead of a file per conductor.
checkpoint_age_s() {                    # conductor_id -> integer seconds
  registry_init || return 1
  local age
  age=$(_sql "SELECT CAST((julianday('now') - julianday(updated_at)) * 86400 AS INTEGER)
              FROM checkpoints WHERE conductor_id=$(_sq "$1");" 2>/dev/null)
  case "$age" in
    ''|*[!0-9-]*) printf '999999999\n' ;;
    *)            printf '%s\n' "$age" ;;
  esac
}

# ---- event-stream cursor ----------------------------------------------------
# The half of review correction 4 the file layout could not do at all: a
# consumer cursor over EVENTS, so "replay every event exactly once" is
# expressible. read_checkpoint's task_states map answers "what changed since I
# last looked"; this answers "which events have I never seen", which is a
# different question and the one an at-least-once producer needs.
events_since() {                        # conductor_id [limit] -> one event json per line
  registry_init || return 1
  local cid="$1" limit="${2:-500}"
  case "$limit" in ''|*[!0-9]*) limit=500 ;; esac
  _sql "SELECT json_object('sequence', e.sequence, 'event_id', e.event_id, 'run_id', e.run_id,
          'task_id', e.task_id, 'type', e.type, 'occurred_at', e.occurred_at,
          'payload', json(e.payload),
          'task_conductor_id', COALESCE(t.conductor_id, ''),
          'task_state', COALESCE(t.state, ''),
          'label', COALESCE(t.label, ''),
          'repo', COALESCE(t.repo, ''))
        FROM events e LEFT JOIN tasks t ON t.task_id = e.task_id AND t.run_id = e.run_id
        WHERE e.sequence > COALESCE(
          (SELECT last_event_seq FROM checkpoints WHERE conductor_id=$(_sq "$cid")), 0)
        ORDER BY e.sequence LIMIT $limit;" 2>/dev/null
}

# Advance the cursor to the highest sequence the consumer has actually
# processed. Separate from write_checkpoint on purpose: a consumer that read
# events but crashed before acting on them must be able to leave the cursor
# where it was and see them again.
advance_event_cursor() {                # conductor_id sequence
  registry_init || return 1
  local cid="$1" seq="$2"
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  _sql "INSERT INTO checkpoints (conductor_id, last_event_seq, task_states, updated_at)
      VALUES ($(_sq "$cid"), $seq, '{}', $(_sq "$(_now_iso)"))
      ON CONFLICT(conductor_id) DO UPDATE SET
        last_event_seq=MAX(checkpoints.last_event_seq, excluded.last_event_seq),
        updated_at=excluded.updated_at;" >/dev/null 2>&1
}

# touch_checkpoint_clock <conductor_id>
#
# Advance ONLY the checkpoint's updated_at — the throttle clock
# checkpoint_age_s reads — without acknowledging anything. This is what a
# DEFERRED-delivery reconciliation pass (agent-hooks/omp-reconcile.sh
# --defer-ack) writes at prepare time: the sweep DID run (so the interval
# throttle must reset, or every subsequent tool_result re-sweeps), but the
# report has not been delivered yet, so neither task_states nor the event
# cursor may move. write_checkpoint cannot express that — it conflates the
# clock with the acknowledgment.
touch_checkpoint_clock() {              # conductor_id
  registry_init || return 1
  _sql "INSERT INTO checkpoints (conductor_id, last_event_seq, task_states, updated_at)
      VALUES ($(_sq "$1"), 0, '{}', $(_sq "$(_now_iso)"))
      ON CONFLICT(conductor_id) DO UPDATE SET
        updated_at=excluded.updated_at;" >/dev/null 2>&1
}

# ack_reconcile <conductor_id> <task_states_json> <last_event_seq>
#
# Commit a prepared reconciliation report as DELIVERED: task_states map and
# event cursor together, in one transaction, only after the consumer confirmed
# the report actually reached its session. The cursor uses MAX() so a stale or
# replayed ack (at-least-once delivery retries with the same token) can never
# move the cursor BACKWARD and resurrect already-consumed events; a crash
# between delivery and ack leaves the cursor where it was, and the next pass
# redelivers — duplicates are possible by design, silent loss is not.
ack_reconcile() {                       # conductor_id task_states_json last_event_seq
  registry_init || return 1
  local cid="$1" j="$2" seq="$3"
  printf '%s' "$j" | jq -e . >/dev/null 2>&1 || j='{}'
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  _sql "INSERT INTO checkpoints (conductor_id, last_event_seq, task_states, updated_at)
      VALUES ($(_sq "$cid"), $seq, $(_sq "$j"), $(_sq "$(_now_iso)"))
      ON CONFLICT(conductor_id) DO UPDATE SET
        task_states=excluded.task_states,
        last_event_seq=MAX(checkpoints.last_event_seq, excluded.last_event_seq),
        updated_at=excluded.updated_at;" >/dev/null 2>&1
}

# ---- approval lifecycle (decided / attempted / confirmed) -------------------
# Review correction 6: "Recording the choice before pressing is good, but that
# record must not imply successful delivery." herdr-select.sh's existing audit
# write satisfied "decided" and then conflated it with "delivered", because
# there was nowhere to put the other two facts. These three functions are that
# somewhere. All are additive: a caller that only ever calls the first one
# behaves exactly as before, minus the false implication.
approval_decided() {                    # approval_id pane_id prompt_id choice choice_text decided_by authority policy_verdict command [run_id] [task_id]
  registry_init || return 1
  _sql "INSERT OR REPLACE INTO approvals
      (approval_id, pane_id, prompt_id, choice, choice_text, decided_by, authority,
       policy_verdict, command, run_id, task_id, decided_at)
      VALUES ($(_sq "$1"), $(_sq "$2"), $(_sq "$3"), $(_sq "$4"), $(_sq "$5"), $(_sq "$6"),
        $(_sq "$7"), $(_sq "$8"), $(_sq "$9"), $(_sq "${10:-}"), $(_sq "${11:-}"),
        $(_sq "$(_now_iso)"));" >/dev/null 2>&1
}

approval_attempted() {                  # approval_id
  registry_init || return 1
  _sql "UPDATE approvals SET attempted_at=$(_sq "$(_now_iso)") WHERE approval_id=$(_sq "$1");" >/dev/null 2>&1
}

# outcome is send-to-agent.sh's own vocabulary (submitted / unsubmitted /
# refused / …) so the record says what actually happened at the keyboard,
# not merely that something was tried.
approval_confirmed() {                  # approval_id outcome [detail]
  registry_init || return 1
  _sql "UPDATE approvals SET confirmed_at=$(_sq "$(_now_iso)"), outcome=$(_sq "$2"),
        detail=$(_sq "${3:-}") WHERE approval_id=$(_sq "$1");" >/dev/null 2>&1
}

# ---- interval-reconcile lock ------------------------------------------------
# A plain directory under run_state_root, used by
# agent-hooks/interval-reconcile.sh as an mkdir-based mutex around the
# throttled reconciliation pass. checkpoint_age_s-vs-interval is a
# check-then-act throttle, not atomic on its own — two PostToolUse hook
# firings close together can both observe "due" and both proceed, doubling
# the herdr pane list + full task scan.
#
# Still a directory rather than a SQLite transaction, deliberately: what needs
# serializing is the whole expensive sweep (a live `herdr pane list` plus a
# full task scan), not just the database writes at the end of it. mkdir is
# atomic on POSIX filesystems, so it makes a dependency-free mutex around
# work that happens mostly OUTSIDE the database.
reconcile_lock_dir() { printf '%s/reconcile.lock\n' "$(run_state_root)"; }
