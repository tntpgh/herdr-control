#!/usr/bin/env bash
# wait-for-blocked.sh — block until any agent pane needs input, then report it.
#
# The orchestration gap this closes: herdr already reports `agent_status:
# blocked` when a session hits a permission prompt, but nothing PUSHES that to a
# conductor session. So a worker sits on "Do you want to proceed? 1/2/3" until
# the conductor happens to poll — which, run by hand, means minutes of a worker
# doing nothing and the operator noticing before the orchestrator does.
#
# Run under Bash run_in_background: the exit re-invokes the conductor with the
# blocked pane named, turning a poll into a wake.
#
#   wait-for-blocked.sh [poll_seconds] [max_polls] [pane_id ...]
#
# With pane ids, only those are watched (use for "my" workers so another
# session's prompt doesn't wake you). With none, watches every agent pane.
#
# Exit 0 = something is blocked (details on stdout). Exit 3 = timed out.
set -uo pipefail

# `shift 2` is all-or-nothing in bash: with fewer than 2 positional args it
# fails and shifts NOTHING, so a single-argument call — `wait-for-blocked.sh
# 30` (poll_seconds only, per the usage line above) — used to leave "30"
# sitting in $* and get treated as a bogus pane id, silently degrading
# "watch everything" into "watch a pane named 30" (which never exists).
# shift exactly min($#, 2) instead, so it always succeeds and only ever
# removes the args that were actually poll_seconds/max_polls.
interval="${1:-15}"; max="${2:-240}"; shift "$(( $# < 2 ? $# : 2 ))"
watch_list="$*"

command -v herdr >/dev/null 2>&1 || { echo "wait-for-blocked: herdr not on PATH" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"

i=0
while [ "$i" -lt "$max" ]; do
  candidates="$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
watch = set(sys.argv[1].split()) if len(sys.argv) > 1 and sys.argv[1].strip() else None
try:
    data = json.load(sys.stdin)
    panes = (data.get("result") or data).get("panes") or []
except Exception:
    sys.exit(1)                      # unreadable -> treat as "nothing yet", keep polling
hits = [p for p in panes
        if (p.get("agent_status") == "blocked" or p.get("agent"))
        and (watch is None or p.get("pane_id") in watch)]
for p in hits:
    print("\t".join(str(p.get(k) or "-") for k in ("pane_id", "label", "workspace_id", "agent_status")))
' "$watch_list" 2>/dev/null)"
  # omp can be labelled "working" with a real approval menu painted.
  # A missed push hook must not hide that stall from the polling backstop.
  out="$(while IFS=$'\t' read -r pane label ws status; do
    [ -n "$pane" ] || continue
    if [ "$status" = blocked ] || {
      pane_is_agent "$pane" && prompt_menu_visible "$pane"
    }; then
      printf '%s\t%s\t%s\n' "$pane" "$label" "$ws"
    fi
  done <<EOF
$candidates
EOF
)"

  if [ -n "$out" ]; then
    echo "BLOCKED — these panes are waiting on input:"
    printf '%s\n' "$out" | while IFS=$'\t' read -r pane label ws; do
      echo "  $pane  (ws $ws, ${label})"
      # Show the prompt itself, so the conductor can answer without another round
      # trip. A numbered prompt is answered with herdr-select.sh <pane> <n>, NOT
      # by sending Enter — Enter accepts whatever option happens to be highlighted.
      herdr pane read "$pane" 2>/dev/null | tail -12 | sed 's/^/      | /'
    done
    exit 0
  fi
  i=$((i + 1))
  sleep "$interval"
done

echo "wait-for-blocked: nothing blocked after $((max * interval))s"
exit 3
