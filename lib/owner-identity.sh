#!/usr/bin/env bash
# lib/owner-identity.sh — the record store for a registered long-lived
# owner/conductor session (docs/design/pretool-approval.md §13).
#
# One row binds an owner LABEL to three facts that must all hold together:
#   pane_id     the herdr pane the owner runs in;
#   pane_birth  that pane's herdr terminal_id at registration (lib/pane-guard.sh
#               pane_birth_now) — a later process given the same, recycled
#               pane id has a different birth, so it is a different identity;
#   session_id  the omp session id of the one running session (the hook reads
#               it from ctx.sessionManager.getSessionId(), never from env).
#
# Rows are never deleted. Revocation flips state to 'revoked' and the next
# registration for that label is a NEW row; the identity check reads the
# label's newest row, so history stays auditable in place. Partial unique
# indexes keep at most one ACTIVE row per label, per pane and per session,
# so two registrations racing for one pane cannot both land.
#
# A separate file beside the registry (owner-identities.sqlite3), never a
# registry table: nothing here migrates the live control-plane registry, the
# file does not exist until a human registers the first owner, and the
# enforcing check (lib/pretool-shadow.sh --owner) only ever READS it. Writes
# come only from owner-approval.sh (human-only; see that file) and the
# best-effort audit append below.
#
# Not a containment boundary (docs/approval-policy.md rule 7, design §12): a
# same-user process can write this file. lib/hook-approval-rules.tsv makes the
# file, its tables, and the scripts that write it human-only for every
# enforced session.
set -uo pipefail

_oi_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v run_state_root >/dev/null 2>&1 || . "$_oi_dir/run-registry.sh"

owner_identity_db() { printf '%s/owner-identities.sqlite3\n' "$(run_state_root)"; }

# Plain path and an ordinary connection, for the reason the hook gives for the
# registry (agent-hooks/omp-herdr-control.ts APPROVAL_READ_ARGS): a read-only
# connection cannot open a WAL database whose -wal/-shm files are absent.
# -bail: a multi-statement write stops at the first error, and the open
# transaction is rolled back when the connection closes.
_oi_sql() {
  sqlite3 -batch -bail -noheader -cmd ".timeout ${HERDR_OWNER_BUSY_MS:-3000}" "$(owner_identity_db)" "$@"
}

# Same shape as register-owner.sh's label rule (the remote Worker's
# OWNER_LABEL regex), so one label means one thing across both tables.
owner_label_valid() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]]; }
owner_session_valid() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; }
owner_pane_valid() { [[ "${1:-}" =~ ^[A-Za-z0-9]+:p[A-Za-z0-9]+$ ]]; }

owner_identity_init() {                 # create the file and schema (writers only)
  mkdir -p "$(run_state_root)" 2>/dev/null || return 1
  _oi_sql "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || return 1
  _oi_sql "CREATE TABLE IF NOT EXISTS owner_identities (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      label         TEXT NOT NULL,
      pane_id       TEXT NOT NULL,
      pane_birth    TEXT NOT NULL,
      session_id    TEXT NOT NULL,
      state         TEXT NOT NULL CHECK (state IN ('active','revoked')),
      registered_at TEXT NOT NULL,
      registered_by TEXT NOT NULL,
      revoked_at    TEXT NOT NULL DEFAULT '',
      revoked_by    TEXT NOT NULL DEFAULT '',
      revoke_reason TEXT NOT NULL DEFAULT '');
    CREATE UNIQUE INDEX IF NOT EXISTS owner_identities_active_label   ON owner_identities(label)      WHERE state='active';
    CREATE UNIQUE INDEX IF NOT EXISTS owner_identities_active_pane    ON owner_identities(pane_id)    WHERE state='active';
    CREATE UNIQUE INDEX IF NOT EXISTS owner_identities_active_session ON owner_identities(session_id) WHERE state='active';
    CREATE TABLE IF NOT EXISTS owner_events (
      seq     INTEGER PRIMARY KEY AUTOINCREMENT,
      at      TEXT NOT NULL,
      label   TEXT NOT NULL,
      kind    TEXT NOT NULL,
      payload TEXT NOT NULL);" >/dev/null 2>&1
}

# owner_identity_register <label> <pane> <birth> <session> <by>
#   0 registered; 1 invalid argument; 3 conflict (the label, pane or session
#   already has an ACTIVE row); 2 store unwritable. Never replaces a row.
owner_identity_register() {
  local label="$1" pane="$2" birth="$3" sid="$4" by="$5" at err
  owner_label_valid "$label" && owner_pane_valid "$pane" && owner_session_valid "$sid" && [ -n "$birth" ] || return 1
  owner_identity_init || return 2
  at="$(_now_iso)"
  err="$(_oi_sql "BEGIN IMMEDIATE;
    INSERT INTO owner_identities(label, pane_id, pane_birth, session_id, state, registered_at, registered_by)
      VALUES ($(_sq "$label"), $(_sq "$pane"), $(_sq "$birth"), $(_sq "$sid"), 'active', $(_sq "$at"), $(_sq "$by"));
    INSERT INTO owner_events(at, label, kind, payload)
      VALUES ($(_sq "$at"), $(_sq "$label"), 'registered',
        json_object('pane_id', $(_sq "$pane"), 'pane_birth', $(_sq "$birth"), 'session_id', $(_sq "$sid"), 'by', $(_sq "$by")));
    COMMIT;" 2>&1 >/dev/null)" && return 0
  case "$err" in *UNIQUE*) return 3 ;; esac
  return 2
}

# owner_identity_revoke <label> <reason> <by> -> 0 revoked; 1 no active row; 2 store error
owner_identity_revoke() {
  local label="$1" why="$2" by="$3" at n
  [ -f "$(owner_identity_db)" ] || return 1
  at="$(_now_iso)"
  n="$(_oi_sql "BEGIN IMMEDIATE;
    UPDATE owner_identities SET state='revoked', revoked_at=$(_sq "$at"), revoked_by=$(_sq "$by"), revoke_reason=$(_sq "$why")
      WHERE label=$(_sq "$label") AND state='active';
    INSERT INTO owner_events(at, label, kind, payload)
      SELECT $(_sq "$at"), $(_sq "$label"), 'revoked', json_object('by', $(_sq "$by"), 'reason', $(_sq "$why"))
      WHERE changes() = 1;
    SELECT changes();
    COMMIT;" 2>/dev/null)" || return 2
  [ "$n" = 1 ] && return 0
  return 1
}

# owner_identity_read <label> -> the label's NEWEST row as JSON on stdout.
#   rc 0 + empty output = no row for that label; rc != 0 = the store could not
#   be read (missing file, not a database, missing table, lock timeout). The
#   caller decides; the enforcing check treats every one of those as refusal.
owner_identity_read() {
  [ -f "$(owner_identity_db)" ] || return 4
  _oi_sql "SELECT json_object('id', id, 'label', label, 'pane_id', pane_id, 'pane_birth', pane_birth,
      'session_id', session_id, 'state', state, 'registered_at', registered_at, 'registered_by', registered_by,
      'revoked_at', revoked_at, 'revoked_by', revoked_by, 'revoke_reason', revoke_reason)
    FROM owner_identities WHERE label=$(_sq "$1") ORDER BY id DESC LIMIT 1;"
}

owner_identity_list() {                 # every row, newest first, one JSON object per line
  [ -f "$(owner_identity_db)" ] || return 0
  _oi_sql "SELECT json_object('id', id, 'label', label, 'pane_id', pane_id, 'pane_birth', pane_birth,
      'session_id', session_id, 'state', state, 'registered_at', registered_at, 'revoked_at', revoked_at,
      'revoke_reason', revoke_reason)
    FROM owner_identities ORDER BY id DESC;"
}

# Best-effort audit append (verdicts, refused registrations). Never creates the
# store: an audit row must not be the thing that brings it into existence.
owner_identity_audit() {                # label kind payload-json
  [ -f "$(owner_identity_db)" ] || return 0
  _oi_sql "INSERT INTO owner_events(at, label, kind, payload)
    VALUES ($(_sq "$(_now_iso)"), $(_sq "$1"), $(_sq "$2"), $(_sq "$3"));" >/dev/null 2>&1 || true
}
