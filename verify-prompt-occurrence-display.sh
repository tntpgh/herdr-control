#!/usr/bin/env bash
# verify-prompt-occurrence-display.sh — hermetic regression for
# lib/prompt-parse.sh's prompt_occurrence_display (docs/plans/
# dot-herdr-recovery-slices.md §2). Same stub-herdr seam as
# verify-attention-tick.sh / verify-omp-hooks.sh: no live herdr, no network.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/prompt-parse.sh
. "$here/lib/prompt-parse.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

PANE="w1:p1"
SCREEN=""
READ_RC=0

herdr() {
  case "$1 $2" in
    "pane read")
      if [ "$READ_RC" -ne 0 ]; then
        return "$READ_RC"
      fi
      printf '%s' "$SCREEN"
      ;;
    *) return 0 ;;
  esac
}
export -f herdr

# -- read_failed: the transport itself failed (pane gone, herdr down) -------
READ_RC=7
SCREEN=""
out="$(prompt_occurrence_display "$PANE")"
[ "$out" = "read_failed" ] && ok "transport failure reads read_failed" \
  || bad "transport failure: got '$out', want read_failed"
READ_RC=0

# -- no_prompt: a read succeeds, ordinary agent output, nothing prompt-like -
SCREEN=$'$ git status\nOn branch main\nnothing to commit, working tree clean\n$ \n'
out="$(prompt_occurrence_display "$PANE")"
[ "$out" = "no_prompt" ] && ok "idle/running pane reads no_prompt, not pending_unreadable" \
  || bad "idle pane: got '$out', want no_prompt"

# -- pending_unreadable: menu-gate words present, panel not fully parseable -
# (M5/L2 follow-up, Main review): the footer words match but there is no
# Approve/Deny row pair for the strict parser to resolve — a genuinely stuck
# panel, which must stay distinct from "nothing is there at all".
SCREEN=$' Allow tool: bash\n   run: some long command\n\n up/down navigate  enter select  esc cancel\n'
out="$(prompt_occurrence_display "$PANE")"
[ "$out" = "pending_unreadable" ] && ok "gate-matched but unparseable panel reads pending_unreadable" \
  || bad "unparseable panel: got '$out', want pending_unreadable"

# -- pending_parseable: a complete omp approval menu ------------------------
SCREEN=$' Allow tool: bash\n   run: git status\n\n\033[48;2;40;40;40m  Approve\033[0m\n   Deny\n\n up/down navigate  enter select  esc cancel\n'
out="$(prompt_occurrence_display "$PANE")"
[ "$out" = "pending_parseable" ] && ok "complete approval menu reads pending_parseable" \
  || bad "complete menu: got '$out', want pending_parseable"

# -- pending_parseable: the numbered-shape fallback (no menu gate) ----------
SCREEN=$'Conductor says:\n1. do this\n2. do that\n'
out="$(prompt_occurrence_display "$PANE")"
[ "$out" = "pending_parseable" ] && ok "numbered-list shape reads pending_parseable" \
  || bad "numbered shape: got '$out', want pending_parseable"

printf -- '-----\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
