#!/usr/bin/env bash
# Negative-only process identity fixtures; no live panes or approval actions.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
passed=0
expect_unknown() {
  local result rc
  result="$(caller_pane_from_ancestry)"; rc=$?
  if [ "$rc" != 1 ] || [ -n "$result" ]; then
    printf 'FAIL %s: rc=%s result=%s\n' "$1" "$rc" "$result" >&2
    exit 1
  fi
  printf 'PASS %s: identity unavailable, no caller accepted\n' "$1"
  passed=$((passed+1))
}
herdr() {
  case "$2" in
    list) printf '{"panes":[{"pane_id":"fixture:p1"}]}' ;;
    process-info) printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s}]}}}' "$PPID" ;;
    *) return 1 ;;
  esac
}
# The closest ancestor even matches a fixture pane. An incomplete walk still
# must fail; partial output cannot prove an identity or an external human.
ps() { return 1; }
expect_unknown 'ps unavailable with matching partial ancestry'
ps() { printf 'not-a-pid'; }
expect_unknown 'malformed parent pid'
ps() { printf '%s' "$PPID"; }
HERDR_ANCESTOR_WALK_MAX=2
expect_unknown 'cycle or truncated ancestor chain'
printf 'passed=%s failed=0\n' "$passed"
