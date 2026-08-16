#!/usr/bin/env bash
# lib/command-policy.sh — "is the shell command behind this prompt something
# peer automation may auto-answer, or does it need a human?"
#
# docs/control-plane-design.md's review correction 8: peer automation (an
# agent auto-pressing herdr-select.sh's option key on ANOTHER agent's
# behalf) may only answer OPERATIONAL prompts. Destructive, credential,
# production, or scope-changing prompts must ESCALATE to the human — never
# get auto-approved just because they happen to look like a tool-approval
# menu. This file is that boundary: it classifies the raw shell text behind
# a prompt, and every caller must treat anything but a bare "allow" as "do
# not auto-answer this."
#
# Provides: scannable_command <cmd>                    -> normalized text on stdout
#           classify_command <cmd> [run_id] [task_id]  -> verdict token (allow|escalate|deny)
#           classify_reason                             -> reason for the last classify_command
#
# The optional [run_id] [task_id] wire in the o2-readonly-flag feature: when
# both are given and lib/run-registry.sh's task_is_read_only says that task
# is marked read_only (spawn-task.sh --read-only), a command that is
# GENUINELY read-only (grep/cat/ls/find/git log|show|diff|status and
# similar — see _cp_read_only_command below) gets its "allow" verdict
# annotated and logged as a formal, auditable auto-pass instead of an
# unremarkable default. This NEVER changes an escalate/deny verdict into
# allow — it only labels a command the floor rules already allowed. See
# _cp_read_only_command's header for the exact, deliberately narrow shape of
# "genuinely read-only".
#
# Ported in spirit from yc-software/qm's src/policy/command-policy.ts — same
# five floor rules, same normalize-before-match shape — reimplemented here
# in bash because that is what herdr-select.sh is written in.
set -uo pipefail

# Every real caller captures classify_command's verdict via command
# substitution — `verdict=$(classify_command "$cmd")` — because the verdict
# token IS its stdout per the contract above. Command substitution forks a
# SUBSHELL: any plain variable classify_command sets there (e.g. a
# "last reason") dies with that subshell the instant `$(...)` returns, so a
# naive in-memory "last reason" reads back empty on the very next line —
# classify_reason runs back in the ORIGINAL shell, which never saw the
# assignment happen. `$$` is the one thing bash keeps stable across that
# fork (unlike $BASHPID, which is per-subshell), so a tiny file keyed by it
# bridges classify_command's subshell back to classify_reason's call in the
# parent. One file, overwritten every call — not a durable log, just enough
# to survive one fork; PIDs recycle, so nothing here grows unbounded.
#
# Lives under a 0700 directory, not the shared /tmp, and the path itself is
# not attacker-predictable-and-preseedable in the way a bare
# $TMPDIR/name.$$.reason would be: a co-resident user on a multi-user Linux
# box (macOS's TMPDIR is already a private per-user 0700 directory) could
# otherwise pre-create that exact path as a symlink to a victim file before
# this PID exists, and the plain `>` redirect below would follow it and
# clobber whatever it points at.
_cp_reason_file() {
  local d="${XDG_RUNTIME_DIR:-$HOME/.cache}/herdr-control"
  mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
  printf '%s/command-policy.%s.reason\n' "$d" "$$"
}

# ---- rule-severity accumulator ---------------------------------------------
# deny(2) > escalate(1) > allow(0). classify_command evaluates EVERY rule
# (built-in and operator) rather than returning on the first hit, because an
# operator rule might raise a command that only matched a lesser built-in
# rule (or none) up to deny — see the operator-rules section below. Keeping
# the strictest match (and its reason) as we go, instead of returning early,
# is what makes that "only ever tightens" invariant hold structurally rather
# than needing a special case.
_cp_best_v=0
_cp_best_r=""
_cp_consider() {                        # severity reason -> updates the running max
  local v="$1" r="$2"
  if [ "$v" -gt "$_cp_best_v" ]; then
    _cp_best_v="$v"
    _cp_best_r="$r"
  fi
}

_cp_match()  { printf '%s' "$2" | grep -qE  "$1" 2>/dev/null; }   # pattern text
_cp_imatch() { printf '%s' "$2" | grep -qiE "$1" 2>/dev/null; }   # pattern text (case-insensitive)

# ---- scannable_command ------------------------------------------------------
# Normalizes raw shell text into something the floor rules below can pattern
# match against, undoing the cheapest obfuscations first: `"rm" -rf` and
# `rm -rf` must scan identically, or a single pair of quotes defeats every
# rule in this file.
scannable_command() {
  if [ "$#" -lt 1 ]; then
    printf 'command-policy: scannable_command requires a <command> argument\n' >&2
    return 2
  fi
  local raw="$1" text
  text="$(_cp_strip_heredocs "$raw")"
  text="$(_cp_decode_ansi_c "$text")"
  # Blunt global strip of literal quote characters, AFTER the ANSI-C pass
  # above (which needs its own $'...' quoting intact to find and decode) —
  # doing this first would eat the very quotes that mark an ANSI-C string
  # and turn `$'\x2drf'` into unparseable garbage instead of `-rf`. This is
  # deliberately not real shell tokenizing (no escape-awareness, no
  # respecting `\"` inside a double-quoted string): a scanner is supposed to
  # be MORE willing to see through quoting than a real shell, not less —
  # false positives here just mean a human reviews something safe, false
  # negatives mean a destructive command auto-executes.
  text="$(printf '%s' "$text" | sed "s/['\"\\\\]//g")"
  text="$(_cp_flatten_substitutions "$text")"
  printf '%s' "$text"
}

# Heredoc bodies are DATA to the enclosing command unless that command is
# itself a shell — `cat <<EOF` just prints its body (mentioning "rm -rf" in
# a warning message is not a warning we need to raise), but `bash <<EOF`
# EXECUTES its body as shell script, so pattern text living only inside that
# body ("rm -rf /") is exactly as real a command as if it were typed
# unindented on the outer line. Getting this backwards in either direction
# is a bug: strip-always lets an attacker hide `rm -rf /` inside a
# `bash <<EOF` body and sail through as "allow"; keep-always turns every
# innocent `cat <<EOF` usage-text heredoc into a false escalation.
_cp_strip_heredocs() {
  local raw="$1" line out="" first=1
  local in_heredoc=0 delim="" strip_tabs=0 keep_body=0
  local drop_buf="" drop_first=1 had_dropped=0
  local chk prefix
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_heredoc" -eq 1 ]; then
      chk="$line"
      if [ "$strip_tabs" -eq 1 ]; then                       # POSIX <<- strips leading tabs from body AND terminator
        while [ "${chk:0:1}" = "$(printf '\t')" ]; do chk="${chk#?}"; done
      fi
      if [ "$chk" = "$delim" ]; then
        in_heredoc=0
        continue
      fi
      if [ "$keep_body" -eq 1 ]; then
        if [ "$first" -eq 1 ]; then out="$line"; first=0; else out="$out"$'\n'"$line"; fi
      else
        # Buffered, not discarded outright — see the fail-closed fallback
        # after the loop: an inert-looking body we never confirmed the END
        # of is a parsing anomaly, not a body we're entitled to drop.
        had_dropped=1
        if [ "$drop_first" -eq 1 ]; then drop_buf="$line"; drop_first=0; else drop_buf="$drop_buf"$'\n'"$line"; fi
      fi
      continue
    fi
    if [ "$first" -eq 1 ]; then out="$line"; first=0; else out="$out"$'\n'"$line"; fi
    if printf '%s' "$line" | grep -qE '<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*'; then
      delim="$(printf '%s' "$line" | sed -E -n "s/.*<<-?[[:space:]]*[\"']?([A-Za-z_][A-Za-z0-9_]*).*/\1/p")"
      if [ -n "$delim" ]; then
        in_heredoc=1
        strip_tabs=0
        printf '%s' "$line" | grep -qE '<<-' && strip_tabs=1
        # "Feeds a shell" = the text BEFORE this line's first << names a
        # shell binary (bash/sh/zsh/dash/ksh/ash), e.g. `bash <<EOF` or
        # `sh <<'EOF'`. Anything else (cat, tee, a custom function we can't
        # see inside) is treated as inert — a real limitation of a static
        # text scanner, not a parser, documented rather than hidden.
        keep_body=0
        prefix="${line%%<<*}"
        printf '%s' "$prefix" | grep -qE '\b(bash|sh|zsh|dash|ksh|ash)\b' && keep_body=1
      fi
    fi
  done <<CPEOF
$raw
CPEOF
  # Fail closed: input ended while still "inside" a heredoc whose terminator
  # never showed up — that is not a well-formed inert-data heredoc, it is
  # unparseable shell. Rather than have silently-buffered "inert" lines just
  # vanish (an attacker's easiest possible evasion: open a heredoc, never
  # close it), fold them back into the scan.
  if [ "$in_heredoc" -eq 1 ] && [ "$had_dropped" -eq 1 ]; then
    if [ "$first" -eq 1 ]; then out="$drop_buf"; else out="$out"$'\n'"$drop_buf"; fi
  fi
  printf '%s' "$out"
}

# Decodes $'...' ANSI-C strings (`$'\x2drf'` -> `-rf`) so a hex-escaped flag
# byte matches the same as a literal one — otherwise `rm $'\x2drf' /tmp/x`
# sails past the recursive-rm rule below untouched. Bounded to 64 quoted
# runs per command (generous for anything a human would write, and each
# iteration only ever consumes forward through the string, so it can't spin
# on adversarial input the way unbounded recursion could).
_cp_decode_ansi_c() {
  local rest="$1" out="" pre body decoded iter=0
  while [ "$iter" -lt 64 ]; do
    iter=$((iter + 1))
    case "$rest" in
      *\$\'*\'*) : ;;
      *) break ;;
    esac
    pre="${rest%%\$\'*}"
    rest="${rest#*\$\'}"
    body="${rest%%\'*}"
    rest="${rest#*\'}"
    decoded="$(printf '%b' "$body" 2>/dev/null)"
    out="$out$pre$decoded"
  done
  printf '%s' "$out$rest"
}

# Flattens $(...) and `...` command substitutions by dropping their syntax
# and leaving the inner source text inline, so a payload smuggled through a
# substitution ($(echo rm) -rf /tmp/x, `echo rm` -rf /tmp/x) is exposed to
# the same floor-rule matching as if it had been typed directly — we are
# NOT executing the substitution (that would run untrusted code just to
# decide whether to trust it), only exposing its literal source text.
#
# Bounded to 8 passes, matching the contract's documented depth limit. Each
# pass only rewrites INNERMOST, non-nested `$(...)`/`` `...` `` pairs
# ([^()]* / [^`]* admit no nested delimiter), so one pass unwinds exactly one
# level of nesting. 200 nested `$(` with no closing `)` never matches at
# all — the pass is a bounded, linear sed scan regardless — so this
# terminates promptly on adversarial input instead of trying to fully
# resolve arbitrary nesting depth.
_cp_flatten_substitutions() {
  local text="$1" depth=0
  while [ "$depth" -lt 8 ]; do
    depth=$((depth + 1))
    text="$(printf '%s' "$text" | sed -E 's/\$\(([^()]*)\)/ \1 /g; s/`([^`]*)`/ \1 /g')"
  done
  printf '%s' "$text"
}

# ---- read-only task auto-pass: is this command GENUINELY read-only? -------
# Deliberately narrow and deliberately separate from the floor-rule table
# above: this is never consulted to move a verdict OUT of escalate/deny (see
# classify_command's call site below — it only fires once best_v is already
# 0/allow), so a command that trips any floor or operator rule — including
# the credential-read rule, so `cat ~/.ssh/id_ed25519` still escalates even
# under a read-only task — is completely unaffected by this function. Its
# only job is deciding whether an already-"allow" command is safe to label
# and log as a formal read-only auto-pass, per spawn-task.sh --read-only.
#
# NOT a per-segment parse of "the" command: lib/prompt-parse.sh's
# prompt_command_text (classify_command's usual raw input, via herdr-
# select.sh) deliberately returns the WHOLE visible prompt region — menu
# header, the command, the question, and the numbered Yes/No options — not
# an isolated command string; see that function's own header comment for
# why a precise extraction is the wrong design here too. A strict "every
# line must independently be a safe verb" check would therefore never fire
# on a real capture (a "Do you want to proceed?" / "2. No" line never looks
# like grep/cat/ls), defeating the whole feature. So, same substring-scan
# philosophy as the floor rules above: a BLACKLIST of common mutation verbs
# and redirects is checked ANYWHERE in the text (catches a mutating verb
# hiding in a chain or in the noise around the real command, and covers gaps
# the floor rules don't — a bare `rm file`, `mkdir`, `npm install`, a
# non-force `git push`, `>` redirection), and only once that comes back
# clean does a POSITIVE match against the curated safe-verb allowlist (the
# "grep, cat, ls, find, git log/show/diff/status, and similar" set the
# read-only flag was scoped to) get to label the command. Both directions
# fail closed: an unmatched command is simply never labeled (no verdict
# change either way — see the best_v==0 gate at the call site), so erring
# broad on the blacklist or narrow on the allowlist only ever costs an
# unlabeled audit entry, never a wrongly-widened permission.
_CP_RO_SAFE_VERBS='(grep|egrep|fgrep|cat|less|more|head|tail|ls|pwd|echo|printf|diff|file|stat|tree|which|type|wc|whoami|date|du|df|ps)'
_CP_RO_GIT_SAFE_SUBCMDS='(log|show|diff|status|branch|remote|blame|describe|rev-parse|ls-files|shortlog)'
_CP_RO_MUTATION_BLACKLIST='\b(rm|mv|cp|mkdir|rmdir|touch|chmod|chown|chgrp|kill|dd|mkfs|truncate|tee|sed|npm|yarn|pnpm|pip|pip3|brew|apt|apt-get|docker|cargo|gem|push|commit|merge|rebase|checkout|reset|clean|stash|clone)\b|>>?|\|[[:space:]]*tee\b'

_cp_read_only_command() {               # normalized text -> 0 (yes) / 1 (no)
  local text="$1" positive=1
  _cp_match "$_CP_RO_MUTATION_BLACKLIST" "$text" && return 1
  if _cp_match '\bfind\b' "$text"; then
    _cp_match '(-delete\b|-exec\b)' "$text" && return 1
    positive=0
  fi
  if _cp_match '\bgit\b' "$text"; then
    _cp_match "git[[:space:]]+${_CP_RO_GIT_SAFE_SUBCMDS}\b" "$text" || return 1
    positive=0
  fi
  _cp_match "\b${_CP_RO_SAFE_VERBS}\b" "$text" && positive=0
  [ "$positive" -eq 0 ]
}

# lib/run-registry.sh's task_is_read_only/append_event, sourced ONLY when a
# caller actually supplies task identity — command-policy.sh must stay
# independently sourceable (verify-command-policy.sh sources only this
# file), so this dependency is optional and pulled in lazily rather than at
# the top of the file.
_cp_ensure_run_registry() {
  declare -F task_is_read_only >/dev/null 2>&1 && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$d/run-registry.sh" ] && . "$d/run-registry.sh"
}

# _cp_log_read_only_auto_pass <run_id> <task_id> <raw_command>
#
# Best-effort audit write via lib/run-registry.sh's own append_event — no new
# log file invented, per the task's "reuse whatever logging/audit mechanism
# ... already has" instruction.
_cp_log_read_only_auto_pass() {
  local run_id="$1" task_id="$2" raw="$3"
  _cp_ensure_run_registry
  declare -F append_event >/dev/null 2>&1 || return 1
  local cmd_record; cmd_record="$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-500)"
  append_event "$run_id" "$task_id" "read_only_auto_pass" \
    "$(jq -nc --arg c "$cmd_record" '{command:$c}')" >/dev/null 2>&1
}

# ---- the floor rule table (ported from qm's command-policy.ts) ------------
# Applies in EVERY posture — there is no "trusted mode" that skips these.
# Deny rules are checked ahead of require_approval ones so a command that
# happens to also match a lesser pattern is still denied, not merely
# escalated.
classify_command() {
  if [ "$#" -lt 1 ]; then
    printf 'command-policy: classify_command requires a <command> argument\n' >&2
    return 2
  fi
  local raw="$1" norm
  norm="$(scannable_command "$raw")"

  _cp_best_v=0
  _cp_best_r=""

  # deny — mkfs formats a block device with no confirmation of its own;
  # nothing downstream of "yes, run this" makes that reversible, so it is
  # never eligible for even a human-approved auto-answer.
  _cp_match '(^|[^A-Za-z0-9_./-])mkfs([.][A-Za-z0-9]+)?([[:space:]]|$)' "$norm" &&
    _cp_consider 2 "mkfs formats a block device outright — irreversible, never eligible for auto-approval"

  # deny — the classic `:(){ :|:& };:` fork-bomb function definition. No
  # legitimate command defines a function named ":"; matching just the
  # opener is enough and avoids depending on exact whitespace in the body.
  _cp_match ':\(\)[[:space:]]*\{' "$norm" &&
    _cp_consider 2 "fork-bomb function definition — exhausts the process table"

  # escalate — recursive rm (-r/-R/-rf/--recursive, any short-opt cluster
  # containing r/R) can delete an entire tree. Word- and flag-checked
  # independently (not "flag immediately after rm") so `rm file -r` and
  # obfuscated `$(echo rm) -rf x` (flattened above to `echo rm -rf x`) both
  # still trip it.
  { _cp_match '\brm\b' "$norm" &&
    _cp_match '(--recursive\b|(^|[[:space:]])-[A-Za-z]*[rR][A-Za-z]*([[:space:]]|$))' "$norm"; } &&
    _cp_consider 1 "recursive rm (-r/-R/--recursive) can delete an entire directory tree"

  # escalate — dd writing to a raw block device is exactly as irreversible
  # as the mkfs case above, just spelled differently.
  { _cp_match '(^|[^A-Za-z0-9_./-])dd([[:space:]]|$)' "$norm" && _cp_match 'of=/dev/' "$norm"; } &&
    _cp_consider 2 "dd writing to a raw device destroys it irreversibly"

  # escalate — recursive/wide-open chmod can strip protection from an
  # entire tree (world-writable secrets, executable payloads left in place).
  { _cp_match '\bchmod\b' "$norm" &&
    _cp_match '(--recursive\b|(^|[[:space:]])-[A-Za-z]*[rR][A-Za-z]*([[:space:]]|$))' "$norm"; } &&
    _cp_consider 1 "recursive chmod can strip protection from an entire tree"

  # escalate — find piping into rm/-delete walks and deletes a whole tree,
  # same blast radius as recursive rm but a different verb.
  { _cp_match '\bfind\b' "$norm" && _cp_match '(-delete\b|-exec[[:space:]]+rm\b)' "$norm"; } &&
    _cp_consider 1 "find -delete / -exec rm walks and deletes a whole tree"

  # escalate — git push --force/-f rewrites remote history other people may
  # already have pulled; the target branch needs a human's eyes, not an
  # automated yes. Flag matched as a CLUSTER (-uf, -fu, ...), not just a
  # bare -f, since git accepts short options combined.
  { _cp_match '\bgit\b' "$norm" && _cp_match '\bpush\b' "$norm" &&
    _cp_match '(^|[[:space:]])(-[A-Za-z]*f[A-Za-z]*|--force(-with-lease)?)([[:space:]]|$)' "$norm"; } &&
    _cp_consider 1 "git push --force/-f rewrites remote history"

  # escalate — DROP/TRUNCATE TABLE, case-insensitive (SQL keywords are
  # conventionally upper- or lower-case interchangeably).
  _cp_imatch '\bdrop[[:space:]]+table\b|\btruncate[[:space:]]+table\b' "$norm" &&
    _cp_consider 1 "DROP/TRUNCATE TABLE is an irreversible schema/data change"

  # escalate — fetch-and-execute, in ANY combination of downloader and
  # interpreter. Split into two independent rules on purpose: the old
  # single rule required the literal token "curl" AND a pipe into sh/bash,
  # so wget, base64-then-exec, and `python3 -c "$(curl …)"` (no pipe at
  # all — the substitution is flattened to inline text above, so this rule
  # alone catches it) all sailed through as "allow". A human should read
  # unreviewed remote code before it runs, regardless of which tool fetched
  # it or which interpreter runs it.
  _cp_match '\|[[:space:]]*(sh|bash|zsh|dash|ksh|python3?|perl|ruby|node)([[:space:]]|$)' "$norm" &&
    _cp_consider 1 "pipes data into an interpreter — executes unreviewed code"
  _cp_imatch '\b(curl|wget|fetch|aria2c)\b' "$norm" &&
    _cp_consider 1 "downloads from the network — pair with running the result unreviewed"

  # escalate — reads or ships credential material. This is the gap the
  # header comment above (and README/SKILL.md) already promised was
  # covered and was not: peer automation could auto-approve a prompt that
  # reads an SSH key or pipes ~/.aws/credentials to an external URL.
  _cp_imatch '\.ssh/|\.aws/|\.gnupg/|\.config/gcloud|id_(rsa|ed25519|ecdsa)\b|\.env(\.[A-Za-z0-9_-]+)?\b|\bcredentials\b' "$norm" &&
    _cp_consider 1 "reads credential material — a human must approve"
  _cp_imatch '(^|[[:space:]])(printenv|env)([[:space:]]|$)|\bop[[:space:]]+read\b|\bgh[[:space:]]+secret\b|\baws[[:space:]]+(configure|sts)\b|\bsecurity[[:space:]]+find-(generic|internet)-password\b' "$norm" &&
    _cp_consider 1 "enumerates or resolves secrets"

  # escalate — production / infrastructure scope change. A name-based
  # rule (matching the literal word "prod"/"production"/"live") is
  # necessarily approximate — it has no notion of which context is
  # actually production — but a false escalation just means a human looks
  # once at an operational command; a false allow means an unreviewed
  # agent prompt destroyed a live system.
  _cp_imatch '\b(prod|production|live)\b' "$norm" &&
    _cp_consider 1 "names a production target"
  _cp_imatch '\bterraform[[:space:]]+(apply|destroy)\b|\bkubectl\b.*\b(delete|drain|scale)\b|\bhelm[[:space:]]+(delete|uninstall)\b|\bflyctl?[[:space:]]+(deploy|destroy)\b' "$norm" &&
    _cp_consider 1 "infrastructure scope change"

  _cp_apply_operator_rules "$norm"

  # ---- read-only task auto-pass (o2-readonly-flag) --------------------------
  # Only ever consulted when the floor+operator rules ALREADY landed on
  # allow (best_v=0) — see _cp_read_only_command's header for why this can
  # never weaken an escalate/deny verdict for a write/mutating command. Task
  # identity is optional and caller-supplied (herdr-select.sh passes the
  # pane's own run_id/task_id via task_for_pane); omitted, this block is a
  # no-op and classify_command behaves exactly as before.
  local run_id="${2:-}" task_id="${3:-}"
  if [ "$_cp_best_v" -eq 0 ] && [ -n "$run_id" ] && [ -n "$task_id" ]; then
    _cp_ensure_run_registry
    if declare -F task_is_read_only >/dev/null 2>&1 && \
       [ "$(task_is_read_only "$run_id" "$task_id" 2>/dev/null)" = "1" ] && \
       _cp_read_only_command "$norm"; then
      _cp_best_r="read-only task auto-pass: genuinely read-only command, no per-command approval needed"
      _cp_log_read_only_auto_pass "$run_id" "$task_id" "$raw"
    fi
  fi

  case "$_cp_best_v" in
    2) printf 'deny\n' ;;
    1) printf 'escalate\n' ;;
    *) printf 'allow\n' ;;
  esac

  # Best-effort write-through for classify_reason (see _cp_reason_file's
  # header comment) — a TMPDIR write failure must never fail classification
  # itself, only degrade the audit reason to empty.
  _CP_LAST_REASON="$_cp_best_r"
  printf '%s\n' "$_cp_best_r" >"$(_cp_reason_file)" 2>/dev/null || true
  return 0
}

# ---- operator extension point ----------------------------------------------
# HERDR_POLICY_EXTRA_RULES: newline-separated records, each
# "<verdict><TAB><extended-regex><TAB><reason>", checked against the same
# normalized text as the floor rules. Operators use this to add site-local
# escalate/deny rules (e.g. "we never auto-answer kubectl delete in this
# shop") WITHOUT editing this file.
#
# INVARIANT, enforced structurally rather than by a special-cased check:
# operator rules can only ever ADD escalate/deny matches into the SAME
# _cp_consider() max-accumulator the built-in rules feed. `<verdict>` MUST
# be exactly "escalate" or "deny" — there is no operator verdict that means
# "allow", so there is no code path by which an operator rule can lower a
# built-in deny (or escalate). A malformed/unrecognized verdict is skipped
# with a stderr note, never silently treated as anything else.
_cp_apply_operator_rules() {
  local norm="$1" ov opat oreason osev
  while IFS=$'\t' read -r ov opat oreason || [ -n "$ov" ]; do
    [ -n "$ov" ] || continue
    case "$ov" in
      escalate) osev=1 ;;
      deny)     osev=2 ;;
      *)
        printf 'command-policy: ignoring malformed HERDR_POLICY_EXTRA_RULES verdict %s (want escalate|deny)\n' "$ov" >&2
        continue
        ;;
    esac
    [ -n "$opat" ] || continue
    if printf '%s' "$norm" | grep -qE "$opat" 2>/dev/null; then
      _cp_consider "$osev" "operator rule: ${oreason:-$opat}"
    fi
  done <<CPEOF2
${HERDR_POLICY_EXTRA_RULES:-}
CPEOF2
}

# The reason behind the LAST classify_command call on this $$, for audit
# records and the escalation message shown to the human. Empty when the
# verdict was "allow" (nothing needs explaining) or when classify_command
# has never run in this process.
classify_reason() {
  local f
  f="$(_cp_reason_file)"
  [ -r "$f" ] && cat "$f"
  return 0
}
