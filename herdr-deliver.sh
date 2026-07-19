#!/usr/bin/env bash
# herdr-deliver.sh <target> <text...>
#
# Deliver a message (a reply / an instruction) to a herdr agent and submit it.
# This is the delivery leaf the Slack bridge calls — but it's useful on its own
# for answering whichever agent is waiting on you.
#
#   <target> is one of:
#     w8:p2        a pane id
#     w8:t2        a tab id  -> its first pane
#     <label>      an agent/pane label (resolved via pane list)
#     --blocked    THE currently blocked pane (errors if 0 or >1 are blocked)
#
#   herdr-deliver.sh --blocked "yes, go with option B"
#   herdr-deliver.sh w8:p2 "continue; skip the migration for now"
#
# Delivery goes through send-to-agent.sh, which retries Enter until the message
# actually submits (handles the TUI paste-debounce). Exit 0 delivered, 4 stranded.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"
here=$(cd "$(dirname "$0")" && pwd)

target="${1:?usage: herdr-deliver.sh <pane|tab|label|--blocked> <text...>}"; shift
text="$*"
[ -n "$text" ] || { echo "herdr-deliver: empty message" >&2; exit 2; }

panes=$(herdr pane list 2>/dev/null) || { echo "herdr-deliver: pane list failed" >&2; exit 1; }

resolve_blocked() {
  local ids
  ids=$(printf '%s' "$panes" | jq -r '(.result.panes // .panes)[] | select(.agent_status=="blocked") | .pane_id')
  local n; n=$(printf '%s' "$ids" | grep -c . || true)
  if [ "$n" -eq 0 ]; then echo "herdr-deliver: no blocked agent to answer" >&2; return 1; fi
  if [ "$n" -gt 1 ]; then
    echo "herdr-deliver: $n blocked agents — name one explicitly:" >&2
    printf '%s' "$panes" | jq -r '(.result.panes // .panes)[] | select(.agent_status=="blocked") | "  \(.pane_id)  \(.label // "")  \(.cwd // "")"' >&2
    return 1
  fi
  printf '%s' "$ids"
}

case "$target" in
  --blocked) pane=$(resolve_blocked) || exit 1 ;;
  *:p*)      pane="$target" ;;
  *:t*)      pane=$(printf '%s' "$panes" | jq -r --arg t "$target" '(.result.panes // .panes)[] | select(.tab_id==$t) | .pane_id' | head -1) ;;
  *)         pane=$(printf '%s' "$panes" | jq -r --arg l "$target" '(.result.panes // .panes)[] | select(.label==$l) | .pane_id' | head -1) ;;
esac
[ -n "$pane" ] || { echo "herdr-deliver: could not resolve target '$target'" >&2; exit 1; }

bash "$here/send-to-agent.sh" "$pane" "$text"
rc=$?
[ "$rc" -eq 0 ] && echo "delivered to $pane" || echo "herdr-deliver: send to $pane returned $rc (may be stranded)" >&2
exit "$rc"
