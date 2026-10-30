#!/usr/bin/env bash
# lib/refusal-ledger.sh — "an approval-tool refusal is final" as a technical
# check, not only a conductor's memory rule.
#
# SPEC: .handoffs/SPEC.md. Design input:
# review/board-cd1eb3d/tmp/INCIDENT-RUNREG.md §5 (2026-10-29 run-registry.sh
# approval-denial incident).
#
# Two independent reviews so far:
#  - 46b70fb (review/dashboard-091ae25/tmp/REVIEW-REFUSAL-46b70fb.md):
#    REJECT. Matching was literal-text regex, bypassed by quoting, a
#    backslash escape, a simple shell variable, a glob, or case; the bulk
#    rule missed `git -C …`/`git -c …` and a recursive `cp`; a filename-less
#    refusal armed nothing.
#  - a0e13dc (review/dashboard-091ae25/tmp/REVIEW-REFUSAL-a0e13dc.md):
#    REJECT. Fixed every B1-B5 input, but introduced a correctness bug
#    (R1, HIGH): the comparison joined multiple extracted targets with
#    SPACES while refusal_ledger_targets returns them NEWLINE-separated, so
#    any retry naming 2+ protected files (literal list, `lib/*`,
#    `find -exec`) matched nothing. Also flagged: brace expansion and
#    ANSI-C `\xHH` are pure syntax and should be resolved without executing
#    anything (R2); the bulk rule still missed `ditto`/`rsync`/`tar -c` of a
#    directory (R4); the header overstated how far a filename-less refusal
#    arms (R5, see refusal_ledger_check below).
# This revision fixes R1/R2/R4/R5; R3 (a symlink created in one call, read
# in a later one) is a documented gap, same as the other un-resolvable
# bypass classes below.
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
# NOT COVERED, DOCUMENTED RATHER THAN GUESSED: a classifier must not
# EXECUTE the text it is classifying to find out what it would do, so
# anything that needs real execution to resolve is left alone, and each
# class below has a committed verify-refusal-ledger.sh case proving it
# stays a STATED gap, not a silent one:
#  - a value built by running something: a command substitution
#    (`$(printf run-reg)istry.sh`), or a non-shell interpreter
#    concatenating/encoding strings (`python3 -c "'run-'+'registry.sh'"`).
#  - a value built by the `read` builtin from stdin/a here-string
#    (`read f <<< run-registry; cat lib/$f.sh`) -- only a same-command
#    `NAME=value` shell-variable ASSIGNMENT is resolved (_rl_normalize),
#    not an arbitrary builtin that happens to set a variable.
#  - a symlink created in one tool call and dereferenced by a later,
#    separate call (R3): the `ln -s <refused> tmp/x` call is itself
#    refused (it names the protected path), but a later `cat tmp/x` has no
#    protected-path token in its own text, and resolving it would mean
#    stat-ing argv tokens against a cwd this module is not given and does
#    not assume.
# Resolved WITHOUT executing anything, because they are pure shell/text
# syntax rather than something that needs a real interpreter (R2): simple
# backslash-escapes, quote characters, ANSI-C `\xHH` hex escapes, a single
# level of `{a,b,c}` brace expansion, a simple same-command `NAME=value`
# variable substitution, and a glob matched with bash's own case/glob
# semantics -- see _rl_normalize and refusal_ledger_targets below.
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

# _rl_resolve_hex_escapes <text> -> <text> with every `\xHH` (H = hex digit)
# replaced by the literal byte it encodes (`\x72` -> `r`). Pure arithmetic
# and printf-format-string octal escaping (`printf '%03o'`, then `printf
# "\OOO"`) -- never executes any part of <text> itself. Must run BEFORE the
# generic backslash de-escape in _rl_normalize, which would otherwise turn
# `\x72` into the three literal characters `x72` (review R2/a0e13dc: "normalize
# turns \x into x").
_rl_resolve_hex_escapes() {
  local rest="$1" out="" chunk hex dec oct char
  while case "$rest" in *'\x'[0-9A-Fa-f][0-9A-Fa-f]*) true ;; *) false ;; esac; do
    chunk="${rest%%\\x*}"
    rest="${rest#*\\x}"
    hex="${rest:0:2}"
    rest="${rest:2}"
    dec=$((16#$hex))
    oct=$(printf '%03o' "$dec")
    char=$(printf "\\${oct}")
    out="${out}${chunk}${char}"
  done
  printf '%s' "${out}${rest}"
}

# _rl_expand_braces_once <text> -> every `${opt}` alternative of the FIRST
# `{a,b,c}` group in <text>, one per line, as `prefix${opt}suffix` (bash's
# own brace-expansion rule, reimplemented as plain string slicing -- never
# `eval`, never a subshell running <text>, since <text> is untrusted input
# a classifier must not execute).
_rl_expand_braces_once() {
  local text="$1" pre rest mid post opt out=""
  pre="${text%%\{*}"
  rest="${text#*\{}"
  mid="${rest%%\}*}"
  post="${rest#"$mid"\}}"
  local IFS=','
  for opt in $mid; do
    out="${out}${pre}${opt}${post}
"
  done
  printf '%s' "$out"
}

# _rl_expand_braces <text> -> <text> plus every alternative of up to 4
# brace groups appended (newline-separated); a no-op when <text> has no
# `{a,b,c}` group. Bounded loop, not recursion into nested groups: this
# resolves the review's named cases (`run-regis{t,}ry.sh`,
# `{run-registry,x}.sh`) and any handful of separate top-level groups in
# one command; it does not attempt a full brace-expansion grammar (nested
# groups, `{a..z}` ranges) -- those stay an unlisted, low-value edge the
# same way a deliberately obfuscated command substitution does.
_rl_expand_braces() {
  local text="$1" i
  for i in 1 2 3 4; do
    case "$text" in
      *'{'*,*'}'*) text="$(_rl_expand_braces_once "$text")" ;;
      *) break ;;
    esac
  done
  printf '%s' "$text"
}

# _rl_normalize <text> -> <text> past every resolvable bypass class
# (review B1 and R2): ANSI-C `$'...'` quoting is folded to plain `'...'`
# quoting so the existing quote-strip also strips it; `\xHH` hex escapes
# are resolved to their literal byte (_rl_resolve_hex_escapes, BEFORE the
# generic strip below would mangle them); a backslash before any other
# character is removed, same as what the shell itself does
# (`run-registr\y.sh` -> `run-registry.sh`); every quote character
# (', ", `) is stripped outright; a same-command `NAME=value` shell-variable
# assignment is substituted into later `$NAME`/`${NAME}` references in the
# SAME text (`f=run-registry; cat "lib/$f.sh"` -> `cat lib/run-registry.sh`);
# and a single level of `{a,b,c}` brace expansion is appended
# (_rl_expand_braces). Pure text substitution throughout -- a value that is
# itself a command substitution, a `read`-assigned variable, or another
# interpreter's string concatenation is left alone (documented above, not
# silently "resolved" wrong).
_rl_normalize() {
  local text out assign name val
  text="$(printf '%s' "$1" | sed -E "s/\\\$'/'/g")"
  text="$(_rl_resolve_hex_escapes "$text")"
  out="$(printf '%s' "$text" | sed -E 's/\\(.)/\1/g' | tr -d '"'"'"'`')"
  while IFS= read -r assign; do
    [ -n "$assign" ] || continue
    name="${assign%%=*}"; val="${assign#*=}"
    [ -n "$name" ] || continue
    out="${out//\$\{$name\}/$val}"
    out="${out//\$$name/$val}"
  done < <(printf '%s' "$out" | grep -oE '(^|[;&|[:space:]])[A-Za-z_][A-Za-z0-9_]*=[^][:space:];&|()]*' 2>/dev/null \
            | sed -E 's/^[;&|[:space:]]+//')
  out="$(_rl_expand_braces "$out")"
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
# every call site. Returns EVERY target found, one per line -- a retry can
# legitimately resolve to 2+ names (`cat a.sh b.sh`, `lib/*`, `find -exec`);
# refusal_ledger_check below (R1) compares line-by-line, not by assuming
# there is only one.
refusal_ledger_targets() {
  local text norm tok name
  text="$1"
  norm="$(_rl_normalize "$text")"
  {
    printf '%s\n' "$norm" | grep -oiE "$_CP_POLICY_FILE_RE" 2>/dev/null \
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
# (review B3/R4, widened across two review rounds from the first cut's
# bare `\bgit[[:space:]]+archive\b`): `git archive` preceded by any number
# of `-C <path>` / `-c <key>=<val>` global options in either order; a
# recursive `cp` of a directory (`cp -R`, `cp -r`, `cp --recursive`); macOS
# `ditto` (always a recursive copy for a directory source, no flag
# required); `rsync` with a recursive/archive flag (`-a`, `-r`,
# `--recursive`, `--archive`); and `tar` creating an archive (`tar cf`,
# `tar -cf`, `tar -czf`, `tar --create`, with or without the leading dash
# BSD tar allows) -- this repo's actual 2026-10-29 incident shape was
# copying an already-extracted snapshot directory, not naming the file.
_RL_BULK_EXTRACT_RE='\bgit([[:space:]]+-C[[:space:]]+[^[:space:]]+|[[:space:]]+-c[[:space:]]+[^[:space:]]+)*[[:space:]]+archive\b'
_RL_BULK_EXTRACT_RE="${_RL_BULK_EXTRACT_RE}"'|\bcp[[:space:]]+(-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$)'
_RL_BULK_EXTRACT_RE="${_RL_BULK_EXTRACT_RE}"'|\bditto\b'
_RL_BULK_EXTRACT_RE="${_RL_BULK_EXTRACT_RE}"'|\brsync\b[^|&;]*(-[A-Za-z]*[raA][A-Za-z]*\b|--recursive\b|--archive\b)'
_RL_BULK_EXTRACT_RE="${_RL_BULK_EXTRACT_RE}"'|\btar\b[[:space:]]+-{0,2}[A-Za-z]*c[A-Za-z]*\b'

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
# Prints a refusal reason and returns 1 in either of two cases:
#  1. STAGE 1 -- <text> resolves (refusal_ledger_targets) to the SAME
#     protected-path target as a PRIOR REFUSAL ROW THAT ITSELF NAMED ONE,
#     in this run+task. <text> can resolve to any number of targets (R1
#     fix: compared one at a time against every target of every prior row,
#     not as a single space-joined string -- `cat a.sh b.sh`, `lib/*`, and
#     `find -exec` all match correctly now). A refusal whose own recorded
#     command named no protected file (a withheld/clipped panel, or a
#     refusal for an unrelated reason, e.g. "unknown or executing tool
#     approval remains human-only" on a multi-line eval) contributes NO
#     stage-1 target -- there is nothing to compare <text> against, so a
#     literal/glob retry after ONLY a filename-less refusal is NOT caught
#     by this stage (review R5/R3: a documented limit, not silently
#     "handled"; see the stage-2 case below for what a filename-less
#     refusal DOES still arm).
#  2. STAGE 2 -- <text> is a bulk archive/recursive-copy shape
#     (_RL_BULK_EXTRACT_RE) issued ANY TIME after ANY prior refusal in this
#     run+task, whether or not that refusal itself named a file. A bulk
#     dump can walk past a protected path without ever typing its name, so
#     this stage arms on the mere fact of a prior refusal, not on what it
#     named.
# Prints nothing and returns 0 otherwise (including: no run/task, no prior
# refusals at all, sqlite3/jq unavailable).
refusal_ledger_check() {
  local run="$1" task="$2" text="$3" ts reason cmd target row_targets any_prior=0 text_targets
  [ -n "$run" ] && [ -n "$task" ] || return 0
  text_targets="$(refusal_ledger_targets "$text")"

  while IFS="$(printf '\t')" read -r ts reason cmd; do
    [ -n "$ts" ] || continue
    any_prior=1
    row_targets="$(refusal_ledger_targets "$cmd")"
    [ -n "$row_targets" ] || continue
    for target in $row_targets; do
      if printf '%s\n' "$text_targets" | grep -qxF "$target"; then
        printf 'retry of an already-refused operation on %s (refused %s: %s) — a tool refusal is final; not re-reviewable by rewording, splitting, or a different tool\n' \
          "$target" "$ts" "$reason"
        return 1
      fi
    done
  done < <(refusal_ledger_prior_refusals "$run" "$task")

  if [ "$any_prior" = 1 ] && _cp_imatch "$_RL_BULK_EXTRACT_RE" "$text" 2>/dev/null; then
    printf 'bulk archive/recursive-copy after an earlier refusal in this run+task — must be re-derived through a normal tool-approved call, not a bulk dump\n'
    return 1
  fi
  return 0
}
