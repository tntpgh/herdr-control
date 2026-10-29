#!/usr/bin/env bash
# no-progress-escalate.sh — the watchdog-cycle entrypoint for
# lib/escalation.sh: record one cycle's progress evidence, and when the
# fixed-cycle window shows no progress, hand off to the next model on the
# reviewed ladder (config.sh HERDR_ESCALATION_LADDER). Same split as
# stall-watchdog.sh: a caller (eventually hub.py's tick, same as the stall
# watchdog) supplies WHICH task and WHAT this cycle observed; this script
# owns the detection window and the escalation decision.
#
#   no-progress-escalate.sh tick <run_id> <task_id> \
#       --commit-sha <sha> --artifact-fp <fp> [--tool-fail-sig <sig>] \
#       [--denial-sig <sig>] [--waiting-on-human] \
#       [--agent claude|codex|omc|omp] [--dry-run] [--context-dir <dir>]
#
#     Records the cycle, runs no_progress_detect over the last
#     HERDR_NO_PROGRESS_CYCLES ticks, and escalates (lib/escalation.sh
#     esc_escalate) exactly when that reports a loop. Exit 0 whether or not
#     a loop fired (a watchdog cycle is not an error); exit 1 only on a
#     hard failure to record evidence at all.
#
#   no-progress-escalate.sh detect <run_id> <task_id>
#     Prints the current no_progress_detect verdict without recording a new
#     tick or escalating. For inspection / tests.
#
# --dry-run (or HERDR_ESCALATION_DRY_RUN=1) records the audit event and
# context packet but never quiesces the old pane or spawns a successor —
# no tier is consumed, so the real escalation can still happen later.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/config.sh"
. "$here/lib/escalation.sh"

usage() { printf 'usage: no-progress-escalate.sh tick|detect <run_id> <task_id> [opts]\n' >&2; exit 2; }

cmd_detect() {
  local run_id="${1:?run_id required}" task_id="${2:?task_id required}"
  no_progress_detect "$run_id" "$task_id"
}

cmd_tick() {
  local run_id="${1:?run_id required}" task_id="${2:?task_id required}"
  shift 2
  local commit_sha="" artifact_fp="" tool_fail_sig="" denial_sig="" waiting_on_human=0 \
        agent=claude dry_run="${HERDR_ESCALATION_DRY_RUN:-0}" context_dir="$here/.handoffs"
  while [ $# -gt 0 ]; do
    case "$1" in
      --commit-sha)     commit_sha="$2"; shift 2 ;;
      --artifact-fp)    artifact_fp="$2"; shift 2 ;;
      --tool-fail-sig)  tool_fail_sig="$2"; shift 2 ;;
      --denial-sig)     denial_sig="$2"; shift 2 ;;
      --waiting-on-human) waiting_on_human=1; shift ;;
      --agent)          agent="$2"; shift 2 ;;
      --dry-run)        dry_run=1; shift ;;
      --context-dir)    context_dir="$2"; shift 2 ;;
      *) printf 'no-progress-escalate.sh tick: unknown option %s\n' "$1" >&2; return 2 ;;
    esac
  done

  no_progress_tick "$run_id" "$task_id" "$commit_sha" "$artifact_fp" "$tool_fail_sig" "$waiting_on_human" "$denial_sig" \
    || { printf 'no-progress-escalate.sh: failed to record tick for %s\n' "$task_id" >&2; return 1; }

  local verdict loop reason
  verdict="$(no_progress_detect "$run_id" "$task_id")"
  loop="$(printf '%s' "$verdict" | jq -r '.loop')"
  reason="$(printf '%s' "$verdict" | jq -r '.reason')"
  printf '%s\n' "$verdict"
  if [ "$loop" != "true" ]; then
    return 0
  fi

  local evidence
  evidence="$(printf '%s' "$verdict" | jq -c '{cycles:.cycles, window:.window}')"
  esc_escalate "$run_id" "$task_id" "$agent" "$reason" "$evidence" "$dry_run" "$context_dir" || true
  return 0
}

case "${1:-}" in
  tick)   shift; cmd_tick "$@" ;;
  detect) shift; cmd_detect "$@" ;;
  *) usage ;;
esac
