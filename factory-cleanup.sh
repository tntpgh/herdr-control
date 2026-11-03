#!/usr/bin/env bash
# factory-cleanup.sh — one conservative entry point for end-of-shift, daily,
# and weekly worker cleanup. DRY-RUN BY DEFAULT.
#
#   factory-cleanup.sh --cadence=shift [--conductor=w19:p7] [--apply]
#   factory-cleanup.sh --cadence=day   [--apply]
#   factory-cleanup.sh --cadence=week  [--apply]
#   factory-cleanup.sh --cadence=shift --summary   # "<closable> <held>"
#
# --apply closes only workers whose branch has a MERGED PR. conductor-exit.sh
# supplies the PR proof and close-done-workers.sh rechecks pane, git, approval,
# and evidence safety. Dirty, unpushed, open-PR, detached, or ambiguous work is
# printed and held; this tool never commits, pushes, deletes, or guesses.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CONDUCTOR_EXIT_SH=$HERE/conductor-exit.sh
CLOSE_DONE_SH=$HERE/close-done-workers.sh
HUB_URL=${HERDR_HUB_URL:-http://127.0.0.1:8600}
if [ "${HERDR_FACTORY_CLEANUP_TEST_MODE:-0}" = 1 ]; then
  CONDUCTOR_EXIT_SH=${HERDR_CONDUCTOR_EXIT_SH:-$CONDUCTOR_EXIT_SH}
  CLOSE_DONE_SH=${HERDR_CLOSE_DONE_SH:-$CLOSE_DONE_SH}
elif [ -n "${HERDR_CONDUCTOR_EXIT_SH:-}${HERDR_CLOSE_DONE_SH:-}" ]; then
  echo "factory-cleanup: dependency overrides require HERDR_FACTORY_CLEANUP_TEST_MODE=1" >&2
  exit 3
fi

cadence=shift
apply=0
summary=0
conductor="${HERDR_PANE_ID:-}"
conductor_explicit=0
cadence_explicit=0
for arg in "$@"; do
  case "$arg" in
    --cadence=*) cadence=${arg#--cadence=}; cadence_explicit=$((cadence_explicit+1)) ;;
    --shift) cadence=shift; cadence_explicit=$((cadence_explicit+1)) ;;
    --day) cadence=day; cadence_explicit=$((cadence_explicit+1)) ;;
    --week) cadence=week; cadence_explicit=$((cadence_explicit+1)) ;;
    --apply) apply=1 ;;
    --summary) summary=1 ;;
    --conductor=*) conductor=${arg#--conductor=}; conductor_explicit=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'factory-cleanup: unknown flag %s\n' "$arg" >&2; exit 2 ;;
  esac
done
[ "$cadence_explicit" -le 1 ] || {
  echo "factory-cleanup: cadence selectors are mutually exclusive" >&2
  exit 2
}


case "$cadence" in
  shift)
    [ -n "$conductor" ] || {
      echo "factory-cleanup: shift cleanup needs HERDR_PANE_ID or --conductor=<pane>" >&2
      exit 2
    }
    [[ "$conductor" =~ ^w[[:alnum:]]+:p[[:alnum:]]+$ ]] || {
      echo "factory-cleanup: invalid conductor pane '$conductor'" >&2
      exit 2
    }
    scope_args=("--conductor=$conductor")
    ;;
  day|week)
    [ "$conductor_explicit" = 0 ] || {
      echo "factory-cleanup: --conductor is valid only for shift cleanup" >&2
      exit 2
    }
    scope_args=(--all)
    ;;
  *) echo "factory-cleanup: --cadence must be shift, day, or week" >&2; exit 2 ;;
esac

[ -x "$CONDUCTOR_EXIT_SH" ] || { echo "factory-cleanup: missing $CONDUCTOR_EXIT_SH" >&2; exit 3; }
[ -x "$CLOSE_DONE_SH" ] || { echo "factory-cleanup: missing $CLOSE_DONE_SH" >&2; exit 3; }

if [ "$summary" = 1 ]; then
  exec bash "$CONDUCTOR_EXIT_SH" "${scope_args[@]}" --summary
fi

printf '== %s cleanup: merged-PR workers ==\n' "$cadence"
exit_rc=0
exit_args=("${scope_args[@]}")
[ "$apply" = 0 ] || exit_args+=(--apply)
bash "$CONDUCTOR_EXIT_SH" "${exit_args[@]}" || exit_rc=$?

printf '\n== global safety gate: everything still held ==\n'
bash "$CLOSE_DONE_SH" || {
  rc=$?
  [ "$exit_rc" = 0 ] && exit_rc=$rc
}

printf '\n== hub ==\n'
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  if hub=$(curl -fsS "$HUB_URL/api/summary" 2>/dev/null); then
    if ! printf '%s\n' "$hub" | jq -er '
      "attention=\(.attention // "?") tasks=\(.attention_tasks // "?") registry=\(.registry_attention // "?") handoff_debt=\(.handoff_debt // "?") decisions=\(.open_decisions // "?")"'
    then
      echo "hub returned invalid summary data (cleanup stayed fail-closed)"
    fi
  else
    echo "hub unavailable at $HUB_URL (cleanup stayed fail-closed)"
  fi
else
  echo "curl/jq unavailable; hub summary skipped"
fi

case "$cadence" in
  shift)
    echo "next: write every touched repo handoff; classify each HOLD before stopping"
    ;;
  day)
    echo "next: run xd://worktree_debt and xd://handoff_debt; push/rescue work before closing panes or removing worktrees"
    ;;
  week)
    echo "next: run xd://fleet_status, xd://worktree_debt, xd://single_copy_scan, and xd://handoff_debt; retire only evidence-backed leftovers"
    ;;
esac

[ "$apply" = 1 ] || echo "DRY RUN: re-run with --apply to close merged-PR workers only"
exit "$exit_rc"
