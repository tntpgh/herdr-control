#!/usr/bin/env bash
# lib/claims.sh — advisory, TTL'd claims on a repo scope.
#
# The gap this closes, measured on 2026-09-22 across one working session:
#
#   * one pane nominally "in" thurber-os made real mutations in FIVE repos
#     (knowledge-base, tourguide, tntpgh-dev, herdr-control, ci-runner-fly).
#     Nothing scoped it, so nothing could have noticed a second pane doing the
#     same — the cross-repo system-reminder only nags AFTER the write.
#   * the branch-switch guard refused a `checkout -b` in ci-runner-fly while
#     reporting thurber-os, because it derives scope from the session's
#     STARTING cwd rather than from what is actually being touched.
#   * 6 worker tasks sat `stalled`/`ready_review` and 3 `lost` for 6-18 hours
#     with no owner and nothing reaping them.
#   * "is another pane already doing this?" was answerable only by querying
#     the task ledger BY HAND, after the fact.
#
# Every one of those is the same missing primitive: nothing is ever CLAIMED,
# so there is no arbitration and no owner to route anything to.
#
# ---- why this is a claim and not a lock ------------------------------------
# One machine, one human, no adversarial actor, and the human can always
# override. So a claim is ADVISORY: it tells you who else is here and why,
# it does not stop you. A hard lock would need deadlock handling, lock
# breaking, and an escalation path — all machinery for a failure mode
# (malicious or wedged peer) that does not exist here. What we actually
# needed was VISIBILITY at the moment of action, which advisory gives.
#
# TTL is the part that is not optional. A pane that crashes must not hold a
# repo forever; expiry IS the reaper, which is why the stalled-task graveyard
# above needs no separate sweeper process.
#
# ---- why it lives in the run registry --------------------------------------
# docs/state-storage-files-vs-sqlite.md §5: "Relational, queried,
# machine-global, many writers -> SQLite." Claims are all four — every pane on
# the host writes them, and the questions are relational ("who holds this
# repo", "which claims have expired", "is this scope a subset of that one").
# The registry is already exactly that store, already WAL, already has a
# busy_timeout, and already ships its own escaping discipline. A second store
# would be a second thing to reap, back up, and reason about.
#
# Requires: sqlite3, jq. Sourced by claim.sh, attention.sh.
set -uo pipefail

_CLAIMS_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=run-registry.sh
source "$_CLAIMS_HERE/run-registry.sh"   # registry_init, _sq, _sql, _now_iso, gen_id

# Default lease length. Deliberately short relative to how long real work
# takes: a claim is meant to be REFRESHED by the holder while it works (see
# claim_touch), so an abandoned one disappears in minutes rather than at the
# end of a workday. 30 minutes is long enough that a normal think-pause or a
# slow build does not drop it, short enough that a crashed pane is not still
# holding tntpgh-dev at midnight.
claims_default_ttl_s() { printf '%s\n' "${HERDR_CLAIM_TTL_S:-1800}"; }

# ---- schema v3 -> v4 --------------------------------------------------------
# Additive, and guarded by pragma_table_info the same way _migrate_schema_v3
# is, so it is safe on every init of an existing registry.
#
# scope is a repo PATH, canonicalized by the caller (claim.sh resolves it via
# git rev-parse --show-toplevel). Storing the path rather than a repo name is
# what makes a worktree and its main checkout distinguishable — they are
# different scopes and may be legitimately held by different panes, which is
# the entire point of the spawn-task.sh worktree pattern.
_CLAIMS_READY=0
claims_init() {
  [ "$_CLAIMS_READY" = 1 ] && return 0
  registry_init || return 1
  _sql "
CREATE TABLE IF NOT EXISTS claims (
  claim_id    TEXT PRIMARY KEY,
  scope       TEXT NOT NULL,
  pane_id     TEXT NOT NULL DEFAULT '',
  pane_birth  TEXT NOT NULL DEFAULT '',
  purpose     TEXT NOT NULL DEFAULT '',
  parent      TEXT NOT NULL DEFAULT '',
  claimed_at  TEXT NOT NULL,
  renewed_at  TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  released_at TEXT
);
-- Partial index on LIVE claims only: every hot query ('who holds this scope')
-- filters released_at IS NULL, and released rows are kept for audit, not for
-- lookup.
CREATE INDEX IF NOT EXISTS claims_live ON claims(scope, expires_at) WHERE released_at IS NULL;
INSERT OR REPLACE INTO schema_meta(key, value) VALUES ('schema_version', '4');
" >/dev/null 2>&1 || {
    printf 'claims: failed to initialize claims table\n' >&2
    return 1
  }
  _CLAIMS_READY=1
  return 0
}

# claims_expire — mark every lapsed claim released.
#
# Called at the top of every read AND every acquire, rather than from a cron:
# a claim that nobody ever asks about does not need reaping, and a claim that
# someone DOES ask about must be accurate at that instant. Doing it inline
# means there is no sweeper to install, supervise, or notice has died — the
# failure mode that produced the 18-hour stalled-task graveyard in the first
# place.
claims_expire() {
  claims_init || return 1
  _sql "UPDATE claims
           SET released_at = $(_sq "$(_now_iso)")
         WHERE released_at IS NULL
           AND expires_at <= $(_sq "$(_now_iso)");" >/dev/null 2>&1
}

# claim_holder <scope> -> json of the live claim, or empty.
claim_holder() {
  claims_expire
  _sql "SELECT json_object(
          'claim_id',   claim_id,
          'scope',      scope,
          'pane_id',    pane_id,
          'pane_birth', pane_birth,
          'purpose',    purpose,
          'parent',     parent,
          'claimed_at', claimed_at,
          'renewed_at', renewed_at,
          'expires_at', expires_at)
        FROM claims
        WHERE scope = $(_sq "$1") AND released_at IS NULL
        ORDER BY claimed_at ASC LIMIT 1;"
}

# claims_active [pane_id] -> one claim json per line (all, or just this pane's).
claims_active() {
  claims_expire
  local where="released_at IS NULL"
  [ -n "${1:-}" ] && where="$where AND pane_id = $(_sq "$1")"
  _sql "SELECT json_object(
          'claim_id',   claim_id,
          'scope',      scope,
          'pane_id',    pane_id,
          'purpose',    purpose,
          'parent',     parent,
          'claimed_at', claimed_at,
          'expires_at', expires_at)
        FROM claims WHERE $where ORDER BY scope ASC;"
}

# claim_acquire <scope> <pane_id> [purpose] [ttl_s] [parent_claim_id]
#
# Prints the claim json on success. On conflict prints the HOLDER's json to
# stdout and returns 2 — the caller decides, because this is advisory. The
# distinction matters for the caller's exit-code handling: 1 is "something
# broke", 2 is "someone else is here, and here is who".
#
# Re-acquiring a scope this pane already holds is a RENEWAL, not a conflict.
# That makes the call idempotent, which is what lets a guard call it on every
# invocation without the caller tracking whether it already claimed.
#
# ---- chaining --------------------------------------------------------------
# parent_claim_id expresses a sub-conductor: you may only delegate a scope you
# hold. Verified here rather than trusted, because a child scope that escapes
# its parent's is exactly how two conductors end up on the same repo believing
# they are disjoint. The rule is the whole multi-conductor design in one line:
# a child's scope must be inside its parent's, and the parent's claim must
# still be live.
claim_acquire() {
  local scope="$1" pane="$2" purpose="${3:-}" ttl="${4:-}" parent="${5:-}"
  claims_init || return 1
  [ -n "$scope" ] && [ -n "$pane" ] || { printf 'claim_acquire: scope and pane_id required\n' >&2; return 1; }
  [ -n "$ttl" ] || ttl="$(claims_default_ttl_s)"

  if [ -n "$parent" ]; then
    local prow pscope
    prow=$(_sql "SELECT scope FROM claims WHERE claim_id = $(_sq "$parent") AND released_at IS NULL;")
    [ -n "$prow" ] || { printf 'claim_acquire: parent claim %s is not live\n' "$parent" >&2; return 1; }
    pscope="$prow"
    # Subset test on paths: identical, or the child is a directory beneath it.
    case "$scope" in
      "$pscope"|"$pscope"/*) : ;;
      *) printf 'claim_acquire: scope %s is not within parent scope %s\n' "$scope" "$pscope" >&2; return 1 ;;
    esac
  fi

  local held held_pane
  held=$(claim_holder "$scope")
  if [ -n "$held" ]; then
    held_pane=$(printf '%s' "$held" | jq -r '.pane_id // ""')
    if [ "$held_pane" != "$pane" ]; then
      printf '%s\n' "$held"
      return 2
    fi
    claim_touch "$(printf '%s' "$held" | jq -r .claim_id)" "$ttl"
    claim_holder "$scope"
    return 0
  fi

  local id now expires
  id=$(gen_id claim)
  now=$(_now_iso)
  expires=$(_sql "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+$((ttl)) seconds');")
  _sql "INSERT INTO claims(claim_id, scope, pane_id, pane_birth, purpose, parent,
                           claimed_at, renewed_at, expires_at)
        VALUES ($(_sq "$id"), $(_sq "$scope"), $(_sq "$pane"), $(_sq "${HERDR_PANE_BIRTH:-}"),
                $(_sq "$purpose"), $(_sq "$parent"),
                $(_sq "$now"), $(_sq "$now"), $(_sq "$expires"));" >/dev/null 2>&1 || {
    printf 'claim_acquire: insert failed for %s\n' "$scope" >&2
    return 1
  }
  claim_holder "$scope"
}

# claim_touch <claim_id> [ttl_s] — push the expiry out. This is what a holder
# doing long work calls; without it the TTL would have to be set to the length
# of the longest imaginable job, which would defeat expiry as a reaper.
claim_touch() {
  claims_init || return 1
  local ttl="${2:-$(claims_default_ttl_s)}"
  _sql "UPDATE claims
           SET renewed_at = $(_sq "$(_now_iso)"),
               expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+$((ttl)) seconds')
         WHERE claim_id = $(_sq "$1") AND released_at IS NULL;" >/dev/null 2>&1
}

# claim_release <scope> <pane_id> — release only what this pane holds.
#
# Scoped to the caller's own pane deliberately: releasing someone else's claim
# is the one thing an advisory system must not let a peer do silently. A human
# overriding does it through claim.sh's explicit --force, which says so.
claim_release() {
  claims_init || return 1
  _sql "UPDATE claims
           SET released_at = $(_sq "$(_now_iso)")
         WHERE scope = $(_sq "$1") AND pane_id = $(_sq "$2") AND released_at IS NULL;" >/dev/null 2>&1
}

claim_release_force() {
  claims_init || return 1
  _sql "UPDATE claims
           SET released_at = $(_sq "$(_now_iso)")
         WHERE scope = $(_sq "$1") AND released_at IS NULL;" >/dev/null 2>&1
}

# claim_release_pane <pane_id> — drop everything a pane holds, for a clean exit.
claim_release_pane() {
  claims_init || return 1
  _sql "UPDATE claims
           SET released_at = $(_sq "$(_now_iso)")
         WHERE pane_id = $(_sq "$1") AND released_at IS NULL;" >/dev/null 2>&1
}

# claims_conflicts — scopes where a live claim is held by a pane OTHER than
# the one named. The "am I duplicating someone" question, answered in SQL
# instead of by hand.
claims_conflicts() {                     # pane_id -> one json per line
  claims_expire
  _sql "SELECT json_object('scope', scope, 'pane_id', pane_id, 'purpose', purpose, 'expires_at', expires_at)
        FROM claims
        WHERE released_at IS NULL AND pane_id <> $(_sq "$1")
        ORDER BY scope ASC;"
}
