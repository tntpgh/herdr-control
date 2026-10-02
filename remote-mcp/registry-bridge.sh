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

# CANCEL_STUCK_THRESHOLD — REVIEW-213 F6: retry is correct (the caller's
# own sweep tick re-issues cancel until it lands, by design); an
# unbounded SILENT retry is not. After this many consecutive
# cancel_attempt_failed events for one task, emit a single cancel_stuck
# event (never a second one) as the alert the old code never raised.
CANCEL_STUCK_THRESHOLD=5

# _pane_list_lookup <pane_list_json> <pane_id>
#
# REVIEW-213 Fz (conductor follow-up on F1/F2): a VALID-JSON herdr pane
# list response in the WRONG SHAPE — an error envelope, a renamed key, a
# pane entry missing terminal_id — used to be indistinguishable from
# "queried fine, pane genuinely not found," because the old inline jq
# query's `(.result.panes // .panes)[]?` silently produces NOTHING for
# any of those shapes (the `?` swallows the type error) and empty output
# was read as "pane gone." This function makes that distinction
# explicit instead of collapsing it in one query:
#
#   return 2  — not an array at all (error envelope, renamed key, …):
#               UNPARSEABLE, never "gone."
#   prints "ABSENT"       — the list parsed; no entry has this pane_id.
#   prints "FOUND\t<terminal_id>\t<agent_session>" — an entry with this
#               pane_id exists; either field may be empty if the entry
#               itself omits it (a found-but-unreadable-field pane is
#               still "FOUND," never "ABSENT" — the caller decides what
#               an empty terminal_id means, but it must never mean gone).
_pane_list_lookup() {
  local list_json="$1" pane_id="$2" entry term sess
  printf '%s' "$list_json" | jq -e '(.result.panes // .panes) | type == "array"' >/dev/null 2>&1 || return 2
  entry="$(printf '%s' "$list_json" | jq -c --arg p "$pane_id" \
    '[(.result.panes // .panes)[] | select(.pane_id==$p)][0] // null' 2>/dev/null)" || return 2
  if [ -z "$entry" ] || [ "$entry" = "null" ]; then
    printf 'ABSENT\n'
    return 0
  fi
  term="$(printf '%s' "$entry" | jq -r '.terminal_id // empty' 2>/dev/null)"
  sess="$(printf '%s' "$entry" | jq -r '.agent_session.value // empty' 2>/dev/null)"
  printf 'FOUND\t%s\t%s\n' "$term" "$sess"
}

# _cancel_attempt_failed <run_id> <task_id> <reason>
#
# REVIEW-213 F6: always records the attempt (append_event is cheap,
# structured, not the noise this is about); only ECHOES to stderr when
# the reason actually changed since the last attempt (one line per
# distinct failure mode, not one per 15s tick); and once
# CANCEL_STUCK_THRESHOLD consecutive failures land, appends ONE
# cancel_stuck event as the alert signal the old code never raised.
# Caller still `exit 1`s after calling this — this only logs/records.
_cancel_attempt_failed() {
  local run_id="$1" task_id="$2" reason="$3" last n already
  last="$(task_last_event_payload "$run_id" "$task_id" cancel_attempt_failed | jq -r '.reason // empty' 2>/dev/null)"
  append_event "$run_id" "$task_id" cancel_attempt_failed \
    "$(jq -nc --arg r "$reason" '{reason:$r}')" >/dev/null 2>&1
  if [ "$last" != "$reason" ]; then
    echo "registry-bridge: cancel $run_id/$task_id -- $reason; leaving the row non-terminal for the next retry (backoff)" >&2
  fi
  n="$(task_event_count "$run_id" "$task_id" cancel_attempt_failed)"
  if [ "${n:-0}" -ge "$CANCEL_STUCK_THRESHOLD" ]; then
    already="$(task_event_count "$run_id" "$task_id" cancel_stuck)"
    if [ "${already:-0}" = 0 ]; then
      append_event "$run_id" "$task_id" cancel_stuck \
        "$(jq -nc --arg r "$reason" --argjson n "$n" '{reason:$r, attempts:$n}')" >/dev/null 2>&1
      echo "registry-bridge: cancel $run_id/$task_id -- STUCK after $n consecutive failures (latest: $reason); alerting once, will keep retrying" >&2
    fi
  fi
}


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
    # REVIEW-213 F2: refuse a TERMINAL row before ever touching a pane.
    # The old order ran herdr pane close FIRST and let set_task_state's
    # own _legal_transition refuse the write only at the very END — a
    # FINISHED task's still-open pane (e.g. close-done's safe-autoclose
    # refused on a dirty worktree) could be closed by a late/duplicate/
    # hard-stop-timer cancel landing after completion, before the refusal
    # ever fired. Nothing downstream of this row's own terminal state is
    # ours to touch. (lib/run-registry.sh's local terminal set, per
    # prune_completed_tasks' own WHERE clause: completed/failed/
    # cancelled/lost.)
    row_state=$(printf '%s' "$row" | jq -r '.state // empty')
    case "$row_state" in
      cancelled)
        # R2-2 (round-2 review of F2): cancel is idempotent against a row
        # ALREADY cancelled -- a duplicate/retried cancel (the exact case
        # F6's own retry loop produces) must succeed quietly, not refuse.
        # Refusing here made a second cancel ack 'failed', which ZR1's
        # retry loop re-queued, which eventually raised a false
        # cancel_stuck alert for a task that was already fully cancelled.
        exit 0
        ;;
      completed|failed|lost)
        echo "registry-bridge: cancel $run_id/$task_id -- already terminal ($row_state); refusing before touching any pane" >&2
        exit 1
        ;;
    esac
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
    # occupant -- BEFORE the row is ever marked cancelled. Any list
    # failure, unparseable/wrong-shaped response, close failure, or a pane
    # that is STILL the registered occupant after the close leaves this
    # row NON-TERMINAL and exits nonzero: the caller (tasks.py _cancel/
    # _force_cancel) reports `failed`, and the next sweep tick retries it
    # -- this is the retry/backoff path (F6), not a bug.
    pane=$(printf '%s' "$row" | jq -r '.pane_id // empty')
    registered_birth=$(printf '%s' "$row" | jq -r '.pane_birth // empty')
    reg_session=$(printf '%s' "$row" | jq -r '.agent_session // empty')
    if [ -z "$pane" ]; then
      # REVIEW-213 F1: no pane_id on record at all -- nothing to
      # positively identify as ours OR as gone. Fail closed rather than
      # assume there is nothing to kill; F6's cap/alert is what keeps
      # this from looping silently forever if a row genuinely never gets
      # a pane_id.
      _cancel_attempt_failed "$run_id" "$task_id" no_pane_id_on_record
      exit 1
    fi
    pane_list_json="$(herdr pane list 2>/dev/null)"
    if [ $? -ne 0 ] || [ -z "$pane_list_json" ]; then
      _cancel_attempt_failed "$run_id" "$task_id" pane_list_failed
      exit 1
    fi
    lookup="$(_pane_list_lookup "$pane_list_json" "$pane")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      # REVIEW-213 Fz: a valid-JSON response in the wrong shape (error
      # envelope, renamed key, …) is a shape failure, never "pane gone."
      _cancel_attempt_failed "$run_id" "$task_id" pane_list_unparseable_or_wrong_shape
      exit 1
    fi
    pane_is_ours=0
    verify_mode=""
    if [ "$lookup" != "ABSENT" ]; then
      live_birth="$(printf '%s' "$lookup" | cut -f2)"
      live_session="$(printf '%s' "$lookup" | cut -f3)"
      if [ -z "$live_birth" ]; then
        # Fz: matched by pane_id but no readable terminal_id -- a pane we
        # can SEE is never "gone" just because one field is missing.
        _cancel_attempt_failed "$run_id" "$task_id" pane_found_terminal_id_missing
        exit 1
      fi
      if [ "$live_birth" = "$registered_birth" ]; then
        pane_is_ours=1; verify_mode=birth
      else
        # REVIEW-213 F1: terminal_id differs. herdr restarts reissue a
        # fresh terminal_id for every pane it re-enumerates on reconnect;
        # the agent process underneath never dies (lib/reconcile.sh:139-
        # 142). Corroborate via agent_session -- the identity that DOES
        # survive a restart -- the same way lib/reconcile.sh's own sweep
        # does, before concluding either way.
        if [ -n "$reg_session" ] && [ -n "$live_session" ]; then
          [ "$reg_session" = "$live_session" ] && { pane_is_ours=1; verify_mode=session; }
          # else: both sides report an agent_session and they DISAGREE --
          # confirmed a different occupant took this pane_id. pane_is_ours
          # stays 0, falls through to "nothing of ours" below.
        else
          # No corroboration available on at least one side -- genuinely
          # cannot tell. Never guess either way.
          _cancel_attempt_failed "$run_id" "$task_id" terminal_id_changed_no_corroboration
          exit 1
        fi
      fi
    fi
    if [ "$pane_is_ours" = 1 ]; then
      # Still our own live pane (confirmed by terminal_id or, across a
      # restart, by agent_session): close it, then re-list to PROVE it is
      # actually gone (or recycled to someone else) before claiming victory.
      [ -x "$HERE/claim.sh" ] && HERDR_PANE_ID="$pane" "$HERE/claim.sh" drop >/dev/null 2>&1
      if ! herdr pane close "$pane" >/dev/null 2>&1; then
        _cancel_attempt_failed "$run_id" "$task_id" pane_close_failed
        exit 1
      fi
      post_list_json="$(herdr pane list 2>/dev/null)"
      if [ $? -ne 0 ] || [ -z "$post_list_json" ]; then
        _cancel_attempt_failed "$run_id" "$task_id" post_close_pane_list_failed
        exit 1
      fi
      post_lookup="$(_pane_list_lookup "$post_list_json" "$pane")"; rc=$?
      if [ "$rc" -ne 0 ]; then
        _cancel_attempt_failed "$run_id" "$task_id" post_close_pane_list_unparseable_or_wrong_shape
        exit 1
      fi
      if [ "$post_lookup" != "ABSENT" ]; then
        post_birth="$(printf '%s' "$post_lookup" | cut -f2)"
        post_session="$(printf '%s' "$post_lookup" | cut -f3)"
        # Only a CONFIRMED different identity on the SAME signal that
        # verified pre-close counts as "gone" -- a present-but-empty
        # field (Fz) or the SAME identity (still ours) both stay
        # non-terminal. Comparing against the pre-close signal that
        # actually matched (not always registered_birth) avoids a false-
        # negative trap in the session-verified branch, where terminal_id
        # is KNOWN to already differ from registered_birth.
        confirmed_different=0
        if [ "$verify_mode" = birth ]; then
          [ -n "$post_birth" ] && [ "$post_birth" != "$registered_birth" ] && confirmed_different=1
        else
          [ -n "$post_session" ] && [ "$post_session" != "$reg_session" ] && confirmed_different=1
        fi
        if [ "$confirmed_different" != 1 ]; then
          _cancel_attempt_failed "$run_id" "$task_id" pane_still_alive_after_close
          exit 1
        fi
      fi
      # post_lookup ABSENT (genuinely gone) or confirmed a different
      # occupant -- either way, nothing of ours remains.
    fi
    # pane_is_ours stayed 0 (genuinely absent, or confirmed a different
    # occupant by two independent live signals) -- nothing of ours to
    # kill; proceed straight to marking the row cancelled.
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
