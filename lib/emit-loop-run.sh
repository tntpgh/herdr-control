#!/usr/bin/env bash
# Shared helper: tell the run ledger that an evolution-loop stage ran.
#
# The loops observed everything except themselves. Stage 2 was dead for a MONTH
# (non-executable spawn-task.sh, then a BSD-mktemp bug) and the only signal was an
# exit code in `launchctl list` — nothing paged, nothing noticed, and the next
# scheduled attempt was another month out.
#
# Feeding kb.agent_runs makes the loop a WATCHED lane: server/watchdog.detect_misses
# raises RUN_MISSED when a registered lane goes quiet, and watchdog_sisyphus then
# turns that into a deduped incident with an assessment and a recommended next step.
# So silence now pages, and the page arrives pre-triaged.
#
# Best-effort by construction: a ledger outage must never break the loop it
# instruments. Emits a warning and returns 0.
emit_loop_run() {
    local loop="$1" state="${2:-succeeded}" findings="${3:-0}" note="${4:-}"
    local kb="$HOME/Code/knowledge-base"
    local py="$kb/.venv/bin/python3"
    [ -x "$py" ] || { echo "emit_loop_run: no KB venv at $py — lane stays unfed" >&2; return 0; }
    ( cd "$kb" && "$py" scripts/emit_loop_run.py --loop "$loop" --state "$state" \
        --findings "$findings" --note "$note" ) \
        || echo "emit_loop_run: ledger write failed for $loop — lane stays unfed" >&2
    return 0
}
