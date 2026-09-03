#!/usr/bin/env bash
# engineering-ledger-poll.sh — Stage-1 / E0 engineering activity collector.
#
# Reads production metadata from Sentry, the KB nightly-resilience ledger, and
# GitHub, then appends one sanitized JSON record per source to a local JSONL
# ledger. It has no monitored-system write path: Sentry is GET-only, GitHub is
# list-only, and Neon rejects writes at the connection level.
#
# Usage:
#   ./engineering-ledger-poll.sh
#   ./engineering-ledger-poll.sh --dry-run   # collect live data; do not append
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/engineering-ledger.sh"
. "$here/lib/emit-loop-run.sh"
. "$here/lib/sentinel-watch.sh"

engineering_ledger_poll "$@"
rc=$?

# Feed the dead-man for this lane (E0 OBSERVE). Every poll reports; the row proves
# the loop is alive, and `findings` is the learning signal over successive runs.
# --dry-run still reports: a dry poll is a real invocation of the loop.
# The higher watcher the sentinel design asks for. Cadence matters: the heartbeat
# TTL is 5 min and this poll runs every 5 min, so staleness is detectable here and
# nowhere else in the fleet.
#
# The verdict is a FINDING, not just a log line. Until 2026-09-03 this ran
# sentinel_watch and then passed a hardcoded findings=0 to emit_loop_run, so 46
# consecutive DEGRADED polls (0 healthy, ever) were recorded as
# `state=succeeded findings=0` — a watcher whose alarm had no reader, which is the
# exact failure this file exists to prevent one level down. Anything that is not
# `healthy` now counts, so the OBSERVE lane's findings column carries the signal
# and Sisyphus can see it.
sentinel_line="$(sentinel_watch)"
echo "$sentinel_line"
case "$sentinel_line" in
    "sentinel: healthy"*) sentinel_findings=0 ;;
    *)                    sentinel_findings=1 ;;
esac

# `state` stays keyed to the POLL's own exit code: the poll really did succeed, and
# conflating "the loop ran" with "the loop is happy" would make a degraded sentinel
# look like a broken poll. The finding is the correct channel for the verdict.
emit_loop_run observe "$([ "$rc" = 0 ] && echo succeeded || echo failed)" \
    "$sentinel_findings" "poll rc=$rc; $sentinel_line"
exit $rc
