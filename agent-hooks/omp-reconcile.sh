#!/usr/bin/env bash
# omp-reconcile.sh — the omp counterpart of session-reconcile.sh +
# interval-reconcile.sh, behind one entry point.
#
# Why one script for both modes instead of mirroring the two Claude hooks: the
# omp side is driven from agent-hooks/omp-herdr-control.ts, which already knows
# WHICH event it is handling (`before_agent_start` vs `tool_result`). Splitting
# that knowledge across two shell files as well would mean four places to keep in
# step with lib/reconcile.sh instead of two.
#
#   omp-reconcile.sh session   — the once-per-session pass (before_agent_start).
#   omp-reconcile.sh interval  — the throttled mid-session pass (tool_result).
#   omp-reconcile.sh ack       — commit a delivered report's checkpoint.
#
# session/interval print ONE JSON envelope on stdout (or nothing when the
# throttled interval pass has nothing to say):
#
#   {"report": "...", "ack_required": bool, "conductor_id": "...",
#    "task_states": {...}, "last_event_seq": N}
#
# The TS shim injects `report` into the session and, when ack_required, feeds
# the WHOLE envelope back on stdin to `omp-reconcile.sh ack` — only then do the
# task_states map and event cursor move. This ordering is the fix for the bug
# this file used to have: the interval pass was spawned with stdout IGNORED
# while run_reconciliation checkpointed its report as delivered, so every
# mid-session report was consumed unseen and the next session start said "no
# changes". Delivery now precedes acknowledgment; a consumer that dies between
# the two causes redelivery, never loss.
#
# Claude's hook-output JSON envelope is never printed here (--no-hook-json):
# it means nothing to omp and would just print a stray blob into the session.
#
# Always exits 0. A reconciliation problem must never fail the agent's turn.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/run-registry.sh"
. "$here/lib/reconcile.sh"

mode="${1:-session}"
conductor_id="$(resolve_conductor_id)"

case "$mode" in
  session)
    # Prune here and not in interval mode, matching session-reconcile.sh: this
    # fires once per session, whereas interval mode can fire every few minutes
    # for hours.
    run_reconciliation "$conductor_id" "omp:before_agent_start" --no-hook-json --defer-ack
    prune_completed_tasks "${HERDR_TASK_RETENTION_DAYS:-14}" >/dev/null 2>&1 || true
    ;;
  interval)
    interval="${HERDR_RECONCILE_INTERVAL_S:-300}"
    age="$(checkpoint_age_s "$conductor_id")"
    # Not due yet — the cheap path, one SQL read and no `herdr pane list`.
    # The clock this reads is touched at PREPARE time (touch_checkpoint_clock
    # inside run_reconciliation --defer-ack), not at ack time, so an
    # undelivered report throttles retries to once per interval instead of
    # re-sweeping on every tool result until the ack lands.
    [ "$age" -ge "$interval" ] || exit 0

    # The age-vs-interval test above is check-then-act, not atomic: two
    # tool_result firings close together can both read "due" and both proceed,
    # doubling the pane list + full registry scan. mkdir is atomic on POSIX
    # filesystems, so exactly one caller wins; the trap releases it on every
    # exit path including a failure inside run_reconciliation.
    lockdir="$(reconcile_lock_dir)"
    mkdir "$lockdir" 2>/dev/null || exit 0
    trap 'rmdir "$lockdir" 2>/dev/null' EXIT

    run_reconciliation "$conductor_id" "omp:tool_result" --quiet-if-empty --no-hook-json --defer-ack
    ;;
  ack)
    # Reads the envelope emitted above back on stdin. Tolerates garbage: a
    # malformed or replayed ack is a no-op (ack_reconcile's MAX() cursor
    # semantics), never a crash and never a backward cursor move.
    envelope="$(cat 2>/dev/null || true)"
    if printf '%s' "$envelope" | jq -e '.ack_required == true' >/dev/null 2>&1; then
      cid="$(printf '%s' "$envelope" | jq -r '.conductor_id // empty')"
      states="$(printf '%s' "$envelope" | jq -c '.task_states // {}')"
      seq="$(printf '%s' "$envelope" | jq -r '.last_event_seq // 0')"
      [ -n "$cid" ] && ack_reconcile "$cid" "$states" "$seq"
    fi
    ;;
  *)
    printf 'omp-reconcile.sh: unknown mode %s (expected session|interval|ack)\n' "$mode" >&2
    ;;
esac

exit 0
