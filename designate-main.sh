#!/usr/bin/env bash
# designate-main.sh — record which pane is "Main", the operator-facing
# conductor that the attention controller escalates to, and that P1's
# conductor-handover.sh (.handoffs/SPEC.md feat/conductor-handover) lets take
# over any task's conductor authority. Because of that second power, "any
# pane can self-designate Main" became "any pane can take every worker" (P3,
# .handoffs/SPEC.md feat/main-designation-lock) — this file enforces who may
# change the designation, not just records it.
#
#   designate-main.sh                        # this pane becomes Main (allowed
#                                             # only if there is no live Main,
#                                             # or this pane already IS it)
#   designate-main.sh --handoff-to <pane>     # run by the CURRENT live Main:
#                                             # hand the role to another live,
#                                             # non-worker agent pane
#   designate-main.sh --force --reason "<text>" <pane>   # Zero/Terrence
#                                             # override from a plain human
#                                             # shell (never from inside an
#                                             # agent) — forces <pane>
#   designate-main.sh --show                 # print the current designation
#   designate-main.sh --clear                # remove it (only the live Main,
#                                             # or --force, may do this)
#
# Storage: a row in the registry's `owners` table (lib/run-registry.sh),
# label "main" — register_owner/read_owner/unregister_owner, plus
# register_owner_cas for the compare-and-swap writes below. NOT a file:
# earlier this lived at roles/main, moved here 2026-10-07 so the role can
# carry the same liveness-aware, race-safe write path every other registry
# row already has, instead of a second bespoke format. config.sh reads the
# SAME table (a direct sqlite3 query, not by sourcing this file) whenever
# HERDR_MAIN_PANE_ID is not set explicitly, and attention-tick.sh re-sources
# config.sh every tick, so a new designation takes effect on the next pass
# with no hub restart — unchanged from the file-based design.
#
# The pane's birth fingerprint (herdr terminal_id) is stored with it.
# attention-tick.sh refuses to send on a POSITIVE birth mismatch, so a
# designation left behind by a Main that exited cannot deliver into whatever
# process later reuses that pane id. It records attention_escalation_refused
# instead. This is the minimal slice of plan item 4 (role addresses).
#
# ---- who may change the designation ----------------------------------------
# Allowed:
#   (a) no live Main exists (no row, or the recorded pane is dead, or its
#       birth no longer matches — Main is gone) — ANY non-worker agent pane
#       may self-designate.
#   (b) the caller IS the current live Main — re-designating itself (e.g.
#       after a session resume in the same pane) is always a no-op allowed.
#   (c) --handoff-to, run BY the current live Main, naming another live
#       agent pane that is not a worker.
# Refused:
#   - a live Main exists and the caller isn't it (and isn't doing (c));
#   - the caller is a worker — HERDR_TASK_ID is set, or its pane is a
#     registered task's own currently active pane (pane_is_conductor_eligible,
#     lib/pane-guard.sh — the same judgment spawn-task.sh's own conductor
#     fallback and conductor-handover.sh (P1) use, F8/R3, security review PR #220).
# Every change writes a `main_designated` event {from,to,birth,by,reason};
# every refusal writes `main_designation_refused` {from,attempted_by,reason}.
# --show is always read-only and never gated.
#
# ---- concurrency -------------------------------------------------------------
# Two panes racing to self-designate when no Main exists (or over a Main they
# both independently decided is dead) must leave exactly one winner, not a
# last-write-wins clobber. register_owner_cas makes the read-permission-check
# and the write happen as one atomic SQL statement guarded by the row's
# pre-image, so a losing racer's write simply fails (changes()=0) instead of
# silently overwriting whoever won.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/run-registry.sh
source "$HERE/lib/run-registry.sh"
# shellcheck source=lib/pane-guard.sh
source "$HERE/lib/pane-guard.sh"

MAIN_LABEL=main

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

die() { local code="$1"; shift; echo "designate-main: $*" >&2; exit "$code"; }

record_designated() {   # from to birth by reason
  append_event "" "" main_designated \
    "$(jq -nc --arg f "$1" --arg t "$2" --arg b "$3" --arg by "$4" --arg r "$5" \
       '{from:$f, to:$t, birth:$b, by:$by, reason:$r}')" >/dev/null 2>&1 || true
}
record_refused() {      # from attempted_by reason
  append_event "" "" main_designation_refused \
    "$(jq -nc --arg f "$1" --arg a "$2" --arg r "$3" '{from:$f, attempted_by:$a, reason:$r}')" \
    >/dev/null 2>&1 || true
}

# Current designation row, split into pane/birth (empty/empty if absent).
_main_row() {
  local j
  j="$(read_owner "$MAIN_LABEL")"
  if [ -z "$j" ] || [ "$j" = "null" ]; then printf ' \n'; return 0; fi
  printf '%s %s\n' "$(printf '%s' "$j" | jq -r '.pane_id // empty')" \
                    "$(printf '%s' "$j" | jq -r '.pane_birth // empty')"
}

# Is the recorded owners row for "main" a LIVE Main right now? Prints
# "<pane> <birth>" and returns 0 if so; prints nothing and returns 1 if the
# row is absent, the pane is gone, or its birth no longer matches (Main is
# gone, same POSITIVE-mismatch-only rule attention-tick.sh's escalation uses).
_live_main() {
  local pane birth live
  read -r pane birth <<<"$(_main_row)"
  [ -n "$pane" ] || return 1
  live="$(pane_birth_now "$pane" 2>/dev/null)"
  [ -n "$live" ] || return 1
  [ -z "$birth" ] || [ "$live" = "$birth" ] || return 1
  printf '%s %s\n' "$pane" "$live"
}

# Refuses a pane that is a worker: HERDR_TASK_ID set in THIS process's own
# environment, or the TARGET pane is a registered task's own active pane
# (pane_is_conductor_eligible, lib/pane-guard.sh). Sets $WORKER_REASON.
_refuse_if_worker() {   # pane -> 0 eligible, 1 refuse
  local pane="$1"
  if [ -n "${HERDR_TASK_ID:-}" ]; then
    WORKER_REASON="caller has HERDR_TASK_ID set (is a worker)"
    return 1
  fi
  if ! pane_is_conductor_eligible "$pane" 2>/dev/null; then
    if ! pane_is_agent "$pane" 2>/dev/null; then
      WORKER_REASON="$pane is not running an agent"
    else
      WORKER_REASON="$pane is a registered worker's own active task pane"
    fi
    return 1
  fi
  return 0
}

show() {
  local pane birth
  read -r pane birth <<<"$(_main_row)"
  if [ -z "$pane" ]; then echo "(no Main designated)"; else printf '%s %s\n' "$pane" "$birth"; fi
}

cmd_clear() {
  local live_pane live_birth caller="${HERDR_PANE_ID:-}"
  if read -r live_pane live_birth <<<"$(_live_main)" && [ -n "$live_pane" ]; then
    if [ -n "$caller" ] && [ "$caller" = "$live_pane" ]; then
      :  # the live Main may clear itself
    else
      record_refused "$live_pane" "${caller:-<no pane>}" "a live Main ($live_pane) exists and the caller isn't it"
      die 4 "refusing to clear: Main is $live_pane (birth $live_birth); only it may clear itself"
    fi
  fi
  unregister_owner "$MAIN_LABEL"
  record_designated "$live_pane" "" "" "${caller:-<no pane>}" "clear"
  echo "Main designation cleared"
}

cmd_handoff() {          # target_pane
  local target="$1" caller="${HERDR_PANE_ID:-}" live_pane live_birth
  [ -n "$caller" ] || die 2 "no pane (set HERDR_PANE_ID)"
  read -r live_pane live_birth <<<"$(_live_main)"
  [ -n "$live_pane" ] || die 4 "refusing: no live Main to hand off from"
  [ "$caller" = "$live_pane" ] || { record_refused "$live_pane" "$caller" "only the current live Main ($live_pane) may --handoff-to"; die 4 "refusing: only the current live Main ($live_pane) may hand off"; }
  if ! _refuse_if_worker "$target"; then
    record_refused "$live_pane" "$caller" "handoff target $WORKER_REASON"
    die 3 "refusing handoff to $target: $WORKER_REASON"
  fi
  local target_birth; target_birth="$(pane_birth_now "$target" 2>/dev/null)"
  [ -n "$target_birth" ] || die 3 "could not read $target's birth fingerprint"
  if register_owner_cas "$MAIN_LABEL" "$target" "$target_birth" "" "" "$live_pane" "$live_birth"; then
    record_designated "$live_pane" "$target" "$target_birth" "$caller" "handoff"
    echo "Main handed off: $live_pane -> $target (birth $target_birth)"
  else
    die 1 "handoff lost a race (the designation changed underneath it); retry"
  fi
}

cmd_force() {             # target_pane reason
  local target="$1" reason="$2" caller="${HERDR_PANE_ID:-}"
  [ -n "$caller" ] || die 2 "no pane (set HERDR_PANE_ID)"
  # Must be invoked directly by a human, never by/through an agent process:
  # owner-approval.sh's agent-ancestor check isn't on main yet, so this is
  # the documented fallback (.handoffs/SPEC.md item 4).
  if [ -n "${HERDR_TASK_ID:-}" ] || [ ! -t 0 ]; then
    die 3 "refusing --force: not an interactive human invocation (HERDR_TASK_ID set, or stdin is not a tty)"
  fi
  if ! _refuse_if_worker "$target"; then
    record_refused "$(_main_row | awk '{print $1}')" "human-force" "force target $WORKER_REASON"
    die 3 "refusing --force: $WORKER_REASON"
  fi
  local target_birth; target_birth="$(pane_birth_now "$target" 2>/dev/null)"
  [ -n "$target_birth" ] || die 3 "could not read $target's birth fingerprint"
  local observed_pane observed_birth
  read -r observed_pane observed_birth <<<"$(_main_row)"
  if register_owner_cas "$MAIN_LABEL" "$target" "$target_birth" "" "" "$observed_pane" "$observed_birth"; then
    record_designated "$observed_pane" "$target" "$target_birth" "human-force" "$reason"
    echo "Main = $target (birth $target_birth) [forced by human: $reason]"
  else
    die 1 "force-designation lost a race (the designation changed underneath it); retry"
  fi
}

cmd_self() {
  local caller="${HERDR_PANE_ID:-}"
  [ -n "$caller" ] || die 2 "no pane (set HERDR_PANE_ID or pass one)"
  if ! _refuse_if_worker "$caller"; then
    record_refused "$(_main_row | awk '{print $1}')" "$caller" "$WORKER_REASON"
    die 3 "refusing: $WORKER_REASON"
  fi
  local live_pane live_birth
  read -r live_pane live_birth <<<"$(_live_main)"
  if [ -n "$live_pane" ] && [ "$live_pane" != "$caller" ]; then
    record_refused "$live_pane" "$caller" "a live Main ($live_pane) already exists and the caller isn't it"
    die 4 "refusing: Main is already $live_pane (birth $live_birth); use --handoff-to from that pane, or --force"
  fi
  local caller_birth; caller_birth="$(pane_birth_now "$caller" 2>/dev/null)"
  [ -n "$caller_birth" ] || die 3 "could not read $caller's birth fingerprint"
  local observed_pane observed_birth
  read -r observed_pane observed_birth <<<"$(_main_row)"
  if register_owner_cas "$MAIN_LABEL" "$caller" "$caller_birth" "" "" "$observed_pane" "$observed_birth"; then
    record_designated "$observed_pane" "$caller" "$caller_birth" "$caller" "$([ -n "$live_pane" ] && echo self-redesignate || echo main-absent-or-dead)"
    echo "Main = $caller (birth $caller_birth)"
  else
    die 1 "designation changed concurrently (lost the race); retry"
  fi
}

force=0 reason="" handoff_to="" target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --show) show; exit 0 ;;
    --clear) cmd_clear; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --handoff-to) handoff_to="${2:?usage: designate-main.sh --handoff-to <pane>}"; shift 2 ;;
    --force) force=1; shift ;;
    --reason) reason="${2:?usage: designate-main.sh --force --reason "<text>" <pane>}"; shift 2 ;;
    --) shift; break ;;
    -*) die 2 "unknown flag: $1" ;;
    *) target="$1"; shift ;;
  esac
done

if [ "$force" = 1 ]; then
  [ -n "$reason" ] || die 2 "--force requires --reason \"<text>\""
  [ -n "$target" ] || die 2 "--force requires a target pane: designate-main.sh --force --reason \"<text>\" <pane>"
  cmd_force "$target" "$reason"
elif [ -n "$handoff_to" ]; then
  cmd_handoff "$handoff_to"
else
  cmd_self
fi
