#!/usr/bin/env bash
# unregister-owner.sh <label>
#
# Remove a label registered by register-owner.sh. Every owner message already
# queued for it does not vanish silently: the Worker's own sync() re-checks
# snapshot.owners on the Mac's NEXT publish and finalizes anything still
# queued as blocked:owner_not_registered (remote-mcp/worker/src/state.ts) --
# this script only ever touches the local registry, never the Worker.
#
#   unregister-owner.sh conductor
#
# Exit 0 removed (or already absent -- idempotent), 1 bad usage.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/run-registry.sh"

label="${1:?usage: unregister-owner.sh <label>}"
unregister_owner "$label" || exit 1
echo "unregistered: $label"
