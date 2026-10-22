#!/usr/bin/env bash
# orphan-plan.sh — READ-ONLY. Lists registry tasks still `running`/`blocked`
# whose pane no longer holds the session they registered (pane absent, or the
# pane_id recycled to a different terminal_id). Prints the plan; changes
# NOTHING (no --apply exists: marking rows `lost` is a separate, gated act).
#
# 2026-10-21: 21 running + 3 blocked rows back to 09-30, most with no pane.
# If herdr's pane list cannot be read, every row is UNKNOWN, never orphan.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/run-registry.sh
source "$here/lib/run-registry.sh"
db="$(registry_db)"
[ -f "$db" ] || { echo "orphan-plan: no registry at $db" >&2; exit 2; }
panes_json="$(herdr pane list 2>/dev/null)"
panes_ok=0
printf '%s' "$panes_json" | jq -e '(.result.panes // .panes) | type == "array"' >/dev/null 2>&1 && panes_ok=1

orphan=0; live=0; unknown=0
while IFS='|' read -r task_id state pane birth label created; do
  if [ "$panes_ok" != 1 ]; then
    verdict=UNKNOWN; why="herdr pane list unreadable"; unknown=$((unknown+1))
  else
    live_birth=$(printf '%s' "$panes_json" | jq -r --arg p "$pane" '((.result.panes // .panes)[]|select(.pane_id==$p)|.terminal_id) // "ABSENT"')
    if [ "$live_birth" = ABSENT ]; then verdict=ORPHAN; why="pane absent"; orphan=$((orphan+1))
    elif [ -n "$birth" ] && [ "$live_birth" != "$birth" ]; then verdict=ORPHAN; why="pane_id recycled (birth mismatch)"; orphan=$((orphan+1))
    else verdict=LIVE; why="pane holds registered session"; live=$((live+1)); fi
  fi
  printf '%-7s %-8s %-8s %-16s %-44s %s\n' "$verdict" "$state" "$pane" "${created:0:16}" "$label" "$why"
done < <(sqlite3 -readonly -batch -noheader "$db" \
  "SELECT task_id||'|'||state||'|'||pane_id||'|'||COALESCE(pane_birth,'')||'|'||label||'|'||created_at FROM tasks WHERE state IN ('running','blocked') ORDER BY created_at")
echo
printf 'plan: %d orphan (would become lost, with this evidence), %d live, %d unknown — READ-ONLY, nothing changed\n' "$orphan" "$live" "$unknown"
