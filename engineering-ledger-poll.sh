#!/usr/bin/env bash
# engineering-ledger-poll.sh — Stage-1 / E0 engineering activity collector.
#
# Reads production metadata from Sentry, the KB nightly-resilience ledger, and
# GitHub, then appends one sanitized JSON record per source to a local JSONL
# ledger (always) and best-effort promotes the same cycle to Neon's
# kb.engineering_activity table (docs/decision-ledger-2026-08-16-record.md
# D-09, thurber-os repo). No monitored-system write path beyond that: Sentry
# is GET-only, GitHub is list-only, and the KB nightly-resilience read uses a
# separate read-only Neon session (lib/engineering-ledger-kb.py).
#
# Usage:
#   ./engineering-ledger-poll.sh
#   ./engineering-ledger-poll.sh --dry-run   # collect live data; do not append
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/engineering-ledger.sh"

engineering_ledger_poll "$@"
