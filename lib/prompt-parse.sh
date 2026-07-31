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
  herdr pane read "$1" --source visible --lines 40 --format ansi 2>/dev/null | tail -n 20
}

# Strip ANSI escapes, then any leading non-alphanumeric run — the highlighted
# row's leading icon glyph survives ANSI-stripping (it's a real character,
# not an escape sequence) — then surrounding whitespace.
_menu_strip() {
  printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g' | sed -E 's/^[^[:alnum:]]+//; s/[[:space:]]+$//'
}

prompt_menu_options() {
  local win n=0 state=0 line stripped
  win=$(_menu_window "$1") || return 1
  while IFS= read -r line; do
    case "$state" in
      0) printf '%s' "$line" | grep -qF "$_MENU_HEADER" && state=1; continue ;;
      1)
        stripped=$(_menu_strip "$line")
        [ -z "$stripped" ] && state=2
        continue ;;
      2)
        printf '%s' "$line" | grep -qF "$_MENU_FOOTER" && { state=3; continue; }
        stripped=$(_menu_strip "$line")
        [ -n "$stripped" ] || continue
        n=$((n+1))
        printf '%d\t%s\n' "$n" "$stripped" ;;
    esac
  done <<EOF
$win
EOF
}

prompt_menu_selected() {
  local win n=0 state=0 found="" line stripped
  win=$(_menu_window "$1") || return 1
  while IFS= read -r line; do
    case "$state" in
      0) printf '%s' "$line" | grep -qF "$_MENU_HEADER" && state=1; continue ;;
      1)
        stripped=$(_menu_strip "$line")
        [ -z "$stripped" ] && state=2
        continue ;;
      2)
        printf '%s' "$line" | grep -qF "$_MENU_FOOTER" && { state=3; continue; }
        stripped=$(_menu_strip "$line")
        [ -n "$stripped" ] || continue
        n=$((n+1))
        printf '%s' "$line" | grep -qE $'\x1b\\[48;2;[0-9]+;[0-9]+;[0-9]+m' && found="$n" ;;
    esac
  done <<EOF
$win
EOF
  printf '%s' "$found"
}

prompt_menu_question() {
  local win state=0 line stripped out=""
  win=$(_menu_window "$1") || return 1
  while IFS= read -r line; do
    if [ "$state" = 0 ]; then
      printf '%s' "$line" | grep -qF "$_MENU_HEADER" && state=1
    fi
    if [ "$state" = 1 ]; then
      stripped=$(_menu_strip "$line")
      [ -z "$stripped" ] && break
      out="${out:+$out ; }$stripped"
    fi
  done <<EOF
$win
EOF
  printf '%s' "$out"
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
