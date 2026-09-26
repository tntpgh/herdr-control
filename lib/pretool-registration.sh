#!/usr/bin/env bash
# pretool-registration.sh — refuse native fleet-creating tools.
#
# Ordinary tools remain governed by the harness and command-policy paths, but a
# built-in task/agent/worktree/delegation tool creates work outside
# spawn-task.sh's central registry. A registered caller proves only who asked;
# it does not prove the child will be registered. Keep the boundary simple and
# fail closed: use spawn-task.sh from the conductor for new workers.
#
# Usage: pretool-registration.sh <tool-name> [cwd]
# Exit 0: tool is not fleet-creating.
# Exit 8: tool is fleet-creating and must use spawn-task.sh instead.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/run-registry.sh"
. "$here/pane-guard.sh"

tool=${1:-}
cwd=${2:-${PWD:-}}

# Shape-match future delegation tools instead of maintaining a fixed allowlist.
# These stems and the safe observer/todo exclusions follow Firstmate's
# b42d4fa8a752fad9a5f0235783b02534bce29219 subagent guard.
tool_norm=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_:-')
case "$tool_norm" in
  mcp__*) exit 0 ;;
  taskoutput|taskstop|taskget|tasklist|cronlist|bashoutput|killshell|taskupdate) exit 0 ;;
  *agent*|*subagent*|*task*|*workflow*|*cron*|*schedul*|*worktree*|*delegate*|*spawn*|*dispatch*|*handoff*|*remote*|*sendmessage*|*monitor*) ;;
  *) exit 0 ;;
esac

fail() {
  printf 'herdr pretool: REFUSED — %s\n' "$1" >&2
  exit 8
}

fail "fleet-creating tool '$tool' must use spawn-task.sh from the conductor so the child is registered"
