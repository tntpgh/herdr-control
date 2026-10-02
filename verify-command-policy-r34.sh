#!/usr/bin/env bash
# verify-command-policy-r34.sh — R3-4 (round-3 security review): the
# `handoffs_write` restriction in _cp_write_menu_verdict (lib/command-policy.sh)
# compared paths LEXICALLY only. A `.handoffs/ANSWER.md -> ../src/x` symlink
# (planted by some earlier approved bash `ln -s`) passed the exact-string
# `rel == ".handoffs/ANSWER.md"` match, so a write tool call targeting
# `.handoffs/ANSWER.md` would actually land on `src/x`, escaping the
# single-file restriction entirely even though the lexical path never left
# the worktree.
#
# Fix: refuse (escalate) when the real, symlink-resolved location of the one
# allowed path differs from its lexical path.
#
#   bash verify-command-policy-r34.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/command-policy.sh"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
wt="$work/wt"; mkdir -p "$wt/.handoffs" "$wt/src"
manifest='{"handoffs_write":"ANSWER.md"}'

printf '== the ordinary case: a real, non-symlinked ANSWER.md still allows ==\n'
out="$(_cp_write_menu_verdict 'Allow tool: write Path: .handoffs/ANSWER.md Content: hi' "$wt" "$manifest")"
[ "$out" = "allow" ] && ok "plain file (no symlink yet) allows" || bad "expected allow, got: $out"

printf '== R3-4: ANSWER.md is a symlink escaping to src/ -- must escalate, not allow ==\n'
ln -s ../src/x "$wt/.handoffs/ANSWER.md"
out="$(_cp_write_menu_verdict 'Allow tool: write Path: .handoffs/ANSWER.md Content: hi' "$wt" "$manifest")"
case "$out" in
  escalate:*) ok "symlinked ANSWER.md escalates instead of writing through to src/x: $out" ;;
  *) bad "expected escalate, got: $out" ;;
esac

printf '== a broken symlink (target does not exist yet) at the same path also escalates ==\n'
rm -f "$wt/.handoffs/ANSWER.md"
ln -s ../src/does-not-exist-yet "$wt/.handoffs/ANSWER.md"
out="$(_cp_write_menu_verdict 'Allow tool: write Path: .handoffs/ANSWER.md Content: hi' "$wt" "$manifest")"
case "$out" in
  escalate:*) ok "a broken symlink at the restricted path also escalates: $out" ;;
  *) bad "expected escalate, got: $out" ;;
esac

printf '== unrelated paths (not the restricted file) are unaffected by the symlink check ==\n'
rm -f "$wt/.handoffs/ANSWER.md"
out="$(_cp_write_menu_verdict 'Allow tool: write Path: src/other.txt Content: hi' "$wt" "$manifest")"
case "$out" in
  escalate:*) ok "a path outside .handoffs/ANSWER.md still escalates (manifest restriction, not a symlink finding): $out" ;;
  *) bad "expected escalate (manifest restricts writes to ANSWER.md only), got: $out" ;;
esac

printf '== no manifest at all: the broad allow for a non-symlinked worktree path is unaffected ==\n'
out="$(_cp_write_menu_verdict 'Allow tool: write Path: src/other.txt Content: hi' "$wt" "")"
[ "$out" = "allow" ] && ok "no handoffs_write restriction: unrestricted write still allows (unchanged by R3-4)" || bad "expected allow, got: $out"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
