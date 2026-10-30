#!/usr/bin/env bash
# lib/refusal-ledger.sh — "an approval-tool refusal is final" as a technical
# check, not only a conductor's memory rule.
#
# SPEC: .handoffs/SPEC.md. Design input:
# review/board-cd1eb3d/tmp/INCIDENT-RUNREG.md §5 (2026-10-29 run-registry.sh
# approval-denial incident). Independent review of the first cut (46b70fb,
# review/dashboard-091ae25/tmp/REVIEW-REFUSAL-46b70fb.md) REJECTED it: the
# matcher was literal-text regex on the retry, bypassed by quoting, a
# backslash escape, a simple shell variable, a glob, or case (findings
# B1/B2); the bulk rule missed `git -C …`/`git -c …` and a recursive `cp`
# of an already-extracted tree (B3); and a refusal whose recorded command
# named no protected file never armed anything, even though "unknown or
# executing tool approval remains human-only" on a multi-line eval or a
# script run by reference is this project's actual common refusal shape
# (B5). This revision fixes all four; see each function's header for which
# finding it closes.
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
# WIRING IS STILL NOT DONE, ON PURPOSE (owner decision, review finding B6):
# the only caller of refusal_ledger_check is verify-refusal-ledger.sh.
# Making a retry refused IN REAL TIME (not just detectable after) needs a
# change to whichever script decides that -- herdr-select.sh/
# scoped-policy.sh's peer_decide (both protected, per above), or the OMP
# tool_approval_requested hook (agent-hooks/omp-herdr-control.ts, not
# protected, but the single highest-blast-radius file in this repo: it
# decides for every tool call, for every worker, before any panel exists).
# That is exactly the kind of auth-adjacent change this project's own rules
# require a security-focused second reviewer for, which a single
# unattended run cannot supply for itself -- a governance owner decides
# this, not this file. See .handoffs/PROOF.md.
#
# NOT COVERED, DOCUMENTED RATHER THAN GUESSED (review "To clear" #1): a
# value built by executing something -- a command substitution, a
# non-shell interpreter concatenating strings (e.g. `python3 -c "'run-' +
# 'registry.sh'"`), or a variable whose value is itself unresolved at
# classification time -- is left alone. A text classifier must not
# execute the text it is classifying to find out what it would do.
# refusal_ledger_targets resolves exactly three bypass classes: shell
# quoting/backslash-escaping, a simple same-command `NAME=value` shell
# variable assignment, and a glob pattern matched with bash's own case/glob
# semantics -- the three the review named as concretely exploitable here
# (verify-refusal-ledger.sh's "not covered, by design" case documents the
# python3 -c boundary explicitly so it stays a stated gap, not a silent one).
# Also out of scope per INCIDENT-RUNREG.md §5 itself: a `read`/`grep` tool
# call never produces a herdr-select occurrence at all (no approval panel),
# so there is nothing here to attach a refusal event to; same for a human
# or conductor acting through their own shell, outside any gated tool
# channel.
#
# Read-only: this module issues a `SELECT ... FROM events` against the SAME
# registry.sqlite3 lib/run-registry.sh already owns (registry_db, sourced
# from run-registry.sh, used exactly like every verify-*.sh harness already
# queries that file directly for assertions) and never calls a write
# function, opens a write handle, or edits run-registry.sh itself.
#
# Requires lib/run-registry.sh (registry_db, _sq) and lib/command-policy.sh
# (_CP_POLICY_FILE_RE, _cp_imatch) sourced first, and the sqlite3 CLI on
# PATH.

# Hand-maintained, not parsed out of _CP_POLICY_FILE_RE: that pattern has
# one nested alternation (`task-authorization\.(py|sh)`), and a parser that
# gets depth-aware splitting subtly wrong would be a worse, silent version
# of exactly the bug this file exists to avoid. verify-refusal-ledger.sh
# asserts every name below actually matches _CP_POLICY_FILE_RE (typo/
# removal drift fails loudly) and that the regex's own top-level
# alternative count matches this list's line count (addition drift fails
# loudly too) -- drift is a committed test failure, not a silent gap.
_RL_PROTECTED_NAMES='gate-registry
approval-policy
herdr-select.sh
scoped-policy.sh
task-manifest.sh
run-registry.sh
task-authorization.py
task-authorization.sh
task-reservation.py
registry-bridge.sh
authorization.py
alert-gate.sh
prompt-parse.sh
command-policy.sh'

# _rl_normalize <text> -> <text> past the three resolvable bypass classes
# (review B1): a backslash before any character is removed (bash itself
# drops the backslash and keeps the character: `run-registr\y.sh` ->
# `run-registry.sh`); every quote character (', ", `) is stripped outright
# (`run-'registry'.sh` and `"run-registry.sh"` both fold to the unquoted
# text, same as what the shell would actually hand the program); and a
# same-command `NAME=value` shell-variable assignment is substituted into
# later `$NAME`/`${NAME}` references in the SAME text (`f=run-registry;
# cat "lib/$f.sh"` -> `cat lib/run-registry.sh`). Pure text substitution --
# a value that is itself a command substitution or another variable is
# left alone (documented above, not silently "resolved" wrong).
_rl_normalize() {
  local text out assign name val
  out="$(printf '%s' "$1" | sed -E 's/\\(.)/\1/g' | tr -d '"'"'"'`')"
  while IFS= read -r assign; do
    [ -n "$assign" ] || continue
    name="${assign%%=*}"; val="${assign#*=}"
    [ -n "$name" ] || continue
    out="${out//\$\{$name\}/$val}"
    out="${out//\$$name/$val}"
  done < <(printf '%s' "$out" | grep -oE '(^|[;&|[:space:]])[A-Za-z_][A-Za-z0-9_]*=[^][:space:];&|()]*' 2>/dev/null \
            | sed -E 's/^[;&|[:space:]]+//')
  printf '%s' "$out"
}

# refusal_ledger_targets <text> -> one protected-path token per line,
# lowercased, sorted and deduped. Two passes over the normalized text
# (_rl_normalize, above): a direct case-insensitive match against
# _CP_POLICY_FILE_RE (closes B2 -- APFS is case-insensitive by default, so
# `cat lib/RUN-REGISTRY.SH` reads the same bytes as the lowercase path and
# must match the same way), and a glob pass -- any whitespace/shell-
# metacharacter-delimited token containing `*`, `?`, or `[` is matched
# against every protected basename with bash's OWN case/glob semantics
# (`run-reg*.sh` matches `run-registry.sh` the same way the shell would
# resolve it; `set -f` around the split keeps THIS shell from pathname-
# expanding the token against the real filesystem first, which is the
# bug-for-bug reproduction of the shell's matching rule, not of its I/O).
# Everything is folded to lowercase on the way out so both sides of a
# comparison (the stored refusal's targets and a later retry's targets)
# are case-insensitive by construction, not by remembering to fold at
# every call site.
refusal_ledger_targets() {
  local text norm tok name
  text="$1"
  norm="$(_rl_normalize "$text")"
  {
    printf '%s' "$norm" | grep -oiE "$_CP_POLICY_FILE_RE" 2>/dev/null \
      | sed -E 's/^[^A-Za-z0-9]+//; s/[^A-Za-z0-9._-]+$//'
    set -f
    for tok in $(printf '%s' "$norm" | tr ';&|()<>' '       '); do
      case "$tok" in
        *[*?\[]*)
          tok="${tok##*/}"
          while IFS= read -r name; do
            [ -n "$name" ] || continue
            case "$name" in
              $tok) printf '%s\n' "$name" ;;
            esac
          done <<NAMES
$_RL_PROTECTED_NAMES
NAMES
          ;;
      esac
    done
    set +f
  } | tr '[:upper:]' '[:lower:]' | sort -u
}

# Bulk shapes that can emit a protected file's content without naming it
# (review B3, widened from the first cut's bare `\bgit[[:space:]]+archive\b`):
# `git archive` preceded by any number of `-C <path>` / `-c <key>=<val>`
# global options in either order (`git -C . archive HEAD`, `git -c
# foo=bar archive HEAD`, `git -C . -c x=y archive HEAD`), and a recursive
# `cp` of a directory (`cp -R`, `cp -r`, `cp --recursive`) -- this repo's
# actual 2026-10-29 incident shape was copying an already-extracted
# snapshot directory that happened to contain run-registry.sh, not naming
# the file itself.
_RL_BULK_EXTRACT_RE='\bgit([[:space:]]+-C[[:space:]]+[^[:space:]]+|[[:space:]]+-c[[:space:]]+[^[:space:]]+)*[[:space:]]+archive\b|\bcp[[:space:]]+(-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$)'

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
# already-refused protected path in this run+task (same file, under any
# wording/quoting/case/glob/variable that still resolves to it, or via a
# different shell verb -- refusal_ledger_targets, above); or a bulk
# archive/recursive-copy shape issued ANY TIME after ANY prior refusal in
# this run+task, filename-identified or not (review B5: a refusal whose
# command was clipped, withheld, or refused for an unrelated reason --
# e.g. "unknown or executing tool approval remains human-only" on a
# multi-line eval -- is this project's actual common refusal shape, and
# must arm the same suspicion a filename-specific refusal does). Prints
# nothing and returns 0 otherwise (including: no run/task, no prior
# refusals at all, sqlite3/jq unavailable).
refusal_ledger_check() {
  local run="$1" task="$2" text="$3" ts reason cmd target row_targets any_prior=0
  [ -n "$run" ] && [ -n "$task" ] || return 0

  while IFS="$(printf '\t')" read -r ts reason cmd; do
    [ -n "$ts" ] || continue
    any_prior=1
    row_targets="$(refusal_ledger_targets "$cmd")"
    [ -n "$row_targets" ] || continue
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
    printf 'bulk archive/recursive-copy after an earlier refusal in this run+task — must be re-derived through a normal tool-approved call, not a bulk dump\n'
    return 1
  fi
  return 0
}
