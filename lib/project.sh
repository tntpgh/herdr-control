#!/usr/bin/env bash
# lib/project.sh — open a WHOLE workspace (every tab, every pane, every
# startup command) from one declarative "project" JSON file, by name.
#
# Builds on lib/layout.sh's already-tested single-tab primitive: each project
# tab's "panes" array is exactly a layout.sh layout, unchanged, re-validated
# with the same layout_validate/layout_apply this repo already ships — and
# `working_dir`'s own `~`-expansion reuses layout.sh's `expand_tilde`
# (defined there, not duplicated here), so callers MUST source lib/layout.sh
# before this file. Both places that currently source this file already do.
# This file only adds the project-level envelope (name/description/
# working_dir + a list of tabs) and the loop that opens the workspace once,
# then lays one tab per entry into it.
#
# Idea and vocabulary ("Projects": a declarative template you open by name,
# "handy for shell aliases, scripts, and AI agents") credited to
# cloudmanic/herdr-plus's Projects feature — reimplemented natively here in
# bash+jq rather than depending on that Go plugin, so herdr-control stays one
# self-contained, dependency-light package under our own control. See
# README's Credits section.
#
# Known gap vs herdr-plus: herdr-plus's FIRST tab reuses the new workspace's
# own root tab (no extra blank tab left behind). Reusing that root pane here
# would require ensure-workspace.sh to hand back the pane id it just created,
# which it currently doesn't (its whole job is create-OR-reuse, collapsed to
# a single workspace_id). Left as a known, documented rough edge rather than
# widening ensure-workspace.sh's contract under time pressure: opening a
# BRAND NEW project workspace leaves one extra empty tab (the workspace's own
# auto-created root) alongside the project's real first tab. Opening an
# EXISTING (reused) workspace has no such artifact — ensure-workspace.sh's
# reuse path creates nothing.
#
# Schema (JSON object):
#   {
#     "name": "your-project",
#     "description": "optional one-liner shown in the --pick browser",
#     "working_dir": "~/Code/your-project",
#     "tabs": [
#       { "label": "work", "panes": [ {"cmd": "claude", "focus": true}, ... ] }
#     ]
#   }
# "panes" is validated/applied by lib/layout.sh's layout_validate/layout_apply
# — same fields (cmd/cwd/env/split/ratio/focus/label), same rules.
#
# Provides:
#   project_validate <project_json>              -> 0 ok / 1 (stderr explains)
#   project_open <project_json> <focus_flag>
#     -> prints layout_apply's own per-pane lines for every tab, sets
#        PROJECT_WORKSPACE_ID on success, returns 1 (stderr explains) on any
#        failure. <focus_flag> (--focus/--no-focus) applies to the FIRST tab
#        only; every later tab is --no-focus, matching herdr-plus's own
#        "tabs open in file order, the rest are created behind it."

_PROJECT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_PROJECT_HERE=$(cd "$_PROJECT_LIB_DIR/.." && pwd)

_PROJECT_KEYS='["name","description","working_dir","tabs"]'
_PROJECT_TAB_KEYS='["label","panes"]'

project_validate() {  # <project_json> -> 0/1
  local p="$1" bad n i
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$p" \
    || { echo "project: not a JSON object" >&2; return 1; }
  bad=$(jq -r --argjson allowed "$_PROJECT_KEYS" '
    [ keys[] | select(. as $k | ($allowed | index($k)) == null) ] | unique | join(", ")
  ' <<<"$p" 2>/dev/null)
  [ -z "$bad" ] || { echo "project: unknown top-level key(s): $bad" >&2; return 1; }
  jq -e '(.name // "") != "" and (.name | type) == "string"' >/dev/null 2>&1 <<<"$p" \
    || { echo "project: missing/empty \"name\"" >&2; return 1; }
  jq -e '(.working_dir // "") != "" and (.working_dir | type) == "string"' >/dev/null 2>&1 <<<"$p" \
    || { echo "project: missing/empty \"working_dir\"" >&2; return 1; }
  jq -e '(.tabs | type) == "array" and (.tabs | length) > 0' >/dev/null 2>&1 <<<"$p" \
    || { echo "project: missing/empty \"tabs\" array" >&2; return 1; }

  bad=$(jq -r --argjson allowed "$_PROJECT_TAB_KEYS" '
    [ .tabs[] | keys[] | select(. as $k | ($allowed | index($k)) == null) ] | unique | join(", ")
  ' <<<"$p" 2>/dev/null)
  [ -z "$bad" ] || { echo "project: unknown tab key(s): $bad" >&2; return 1; }
  jq -e '[.tabs[] | (.label // "") != "" and (.label | type) == "string"] | all' >/dev/null 2>&1 <<<"$p" \
    || { echo "project: every tab needs a non-empty \"label\"" >&2; return 1; }

  n=$(jq '.tabs | length' <<<"$p")
  i=0
  while [ "$i" -lt "$n" ]; do
    layout_validate "$(jq -c ".tabs[$i].panes" <<<"$p")" \
      || { echo "project: tab[$i] (\"$(jq -r ".tabs[$i].label" <<<"$p")\") has an invalid \"panes\" layout" >&2; return 1; }
    i=$((i + 1))
  done
  return 0
}

project_open() {  # <project_json> <focus_flag>
  local p="$1" foc="$2" wd raw_wd n i
  project_validate "$p" || return 1

  raw_wd=$(jq -r '.working_dir' <<<"$p")
  wd=$(expand_tilde "$raw_wd")
  wd=$(cd "$wd" 2>/dev/null && pwd) || { echo "project: no such directory: $raw_wd" >&2; return 1; }

  PROJECT_WORKSPACE_ID=$(bash "$_PROJECT_HERE/ensure-workspace.sh" --no-focus "$wd") \
    || { echo "project: ensure-workspace failed for $wd" >&2; return 1; }

  n=$(jq '.tabs | length' <<<"$p")
  i=0
  while [ "$i" -lt "$n" ]; do
    local label panes tab_foc
    label=$(jq -r ".tabs[$i].label" <<<"$p")
    panes=$(jq -c ".tabs[$i].panes" <<<"$p")
    tab_foc=--no-focus
    [ "$i" -eq 0 ] && tab_foc="$foc"
    layout_apply "$PROJECT_WORKSPACE_ID" "$wd" "$label" "$tab_foc" "$panes" \
      || { echo "project: tab \"$label\" failed to build" >&2; return 1; }
    i=$((i + 1))
  done
  return 0
}
