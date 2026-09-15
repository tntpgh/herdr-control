#!/usr/bin/env bash
# prompt-parse.sh — read the choices an agent is currently offering.
#
# Sourced by herdr-notify.sh (to show them in Slack) and herdr-select.sh (to
# validate a selection before pressing anything). Both must agree on what
# "option 2" means, or Slack would show one list and the keypress would answer a
# different one — so the parse lives in exactly one place.
#
# Provides: prompt_options <pane_id>   -> "N<TAB>text" per line, empty if none
#           prompt_question <pane_id>  -> the question line, if identifiable
#           composer_stable_snapshot <pane_id> [lines] -> filtered bottom-of-pane
#             text for send-to-agent.sh's before/after submit-confirmation diff

# A numbered option, with or without the selection arrow:
#   ❯ 1. Yes
#     2. Yes, and don't ask again
_OPT_LINE='^[[:space:]]*[❯>]?[[:space:]]*([0-9]+)\.[[:space:]]+(.+)$'

_prompt_window() {
  # The prompt is anchored at the bottom. Read a little more than the guard does
  # so a long option list is not clipped, but stay in the live region.
  herdr pane read "$1" --source visible --lines 40 2>/dev/null | tail -n 20
}

prompt_options() {
  local win
  win=$(_prompt_window "$1") || return 1
  printf '%s\n' "$win" | sed -nE "s/$_OPT_LINE/\1\t\2/p" \
    | sed -E 's/[[:space:]]+$//' \
    | awk -F'\t' '!seen[$1]++'   # first occurrence of each number wins
}

# What is on screen, when there is no numbered list to parse.
#
# Without this you get "Claude needs your permission to use Bash" and answer
# BLIND — the alert names the pane but not the question. Options are the better
# signal when they exist; this is the fallback for everything else: a
# non-numbered prompt, a plan approval, or a prompt auto-mode already dismissed
# before the hook could read it.
#
# Strips the furniture so what is left is the agent's own words: box-drawing
# rules, the `❯` composer line, the OMC status lines (branch:, [OMC#, ⏵⏵ mode),
# the tmux status bar, and the spinner.
#
# NOTE this puts pane content in Slack. herdr-notify posts to the allowlisted
# user's DM only (channel = their user id), so it does not reach a channel —
# but it IS your screen contents leaving the machine, which is why it is behind
# --choices rather than on by default.
prompt_context() {
  local win
  win=$(herdr pane read "$1" --source visible --lines 40 2>/dev/null) || return 1
  # The TUI pads with NON-BREAKING spaces, which [[:space:]] does not match —
  # without normalising them first, "blank" lines and a bare composer arrow
  # survive every filter below and end up in the alert.
  # BSD sed (macOS) does not understand \xNN, so the non-breaking space must be
  # written as real bytes via $'...' — with a literal "\xc2\xa0" pattern the
  # substitution silently does nothing and every "blank" padding line survives.
  printf '%s\n' "$win" \
    | sed $'s/\xc2\xa0/ /g' \
    | grep -vE '^[[:space:]]*[─═│┌┐└┘├┤┬┴┼╭╮╰╯]+[[:space:]]*$' \
    | grep -vE '^[[:space:]]*[❯>]([[:space:]]|$)' \
    | grep -vE '^[[:space:]]*(branch:|\[OMC#|⏵)' \
    | grep -vE '^\[[a-z0-9-]+:' \
    | grep -vE '^[[:space:]]*[✻✳✽✶✢✷✸✹✺·*][[:space:]]' \
    | sed -E 's/[[:space:]]+$//' \
    | awk '{ s=$0; gsub(/[[:space:]]/,"",s); if (length(s)) print }' \
    | tail -n 8 \
    | cut -c1-200
}

# ---- submit confirmation (send-to-agent.sh) ---------------------------------
#
# A snapshot of the bottom of the pane, filtered to strip volatile furniture
# that changes independent of whether anything was actually submitted — the
# OMC/tmux status bar's live elapsed-time and context-percentage counters,
# the spinner glyph — but DELIBERATELY KEEPING `❯`-prefixed lines. That is the
# opposite choice from prompt_context above: prompt_context strips them
# because it wants the agent's own words; this wants exactly the composer's
# own line, since "unsent text still sitting there" is the whole signal.
#
# Why this exists: send-to-agent.sh's Enter-retry loop used to detect
# "submitted" by grepping for ONE specific artifact (Claude's "[Pasted text"
# paste-debounce placeholder). For ordinary short text there is no such
# artifact, so that check reported "clear" — and therefore SUBMITTED — after
# the very first Enter, whether or not the Enter actually landed. Comparing
# two of these snapshots instead (before/after an Enter) catches that
# honestly: a message truly stuck in the composer produces byte-identical
# snapshots and correctly keeps retrying; a real submit changes the bottom of
# the pane (new response text, a fresh empty prompt, or the debounce artifact
# clearing) and is detected the same way regardless of which of those it was.
#
# The status-bar/spinner strip is what makes this safe to compare across a
# multi-second retry gap: without it, session-elapsed-minutes or a context%
# counter ticking over between two reads would register as "something
# changed" and falsely declare an unsubmitted message SUBMITTED — a worse
# failure than the one this replaces, since it actively lies about delivery.
composer_stable_snapshot() {
  local win
  win=$(herdr pane read "$1" --source visible --lines "${2:-12}" 2>/dev/null) || return 1
  printf '%s\n' "$win" \
    | sed $'s/\xc2\xa0/ /g' \
    | grep -vE '^[[:space:]]*[─═│┌┐└┘├┤┬┴┼╭╮╰╯]+[[:space:]]*$' \
    | grep -vE '^[[:space:]]*(branch:|\[OMC#|⏵)' \
    | grep -vE '^\[[a-z0-9-]+:' \
    | grep -vE '^[[:space:]]*[✻✳✽✶✢✷✸✹✺·*][[:space:]]' \
    | sed -E 's/[[:space:]]+$//'
}

# --- menu-shape prompts (no numbered options at all) ------------------------
#
# Not every agent renders a numbered list. omp's tool-approval prompt is an
# up/down + Enter menu with no numbers and no bare-digit convention at all —
# verified live 2026-07-31 against `omp --approval-mode always-ask`: an
# "Allow tool: <name>" header, a blank separator, one row per option, a
# blank separator, and a "... enter select ..." footer. The CURRENTLY
# HIGHLIGHTED row is the only one carrying an SGR 24-bit background-colour
# escape (\e[48;2;R;G;Bm) — every other row is unstyled plain text, which is
# why this needs --format ansi; prompt_options above (plain --source
# visible) cannot see it at all.
#
# Provides: prompt_menu_options <pane>  -> "N<TAB>label" per row, 1-based,
#             top-to-bottom — the SAME numbering convention as
#             prompt_options, so a caller (herdr-select.sh, a Slack "reply
#             1/2/3") never needs to know which mechanism it is driving.
#           prompt_menu_selected <pane> -> the 1-based row currently
#             highlighted, or empty if no menu is showing OR the highlight
#             could not be determined — never guess a position.
#           prompt_menu_question <pane> -> the header/detail lines, for
#             prompt_id() below.
# 200 lines, not 60: the header is the ANCHOR of the state machine below, and a
# long command body pushes it further from the footer than 60 rows. Measured
# 2026-09-13 on an `eval` approval whose body was ~1.2 kB — the "Allow tool:"
# row was outside every window up to 140, so `_prompt_menu` never left state 0,
# `prompt_menu_options` failed closed, and herdr-select refused a menu that was
# plainly on screen ("not showing a prompt this script recognises"). Widening
# alone is not sufficient — see the footer-anchored fallback in _prompt_menu —
# but it keeps the RICH parse (full header + detail rows) available far more
# often, and the fallback's truncated question is strictly worse for review.
_menu_window() {
  herdr pane read "$1" --source visible --lines 200 --format ansi 2>/dev/null
}

# A NECESSARY condition for either pass below, decided in the shell with no
# process at all: both passes end on the navigation footer, so a window
# carrying neither of its words cannot parse as a menu and spawning python to
# learn that is pure cost. It is deliberately only a gate — it never decides a
# menu IS present, so no fixture that used to parse can stop parsing.
#
# Why it exists: omp-notify.sh calls this up to 10 times per tool call in every
# omp pane, and python3.14 startup is ~45ms of CPU each. Measured 2026-09-14
# while diagnosing machine-wide herdr lag — the poll cost 1.86s of CPU per tool
# call per worker, against ~8 live workers, for the answer "nothing is asking".
# Matching two separate words rather than the whole footer phrase keeps the gate
# robust to a style change painted between them.
_menu_gate() {                         # <window>
  case "$1" in *navigate*) ;; *) return 1 ;; esac
  case "$1" in *select*)   ;; *) return 1 ;; esac
  return 0
}

# Parse the complete, known two-choice approval menu from ONE snapshot.
# Blank rows separate command details too; they are not an option boundary.
# Unknown/truncated menu shapes fail closed rather than turning detail text
# into option 1 and arrow-walking forever toward a row that cannot be selected.
#
# TWO passes, in preference order:
#   1. header-anchored — opens on "Allow tool:", collects every detail row, and
#      yields the rich question text a reviewer should be judging.
#   2. footer-anchored — when pass 1 found no complete panel, walk UP from the
#      navigation footer looking for Deny then Approve. The footer and the two
#      option rows are pinned to the bottom of the panel, so they survive a
#      command body long enough to push the header off-screen entirely; that is
#      the case that deadlocked wM:p4 on 2026-09-13 (a ~1.2 kB `eval` body; the
#      header was outside every window up to 140 rows, so no widening could
#      reach it). The question is then only what is still visible, marked
#      "[header off-screen]" so it is never mistaken for a full parse and so
#      prompt_id() hashes differently from one.
#
# Pass 2 is deliberately narrow: it requires the exact footer, then exactly
# "Deny", then exactly "Approve", nearest-first with only blank rows allowed
# between. Anything else fails closed, as before. The risk it accepts is a pane
# whose transcript happens to end with those three lines in that order; the risk
# it removes is a real menu that cannot be answered at all, which forces either
# a blind Enter (pressing whatever is highlighted) or a stalled lane.
_prompt_menu() {                       # <pane> visible|options|selected|question
  local win
  win=$(_menu_window "$1") || return 1
  _menu_gate "$win" || return 1
  printf '%s\n' "$win" | _prompt_menu_parse "$2"
}

# The parser itself: <mode>, window on stdin. Split out from _prompt_menu so a
# caller that already holds a snapshot (prompt_any_visible below) can parse it
# without paying a second `herdr pane read`. One parser process per snapshot,
# not sed/grep subprocesses per screen row — the latter made one reviewed
# approval take seconds of process churn.
_prompt_menu_parse() {                 # <mode>; window on stdin
  python3 -c '
import re, sys
ansi = re.compile(r"\x1b\[[0-9;]*m")
highlight = re.compile(r"\x1b\[48;2;[0-9]+;[0-9]+;[0-9]+m")
lines = []
state = 0
question = []
selected = ""
invalid = complete = visible = False
truncated = False
# Read bytes: a stray non-UTF-8 byte in a pane must degrade to U+FFFD, not
# abort the parser and silence the wake path.
for raw in sys.stdin.buffer:
    line = raw.decode("utf-8", "replace")
    lines.append(line)
    plain = ansi.sub("", line)
    # `text` (leading punctuation stripped) is ONLY for header/option/footer
    # matching. `body` keeps a command row intact — `-rf`, `--flag`, `| sh`,
    # `~/.ssh` — because it is what gets classified.
    text = re.sub(r"^[^A-Za-z0-9]+", "", plain).rstrip(" \t\r\n│─╮")
    body = re.sub(r"^[\s│]+", "", plain).rstrip(" \t\r\n│─╮")
    # A header row only OPENS a panel; inside one it is command content
    # (a multi-line command can contain the literal text "Allow tool:").
    if state == 0 and text.startswith("Allow tool:"):
        state, question, selected = 1, [text], ""
        invalid = complete = visible = False
        continue
    if state == 0:
        if text:
            complete = visible = False
        continue
    if text.startswith("up/down navigate") and "enter select" in text:
        # `visible` requires an actual option ROW (state >= 2 means an
        # "Approve" line was consumed), not merely a header plus a footer.
        # Without that, a pane which merely DISPLAYS pane content — a
        # conductor echoing `herdr pane read` output, a transcript quoting an
        # approval panel — opens the state machine on the echoed "Allow tool:"
        # and trips `visible` on the echoed footer, reporting a menu that is
        # not there. Observed 2026-09-13 on the conductor pane itself, which
        # herdr-gates then showed as GATE=UNPARSED while that session was
        # merely printing the gates of other panes. A false needs-input is not
        # harmless: wait-for-blocked.sh treats prompt_menu_visible as its
        # backstop signal, so it would wake on a pane nobody is waiting on.
        # The options sit ABOVE the footer in the omp layout and the header
        # scrolls off the TOP, so a real panel showing its footer is showing
        # its option rows too — requiring one costs no genuine detection.
        visible = state >= 2
        complete = state == 3 and not invalid
        state = 0
        continue
    if not body:
        continue
    if state == 1 and text == "Approve":
        state, n = 2, "1"
    elif state == 2 and text == "Deny":
        state, n = 3, "2"
    elif state == 1:
        question.append(body)
        continue
    else:
        invalid = True
        continue
    if highlight.search(line):
        invalid = invalid or bool(selected)
        selected = n

# ---- pass 2: footer-anchored, header off-screen -----------------------------
if not complete:
    def _text(s):
        return re.sub(r"^[^A-Za-z0-9]+", "", ansi.sub("", s)).rstrip(" \t\r\n|-\u2502\u2500\u256e")
    foot = None
    for i in range(len(lines) - 1, -1, -1):
        t = _text(lines[i])
        if t.startswith("up/down navigate") and "enter select" in t:
            foot = i
            break
    # A panel is BOTTOM-ANCHORED: below its footer there is nothing but the
    # box closer and blank rows. Pass 1 already enforces this (its state
    # machine clears `visible`/`complete` on any text after the footer), but
    # pass 2 walked up from the last footer in the window and so accepted a
    # DISMISSED menu with fresh output printed underneath — reporting a pane
    # as needing input when it had already moved on, and offering a keypress
    # into a pane that is not prompting. Caught by the verify-omp-hooks.sh
    # case "dismissed menu above new output is not actionable", which was red
    # on this branch from b0ac384 until 2026-09-15. (No apostrophes in here:
    # this whole parser is a single-quoted shell argument.)
    if foot is not None:
        for tail in lines[foot + 1:]:
            if _text(tail):
                foot = None
                break
    if foot is not None:
        want = ["Deny", "Approve"]
        rows = {}
        j = foot - 1
        for label in want:
            while j >= 0 and not _text(lines[j]):
                j -= 1
            if j < 0 or _text(lines[j]) != label:
                rows = {}
                break
            rows[label] = j
            j -= 1
        if rows:
            visible = complete = True
            invalid = False
            truncated = True
            selected = ""
            for label, n in (("Approve", "1"), ("Deny", "2")):
                if highlight.search(lines[rows[label]]):
                    invalid = invalid or bool(selected)
                    selected = n
            question = ["[header off-screen]"]
            for k in range(max(0, rows["Approve"] - 6), rows["Approve"]):
                b = re.sub(r"^[\s\u2502]+", "", ansi.sub("", lines[k])).rstrip(" \t\r\n\u2502\u2500\u256e")
                if b:
                    question.append(b)
            if invalid:
                complete = False
mode = sys.argv[1]
if mode == "visible":
    sys.exit(0 if visible else 1)
if not complete or invalid:
    sys.exit(1)
if mode == "options":
    print("1\tApprove\n2\tDeny")
elif mode == "selected":
    print(selected, end="")
elif mode == "question":
    print(" ; ".join(question), end="")
' "$1"
}

prompt_menu_options()  { _prompt_menu "$1" options; }
prompt_menu_selected() { _prompt_menu "$1" selected; }
prompt_menu_question() { _prompt_menu "$1" question; }
prompt_menu_visible()  { _prompt_menu "$1" visible; }

# "Is EITHER prompt shape on screen?", from ONE pane read.
#
# The obvious spelling — `prompt_menu_visible || [ -n "$(prompt_options)" ]` —
# costs TWO `herdr pane read` processes per call, and omp-notify.sh calls it up
# to 10 times per tool call in every omp pane. Measured 2026-09-14: 20 CLI
# spawns and 10 python3 spawns per tool call, ~1.86s of CPU, all of it against
# the single herdr server socket, which is what made the TUI itself feel laggy
# with the fleet working. This reads once and answers both shapes from that
# snapshot.
#
# The numbered shape keeps _prompt_window's bottom-anchored 20-row scope: both
# reads end at the bottom of the visible region, so the last 20 rows of the
# 200-row menu window ARE the rows prompt_options would have looked at. That
# scope is load-bearing — omp prints queued/steering messages as a numbered
# list higher up the pane, and matching those is the false "needs input" that
# #59 removed. ANSI is stripped first because the menu window carries it and
# _OPT_LINE anchors at start-of-line.
prompt_any_visible() {                 # <pane>
  local win
  win=$(_menu_window "$1") || return 1
  if _menu_gate "$win"; then
    printf '%s\n' "$win" | _prompt_menu_parse visible && return 0
  fi
  # tail first, then ONE sed doing both jobs: strip the escapes the menu
  # window carries (_OPT_LINE anchors at start-of-line) and print the option
  # numbers. Two seds and a 200-row strip is measurable when this runs on
  # every tool call in every pane.
  [ -n "$(printf '%s\n' "$win" | tail -n 20 \
    | sed -nE -e $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' -e "s/$_OPT_LINE/\1/p")" ] && return 0
  return 1
}

# A stable fingerprint for "this exact prompt, right now" — the question plus
# its options, hashed. Lets a wake event and a later answer agree on WHICH
# prompt they mean: between a conductor deciding "press 2" and actually
# pressing it, the prompt can vanish, the options can change, or the pane can
# now belong to a different task entirely (time-of-check/time-of-use). A
# caller that captured a prompt_id at decision time can pass it back at
# injection time and refuse to act if it no longer matches, rather than
# firing a stale decision into whatever the pane happens to show by then.
#
# The MENU shape wins whenever a complete one is on screen, and only then does
# the numbered extractor get a turn. It used to be the other way round, and
# that was wrong for exactly the pane this fingerprint matters most on: omp
# prints its queued/steering messages as a numbered list ("1. Conductor: …"),
# so `prompt_options` matched THAT and every distinct approval panel on such a
# pane hashed to the same id. Observed live 2026-09-12 — five different
# commands (git status, a plist read, run_nightly.sh, job_ledger.py,
# search_memory.py) all woke the conductor carrying one prompt_id, which makes
# --expect-prompt-id assert a prompt that is not the one on screen. Preferring
# the menu is also what herdr-select.sh's own `_current_offer` does, so the id
# and the mechanism now agree about which prompt is being answered. A pane
# with no menu panel (Claude, Codex) is unaffected: its menu extractors return
# nothing and the numbered path runs exactly as before.
prompt_id() {
  local q opts
  q="$(prompt_menu_question "$1" 2>/dev/null)"
  opts="$(prompt_menu_options "$1" 2>/dev/null)"
  if [ -z "$opts" ]; then
    # No COMPLETE panel, so the numbered extractor supplies the options. But on
    # an omp pane the numbered extractor matches the STEERING QUEUE, and any
    # text below the navigation footer resets the menu parse — question
    # included — so both halves of the hash came from the queue and every
    # command on the pane collided again (PR #59 review, F3: the same failure
    # this function exists to stop, one layout over).
    #
    # So when a panel is on screen at all, scrape its own header rows straight
    # out of the region — "Allow tool:" down to the navigation footer — and
    # keep them in the hash. Bounded to the panel, never the whole visible
    # window: a fingerprint that moved with unrelated transcript output would
    # make --expect-prompt-id refuse a prompt that had not changed.
    local menu_q="$q"
    if [ -z "$menu_q" ]; then
      menu_q="$(herdr pane read "$1" --source visible --lines 60 2>/dev/null \
        | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' \
        | sed -n '/Allow tool:/,/enter select/p' \
        | sed -E 's/^[[:space:]│|]+//; s/[[:space:]│|]+$//' \
        | grep -vE '^$')"
    fi
    q="$(prompt_question "$1")"
    opts="$(prompt_options "$1")"
    [ -n "$menu_q" ] && q="$menu_q"$'\n'"$q"
  fi
  printf '%s\n%s' "$q" "$opts" | shasum -a 256 | cut -d' ' -f1
}

prompt_question() {
  local win
  win=$(_prompt_window "$1") || return 1
  # The last non-empty line above the first numbered option is the question.
  printf '%s\n' "$win" \
    | awk -v re="$_OPT_LINE" '
        $0 ~ /^[[:space:]]*[❯>]?[[:space:]]*[0-9]+\.[[:space:]]/ { exit }
        NF { last = $0 }
        END { gsub(/^[[:space:]]+|[[:space:]]+$/, "", last); print last }'
}

# The text an approval decision should be CLASSIFIED against
# (lib/command-policy.sh), for deciding whether automation may answer a prompt
# or must escalate it to a human.
#
# A recognized complete omp panel supplies ALL its header/detail rows, not
# a guessed shell-command extraction. Do not also classify old transcript
# output above that panel: a previous discussion of rm/credentials is not
# the pending git-status request. Unknown/numbered layouts retain the whole
# visible-region fallback because their command boundaries are not known.
#
# Never reuse prompt_context's display trimming (8 lines, 200 columns).
# Selection separately refuses explicit elision markers. This is still only
# a visible-text guard, not proof about an indirect script or a sandbox.
prompt_command_text() {
  local menu win
  menu="$(prompt_menu_question "$1" 2>/dev/null)" || menu=""
  if [ -n "$menu" ]; then printf '%s\n' "$menu"; return 0; fi
  win="$(herdr pane read "$1" --source visible --lines 60 2>/dev/null)" || win=""
  printf '%s\n%s\n' "$menu" "$(
    printf '%s\n' "$win" \
      | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' \
      | sed $'s/\xc2\xa0/ /g' \
      | grep -vE '^[[:space:]]*[─═│┌┐└┘├┤┬┴┼╭╮╰╯]+[[:space:]]*$' \
      | sed -E 's/[[:space:]]+$//'
  )"
}
