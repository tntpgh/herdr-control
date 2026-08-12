#!/usr/bin/env bash
# engineering-ledger-loop.sh — Phase 1 (E0) background cadence for the
# Stage-1 engineering activity ledger (docs/engineering-evolution-loop-charter.md
# §3 Stage 1, §7 Phase 1, thurber-os repo). Wraps the already-built, already-
# verified engineering-ledger-poll.sh (herdr-control PR #14) in a supervised
# poll loop — this file is the one piece Phase 1 was still missing per the
# charter's own "remaining work" note.
#
# Intended to run under `hub start ... --restart always` (process supervision,
# auto-restart on crash) rather than as a bare backgrounded shell — this
# script itself does not daemonize or retry on failure; that's the
# supervisor's job. It only loops + sleeps + logs.
#
# Zero write capability outside the ledger file itself: every source the
# underlying poll script hits is read-only (Sentry GET, gh list, Neon
# read-only transaction) — same E0 guarantee, just recurring instead of
# manual-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL_SECONDS="${ENGINEERING_LEDGER_POLL_INTERVAL_SECONDS:-300}"

echo "engineering-ledger-loop: starting, interval=${POLL_INTERVAL_SECONDS}s, dir=${ENGINEERING_LEDGER_DIR:-<default .local-state/engineering-ledger>}"

cycle=0
while true; do
  cycle=$((cycle + 1))
  echo "--- cycle ${cycle} $(date -u +%Y-%m-%dT%H:%M:%SZ) ---"
  if ! "${SCRIPT_DIR}/engineering-ledger-poll.sh"; then
    echo "engineering-ledger-loop: cycle ${cycle} poll failed non-zero exit — continuing, poll script already fails closed per-source" >&2
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
done
