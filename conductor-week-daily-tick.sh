#!/usr/bin/env bash
# conductor-week-daily-tick.sh — docs/design/weekly-conductor-authorization.md
# §(f): the unattended daily recovery tick named by the design but not
# built in the earlier pass of this feature. Reached by cron/a scheduled
# unattended invocation, never interactively by T. The actor is always the
# live conductor; --recover-label names one exact factory lane authorized by
# the weekly grant:
#
#   1. Revocation + grant lookup — conductor_week_admits (lib/run-
#      registry.sh) already folds "absent / expired / revoked" into one
#      refusal, exactly the §(f) item-1 contract: no grant means the tick
#      does not run --apply today and the label simply PAUSES; it never
#      falls back to requesting a human form.
#   2. Re-verifies the live-Main identity check (§(b)) via roles.main +
#      _is_live (duplicated from conductor-handover.sh's own copy —
#      neither file exports it as a shared lib function; mirrors the
#      exact rc 0/1/2 live/gone/indeterminate contract, fails closed on 2).
#   3. Target-label scope is covered by step 1's conductor_week_admits
#      call. An unlisted factory lane pauses rather than minting a token.
#   4. Mints a brand-new, single-use redemption token clamped to the
#      grant's own expires_at (REVIEW-GRANT-9ac2fc4: never passes the
#      bare weekly grant command_id onward).
#   5. Invokes owner-lease-recover.py --conductor-grant <token>, which
#      independently re-derives and enforces
#      min(now + ol.MAX_TTL_S, grant.expires_at) itself — this script
#      never computes or passes a lifecycle bound directly.
#
#   bash conductor-week-daily-tick.sh --label conductor --project <proj> \
#     --recover-label <approved-factory-label> --pane-id <own-pane> --pane-birth <own-birth> \
#     [--apply]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
. "$HERE/lib/run-registry.sh"
. "$HERE/lib/pane-guard.sh"

label="" project="" recover_label="" pane_id="" pane_birth="" apply=0
while [ $# -gt 0 ]; do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --label=*) label="${1#--label=}"; shift ;;
    --project) project="$2"; shift 2 ;;
    --project=*) project="${1#--project=}"; shift ;;
    --recover-label) recover_label="$2"; shift 2 ;;
    --recover-label=*) recover_label="${1#--recover-label=}"; shift ;;
    --pane-id) pane_id="$2"; shift 2 ;;
    --pane-id=*) pane_id="${1#--pane-id=}"; shift ;;
    --pane-birth) pane_birth="$2"; shift 2 ;;
    --pane-birth=*) pane_birth="${1#--pane-birth=}"; shift ;;
    --apply) apply=1; shift ;;
    *) echo "conductor-week-daily-tick: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$label" ] && [ -n "$project" ] && [ -n "$recover_label" ] && [ -n "$pane_id" ] && [ -n "$pane_birth" ] || {
  echo "conductor-week-daily-tick: --label, --project, --recover-label, --pane-id, --pane-birth all required" >&2
  exit 2
}
[ "$label" = conductor ] || { echo "refused:actor_label"; exit 4; }

# §(b)'s own rc 0/1/2 liveness contract, duplicated verbatim from
# conductor-handover.sh (not a shared lib function there either).
_is_live() {       # pane birth -> 0 live / 1 confirmed gone / 2 indeterminate
  local pane="$1" birth="$2" live rc
  [ -n "$pane" ] || return 1
  live="$(pane_birth_now "$pane")"; rc=$?
  [ "$rc" = 0 ] || return 2
  [ -n "$live" ] || return 1
  if [ -z "$birth" ] || [ "$live" = "$birth" ]; then
    return 0
  fi
  return 1
}

registry_init || { echo "conductor-week-daily-tick: registry_init failed" >&2; exit 1; }

# ---- step 1+3: revocation, expiry, and recovery-label scope ----
grant_id="$(conductor_week_admits "$recover_label" 2>/dev/null)"; grant_rc=$?
if [ "$grant_rc" != 0 ] || [ -z "$grant_id" ]; then
  echo "paused:no_grant"
  exit 0
fi

# ---- step 2: live-Main re-verification, fresh every tick ----
_main_row_j="$(read_role main 2>/dev/null)"
if [ -z "$_main_row_j" ] || [ "$_main_row_j" = null ]; then
  echo "refused:no_live_main"
  exit 4
fi
_main_pane="$(printf '%s' "$_main_row_j" | jq -r '.pane_id // empty')"
_main_birth="$(printf '%s' "$_main_row_j" | jq -r '.pane_birth // empty')"
_main_live_rc=0
_is_live "$_main_pane" "$_main_birth" || _main_live_rc=$?
if [ "$_main_live_rc" != 0 ]; then
  echo "refused:no_live_main"
  exit 4
fi

# ---- step 4: mint a fresh, single-use redemption token, clamped ----
grant_expires_at="$(_sql "SELECT expires_at FROM task_authorizations WHERE command_id=$(_sq "$grant_id");")"
[ -n "$grant_expires_at" ] || { echo "refused:grant_row_unreadable"; exit 4; }
token_cmd="$(gen_id conductor_week_redemption)"
if ! mint_conductor_redemption "$token_cmd" "$grant_id" "$recover_label" "$grant_expires_at" >/dev/null 2>&1; then
  echo "refused:redemption_mint_failed"
  exit 4
fi

# ---- step 5: owner-lease-recover.py enforces its own clamp independently ----
mode=(); [ "$apply" = 1 ] && mode=(--apply)
out="$(HERDR_OWNER_LEASE_WRITER=1 python3 "$HERE/owner-lease-recover.py" \
  --label "$recover_label" --project "$project" --pane-id "$pane_id" --pane-birth "$pane_birth" \
  --conductor-grant "$token_cmd" "${mode[@]}")"
rc=$?
printf '%s\n' "$out"
exit "$rc"
