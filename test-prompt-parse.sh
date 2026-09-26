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
# Same trap, second form, found while reviewing the footer-unwrap fix: a
# non-breaking space written as \u00a0 also stays literal text under bash 3.2,
# so an NBSP-padded continuation row appears not to parse when the fixture is
# what is broken. Write real bytes — $'\302\240' — and it parses fine.
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
# A panel is bottom-anchored. Fresh output printed BELOW the footer means the
# menu was dismissed and the pane moved on; answering it would press a key
# into a pane that is not prompting.
FIXTURE="$(panel 0 3 Approve)"$'\nTask complete.\n'
[ -z "$(prompt_menu_options fake:pane)" ] && ! prompt_menu_visible fake:pane \
  && ok "a dismissed menu with newer output below it is not actionable" \
  || no "stale menu" "accepted a menu that has output under its footer"

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
echo "== a NUMBERED list is only offered while it is still the live prompt =="
# `prompt_options` took the first occurrence of each number anywhere in the
# bottom 25 lines, so an ANSWERED list — or omp's steering queue painted above
# a panel — was served as the current choice. That has hurt twice: numbered-only
# parsing made every omp alert unanswerable (2026-08-01), and the numbered-FIRST
# fix then matched the queue, so a Slack click on "1" pressed Approve on a
# command the operator never saw. A screen scrape has exactly one freshness
# signal: a waiting prompt is the LAST thing painted.
_prompt_window() { printf '%s\n' "$SCREEN"; }

# The two-line OMC status bar, captured from a live pane. The first version of
# this gate enumerated furniture and matched NEITHER line, so a real prompt
# above a real bar produced no options at all — an unanswerable agent.
BAR=$'╭── ⠙ 34m ▎ Opus 5 ▎ ~/Code/thurber-os ▎ main ▎ 20.71 ───22%───
╰─                    ─╯'
SCREEN=$'Do you want to proceed?\n1. Yes\n2. No\n  \u2191/\u2193 navigate \u00b7 enter select\n'"$BAR"
[ -n "$(prompt_options fake:pane)" ] \
  && ok "a live list with a navigation footer below it is offered" \
  || no "live numbered list" "options empty — the footer was read as new output"

# omp's task line is a SENTENCE and the classifier says so — it is exempted by
# POSITION (the status block is sized from the trailing decorated run plus the
# title line above it), not by being recognised as decoration. Asserting the
# classifier called it status was asserting the wrong mechanism.
_is_prose '  󱊷 Commit the Jacomo fixes and push' \
  && ok "the task line reads as prose (it is a sentence); position exempts it" \
  || no "task line classifier" "expected prose, got status"

# The classifier itself, line by line. Three earlier designs each failed
# against one of these and the caller-level rows could not tell me which:
# a furniture allowlist missed the bar, private-use byte ranges never fired in
# BSD awk, and a positional rule swallowed the canonical stale case.
for _line in \
  'I have applied the change and moved on to the tests.' \
  ' Done. Press Enter to send your next message.' \
  ' I have applied it. You can use the arrow keys to navigate the tree.'; do
  _is_prose "$_line" && ok "output recognised: ${_line:0:42}" \
    || no "prose classifier" "missed output: $_line"
done
for _line in \
  '  ↑/↓ navigate · enter select · esc cancel' \
  '⏵⏵ auto-accept edits on' \
  'branch: main' \
  '  249 insertions(+), 18 deletions(-)' \
  '╭── ⠙ 34m ▎ Opus 5 ▎ ~/Code/x ▎ main ▎ 20.71 ──22%──' \
  ; do
  _is_prose "$_line" && no "prose classifier" "status read as output: $_line" \
    || ok "status recognised: ${_line:0:42}"
done

SCREEN=$'Choose:\n1. Alpha\n2. Beta\n\u23f5\u23f5 auto-accept edits on'
[ -n "$(prompt_options fake:pane)" ] \
  && ok "a live list above Claude Code's mode line is offered" \
  || no "mode line" "options empty — the mode line was read as new output"

SCREEN=$'Q?\n1. Yes\n2. No\n  ⫷⫷ x\n'"  󱊷 Commit the Jacomo fixes and push"$'\n'"$BAR"
[ -n "$(prompt_options fake:pane)" ] \
  && ok "and above omp's task line, which is prose by any word count" \
  || no "task line" "options empty — omp panes would be unanswerable"

# Footer PHRASINGS are an open set too — matching the two literal words
# navigate+select was the furniture mistake one noun over. Every line below was
# REFUSED by that version, and any of them would make a live prompt
# unanswerable in whatever CLI an agent happens to run inside a pane.
for _f in \
  '  ↑/↓ navigate · enter select · esc cancel' \
  '  ? for shortcuts' \
  '  Context left until auto-compact: 23%' \
  '  ⏵⏵ auto-accept edits on (shift+tab to cycle)' \
  '  esc to interrupt' \
  '  Use the arrow keys to move, Enter to choose, Esc to go back' \
  '  Press Enter to confirm your selection, or Esc to go back' \
  '  Press up and down to move between the options' \
  '  Type a number and press return to answer this question' \
  '  Choose one of the options above with the arrow keys' \
  '  (Use arrow keys or type a number, then press Enter to submit)'; do
  SCREEN=$'Proceed?\n1. Yes\n2. No\n'"$_f"$'\n'"$BAR"
  [ "$(prompt_options fake:pane | grep -c .)" -eq 2 ] \
    && ok "offered below: $(printf '%s' "$_f" | cut -c1-44)" \
    || no "footer phrasing" "REFUSED below: $_f"
done

# A WRAPPED option must arrive whole. This is the one failure in this file that
# asks a human the WRONG question rather than failing to ask: the run was
# strictly contiguous option lines, so an indented continuation truncated the
# list to its suffix — a two-choice prompt reached Slack as ONE button, and the
# option that wrapped could not be picked at all.
SCREEN=$'Proceed?\n1. Yes, and remember this decision for the rest of\n   the session\n2. No\n'"$BAR"
_opts="$(prompt_options fake:pane)"
[ "$(printf '%s' "$_opts" | grep -c .)" -eq 2 ] \
  && ok "a wrapped option does not truncate the list" \
  || no "wrapped option" "got [$(printf '%s' "$_opts" | tr '\n' '|')]"
case "$_opts" in
  *"rest of the session"*) ok "and its continuation is joined onto it" ;;
  *) no "wrapped option text" "continuation lost: [$(printf '%s' "$_opts" | tr '\n' '|')]" ;;
esac

SCREEN=$'Choose:\n1. Alpha\n2. Beta\nbranch: main'
[ -n "$(prompt_options fake:pane)" ] \
  && ok "and above an OMC branch line" \
  || no "branch line" "options empty — the branch line was read as new output"

SCREEN=$'1. Yes\n2. No\n I have applied the change and moved on to the tests.\n'"$BAR"
[ -z "$(prompt_options fake:pane)" ] \
  && ok "a list the agent has already moved past is NOT offered" \
  || no "stale numbered list" "offered [$(prompt_options fake:pane | tr '\n' '|')]"

# The steering-queue case is guarded by ORDER, not by this parser: every caller
# tries prompt_menu_options FIRST (slack-bridge/herdr-notify.sh:229,
# herdr-select.sh:166), so on a screen with a real approval panel the menu
# parse consumes it and the queue is never consulted. `prompt_options` cannot
# distinguish them itself — the panel below the queue is box furniture, and
# rejecting box furniture would refuse every live prompt painted above a status
# bar, which is the 2026-08-01 unanswerable failure. So this asserts the
# property that actually holds.
FIXTURE="$(printf '1. Conductor: review auth\n2. Conductor: fix nightly\n%s' "$(panel 1 2 Approve)")"
SCREEN="$FIXTURE"
[ -n "$(prompt_menu_options fake:pane)" ] \
  && ok "menu-first ordering consumes a panel, so a queue above it is never offered" \
  || no "queue above panel" "the menu parse missed a real panel; the queue would be used"

SCREEN=$'old question\n1. A\n2. B\nnew question\n1. X\n2. Y\n❯'
case "$(prompt_options fake:pane | tr '\n' ' ')" in
  *X*Y*) ok "with two lists on screen, only the newest is offered" ;;
  *) no "two lists" "offered [$(prompt_options fake:pane | tr '\n' '|')]" ;;
esac
unset -f _prompt_window; . "$HERE/lib/prompt-parse.sh"   # restore the real _prompt_window/_pane_visible

echo
echo "== a pane line truncated mid multibyte character must not crash the parser =="
# tmux captures a pane at its column width, and that cut can land inside a
# multibyte UTF-8 character (e.g. an em-dash, U+2014, e2 80 94 — the wrap
# lops off the trailing byte). Confirmed live: BSD sed under a UTF-8 locale
# exits 2 "stream did not contain valid UTF-8" on exactly that input, which
# used to empty prompt_options/prompt_command_text's `$(...)` pipeline
# silently rather than crash loudly — either way the prompt went unanswerable.
# This drives the REAL `_pane_visible`/`_menu_window` (the `_prompt_window`
# override above is gone now), so it exercises the actual `herdr pane read`
# boundary where the fix (iconv -c) lives.
herdr() {
  case "$1 $2" in
    "pane read")
      printf '1. Yes \342\200X\n2. No\n'
      ;;
  esac
}
_broken_opts="$(prompt_options fake:pane)"; _broken_rc=$?
[ "$_broken_rc" -eq 0 ] \
  && ok "truncated multibyte line does not abort the parser (rc=$_broken_rc)" \
  || no "truncated multibyte" "parser exited $_broken_rc instead of continuing"
case "$_broken_opts" in
  *"1"*"Yes"*"2"*"No"*) ok "options either side of the torn character still parse" ;;
  *) no "truncated multibyte options" "got [$_broken_opts]" ;;
esac
# A VALID em-dash (all three bytes intact) is unaffected by the same fix.
herdr() {
  case "$1 $2" in
    "pane read") printf '1. Yes \342\200\224 and remember\n2. No\n' ;;
  esac
}
case "$(prompt_options fake:pane)" in
  *$'\342\200\224'*) ok "an intact em-dash still renders as a real character" ;;
  *) no "intact em-dash" "got [$(prompt_options fake:pane)]" ;;
esac
unset -f herdr

echo
echo "== prompt_command_torn: detects invalid UTF-8 in the RAW capture (PR #147 hold) =="
# _sanitize_utf8 (iconv -c) drops an invalid byte before menu/numbered parsing
# ever sees it, which is right for PARSING but wrong for CLASSIFICATION: see
# lib/prompt-parse.sh's prompt_command_torn comment for the live probe table
# that made dropping alone dangerous (an escalate/deny verdict became allow).
# herdr-select.sh consults this to force escalate on a torn capture.
herdr() {
  case "$1 $2" in
    "pane read")
      # a numbered-shape screen (no "Allow tool:" header), with a torn byte
      # sitting in the middle of the command text — the shape prompt_command_text
      # falls back to when no omp menu panel is present.
      printf 'Bash command\n  curl https://example.com/x \342\200 -o /tmp/p.json\n\n1. Yes\n2. No\n'
      ;;
  esac
}
prompt_command_torn fake:pane
[ $? -eq 0 ] && ok "a torn byte in the raw capture is detected" \
  || no "torn detection" "prompt_command_torn did not report torn"
herdr() {
  case "$1 $2" in
    "pane read")
      printf 'Bash command\n  curl https://example.com/x -o /tmp/p.json\n\n1. Yes\n2. No\n'
      ;;
  esac
}
prompt_command_torn fake:pane
[ $? -eq 1 ] && ok "a clean capture is not flagged torn" \
  || no "clean detection" "prompt_command_torn wrongly reported torn on clean text"
herdr() {
  case "$1 $2" in
    "pane read")
      printf 'Allow tool: bash\nCommand: curl https://example.com/x \342\200 -o /tmp/p.json\n\n\x1b[48;2;42;47;65m Approve\x1b[0m\nDeny\n\nup/down navigate  enter select  esc cancel\n'
      ;;
  esac
}
prompt_command_torn fake:pane
[ $? -eq 0 ] && ok "menu-shape (omp) torn byte in a classified panel row is detected" \
  || no "menu-shape torn" "prompt_command_torn did not report torn on a torn omp panel row"
herdr() {
  case "$1 $2" in
    "pane read")
      printf 'Allow tool: bash\nCommand: curl https://example.com/x -o /tmp/p.json\n\n\x1b[48;2;42;47;65m Approve\x1b[0m\nDeny\n\nup/down navigate  enter select  esc cancel\n'
      ;;
  esac
}
prompt_command_torn fake:pane
[ $? -eq 1 ] && ok "menu-shape (omp) clean capture is not flagged torn" \
  || no "menu-shape clean" "prompt_command_torn wrongly reported torn on a clean omp panel"
# F3 (independent review, torn-gate-scope-liveness): a torn byte OUTSIDE the
# classified panel rows (old transcript above the panel) must not flag every
# future approval on this pane torn — prompt_command_text never reads that
# transcript either.
herdr() {
  case "$1 $2" in
    "pane read")
      printf 'earlier output \342\200 with a torn byte, never classified\nAllow tool: bash\nCommand: curl https://example.com/x -o /tmp/p.json\n\n\x1b[48;2;42;47;65m Approve\x1b[0m\nDeny\n\nup/down navigate  enter select  esc cancel\n'
      ;;
  esac
}
prompt_command_torn fake:pane
[ $? -eq 1 ] && ok "a torn byte outside the classified panel rows is not flagged (F3 scope)" \
  || no "F3 scope" "a torn byte in unrelated transcript wrongly escalated every future approval"
# F2 (independent review, torn-gate-unreadable-fail-open): an unreadable
# capture must count as torn, never clean -- an empty read here used to
# return "clean", silently trusting whatever verdict was computed moments
# earlier on a DIFFERENT (successful) read.
herdr() {
  case "$1 $2" in
    "pane read") printf '' ;;
  esac
}
prompt_command_torn fake:pane
[ $? -eq 0 ] && ok "an unreadable capture counts as torn, not clean (F2)" \
  || no "F2 empty read" "prompt_command_torn reported an unreadable pane as clean"
unset -f herdr
unset -f _prompt_window

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
