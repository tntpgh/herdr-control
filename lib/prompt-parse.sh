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
_MENU_HEADER='Allow tool:'
_MENU_FOOTER='enter select'

_menu_window() {
  herdr pane read "$1" --source visible --lines 60 --format ansi 2>/dev/null
}

# Strip styling and the box, not just whitespace: current omp wraps both
# command details and choices in a bordered panel.
_menu_strip() {
  printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g' \
    | sed -E 's/^[^[:alnum:]]+//; s/[[:space:]│─╮]+$//'
}

# Parse the complete, known two-choice approval menu from ONE snapshot.
# Blank rows separate command details too; they are not an option boundary.
# Unknown/truncated menu shapes fail closed rather than turning detail text
# into option 1 and arrow-walking forever toward a row that cannot be selected.
_prompt_menu() {                       # <pane> visible|options|selected|question
  local win line stripped state=0 question="" selected="" n=0 invalid=0 complete=0 visible=0
  win=$(_menu_window "$1") || return 1
  while IFS= read -r line; do
    stripped=$(_menu_strip "$line")
    case "$stripped" in
      "$_MENU_HEADER"*)
        state=1; question="$stripped"; selected=""; n=0; invalid=0; complete=0; visible=0
        continue ;;
    esac
    if [ "$state" = 0 ]; then
      # A dismissed menu still in the viewport is not an active prompt.
      [ -z "$stripped" ] || { complete=0; visible=0; }
      continue
    fi
    case "$stripped" in
      "up/down navigate"*"$_MENU_FOOTER"*)
        visible=1
        [ "$state" = 3 ] && [ "$invalid" = 0 ] && complete=1
        state=0; continue ;;
      "") continue ;;
    esac
    case "$state:$stripped" in
      1:Approve) state=2; n=1 ;;
      2:Deny) state=3; n=2 ;;
      1:*) question="$question ; $stripped"; continue ;;
      *) invalid=1; continue ;;
    esac
    if printf '%s' "$line" | grep -qE $'\x1b\\[48;2;[0-9]+;[0-9]+;[0-9]+m'; then
      [ -z "$selected" ] || invalid=1
      selected="$n"
    fi
  done <<EOF
$win
EOF
  # Unknown choices require attention even though automated selection refuses.
  [ "$2" = visible ] && { [ "$visible" = 1 ]; return; }
  [ "$complete" = 1 ] && [ "$invalid" = 0 ] || return 1
  case "$2" in
    options) printf '1\tApprove\n2\tDeny\n' ;;
    selected) printf '%s' "$selected" ;;
    question) printf '%s' "$question" ;;
  esac
}

prompt_menu_options()  { _prompt_menu "$1" options; }
prompt_menu_selected() { _prompt_menu "$1" selected; }
prompt_menu_question() { _prompt_menu "$1" question; }
prompt_menu_visible()  { _prompt_menu "$1" visible; }

# A stable fingerprint for "this exact prompt, right now" — the question plus
# its options, hashed. Lets a wake event and a later answer agree on WHICH
# prompt they mean: between a conductor deciding "press 2" and actually
# pressing it, the prompt can vanish, the options can change, or the pane can
# now belong to a different task entirely (time-of-check/time-of-use). A
# caller that captured a prompt_id at decision time can pass it back at
# injection time and refuse to act if it no longer matches, rather than
# firing a stale decision into whatever the pane happens to show by then.
#
# Falls back to the menu-shape extractors above when no numbered options are
# found, so --expect-prompt-id (herdr-select.sh) works the same way
# regardless of which prompt shape is on screen — a caller never needs to
# know or care which one it captured.
prompt_id() {
  local q opts
  q="$(prompt_question "$1")"
  opts="$(prompt_options "$1")"
  if [ -z "$opts" ]; then
    q="$(prompt_menu_question "$1")"
    opts="$(prompt_menu_options "$1")"
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
# Deliberately NOT named prompt_command, and deliberately not a precise parse of
# "the command". Pulling an exact command string out of a TUI screenshot is
# guesswork that fails in the dangerous direction: a near-miss extraction hands
# the classifier the WRONG text, and a classifier fed the wrong text returns a
# confident verdict about something nobody is being asked to approve.
#
# So this returns the whole visible prompt region — the menu header/details
# (where omp puts the tool and its arguments) plus the screen text (where Claude
# renders the command). The classifier then looks for dangerous SHAPES anywhere
# in that text. The failure mode of that design is escalating a prompt whose
# prose merely mentions something like `rm -rf`, which costs one human glance;
# the failure mode of the precise-parse design is silently auto-approving a
# destructive command because the extractor clipped it.
#
# It does its OWN read rather than reusing prompt_context, and that is a
# correctness fix, not a style choice. prompt_context is built for a Slack alert:
# it ends in `tail -n 8 | cut -c1-200`, which is right for something a human
# skims and WRONG for security classification — a command longer than 200
# characters, or sitting more than eight non-empty lines above the bottom of the
# pane, was trimmed away before the classifier ever saw it, and a classifier
# handed the leftovers returns `allow`. That is a fail-open. Here nothing is
# truncated: only ANSI escapes and box-drawing furniture are stripped.
#
# Residual limit, stated rather than papered over: this can only classify what is
# VISIBLE. A command that has scrolled out of the pane cannot be judged, which is
# part of why peer authority is opt-in and a human remains the default.
prompt_command_text() {
  local menu win
  menu="$(prompt_menu_question "$1" 2>/dev/null)" || menu=""
  win="$(herdr pane read "$1" --source visible --lines 60 2>/dev/null)" || win=""
  printf '%s\n%s\n' "$menu" "$(
    printf '%s\n' "$win" \
      | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' \
      | sed $'s/\xc2\xa0/ /g' \
      | grep -vE '^[[:space:]]*[─═│┌┐└┘├┤┬┴┼╭╮╰╯]+[[:space:]]*$' \
      | sed -E 's/[[:space:]]+$//'
  )"
}
