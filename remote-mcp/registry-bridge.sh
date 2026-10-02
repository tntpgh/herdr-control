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
#   registry-bridge.sh find-spawned <worktree> <branch> <since_iso> <expected_remote_task_id>
#   registry-bridge.sh set-remote-id <run_id> <task_id> <remote_task_id>
#   registry-bridge.sh set-deadline <run_id> <task_id> <deadline_iso>
#   registry-bridge.sh set-verified <run_id> <task_id> 0|1 [detail]
#   registry-bridge.sh cancel <run_id> <task_id> <reason> [expected_remote_task_id]
#
# Every subcommand prints JSON (the row) or nothing, and exits nonzero on
# failure — tasks.py checks the return code, never scrapes stderr text.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)/..
# shellcheck source=lib/run-registry.sh
. "$HERE/lib/run-registry.sh"

cmd="${1:-}"; shift || true
case "$cmd" in
  read)
    read_task "$1" "$2"
    ;;
  read-by-remote)
    read_task_by_remote_id "$1"
    ;;
  find-spawned)
    task_for_orphan_cleanup "$1" "$2" "$3" "$4"
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
    run_id="$1" task_id="$2" reason="$3" expected_remote="${4:-}"
    row=$(read_task "$run_id" "$task_id")
    [ -n "$row" ] || { echo "registry-bridge: no task record for $run_id/$task_id" >&2; exit 1; }
    if [ -n "$expected_remote" ]; then
      # R3-3: tasks.py's post-spawn-failure cleanup can reach here with a
      # run_id/task_id read cold from identity.json in a worktree _resume
      # reused from a PARENT task -- if spawn-task.sh hung before rewriting
      # that file for THIS attempt, the read names a different, possibly
      # still-live task. Refuse when this row's OWN remote_task_id is a
      # DIFFERENT, already-stamped task's id.
      #
      # R4-1: register_task runs long before the caller ever stamps
      # remote_task_id (set-remote-id) -- a timeout/crash in that window is
      # exactly the common case this cleanup exists for, and the row is
      # legitimately still unstamped ('') then. Refusing on EMPTY brought
      # back the orphan (no cancel at all); only a NON-EMPTY, DIFFERENT
      # remote_task_id is a real mismatch worth refusing.
      actual_remote=$(printf '%s' "$row" | jq -r '.remote_task_id // empty')
      [ -z "$actual_remote" ] || [ "$actual_remote" = "$expected_remote" ] || {
        echo "registry-bridge: refusing cancel — $run_id/$task_id's remote_task_id ($actual_remote) does not match the expected $expected_remote" >&2
        exit 1
      }
    fi
    # Z1 (SPEC fix: Zero's acceptance review item 1): the pane must be
    # CONFIRMED gone -- closed by us, or already recycled to a different
    # occupant -- BEFORE the row is ever marked cancelled. The old order
    # (state flip first, `herdr pane close ... || true` second) could
    # report a task cancelled while its agent kept running: a failed or
    # unmatched `herdr pane list` silently skipped the close, and the
    # state write had already happened. Any list failure, close failure,
    # or a pane that is STILL the registered occupant after the close
    # leaves this row NON-TERMINAL and exits nonzero: the caller
    # (tasks.py _cancel/_force_cancel) reports `failed`, and the next
    # sweep tick retries it (a timeout's deadline is already past, so
    # every tick retries; an explicit cancel's command is re-leased by
    # the Worker) -- this is the retry/backoff path, not a bug.
    pane=$(printf '%s' "$row" | jq -r '.pane_id // empty')
    if [ -n "$pane" ]; then
      # M4/N5/R3-6 (unchanged): a bare pane_id can already belong to an
      # unrelated worker herdr handed it to after this task's own pane
      # died, so only ever act on it when the live occupant's terminal_id
      # still matches what this row registered -- a list that fails or
      # does not parse must never fail OPEN into closing by bare id.
      registered_birth=$(printf '%s' "$row" | jq -r '.pane_birth // empty')
      pane_list_json="$(herdr pane list 2>/dev/null)"
      if [ $? -ne 0 ] || [ -z "$pane_list_json" ]; then
        echo "registry-bridge: cancel $run_id/$task_id -- herdr pane list failed; leaving the row non-terminal for the next retry (backoff)" >&2
        exit 1
      fi
      if ! live_birth="$(printf '%s' "$pane_list_json" | jq -r --arg p "$pane" \
          '(.result.panes // .panes)[]? | select(.pane_id==$p) | .terminal_id // empty' 2>/dev/null)"; then
        echo "registry-bridge: cancel $run_id/$task_id -- herdr pane list did not parse; leaving the row non-terminal for the next retry (backoff)" >&2
        exit 1
      fi
      if [ -n "$live_birth" ] && [ "$live_birth" = "$registered_birth" ]; then
        # Still our own live pane: close it, then re-list to PROVE it is
        # actually gone (or recycled to someone else) before we claim victory.
        [ -x "$HERE/claim.sh" ] && HERDR_PANE_ID="$pane" "$HERE/claim.sh" drop >/dev/null 2>&1
        if ! herdr pane close "$pane" >/dev/null 2>&1; then
          echo "registry-bridge: cancel $run_id/$task_id -- herdr pane close failed; leaving the row non-terminal for the next retry (backoff)" >&2
          exit 1
        fi
        post_list_json="$(herdr pane list 2>/dev/null)"
        if [ $? -ne 0 ] || [ -z "$post_list_json" ]; then
          echo "registry-bridge: cancel $run_id/$task_id -- post-close herdr pane list failed; leaving the row non-terminal for the next retry (backoff)" >&2
          exit 1
        fi
        if ! post_birth="$(printf '%s' "$post_list_json" | jq -r --arg p "$pane" \
            '(.result.panes // .panes)[]? | select(.pane_id==$p) | .terminal_id // empty' 2>/dev/null)"; then
          echo "registry-bridge: cancel $run_id/$task_id -- post-close herdr pane list did not parse; leaving the row non-terminal for the next retry (backoff)" >&2
          exit 1
        fi
        if [ -n "$post_birth" ] && [ "$post_birth" = "$registered_birth" ]; then
          echo "registry-bridge: cancel $run_id/$task_id -- pane $pane is still alive after the close; leaving the row non-terminal for the next retry (backoff)" >&2
          exit 1
        fi
        # post_birth empty (pane genuinely gone) or different (recycled to
        # a new occupant) -- either way, confirmed: nothing of ours remains.
      fi
      # live_birth empty (already gone before we even tried) or different
      # from registered_birth (already recycled) -- nothing of ours to
      # kill; proceed straight to marking the row cancelled.
    fi
    set_task_state "$run_id" "$task_id" cancelled "$reason" || exit 1
    ;;
  append-event)
    type_arg="$3"; payload="${4:-}"; [ -n "$payload" ] || payload='{}'
    append_event "$1" "$2" "$type_arg" "$payload" || exit 1
    ;;

  *)
    echo "registry-bridge: unknown subcommand '$cmd'" >&2
    exit 2
    ;;
esac
