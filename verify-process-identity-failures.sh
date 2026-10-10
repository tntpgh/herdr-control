#!/usr/bin/env bash
# Identity fixtures only: every herdr/ps call is intercepted. No live panes,
# designation, outside-human force, network or process inspection is used.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/herdr-identity.XXXXXX")
trap 'rm -rf "$work"' EXIT
export HERDR_RUN_STATE_DIR="$work/runs" XDG_RUNTIME_DIR="$work/runtime"
export INFO_PAYLOAD PANES_PAYLOAD INFO_FAILURE=0 LIST_FAILURE=0 SECOND_INFO=''
passed=0 failed=0
expect_identity() {
  local label="$1" expected="$2" wanted="${3:-}" result rc
  result="$(caller_pane_from_ancestry)"; rc=$?
  if [ "$rc" = "$expected" ] && [ "$result" = "$wanted" ]; then
    printf 'PASS %s: rc=%s, expected caller result\n' "$label" "$rc"
    passed=$((passed+1))
  else
    printf 'FAIL %s: expected rc=%s result=%s; got rc=%s result=%s\n' "$label" "$expected" "$wanted" "$rc" "$result" >&2
    failed=$((failed+1))
  fi
}
expect_unknown() { expect_identity "$1" 1; }
herdr() {
  case "$1 $2" in
    'pane list') [ "$LIST_FAILURE" = 0 ] || return 1; printf '%s' "$PANES_PAYLOAD" ;;
    'pane process-info')
      [ "$INFO_FAILURE" = 0 ] || return 1
      if [ "${4:-}" = fixture:p2 ]; then printf '%s' "$SECOND_INFO"; else printf '%s' "$INFO_PAYLOAD"; fi ;;
    *) return 99 ;;
  esac
}
export -f herdr
PANES_PAYLOAD='{"panes":[{"pane_id":"fixture:p1"}]}'
INFO_PAYLOAD="$(printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s}]}}}' "$PPID")"
matching="$INFO_PAYLOAD"
# Even a matching partial ancestor cannot establish identity after ps failure.
ps() { return 1; }
expect_unknown 'ps unavailable with matching partial ancestry'
ps() { printf 'not-a-pid'; }
expect_unknown 'malformed parent pid'
ps() { printf '%s' "$PPID"; }
HERDR_ANCESTOR_WALK_MAX=2
expect_unknown 'cycle or truncated ancestor chain'
unset HERDR_ANCESTOR_WALK_MAX
ps() { printf '1\n'; }
export -f ps

expect_identity 'complete matching process inventory' 0 fixture:p1
for payload in 'not-json' '{}' '' 'null' '[]' '{"result":{}}' \
  '{"result":{"process_info":{}}}' \
  '{"result":{"process_info":{"foreground_processes":null}}}' \
  '{"result":{"process_info":{"foreground_processes":{}}}}' \
  '{"result":{"process_info":{"foreground_processes":[{}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":null}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":"123"}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":0}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":-1}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":1.5}]}}}'; do
  INFO_PAYLOAD="$payload"
  expect_unknown "incomplete or invalid process response: ${payload:-<empty>}"
done
INFO_PAYLOAD="$matching $matching"
expect_unknown 'multiple JSON process responses'
INFO_PAYLOAD="$(printf '%s' "$matching" | jq '.result.process_info.foreground_processes += [{}]')"
expect_unknown 'matching row cannot hide later incomplete process row'
INFO_PAYLOAD="$matching" INFO_FAILURE=1
expect_unknown 'process-info unavailable'
INFO_FAILURE=0
PANES_PAYLOAD='{"panes":[{"pane_id":"fixture:p1"},{"pane_id":"fixture:p2"}]}'
SECOND_INFO='{}'
expect_unknown 'matching pane cannot hide another unavailable pane inventory'
PANES_PAYLOAD='{"panes":[{"pane_id":"fixture:p1"}]}'
valid_panes="$PANES_PAYLOAD"
for payload in 'not-json' '{}' '{"panes":{}}' '{"panes":[{}]}' \
  '{"panes":[{"pane_id":""}]}' '{"panes":[{"pane_id":"fixture p1"}]}' \
  '{"panes":[{"pane_id":"fixture:p1"},{}]}'; do
  PANES_PAYLOAD="$payload"
  expect_unknown "incomplete or invalid pane inventory: $payload"
done
PANES_PAYLOAD="$valid_panes $valid_panes"
expect_unknown 'multiple JSON pane inventories'
for payload in '{"panes":[{"pane_id":"fixture:p1\n"}]}' \
  '{"panes":[{"pane_id":"fixture:p\u00001"}]}' \
  '{"panes":[{"pane_id":"*"}]}'; do
  PANES_PAYLOAD="$payload" INFO_PAYLOAD="$matching"
  expect_unknown "malformed identifier cannot normalize to matching caller: $payload"
  INFO_PAYLOAD='{"result":{"process_info":{"foreground_processes":[]}}}'
  expect_unknown "malformed identifier cannot prove outside caller: $payload"
done
PANES_PAYLOAD="$valid_panes" LIST_FAILURE=1
expect_unknown 'pane inventory unavailable'
LIST_FAILURE=0
INFO_PAYLOAD='{"result":{"process_info":{"foreground_processes":[{"pid":2147483000}]}}}'
expect_identity 'complete inventory and ancestry prove legitimate outside-Herdr caller' 2
INFO_PAYLOAD='{"result":{"process_info":{"foreground_processes":[]}}}'
expect_identity 'explicit empty foreground array is a complete no-match' 2

# Exercise the actual --force refusal boundary, never a force success. Both
# transport functions remain exported fixtures and all registry paths isolated.
# Checking this exact reason prevents a later target-validation refusal from
# masking the old, incorrect rc=2 caller classification.
for payload in 'not-json' '{}'; do
  INFO_PAYLOAD="$payload"
  out="$(bash "$here/designate-main.sh" --force fixture:p1 --reason fixture 2>&1)"; rc=$?
  if [ "$rc" = 3 ] && printf '%s' "$out" | grep -q -- '--force is only for a shell outside herdr'; then
    printf 'PASS force consumer refuses unavailable identity before target validation\n'
    passed=$((passed+1))
  else
    printf 'FAIL force consumer: expected caller refusal, got rc=%s %s\n' "$rc" "$out" >&2
    failed=$((failed+1))
  fi
done
printf 'passed=%s failed=%s; live designations=0\n' "$passed" "$failed"
[ "$failed" = 0 ]
