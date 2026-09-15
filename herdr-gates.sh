#!/usr/bin/env bash
# herdr-gates.sh — one-shot view of what EVERY watched pane is waiting on.
#
# The gap this closes: answering a fan-out of lanes meant one `herdr pane read`
# per pane per sweep, and a conductor shepherding 4-5 workers repeats that
# sweep continuously. On 2026-09-13 a single batch of four knowledge-base lanes
# cost 39 re-arms of wait-for-blocked.sh plus a per-pane read loop after each
# one, purely to answer "who is stuck and on what". That is the whole job of
# this script, in one call.
#
#   herdr-gates.sh [pane_id ...]     # omit ids to show every agent pane
#   herdr-gates.sh --blocked         # only panes actually waiting on input
#   herdr-gates.sh --full            # whole command text, not the first 2 rows
#
# Columns: pane, status (herdr's own agent_status), gate (what the PARSER sees,
# which is the load-bearing one), selected row, prompt_id prefix, and the
# command being asked about.
#
# Why both status and gate: herdr's agent_status is unreliable in BOTH
# directions — it reports `working` while an approval menu is painted, and
# `done` while output is still streaming. The `gate` column comes from
# prompt_menu_visible/prompt_menu_options, i.e. the same parse herdr-select.sh
# will use to press a key, so if gate says `menu` the pane is genuinely
# answerable and if it says `-` there is nothing to press. Trust gate.
#
# prompt_id is printed so a conductor can pass the SAME id to
# `herdr-select.sh --expect-prompt-id` and have the keypress refuse if the
# prompt changed between reading and answering.
set -uo pipefail

only_blocked=0
full=0
panes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --blocked) only_blocked=1; shift ;;
    --full)    full=1; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    -*) echo "herdr-gates: unknown option $1" >&2; exit 2 ;;
    *)  panes+=("$1"); shift ;;
  esac
done

command -v herdr >/dev/null 2>&1 || { echo "herdr-gates: herdr not on PATH" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"

want=""
[ ${#panes[@]} -gt 0 ] && want="${panes[*]}"

# One `herdr pane list` for the whole run; per-pane reads happen only for panes
# that survive the filter.
roster="$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
want = set(sys.argv[1].split()) if len(sys.argv) > 1 and sys.argv[1].strip() else None
try:
    data = json.load(sys.stdin)
    panes = (data.get("result") or data).get("panes") or []
except Exception:
    sys.exit(1)
for p in panes:
    pid = p.get("pane_id") or ""
    if want is not None and pid not in want:
        continue
    if want is None and not (p.get("agent") or p.get("agent_status")):
        continue
    print("\t".join(str(p.get(k) or "-") for k in ("pane_id", "agent_status", "label")))
' "$want" 2>/dev/null)"

[ -n "$roster" ] || { echo "herdr-gates: no matching agent panes"; exit 0; }

printf '%-8s %-9s %-6s %-4s %-10s %s\n' PANE STATUS GATE SEL PROMPT_ID LABEL
while IFS=$'\t' read -r pane status label; do
  [ -n "$pane" ] || continue
  gate="-" ; sel="-" ; pid="-" ; cmd=""
  if pane_is_agent "$pane"; then
    if prompt_menu_visible "$pane" 2>/dev/null; then
      if [ -n "$(prompt_menu_options "$pane" 2>/dev/null)" ]; then
        gate="menu"
        sel="$(prompt_menu_selected "$pane" 2>/dev/null)"; sel="${sel:--}"
        pid="$(prompt_id "$pane" 2>/dev/null | cut -c1-8)"
        cmd="$(prompt_menu_question "$pane" 2>/dev/null)"
      else
        # A menu is on screen but not parseable: never answerable by keypress.
        # Say so loudly rather than printing a dash that reads as "idle".
        gate="UNPARSED"
      fi
    elif [ -n "$(prompt_options "$pane" 2>/dev/null)" ]; then
      gate="numbered"
      pid="$(prompt_id "$pane" 2>/dev/null | cut -c1-8)"
      cmd="$(prompt_question "$pane" 2>/dev/null)"
    fi
  fi
  [ "$only_blocked" = 1 ] && [ "$gate" = "-" ] && continue
  printf '%-8s %-9s %-6s %-4s %-10s %s\n' \
    "$pane" "$status" "$gate" "$sel" "$pid" "${label}"
  if [ -n "$cmd" ]; then
    if [ "$full" = 1 ]; then
      printf '%s\n' "$cmd" | tr ';' '\n' | sed -E 's/^ +//; s/^/    | /'
    else
      printf '%s\n' "$cmd" | tr ';' '\n' | sed -E 's/^ +//' \
        | grep -vE '^\[header off-screen\]$' | head -2 | sed 's/^/    | /'
    fi
  fi
done <<EOF
$roster
EOF
