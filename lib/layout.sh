#!/usr/bin/env bash
# lib/layout.sh — apply a declarative pane layout (a small JSON array) to a
# NEW tab, splitting real panes via `herdr pane split` and threading the real
# ids each herdr call returns — same discipline spawn-agent.sh / spawn-task.sh
# already use for their single-pane tabs (jq out of `.result...`, never
# guessed). This is the multi-pane generalization of that same pattern.
#
# Deliberately has NO wait_for / output-pattern step. spawn-task.sh's own
# "coordination scaffold" comment already documents why: `herdr wait output
# --match` false-fires on a command's own kick-off echo quoting the marker.
# A layout pane that genuinely needs to block on another pane's readiness
# should use the same events.jsonl + wake-on-evidence.sh pattern spawn-task.sh
# uses, not output matching. This stays a pure "build the panes" primitive —
# sequencing belongs to the caller, not to the layout engine.
#
# Schema (JSON array, first element = the tab's root pane; every later
# element is a `pane split` chained off the PREVIOUS element, not the root):
#   [
#     {"cmd": "nvim", "cwd": "./src"},
#     {"split": "down", "ratio": 0.3, "cmd": "npm run dev", "focus": true}
#   ]
# Fields (unknown keys are a hard error — a typo should never be silently
# ignored):
#   cmd    shell command to run in the pane once created. Omit to leave the
#          pane sitting at a plain shell prompt (today's default behaviour).
#   cwd    relative to the LAYOUT's own root cwd (one level, not chained pane
#          to pane) unless it starts with / or ~.
#   env    {"KEY": "value", ...} — passed straight through as herdr's own
#          --env, so (unlike spawn-task.sh's stamped_cli) nothing here builds
#          a shell string of its own and there is no quoting hazard to guard.
#   split  "right" | "down", default "right". Ignored on the first pane.
#   ratio  float, forwarded to `herdr pane split --ratio`.
#   focus  bool. At most one pane should set this; first-with-focus wins.
#   label  border label, set via `herdr pane rename` after the pane exists
#          (there is no --label on pane split/tab create itself). Omit for
#          herdr's own default pane name.
#
# Provides:
#   layout_validate <layout_json>                     -> 0 ok / 1 (stderr explains)
#   layout_apply <workspace_id> <cwd> <label> <focus_flag> <layout_json>
#     -> prints one "pane=<id> role=<root|split> cmd=<...>" line per pane,
#        sets LAYOUT_TAB_ID and the LAYOUT_PANE_IDS array on success,
#        returns 1 (stderr explains) on any herdr call failure.
#     <focus_flag> is --focus or --no-focus — the layout-level fallback used
#     only when no individual pane sets "focus": true.

_LAYOUT_KEYS='["cmd","cwd","env","split","ratio","focus","label"]'

expand_tilde() {  # <path> -> $HOME-expanded path on stdout
  # Bash does NOT expand a literal `~` that arrives through a variable
  # (only a bare `~` token in source text gets that treatment), so a path
  # straight out of jq needs this done by hand before it reaches herdr —
  # otherwise herdr receives the literal string "~/logs" and tries to open
  # a directory actually named that. Handles `~` and `~/...` only (not
  # `~user`, same restriction project.sh's original copy of this had).
  # Shared here so lib/project.sh's working_dir and lib/layout.sh's own
  # per-pane cwd use the identical rule instead of two copies drifting.
  local raw="$1"
  case "$raw" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${raw#\~/}" ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

layout_validate() {  # <layout_json> -> 0/1
  local layout="$1" bad
  jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$layout" \
    || { echo "layout: not a non-empty JSON array" >&2; return 1; }
  bad=$(jq -r --argjson allowed "$_LAYOUT_KEYS" '
    [ .[] | keys[] | select(. as $k | ($allowed | index($k)) == null) ] | unique | join(", ")
  ' <<<"$layout" 2>/dev/null)
  [ -z "$bad" ] || { echo "layout: unknown key(s): $bad" >&2; return 1; }
  jq -e '[.[].split] | all(. == null or . == "right" or . == "down")' >/dev/null 2>&1 <<<"$layout" \
    || { echo "layout: split must be \"right\" or \"down\"" >&2; return 1; }
  jq -e '[.[].ratio] | all(. == null or (type == "number" and . > 0 and . < 1))' >/dev/null 2>&1 <<<"$layout" \
    || { echo "layout: ratio must be a number strictly between 0 and 1" >&2; return 1; }
  return 0
}

layout_apply() {  # <workspace_id> <cwd> <label> <focus_flag> <layout_json>
  local ws="$1" root_cwd="$2" label="$3" tab_focus="$4" layout="$5"
  layout_validate "$layout" || return 1
  LAYOUT_TAB_ID=""; LAYOUT_PANE_IDS=()

  local n; n=$(jq 'length' <<<"$layout")
  local declares_focus; declares_focus=$(jq -e 'any(.[]; .focus == true)' <<<"$layout" >/dev/null 2>&1 && echo 1 || echo 0)

  local i=0 prev_pane=""
  while [ "$i" -lt "$n" ]; do
    local spec; spec=$(jq -c ".[$i]" <<<"$layout")
    local p_cwd p_cmd p_split p_ratio p_focus_raw p_foc p_label abs_cwd
    p_cwd=$(jq -r '.cwd // empty' <<<"$spec")
    p_cmd=$(jq -r '.cmd // empty' <<<"$spec")
    p_split=$(jq -r '.split // "right"' <<<"$spec")
    p_ratio=$(jq -r '.ratio // empty' <<<"$spec")
    p_focus_raw=$(jq -r '.focus // false' <<<"$spec")
    p_label=$(jq -r '.label // empty' <<<"$spec")

    p_foc=--no-focus
    if [ "$p_focus_raw" = "true" ]; then
      p_foc=--focus
    elif [ "$i" -eq 0 ] && [ "$declares_focus" = 0 ] && [ "$tab_focus" = "--focus" ]; then
      # nobody in the layout claimed focus explicitly — fall back to the
      # tab-level flag landing on the root pane, same as a plain spawn.
      p_foc=--focus
    fi

    abs_cwd="$root_cwd"
    case "$p_cwd" in
      "") ;;
      /*) abs_cwd="$p_cwd" ;;
      "~"*) abs_cwd=$(expand_tilde "$p_cwd") ;;
      *) abs_cwd="$root_cwd/$p_cwd" ;;
    esac

    local -a ratio_args=()
    [ -n "$p_ratio" ] && ratio_args=(--ratio "$p_ratio")

    local -a env_args=()
    while IFS= read -r kv; do
      [ -n "$kv" ] && env_args+=(--env "$kv")
    done < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' <<<"$spec")

    local pane resp role
    if [ "$i" -eq 0 ]; then
      role=root
      resp=$(herdr tab create --workspace "$ws" --cwd "$abs_cwd" --label "$label" ${env_args[@]+"${env_args[@]}"} "$p_foc" 2>/dev/null)
      LAYOUT_TAB_ID=$(jq -r '.result.tab.tab_id // empty' <<<"$resp")
      pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$resp")
      [ -n "$LAYOUT_TAB_ID" ] && [ -n "$pane" ] || { echo "layout: tab create failed in $ws" >&2; return 1; }
    else
      role="split $p_split"
      resp=$(herdr pane split "$prev_pane" --direction "$p_split" \
        ${ratio_args[@]+"${ratio_args[@]}"} --cwd "$abs_cwd" ${env_args[@]+"${env_args[@]}"} "$p_foc" 2>/dev/null)
      pane=$(jq -r '.result.pane.pane_id // empty' <<<"$resp")
      [ -n "$pane" ] || { echo "layout: pane split failed (from $prev_pane)" >&2; return 1; }
    fi

    if [ -n "$p_label" ]; then
      herdr pane rename "$pane" "$p_label" >/dev/null 2>&1 \
        || { echo "layout: failed to label $pane as '$p_label'" >&2; return 1; }
    fi

    if [ -n "$p_cmd" ]; then
      # $p_cmd is passed as a single argv element straight to `herdr pane
      # run` — never concatenated into a shell string ourselves, so (unlike
      # spawn-task.sh's stamped export line) there is nothing here for a
      # stray quote in a layout file to break out of.
      herdr pane run "$pane" "$p_cmd" >/dev/null 2>&1 \
        || { echo "layout: failed to run '$p_cmd' in $pane" >&2; return 1; }
    fi

    printf 'pane=%s role=%s label=%s cmd=%s\n' "$pane" "$role" "${p_label:-<none>}" "${p_cmd:-<shell>}"
    LAYOUT_PANE_IDS+=("$pane")
    prev_pane="$pane"
    i=$((i + 1))
  done
  return 0
}
