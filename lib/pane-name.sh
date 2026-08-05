#!/usr/bin/env bash
# pane-name.sh — turn a pane id into something a human recognises.
#
# "w3:p1" means nothing to the person reading the alert on their phone. The
# workspace and tab already carry the names they chose ("project-a", "Main"),
# so use those and keep the id only as a small technical suffix.
#
# Provides: pane_display_name <pane_id>   -> "project-a — Main" / "~ — main"
#
# Falls back through: pane label -> "workspace — tab" -> workspace -> pane id.
# Never fails: an alert with an ugly name beats no alert.

pane_display_name() {
  local pane="$1" panes ws tab plabel wlabel tlabel
  panes=$(herdr pane list 2>/dev/null) || { printf '%s' "$pane"; return 0; }

  read -r ws tab plabel <<EOF
$(printf '%s' "$panes" | jq -r --arg p "$pane" '
  (.result.panes // .panes)[]? | select(.pane_id==$p)
  | "\(.workspace_id // "-") \(.tab_id // "-") \(.label // "-")"' 2>/dev/null)
EOF

  [ -n "${ws:-}" ] && [ "$ws" != "-" ] || { printf '%s' "${plabel:-$pane}"; return 0; }
  wlabel=$(herdr workspace list 2>/dev/null | jq -r --arg w "$ws" '
    (.result.workspaces // .workspaces)[]? | select(.workspace_id==$w) | .label // empty' 2>/dev/null)
  tlabel=$(herdr tab list --workspace "$ws" 2>/dev/null | jq -r --arg t "${tab:-}" '
    (.result.tabs // .tabs)[]? | select(.tab_id==$t) | .label // empty' 2>/dev/null)

  # Space — Tab is the primary identity: it is what you see in the herdr UI.
  # A pane label ("project-a-gate") is extra precision when several panes share
  # a tab, so it rides along in parens rather than replacing the names.
  local name=""
  if [ -n "$wlabel" ] && [ -n "$tlabel" ]; then name="$wlabel — $tlabel"
  elif [ -n "$wlabel" ];                  then name="$wlabel"
  fi
  if [ -n "$name" ]; then
    if [ -n "${plabel:-}" ] && [ "$plabel" != "-" ] && [ "$plabel" != "$tlabel" ]; then
      printf '%s (%s)' "$name" "$plabel"
    else
      printf '%s' "$name"
    fi
  else
    printf '%s' "${plabel:-$pane}"
  fi
}
