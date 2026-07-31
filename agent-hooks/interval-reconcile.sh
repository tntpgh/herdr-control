#!/usr/bin/env bash
# interval-reconcile.sh — PostToolUse hook: the "periodic reconciliation"
# half of "push for responsiveness + periodic reconciliation for
# correctness" WITHIN a single live conductor session, not just at start.
#
# session-reconcile.sh only runs once, at SessionStart — a conductor that
# stays open for hours never re-checks the registry again on its own, so a
# worker that goes `lost` (pane closed, pane recycled) or completes an hour
# into a long session isn't surfaced until the NEXT restart. This hook
# piggybacks on PostToolUse (fires on every tool call, so its wall-clock
# resolution tracks actual session activity) but is THROTTLED — the
# expensive part (a live `herdr pane list` + a full registry scan) only runs
# once per HERDR_RECONCILE_INTERVAL_S (default 300s), using the checkpoint
# file's own mtime as the "last ran" clock (lib/run-registry.sh's
# checkpoint_age_s) so most invocations cost a single stat call.
#
# A necessary limitation, not a bug: an IDLE session (no tool calls) gets no
# interval reconciliation until its next tool call or the next SessionStart —
# this is activity-gated polling, not a real timer. True wall-clock
# periodicity independent of activity would need a background daemon, which
# is out of scope for a Claude Code hook (see
# docs/control-plane-design.md, roadmap item #1).
#
# --quiet-if-empty (lib/reconcile.sh) matters here specifically: unlike
# SessionStart's one-time "no changes" confirmation, narrating that on every
# throttled tick would be noise the agent has to read on every few tool
# calls for the entire life of a session.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/run-registry.sh"
. "$here/lib/reconcile.sh"

interval="${HERDR_RECONCILE_INTERVAL_S:-300}"
conductor_id="$(resolve_conductor_id)"

age="$(checkpoint_age_s "$conductor_id")"
[ "$age" -ge "$interval" ] || exit 0     # not due yet — cheap, no herdr/jq calls

# checkpoint_age_s-vs-interval above is check-then-act, not atomic: two
# PostToolUse hook firings close together can both read "due" before either
# has run reconciliation, and both proceed — doubling the herdr pane list +
# full task scan and racing on the same task-file writes. mkdir is atomic on
# POSIX filesystems (exactly one caller ever wins the "did not exist, now
# does" transition), so it's a dependency-free mutex; the trap guarantees
# the lock directory is removed on every exit path, including a failure
# inside run_reconciliation itself.
lockdir="$(reconcile_lock_dir)"
mkdir "$lockdir" 2>/dev/null || exit 0
trap 'rmdir "$lockdir" 2>/dev/null' EXIT

run_reconciliation "$conductor_id" "PostToolUse" --quiet-if-empty
exit 0
