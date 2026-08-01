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
#                                Prints the report; the TS shim returns it as an
#                                injected message so it lands before the turn,
#                                which is omp's equivalent of Claude's
#                                hookSpecificOutput.additionalContext.
#   omp-reconcile.sh interval  — the throttled mid-session pass (tool_result).
#                                Silent when nothing changed.
#
# Both print the HUMAN summary only (--no-hook-json): Claude's hook-output JSON
# envelope means nothing to omp and would just print a stray blob into the
# session.
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
    run_reconciliation "$conductor_id" "omp:before_agent_start" --no-hook-json
    prune_completed_tasks "${HERDR_TASK_RETENTION_DAYS:-14}" >/dev/null 2>&1 || true
    ;;
  interval)
    interval="${HERDR_RECONCILE_INTERVAL_S:-300}"
    age="$(checkpoint_age_s "$conductor_id")"
    # Not due yet — the cheap path, one SQL read and no `herdr pane list`.
    [ "$age" -ge "$interval" ] || exit 0

    # The age-vs-interval test above is check-then-act, not atomic: two
    # tool_result firings close together can both read "due" and both proceed,
    # doubling the pane list + full registry scan. mkdir is atomic on POSIX
    # filesystems, so exactly one caller wins; the trap releases it on every
    # exit path including a failure inside run_reconciliation.
    lockdir="$(reconcile_lock_dir)"
    mkdir "$lockdir" 2>/dev/null || exit 0
    trap 'rmdir "$lockdir" 2>/dev/null' EXIT

    run_reconciliation "$conductor_id" "omp:tool_result" --quiet-if-empty --no-hook-json
    ;;
  *)
    printf 'omp-reconcile.sh: unknown mode %s (expected session|interval)\n' "$mode" >&2
    ;;
esac

exit 0
