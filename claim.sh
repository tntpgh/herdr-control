#!/usr/bin/env bash
# claim.sh — declare what a pane is working on, and see who else is where.
#
#   claim.sh                          # what do I hold, and who else is around
#   claim.sh take [repo] [-m purpose] # claim a repo (defaults to cwd's repo)
#   claim.sh drop [repo]              # release it (all of mine if omitted)
#   claim.sh who  [repo]              # who holds this repo
#   claim.sh list                     # every live claim on this machine
#   claim.sh sweep                    # expire lapsed claims now (also automatic)
#
# The design constraint that shaped this file: **if claiming costs more than
# one command, nobody claims.** So `claim.sh take` with no arguments does the
# right thing from inside any repo, purpose is optional, the TTL is implicit,
# and re-running it is a renewal rather than an error. Everything else here is
# a read.
#
# Advisory by construction: `take` on a repo someone else holds prints who and
# why and exits 2. It does not stop you — one machine, one human, no
# adversarial peer. What was missing was never enforcement, it was knowing.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/claims.sh
source "$HERE/lib/claims.sh"

me() { printf '%s\n' "${HERDR_PANE_ID:-${CLAIM_PANE_ID:-}}"; }

# A repo argument may be a path, a bare repo name under ~/Code, or omitted
# (meaning: the repo the caller is standing in). Always canonicalized to the
# git toplevel, so a worktree and its main checkout stay distinguishable —
# they are genuinely different scopes.
resolve_scope() {
  local arg="${1:-}"
  local dir="${arg:-$PWD}"
  [ -d "$dir" ] || [ -z "$arg" ] || dir="$HOME/Code/$arg"
  [ -d "$dir" ] || { printf 'claim: no such repo or path: %s\n' "$arg" >&2; return 1; }
  local top
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || {
    printf 'claim: not a git repo: %s\n' "$dir" >&2
    return 1
  }
  printf '%s\n' "$top"
}

short() { printf '%s' "${1##*/}"; }

require_pane() {
  local p; p=$(me)
  [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
  printf 'claim: no pane identity (HERDR_PANE_ID unset).\n' >&2
  printf 'claim: run inside a herdr pane, or set CLAIM_PANE_ID for a one-off.\n' >&2
  return 1
}

cmd_take() {
  local scope purpose="" pane parent="${CLAIM_PARENT:-}"
  local arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--purpose) purpose="${2:-}"; shift 2 ;;
      --parent)     parent="${2:-}"; shift 2 ;;
      -*) printf 'claim: unknown flag %s\n' "$1" >&2; return 1 ;;
      *) arg="$1"; shift ;;
    esac
  done
  scope=$(resolve_scope "$arg") || return 1
  pane=$(require_pane) || return 1

  local out rc
  out=$(claim_acquire "$scope" "$pane" "$purpose" "" "$parent")
  rc=$?
  if [ "$rc" = 2 ]; then
    local hp hu he
    hp=$(printf '%s' "$out" | jq -r '.pane_id')
    hu=$(printf '%s' "$out" | jq -r '.purpose // ""')
    he=$(printf '%s' "$out" | jq -r '.expires_at')
    printf 'HELD: %s is already claimed by %s%s\n' "$(short "$scope")" "$hp" \
      "$([ -n "$hu" ] && printf ' — %s' "$hu")"
    printf '      lease expires %s. Talk to that pane, or --force if it is dead.\n' "$he"
    return 2
  fi
  [ "$rc" = 0 ] || return "$rc"
  printf 'claimed %s%s\n' "$(short "$scope")" "$([ -n "$purpose" ] && printf ' — %s' "$purpose")"
}

cmd_drop() {
  local pane; pane=$(require_pane) || return 1
  if [ $# -eq 0 ]; then
    claim_release_pane "$pane"
    printf 'released every claim held by %s\n' "$pane"
    return 0
  fi
  local force=0 arg=""
  for a in "$@"; do
    case "$a" in --force) force=1 ;; *) arg="$a" ;; esac
  done
  local scope; scope=$(resolve_scope "$arg") || return 1
  if [ "$force" = 1 ]; then
    claim_release_force "$scope"
    printf 'force-released %s (was not necessarily yours)\n' "$(short "$scope")"
  else
    claim_release "$scope" "$pane"
    printf 'released %s\n' "$(short "$scope")"
  fi
}

cmd_who() {
  local scope; scope=$(resolve_scope "${1:-}") || return 1
  local held; held=$(claim_holder "$scope")
  if [ -z "$held" ]; then
    printf '%s — unclaimed\n' "$(short "$scope")"
    return 0
  fi
  printf '%s\n' "$held" | jq -r '"\(.scope | split("/") | last) — \(.pane_id)\(if .purpose == "" then "" else " — " + .purpose end) (expires \(.expires_at))"'
}

# The claim id for a scope, bare — what `--parent` needs when delegating a
# sub-scope to a child conductor. Exists so chaining never requires a caller
# to source the library and poke at SQL.
cmd_id() {
  local scope; scope=$(resolve_scope "${1:-}") || return 1
  claim_holder "$scope" | jq -r '.claim_id // empty'
}

cmd_list() {
  local rows; rows=$(claims_active)
  [ -n "$rows" ] || { printf 'no live claims\n'; return 0; }
  printf '%s\n' "$rows" | jq -r '"\(.pane_id)\t\(.scope | split("/") | last)\t\(.purpose)\t\(.expires_at)"' |
    awk -F'\t' 'BEGIN{printf "%-10s %-20s %-34s %s\n","PANE","SCOPE","PURPOSE","EXPIRES"}
                {printf "%-10s %-20s %-34s %s\n",$1,$2,($3==""?"-":$3),$4}'
}

# Default view: mine first, then everyone else's — the two facts a pane needs
# before it starts writing anywhere.
cmd_status() {
  local pane; pane="$(me)"
  if [ -n "$pane" ]; then
    local mine; mine=$(claims_active "$pane")
    if [ -n "$mine" ]; then
      printf 'held by this pane (%s):\n' "$pane"
      printf '%s\n' "$mine" | jq -r '"  \(.scope | split("/") | last)\(if .purpose == "" then "" else " — " + .purpose end)  (expires \(.expires_at))"'
    else
      printf 'this pane (%s) holds nothing\n' "$pane"
    fi
    local others; others=$(claims_conflicts "$pane")
    if [ -n "$others" ]; then
      printf '\nheld elsewhere:\n'
      printf '%s\n' "$others" | jq -r '"  \(.scope | split("/") | last) — \(.pane_id)\(if .purpose == "" then "" else " — " + .purpose end)"'
    fi
  else
    cmd_list
  fi
}

case "${1:-status}" in
  take|claim)   shift; cmd_take "$@" ;;
  drop|release) shift; cmd_drop "$@" ;;
  who)          shift; cmd_who "$@" ;;
  id)           shift; cmd_id "$@" ;;
  list)         shift; cmd_list "$@" ;;
  sweep)        claims_expire; printf 'expired lapsed claims\n' ;;
  status)       cmd_status ;;
  -h|--help|help)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) printf 'claim: unknown command %s (try --help)\n' "$1" >&2; exit 1 ;;
esac
