#!/usr/bin/env bash
# wake-on-evidence.sh — wake when a peer session writes a milestone to a shared
# evidence file. Watches the FILE (durable), never the terminal (which echoes
# your own kick-off that quotes the marker → false positives).
#
# Usage:  wake-on-evidence.sh <file> <pattern> [max_polls] [interval_s]
#   file       path to the peer's append-only events file (may not exist yet)
#   pattern    grep -E pattern that appears ONLY on real completion
#   max_polls  polls before timeout (default 480)
#   interval_s seconds between polls (default 30)
#
# Exit 0 + echo the matched line on match; exit 3 on timeout. Run via Bash
# run_in_background so the single match re-invokes the agent. Re-arm only once
# the awaited event can actually occur — long idle watches get reaped.
set -uo pipefail

f="${1:?usage: wake-on-evidence.sh <file> <pattern> [max_polls] [interval_s]}"
pat="${2:?pattern required}"
max="${3:-480}"
interval="${4:-30}"

for _ in $(seq 1 "$max"); do
  if line=$(grep -E "$pat" "$f" 2>/dev/null | tail -1) && [ -n "$line" ]; then
    echo "MATCH: $line"
    exit 0
  fi
  sleep "$interval"
done
echo "WATCH_TIMEOUT after ~$((max * interval / 60))m with no match for '$pat' in $f"
exit 3
