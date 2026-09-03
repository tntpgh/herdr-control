#!/usr/bin/env bash
# mark-tab.sh <pane_id|tab_id> <need> [badge-text]
#
# "Color" a tab by pushing an agent_status onto its pane — herdr renders the
# status as the tab's colored indicator. herdr has NO arbitrary tab color; the
# vocabulary is fixed, so <need> maps onto it:
#
#   waiting | decision | review | blocked   -> blocked   (needs you / attention)
#   active  | working  | busy               -> working   (in progress)
#   done    | idle     | parked | ok        -> idle      (finished / quiet)
#
# Optional badge-text attaches a label to that state (herdr state-label), e.g.
#   mark-tab.sh w2:t3 waiting "needs decision: merge?"
#
# Targets accept a tab id (w2:t3 -> its first pane) or a pane id (w2:p3).
# NOTE: if a live agent occupies the pane, its own status hook may later
# overwrite this — mark is an assertion, not a lock.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

target="${1:?usage: mark-tab.sh <pane_id|tab_id> <need> [badge-text]}"
need="${2:?usage: mark-tab.sh <pane_id|tab_id> <need> [badge-text]}"
badge="${3:-}"

case "$need" in
  waiting|decision|review|blocked)      state=blocked ;;
  active|working|busy|run|running)      state=working ;;
  done|idle|parked|ok|clean|finished)   state=idle ;;
  *) echo "mark-tab: unknown need '$need' (waiting|active|done)" >&2; exit 1 ;;
esac

# Resolve a tab id to its first pane.
case "$target" in
  *:t*) pane=$(herdr pane list 2>/dev/null | jq -r --arg t "$target" \
                 '(.result.panes // .panes)[] | select(.tab_id==$t) | .pane_id' | head -1) ;;
  *)    pane="$target" ;;
esac
[ -n "$pane" ] || { echo "mark-tab: no pane for target '$target'" >&2; exit 1; }

herdr pane report-agent "$pane" --source "$HERDR_SOURCE" --agent "${HERDR_MARK_AGENT:-task}" --state "$state" >/dev/null 2>&1 \
  || { echo "mark-tab: report-agent failed for $pane" >&2; exit 1; }

if [ -n "$badge" ]; then
  herdr pane report-metadata "$pane" --source "$HERDR_SOURCE" --state-label "${state}=${badge}" >/dev/null 2>&1 \
    || echo "mark-tab: badge set failed (state color still applied)" >&2
fi

printf 'marked %s -> %s%s\n' "$pane" "$state" "${badge:+ ($badge)}"
