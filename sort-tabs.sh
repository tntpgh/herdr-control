#!/usr/bin/env bash
# sort-tabs.sh [--all | <workspace_id>] [--mark] [--dry-run]
#
# Reorder a workspace's tabs by the state of the branch each tab sits on, so the
# ones needing you float to the top and finished work sinks. State per tab comes
# from the tab's cwd (git + gh); herdr just moves tabs (via the socket tab.move
# method — no CLI verb) and, with --mark, recolors them.
#
# Rank (top -> bottom), attention-first:
#   1 waiting    open PR awaiting review / changes requested   (gh)
#   2 active     uncommitted changes in the tree
#   3 committed  clean, no approving PR
#   4 reviewed   PR approved, not yet merged                   (gh)
#   5 merged     PR merged                                     (gh)
#   6 other      not a git repo / detached
# Set HERDR_SORT_DONE_FIRST=1 to flip (finished on top). HERDR_SORT_NO_GH=1
# skips gh (git-only: you lose the reviewed/merged/waiting distinction).
#
#   sort-tabs.sh                 # the focused workspace
#   sort-tabs.sh w2 --mark       # w2, and recolor tabs by state
#   sort-tabs.sh --all --dry-run # show the plan for every workspace, move nothing
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"

ws_arg=""; do_all=0; do_mark=0; dry=0
for a in "$@"; do
  case "$a" in
    --all) do_all=1 ;;
    --mark) do_mark=1 ;;
    --dry-run|-n) dry=1 ;;
    w*) ws_arg="$a" ;;
    *) echo "sort-tabs: unknown arg '$a'" >&2; exit 1 ;;
  esac
done

panes_json=$(herdr pane list 2>/dev/null) || { echo "sort-tabs: pane list failed" >&2; exit 1; }
tab_cwd() {  # tab_id -> a representative cwd (first pane's foreground cwd)
  printf '%s' "$panes_json" | jq -r --arg t "$1" \
    '[(.result.panes // .panes)[] | select(.tab_id==$t)][0] | (.foreground_cwd // .cwd // "")'
}

rank_state() {  # cwd -> "<rank> <state>"
  local cwd="$1" root branch dirty pr st rd
  [ -n "$cwd" ] || { echo "6 other"; return; }
  root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || { echo "6 other"; return; }
  branch=$(git -C "$root" branch --show-current 2>/dev/null)
  dirty=$(git -C "$root" status --porcelain 2>/dev/null | head -c1)
  if [ "${HERDR_SORT_NO_GH:-0}" != 1 ] && command -v gh >/dev/null 2>&1 && [ -n "$branch" ]; then
    pr=$( (cd "$root" && GH_PROMPT_DISABLED=1 gh pr view --json state,reviewDecision 2>/dev/null) || true )
    if [ -n "$pr" ]; then
      st=$(printf '%s' "$pr" | jq -r '.state // empty')
      rd=$(printf '%s' "$pr" | jq -r '.reviewDecision // empty')
      [ "$st" = MERGED ] && { echo "5 merged"; return; }
      case "$rd" in
        APPROVED) echo "4 reviewed"; return ;;
        CHANGES_REQUESTED|REVIEW_REQUIRED) echo "1 waiting"; return ;;
      esac
    fi
  fi
  [ -n "$dirty" ] && { echo "2 active"; return; }
  echo "3 committed"
}

sort_one() {  # workspace_id
  local ws="$1" tabs desired cur i tid rank state cwd lines sortflag
  tabs=$(herdr tab list --workspace "$ws" 2>/dev/null | jq -r '(.result.tabs // .tabs)[].tab_id')
  [ -n "$tabs" ] || { echo "sort-tabs: no tabs in $ws"; return; }

  # Build "rank<TAB>tabid<TAB>state<TAB>cwd", preserving current order (stable).
  lines=""
  while IFS= read -r tid; do
    [ -n "$tid" ] || continue
    cwd=$(tab_cwd "$tid")
    read -r rank state <<<"$(rank_state "$cwd")"
    lines+=$(printf '%s\t%s\t%s\t%s\n' "$rank" "$tid" "$state" "$cwd")
    lines+=$'\n'
  done <<<"$tabs"

  sortflag="-k1,1n"; [ "${HERDR_SORT_DONE_FIRST:-0}" = 1 ] && sortflag="-k1,1nr"
  desired=$(printf '%s' "$lines" | sed '/^$/d' | sort -s -t$'\t' $sortflag | cut -f2)
  cur=$(printf '%s' "$tabs")

  echo "workspace $ws — plan (top first):"
  printf '%s' "$lines" | sed '/^$/d' | sort -s -t$'\t' $sortflag \
    | awk -F'\t' '{printf "  %-9s %s  %s\n", $3, $2, $4}'

  if [ "$cur" = "$desired" ]; then
    echo "  (already in order)"
  elif [ "$dry" = 1 ]; then
    echo "  [dry-run] would reorder"
  else
    i=0
    while IFS= read -r tid; do
      [ -n "$tid" ] || continue
      python3 "$here/herdr-rpc.py" tab.move "{\"tab_id\":\"$tid\",\"insert_index\":$i}" >/dev/null \
        || { echo "sort-tabs: tab.move failed for $tid" >&2; return 1; }
      i=$((i+1))
    done <<<"$desired"
    echo "  reordered $i tabs"
  fi

  # Optional recolor by state.
  if [ "$do_mark" = 1 ] && [ "$dry" != 1 ]; then
    printf '%s' "$lines" | sed '/^$/d' | while IFS=$'\t' read -r rank tid state cwd; do
      case "$state" in
        waiting) bash "$here/mark-tab.sh" "$tid" waiting >/dev/null 2>&1 ;;
        active)  bash "$here/mark-tab.sh" "$tid" active  >/dev/null 2>&1 ;;
        committed|reviewed|merged) bash "$here/mark-tab.sh" "$tid" done >/dev/null 2>&1 ;;
      esac
    done
    echo "  recolored by state"
  fi
}

if [ "$do_all" = 1 ]; then
  for ws in $(herdr workspace list 2>/dev/null | jq -r '(.result.workspaces // .workspaces)[].workspace_id'); do
    sort_one "$ws"
  done
else
  ws="$ws_arg"
  [ -n "$ws" ] || ws=$(herdr workspace list 2>/dev/null | jq -r '(.result.workspaces // .workspaces)[] | select(.focused==true) | .workspace_id' | head -1)
  [ -n "$ws" ] || { echo "sort-tabs: no focused workspace; pass a workspace id or --all" >&2; exit 1; }
  sort_one "$ws"
fi
