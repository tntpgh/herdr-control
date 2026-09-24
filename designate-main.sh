#!/usr/bin/env bash
# designate-main.sh — record which pane is "Main", the operator-facing
# conductor that the attention controller escalates to.
#
#   designate-main.sh              # this pane ($HERDR_PANE_ID) becomes Main
#   designate-main.sh w19:p1       # a named pane becomes Main
#   designate-main.sh --show       # print the current designation
#   designate-main.sh --clear      # remove it (escalations are then skipped, recorded)
#
# Why a file and not config: Main's pane id changes every session, so a value
# in config.sh or the hub's launchd environment is stale by the next session.
# It stayed empty in practice, and every escalation was recorded as "Main
# could not be reached" (2026-09-24). config.sh reads this file whenever
# HERDR_MAIN_PANE_ID is not set explicitly, and attention-tick.sh re-sources
# config.sh every tick, so a new designation takes effect on the next pass
# with no hub restart.
#
# The pane's birth fingerprint (herdr terminal_id) is stored with it.
# attention-tick.sh refuses to send on a POSITIVE birth mismatch, so a
# designation left behind by a Main that exited cannot deliver into whatever
# process later reuses that pane id. It records attention_escalation_refused
# instead. This is the minimal slice of plan item 4 (role addresses).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/run-registry.sh
source "$HERE/lib/run-registry.sh"
# shellcheck source=lib/pane-guard.sh
source "$HERE/lib/pane-guard.sh"

role_file="$(run_state_root)/roles/main"

case "${1:-}" in
  --show)
    if [ -s "$role_file" ]; then cat "$role_file"; else echo "(no Main designated)"; fi
    exit 0 ;;
  --clear)
    rm -f "$role_file"; echo "Main designation cleared"; exit 0 ;;
  -h|--help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

pane="${1:-${HERDR_PANE_ID:-}}"
[ -n "$pane" ] || { echo "designate-main: no pane (set HERDR_PANE_ID or pass one)" >&2; exit 2; }
pane_is_agent "$pane" || { echo "designate-main: $pane is not running an agent; refusing" >&2; exit 3; }
birth="$(pane_birth_now "$pane")"
[ -n "$birth" ] || { echo "designate-main: could not read $pane's birth fingerprint; refusing" >&2; exit 3; }

tmp="$role_file.tmp.$$"
mkdir -p "$(dirname "$role_file")" && printf '%s %s\n' "$pane" "$birth" > "$tmp" && mv -f "$tmp" "$role_file" \
  || { rm -f "$tmp"; echo "designate-main: could not write $role_file" >&2; exit 1; }
echo "Main = $pane (birth $birth)"
