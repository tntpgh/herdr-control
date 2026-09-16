#!/usr/bin/env bash
# guard-raw-prompt-answer.sh <command-text>
#
# "Is this shell command about to answer another agent's permission prompt
# with a raw keypress?"  Exit 0 = allow, exit 1 = DENY with a reason on stdout.
#
# WHY THIS EXISTS. herdr-select.sh's header calls itself "the ONE path allowed
# to answer a permission prompt", and everything in it exists to keep that
# true: a classifier verdict (lib/command-policy.sh) that only auto-answers
# operational commands, an --expect-prompt-id TOCTOU check, an unconditional
# re-offer check ("option 2 now means something else — refusing"), a pane-birth
# fingerprint so a RECYCLED pane id cannot be answered as if it were the
# original task, and an append-only audit trail it refuses to act without.
# send-to-agent.sh guards the same hazard from the other side, exiting 5 rather
# than let ordinary text delivery press Enter into a pane that is asking
# something.
#
# None of that is enforced. `herdr pane send-keys <pane> ENTER` walks straight
# past all of it, and on 2026-09-16 that is exactly what happened: an agent
# (me) swept four blocked review panes by pressing Enter on whatever option was
# highlighted. The commands behind those prompts did classify `allow`, and the
# outcome was fine — which is the problem. There was no classification, no
# TOCTOU re-check, no fingerprint, and no audit record; it was fine by luck and
# by my reading of the screen, and the next caller has the same side door with
# a worse command behind the prompt.
#
# So this closes it: raw keys that would ANSWER a live prompt are denied and
# redirected to the tool that does it accountably. Everything else — typing
# into a shell pane, answering a pane that is not asking anything, ESC, Ctrl-C,
# navigation keys — is untouched, because the hazard is specifically "accept an
# option nobody named".
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
CMD="${1:-}"
[ -n "$CMD" ] || exit 0

# herdr-select.sh and send-to-agent.sh reach send-keys legitimately, having
# done the checks this guard is about. They mark themselves so their own
# keypresses are not denied by it. An env marker is not a security boundary —
# anything that can set it can also call herdr pane directly — and it does not
# need to be: this guard defends against the ACCIDENTAL side door (an agent
# reaching for the obvious CLI), exactly as herdr-select's own
# "demonstrably-human" check defends against accident and stale signals rather
# than a hostile caller.
[ "${HERDR_SANCTIONED_ANSWER:-}" = 1 ] && exit 0

# Only `herdr pane send-keys` / `send-text` can answer a prompt, and only when
# it is the COMMAND being run — not a word inside `echo`, a quoted printf
# argument, or a commit message. Guessing that with one regex went wrong twice
# (an over-broad pattern denied an echo; adding shell keywords to it broke the
# match completely and the suite went from 25 rows passing to 14). So: split on
# the things that START a command, and ask whether any resulting segment's
# FIRST WORD is herdr. An over-broad guard on a control like this is not
# harmless — it teaches the people it nags to route around it.
printf '%s' "$CMD" \
  | sed -e 's/#[^"'"'"']*$//' -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;&|(){}]/\n/g' \
  | sed -E 's/[[:space:]](do|then|else)[[:space:]]/\n/g' \
  | awk '{ if ($1 ~ /(^|\/)herdr$/ && $2 == "pane" && ($3 == "send-keys" || $3 == "send-text")) f = 1 }
         END { exit !f }' \
  || exit 0

# Which pane, and which keys? The pane id is the first argument after the
# subcommand; keys are everything after it.
read -r sub pane keys <<<"$(printf '%s' "$CMD" \
  | sed -nE 's/.*pane[[:space:]]+send-(keys|text)[[:space:]]+([^[:space:]]+)[[:space:]]*(.*)$/\1 \2 \3/p')"
[ -n "${pane:-}" ] || exit 0

# An ANSWERING key is one that commits a choice: Enter (the default option),
# or a bare digit (the numbered-prompt shape, where the digit IS the answer and
# no Enter follows). ESC and Ctrl-C cancel, which cannot approve anything, and
# arrows only move the highlight — all three stay allowed so a caller can still
# back out of a prompt it stumbled into.
_answers=0
case " ${keys:-} " in
  *[Ee]nter*|*ENTER*|*[Rr]eturn*|*RETURN*) _answers=1 ;;
esac
# send-text into a prompting pane is denied OUTRIGHT, whatever the text, which
# is send-to-agent.sh's own stance (exit 5: "Enter would select its default
# option"). Deciding from the text is not possible anyway: a trailing newline
# may arrive as a real newline, as the two characters \n, or be added by the
# transport, and a bare digit with no newline IS the answer in the numbered
# shape. The safe rule is the one the repo already uses — do not type into a
# pane that is asking something.
[ "$sub" = text ] && _answers=1
printf '%s' "${keys:-}" | grep -qE '(^|[^0-9A-Za-z])[0-9]([^0-9A-Za-z]|$)' && _answers=1
[ "$_answers" = 1 ] || exit 0

# Is that pane actually asking something RIGHT NOW? This is the whole point of
# checking at the tool boundary rather than statically: sending Enter to a pane
# running a build is ordinary, and sending the same Enter two seconds after a
# permission panel appeared is answering it.
# shellcheck source=/dev/null
[ -r "$here/config.sh" ] && . "$here/config.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$here/lib/prompt-parse.sh" >/dev/null 2>&1 || exit 0
prompt_any_visible "$pane" 2>/dev/null || exit 0

# It is. Deny, and name the accountable path — including the option NUMBER the
# caller would have to state, because "press whatever is highlighted" is the
# thing being refused.
opts=$(prompt_menu_options "$pane" 2>/dev/null || true)
[ -n "$opts" ] || opts=$(prompt_options "$pane" 2>/dev/null || true)
# A prompt this guard can SEE but not parse is the most dangerous case to
# answer blind, so the message says how to look at it rather than leaving the
# reader with an empty list.
[ -n "$opts" ] || opts="(not parseable — read it first: herdr pane read $pane --source visible)"
cat <<EOF
DENIED: $pane is showing a permission prompt, and this would answer it with a
raw keypress — accepting whichever option happens to be highlighted, with no
classifier verdict, no prompt-id check, no pane fingerprint, and no audit
record. herdr-select.sh exists precisely for this and does all four:

  $here/herdr-select.sh $pane <option-number> --expect-prompt-id \$(
      . $here/lib/prompt-parse.sh; prompt_id $pane)

Options currently on offer in $pane:
$(printf '%s\n' "${opts:-  (could not read the option list — do not answer blind)}" | sed 's/^/  /')

To send a MESSAGE to an agent instead of answering its prompt, use
$here/send-to-agent.sh, which refuses rather than submit into a prompting pane.
EOF
exit 1
