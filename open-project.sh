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
# $0 resolved through SYMLINKS — README documents `ln -s "$PWD"/*.sh
# ~/.local/bin/`, and through that link a plain `dirname "$0"` finds neither
# config.sh nor lib/trust.sh, so the trust gate would be undefined rather
# than refusing.
_self="$0"
while [ -L "$_self" ]; do
  _link=$(readlink "$_self")
  case "$_link" in
    /*) _self="$_link" ;;
    *)  _self="$(dirname "$_self")/$_link" ;;
  esac
done
here=$(cd "$(dirname "$_self")" && pwd)
source "$here/config.sh"
. "$here/lib/layout.sh"
. "$here/lib/project.sh"

. "$here/lib/trust.sh"

PERSONAL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-control/projects"
SHIPPED_DIR="$here/projects"

# THIRD TIER: the repo's OWN space, committed beside the code it describes.
#
# `<repo-root>/.herdr-control/project.json`, found from the current directory
# the way every other repo-aware tool here finds its root. This is what makes
# per-repo start rules writable once: a fresh clone carries its own tabs,
# panes and startup commands, instead of a personal-tier file that has to be
# hand-copied per repo per machine.
#
# Same discovery shape as quick-action.sh's global vs repo-local, and the same
# trust gate for the same reason — a space carries pane startup COMMANDS, so it
# is shell that arrived with a `git pull` from a branch anyone could have
# pushed. Approval is keyed by content hash, so editing an approved file
# revokes it (lib/trust.sh).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
REPO_FILE=""
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.herdr-control/project.json" ]; then
  REPO_FILE="$REPO_ROOT/.herdr-control/project.json"
  # Run from the REPO ROOT, not from wherever you happened to stand. The
  # tier is discovered from the root but `project_open` resolves
  # `working_dir` against the cwd, so `"working_dir": "."` in an approved
  # space meant something different in every subdirectory — and what "."
  # resolved to was never covered by the content hash. Invoked from `sub/deep`
  # this repo's own space ran `./restart.sh --verify` in `sub/deep`, which
  # either fails or runs a same-named script the approval never saw.
  cd "$REPO_ROOT" || exit 1
fi

foc=--no-focus; dry=0; pick=0; trust=0; positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --focus) foc=--focus; shift ;;
    --dry-run|-n) dry=1; shift ;;
    --pick) pick=1; shift ;;
    --trust) trust=1; shift ;;
    *) positional+=("$1"); shift ;;
  esac
done
set -- ${positional[@]+"${positional[@]}"}

if [ "$trust" = 1 ]; then
  [ -n "$REPO_FILE" ] || {
    echo "open-project: no repo-local space here (expected .herdr-control/project.json)" >&2; exit 1; }
  echo "open-project: this space runs these commands:" >&2
  jq -r '.tabs[]? | .panes | to_entries[]? | "  \(.value.cmd // "<shell>")"' "$REPO_FILE" >&2
  # An explicit YES, exactly as quick-action.sh --trust does. Printing the
  # commands and approving in the same breath gives the operator no point at
  # which to decline, which makes the banner a lie.
  printf 'open-project: type YES to approve %s: ' "$REPO_FILE" >&2
  read -r _ans
  [ "$_ans" = YES ] || { echo "open-project: not approved" >&2; exit 1; }
  trust_file "$REPO_FILE" || exit 1
  echo "approved at its current content: $REPO_FILE" >&2
  exit 0
fi

# Fields are TAB-separated, so any field that can contain a TAB or a NEWLINE
# can forge rows in this table. For the repo tier `name` and `description`
# arrive with a `git pull`, and `project_validate` only type-checks them — a
# description carrying "\t...\n" injected a row whose FILE field was any path
# the attacker chose, and because the trust gate compared the resolved path
# against $REPO_FILE, a forged path skipped the gate entirely and its commands
# ran with zero arguments and an empty trust DB (found in review of this PR).
#
# Two independent fixes, both kept: untrusted text is scrubbed of the
# separators here, AND the tier tag travels as its own field so the gate keys
# on the TIER rather than on string equality of a parsed path.
_scrub() { printf '%s' "$1" | tr -d '\t\n\r'; }

list_projects() {  # -> "<name>\t<scope>\t<description>\t<file>" per line, most specific first
  local f name desc
  # The repo you are STANDING IN is the most specific answer there is, so it
  # is listed first and wins a name collision.
  if [ -n "$REPO_FILE" ]; then
    name=$(_scrub "$(jq -r '.name // empty' "$REPO_FILE" 2>/dev/null)")
    desc=$(_scrub "$(jq -r '.description // ""' "$REPO_FILE" 2>/dev/null)")
    if [ -n "$name" ]; then
      if is_trusted "$REPO_FILE"; then
        printf '%s\trepo\t%s\t%s\n' "$name" "$desc" "$REPO_FILE"
      else
        printf '%s\trepo, UNTRUSTED\t%s\t%s\n' "$name" "$desc" "$REPO_FILE"
      fi
    fi
  fi
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

# The repo tier wins, then personal, then shipped: most specific first. Both
# overrides are deliberate, not duplicates, so take the FIRST match only.
#
# Returns "<tier>\t<file>". The TIER travels with the path because the trust
# gate keys on it: identifying the repo tier by comparing the resolved path
# against $REPO_FILE let a forged row (see _scrub above) present a path that
# was not equal to it and therefore skipped the gate.
resolve_project() {  # <name> -> "<tier>\t<file>" on stdout, empty + rc 1 if unknown
  local n="$1" row
  row=$(list_projects | awk -F'\t' -v want="$n" '$1==want{print $2 "\t" $4; exit}')
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

name="${1:-}"
if [ "$pick" = 1 ]; then
  command -v fzf >/dev/null 2>&1 || { echo "open-project: --pick needs fzf on PATH" >&2; exit 1; }
  chosen=$(list_projects | fzf --prompt='project> ' --height=40% --reverse \
    --delimiter='\t' --with-nth=1,2,3) || exit 1
  name=$(cut -f1 <<<"$chosen")
fi
# NO NAME NEEDED when you are standing in a repo that ships a space. That is
# the whole point of the tier: `cd ~/Code/knowledge-base && open-project.sh`
# opens that repo's space, and you never type its name. A name is still
# accepted, and is the only way to open a space for somewhere you are not.
if [ -z "$name" ] && [ -n "$REPO_FILE" ]; then
  name=$(jq -r '.name // empty' "$REPO_FILE" 2>/dev/null)
  [ -n "$name" ] && echo "open-project: using this repo's space ($name)" >&2
fi
[ -n "$name" ] || {
  echo "usage: open-project.sh [--focus] [--dry-run] [--pick] [--trust] [<name>]" >&2
  echo "  with no <name>, opens <repo-root>/.herdr-control/project.json if there is one" >&2
  exit 1; }

row=$(resolve_project "$name") || {
  echo "open-project: no such project: $name" >&2
  echo "available:" >&2
  list_projects | awk -F'\t' '{print "  " $1 " (" $2 ")"}' >&2
  exit 1
}
tier=${row%%	*}
file=${row#*	}

# A repo-local space runs pane commands that came from the repo, so it needs
# the same approval a repo-local quick action needs. Refused, not warned: the
# commands run the moment the workspace opens, so there is no later moment at
# which a warning could still be acted on. `--dry-run` is exempt — reading what
# a space WOULD do is how you decide whether to approve it.
#
# BEFORE the file is read, so approval covers the bytes that get executed and
# an unapproved space cannot even reach the validator. Keyed on the TIER tag,
# and the file must still be the repo path — a forged row claiming tier `repo`
# with someone else's path is refused rather than opened.
case "$tier" in
  repo*)
    if [ "$file" != "${REPO_FILE:-}" ]; then
      echo "open-project: a listed space claims to be this repo's but points elsewhere:" >&2
      echo "  $file" >&2
      echo "  refusing — the repo tier is exactly \$REPO_ROOT/.herdr-control/project.json" >&2
      exit 1
    fi
    if [ "$dry" = 0 ] && ! is_trusted "$REPO_FILE"; then
      echo "open-project: this repo's space is not approved on this machine." >&2
      echo "  file: $REPO_FILE" >&2
      echo "  It runs pane commands that arrived with the repo. Review them:" >&2
      echo "    ./open-project.sh --dry-run $name" >&2
      echo "  Then approve at the current content:" >&2
      echo "    ./open-project.sh --trust" >&2
      exit 1
    fi
    ;;
esac

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
