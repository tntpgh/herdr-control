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

engineering_ledger_poll "$@"
