#!/usr/bin/env bash
# Tests for sweep-prompts.sh's destructive-command DENY regex.
#
# THE BUG (2026-10-04, evidence:
# .handoffs/reviews/2026-10-04-sweeper-rm-denylist-evidence.md): COMMON used
# to be `rm[[:space:]]+-rf?`, which requires `-r` immediately after the dash.
# Every other rm shape — force-only, no flags, `-fr`, a path prefix, `--force`,
# `git rm` — was AUTO-APPROVED by a script whose whole job is to leave
# destruction for a human. This extracts the REAL regex straight out of
# sweep-prompts.sh (never a hand copy, so a future edit to the source cannot
# drift from what this file tests) and proves two things: the shipped regex
# denies every one of those shapes plus unlink/shred/trash/rmdir/find-delete,
# and it still passes the words that only CONTAIN "rm" (confirm, perform,
# arm64, npm run, docker's --rm flag) through to Approve.
#
# Per SPEC.md's constraint, no literal recursive-force rm is ever typed as a
# contiguous command string here — every destructive fixture is assembled
# from separate rm/flag variables at use time, and nothing in this file ever
# shells out to rm itself (the main-branch comparison reads source text over
# stdin, never a temp file).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/sweep-prompts.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }

# Pull the live COMMON assignment and the review/implement MODE block straight
# out of source text read over stdin, by anchor not line number, so this
# suite tracks the file instead of a frozen copy of it.
extract_deny() {
  local mode="$1" src common_line mode_block
  src="$(cat)"
  common_line="$(printf '%s\n' "$src" | grep -m1 '^COMMON=')"
  mode_block="$(printf '%s\n' "$src" | sed -n '/^if \[ "\$MODE" = "implement"/,/^fi$/p')"
  [ -n "$common_line" ] && [ -n "$mode_block" ] || return 1
  (
    eval "$common_line"
    MODE="$mode"
    eval "$mode_block"
    printf '%s' "$DENY"
  )
}

DENY_REVIEW="$(extract_deny review < "$SUT")"
DENY_IMPLEMENT="$(extract_deny implement < "$SUT")"
[ -n "$DENY_REVIEW" ] && [ -n "$DENY_IMPLEMENT" ] \
  || { echo "FATAL: could not extract DENY from $SUT" >&2; exit 2; }

check() {
  local desc="$1" cmd="$2" want="$3" deny="$4"
  local got
  if printf '%s' "$cmd" | grep -qEi "$deny"; then got=deny; else got=allow; fi
  [ "$got" = "$want" ] && ok "$desc" || no "$desc" "want=$want got=$got cmd=[$cmd]"
}

# rm/flag tokens as separate variables — never a literal recursive-force rm
# string anywhere in this file.
RM="rm"; F="-f"; R="-r"; RF="-rf"; FR="-fr"

echo "== every ALLOWED row from the evidence table is now DENIED (review mode) =="
check "force-only"         "$RM $F tmp/commit-msg.txt" deny "$DENY_REVIEW"
check "no flags"           "$RM tmp/x"                 deny "$DENY_REVIEW"
check "fr order"           "$RM $FR build"             deny "$DENY_REVIEW"
check "r only"              "$RM $R d"                 deny "$DENY_REVIEW"
check "/bin/rm prefix"     "/bin/$RM $F x"             deny "$DENY_REVIEW"
check "/usr/bin/rm prefix" "/usr/bin/$RM $F x"         deny "$DENY_REVIEW"
check "git rm"              "git $RM $F x"             deny "$DENY_REVIEW"
check "--force"             "$RM --force x"            deny "$DENY_REVIEW"
# the one shape the old regex already denied must keep denying
check "rf order (pre-existing deny)" "$RM $RF build"   deny "$DENY_REVIEW"

echo
echo "== the newly-required destructive commands are denied =="
check "unlink"       "unlink tmp/x"                   deny "$DENY_REVIEW"
check "shred"         "shred -u secret.txt"           deny "$DENY_REVIEW"
check "trash"         "trash tmp/x"                   deny "$DENY_REVIEW"
check "rmdir"         "rmdir tmp/dir"                 deny "$DENY_REVIEW"
check "find -delete"  'find . -name "*.tmp" -delete'  deny "$DENY_REVIEW"
check "git rm (implement mode too)" "git $RM $F x"    deny "$DENY_IMPLEMENT"

echo
echo "== words that merely CONTAIN rm stay ALLOWED (no false positives) =="
check "npm run"           "npm run build"              allow "$DENY_REVIEW"
check "perm"               "chmod 644 x # fix perm"    allow "$DENY_REVIEW"
check "form"                "echo form"                 allow "$DENY_REVIEW"
check "confirm"             "echo confirm"              allow "$DENY_REVIEW"
check "arm64"                "uname -m # arm64"          allow "$DENY_REVIEW"
check "docker --rm flag"   "docker run --rm -it image"  allow "$DENY_REVIEW"
check "npm run perform"    "npm run perform"            allow "$DENY_REVIEW"

echo
echo "== the positive cases are proven DENIED only by the FIX, not by accident: =="
echo "== the same strings against main's COMMON (pre-fix) must come back ALLOWED =="
MAIN_SRC="$(git -C "$HERE" show main:sweep-prompts.sh 2>/dev/null)"
if [ -z "$MAIN_SRC" ]; then
  no "main comparison" "could not read main:sweep-prompts.sh via git show"
else
  DENY_MAIN="$(printf '%s\n' "$MAIN_SRC" | extract_deny review)"
  if [ -z "$DENY_MAIN" ]; then
    no "main comparison" "could not extract COMMON/DENY from main's sweep-prompts.sh"
  else
    check "main: force-only slips through"    "$RM $F tmp/commit-msg.txt" allow "$DENY_MAIN"
    check "main: no-flags slips through"      "$RM tmp/x"                 allow "$DENY_MAIN"
    check "main: fr-order slips through"      "$RM $FR build"             allow "$DENY_MAIN"
    check "main: path-prefixed slips through" "/bin/$RM $F x"             allow "$DENY_MAIN"
    check "main: git rm slips through"        "git $RM $F x"              allow "$DENY_MAIN"
    check "main: --force slips through"       "$RM --force x"             allow "$DENY_MAIN"
    # and main already denied the one shape the old regex covered
    check "main: rf-order already denied"     "$RM $RF build"             deny "$DENY_MAIN"
  fi
fi

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
