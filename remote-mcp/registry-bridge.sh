#!/usr/bin/env bash
# registry-bridge.sh — the one place remote-mcp/tasks.py (Python) reaches
# into lib/run-registry.sh (bash functions, not a CLI) for the writes it has
# no other entry point for. Reads of a single row go through here too, so a
# future schema change updates one JSON shape instead of two parsers.
#
# Deliberately narrow: starting and completing a task already have real
# entry points (spawn-task.sh, close-done-workers.sh) that tasks.py calls
# directly as subprocesses — this exists only for set_task_remote_id /
# set_task_deadline / set_task_verified (no other caller needs them) and a
# forced cancel (explicit cancel_task / timed_out, which must NOT go through
# close-done-workers.sh's safe-autoclose gate: a cancel means give up now,
# dirty worktree or not).
#
#   registry-bridge.sh read <run_id> <task_id>
#   registry-bridge.sh read-by-remote <remote_task_id>
#   registry-bridge.sh set-remote-id <run_id> <task_id> <remote_task_id>
#   registry-bridge.sh set-deadline <run_id> <task_id> <deadline_iso>
#   registry-bridge.sh set-verified <run_id> <task_id> 0|1 [detail]
#   registry-bridge.sh cancel <run_id> <task_id> <reason>
#
# Every subcommand prints JSON (the row) or nothing, and exits nonzero on
# failure — tasks.py checks the return code, never scrapes stderr text.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)/..
# shellcheck source=lib/run-registry.sh
. "$HERE/lib/run-registry.sh"
# shellcheck source=lib/pane-guard.sh
. "$HERE/lib/pane-guard.sh"

cmd="${1:-}"; shift || true
case "$cmd" in
  read)
    read_task "$1" "$2"
    ;;
  read-by-remote)
    read_task_by_remote_id "$1"
    ;;
  set-remote-id)
    set_task_remote_id "$1" "$2" "$3" || exit 1
    read_task "$1" "$2"
    ;;
  set-deadline)
    set_task_deadline "$1" "$2" "$3" || exit 1
    ;;
  set-verified)
    set_task_verified "$1" "$2" "$3" "${4:-}" || exit 1
    ;;
  cancel)
    run_id="$1" task_id="$2" reason="$3"
    row=$(read_task "$run_id" "$task_id")
    [ -n "$row" ] || { echo "registry-bridge: no task record for $run_id/$task_id" >&2; exit 1; }
    set_task_state "$run_id" "$task_id" cancelled "$reason" || exit 1
    pane=$(printf '%s' "$row" | jq -r '.pane_id // empty')
    if [ -n "$pane" ]; then
      # M4: herdr reuses pane ids once a pane closes. If this task's own
      # pane died while the row stayed non-terminal, herdr may already have
      # handed that id to an unrelated worker -- closing by bare pane_id
      # would close THEIR pane, not this cancelled task's. Same rule
      # close-done-workers.sh --pane uses: only close when the currently
      # live occupant's terminal_id still matches what this row registered
      # (or the pane reports no live occupant at all, i.e. already gone).
      registered_birth=$(printf '%s' "$row" | jq -r '.pane_birth // empty')
      live_birth="$(pane_birth_now "$pane")"
      if [ -z "$live_birth" ] || [ "$live_birth" = "$registered_birth" ]; then
        [ -x "$HERE/claim.sh" ] && HERDR_PANE_ID="$pane" "$HERE/claim.sh" drop >/dev/null 2>&1
        herdr pane close "$pane" >/dev/null 2>&1 || true
      fi
    fi
    ;;
  *)
    echo "registry-bridge: unknown subcommand '$cmd'" >&2
    exit 2
    ;;
esac
