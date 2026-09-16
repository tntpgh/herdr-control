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

# ONE quote-aware pass. Two requirements pull in opposite directions:
#
#   `echo "swept 4 panes; herdr pane send-keys wN:p7 ENTER was how"`  must be
#   ALLOWED — the `;` is inside a string, so it starts no command, and writing
#   a note about this side door must not be refused (review found every such
#   note denied, which is the "teaches people to route around it" failure).
#
#   `herdr pane send-keys "wN:p7" ENTER` must be DENIED — quoting an argument
#   is ordinary hygiene, and blanking quoted spans wholesale turned the pane id
#   into `""`, so the guard allowed it.
#
# So the splitter tracks quote state and only breaks on UNQUOTED delimiters,
# leaving the text of each segment intact. Braces are deliberately not
# delimiters: `{}` is xargs' placeholder, and splitting on it hid the target.
_targets=$(printf '%s' "$CMD" | awk '
  BEGIN { seg = "" }
  function flush() { if (seg != "") print seg; seg = "" }
  {
    line = $0
    inq = 0; q = ""
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (inq) {
        seg = seg c
        if (c == q) inq = 0
        continue
      }
      if (c == "\"" || c == "\047") { inq = 1; q = c; seg = seg c; continue }
      if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")") { flush(); continue }
      seg = seg c
    }
    flush()                                  # a newline ends a command too
  }
  END { flush() }' \
  | sed -E 's/[[:space:]](do|then|else)[[:space:]]/\n/g' \
  | awk '
      # herdr need not be the FIRST word: a prefix runner may execute it, and
      # `xargs -I{} herdr pane send-keys {} ENTER` is a sweep, not an evasion —
      # review listed it among the shapes that failed open. So skip leading
      # runner words and their flags, then require herdr at that position.
      # Anything else (a pipeline whose producer merely mentions herdr, an
      # `echo`) still does not match, which is what keeps notes allowed.
      function is_runner(w) {
        return (w == "xargs" || w == "env" || w == "command" || w == "time" ||
                w == "nohup" || w == "stdbuf" || w == "nice")
      }
      {
        start = 1
        while (start <= NF && (is_runner($start) || $start ~ /^-/ || $start ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) start++
        if ($start ~ /(^|\/)herdr$/ && $(start+1) == "pane" &&
            ($(start+2) == "send-keys" || $(start+2) == "send-text")) {
          keys = ""
          for (i = start + 4; i <= NF; i++) keys = keys (keys == "" ? "" : " ") $i
          print $(start+2) "\t" $(start+3) "\t" keys
        }
      }')
[ -n "$_targets" ] || exit 0

# shellcheck source=/dev/null
[ -r "$here/config.sh" ] && . "$here/config.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$here/lib/prompt-parse.sh" >/dev/null 2>&1 || exit 0

_deny() {                                 # <pane> <options> <why>
  cat <<EOF
DENIED: $3

herdr-select.sh exists precisely for this and does what a keypress cannot: it
classifies the command behind the prompt (lib/command-policy.sh), refuses if
the prompt changed since it was read (--expect-prompt-id), refuses if the
option now means something else, checks the pane has not been RECYCLED by
another task, and records the decision in an append-only audit trail.

  $here/herdr-select.sh $1 <option-number> --expect-prompt-id \$(
      . $here/lib/prompt-parse.sh; prompt_id $1)

Options currently on offer in $1:
$(printf '%s\n' "$2" | sed 's/^/  /')

To send a MESSAGE to an agent rather than answer its prompt, use
$here/send-to-agent.sh, which refuses rather than submit into a prompting pane.
EOF
  exit 1
}

printf '%s\n' "$_targets" | while IFS=$'\t' read -r sub pane keys; do
  [ -n "$pane" ] || continue
  # Ordinary shell hygiene, not evasion: `send-keys "wN:p7" ENTER` kept the
  # quotes in the extracted token, the pane read failed, and the guard allowed.
  pane=${pane#[\"\']}; pane=${pane%[\"\']}

  _answers=0
  case " ${keys:-} " in
    *[Ee]nter*|*ENTER*|*[Rr]eturn*|*RETURN*) _answers=1 ;;
  esac
  # send-text into a prompting pane is denied outright, whatever the text —
  # send-to-agent.sh's own stance. Deciding from the text is not possible: a
  # trailing newline may arrive as a real newline, as the two characters \n, or
  # be added by the transport, and in the numbered shape a bare digit with no
  # newline IS the answer.
  [ "$sub" = send-text ] && _answers=1
  printf '%s' "${keys:-}" | grep -qE '(^|[^0-9A-Za-z])[0-9]([^0-9A-Za-z]|$)' && _answers=1
  [ "$_answers" = 1 ] || continue

  # An UNRESOLVABLE pane id is the sweep shape this guard exists to stop:
  # `for p in ...; do herdr pane send-keys $p ENTER; done`. The id is not known
  # until the loop runs, so no liveness question can be asked about it — and
  # treating "cannot read that pane" as "not prompting" failed open on the one
  # spelling a real sweep uses.
  case "$pane" in
    *'$'*|*'`'*|'{}'|*'*'*)
      _deny "$pane" "(pane id is not known until the command runs)" \
        "the pane id in this command is computed at run time ($pane), so whether it
is showing a prompt cannot be established before the keys are sent. A sweep
that answers whatever it finds is the exact shape this guard exists to stop." ;;
  esac

  prompt_any_visible "$pane" 2>/dev/null || continue

  # A PARSEABLE option list is required before denying. prompt_any_visible is
  # the loosest predicate in prompt-parse.sh — its numbered fallback matches any
  # bottom-of-viewport numbered list, which is what an agent's ordinary prose
  # summary looks like. Review measured a ~10% false-denial rate on live panes:
  # two idle/done panes were denied over a numbered "Still needs you" list, and
  # that included `send-text` to an idle agent, the everyday way to message one.
  # The blocked-vs-idle split was clean, so this costs no true positive.
  opts=$(prompt_menu_options "$pane" 2>/dev/null || true)
  [ -n "$opts" ] || opts=$(prompt_options "$pane" 2>/dev/null || true)
  [ -n "$opts" ] || continue

  _deny "$pane" "$opts" \
    "$pane is showing a permission prompt, and this would answer it with a raw keypress
— accepting whichever option happens to be highlighted, with no classifier
verdict, no prompt-id check, no pane fingerprint, and no audit record."
done
_rc=$?
exit "$_rc"
