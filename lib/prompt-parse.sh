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
  # The prompt is anchored at the BOTTOM of the viewport, so this stays
  # bottom-anchored — but it takes that bottom out of the one window every
  # other scrape uses. It used to ask for `--lines 40` directly, which is the
  # clipping bug documented at _PANE_WINDOW_LINES below: a small --lines is not
  # "the last N rows", it is an unreliable slice, and at 40 an option list
  # rendered inside a taller panel could come back EMPTY while it was plainly
  # on screen. prompt_options is the necessary condition in wait-for-blocked.sh,
  # herdr-gates.sh, herdr-select.sh and attention.sh, so an empty parse there
  # reads as "no prompt" and the worker waits for an answer nobody is asked for.
  #
  # The TUI pads with blank and non-breaking-space lines, so a raw `tail` of a
  # full-height viewport can be all padding. Drop whitespace-only lines FIRST,
  # then take the bottom slice: same intent as the original `tail -n 20`, now
  # measured against content instead of furniture.
  _pane_visible "$1" \
    | sed $'s/\xc2\xa0/ /g' \
    | awk '{ s=$0; gsub(/[[:space:]]/,"",s); if (length(s)) print }' \
    | tail -n 25
}

# Is a line AGENT OUTPUT — the positive signal that a prompt above it is gone?
#
# FOUR designs were tried against the real screens before this one, and every
# failure is the reason a line of it exists:
#
#   1. a FURNITURE allowlist (box characters, branch:, the mode line). The OMC
#      bar is box characters interleaved with text and glyphs, so a real prompt
#      above a real bar went unanswerable — the 2026-08-01 failure reproduced
#      by the fix for its opposite.
#   2. bracket expressions holding box characters. In this awk (version
#      20200816, UTF-8 aware) a class containing a multibyte character matches
#      EVERY line, including an empty one: `printf 'x' | awk '$0 ~ /[─]/'`
#      matches. So the rule did not miss the bar — it matched all prose too.
#      And the byte form was the Latin-1 class [â, ...], not U+2500-257F,
#      which is why it never fired at all. ANY awk bracket class holding box
#      characters in this repo is suspect.
#   3. POSITION alone (ignore the last N lines). Swept across all 14 live
#      panes at N=0..6, refusals only cleared at N=5 — and exempting five
#      trailing lines from ever rejecting leaves nothing of the stale half.
#   4. a word count with a glyph threshold. The bar embeds the terminal TITLE,
#      so it reads as a sentence: "... Opus ... main ... Fix OMP Load
#      Warnings, KB Invariant" is seven qualifying words. Two of four agent
#      panes refused, and the other two passed only because their titles were
#      short — making answerability depend on what a task is CALLED, which is
#      worse than a deterministic miss.
#
# So: glyphs are detected with index() over real characters, never a bracket
# class, and the two-line status block at the bottom is exempt by POSITION as
# well. Together those are what make every live pane answerable.
#
# The asymmetry is the design. This gate may fail to REJECT — a stale list is
# caught downstream by the prompt fingerprint, since herdr-select refuses on a
# mismatch and the Slack numeric route needs a recorded prompt id — but it may
# not fail to ASK, because nothing downstream catches an agent nobody can
# answer.
#
# The status block: omp paints a task line plus a two-line bar, Claude Code a
# mode line, tmux one row. Two is what made all four agent panes answerable at
# tail 1 and 2 in the live sweep; more than that and the stale half is gone.
STATUS_TAIL=2

_DECOR='─│┌┐└┘├┤┬┴┼╭╮╯╰═║█▀▄▏▎▋'

_is_prose() {
  # Any decoration character at all: status bar, panel, rule, progress block.
  # `index()` on real characters — see design note 2 above.
  printf '%s\n' "$1" | awk -v g="$_DECOR" '
    BEGIN { n = split(g, ch, "") }
    { for (k = 1; k <= n; k++) if (index($0, ch[k])) exit 1
      exit 0 }' || return 1
  local words
  words=$(printf '%s\n' "$1" | awk '{ n = 0
    for (i = 1; i <= NF; i++) if ($i ~ /^[A-Za-z][A-Za-z-]+$/) n++
    print n; exit }')
  [ "${words:-0}" -ge 5 ] || return 1
  # A navigation footer is a hint, not output. Matching two LITERAL words
  # (navigate + select) was enumerating footer PHRASINGS — the same open-set
  # mistake as the furniture list, one noun over. Every one of these was
  # refused, and any of them would make a live prompt unanswerable in a CLI an
  # agent happens to run:
  #
  #   "Use the arrow keys to move, Enter to choose, Esc to go back"
  #   "Press Enter to confirm your selection, or Esc to go back"
  #   "Type a number and press return to answer this question"
  #   "(Use arrow keys or type a number, then press Enter to submit)"
  #
  # So: a KEY NAME paired with a CHOICE VERB. Short hints that are already
  # under five words ("esc to interrupt", "? for shortcuts") never reach here.
  local low
  low="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/^[^a-z0-9↑↓(?]*//; s/^[[:space:]]+//')"
  # ANCHORED at the start, because an unanchored pair swallowed real output:
  # " I have applied it. You can use the arrow keys to navigate the tree."
  # contains arrow+navigate and is a sentence about what the agent DID. A hint
  # is imperative — it opens with a key name, an arrow, a bracket, or a verb
  # telling you to act — while output opens with a subject. That is the only
  # separation available here: both shapes are the same length and use the
  # same vocabulary.
  case "$low" in
    ↑*|↓*|"("*|"?"*|press*|use*|type*|choose*|hit*|select*|enter*|esc*|escape*|tab*|space*|return*|arrow*|up\ and\ down*)
      case "$low" in
        *select*|*choose*|*navigate*|*move*|*confirm*|*cancel*|*submit*|*answer*|*go\ back*|*shortcuts*)
          return 1 ;;
      esac ;;
  esac
  return 0
}

prompt_options() {
  local win
  win=$(_prompt_window "$1") || return 1
  # The LAST run of option lines, offered unless AGENT PROSE follows it.
  #
  # `!seen[$1]++` over a 25-line window took the first occurrence of each
  # number ANYWHERE in it, so an already-answered list — or omp's steering
  # queue painted above a panel — was served as the current choice. That has
  # hurt twice: numbered-only parsing made every omp alert unanswerable
  # (2026-08-01), and the numbered-FIRST fix then matched the queue, so a Slack
  # click on "1" pressed Approve on a command the operator never saw
  # (slack-bridge/herdr-notify.sh:205-219 carries both). Menu-first ordering
  # and prompt fingerprints closed the wrong-panel half; this closes the stale
  # half, in the direction that cannot block a human.
  #
  # `[0-9]+[.]` and not `\.`: awk -v STRIPS the backslash, so passing the
  # sed-style pattern in made awk's notion of an option line looser than the
  # sed extraction that follows, and post-prompt output like
  # "249 insertions(+), 18 deletions(-)" was swallowed into the run.
  local block
  block=$(printf '%s\n' "$win" | awk -v decor="$_DECOR" '
    BEGIN { ng = split(decor, ch, "") }
    { line[NR] = $0; isopt[NR] = ($0 ~ /^[[:space:]]*[❯>]?[[:space:]]*[0-9]+[.][[:space:]]+./) }
    END {
      last = 0
      for (i = NR; i >= 1; i--) if (isopt[i]) { last = i; break }
      if (!last) exit 0
      # Walk the run upward through option lines AND their CONTINUATIONS. An
      # option that wraps ("1. Yes, and remember this decision for the rest of"
      # / "   the session") used to truncate the run to the suffix, so a
      # two-choice prompt reached Slack as ONE button and the wrapped option
      # could not be picked at all. That is the failure mode this gate exists
      # to avoid — asking a human the wrong question — so a continuation is
      # joined onto its option rather than ending the run.
      first = last
      while (first > 1) {
        if (isopt[first - 1]) { first--; continue }
        # an indented non-option line is a continuation only if an OPTION sits
        # above it; otherwise it is the question, or output, and the run ends.
        if (line[first - 1] ~ /^[[:space:]]+[^[:space:]]/ && first > 2 && isopt[first - 2]) {
          first -= 2; continue
        }
        break
      }
      acc = ""
      for (i = first; i <= last; i++) {
        if (isopt[i]) {
          if (acc != "") print "OPT\t" acc
          acc = line[i]
        } else {
          sub(/^[[:space:]]+/, " ", line[i])
          acc = acc line[i]          # a wrap is part of the option it follows
        }
      }
      if (acc != "") print "OPT\t" acc
      # Each AFTER line carries how far it is from the BOTTOM, because the
      # status block lives there and is not agent output.
      # dist-from-bottom and whether the line carries DECORATION, so the
      # caller can size the status block from the screen instead of guessing.
      for (i = last + 1; i <= NR; i++) {
        d = 0
        for (k = 1; k <= ng; k++) if (index(line[i], ch[k])) { d = 1; break }
        # PRIVATE-USE glyphs by lead byte (U+E000-F8FF -> \356/\357,
        # plane-15/16 -> \363/\364). omp marks its task-description row with
        # one, which is how that row is recognised as status rather than
        # output — it is a sentence by every other measure, and the terminal
        # TITLE it embeds is what made answerability depend on a task name.
        if (!d && (index(line[i], "\356") || index(line[i], "\357") \
                || index(line[i], "\363") || index(line[i], "\364"))) d = 1
        print "AFTER\t" (NR - i) "\t" d "\t" line[i]
      }
    }')
  [ -n "$block" ] || return 0
  # The STATUS BLOCK is measured, not assumed: the trailing run of DECORATED
  # lines (the bar), plus the one line immediately above it (omp's
  # task-description line, Claude Code's mode line — the title row).
  #
  # A fixed count was wrong in both directions. STATUS_TAIL=2 left omp's task
  # line inside the checked region, and that line embeds the terminal TITLE, so
  # it reads as a sentence — "<glyph> Fix OMP Load Warnings, KB Invariant" —
  # and a live prompt above it was REFUSED. Raising the count to cover it then
  # exempted a real line of output on panes whose status block is one row.
  # Sizing it from the screen handles both: 3 on an omp pane, 1 on a shell.
  local decor_run=0 after dist dec text
  while IFS= read -r after; do
    case "$after" in
      AFTER*)
        after="${after#AFTER	}"
        dist="${after%%	*}"; after="${after#*	}"
        dec="${after%%	*}"
        [ "$dist" -eq "$decor_run" ] && [ "$dec" = 1 ] && decor_run=$((decor_run + 1))
        ;;
    esac
  done < <(printf '%s\n' "$block" | awk -F'\t' '$1=="AFTER"' | sort -t'	' -k2,2n)
  # Exactly the decorated run. An earlier version added one for "the title
  # row", which on a pane whose status block is bar-only exempted a genuine
  # line of output and offered the canonical stale list. The title row is
  # detected instead (private-use glyph), so it is inside the run when present
  # and costs nothing when absent.
  local status_block=$decor_run
  while IFS= read -r after; do
    case "$after" in
      AFTER*)
        after="${after#AFTER	}"
        dist="${after%%	*}"; after="${after#*	}"
        dec="${after%%	*}"; text="${after#*	}"
        [ "$dist" -ge "$status_block" ] || continue
        _is_prose "$text" && return 0
        ;;
    esac
  done <<<"$block"
  printf '%s\n' "$block" | sed -n 's/^OPT\t//p' \
    | sed -nE "s/$_OPT_LINE/\1\t\2/p" \
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
  # Same window as every other scrape. This is the ALERT BODY — the only text
  # describing what the agent is asking — and it was reading the clipped
  # `--lines 40` slice, so the question itself could be missing from the very
  # message sent to get it answered. The filters below strip furniture and the
  # closing `tail -n 8` bounds the result, so a taller window costs nothing.
  win=$(_pane_visible "$1") || return 1
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
# Read the WHOLE visible screen, everywhere a pane is scraped.
#
# 60 was a guess, and a panel taller than it is silently unanswerable: the
# "Allow tool:" header scrolls out of the window, the parser fails closed
# (correctly — it will not turn detail text into option 1), and the worker sits
# `blocked` with nobody able to press a key. Observed 2026-09-12 on wH:p6,
# whose panel spanned 61 rows: at --lines 60 the header appeared 0 times, at
# --lines 200 it appeared once. The workaround had even reached our task briefs
# ("keep every bash command short enough that an approval panel renders it
# whole"), which is a parser bug wearing a process rule.
#
# `--source visible` already caps the read at the pane's own viewport —
# measured across all 11 live panes, `--lines 200` and `--lines 500` return
# identical row counts, never more than viewport_rows. So the window only has
# to be LARGER than any viewport; it does not have to be exact. An earlier cut
# of this fix derived it from `herdr pane list`, which cost a second RPC and a
# jq per parse (+73%: 18.5ms -> 32.1ms) on a path that runs ~20 times per alert
# — to produce a number that is inert for every pane here, and that can be
# stale by the time `pane read` runs anyway. A constant is cheaper AND more
# correct.
#
# Every pane scrape shares this, because a window that is right in one place
# and 60 in three others is the same bug wearing a different line number.
_PANE_WINDOW_LINES=1000

_menu_window() {
  herdr pane read "$1" --source visible --lines "$_PANE_WINDOW_LINES" --format ansi 2>/dev/null
}

# The same window, without ANSI — for the scrapes that work on plain text.
_pane_visible() {
  herdr pane read "$1" --source visible --lines "$_PANE_WINDOW_LINES" 2>/dev/null
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
#
# The wider window above makes the gate MORE valuable, not less: a 1000-row
# read hands python ~20x the bytes it used to, so refusing the spawn on a
# window that cannot parse is now the difference between a cheap grep and a
# 23 kB parse per attempt.
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


def _text(s):
    return re.sub(r"^[^A-Za-z0-9]+", "", ansi.sub("", s)).rstrip(" \t\r\n|-\u2502\u2500\u256e")


# A pane narrow enough to wrap the navigation footer splits it across rows, and
# the wrap point depends only on pane width: 43 columns broke it before
# "cancel", a narrower pane breaks it earlier. Every fragment is footer, never
# output — but both passes below judge rows individually, so the leftover
# fragment read as text BELOW the footer and failed the panel closed. The hub
# then paged for a prompt that peer-answer and herdr-select both refused to
# touch, leaving a human keypress as the only exit (wN:p9, 2026-09-18).
#
# Rejoining here, once, keeps both passes and every fixture judging the same
# canonical single-row footer. It only ever fires on rows whose text is a
# PREFIX of the exact phrase, so a command row that merely mentions these words
# is untouched.
#
# ADJACENCY IS THE WHOLE SAFETY PROPERTY, and the first version of this did not
# have it. It skipped any row whose _text() was empty, and _text() strips all
# leading non-alphanumerics — so the panel closing border, rules, block glyphs
# and padding rows all normalise to empty and the accumulator walked straight
# past the bottom of the panel. It then joined the first REAL output line onto
# the fragment whenever that line happened to be an exact remaining suffix of
# the phrase, so a DISMISSED panel followed by agent output `cancel` parsed as
# a live, answerable menu. That is precisely the false positive the
# bottom-anchor check below exists to prevent: wait-for-blocked.sh would wake
# on a pane that had moved on, and herdr-select.sh would press a key into a
# pane that was not asking anything. Caught in review of this branch before it
# merged (PR #93).
#
# So a fragment joins ONLY to the row immediately beneath it. A wrap is a
# rendering artefact of one logical line; there is never a blank, a border or
# anything else inside it.
#
# One known gap, unreachable today: the prefix test is character-level but the
# rejoin inserts a space, so a footer broken MID-WORD ("enter sel" / "ect esc
# cancel") never reassembles. omp word-wraps inside its own box, so this cannot
# happen now — and if it ever did, _menu_gate would close first (the window
# would contain no literal "select") and the parser would never be spawned, so
# no fixture here would catch it. Worth knowing before changing how omp draws.
#
# A second gap is ACCEPTED DELIBERATELY, disclosed by the reviewer who found
# the adjacency bug above: adjacency does not require the continuation to be
# INSIDE the panel, so a bordered fragment
#     │ up/down navigate  enter select  esc │
# followed DIRECTLY by a bare, unbordered `cancel` still parses as answerable,
# where main refuses it. It needs the first fragment to be the last panel row
# with no closing border beneath it, and no real dismissed-panel capture
# produces that — the panel own second fragment and its `╰──╯` sit in
# between, and the break fires.
#
# The available fix (require both rows to share the box gutter) was written and
# tested, and REJECTED: it assumes a wrap preserves the gutter, so a
# hanging-indented footer would become unanswerable — the worst failure this
# file has, the one that stranded wN:p9. The two errors are not
# symmetric. A spurious keypress is bounded by herdr-select verifying the
# selection took effect and by `--expect-prompt-id` failing closed when the
# prompt is gone, so it degrades to a no-op; an unparseable real menu degrades
# to a stalled worker and a human woken at 3am. Do not close this by making
# real menus stricter. If omp ever hangs-indents the footer, revisit BOTH
# choices together.
FOOTER = "up/down navigate enter select esc cancel"


def _unwrap_footer(rows):
    out, i = [], 0
    while i < len(rows):
        acc = " ".join(_text(rows[i]).split())
        if acc and acc != FOOTER and FOOTER.startswith(acc):
            j = i + 1
            while j < len(rows) and acc != FOOTER:
                nxt = " ".join(_text(rows[j]).split())
                cand = acc + " " + nxt if nxt else ""
                if not nxt or not FOOTER.startswith(cand):
                    break
                acc, j = cand, j + 1
            if acc == FOOTER:
                out.append(FOOTER + "\n")
                i = j
                continue
        out.append(rows[i])
        i += 1
    return out


# Read bytes: a stray non-UTF-8 byte in a pane must degrade to U+FFFD, not
# abort the parser and silence the wake path.
lines = _unwrap_footer([raw.decode("utf-8", "replace") for raw in sys.stdin.buffer])
for line in lines:
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
      menu_q="$(_pane_visible "$1" \
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
  win="$(_pane_visible "$1")" || win=""
  printf '%s\n%s\n' "$menu" "$(
    printf '%s\n' "$win" \
      | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' \
      | sed $'s/\xc2\xa0/ /g' \
      | grep -vE '^[[:space:]]*[─═│┌┐└┘├┤┬┴┼╭╮╰╯]+[[:space:]]*$' \
      | sed -E 's/[[:space:]]+$//'
  )"
}
