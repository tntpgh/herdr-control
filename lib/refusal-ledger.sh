#!/usr/bin/env bash
# lib/refusal-ledger.sh — "an approval-tool refusal is final" as a technical
# check, not only a conductor's memory rule.
#
# SPEC: .handoffs/SPEC.md. Design input:
# review/board-cd1eb3d/tmp/INCIDENT-RUNREG.md §5 (2026-10-29 run-registry.sh
# approval-denial incident): command-policy.sh already refuses a bash
# occurrence that names a protected governance/policy file
# (_CP_POLICY_FILE_RE, lib/command-policy.sh), but it judges every occurrence
# fresh — nothing remembered that a given run+task had ALREADY been told no.
# §5's three concrete gaps were: a reworded retry (different shell syntax,
# same filename), a retry split across more than one bash call, and a bulk
# `git archive` that can emit the same file's content without naming it at
# all. This module closes those for the one run+task scope that was actually
# refused.
#
# WHY THIS NEVER TOUCHES herdr-select.sh: herdr-select.sh, scoped-policy.sh
# and command-policy.sh are themselves on _CP_POLICY_FILE_RE's protected
# list -- "the approval selector" is governance-gated the same way the
# registry is. 2026-10-29 conductor directive (this task's own SPEC run):
# a `bash -n herdr-select.sh` parse-check was refused as a genuine control
# boundary, with the explicit instruction "design the enforcement so it
# doesn't require changing herdr-select.sh, or stop and report that it needs
# a governance owner." This module takes the first option by construction:
# it is a pure READER of data herdr-select.sh's UNCHANGED, EXISTING code
# already writes unconditionally on every peer/conductor refusal --
# `_refuse_non_human`'s `append_event ... approval_escalated` call
# (herdr-select.sh, pre-existing, not part of this change) already records
# {verdict, reason, pane, prompt_id, command} for the exact case the
# incident was about. Nothing here needs herdr-select.sh, scoped-policy.sh,
# or command-policy.sh to call anything new, so none of them are edited.
#
# WHAT THIS DOES NOT CLOSE: wiring this reader into the live approval path
# (so a retry is refused BEFORE a key is pressed, not merely detectable
# after) requires a change to whichever script makes that decision --
# herdr-select.sh, scoped-policy.sh's peer_decide, or the omp
# tool_approval_requested hook (agent-hooks/omp-herdr-control.ts) -- and
# every one of those is either on the protected list or is the single
# highest-blast-radius file in this repo (the hook decides for every tool
# call, for every worker, before any panel exists). That wiring is exactly
# the kind of auth-adjacent, same-day change this project's own rules
# require a security-focused second reviewer for (shipped-change-review-gate
# skill; AGENTS.md "Author and reviewer are separate passes"), which a
# single unattended run cannot supply for itself. .handoffs/PROOF.md records
# this as the explicit handoff: the DETECTION is proven below against real
# registry rows; the WIRING is a governance-owner decision, not made here.
# Also out of scope, per INCIDENT-RUNREG.md §5 itself: a `read`/`grep` tool
# call never produces a herdr-select occurrence at all (no approval panel),
# so there is nothing here to attach a refusal event to; same for a human or
# conductor acting through their own shell, outside any gated tool channel.
#
# Read-only: this module issues a `SELECT ... FROM events` against the SAME
# registry.sqlite3 lib/run-registry.sh already owns (registry_db, sourced
# from run-registry.sh, used exactly like every verify-*.sh harness already
# queries that file directly for assertions) and never calls a write
# function, opens a write handle, or edits run-registry.sh itself.
#
# Requires lib/run-registry.sh (registry_db, _sq) and lib/command-policy.sh
# (_CP_POLICY_FILE_RE, the one source of protected-path vocabulary) sourced
# first, and the sqlite3 CLI on PATH.

# refusal_ledger_targets <text> -> one protected-path token per line, sorted
# and deduped, exactly as _CP_POLICY_FILE_RE's own alternation names them
# (e.g. "run-registry.sh", "task-authorization.py").
refusal_ledger_targets() {
  local text="$1"
  [ -n "${_CP_POLICY_FILE_RE:-}" ] || return 0
  printf '%s' "$text" | grep -oE "$_CP_POLICY_FILE_RE" 2>/dev/null \
    | sed -E 's/^[^A-Za-z0-9]+//; s/[^A-Za-z0-9._-]+$//' \
    | sort -u
}

# A command that can emit every tracked file's content without naming any of
# them (git archive of a ref, piped into tar/unzip) is §5's one unresolved
# surface that free-text name matching above structurally cannot see. The
# narrow, traceable slice that IS in scope here: once this run+task has a
# real protected-path refusal on record, a later bulk git-archive extraction
# in that SAME run+task is flagged too. An unrelated run+task that never had
# a refusal is completely untouched.
_RL_BULK_EXTRACT_RE='\bgit[[:space:]]+archive\b'

# refusal_ledger_prior_refusals <run> <task> -> one TAB-separated
# "occurred_at<TAB>reason<TAB>command" row per prior approval_escalated
# event for this run+task, oldest first. Read-only SELECT against the live
# registry schema (events: sequence, event_id, run_id, task_id, type,
# occurred_at, payload -- lib/run-registry.sh's own CREATE TABLE).
refusal_ledger_prior_refusals() {
  local run="$1" task="$2" db
  [ -n "$run" ] && [ -n "$task" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  db="$(registry_db)"
  [ -r "$db" ] || return 0
  sqlite3 -separator "$(printf '\t')" "$db" \
    "SELECT occurred_at, payload FROM events
     WHERE run_id = $(_sq "$run") AND task_id = $(_sq "$task")
       AND type = 'approval_escalated'
     ORDER BY sequence;" 2>/dev/null \
  | while IFS="$(printf '\t')" read -r ts payload; do
      [ -n "$payload" ] || continue
      printf '%s\t%s\t%s\n' "$ts" \
        "$(printf '%s' "$payload" | jq -r '.reason // empty' 2>/dev/null)" \
        "$(printf '%s' "$payload" | jq -r '.command // empty' 2>/dev/null)"
    done
}

# refusal_ledger_check <run> <task> <text>
# Prints a refusal reason and returns 1 when <text> is a retry of an
# already-refused operation in this run+task (same protected path, named
# under any wording or tool that still reaches it; or a bulk git-archive
# after any protected-path refusal). Prints nothing and returns 0 otherwise
# (including: no run/task, no prior refusals, sqlite3/jq unavailable).
refusal_ledger_check() {
  local run="$1" task="$2" text="$3" ts reason cmd target row_targets any_prior=0
  [ -n "$run" ] && [ -n "$task" ] || return 0

  while IFS="$(printf '\t')" read -r ts reason cmd; do
    [ -n "$ts" ] || continue
    row_targets="$(refusal_ledger_targets "$cmd")"
    [ -n "$row_targets" ] || continue
    any_prior=1
    for target in $row_targets; do
      case " $(refusal_ledger_targets "$text") " in
        *" $target "*)
          printf 'retry of an already-refused operation on %s (refused %s: %s) — a tool refusal is final; not re-reviewable by rewording, splitting, or a different tool\n' \
            "$target" "$ts" "$reason"
          return 1
          ;;
      esac
    done
  done < <(refusal_ledger_prior_refusals "$run" "$task")

  if [ "$any_prior" = 1 ] && _cp_imatch "$_RL_BULK_EXTRACT_RE" "$text" 2>/dev/null; then
    printf 'bulk archive/extraction after an earlier protected-path refusal in this run+task — must be re-derived through a normal tool-approved call, not a bulk dump\n'
    return 1
  fi
  return 0
}
