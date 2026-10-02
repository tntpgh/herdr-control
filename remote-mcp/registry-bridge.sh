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
      #
      # N5: pane_birth_now (lib/pane-guard.sh) swallows `herdr pane list`'s
      # own exit code -- empty there means EITHER "pane gone" or "list
      # failed," and treating a transient list failure as "gone" would
      # fail OPEN into closing by bare id. Re-run the list here ourselves
      # so a failed/unparseable list skips the close instead.
      #
      # R3-6: a non-JSON list with rc 0 made jq itself fail silently
      # (stderr suppressed) while `live_birth` just read empty -- which
      # looked identical to "jq succeeded, pane genuinely absent" and still
      # fail-opened into closing by bare id. Capture jq's own exit status
      # (pipefail is set at the top of this file) and only close when jq
      # actually succeeded.
      registered_birth=$(printf '%s' "$row" | jq -r '.pane_birth // empty')
      pane_list_json="$(herdr pane list 2>/dev/null)"
      if [ $? -eq 0 ] && [ -n "$pane_list_json" ]; then
        if live_birth="$(printf '%s' "$pane_list_json" | jq -r --arg p "$pane" \
            '(.result.panes // .panes)[]? | select(.pane_id==$p) | .terminal_id // empty' 2>/dev/null)"; then
          if [ -z "$live_birth" ] || [ "$live_birth" = "$registered_birth" ]; then
            [ -x "$HERE/claim.sh" ] && HERDR_PANE_ID="$pane" "$HERE/claim.sh" drop >/dev/null 2>&1
            herdr pane close "$pane" >/dev/null 2>&1 || true
          fi
        fi
      fi
    fi
    ;;
  *)
    echo "registry-bridge: unknown subcommand '$cmd'" >&2
    exit 2
    ;;
esac
