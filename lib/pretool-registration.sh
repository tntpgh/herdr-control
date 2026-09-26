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
# b42d4fa8a752fad9a5f0235783b02534bce29219 subagent guard. MCP tools are not
# blanket-safe: only read-only observer-shaped MCP names bypass this block;
# unknown or delegation-shaped MCP tools fail closed before server code runs.
tool_norm=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_:-')
mcp_tool_is_safe_observer() {
  case "$1" in mcp__*) ;; *) return 1 ;; esac
  local leaf="${1##*__}"
  case "$leaf" in
    read|read_*|get|get_*|list|list_*|search|search_*|fetch|fetch_*|lookup|lookup_*|inspect|inspect_*|show|show_*|find|find_*|grep|grep_*|glob|glob_*|status|status_*|metadata|metadata_*) return 0 ;;
    *) return 1 ;;
  esac
}
case "$tool_norm" in
  taskoutput|taskstop|taskget|tasklist|cronlist|bashoutput|killshell|taskupdate) exit 0 ;;
  mcp__*) mcp_tool_is_safe_observer "$tool_norm" && exit 0 ;;
  *agent*|*subagent*|*task*|*workflow*|*cron*|*schedul*|*worktree*|*delegate*|*spawn*|*dispatch*|*handoff*|*remote*|*sendmessage*|*monitor*) ;;
  *) exit 0 ;;
esac

fail() {
  printf 'herdr pretool: REFUSED — %s\n' "$1" >&2
  exit 8
}

fail "fleet-creating tool '$tool' must use spawn-task.sh from the conductor so the child is registered"
