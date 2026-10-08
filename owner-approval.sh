#!/usr/bin/env bash
# owner-approval.sh — register or revoke a long-lived owner/conductor identity
# for exact-input hook approval (docs/design/pretool-approval.md §13).
#
#   owner-approval.sh register <label> <pane_id> <session_id>
#   owner-approval.sh revoke <label> --reason <why>
#   owner-approval.sh show <label>
#   owner-approval.sh list
#
# HUMAN-ONLY to register and to revoke. The session an identity protects must
# never be able to create, re-bind or lift it, so register/revoke refuse
# (exit 9) unless every one of these holds:
#   - no worker or owner-mode environment (HERDR_TASK_ID, HERDR_RUN_ID,
#     HERDR_OWNER_APPROVAL);
#   - the caller's own herdr pane is not the pane being registered, and is
#     not running an agent (lib/pane-guard.sh pane_is_agent);
#   - stdin is a terminal and the label is typed back to confirm;
#   - no ancestor process is an agent (lib/agent-profiles.sh names): an
#     agent's bash tool, even with a pty, runs as that agent's descendant.
# Inside an enforced session the policy refuses first anyway:
# lib/hook-approval-rules.tsv makes this script, lib/owner-identity.sh, the
# store and its tables human-only. These are layers, not containment: a
# same-user process that detaches from its agent and fakes a terminal can
# still write the store (design §12's residual; isolation is #172).
#
# NOT WIRED: nothing in this repo calls this script. Registering an owner
# changes nothing by itself; an owner session is only judged when it was
# launched with HERDR_OWNER_APPROVAL=<label> (the activation step, §13).
#
# The session id to register is printed in the refusal every tool call of an
# unregistered owner-mode session gets ("this session is <id>").
#
# Exit: 0 done; 1 usage / invalid argument / not found; 2 store error;
#       3 conflict (an ACTIVE row already holds that label, pane or session);
#       9 refused: not a human at a plain terminal.
set -uo pipefail
_oa_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Fallback locations only: the caller's own PATH (and so its herdr) comes first.
export PATH="${PATH:-}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
. "$_oa_here/lib/run-registry.sh"
. "$_oa_here/lib/pane-guard.sh"
. "$_oa_here/lib/owner-identity.sh"

_oa_die() { printf 'owner-approval: %s\n' "$1" >&2; exit "${2:-1}"; }

# The nearest ancestor of <pid> whose executable is a known agent, as
# "<pid> <name>"; empty when there is none. Names come from the ONE list
# (lib/agent-profiles.sh, loaded by pane-guard.sh).
_oa_agent_ancestor() {                  # pid
  local p="$1" name parent hops=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
    name="$(ps -o comm= -p "$p" 2>/dev/null)"; name="${name##*/}"
    case " $HERDR_AGENT_PROC_NAMES " in
      *" $name "*) printf '%s %s\n' "$p" "$name"; return 0 ;;
    esac
    parent="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    [ "$parent" != "$p" ] || break
    p="$parent"; hops=$((hops + 1))
  done
  return 1
}

_oa_caller() { printf 'user=%s tty=%s ppid=%s' "$(id -un 2>/dev/null)" "$(tty 2>/dev/null || printf none)" "$PPID"; }

# Refuses (exit 9) unless this is a human at a plain terminal. A refusal is
# audited when the store already exists, and the store is never created by it.
_oa_require_human() {                   # verb label [target-pane]
  local verb="$1" label="$2" target="${3:-}" why="" anc typed
  if [ -n "${HERDR_TASK_ID:-}${HERDR_RUN_ID:-}" ]; then
    why="the caller carries a worker task's environment (HERDR_TASK_ID/HERDR_RUN_ID)"
  elif [ -n "${HERDR_OWNER_APPROVAL:-}" ]; then
    why="the caller carries an owner-mode session's environment (HERDR_OWNER_APPROVAL) — an owner never registers or revokes itself"
  elif [ -n "$target" ] && [ "${HERDR_PANE_ID:-}" = "$target" ]; then
    why="self-registration: the caller is running in pane $target, the pane being registered"
  elif [ -n "${HERDR_PANE_ID:-}" ] && pane_is_agent "$HERDR_PANE_ID" 2>/dev/null; then
    why="the calling pane ${HERDR_PANE_ID} is running an agent"
  elif [ ! -t 0 ]; then
    why="stdin is not a terminal: a human runs this at a plain terminal"
  elif anc="$(_oa_agent_ancestor "$$")"; then
    why="called from inside an agent process (${anc#* }, pid ${anc%% *})"
  fi
  if [ -z "$why" ]; then
    printf "Type the label '%s' to confirm %s: " "$label" "$verb" >&2
    IFS= read -r typed || typed=""
    [ "$typed" = "$label" ] || why="confirmation did not match the label"
  fi
  [ -z "$why" ] && return 0
  owner_identity_audit "$label" "${verb}_refused" \
    "$(jq -nc --arg w "$why" --arg c "$(_oa_caller)" --arg t "$target" '{why:$w, caller:$c, target_pane:$t}')"
  _oa_die "refused — $why. Registering or revoking an owner is human-only." 9
}

_oa_register() {
  local label="${1:-}" pane="${2:-}" sid="${3:-}" birth rc
  [ $# -eq 3 ] || _oa_die "usage: owner-approval.sh register <label> <pane_id> <session_id>"
  owner_label_valid "$label" || _oa_die "label '$label' must match ^[a-z0-9][a-z0-9-]{1,40}\$"
  owner_pane_valid "$pane" || _oa_die "pane '$pane' is not a herdr pane id (w<N>:p<N>)"
  owner_session_valid "$sid" || _oa_die "session id '$sid' is malformed"
  _oa_require_human register "$label" "$pane"
  birth="$(pane_birth_now "$pane" 2>/dev/null)"
  [ -n "$birth" ] || _oa_die "pane $pane is not in herdr pane list"
  require_agent_pane "$pane" || _oa_die "pane $pane is not running an agent"
  owner_identity_register "$label" "$pane" "$birth" "$sid" "$(_oa_caller)"; rc=$?
  case "$rc" in
    0) owner_identity_read "$label" ;;
    3) _oa_die "an ACTIVE owner already holds label '$label', pane $pane or session $sid — revoke it first" 3 ;;
    1) _oa_die "invalid argument" ;;
    *) _oa_die "the owner store is unwritable ($(owner_identity_db))" 2 ;;
  esac
}

_oa_revoke() {
  local label="${1:-}" why="" rc
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) why="${2:-}"; shift 2 ;;
      *) _oa_die "usage: owner-approval.sh revoke <label> --reason <why>" ;;
    esac
  done
  owner_label_valid "$label" || _oa_die "usage: owner-approval.sh revoke <label> --reason <why>"
  [ -n "${why//[[:space:]]/}" ] || _oa_die "revoke needs a nonblank --reason"
  _oa_require_human revoke "$label"
  owner_identity_revoke "$label" "$why" "$(_oa_caller)"; rc=$?
  case "$rc" in
    0) owner_identity_read "$label" ;;
    1) _oa_die "no ACTIVE owner '$label'" ;;
    *) _oa_die "the owner store is unwritable ($(owner_identity_db))" 2 ;;
  esac
}

owner_approval_main() {
  local verb="${1:-}" row
  shift || true
  case "$verb" in
    register) _oa_register "$@" ;;
    revoke) _oa_revoke "$@" ;;
    show)
      row="$(owner_identity_read "${1:-}" 2>/dev/null)" || _oa_die "the owner store is unreadable or absent ($(owner_identity_db))" 2
      [ -n "$row" ] || _oa_die "no owner '${1:-}'"
      printf '%s\n' "$row" ;;
    list) owner_identity_list ;;
    *) _oa_die "usage: owner-approval.sh register <label> <pane_id> <session_id> | revoke <label> --reason <why> | show <label> | list" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  owner_approval_main "$@"
  exit $?
fi
