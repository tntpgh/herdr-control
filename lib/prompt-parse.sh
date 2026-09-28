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

# KNOWN SHAPES THIS WINDOW DOES NOT HANDLE. Recorded here because they were
# carried as "named, not patched" through five review rounds and lived only in
# commit messages and PR bodies — which is not where the next person to touch
# this function will look. None is reachable from any tool in this fleet today;
# each becomes reachable the moment one paints the shape.
#
#   1. A STATUS ROW THAT WRAPS. The status block is sized from the screen as the
#      trailing run of DECORATED lines. A row that wraps puts its continuation
#      on a line carrying no glyph, so the run stops under it and the rows above
#      the continuation are read as output. Reproduced by splicing a prompt
#      above `"   and merge the remaining pull requests cleanly"` plus a real
#      bar: the options are refused.
#
#   2. A BANNER PRINTED BETWEEN A PROMPT AND THE BAR (an update notice, a
#      deprecation line). It is undecorated, so it ends the status run early and
#      the prompt above it falls outside the window.
#
#   Both fail toward NOT OFFERING, which is the direction that leaves an agent
#      unanswerable — the one this file's asymmetry says must not happen. The
#      fix for either is the same and was deliberately not taken: widening the
#      block by a fixed count re-opens the stale-menu hole that positional
#      sizing was removed to close.
#
#   3. A SINGLE INVALID UTF-8 BYTE aborts the awk below (`towc: multibyte
#      conversion failure`), truncating the window at that line. PRE-EXISTING
#      and identical on origin/main — options survive if the bad byte is below
#      them and are lost if above.
#
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

# _composer_input_rows (stdin filter) — only the rows a human types into.
#
# omp draws its composer as a box at the bottom of the pane: a `╭── <status
# bar> ──╮` top border, then the input (`│ …` continuation rows, the last row
# on the `╰─ …` border itself). Everything above that border is agent OUTPUT,
# and on a working agent it changes every frame — streamed text, tool panels,
# "background job completed" notices — as does the border itself (spinner,
# elapsed time, cost, context %, git untracked count). None of that is typing.
# Only the rows below the LAST `╭` are the composer.
#
# No `╭` in the window — a `❯` composer, or input tall enough to scroll its own
# border out of view — means the whole window, which is all this ever compared
# before; the second case is all input rows anyway.
_composer_input_rows() {
  awk '{ row[NR] = $0 } /^[[:space:]]*╭/ { top = NR } END { for (i = top + 1; i <= NR; i++) print row[i] }'
}

# composer_looks_actively_typed <pane> [settle_ms=350]
#
# Two reads of the composer's INPUT ROWS (_composer_input_rows over
# composer_stable_snapshot) a short interval apart, compared. A human
# mid-keystroke changes them between reads; an idle composer does not.
#
# The gap this closes: send-to-agent.sh's only pre-send check was "is the
# pane on a permission prompt" — nothing asked whether a human was AT THAT
# MOMENT typing into the same composer this script was about to write into.
# Two writers on one stdin interleave; the operator's own keystrokes and an
# injected message would land mixed into each other, corrupting both, with
# no error from anything — `herdr pane send-text` has no way to know it
# shares the terminal with a live human.
#
# Why input rows only (regression, 2026-09-23): the first version compared the
# whole 12-line snapshot, so any WORKING omp pane read as "typing" — its output
# and status border churn between two reads 350ms apart. Every push wake into
# a busy conductor was refused with exit 6: 20 of 21 in the first 15 minutes
# after it shipped, including a wake for a prompt only a human could answer.
#
#   0 = actively changing right now (probably a human typing)
#   1 = stable across the interval (looks safe to write into)
#   2 = unreadable — caller must not guess; same as any other blind spot
#       here, this refuses rather than assumes idle.
composer_looks_actively_typed() {
  local pane="$1" settle_ms="${2:-350}"
  local a b
  a=$(composer_stable_snapshot "$pane" 12) || return 2
  sleep "$(awk "BEGIN { printf \"%.3f\", $settle_ms / 1000 }")"
  b=$(composer_stable_snapshot "$pane" 12) || return 2
  [ "$(printf '%s\n' "$a" | _composer_input_rows)" = "$(printf '%s\n' "$b" | _composer_input_rows)" ] && return 1
  return 0
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

# tmux truncates a captured line at the pane's column width, and that cut can
# land INSIDE a multibyte UTF-8 character — the box edge of a wrapped commit
# message with an em-dash near the wrap column, for instance. The orphaned
# lead byte(s) are not valid UTF-8, and every awk/sed downstream in this file
# runs in a UTF-8 locale so it can match real glyphs (box-drawing, arrows,
# the private-use status glyph) by character. Confirmed live: a truncated
# em-dash (bytes e2 80 with no third byte) makes BSD sed exit 2 "stream did
# not contain valid UTF-8", which empties a `$(...)` pipeline the caller
# never checks the exit code of — the parse goes quietly wrong instead of
# loudly crashing. `iconv -c` DROPS invalid bytes and passes valid multibyte
# characters through unchanged, so this is the one place to fix it: every
# consumer below stays UTF-8-aware, and a torn character is gone rather than
# poisoning the whole scrape. `2>/dev/null` matches the `herdr pane read`
# call it wraps — an unreadable pane already returns empty, not an error.
_sanitize_utf8() { iconv -c -f UTF-8 -t UTF-8 2>/dev/null; }

# Unsanitized: the same window `_menu_window`/`_pane_visible` read, before
# `_sanitize_utf8` drops anything. Exists so `prompt_command_torn` below can
# check the RAW bytes for validity without re-deriving the `herdr pane read`
# invocation a second, differently-spelled way.
_pane_read_raw() {                      # <pane> [herdr-pane-read-extra-args...]
  local pane="$1"; shift
  herdr pane read "$pane" --source visible --lines "$_PANE_WINDOW_LINES" "$@" 2>/dev/null
}

_menu_window() {
  _pane_read_raw "$1" --format ansi | _sanitize_utf8
}

# The same window, without ANSI — for the scrapes that work on plain text.
_pane_visible() {
  _pane_read_raw "$1" | _sanitize_utf8
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
# fix/approve-wrapped-commands security review round 1 (F3) and round 2
# (N5): per-row measurements needed to tell a genuine terminal wrap from a
# real line break, same indices as `question`.
#   question_rawlen      the RAW rendered length (ANSI stripped, before any
#                         body/text stripping) of the row as captured.
#   question_content_end  the column the rows own CONTENT ends at: raw
#                         length minus whatever trailing padding/box-border
#                         run (spaces, `|`/border-draw chars) was stripped.
#                         In a padded, right-bordered box every rows RAW
#                         length is the SAME (the box width) regardless of
#                         how short its content is -- round 2s N5 finding:
#                         using raw length alone as the "is this row full"
#                         signal is vacuous there. content_end is what
#                         actually varies with how much of the row a short
#                         line fills.
#   box_width             the right-bordered boxs own width (a `\u2571`/
#                         corner-drawn header row was seen), or None when
#                         this capture never showed a border at all -- a
#                         left-gutter-only capture (no right border, no
#                         padding) carries no reliable reference for "did
#                         this row reach the edge", so it never glues
#                         (round 2, N5/N2: "if theres no border, dont glue").
question_rawlen = []
question_content_end = []
box_width = None
selected = ""
invalid = complete = visible = poisoned = False
truncated = False
# The most recent "running <label>" bordered box seen while scanning, and a
# snapshot of it taken the instant a panel opens. See BROWSER_FALLBACK below
# for why this exists — the approval panel for some tools (browser, observed
# 2026-09-21) renders NO body row between its header and "Approve", so it is
# the only source of content that distinguishes one pending call from another.
running_open = False
running_lines = []
pending_running = []


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
# file has, the one that stranded wN:p9. The two errors are not symmetric: the
# false negative is unbounded — a worker stalls until a human notices — while
# the false positive is ONE bare Enter with no gap between deciding and
# pressing, because peer-answer classifies and presses inside a single call.
#
# Be precise about why, because the obvious reason is wrong: peer-answer does
# NOT pass `--expect-prompt-id` (peer-answer.sh:148 calls herdr-select with
# just `--authority peer`), and herdr-select only enforces that fingerprint
# when it was supplied (:219) — it is REQUIRED only for `--authority conductor`
# (:260). So on the peer path nothing downstream re-checks that the prompt was
# ever live, and none of the other guards fire on this residual either: the
# re-offer check re-reads the same screen and agrees, `_require_current_
# decision` only catches a change DURING the run, and the confirm-after-each-
# keystroke walk is skipped entirely when Approve is already highlighted
# (choice == cur, so it goes straight to Enter — the fixtures pin that as a
# single bare `Enter`). `require_pane_birth_match` does run, but it proves pane
# identity, not prompt liveness.
#
# Do not close this by making real menus stricter. If omp ever hangs-indents
# the footer, revisit BOTH choices together.
FOOTER = "up/down navigate enter select esc cancel"

# omp 18.3.5 (installed 2026-09-27) renders the footer KEY names through its
# symbolPreset instead of printing them as words. Measured on live panes:
#   older omp : "up/down navigate  enter select  esc cancel"
#   nerd      : "U+2191/U+2193 navigate  U+F0311 select  U+F12B7 cancel"
#   ascii     : "Up/Down navigate  Enter select  Esc cancel"
# The literal match above stopped matching every omp pane started after the
# upgrade, so prompt_menu_visible went false while Approve/Deny sat on screen
# and herdr-select/peer-answer refused every worker. The ACTION words never
# changed, so the footer is recognised by SHAPE: key, navigate, key, select,
# key, cancel. A key is one of the old key words, an arrow pair, or ONE glyph
# from a private-use plane (nerd icons). Leading strip is whitespace and the
# box-drawing gutter only, so an ascii-preset box ("| ... |") still fails
# closed as it did before: its gutter is a pipe, which is not a key.
_KEY = re.compile(r"^(?:up/down|enter|esc|[\u2190-\u21ff\u23ce](?:/[\u2190-\u21ff])?|[\ue000-\uf8ff\U000f0000-\U0010fffd])$")
SHAPE = ["<k>", "navigate", "<k>", "select", "<k>", "cancel"]


def _ftoks(s):
    b = re.sub(r"^[\s\u2502]+", "", ansi.sub("", s)).rstrip(" \t\r\n\u2502\u2500\u256e")
    return ["<k>" if _KEY.match(w) else w for w in b.lower().split()]


def _is_footer(s):
    return _ftoks(s) == SHAPE


def _unwrap_footer(rows):
    out, i = [], 0
    while i < len(rows):
        acc = _ftoks(rows[i])
        if acc and acc != SHAPE and SHAPE[:len(acc)] == acc:
            j = i + 1
            while j < len(rows) and acc != SHAPE:
                nxt = _ftoks(rows[j])
                cand = acc + nxt if nxt else []
                if not nxt or SHAPE[:len(cand)] != cand:
                    break
                acc, j = cand, j + 1
            if acc == SHAPE:
                out.append(FOOTER + "\n")
                i = j
                continue
        out.append(rows[i])
        i += 1
    return out


# Read bytes: a stray non-UTF-8 byte in a pane must degrade to U+FFFD, not
# abort the parser and silence the wake path.
lines = _unwrap_footer([raw.decode("utf-8", "replace") for raw in sys.stdin.buffer])
_border_chars = "\u2500\u256d\u256e\u2570\u256f"  # ─ ╭ ╮ ╰ ╯
# #191 (herdr-control PR #189 round-2 security review, P2/CRITICAL): the
# pass-1 opener used to accept ANY non-alnum prefix (`text`, stripped at
# `^[^A-Za-z0-9]+`), so a Python COMMENT inside a real eval body --
# `# Allow tool: read Path: README.md` -- opened a fake one-row "read"
# panel once the genuine header had scrolled off the top of the captured
# window (a tall eval body, the wM:p4 shape). A real omp panel header is
# never preceded by anything but whitespace or the box-drawing border this
# parser already tracks (`_border_chars`, plus the vertical bar `│`); an
# arbitrary prefix like `#`, `//`, `*` or a quote character means the row
# is BODY TEXT that merely contains the literal string, never a real
# header omp rendered.
_HEADER_PREFIX_RE = re.compile(r"^[\s\u2502" + _border_chars + r"]+")
# Round-3 security review interim hardening (#191 stays open; this narrows
# the exposure, it does not close it -- a real fix needs the tool name
# recorded at the hook, see SUMMARY.md): a real omp header row carries
# NOTHING after "Allow tool: <name>" but the name itself (optional -- omp
# can wrap the row right after the colon, leaving the name on the NEXT
# row) and trailing border/space. `Allow tool: read Path: README.md"""`
# (a Python string literal body row that merely starts with the literal)
# fails this: there is a SECOND field after the tool name, which no real
# header row ever has.
_HEADER_TOOL_RE = re.compile(r"^Allow tool:(\s*\S+)?[\s\u2502" + _border_chars + r"]*$")

def _row_metrics(plain_line):
    raw = plain_line.rstrip("\r\n")
    content_end = len(raw.rstrip(" \t\u2502" + _border_chars))
    bordered = any(c in raw for c in _border_chars)
    return len(raw), content_end, bordered


for line in lines:
    plain = ansi.sub("", line)
    # `text` (leading punctuation stripped) is ONLY for header/option/footer
    # matching. `body` keeps a command row intact — `-rf`, `--flag`, `| sh`,
    # `~/.ssh` — because it is what gets classified.
    text = re.sub(r"^[^A-Za-z0-9]+", "", plain).rstrip(" \t\r\n│─╮")
    body = re.sub(r"^[\s│]+", "", plain).rstrip(" \t\r\n│─╮")
    # A header row only OPENS a panel; inside one it is command content
    # (a multi-line command can contain the literal text "Allow tool:").
    # #191 narrowed the opener to `header_text` (whitespace/border-char
    # prefix only); F8 (round-3 security review R9) restores the original,
    # looser trigger (`text`, ANY non-alnum prefix stripped) that MAIN
    # still uses, so a row that would open a panel on MAIN still opens one
    # here too -- but marks the panel POISONED unless the row ALSO clears
    # both the #191 border-prefix check and the interim hardening check
    # (nothing after the tool name, `_HEADER_TOOL_RE`). A poisoned panel
    # still takes in every row below it exactly like the old opener did
    # (so a LATER row that would otherwise open a fresh, clean one-row
    # panel over the real command cannot -- state is already 1), but can
    # never itself produce a pressable verdict: `complete` below is forced
    # False whenever `poisoned`, so pass 2 footer-anchored fallback decides.
    header_text = _HEADER_PREFIX_RE.sub("", plain)
    real_header = bool(header_text.startswith("Allow tool:") and _HEADER_TOOL_RE.match(header_text))
    if state == 0 and text.startswith("Allow tool:"):
        pending_running = list(running_lines)
        state, question, selected = 1, [text], ""
        poisoned = not real_header
        _rawlen, _cend, _bordered = _row_metrics(plain)
        question_rawlen = [_rawlen]
        question_content_end = [_cend]
        box_width = _rawlen if _bordered else None
        invalid = complete = visible = False
        continue
    if state == 0:
        # Track the nearest preceding "running <label>" bordered box. Close
        # on an "Output"/"Status" divider (the call already finished, so its
        # body is a PAST result) or the box own closing border: that row has
        # pipe/border content (body non-empty) but no alnum (text empty) once
        # leading non-alnum is stripped — the ONE thing that told it apart
        # from a blank row inside the box, which also strips to empty text
        # but ALSO strips to an empty body (the whole row is spaces and pipe
        # chars, all in the leading-strip class). Checking "no alnum" alone
        # closed on that first blank row, before ever reaching the code.
        if text.startswith("running "):
            running_open, running_lines = True, []
        elif running_open:
            if _text(plain).startswith(("Output", "Status")):
                running_open = False
            elif body and not text:
                running_open = False
            elif body:
                running_lines.append(body)
        if text:
            complete = visible = False
        continue
    if _is_footer(line):
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
        # F8 (round-3 security review R9): a poisoned panel (see the
        # opener above) can reach state 3 exactly like a real one -- every
        # row below it, including a real Approve/Deny/footer, still gets
        # consumed the same way -- but it must never itself count as
        # complete. `not poisoned` is the whole fix: pass 2 decides instead.
        complete = state == 3 and not invalid and not poisoned
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
        _rawlen, _cend, _ = _row_metrics(plain)
        question_rawlen.append(_rawlen)
        question_content_end.append(_cend)
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
        if _is_footer(lines[i]):
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
            question_rawlen = [-1]
            question_content_end = [-1]
            box_width = None
            for k in range(max(0, rows["Approve"] - 6), rows["Approve"]):
                b = re.sub(r"^[\s\u2502]+", "", ansi.sub("", lines[k])).rstrip(" \t\r\n\u2502\u2500\u256e")
                if b:
                    question.append(b)
                    _rawlen, _cend, _ = _row_metrics(ansi.sub("", lines[k]))
                    question_rawlen.append(_rawlen)
                    question_content_end.append(_cend)
            if invalid:
                complete = False
# _wrapjoin(q, qlen, cend, box_w) -> the mid-token wrap-join candidate for
# the Command:/run: row onward, or None when no such row exists in q.
#
# fix/approve-wrapped-commands security review round 1, F2: a panel with no
# Command:/run: row at all (a header-only browser call, say) must never
# fabricate one by gluing the tool-name header onto whatever text follows
# -- so this returns None, never a guess, when no label row is found. The
# head (everything through the label row itself) is joined with a plain
# space, byte-identical to "command" mode; only rows AFTER the label row
# are candidates for a no-separator glue.
#
# Round 1, F3 (superseded by round 2, N5): the first cut glued a boundary
# whenever the row aboves RAW length equalled the widest raw row seen. That
# is vacuous in a real, right-bordered omp panel: padding makes EVERY row
# the same raw length regardless of its content, so every boundary passed.
# It was also wrong the other way for a left-gutter-only capture (no right
# border): the longest row always counts as "full" even when nothing
# establishes that it reached the actual terminal edge.
#
# Round 2, N5 fix: only ever glue when a border was genuinely captured
# (box_w is not None -- a `\u256d…\u256e`/`\u2570…\u256f` header or footer
# row was seen for THIS panel); a left-gutter-only capture has no reference
# for "the edge" at all and never glues. Where a border exists, compare
# each rows CONTENT end column (its raw length minus trailing
# padding/border, `question_content_end`) against the boxs own width, not
# the rows raw length -- a short line inside a padded box has a small
# content_end even though every row is padded to the same raw length.
# SLACK absorbs the boxs own 1-2 column right margin (the mandatory space
# before the border) without letting a genuinely short row pass.
_WRAPJOIN_SLACK = 2


def _wrapjoin(q, qlen, cend, box_w):
    idx = None
    for i, row in enumerate(q):
        if row.startswith("Command:") or row.startswith("run:"):
            idx = i
            break
    if idx is None:
        return None
    head, tail = q[:idx], q[idx:]
    text = " ".join(head + tail[:1])
    if box_w is not None and len(cend) == len(q):
        tail_cend = cend[idx:]
    else:
        tail_cend = None
    for i in range(1, len(tail)):
        full = tail_cend is not None and tail_cend[i - 1] >= box_w - _WRAPJOIN_SLACK
        text += ("" if full else " ") + tail[i]
    return text


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
    # BROWSER_FALLBACK: some tools approval panel (browser, observed
    # 2026-09-21) renders no body row at all between its header and
    # "Approve" — two distinct pending calls (open a tab; evaluate on it)
    # produced the IDENTICAL panel text and so the IDENTICAL prompt_id,
    # which defeats --expect-prompt-id staleness detection for that tool: a
    # conductor answering one browser prompt could not tell it apart from
    # the next. `question` degenerate here means len == 1, just the header
    # — a real command/diff/detail row from any OTHER tool already makes it
    # longer, so this never touches an already-distinguishing panel.
    if len(question) == 1 and pending_running:
        question = question + pending_running
    print(" ; ".join(question), end="")
elif mode == "command_rows":
    if len(question) == 1 and pending_running:
        question = question + pending_running
    rows = question
    for i, row in enumerate(question):
        if row.startswith("Command:"):
            rows = question[i:]
            break
    print(len([r for r in rows if r.strip()]), end="")
elif mode == "command_wrapjoin":
    # A candidate reconstruction for a MID-TOKEN terminal wrap -- see
    # _wrapjoin above for the F2/N5 rules (no label row -> nothing; glue
    # only past the label row, only at a full-width boundary in a
    # genuinely bordered capture). Both this and "command" are candidates,
    # never a verdict on their own: herdr-select.sh only trusts whichever
    # one, after whitespace-collapse, equals the SEPARATE hook-recorded
    # command (lib/scoped-policy.sh approval_command_text) -- this mode
    # only supplies the second candidate string. No apostrophes in here:
    # this whole parser is a single-quoted shell argument.
    wj = _wrapjoin(question, question_rawlen, question_content_end, box_width)
    if wj is None:
        sys.exit(1)
    print(wj, end="")
elif mode == "command":
    # For CLASSIFICATION ONLY (lib/command-policy.sh via prompt_command_text
    # below), never for display or prompt_id: `" ; "` is a real shell
    # separator. A long single command wraps across several terminal ROWS --
    # a box width, not a statement boundary -- and each wrapped row becomes
    # its own `question` entry the same as a genuinely distinct detail row.
    # Joining those with `" ; "` manufactured a FAKE statement boundary that
    # the walker in command-policy.sh then split on for real, so a long
    # argument that landed alone on its own wrapped row (`/tmp/.../notes.md`
    # with nothing else on that row) was read as a standalone segment whose
    # "command word" IS that path: the rule in command-policy.sh for "no
    # interpreter, the command word IS the file" then fired, escalating an
    # ordinary `cat`/`sed`/`grep` of a long path as "executes a data file".
    # A plain space reconstructs the original wrapped line instead: any
    # REAL statement separator the agent actually typed is already a
    # character INSIDE one of these rows (a literal `;`/`&&`/newline in the
    # command text itself), so nothing that must escalate stops escalating —
    # only the artificial row boundary this parser itself introduced is
    # removed.
    if len(question) == 1 and pending_running:
        question = question + pending_running
    print(" ".join(question), end="")
elif mode == "command_both":
    # fix/approve-wrapped-commands security review round 1, F6: ONE parser
    # call, ONE `herdr pane read`, emitting BOTH corroboration candidates
    # so a caller never pairs a space-join from one screen with a
    # wrap-join from a later, possibly repainted one. Output is
    # "<space-join>\x1e<wrap-join-or-empty>"; \x1e (ASCII record
    # separator) is the split point the bash side uses.
    #
    # Round 2, N7: a captured row that itself contains a literal 0x1E
    # would otherwise land inside the emitted text and shift that split
    # point, truncating what the caller reads as CC_PANEL at the injected
    # byte. A real terminal grid should never store a C0 control in a
    # cell, but this is cheap to fail closed on rather than trust that:
    # refuse to emit anything (exit 1, same as any other unparseable
    # panel) when any captured row carries one.
    if any("\x1e" in row for row in question + pending_running):
        sys.exit(1)
    sp_q = question + pending_running if len(question) == 1 and pending_running else question
    wj = _wrapjoin(question, question_rawlen, question_content_end, box_width)
    sys.stdout.write(" ".join(sp_q) + "\x1e" + (wj if wj is not None else ""))
' "$1"
}

prompt_menu_options()  { _prompt_menu "$1" options; }
prompt_menu_selected() { _prompt_menu "$1" selected; }
prompt_menu_question() { _prompt_menu "$1" question; }
prompt_menu_command()  { _prompt_menu "$1" command; }
prompt_menu_command_rows() { _prompt_menu "$1" command_rows; }
prompt_menu_command_wrapjoin() { _prompt_menu "$1" command_wrapjoin; }
prompt_menu_command_both() { _prompt_menu "$1" command_both; }
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
#
# The id is an OCCURRENCE, not just content (2026-09-27, F7b). Content alone
# collided across time and across panes: one id (9db57228…) covered 190 events
# on 40 tasks, and a worker re-asking the identical `git status` an hour later
# reused the first occurrence's input_required row (INSERT OR IGNORE on a
# prompt_id-derived event id), its grace claims and its wake key. So the hash
# also carries the pane id, the pane's live birth (herdr's terminal_id, never
# reused) and prompt_period below. Prints nothing and returns 1 when no
# question or option is readable: a vanished prompt has no identity, and a
# constant "empty" digest used to ship as an actionable Slack button.
prompt_id() {
  local content
  content="$(prompt_content "$1")" || return 1
  prompt_id_of "$1" "$content"
}

# prompt_id_of <pane_id> <content> -> prompt_id for content already read with
# prompt_content, so a caller that also needs the content digest reads the
# screen once, not twice (a second read can see a different frame).
prompt_id_of() {
  local birth period
  birth="$(command -v pane_birth_now >/dev/null 2>&1 || . "$_PP_LIB_DIR/pane-guard.sh" >/dev/null 2>&1
           pane_birth_now "$1" 2>/dev/null)"
  period="$(prompt_period "$1")"
  printf 'pane=%s\nbirth=%s\nperiod=%s\n%s' "$1" "$birth" "$period" "$2" \
    | shasum -a 256 | cut -d' ' -f1
}

# prompt_content_digest <pane_id> -> the hash of WHAT is on screen, without the
# occurrence salt. For the one caller that must re-check the screen after it
# has itself closed the blocked period (herdr-select.sh, right before its
# keystroke), where prompt_id has legitimately stepped. prompt_digest_of is the
# same hash for content already read.
prompt_content_digest() {
  local content
  content="$(prompt_content "$1")" || return 1
  prompt_digest_of "$content"
}
prompt_digest_of() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }

# prompt_content <pane_id> -> "<question>\n<options>", or rc 1 when neither is
# readable. The content half of prompt_id.
prompt_content() {
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
        | sed -n '/Allow tool:/,/navigate.*select/p' \
        | sed -E 's/^[[:space:]│|]+//; s/[[:space:]│|]+$//' \
        | grep -vE '^$')"
    fi
    q="$(prompt_question "$1")"
    opts="$(prompt_options "$1")"
    [ -n "$menu_q" ] && q="$menu_q"$'\n'"$q"
  fi
  [ -n "$q$opts" ] || return 1
  printf '%s\n%s' "$q" "$opts"
}

# prompt_period <pane_id> -> which blocked period of this pane we are in: the
# registry sequence of the latest time a task registered on the pane LEFT
# `blocked` (a state_changed event with from=blocked), or 0.
#
# Keyed on the END of the previous period, never the start of this one. A
# start marker (the old attn_prompt_edge, written by the hook's first firing)
# races every other reader at exactly the moment they all look: live,
# 2026-09-26 (events 37680/37682), attention-tick.sh read the pane before the
# hook marked its edge, the two computed different keys, and the conductor was
# woken twice for one prompt. A close is written when the previous prompt was
# answered (herdr-select.sh after a confirmed press, agent-edge.sh when the
# agent leaves `blocked`), long before the next prompt paints, so every reader
# of the new prompt sees the same value. The id then steps exactly when the
# prompt is answered, which is when a decision captured against it goes stale.
# Only blocked->running counts: a previous occupant of a RECYCLED pane id
# being moved blocked->lost by reconcile while the new occupant's prompt is
# open must not step that prompt's id (PR #168 review). Unregistered panes (a
# hand-started session) have no transitions: 0.
# Read in a subshell so run-registry.sh's shell options never leak into a
# caller that did not source it (herdr-notify.sh, sweep-approvals.sh, …).
_PP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prompt_period() {                      # <pane_id>
  (
    command -v _sql >/dev/null 2>&1 || . "$_PP_LIB_DIR/run-registry.sh" >/dev/null 2>&1 || { printf '0'; exit 0; }
    [ -f "$(registry_db)" ] || { printf '0'; exit 0; }
    n="$(_sql "SELECT max(e.sequence) FROM events e JOIN tasks t ON t.task_id=e.task_id
          WHERE t.pane_id=$(_sq "$1") AND e.type='state_changed'
            AND json_extract(e.payload,'\$.from')='blocked'
            AND json_extract(e.payload,'\$.state')='running';" 2>/dev/null)"
    printf '%s' "${n:-0}"
  )
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
# Does the RAW capture behind prompt_command_text below contain a byte that
# is not valid UTF-8, BEFORE _sanitize_utf8 drops it, WITHIN the text that
# actually gets classified?
#
# PR #147 hold (Main's live probe table, 2026-09-25): _sanitize_utf8's
# `iconv -c` is right for MENU PARSING — a torn byte must never crash the
# parser, which is what stranded a pane before that fix — but it is never
# safe for the text a peer-authority decision is CLASSIFIED against.
# Dropping the byte classifies whatever SURVIVES, and the live probe table
# showed that turns escalate/deny into allow: a recursive delete of a local
# dir plus one torn byte at the row end, and a curl download plus one torn
# byte, both went from escalate to allow; `x` plus a torn byte plus a
# recursive delete of `/` went from deny to allow. Reading LESS of a
# dangerous command is not the same as reading NONE of it — a classifier
# that only ever sees the surviving bytes can be steered toward its
# blindest verdict by whichever byte gets torn off. herdr-select.sh consults
# this and forces escalate whenever it is true, never trusting an allow
# computed on a possibly-redacted capture.
#
# Reads the pane a second time rather than threading a flag out of
# prompt_command_text: that function's result crosses a `$(...)` command
# substitution at every call site, so a variable it set would not survive
# back to the caller. This runs once per actual answer decision (not in any
# hot poll loop), so the extra read costs nothing that matters here.
#
# UNREADABLE COUNTS AS TORN (independent review of PR #147, finding
# torn-gate-unreadable-fail-open): an empty second read used to return
# "clean", so a transient `herdr pane read` failure on THIS call silently
# stood on the allow verdict computed by prompt_command_text's own read
# moments earlier — the exact fail-open this function exists to close, one
# read later. herdr-select.sh already refuses empty cmd_text for every
# non-human authority, so returning torn here costs no real liveness.
#
# SCOPED TO WHAT WAS ACTUALLY CLASSIFIED (independent review, finding
# torn-gate-scope-liveness): prompt_command_text's omp-menu branch classifies
# only the panel's own header/detail rows, never the whole 1000-line window —
# but the first cut of this function validated the WHOLE window regardless of
# shape, so a torn byte anywhere in old transcript scrollback escalated every
# peer approval on that pane while that unrelated row stayed on screen. Fixed
# by parsing the SAME rows prompt_command_text would, twice — once from the
# raw bytes (python's own `decode(..., "replace")` degrades a torn byte to
# U+FFFD rather than crashing, so this is safe) and once from the
# `_sanitize_utf8`-cleaned bytes — and comparing: identical output means
# nothing inside the classified rows was torn, even if the wider window was.
# A torn byte outside the panel changes neither reading. The NUMBERED shape
# (Claude/Codex) has no such row boundary — prompt_command_text classifies
# its whole window — so that branch keeps whole-window validation.
prompt_command_torn() {                 # <pane> -> 0 torn(-or-unreadable) / 1 proven clean
  local raw_menu clean_q raw_q raw_win
  raw_menu="$(_pane_read_raw "$1" --format ansi)"
  if [ -n "$raw_menu" ]; then
    clean_q="$(printf '%s' "$raw_menu" | _sanitize_utf8 | _prompt_menu_parse question 2>/dev/null)"
    if [ -n "$clean_q" ]; then
      raw_q="$(printf '%s' "$raw_menu" | _prompt_menu_parse question 2>/dev/null)"
      [ "$raw_q" = "$clean_q" ] && return 1 || return 0
    fi
    # No complete menu panel either way: prompt_command_text falls through
    # to the whole-window numbered/plain path below, so validate THAT.
  fi
  raw_win="$(_pane_read_raw "$1")"
  [ -n "$raw_win" ] || return 0
  printf '%s' "$raw_win" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && return 1
  return 0
}


prompt_command_text() {
  local menu win
  # `command`, not `question`: joins wrapped rows with a space instead of
  # `" ; "`, so a long argument that landed alone on its own wrapped row is
  # not read as its own fake statement. See the "command" mode comment in
  # _prompt_menu_parse above for the full failure this avoids.
  menu="$(prompt_menu_command "$1" 2>/dev/null)" || menu=""
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
