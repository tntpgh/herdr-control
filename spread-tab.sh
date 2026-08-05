#!/usr/bin/env bash
# spread-tab.sh [--focus] [--layout <name>] [--dry-run] <project-path> <tab-label>
#
# Open (or reuse) the project's workspace and lay out ONE new tab from a
# declarative pane layout — the multi-pane sibling of spawn-agent.sh, which
# only ever builds a single pane. Layout mechanics live in lib/layout.sh.
#
#   spread-tab.sh ~/Code/myproject dev                 # picks a layout below
#   spread-tab.sh --layout example-dev ~/Code/x work   # explicit layout
#   spread-tab.sh --dry-run ~/Code/myproject dev       # print the plan only
#
# Layout resolution (first match wins) — this is the "case by case" knob:
# nothing is forced project-wide, a project opts in by dropping one file.
#   1. --layout <name>            -> layouts/<name>.json
#   2. layouts/<project-dir-name>.json   (auto-picked by the repo's own name)
#   3. layouts/default.json              (single plain pane — today's status quo)
#
# Layout files are plain JSON (schema + field docs in lib/layout.sh's header)
# so this needs no new dependency beyond jq, which every other script here
# already requires.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/layout.sh"

foc=--no-focus; dry=0; layout_name=""; positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --focus) foc=--focus; shift ;;
    --dry-run|-n) dry=1; shift ;;
    --layout) layout_name="$2"; shift 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done
set -- ${positional[@]+"${positional[@]}"}
proj="${1:?usage: spread-tab.sh [--focus] [--layout <name>] [--dry-run] <project-path> <tab-label>}"
label="${2:?usage: spread-tab.sh [--focus] [--layout <name>] [--dry-run] <project-path> <tab-label>}"

root=$(cd "$proj" 2>/dev/null && pwd) || { echo "spread-tab: no such directory: $proj" >&2; exit 1; }

layout_file=""
if [ -n "$layout_name" ]; then
  layout_file="$here/layouts/$layout_name.json"
  [ -f "$layout_file" ] || { echo "spread-tab: no such layout: $layout_file" >&2; exit 1; }
elif [ -f "$here/layouts/$(basename "$root").json" ]; then
  layout_file="$here/layouts/$(basename "$root").json"
else
  layout_file="$here/layouts/default.json"
fi
layout_json=$(cat "$layout_file") || { echo "spread-tab: cannot read $layout_file" >&2; exit 1; }
layout_validate "$layout_json" || { echo "spread-tab: invalid layout in $layout_file" >&2; exit 1; }

if [ "$dry" = 1 ]; then
  echo "spread-tab (dry-run):"
  echo "  project : $root"
  echo "  label   : $label"
  echo "  layout  : $layout_file"
  jq -r 'to_entries[] | "    [\(.key)] role=\(if .key==0 then "root" else (.value.split // "right") end) cwd=\(.value.cwd // "<tab root>") label=\(.value.label // "<none>") cmd=\(.value.cmd // "<shell>") focus=\(.value.focus // false)"' <<<"$layout_json"
  exit 0
fi

ws=$(bash "$here/ensure-workspace.sh" --no-focus "$root") || exit 1
layout_apply "$ws" "$root" "$label" "$foc" "$layout_json" || exit 1

bgtag="background"; [ "$foc" = --focus ] && bgtag="focused"
printf 'spread %-14s ws=%s tab=%s panes=%d  [%s]  layout=%s\n' \
  "$label" "$ws" "$LAYOUT_TAB_ID" "${#LAYOUT_PANE_IDS[@]}" "$bgtag" "$(basename "$layout_file")"
