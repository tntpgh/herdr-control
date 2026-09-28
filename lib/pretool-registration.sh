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

# omp's own read-only xd:// fleet-status devices (lib/pretool-shadow.sh:167
# lists these exact names as read-only/session-memory, allowed through its
# own tool-table) are reached here as a bare device name, or with an
# `xd_`/`xd:` prefix depending on which caller invokes this script. Exclude
# them by EXACT name before the stem match below — `handoff_debt` and
# `worktree_debt` otherwise stem-match `*handoff*`/`*worktree*` and get
# refused as fleet-creating (#182) even though neither creates a task or
# pane; they only read the registry/git state. Every other name on this
# list already falls through the stem match unmatched. The real `task`
# tool, `spawn-task.sh`, and `spawn-agent.sh` are untouched — none of their
# names appear here, so this opens no hole for actual delegation.
xd_dev="${tool_norm#xd_}"; xd_dev="${xd_dev#xd:}"
case "$xd_dev" in
  notepad_read|notepad_stats|fleet_status|pr_ready|handoff_debt|single_copy_scan|worktree_debt|suite_wired|decisions_open|project_status|recall|reflect|retain|report_issue)
    exit 0 ;;
esac
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
