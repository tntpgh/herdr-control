#!/usr/bin/env bash
# Tests for lib/prompt-parse.sh's approval-menu parser.
#
# The load-bearing behaviour is the pair: it must RECOGNISE a menu whose
# "Allow tool:" header has scrolled off-screen, and it must still FAIL CLOSED
# on anything that merely resembles one. Both halves matter and they pull in
# opposite directions:
#
#   * refuse a real menu  -> the pane cannot be answered by keypress at all,
#     which strands a worker. Observed 2026-09-13: an `eval` approval with a
#     ~1.2 kB body put its header outside every readable window, so
#     prompt_menu_options returned nothing and herdr-select.sh refused with
#     "not showing a prompt this script recognises" while Approve/Deny sat
#     visibly on screen. The only ways out were a blind Enter (which accepts
#     whatever is highlighted) or a human pressing the key.
#   * accept a non-menu  -> herdr-select arrow-walks toward a row that does
#     not exist, or presses Enter on unrelated content.
#
# No live pane needed: _menu_window is a shell function, so each case
# redefines it to emit a fixture. That keeps the production path untouched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/prompt-parse.sh"

pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s: %s\n' "$1" "$2"; }

HL=$'\x1b[48;2;40;40;40m'          # the 24-bit background the highlighted row carries
# Literal box-drawing characters, not \u escapes: this repo's scripts run under
# /bin/bash, which on macOS is 3.2 and supports \uXXXX in NEITHER $'...' nor
# printf. An escaped fixture silently becomes the text "\u2502", the header row
# then fails to match, and every positive case fails while the fail-closed
# cases still pass — which reads exactly like a broken parser.
FOOT='│ up/down navigate  enter select  esc cancel │'

# Build a panel. header=1 includes the "Allow tool:" anchor; body=N detail rows;
# hl names the highlighted option; drop_approve/drop_deny/drop_foot omit a part.
panel() {
  local header="$1" body="$2" hl="$3" drop="${4:-}"
  [ "$header" = 1 ] && printf '│ Allow tool: bash │\n'
  local i=0
  while [ "$i" -lt "$body" ]; do printf '│ Command: step %s │\n' "$i"; i=$((i + 1)); done
  printf '│\n'
  [ "$drop" != approve ] && printf '%s│   Approve │\n' "$([ "$hl" = Approve ] && printf '%s' "$HL")"
  [ "$drop" != deny ]    && printf '%s│    Deny │\n'   "$([ "$hl" = Deny ]    && printf '%s' "$HL")"
  printf '│\n'
  [ "$drop" != foot ] && printf '%s\n' "$FOOT"
  return 0
}

# Each case sets FIXTURE, then this override feeds it to the parser.
_menu_window() { printf '%s' "$FIXTURE"; }

echo "== a complete panel WITH its header parses (the pre-existing path) =="
FIXTURE="$(panel 1 2 Approve)"
opts="$(prompt_menu_options fake:pane)"
[ "$(printf '%s' "$opts" | wc -l | tr -d ' ')" = 1 ] \
  && ok "two options parsed" || no "header panel" "options=[$opts]"
[ "$(prompt_menu_selected fake:pane)" = 1 ] \
  && ok "highlighted row reported as 1" || no "header panel selected" "got [$(prompt_menu_selected fake:pane)]"
case "$(prompt_menu_question fake:pane)" in
  "Allow tool: bash"*) ok "question keeps the header" ;;
  *) no "header panel question" "got [$(prompt_menu_question fake:pane)]" ;;
esac

echo
echo "== a panel whose header scrolled AWAY still parses (the fix) =="
FIXTURE="$(panel 0 80 Approve)"
opts="$(prompt_menu_options fake:pane)"
[ -n "$opts" ] && ok "headerless menu is answerable" \
  || no "headerless menu" "options empty — this is the wM:p4 deadlock"
[ "$(prompt_menu_selected fake:pane)" = 1 ] \
  && ok "highlight still located" || no "headerless selected" "got [$(prompt_menu_selected fake:pane)]"
case "$(prompt_menu_question fake:pane)" in
  *"[header off-screen]"*) ok "question is marked truncated" ;;
  *) no "headerless question" "missing the off-screen marker" ;;
esac
# A truncated parse MUST hash differently from a full one, or --expect-prompt-id
# would treat the two as the same prompt.
FIXTURE="$(panel 1 2 Approve)"; a="$(prompt_id fake:pane)"
FIXTURE="$(panel 0 80 Approve)"; b="$(prompt_id fake:pane)"
[ "$a" != "$b" ] && ok "truncated parse hashes differently" || no "prompt_id" "ids collide"

echo
echo "== near-misses MUST fail closed =="
FIXTURE="$(panel 0 3 Approve approve)"
[ -z "$(prompt_menu_options fake:pane)" ] \
  && ok "footer + Deny but no Approve refused" || no "no-approve" "accepted"
FIXTURE="$(panel 0 3 Approve deny)"
[ -z "$(prompt_menu_options fake:pane)" ] \
  && ok "footer + Approve but no Deny refused" || no "no-deny" "accepted"
FIXTURE="$(panel 0 3 Approve foot)"
[ -z "$(prompt_menu_options fake:pane)" ] \
  && ok "no navigation footer refused" || no "no-footer" "accepted"
FIXTURE='│ just some transcript output │
│ Approve of this plan? │'
[ -z "$(prompt_menu_options fake:pane)" ] \
  && ok "prose containing Approve refused" || no "prose" "accepted"
# Two highlighted rows means the snapshot was torn mid-render: refuse rather
# than pick one and press it.
FIXTURE="$(printf '│\n%s│   Approve │\n%s│    Deny │\n│\n%s\n' "$HL" "$HL" "$FOOT")"
[ -z "$(prompt_menu_options fake:pane)" ] \
  && ok "two highlighted rows refused" || no "double highlight" "accepted"

echo
echo "== prompt_any_visible: both shapes from one read, same scope as before =="
FIXTURE="$(panel 1 2 Approve)"
prompt_any_visible fake:pane \
  && ok "menu panel seen" || no "any_visible menu" "missed a complete panel"
FIXTURE="$(panel 0 80 Approve)"
prompt_any_visible fake:pane \
  && ok "headerless menu seen" || no "any_visible headerless" "missed the footer-anchored panel"
# The numbered shape (Claude/Codex), which carries no navigation footer at all,
# so it must be found by the option-row path with the menu gate closed.
FIXTURE=$'some output\n❯ 1. Yes\n  2. No, and tell me why\n'
prompt_any_visible fake:pane \
  && ok "numbered prompt seen with no footer" || no "any_visible numbered" "missed numbered options"
# Scope guard (#59): omp prints queued/steering messages as a numbered list.
# One that has scrolled out of the bottom 20 rows is NOT a prompt, and reading
# the whole 200-row menu window would call it one.
FIXTURE="1. Conductor: land the branch
2. Conductor: then report
$(for i in $(seq 25); do echo "transcript row $i"; done)"
prompt_any_visible fake:pane \
  && no "any_visible scope" "matched a numbered list above the live region" \
  || ok "numbered list outside the bottom 20 rows ignored"
FIXTURE=$'│ just some transcript output │\n│ Approve of this plan? │'
prompt_any_visible fake:pane \
  && no "any_visible prose" "accepted prose" || ok "prose refused"

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
