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
#   sort-tabs.sh --all --yes     # every workspace, for real (--all otherwise refuses)
#
# --mark only recolors a tab whose pane is actually running an agent (detected
# via lib/pane-guard.sh's process check, the same gate herdr-select.sh and
# herdr-deliver.sh use). A bare shell prompt is left untouched rather than
# asserted idle/done over — a shell was never doing anything, so "idle" is not
# an observation, it's a guess. --all reaches into EVERY workspace, not just
# the focused one, so it refuses to act (dry-run print of scope only) unless
# --yes or --dry-run is also given.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/pane-guard.sh"

ws_arg=""; do_all=0; do_mark=0; dry=0; confirmed=0
for a in "$@"; do
  case "$a" in
    --all) do_all=1 ;;
    --mark) do_mark=1 ;;
    --dry-run|-n) dry=1 ;;
    --yes|-y) confirmed=1 ;;
    w*) ws_arg="$a" ;;
    *) echo "sort-tabs: unknown arg '$a'" >&2; exit 1 ;;
  esac
done

if [ "$do_all" = 1 ] && [ "$dry" != 1 ] && [ "$confirmed" != 1 ]; then
  echo "sort-tabs: --all reaches into EVERY workspace, not just the focused one:" >&2
  herdr workspace list 2>/dev/null | jq -r '(.result.workspaces // .workspaces)[] | "  \(.workspace_id)  \(.label)"' >&2
  echo "sort-tabs: pass --yes to act for real, or --dry-run to preview without acting." >&2
  exit 1
fi

panes_json=$(herdr pane list 2>/dev/null) || { echo "sort-tabs: pane list failed" >&2; exit 1; }
tab_cwd() {  # tab_id -> a representative cwd (first pane's foreground cwd)
  printf '%s' "$panes_json" | jq -r --arg t "$1" \
    '[(.result.panes // .panes)[] | select(.tab_id==$t)][0] | (.foreground_cwd // .cwd // "")'
}

tab_pane_id() {  # tab_id -> its first pane's pane_id (same pane mark-tab.sh would resolve to)
  printf '%s' "$panes_json" | jq -r --arg t "$1" \
    '[(.result.panes // .panes)[] | select(.tab_id==$t)][0] | (.pane_id // "")'
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
  local ws="$1" tabs tabs_json herdr_rc jq_rc desired cur i tid params rank state cwd lines sortflag pane marked skipped
  # `herdr tab list | jq` used to collapse two very different outcomes into
  # the same "no tabs in $ws" message: a genuinely empty workspace, and a
  # dead/erroring RPC or a jq parse failure (both silently produce empty
  # $tabs when piped straight through). Under --all that hid systemic
  # failures — one workspace's socket error just looked like it had no tabs.
  # Capture herdr's own exit status before jq ever sees the output, so a
  # transport/parse failure is reported distinctly from a real empty result.
  tabs_json=$(herdr tab list --workspace "$ws" 2>/dev/null); herdr_rc=$?
  tabs=$(printf '%s' "$tabs_json" | jq -r '(.result.tabs // .tabs)[].tab_id' 2>/dev/null); jq_rc=$?
  if [ "$herdr_rc" != 0 ] || [ "$jq_rc" != 0 ]; then
    echo "sort-tabs: tab list RPC/parse failed for $ws (herdr rc=$herdr_rc, jq rc=$jq_rc)" >&2
    return 1
  fi
  [ -n "$tabs" ] || { echo "sort-tabs: no tabs in $ws"; return; }

  # Build "rank<TAB>tabid<TAB>state<TAB>cwd", preserving current order (stable).
  lines=""
  while IFS= read -r tid; do
    [ -n "$tid" ] || continue
    cwd=$(tab_cwd "$tid")
    # A cwd is a filesystem path, and tab/newline are legal filename bytes on
    # macOS/Linux — an embedded one would break the tab-delimited row framing
    # below, shifting fields so `cut -f2` on a later row hands a bogus string
    # (part of a path, not a tab_id) to the tab.move RPC. cwd is only used
    # here for display and rank_state's git lookup, never required verbatim,
    # so stripping the offending bytes is safe and closes the framing hole.
    cwd=$(printf '%s' "$cwd" | tr -d '\t\n')
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
      # tid is interpolated straight from a JSON string field returned by
      # `herdr tab list`, so a tab_id containing a quote or backslash would
      # break out of the hand-built "{...}" literal below and either corrupt
      # the RPC params or fail to parse as JSON. jq -n with --arg/--argjson
      # does the escaping properly instead of us reimplementing it by hand.
      params=$(jq -n --arg tab_id "$tid" --argjson insert_index "$i" \
        '{tab_id:$tab_id, insert_index:$insert_index}') \
        || { echo "sort-tabs: failed to build tab.move params for $tid" >&2; return 1; }
      python3 "$here/herdr-rpc.py" tab.move "$params" >/dev/null \
        || { echo "sort-tabs: tab.move failed for $tid" >&2; return 1; }
      i=$((i+1))
    done <<<"$desired"
    echo "  reordered $i tabs"
  fi

  # Optional recolor by state — but only for a tab whose pane is actually
  # running an agent. herdr's agent_status is a claim about a process; a bare
  # shell prompt has no process to make a claim about, so asserting "idle" or
  # "done" over it is fabrication, not observation.
  if [ "$do_mark" = 1 ] && [ "$dry" != 1 ]; then
    marked=0; skipped=0
    while IFS=$'\t' read -r rank tid state cwd; do
      [ -n "$tid" ] || continue
      pane=$(tab_pane_id "$tid")
      if [ -z "$pane" ] || ! pane_is_agent "$pane"; then
        skipped=$((skipped+1))
        continue
      fi
      case "$state" in
        waiting) bash "$here/mark-tab.sh" "$tid" waiting >/dev/null 2>&1 && marked=$((marked+1)) ;;
        active)  bash "$here/mark-tab.sh" "$tid" active  >/dev/null 2>&1 && marked=$((marked+1)) ;;
        committed|reviewed|merged) bash "$here/mark-tab.sh" "$tid" done >/dev/null 2>&1 && marked=$((marked+1)) ;;
      esac
    done < <(printf '%s' "$lines" | sed '/^$/d')
    echo "  recolored $marked tab(s) hosting an agent; left $skipped agentless tab(s) untouched"
  fi
}

if [ "$do_all" = 1 ]; then
  # Every other id-list loop in this file reads via `while ... < <(...)` to
  # avoid word-splitting/globbing on unquoted command substitution; this was
  # the one holdout still using `for x in $(...)`, unsafe for a workspace
  # label containing whitespace or shell glob characters.
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    sort_one "$ws"
  done < <(herdr workspace list 2>/dev/null | jq -r '(.result.workspaces // .workspaces)[].workspace_id')
else
  ws="$ws_arg"
  [ -n "$ws" ] || ws=$(herdr workspace list 2>/dev/null | jq -r '(.result.workspaces // .workspaces)[] | select(.focused==true) | .workspace_id' | head -1)
  [ -n "$ws" ] || { echo "sort-tabs: no focused workspace; pass a workspace id or --all" >&2; exit 1; }
  sort_one "$ws"
fi
