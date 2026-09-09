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

# A worker briefed before 2026-09-09 appends to the legacy
# `<worktree>/.omc/handoffs/events.jsonl` instead of `<worktree>/.handoffs/`
# (see lib/handoff.sh). Watching only the path we were given would then time
# out on a worker that finished correctly, so when handed a canonical path we
# also watch its legacy sibling. Drop this once no in-flight worker predates
# the change.
watch=("$f")
case "$f" in
  */.handoffs/events.jsonl) watch+=("${f%/.handoffs/events.jsonl}/.omc/handoffs/events.jsonl") ;;
esac

for _ in $(seq 1 "$max"); do
  # The MATCH test is the captured line, never the pipeline's status: grep
  # exits 2 when ANY named file is missing, and under `set -o pipefail` that 2
  # wins over the successful match in the file that does exist. With two
  # watched paths one is normally absent, so gating on status here silently
  # never fires — caught by verify-reconcile's legacy-brief case, 2026-09-09.
  line=$(grep -hE "$pat" "${watch[@]}" 2>/dev/null | tail -1) || true
  if [ -n "$line" ]; then
    echo "MATCH: $line"
    exit 0
  fi
  sleep "$interval"
done
echo "WATCH_TIMEOUT after ~$((max * interval / 60))m with no match for '$pat' in ${watch[*]}"
exit 3
