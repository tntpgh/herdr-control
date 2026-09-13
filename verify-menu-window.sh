#!/usr/bin/env bash
# verify-menu-window.sh — a tall approval panel must still be answerable.
#
# OBSERVED 2026-09-12, pane wH:p6: a worker ran a bash command long enough that
# its approval panel spanned 61 rows. `_menu_window` read a fixed 60, the
# "Allow tool:" header fell outside it, the parser failed closed, and the worker
# sat `blocked` with no option anyone could select — peer authority, the Slack
# reply path and a human all equally stuck. It had even become a rule in our
# task briefs ("keep every bash command short enough that an approval panel
# renders it whole"), which is a parser bug wearing a process rule.
#
# The existing suites could not catch this: their herdr stub `cat`s a fixture
# regardless of --lines, so truncation is invisible to them. This stub HONOURS
# --lines, which is the whole point.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PANE="wT:p1"
HL=$'\033[48;2;60;60;60m'      # the SGR background the highlighted row carries
RESET=$'\033[0m'

# Build a panel with `n` rows of command detail between header and options.
make_panel() {                          # <detail-rows> -> writes $TMP/screen
  { printf '%s\n' "some earlier scrollback line"
    printf '╭─ Allow tool: bash ──────────────────────────────╮\n'
    printf '│                                                 │\n'
    for i in $(seq 1 "$1"); do printf '│ echo "detail row %s"                            │\n' "$i"; done
    printf '│                                                 │\n'
    printf '│ %sApprove%s                                        │\n' "$HL" "$RESET"
    printf '│   Deny                                          │\n'
    printf '│                                                 │\n'
    printf '│ up/down navigate  enter select  esc cancel      │\n'
    printf '╰─────────────────────────────────────────────────╯\n'
  } > "$TMP/screen"
}

VIEWPORT=62
herdr() {
  case "$1 $2" in
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","scroll":{"viewport_rows":%s}}]}}\n' "$PANE" "$VIEWPORT" ;;
    "pane read")
      # Honour --lines the way the real herdr does: the LAST n rows of the
      # visible screen. This is the behaviour the old fixed window tripped on.
      local n=60 prev=""
      for a in "$@"; do [ "$prev" = "--lines" ] && n="$a"; prev="$a"; done
      tail -n "$n" "$TMP/screen" ;;
    *) return 0 ;;
  esac
}
export -f herdr 2>/dev/null || true

. lib/prompt-parse.sh

echo "== a panel that fits is answerable (regression floor)"
make_panel 5
opts="$(prompt_menu_options "$PANE" 2>/dev/null)"
[ "$(printf '%s' "$opts" | wc -l | tr -d ' ')" = "1" ] && [ "${opts%%$'\n'*}" = "1	Approve" ] \
  && ok "short panel parses" || no "short panel parses" "got: $(printf '%s' "$opts" | tr '\n' '|')"
is_sel="$(prompt_menu_selected "$PANE" 2>/dev/null)"
[ "$is_sel" = "1" ] && ok "short panel highlight found" || no "short panel highlight found" "got '$is_sel'"

echo "== a panel taller than the old fixed window, but still ON SCREEN"
# The real shape from wH:p6: 52 detail rows -> a 61-row panel inside a 62-row
# viewport. Entirely visible to a human, entirely invisible to a 60-row window.
make_panel 52
opts="$(prompt_menu_options "$PANE" 2>/dev/null)"
[ -n "$opts" ] && ok "tall panel parses (was: unanswerable forever)" \
  || no "tall panel parses" "parser returned nothing — header outside the window"
is_sel="$(prompt_menu_selected "$PANE" 2>/dev/null)"
[ "$is_sel" = "1" ] && ok "tall panel highlight found" || no "tall panel highlight found" "got '$is_sel'"

echo "== the window follows the pane's own viewport, not a constant"
VIEWPORT=200
make_panel 150  # viewport 200 contains it
[ -n "$(prompt_menu_options "$PANE" 2>/dev/null)" ] \
  && ok "very tall pane reports very tall window" || no "very tall pane" "parser returned nothing"

echo "== a panel taller than the VIEWPORT is legitimately unparseable"
# Not a bug to fix: those rows are not on screen at all, so refusing is right.
# Recorded so a future reader does not mistake it for the truncation defect.
VIEWPORT=20
make_panel 70
[ -z "$(prompt_menu_options "$PANE" 2>/dev/null)" ] \
  && ok "panel exceeding the viewport still fails closed" || no "panel exceeding viewport" "parsed something it could not see"
VIEWPORT=62

echo "== a pane record without viewport_rows falls back, never truncates to 60"
herdr() {
  case "$1 $2" in
    "pane list") printf '{"result":{"panes":[{"pane_id":"%s"}]}}\n' "$PANE" ;;
    "pane read")
      local n=60 prev=""
      for a in "$@"; do [ "$prev" = "--lines" ] && n="$a"; prev="$a"; done
      tail -n "$n" "$TMP/screen" ;;
    *) return 0 ;;
  esac
}
make_panel 70
[ -n "$(prompt_menu_options "$PANE" 2>/dev/null)" ] \
  && ok "missing viewport_rows falls back generously" || no "missing viewport_rows" "truncated anyway"

echo "== a garbage viewport_rows does not shrink the window"
herdr() {
  case "$1 $2" in
    "pane list") printf '{"result":{"panes":[{"pane_id":"%s","scroll":{"viewport_rows":"nonsense"}}]}}\n' "$PANE" ;;
    "pane read")
      local n=60 prev=""
      for a in "$@"; do [ "$prev" = "--lines" ] && n="$a"; prev="$a"; done
      tail -n "$n" "$TMP/screen" ;;
    *) return 0 ;;
  esac
}
[ -n "$(prompt_menu_options "$PANE" 2>/dev/null)" ] \
  && ok "non-numeric viewport_rows falls back" || no "non-numeric viewport_rows" "truncated anyway"

echo "== fail-closed behaviour is PRESERVED for a genuinely broken panel"
# The point of the old window was never truncation; it was refusing to turn
# detail text into option 1. That must still hold.
{ printf '╭─ Allow tool: bash ──────────────────────────────╮\n'
  printf '│ echo hi                                         │\n'
  printf '│ %sApprove%s                                        │\n' "$HL" "$RESET"
  printf '│   Maybe                                         │\n'
  printf '│ up/down navigate  enter select  esc cancel      │\n'
} > "$TMP/screen"
[ -z "$(prompt_menu_options "$PANE" 2>/dev/null)" ] \
  && ok "unknown option shape still refuses" || no "unknown option shape still refuses" "parsed something"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
