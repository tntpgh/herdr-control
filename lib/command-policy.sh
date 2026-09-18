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
# Provides: scannable_command <cmd>   -> normalized text on stdout
#           classify_command <cmd>    -> verdict token (allow|escalate|deny)
#           classify_reason           -> reason for the last classify_command
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
  # BYTES, not characters. Every transform below is a `sed`, and in a UTF-8
  # locale BSD sed aborts with "RE error: illegal byte sequence" on the first
  # invalid byte — the substitution then captures nothing and this function
  # returns the EMPTY STRING. That is a fail-open in the floor rule table
  # itself: with one 0xFF byte appended, a push to the default branch went
  # from `reserved: human-only` to classify=allow, reservation=none, and
  # `--authority peer` would press Approve (proved 2026-09-12, detonation
  # pass F2). A worker only has to emit one stray byte — a latin-1 filename
  # in `ls`, a corrupt log line — for its own pane's scrollback to disarm the
  # classifier. Under LC_ALL=C sed treats input as bytes and cannot fail this
  # way; the patterns here are all ASCII, so nothing else changes.
  local LC_ALL=C LANG=C
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
  # A backslash-newline continuation is one logical line to the shell, and
  # the matchers below are line-scoped — `gh pr \<newline>merge 5` used to
  # read as two harmless halves (PR #57 review, F2). Fold it before the
  # quote/backslash strip below eats the backslash.
  text="$(printf '%s' "$text" | sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba' -e '}')"
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
  #
  # Narrowed 2026-09-18: 16 of 142 escalations in the recorded worker corpus
  # were `rm -rf dist`, `rm -rf __pycache__`, `rm -rf node_modules` — build
  # artifacts inside the worker OWN worktree, which is the thing a worker is
  # expected to rebuild. A recursive rm whose every target is relative and
  # glob-free cannot escape the working directory, so it no longer wakes
  # anyone. Anything absolute, home-anchored, parent-relative or globbed still
  # does: `/`, `~`, `$HOME`, `..`, `*` all keep the escalation, and so does a
  # scratch path under /tmp — deliberately, because "outside the worktree" is
  # the line, not "harmless in my judgement".
  { _cp_match '\brm\b' "$norm" &&
    _cp_match '(--recursive\b|(^|[[:space:]])-[A-Za-z]*[rR][A-Za-z]*([[:space:]]|$))' "$norm" &&
    _cp_match '\brm\b[^;&|]*[[:space:]](/|~|\$HOME|\$\{HOME|\.\.([[:space:]]|/|$)|[^[:space:]]*\*)' "$norm"; } &&
    _cp_consider 1 "recursive rm of a path outside the working tree can delete anything"

  # deny — recursive rm of the filesystem root, or of a bare HOME, is the same
  # class as mkfs and dd-to-a-raw-device above: irreversible, and never
  # eligible for auto-approval by anybody. It was only ESCALATE, which is a
  # gap — escalate means one keypress from a menu that does not show the blast
  # radius. A path UNDER root or home stays escalate; this is only the root
  # itself, with or without a trailing glob.
  { _cp_match '(--recursive\b|(^|[[:space:]])-[A-Za-z]*[rR][A-Za-z]*([[:space:]]|$))' "$norm" &&
    _cp_match '\brm\b[^;&|]*[[:space:]](/|~|\$HOME|\$\{HOME\})(\*|[[:space:]]|$)' "$norm"; } &&
    _cp_consider 2 "recursive rm of the filesystem root or home — irreversible, never auto-approvable"

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
  # interpreter. Split into independent rules on purpose: the old single rule
  # required the literal token "curl" AND a pipe into sh/bash, so wget,
  # base64-then-exec, and `python3 -c "$(curl …)"` (no pipe at all — the
  # substitution is flattened to inline text above, so this rule alone catches
  # it) all sailed through as "allow". A human should read unreviewed remote
  # code before it runs, regardless of which tool fetched it or which
  # interpreter runs it.
  #
  # What changed 2026-09-18, measured against 1,614 distinct commands real
  # workers ran (extracted from their session transcripts): 142 escalated, and
  # the largest class was this rule firing on the DOWNLOAD ALONE — 24 read-only
  # GETs whose output went to a pipe or stdout, plus 11 `git fetch`. Reading a
  # deployed page is how a review lane checks its own subject; it executes
  # nothing. The rule now matches what its own comment always claimed: a
  # download PAIRED with running it, a download that lands a FILE you could run
  # later, or a request that SENDS data.

  # stdin becomes the program: for a shell there is no other reading of it.
  _cp_match '\|[[:space:]]*(sh|bash|zsh|dash|ksh)([[:space:]]|$)' "$norm" &&
    _cp_consider 1 "pipes data into a shell — stdin becomes the program"
  # For python/perl/ruby/node, stdin is the program ONLY when no inline program
  # was given. `curl … | python3 -c "import json…"` pipes DATA into a program
  # that is fully visible in the prompt being reviewed, which is not the same
  # act as `| sh` at all — 3 of the 7 hits on this rule were exactly that.
  { _cp_match '\|[[:space:]]*(python3?|perl|ruby|node)([[:space:]]|$)' "$norm" &&
    ! _cp_match '\|[[:space:]]*(python3?|perl|ruby|node)[[:space:]]+-[A-Za-z]*[cem]([[:space:]]|$)' "$norm"; } &&
    _cp_consider 1 "pipes data into an interpreter — stdin becomes the program"

  # A downloader is a COMMAND, not a substring. Matching the bare words meant
  # `git fetch` (the first step of every review lane), `node scripts/
  # fetch-reviews.js`, and any path with "curl" in its name all counted as
  # network downloads — 35 of the 43 hits on this rule in the recorded worker
  # corpus were exactly that, and each one woke a human. The token now has to
  # sit where a command goes: at the start, after a separator, or behind the
  # usual prefixes (sudo/env/timeout/xargs/--). `git fetch` no longer needs a
  # special case, because `fetch` there is a SUBCOMMAND, not a command.
  # `-[A-Za-z]*[cem]` is in the prefix set because the normalizer above erases
  # `$( )`, so `python3 -c "$(curl …)"` flattens to `python3 -c  curl …` and the
  # downloader IS the command there — it just lost its punctuation.
  _cp_dl_cmd='(^|[;&|(){]|&&|\|\||[[:space:]](sudo|nohup|xargs|exec|eval|time|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)*|timeout([[:space:]]+-[^[:space:]]+)*[[:space:]]+[0-9]+[A-Za-z]?|do|then|else|--|-[A-Za-z]*[cem])[[:space:]])[[:space:]]*(curl|wget|fetch|aria2c)([[:space:]]|$)'
  _cp_downloader=0
  _cp_imatch "$_cp_dl_cmd" "$norm" && _cp_downloader=1

  # Paired with execution — the case this rule exists for. The pipe-into-shell
  # and pipe-into-bare-interpreter shapes are NOT repeated here: the two rules
  # above already fire on them independently, and repeating them would undo the
  # inline-program exception (`curl … | python3 -c "…"` is data, not code).
  # What is left is the execution this classifier would otherwise miss: running
  # a downloaded script file, making one executable, `eval`, a base64 decode
  # feeding a run, and the substitution form (`python3 -c "$(curl …)"`), where
  # the downloaded text IS the inline program — recognisable because the
  # downloader appears AFTER the inline flag with no pipe between them.
  [ "$_cp_downloader" = 1 ] &&
    _cp_match '((^|[[:space:]])(sh|bash|zsh|dash|ksh|python3?|perl|ruby|node)[[:space:]]+[^[:space:]]*\.(sh|py|pl|rb|js)([[:space:]]|$)|\bchmod[[:space:]]+[^[:space:]]*\+x|\beval\b|\bbase64[[:space:]]+(-d|--decode)\b|(python3?|perl|ruby|node)[[:space:]]+-[A-Za-z]*[ce]([[:space:]])[^|]*\b(curl|wget|aria2c)\b)' "$norm" &&
    _cp_consider 1 "downloads and then runs it — unreviewed remote code"

  # Lands a PROGRAM you could run in a later command, which this classifier
  # never sees. curl writes to stdout unless told otherwise; wget/fetch/aria2c
  # save a file unless told otherwise, so the default flips per tool.
  #
  # A landed file is only interesting if it could be executed. Saving a page,
  # a JSON body or a markdown doc to /tmp and grepping it is how a worker
  # inspects a deploy — 24 of the remaining escalations were exactly that — so
  # known data extensions are exempt and everything else (a script extension,
  # or no extension at all) still stops for a human.
  #
  # Two more exemptions, both measured rather than guessed:
  #   * `-o /dev/null` lands NOTHING. It is the standard idiom for wanting only
  #     the status line (`curl -s -o /dev/null -w "%{http_code}"`), which is how
  #     every worker smoke-tests a URL.
  #   * a loopback URL is not remote code. `curl http://localhost:4173/…` talks
  #     to the build this same worker just started; the unreviewed-remote-code
  #     risk this rule exists for does not exist there. A loopback request that
  #     MUTATES is still caught below, by the data-sending rule.
  _cp_data_out='(\.(html?|json|xml|csv|tsv|txt|md|log|ya?ml|png|jpe?g|gif|svg|pdf|ico|woff2?)([[:space:]]|$|["'"'"'])|-[oO][[:space:]]*/dev/null|--output[[:space:]]*/dev/null)'
  _cp_loopback='https?://(localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0)([:/[:space:]]|$)'
  [ "$_cp_downloader" = 1 ] &&
    { _cp_imatch '\bcurl\b[^;&]*((^|[[:space:]])-[A-Za-z]*[oO]([[:space:]]|$)|--output\b|--remote-name\b)' "$norm" ||
      _cp_match "$_cp_dl_cmd"'[^;&|]*>[[:space:]]*[^[:space:]]' "$norm" ||
      { _cp_imatch '(^|[;&|(){]|&&|\|\||[[:space:]](sudo|xargs|--)[[:space:]])[[:space:]]*(wget|fetch|aria2c)([[:space:]]|$)' "$norm" &&
        ! _cp_match '(-O[[:space:]]*-|--output-document=-|-qO-)' "$norm"; }; } &&
    ! _cp_imatch "$_cp_data_out" "$norm" &&
    ! _cp_imatch "$_cp_loopback" "$norm" &&
    _cp_consider 1 "downloads a program to disk — it can be run by a later command"

  # Sending data out is not reading the web: a GET is inert, but a POST/PUT, a
  # form or file upload, or an inline body can mutate a remote system or carry
  # a secret off this machine.
  [ "$_cp_downloader" = 1 ] &&
    _cp_imatch '(-X[[:space:]]*(POST|PUT|PATCH|DELETE)|--request[[:space:]]+(POST|PUT|PATCH|DELETE)|(^|[[:space:]])-d([[:space:]]|=)|--data(-raw|-binary|-urlencode|-ascii)?([[:space:]]|=)|(^|[[:space:]])-F([[:space:]]|=)|--form([[:space:]]|=)|(^|[[:space:]])-T([[:space:]]|=)|--upload-file|--json([[:space:]]|=))' "$norm" &&
    _cp_consider 1 "sends data to the network — remote mutation or an exfiltration path"

  # escalate — reads or ships credential material. This is the gap the
  # header comment above (and README/SKILL.md) already promised was
  # covered and was not: peer automation could auto-approve a prompt that
  # reads an SSH key or pipes ~/.aws/credentials to an external URL.
  _cp_imatch '\.ssh/|\.aws/|\.gnupg/|\.config/gcloud|id_(rsa|ed25519|ecdsa)\b|\.env(\.[A-Za-z0-9_-]+)?\b|\bcredentials\b' "$norm" &&
    _cp_consider 1 "reads credential material — a human must approve"
  _cp_imatch '(^|[[:space:]])(printenv|env)([[:space:]]|$)|\bop[[:space:]]+read\b|\bgh[[:space:]]+secret\b|\baws[[:space:]]+(configure|sts)\b|\bsecurity[[:space:]]+find-(generic|internet)-password\b' "$norm" &&
    _cp_consider 1 "enumerates or resolves secrets"

  # escalate — production / infrastructure scope change. A name-based rule is
  # necessarily approximate: it has no notion of which context is actually
  # production. The old form matched the bare word anywhere, on the reasoning
  # that "a false escalation just means a human looks once". Measured against
  # the recorded worker corpus that reasoning does not hold — every single hit
  # was a LOCAL name: `cp -r dist dist-prod-verified`, a pytest node id with
  # "production" in it, `pkill -f "serve dist"` next to a prod-named folder.
  # None of them could touch a live system, and each one woke a human.
  #
  # So the word now has to appear where a TARGET goes: a selector flag, an
  # environment assignment, a remote-session command, or a hostname. The
  # dangerous shapes are unchanged — `kubectl --context production delete …`,
  # `wrangler deploy --env production`, `ssh prod`, `psql …@live.…` — and the
  # infrastructure-verb rule below is untouched and independent.
  _cp_imatch '(--(context|env|environment|profile|namespace|target|app|stage|remote|host)([[:space:]]+|=)[^[:space:]]*(prod|production|live)|(^|[[:space:]])-[aeEpn][[:space:]]+(prod|production|live)([[:space:]]|$)|\b(NODE_ENV|APP_ENV|RAILS_ENV|DEPLOY_ENV|ENV|STAGE)=(prod|production|live)\b|\b(ssh|scp|rsync|psql|mysql|redis-cli|mongosh|wrangler|vercel|netlify|fly|heroku)\b[^;&|]*\b(prod|production|live)\b|\b(prod|production|live)\.[a-z0-9][a-z0-9.-]*\b)' "$norm" &&
    _cp_consider 1 "names a production target"
  _cp_imatch '\bterraform[[:space:]]+(apply|destroy)\b|\bkubectl\b.*\b(delete|drain|scale)\b|\bhelm[[:space:]]+(delete|uninstall)\b|\bflyctl?[[:space:]]+(deploy|destroy)\b' "$norm" &&
    _cp_consider 1 "infrastructure scope change"

  _cp_apply_operator_rules "$norm"

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

# Human-reserved actions under the reviewed-operational conductor grant.
# This is a conservative accident guard, not an interpreter/sandbox. Indirect
# scripts still require the trusted conductor to inspect their complete body.
# Operator-added restrictions remain hard stops even when a built-in rule
# with equal severity supplied classify_reason's first-match explanation.
conductor_reserved_reason() {
  local norm
  norm="$(scannable_command "$1")"
  _cp_best_v=0; _cp_best_r=""
  _cp_apply_operator_rules "$norm"
  if [ "$_cp_best_v" -gt 0 ]; then printf '%s\n' "$_cp_best_r"; return; fi
  # Widened 2026-09-12 (security review of PR #57, findings F2–F6): once the
  # peer path relies on this list, every gap here is a peer-pressed Approve.
  # `gh -R o/r pr merge`, `gh api -X PUT …/merge`, `gh pr review --approve`,
  # bare `git push` / `--all` / `--mirror` (upstream may be main), agent
  # flags that switch approvals off, edits to the two policy scripts, the gh
  # OAuth token file and bare env dumps were all classify=allow + unreserved.
  if _cp_imatch '\.ssh/|\.aws/|\.gnupg/|\.config/gcloud|\.config/gh/hosts\.yml|\.netrc\b|\.npmrc\b|\.pypirc\b|\.env(\.[A-Za-z0-9_-]+)?\b|id_(rsa|ed25519|ecdsa)\b|\bcredentials\b|(^|[[:space:]])(printenv|env)([[:space:]]|$)|(^|[;[:space:]])(export|set)[[:space:]]*($|;)|\bdeclare[[:space:]]+-p\b|\bop[[:space:]]+(read|item[[:space:]]+get)\b|\bsecurity[[:space:]]+find-(generic|internet)-password\b' "$norm"; then
    printf 'credential-value access remains human-only\n'
  elif _cp_imatch '\b(wrangler|fly|flyctl)[[:space:]]+(deploy|publish|destroy|secrets)\b|\bterraform[[:space:]]+(apply|destroy)\b|\bkubectl\b.*\b(apply|delete|drain|scale|exec)\b|\bhelm[[:space:]]+(install|upgrade|delete|uninstall)\b|\bcurl\b.*(-X[[:space:]]*(POST|PUT|PATCH|DELETE)|--data|-d[[:space:]])|\bgh\b.*\bapi\b.*(-X[[:space:]]*(POST|PUT|PATCH|DELETE)|--method[[:space:]=]*(POST|PUT|PATCH|DELETE)|-f[[:space:]]|-F[[:space:]]|--input\b)|\bgh\b.*\bapi\b.*/(merge|merges)\b' "$norm"; then
    printf 'remote mutation remains human-only\n'
  # KNOWN GAP, deliberately not closed here (detonation pass F3): a worktree
  # standing on the default branch makes `git push origin HEAD` a push to main
  # without the word ever appearing. Reserving every `push … HEAD` would catch
  # it — and would also catch `git push -u origin HEAD`, which is how every
  # spawned worker publishes its feature branch, so every worker would escalate
  # to a human and the alert flood this week's work removed would come straight
  # back. Resolving HEAD needs the pane's repo, which a text scanner does not
  # have; the fix belongs in a repo-aware check, not another regex. Bare
  # `git push` and `git -C <dir> push` ARE reserved below, because those are
  # rare in worker traffic and cost nothing to stop.
  elif _cp_imatch '\bgh\b.*\bpr\b.*\bmerge\b|\bgh\b.*\bpr\b.*\breview\b.*--approve|\bgh\b.*\balias[[:space:]]+set\b|\bgit\b.*\bpush\b.*\b(main|master)\b|\bgit\b.*\bpush\b.*(--all\b|--mirror\b)|(^|[;[:space:]])git([[:space:]]+-[A-Za-z]+[[:space:]]+[^[:space:]]+)*[[:space:]]+push[[:space:]]*($|;)|\b(gate-registry|approval-policy|command-policy\.sh|herdr-select\.sh)\b|--auto-approve|--dangerously-skip-permissions|--approval-mode[=[:space:]]+yolo|(^|[[:space:]])-a[[:space:]]+yolo\b|--yolo\b|--full-auto\b|--permission-mode[=[:space:]]+bypass' "$norm"; then
    printf 'merge, governance, or control weakening remains human-only\n'
  fi
}
