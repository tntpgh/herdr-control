#!/usr/bin/env bash
# session-reconcile.sh — SessionStart hook: make wake-on-evidence PERSISTENT
# across conductor sessions.
#
# wake-on-evidence.sh only exists for as long as the Claude Code session that
# `run_in_background`'d it. When that session ends, the poller dies with it,
# and nothing re-arms it — a reopened session starts blind to every event a
# worker wrote in the meantime (observed: five agents finished unnoticed in
# one session). The registry (lib/run-registry.sh) is already durable; this
# hook is the missing READ on session start.
#
# The actual sweep (lost-detection) + report (per-conductor checkpoint) logic
# lives in lib/reconcile.sh, shared with agent-hooks/interval-reconcile.sh —
# the throttled PostToolUse counterpart that keeps checking DURING a long
# live session instead of only once at the start. See that file's header for
# why "only at SessionStart" isn't enough on its own.
#
# Emits hookSpecificOutput.additionalContext so the summary lands in the new
# session's context directly, not just on stdout a human has to go read.
# Never fails the session: every path exits 0.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/run-registry.sh"
. "$here/lib/reconcile.sh"

conductor_id="$(resolve_conductor_id)"
run_reconciliation "$conductor_id" "SessionStart"
exit 0
