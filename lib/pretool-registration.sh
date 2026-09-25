#!/usr/bin/env bash
# pretool-registration.sh — refuse fleet-creating tools outside a live,
# registered worker generation.
#
# This is the herdr-control equivalent of Firstmate's primary-session
# delegation guard: ordinary tools remain governed by the harness and
# command-policy paths, but a built-in task/agent/worktree tool must not create
# work the central registry cannot supervise. The registry is outside the
# worktree, and pane_birth is the generation fingerprint; neither is trusted
# from worker-controlled files or caller-supplied arguments.
#
# Usage: pretool-registration.sh <tool-name> [cwd]
# Exit 0: tool is not fleet-creating, or the current task owns this generation.
# Exit 8: fleet-creating tool is unregistered, stale, outside its worktree, or
#         the registry/live pane identity cannot be proved.
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
  taskoutput|taskstop|taskget|tasklist|cronlist|bashoutput|killshell|taskcreate|taskupdate) exit 0 ;;
  *agent*|*subagent*|*task*|*workflow*|*cron*|*schedul*|*worktree*|*delegate*|*spawn*|*dispatch*|*handoff*|*remote*|*sendmessage*|*monitor*) ;;
  *) exit 0 ;;
esac

fail() {
  printf 'herdr pretool: REFUSED — %s\n' "$1" >&2
  exit 8
}

run_id=${HERDR_RUN_ID:-}
task_id=${HERDR_TASK_ID:-}
pane=${HERDR_PANE_ID:-}
[ -n "$run_id" ] && [ -n "$task_id" ] && [ -n "$pane" ] \
  || fail "fleet-creating tool '$tool' requires a registered worker; use spawn-task.sh from the conductor"

task_json=$(read_task "$run_id" "$task_id" 2>/dev/null || true)
[ -n "$task_json" ] || fail "worker identity $run_id/$task_id is not registered"

state=$(printf '%s' "$task_json" | jq -r '.state // empty' 2>/dev/null)
case "$state" in
  starting|running|blocked) ;;
  *) fail "worker identity $run_id/$task_id is not active (state=${state:-unknown})" ;;
esac

registered_pane=$(printf '%s' "$task_json" | jq -r '.pane_id // empty' 2>/dev/null)
registered_birth=$(printf '%s' "$task_json" | jq -r '.pane_birth // empty' 2>/dev/null)
[ "$registered_pane" = "$pane" ] && [ -n "$registered_birth" ] \
  || fail "worker identity does not own pane '$pane'"

live_birth=$(pane_birth_now "$pane" 2>/dev/null || true)
[ -n "$live_birth" ] || fail "cannot prove the live generation for pane '$pane'"
[ "$live_birth" = "$registered_birth" ] \
  || fail "pane '$pane' was recycled (registered generation=$registered_birth live generation=$live_birth)"

worktree=$(printf '%s' "$task_json" | jq -r '.worktree // empty' 2>/dev/null)
[ -n "$worktree" ] || fail "registered worker has no worktree ownership"
real_cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || fail "cannot resolve tool cwd '$cwd'"
real_worktree=$(cd "$worktree" 2>/dev/null && pwd -P) || fail "cannot resolve registered worktree"
case "$real_cwd/" in
  "$real_worktree/"*) ;;
  *) fail "tool cwd '$real_cwd' is outside the registered worktree '$real_worktree'" ;;
esac

exit 0
