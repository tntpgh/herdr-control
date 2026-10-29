#!/usr/bin/env bash
# grant-resident-escalation.sh <repo> <max_tier> [--ttl-hours N]
#
# docs/design/resident-launch-grant.md — mints a STANDING resident escalation
# launch grant for <repo>. HUMAN-ONLY: this is the one place live process
# ancestry is ever proven for this feature, at MINT time rather than at
# every later unattended spawn. Run this from a real, live, conductor-
# eligible pane for <repo> — an unattended caller (no herdr-pane ancestry)
# is refused the exact same way spawn-task.sh itself refuses one.
#
# <max_tier>: one of fast|standard|deep|frontier (lib/escalation.sh's own
# ladder, HERDR_ESCALATION_LADDER). The grant admits every tier AT OR BELOW
# <max_tier> in that ladder's order, not a hand-picked subset — see
# docs/design/resident-launch-grant.md's "Pilot scope: two options" for what
# each ceiling actually authorizes before picking one.
#
# --ttl-hours N: validity window in hours, hard-capped at 24 (the grant's
# own hard-cap regardless of what is asked for) and defaulting to 24.
# Minting again before expiry does NOT extend an existing grant to a new
# window — the stored claims are content-addressed; re-minting the exact
# same (repo, job_classes, max_tier) within its own validity window returns
# the SAME row untouched, never widening it (lib/task-authorization.py's
# accept_resident).
#
# Prints the minted grant's JSON (same `public()` shape every other
# task_authorizations reader returns) on success. Mints nothing, grants no
# authority, and changes no running behavior until lib/escalation.sh's own
# pre-flight check (_esc_check_launch_authority) is reached by a REAL
# no-progress escalation for THIS repo — this script's only side effect is
# the one new row.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"
. "$here/lib/repo-root.sh"
. "$here/lib/escalation.sh"

repo="${1:-}"
max_tier="${2:-}"
ttl_hours=24
shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --ttl-hours) ttl_hours="${2:?grant-resident-escalation: --ttl-hours needs a value}"; shift 2 ;;
    *) echo "grant-resident-escalation: unrecognized argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$repo" ] && [ -n "$max_tier" ] || {
  echo "usage: grant-resident-escalation.sh <repo> <fast|standard|deep|frontier> [--ttl-hours N]" >&2
  exit 1
}
case "$max_tier" in
  fast|standard|deep|frontier) ;;
  *) echo "grant-resident-escalation: unrecognized max_tier '$max_tier' (want fast|standard|deep|frontier)" >&2; exit 1 ;;
esac
case "$ttl_hours" in
  ''|*[!0-9]*) echo "grant-resident-escalation: --ttl-hours must be a positive integer" >&2; exit 1 ;;
esac
[ "$ttl_hours" -ge 1 ] || { echo "grant-resident-escalation: --ttl-hours must be at least 1" >&2; exit 1; }
[ "$ttl_hours" -le 24 ] || {
  echo "grant-resident-escalation: --ttl-hours cannot exceed the hard cap (24) — ${ttl_hours} requested" >&2
  exit 1
}

root="$(repo_root "$repo" 2>/dev/null)"
[ -n "$root" ] || { echo "grant-resident-escalation: '$repo' is not inside a git repository" >&2; exit 1; }
root_real="$(cd "$root" 2>/dev/null && pwd -P)"
[ -n "$root_real" ] || root_real="$root"

# Fail-closed hard cap, parallel to the ttl_hours cap above: this grant
# may ONLY ever be minted for an explicitly approved repo. root_real is
# already worktree- and path-traversal-safe (repo_root + pwd -P above),
# so a worktree alias or a `..`-laden argument is refused or admitted
# exactly as its canonical main-repo identity would be -- nothing here
# does its own path resolution.
resident_grant_allowed_repo "$root_real" || {
  echo "grant-resident-escalation: refused — '$root_real' is not one of the explicitly approved repos for this grant" >&2
  exit 1
}

# The SAME real gate spawn-task.sh itself uses for every local spawn — never
# reimplemented, never loosened for this mint path.
minting_pane="$(caller_pane_from_ancestry)" || {
  echo "grant-resident-escalation: refused — local caller ancestry unavailable or outside Herdr; this must be run from a real, live pane, never unattended" >&2
  exit 1
}
pane_is_conductor_eligible "$minting_pane" "$root_real" || {
  echo "grant-resident-escalation: refused — calling pane is not an eligible conductor for '$root_real'" >&2
  exit 1
}
minting_pane_birth="$(pane_birth_now "$minting_pane")" || exit 1
[ -n "$minting_pane_birth" ] || { echo "grant-resident-escalation: refused — minting pane birth unavailable" >&2; exit 1; }

# job_classes: every tier at or below max_tier in the real ladder, derived
# the same way esc_tier_job already maps each tier to its job-class string
# — never a hand-picked subset, see this script's own header.
job_classes=""
for tier in $(esc_ladder); do
  job_classes="${job_classes}$(esc_tier_job "$tier" 2>/dev/null),"
  [ "$tier" = "$max_tier" ] && break
done
job_classes="${job_classes%,}"
[ -n "$job_classes" ] || { echo "grant-resident-escalation: could not derive any job classes for max_tier '$max_tier'" >&2; exit 1; }

ttl_ms=$((ttl_hours * 60 * 60 * 1000))
command_id="$(gen_id resident_grant)"
accept_resident_escalation_grant "$command_id" "$minting_pane" "$minting_pane_birth" "$root_real" "$job_classes" "$max_tier" "$ttl_ms"
