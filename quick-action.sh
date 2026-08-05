#!/usr/bin/env bash
# quick-action.sh [--pick] [--trust <name>] [<name>]
#
# A fuzzy launcher for one-off commands, run in the CURRENT shell/directory —
# no herdr socket call at all, unlike everything else in this repo. It works
# even while herdr's control socket is down or version-mismatched, since it
# never talks to herdr; it just runs a local command.
#
# Actions are JSON files: global ones in
# ${XDG_CONFIG_HOME:-~/.config}/herdr-control/quick-actions/*.json, plus a
# repo-local override in <workdir>/.herdr-control/quick-actions/*.json — shown
# together, repo-local ones tagged (project). LOCAL wins a name collision
# (it is a deliberate override of a same-named global action), which is
# exactly why it needs the trust gate below: a repo-local action is shell
# code that arrives with whatever repo you clone or cd into, not something
# you personally authored the way your global actions are.
#
# TRUST GATE (independent security review, PoC-verified): running
# quick-action.sh inside ANY cloned repo used to execute its
# .herdr-control/quick-actions/*.json with zero prompt — full account code
# execution from a repo you merely inspected. Repo-local actions now require
# an explicit, content-hash-keyed approval before they can run:
#   quick-action.sh --trust "Build"     # review the file first, then approve
# Approval is recorded in $XDG_STATE_HOME/herdr-control/trusted-actions,
# keyed by (path, sha256 of content) — editing an already-trusted file's
# command re-requires approval, same as changing what you approved. Global
# actions need no trust step: you wrote them yourself.
#
# Idea, the global+repo-local two-tier discovery, the three action shapes
# (command/select/form), and the "value not referenced -> append as a final
# shell-quoted argument" fallback rule are credited to cloudmanic/herdr-plus's
# Quick Actions feature — reimplemented natively here (plain bash env-var
# substitution instead of Go templates, fzf instead of a bubbletea TUI) so
# herdr-control stays one dependency-light package. See README's Credits
# section.
#
# Schema:
#   {"name": "Verify Suite", "command": "for v in verify-*.sh; do ...; done"}
#   {"name": "Open Repo", "type": "select", "command": "open https://github.com/tntpgh/$HERDR_CONTROL_VALUE",
#    "options": [{"label": "herdr-control", "value": "herdr-control"}]}
#   {"name": "Search Google", "type": "form", "form": {"prompt": "Search for"},
#    "command": "open \"https://www.google.com/search?q=$HERDR_CONTROL_VALUE\""}
# "type" defaults to "command". select/form expose the chosen/typed text as
# $HERDR_CONTROL_VALUE (also $HERDR_CONTROL_WORKDIR, the launch directory).
#
# $HERDR_CONTROL_VALUE is expanded EXACTLY ONCE, by the shell that runs your
# command, so it is inert text — including `$(...)`, backticks, and `;` (a
# malicious form value cannot inject a second command). That guarantee is
# VOID the moment your own command hands the value to a SECOND shell —
# `bash -c "...$HERDR_CONTROL_VALUE..."`, `sh -c`, `eval`, `ssh host "..."`,
# `find -exec sh -c` all re-parse it and would execute an injected payload.
# If you need that, pass the value as an ARGUMENT to the second shell, not
# text spliced into its script: `bash -c 'echo "$1"' _ "$HERDR_CONTROL_VALUE"`.
#
#   ./quick-action.sh --pick               # fuzzy-pick (needs fzf)
#   ./quick-action.sh "Verify Suite"       # run by name, headless
#   ./quick-action.sh --trust "Build"      # approve a repo-local action
set -uo pipefail

GLOBAL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-control/quick-actions"
WORKDIR="$PWD"
LOCAL_DIR="$WORKDIR/.herdr-control/quick-actions"
TRUST_DB="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-control/trusted-actions"

_trust_hash() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

is_trusted() {  # <file> -> 0 iff approved at its CURRENT content hash
  local f="$1" h
  [ -f "$TRUST_DB" ] || return 1
  h=$(_trust_hash "$f")
  [ -n "$h" ] || return 1
  grep -qxF "$h  $f" "$TRUST_DB" 2>/dev/null
}

trust_file() {  # <file> -> record approval, replacing any stale entry for it
  local f="$1" h dir
  h=$(_trust_hash "$f")
  [ -n "$h" ] || { echo "quick-action: cannot hash $f" >&2; return 1; }
  dir=$(dirname "$TRUST_DB")
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null
  if [ -f "$TRUST_DB" ]; then
    grep -vF "  $f" "$TRUST_DB" >"$TRUST_DB.tmp" 2>/dev/null || : >"$TRUST_DB.tmp"
    mv "$TRUST_DB.tmp" "$TRUST_DB"
  fi
  printf '%s  %s\n' "$h" "$f" >>"$TRUST_DB"
  chmod 600 "$TRUST_DB" 2>/dev/null || true
}

list_actions() {  # -> "<name>\t<scope>\t<file>" per line, LOCAL first (it can override GLOBAL)
  local f name
  for f in "$LOCAL_DIR"/*.json; do
    [ -e "$f" ] || continue
    name=$(jq -r '.name // empty' "$f" 2>/dev/null)
    if [ -n "$name" ]; then
      if is_trusted "$f"; then
        printf '%s\tproject\t%s\n' "$name" "$f"
      else
        printf '%s\tproject, UNTRUSTED\t%s\n' "$name" "$f"
      fi
    fi
  done
  for f in "$GLOBAL_DIR"/*.json; do
    [ -e "$f" ] || continue
    name=$(jq -r '.name // empty' "$f" 2>/dev/null)
    [ -n "$name" ] && printf '%s\tglobal\t%s\n' "$name" "$f"
  done
}

pick=0; trust_target=""; positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pick) pick=1; shift ;;
    --trust) trust_target="${2:?usage: quick-action.sh --trust <name>}"; shift 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done
set -- ${positional[@]+"${positional[@]}"}

if [ -n "$trust_target" ]; then
  file=""
  while IFS=$'\t' read -r n _scope f; do
    [ "$n" = "$trust_target" ] && { file="$f"; break; }
  done < <(list_actions)
  case "$file" in
    "$LOCAL_DIR"/*) : ;;
    "") echo "quick-action: no such action: $trust_target" >&2; exit 1 ;;
    *) echo "quick-action: \"$trust_target\" is a global action — no trust step needed, you wrote it yourself." >&2; exit 1 ;;
  esac
  echo "quick-action: trusting $file — review its command before confirming:" >&2
  jq -r '.command' "$file" >&2
  echo "quick-action: this command runs UNRESTRICTED shell as you, every time \"$trust_target\" is invoked from this repo." >&2
  read -r -p "quick-action: type YES to approve: " confirm
  [ "$confirm" = "YES" ] || { echo "quick-action: not trusted." >&2; exit 1; }
  trust_file "$file" && echo "quick-action: trusted $file" >&2
  exit 0
fi

name="${1:-}"
if [ "$pick" = 1 ]; then
  command -v fzf >/dev/null 2>&1 || { echo "quick-action: --pick needs fzf on PATH" >&2; exit 1; }
  chosen=$(list_actions | fzf --prompt='action> ' --height=40% --reverse \
    --delimiter='\t' --with-nth=1,2) || exit 1
  name=$(cut -f1 <<<"$chosen")
fi
[ -n "$name" ] || { echo "usage: quick-action.sh [--pick] [--trust <name>] <name>" >&2; exit 1; }

file=""
while IFS=$'\t' read -r n _scope f; do
  [ "$n" = "$name" ] && { file="$f"; break; }
done < <(list_actions)
if [ -z "$file" ]; then
  echo "quick-action: no such action: $name" >&2
  echo "available:" >&2
  list_actions | while IFS=$'\t' read -r n scope _f; do echo "  $n ($scope)" >&2; done
  exit 1
fi

case "$file" in
  "$LOCAL_DIR"/*)
    if ! is_trusted "$file"; then
      echo "quick-action: $file is a REPO-LOCAL action and runs shell as you." >&2
      echo "quick-action: review it, then: quick-action.sh --trust '$name'" >&2
      exit 1
    fi
    ;;
esac

action=$(cat "$file") || { echo "quick-action: cannot read $file" >&2; exit 1; }
type=$(jq -r '.type // "command"' <<<"$action")
cmd=$(jq -r '.command // empty' <<<"$action")
[ -n "$cmd" ] || { echo "quick-action: $file has no \"command\"" >&2; exit 1; }

value=""
case "$type" in
  command) ;;
  select)
    command -v fzf >/dev/null 2>&1 || { echo "quick-action: a \"select\" action needs fzf on PATH" >&2; exit 1; }
    [ "$(jq '[.options[]?] | length' <<<"$action")" -gt 0 ] || { echo "quick-action: $file is type \"select\" but has no \"options\"" >&2; exit 1; }
    choice=$(jq -r '.options[]? | "\(.label)\t\(.value)"' <<<"$action" \
      | fzf --prompt="$name> " --height=40% --reverse --delimiter='\t' --with-nth=1) || exit 1
    value=$(cut -f2 <<<"$choice")
    ;;
  form)
    prompt=$(jq -r '.form.prompt // .name' <<<"$action")
    read -r -p "$prompt: " value || { echo "quick-action: cancelled" >&2; exit 1; }
    ;;
  *)
    echo "quick-action: unknown type \"$type\" in $file (want command|select|form)" >&2
    exit 1
    ;;
esac

export HERDR_CONTROL_WORKDIR="$WORKDIR"
export HERDR_CONTROL_VALUE="$value"
if [ "$type" != "command" ]; then
  case "$cmd" in
    *'$HERDR_CONTROL_VALUE'*|*'${HERDR_CONTROL_VALUE}'*) ;;  # already referenced
    *)
      # mirrors herdr-plus: a select/form command that never references the
      # value gets it appended as a final, shell-quoted argument instead.
      printf -v quoted_value '%q' "$value"
      cmd="$cmd $quoted_value"
      ;;
  esac
fi

bash -c "$cmd"
