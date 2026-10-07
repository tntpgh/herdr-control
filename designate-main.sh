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
#                                             # override from a shell outside
#                                             # herdr's reach entirely (never
#                                             # from inside any herdr pane,
#                                             # agent or not) — forces <pane>
#   designate-main.sh --show                 # print the current designation
#   designate-main.sh --clear                # remove it — only the live
#                                             # Main may clear a LIVE row; a
#                                             # DEAD row may be cleared by any
#                                             # eligible non-worker agent pane
#
# Storage: a row in the registry's OWN `roles` table (lib/run-registry.sh),
# label "main" — read_role, plus register_role_cas/unregister_role_cas for
# every write below. NOT the shared `owners` table: security review PR #252
# (F1) found register-owner.sh/unregister-owner.sh — generic, already-shipped
# tools with no designation gate — could overwrite or delete a "main" row
# there with no liveness or worker check, and that same table is read
# generically by remote-mcp's publisher.py and herdr-action.sh's owner-alert
# routing. A dedicated table makes the collision impossible by construction
# instead of filtering it at every read site. config.sh reads the SAME table
# (a direct sqlite3 query, not by sourcing this file) whenever
# HERDR_MAIN_PANE_ID has no registry row to defer to, and attention-tick.sh
# re-sources config.sh every tick, so a new designation takes effect on the
# next pass with no hub restart.
#
# The pane's birth fingerprint (herdr terminal_id) is stored with it.
# attention-tick.sh refuses to send on a POSITIVE birth mismatch, so a
# designation left behind by a Main that exited cannot deliver into whatever
# process later reuses that pane id. It records attention_escalation_refused
# instead. This is the minimal slice of plan item 4 (role addresses).
#
# ---- caller identity: process ancestry, never self-asserted env -----------
# Every subcommand resolves ITS CALLER from caller_pane_from_ancestry
# (lib/pane-guard.sh): the first ancestor pid of this process that herdr
# itself reports as a pane's CURRENT foreground process. $HERDR_PANE_ID and
# $HERDR_TASK_ID are the CALLER's own environment — a worker can set either
# to whatever it likes (security review PR #252, F2) — and are never trusted
# for identity or the worker check here; pane_is_conductor_eligible looks up
# the resolved pane in the registry directly, which a caller cannot spoof by
# exporting a variable.
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
#   - the caller is a worker (pane_is_conductor_eligible, lib/pane-guard.sh
#     — the same judgment spawn-task.sh's own conductor fallback and
#     conductor-handover.sh (P1) use, F8/R3, security review PR #220);
#   - the caller's identity could not be resolved from process ancestry at
#     all (herdr unreachable, or this process traces to no live pane).
# Every change writes a `main_designated` event {from,to,birth,by,reason};
# every refusal writes `main_designation_refused` {from,attempted_by,reason}.
# --show is always read-only and never gated.
#
# ---- --force -----------------------------------------------------------------
# Measured empirically (security review PR #252, F3): neither a human typing
# directly into a herdr pane NOR an agent's own bash-tool dispatch makes the
# agent binary (omp/claude/codex) a process ancestor of the command it runs
# — herdr's daemon forks the shell itself for both, so walking ancestry for
# an agent's NAME cannot tell them apart, and `-t 0`/HERDR_TASK_ID (the
# original gate) is satisfiable by any agent via `script -q /dev/null ...`.
# What IS unspoofable: whether this process's ancestry traces to ANY
# herdr-tracked pane at all. Every agent (worker or Main) by definition runs
# inside one; a genuinely external human shell (direct ssh, a terminal
# outside herdr's purview) never will. --force requires
# caller_pane_from_ancestry to return rc=2 — the walk ran cleanly and found
# NO herdr pane anywhere in this process's ancestry — not merely "stdin is a
# tty" or "no env var is set."
#
# ---- concurrency -------------------------------------------------------------
# Two panes racing to self-designate when no Main exists (or over a Main
# they both independently decided is dead) must leave exactly one winner,
# not a last-write-wins clobber. register_role_cas makes the
# read-permission-check and the write happen as one atomic SQL statement
# guarded by the row's pre-image, so a losing racer's write simply fails
# (changes()=0) instead of silently overwriting whoever won.
#
# F4 (security review PR #252): that pre-image is read EXACTLY ONCE per
# command below and reused unchanged as the CAS expected_pane/expected_birth
# — no command re-reads the row between its permission check and its write.
# A second, later read let a Main that appeared IN BETWEEN get silently
# overwritten by a racer who had already passed its permission check against
# the first read.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/run-registry.sh
source "$HERE/lib/run-registry.sh"
# shellcheck source=lib/pane-guard.sh
source "$HERE/lib/pane-guard.sh"

MAIN_LABEL=main

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

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

# Resolve the CALLER's pane from process ancestry (F2) — never from
# self-asserted HERDR_PANE_ID. Dies the caller never sees a fallback value:
# an unresolved caller refuses, full stop.
_caller_pane() {
  caller_pane_from_ancestry
}

# Current "main" row, split pane/birth (empty/empty if absent). Read this
# EXACTLY ONCE per command (F4) — every caller below reuses the same
# pane/birth pair as both the permission-check input and the CAS pre-image.
_main_row() {
  local j
  j="$(read_role "$MAIN_LABEL")" || return 1
  if [ -z "$j" ] || [ "$j" = "null" ]; then printf ' \n'; return 0; fi
  printf '%s %s\n' "$(printf '%s' "$j" | jq -r '.pane_id // empty')" \
                    "$(printf '%s' "$j" | jq -r '.pane_birth // empty')"
}

# Is a given (pane, birth) pair LIVE right now? F5: fails closed (1, "treat
# as not live") on a herdr read failure — a transient herdr hiccup must
# never read as "Main is gone."
_is_live() {       # pane birth -> 0 live, 1 not live or indeterminate
  local pane="$1" birth="$2" live
  [ -n "$pane" ] || return 1
  live="$(pane_birth_now "$pane")" || return 1
  [ -n "$live" ] || return 1
  [ -z "$birth" ] || [ "$live" = "$birth" ]
}

# Refuses a pane that is a worker — pane_is_conductor_eligible
# (lib/pane-guard.sh) looks the pane up in the registry directly, and itself
# fails closed on a registry read failure (F5). Sets $WORKER_REASON.
_refuse_if_worker() {   # pane -> 0 eligible, 1 refuse
  local pane="$1"
  if ! pane_is_conductor_eligible "$pane"; then
    if ! pane_is_agent "$pane" 2>/dev/null; then
      WORKER_REASON="$pane is not running an agent"
    else
      WORKER_REASON="$pane is a registered worker's own active task pane, or its eligibility could not be verified"
    fi
    return 1
  fi
  return 0
}

show() {
  local pane birth
  read -r pane birth <<<"$(_main_row)" || die 1 "could not read the registry"
  if [ -z "$pane" ]; then echo "(no Main designated)"; else printf '%s %s\n' "$pane" "$birth"; fi
}

cmd_clear() {
  local caller pane birth
  caller="$(_caller_pane)" || die 3 "could not verify caller identity from process ancestry (herdr unreachable, or this process traces to no live pane)"
  if ! _refuse_if_worker "$caller"; then
    record_refused "$(_main_row | awk '{print $1}')" "$caller" "$WORKER_REASON"
    die 3 "refusing to clear: $WORKER_REASON"
  fi
  read -r pane birth <<<"$(_main_row)" || die 1 "could not read the registry"
  if [ -z "$pane" ]; then
    echo "(no Main designated; nothing to clear)"
    return 0
  fi
  if _is_live "$pane" "$birth" && [ "$caller" != "$pane" ]; then
    record_refused "$pane" "$caller" "a live Main ($pane) exists and the caller isn't it"
    die 4 "refusing to clear: Main is $pane (birth $birth); only it may clear itself"
  fi
  if unregister_role_cas "$MAIN_LABEL" "$pane" "$birth"; then
    record_designated "$pane" "" "" "$caller" "clear"
    echo "Main designation cleared"
  else
    die 1 "clear lost a race (the designation changed underneath it); retry"
  fi
}

cmd_handoff() {          # target_pane
  local target="$1" caller pane birth
  caller="$(_caller_pane)" || die 3 "could not verify caller identity from process ancestry (herdr unreachable, or this process traces to no live pane)"
  read -r pane birth <<<"$(_main_row)" || die 1 "could not read the registry"
  _is_live "$pane" "$birth" || die 4 "refusing: no live Main to hand off from"
  if [ "$caller" != "$pane" ]; then
    record_refused "$pane" "$caller" "only the current live Main ($pane) may --handoff-to"
    die 4 "refusing: only the current live Main ($pane) may hand off"
  fi
  if ! _refuse_if_worker "$target"; then
    record_refused "$pane" "$caller" "handoff target $WORKER_REASON"
    die 3 "refusing handoff to $target: $WORKER_REASON"
  fi
  local target_birth
  target_birth="$(pane_birth_now "$target")" || die 3 "could not read $target's birth fingerprint (herdr unreachable)"
  [ -n "$target_birth" ] || die 3 "could not read $target's birth fingerprint (pane not found)"
  if register_role_cas "$MAIN_LABEL" "$target" "$target_birth" "" "" "$pane" "$birth"; then
    record_designated "$pane" "$target" "$target_birth" "$caller" "handoff"
    echo "Main handed off: $pane -> $target (birth $target_birth)"
  else
    die 1 "handoff lost a race (the designation changed underneath it); retry"
  fi
}

cmd_force() {             # target_pane reason
  local target="$1" reason="$2" rc=0
  caller_pane_from_ancestry >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || die 3 "refusing --force: this process traces to a herdr-managed pane (or that could not be verified); --force is only for a shell outside herdr's reach entirely"
  if ! _refuse_if_worker "$target"; then
    local pane; pane="$(_main_row | awk '{print $1}')"
    record_refused "$pane" "human-force" "force target $WORKER_REASON"
    die 3 "refusing --force: $WORKER_REASON"
  fi
  local target_birth
  target_birth="$(pane_birth_now "$target")" || die 3 "could not read $target's birth fingerprint (herdr unreachable)"
  [ -n "$target_birth" ] || die 3 "could not read $target's birth fingerprint (pane not found)"
  local pane birth
  read -r pane birth <<<"$(_main_row)" || die 1 "could not read the registry"
  if register_role_cas "$MAIN_LABEL" "$target" "$target_birth" "" "" "$pane" "$birth"; then
    record_designated "$pane" "$target" "$target_birth" "human-force" "$reason"
    echo "Main = $target (birth $target_birth) [forced by human: $reason]"
  else
    die 1 "force-designation lost a race (the designation changed underneath it); retry"
  fi
}

cmd_self() {
  local caller
  caller="$(_caller_pane)" || die 3 "could not verify caller identity from process ancestry (herdr unreachable, or this process traces to no live pane)"
  if ! _refuse_if_worker "$caller"; then
    record_refused "$(_main_row | awk '{print $1}')" "$caller" "$WORKER_REASON"
    die 3 "refusing: $WORKER_REASON"
  fi
  local pane birth
  read -r pane birth <<<"$(_main_row)" || die 1 "could not read the registry"
  if _is_live "$pane" "$birth" && [ "$pane" != "$caller" ]; then
    record_refused "$pane" "$caller" "a live Main ($pane) already exists and the caller isn't it"
    die 4 "refusing: Main is already $pane (birth $birth); use --handoff-to from that pane, or --force"
  fi
  local caller_birth
  caller_birth="$(pane_birth_now "$caller")" || die 3 "could not read $caller's birth fingerprint (herdr unreachable)"
  [ -n "$caller_birth" ] || die 3 "could not read $caller's birth fingerprint (pane not found)"
  if register_role_cas "$MAIN_LABEL" "$caller" "$caller_birth" "" "" "$pane" "$birth"; then
    record_designated "$pane" "$caller" "$caller_birth" "$caller" "$([ -n "$pane" ] && echo self-redesignate || echo main-absent-or-dead)"
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
  [ -z "$target" ] || die 2 "unexpected extra argument: $target"
  cmd_handoff "$handoff_to"
else
  [ -z "$target" ] || die 2 "designate-main.sh takes no positional pane argument except with --force; did you mean --handoff-to $target or --force --reason \"<text>\" $target?"
  cmd_self
fi
