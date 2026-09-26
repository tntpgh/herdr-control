#!/usr/bin/env bash
# detect-dead-workers.sh — find panes whose agent DIED on a provider error
# while herdr still reports them `working`.
#
# Why this exists: on 2026-09-21 two spawned workers were killed by provider
# limits — Sonnet `retry-after 6,132,000ms` at spawn, Codex
# `usage_limit_reached` mid-review. Both left a dead pane that herdr reported
# as `working`, and both were found only because a human swept the panes by
# hand. `agent_status` cannot see this: the process is alive and the TUI is
# painted, so nothing in the status model is false — it simply does not model
# "the model refused and the turn ended".
#
# REPORTS, NEVER ACTS. It prints candidates and exits 1. Killing or respawning
# a worker on a text match would be a control acting on a heuristic; the
# signature can legitimately appear in a pane that is merely DISCUSSING these
# errors (this repo's own session did exactly that). A human or conductor
# confirms, then acts.
#
# Run it on demand, or after a spawn batch. Do NOT put it on a short timer:
# fanning `pane read` across every pane on a timer is what pushed herdr's
# socket p95 from 9ms to 136ms (2026-09-14). The pane list comes from the hub
# (one HTTP call, zero herdr RPCs); only agent panes are then read.
#
# Usage: detect-dead-workers.sh [--lines N] [--json]
# Exit:  0 nothing found · 1 candidates found · 2 usage/env error

set -uo pipefail

HUB="${HERDR_HUB_URL:-http://127.0.0.1:8600}"
LINES=25
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lines) LINES="${2:?--lines needs a value}"; shift 2 ;;
    --json)  JSON=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "detect-dead-workers: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

command -v herdr >/dev/null || { echo "detect-dead-workers: herdr not on PATH" >&2; exit 2; }
command -v jq    >/dev/null || { echo "detect-dead-workers: jq not on PATH" >&2; exit 2; }

# Fatal signatures, every one observed in a real dead pane or in omp's own
# documented retry dead-end (omp://non-compaction-retry-policy.md step 8).
# Anchored to what the PROVIDER or the harness emits, never to prose an agent
# might write about them.
SIGS='usage_limit_reached|rate_limit_error|Retry failed after [0-9]+ attempts|exceeds retry\.maxDelayMs|Provider requested [0-9]+ms wait|The usage limit has been reached'

# The signature alone is NOT enough, and this is not theoretical: the first
# run of this script printed `usage_limit_reached` into the conductor's own
# pane, and the second run then reported the CONDUCTOR as a dead worker. A
# real death is an error-SHAPED line — the harness prefixes it (`Error:`), or
# it carries the provider's own `code=` / retry phrasing. A report table, a
# grep result, or an agent discussing these strings has none of that.
ERRSHAPE='(^|[[:space:]])[Ee]rror:|code=|Retry failed|Provider requested'

panes="$(curl -fsS --max-time 5 "$HUB/api/panes" 2>/dev/null \
         | jq -r '.panes[]? | select(.agent) | "\(.pane_id)\t\(.agent_status // "unknown")\t\(.label // .agent)"')" || {
  echo "detect-dead-workers: hub unreachable at $HUB — cannot enumerate panes" >&2
  exit 2
}
[ -n "$panes" ] || { [ "$JSON" = 1 ] && echo '{"candidates":[]}'; exit 0; }

found=0
rows=""
while IFS=$'\t' read -r pane status label; do
  [ -n "$pane" ] || continue
  text="$(herdr pane read "$pane" --source recent-unwrapped --lines "$LINES" 2>/dev/null)" || continue
  # The signature must be in the TAIL and on an error-shaped line. An agent
  # that merely quoted one of these strings mid-run keeps producing output,
  # which pushes it out of the window; a pane that DIED has it at the bottom.
  hit="$(printf '%s\n' "$text" | grep -E "$ERRSHAPE" | grep -oE "$SIGS" | tail -1)"
  [ -n "$hit" ] || continue
  found=1
  rows="${rows}${pane}\t${status}\t${label}\t${hit}\n"
done <<< "$panes"

if [ "$found" = 0 ]; then
  [ "$JSON" = 1 ] && echo '{"candidates":[]}'
  exit 0
fi

if [ "$JSON" = 1 ]; then
  printf "$rows" | jq -Rs 'split("\n")[:-1] | map(split("\t") |
    {pane: .[0], herdr_status: .[1], label: .[2], signature: .[3]}) | {candidates: .}'
else
  printf 'DEAD-WORKER CANDIDATES (herdr status shown for contrast — it is why these hide)\n\n'
  printf 'PANE\tHERDR\tLABEL\tSIGNATURE\n'
  printf "$rows"
  printf '\nConfirm before acting: read the pane, then resume it on a live model\n'
  printf 'or respawn. This script never kills or restarts anything.\n'
fi
exit 1
