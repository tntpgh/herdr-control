#!/usr/bin/env bash
# Run the isolated authorization gate locally or in CI. Dependency setup is
# separate: never install packages, touch user settings, or start live services.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
for dependency in python3 sqlite3 jq git; do
  command -v "$dependency" >/dev/null
done
.venv-bashlex/bin/python3 -c 'from importlib.metadata import version; assert version("bashlex") == "0.18"'

scratch="$(mktemp -d "${TMPDIR:-/tmp}/herdr-authorization-ci.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/tmp" "$scratch/runtime"
export TMPDIR="$scratch/tmp" PYTHONDONTWRITEBYTECODE=1
export HERDR_RUN_STATE_DIR="$scratch/runs" HERDR_STATE_ROOT="$scratch/state"
export HERDR_STATE_DIR="$scratch/state" HERDR_BRIDGE_STATE="$scratch/bridge"
export HERDR_ARCHIVE_ROOT="$scratch/archives" XDG_RUNTIME_DIR="$scratch/runtime"

run() {
  printf '\n+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

run python3 remote-mcp/verify-authorization.py
run python3 verify-task-authorization.py
run python3 verify-action-transaction.py
run python3 verify-task-reservation.py
run bash verify-run-registry.sh
run bash verify-task-authorization-gates.sh
run bash verify-process-identity-failures.sh
# Independent timers/process identity and live spawn acceptance are excluded.
run python3 remote-mcp/verify-tasks-e2e.py --registry-only
