#!/usr/bin/env bash
# open-project.sh [--focus] [--dry-run] [--pick] [<name>]
#
# Open (create-or-reuse) a whole PROJECT workspace by NAME — every tab, every
# pane, every startup command — from a declarative template. Headless by
# default (say the name, get the workspace); --pick drops into an fzf
# browser when you don't remember it.
#
# Two tiers, shown together — same private/public split as quick-action.sh's
# global vs. repo-local, applied here to keep this repo's own tracked
# projects/*.json GENERIC (a pattern to copy) rather than a real person's
# real private repos:
#   personal (tagged "personal") — ${XDG_CONFIG_HOME:-~/.config}/herdr-control/projects/*.json.
#     YOUR real projects, real working_dir paths, real descriptions. Not
#     tracked by this repo's git — lives in your own config dir, same as
#     quick-action.sh's global tier. On a name collision, personal wins:
#     it's a more specific override of a shipped example, not a duplicate.
#   shipped (tagged "example") — projects/*.json in this repo. Generic
#     PATTERNS ("agent + a one-shot check on open", "agent + an ambient
#     git-status sentinel"), portable working_dir placeholders
#     (~/Code/your-project), meant to be copied into your personal tier and
#     edited, not used verbatim. See README's "Private vs. public" section.
#
# Idea, vocabulary, and the "headless open-by-name is handy for shell
# aliases, scripts, and AI agents" framing are credited to
# cloudmanic/herdr-plus's Projects feature — reimplemented natively here in
# bash+jq+fzf, no Go toolchain / external plugin install, so herdr-control
# stays one self-contained package. See README's Credits section and
# lib/project.sh's header for the one known behavioural gap (a fresh
# workspace's own auto-created root tab is left empty, not reused).
#
#   ./open-project.sh herdr-control              # headless, by name
#   ./open-project.sh --pick                      # fuzzy-pick (needs fzf)
#   ./open-project.sh --dry-run herdr-control     # preview, no calls made
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/layout.sh"
. "$here/lib/project.sh"

PERSONAL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-control/projects"
SHIPPED_DIR="$here/projects"

foc=--no-focus; dry=0; pick=0; positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --focus) foc=--focus; shift ;;
    --dry-run|-n) dry=1; shift ;;
    --pick) pick=1; shift ;;
    *) positional+=("$1"); shift ;;
  esac
done
set -- ${positional[@]+"${positional[@]}"}

list_projects() {  # -> "<name>\t<scope>\t<description>\t<file>" per line, personal first
  local f name desc
  for f in "$PERSONAL_DIR"/*.json; do
    [ -e "$f" ] || continue
    name=$(jq -r '.name // empty' "$f" 2>/dev/null)
    desc=$(jq -r '.description // ""' "$f" 2>/dev/null)
    [ -n "$name" ] && printf '%s\tpersonal\t%s\t%s\n' "$name" "$desc" "$f"
  done
  for f in "$SHIPPED_DIR"/*.json; do
    [ -e "$f" ] || continue
    name=$(jq -r '.name // empty' "$f" 2>/dev/null)
    desc=$(jq -r '.description // ""' "$f" 2>/dev/null)
    [ -n "$name" ] && printf '%s\texample\t%s\t%s\n' "$name" "$desc" "$f"
  done
}

# personal wins on a name collision — it's a deliberate override of a
# shipped example, not a duplicate, so grep the FIRST match only.
resolve_project() {  # <name> -> file path on stdout, empty + rc 1 if unknown
  local n="$1" file
  file=$(list_projects | awk -F'\t' -v want="$n" '$1==want{print $4; exit}')
  [ -n "$file" ] || return 1
  printf '%s' "$file"
}

name="${1:-}"
if [ "$pick" = 1 ]; then
  command -v fzf >/dev/null 2>&1 || { echo "open-project: --pick needs fzf on PATH" >&2; exit 1; }
  chosen=$(list_projects | fzf --prompt='project> ' --height=40% --reverse \
    --delimiter='\t' --with-nth=1,2,3) || exit 1
  name=$(cut -f1 <<<"$chosen")
fi
[ -n "$name" ] || { echo "usage: open-project.sh [--focus] [--dry-run] [--pick] <name>" >&2; exit 1; }

file=$(resolve_project "$name") || {
  echo "open-project: no such project: $name" >&2
  echo "available:" >&2
  list_projects | awk -F'\t' '{print "  " $1 " (" $2 ")"}' >&2
  exit 1
}
project_json=$(cat "$file") || { echo "open-project: cannot read $file" >&2; exit 1; }
project_validate "$project_json" || { echo "open-project: invalid project in $file" >&2; exit 1; }

if [ "$dry" = 1 ]; then
  echo "open-project (dry-run):"
  echo "  file       : $file"
  jq -r '"  name       : \(.name)\n  description: \(.description // "<none>")\n  working_dir: \(.working_dir)"' <<<"$project_json"
  jq -c '.tabs[]' <<<"$project_json" | while IFS= read -r tab; do
    echo "  tab: $(jq -r '.label' <<<"$tab")"
    jq -r '.panes | to_entries[] | "    [\(.key)] role=\(if .key==0 then "root" else (.value.split // "right") end) label=\(.value.label // "<none>") cmd=\(.value.cmd // "<shell>") focus=\(.value.focus // false)"' <<<"$tab"
  done
  exit 0
fi

project_open "$project_json" "$foc" || exit 1
printf 'opened  %-16s ws=%s  tabs=%d  [%s]\n' \
  "$name" "$PROJECT_WORKSPACE_ID" "$(jq '.tabs | length' <<<"$project_json")" \
  "$([ "$foc" = --focus ] && echo focused || echo background)"
