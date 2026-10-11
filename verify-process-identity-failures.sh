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
export RAW_PANES=0 RAW_INFO=0 INFO_FILE=''
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
    'pane list')
      [ "$LIST_FAILURE" != 1 ] || return 1
      if [ "$RAW_PANES" = 1 ]; then printf '%b' "$PANES_PAYLOAD"; else printf '%s' "$PANES_PAYLOAD"; fi
      [ "$LIST_FAILURE" = 0 ] ;;
    'pane process-info')
      [ "$INFO_FAILURE" != 1 ] || return 1
      if [ "${4:-}" = fixture:p2 ]; then printf '%s' "$SECOND_INFO"
      elif [ -n "$INFO_FILE" ]; then cat "$INFO_FILE"
      elif [ "$RAW_INFO" = 1 ]; then printf '%b' "$INFO_PAYLOAD"; else printf '%s' "$INFO_PAYLOAD"; fi
      [ "$INFO_FAILURE" = 0 ] ;;
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
# Stream a large fixture from disk, avoiding exported-payload/ARG_MAX effects.
# The first row matches, but the lookup must still drain its pipe under pipefail.
python3 -I -S -c 'import json,sys
rows=[{"pid":int(sys.argv[1])}]+[{"pid":n} for n in range(1000000,1020000)]
with open(sys.argv[2],"w") as f: json.dump({"result":{"process_info":{"foreground_processes":rows}}},f)
' "$PPID" "$work/large-processes.json"
INFO_FILE="$work/large-processes.json"
expect_identity 'large complete matching inventory does not fail from SIGPIPE' 0 fixture:p1
INFO_FILE=''
awk() { return 1; }
expect_unknown 'process map lookup unavailable'
unset -f awk

# Worker-controlled CWD/PYTHONPATH must not supply parser modules or startup
# hooks. This fake decoder would convert missing process data into rc=2.
mkdir -p "$work/import-shadow"
cat > "$work/import-shadow/json.py" <<'PY'
def loads(raw, **kwargs):
    if 'pane_id' in raw:
        return {'panes': [{'pane_id': 'fixture:p1'}]}
    return {'result': {'process_info': {'foreground_processes': []}}}
PY
saved_dir="$PWD"
cd "$work/import-shadow"
expect_identity 'repository json module cannot replace stdlib for matching caller' 0 fixture:p1
INFO_PAYLOAD='{}'
expect_unknown 'repository json module cannot forge complete no-match'
cd "$saved_dir"
saved_pythonpath="${PYTHONPATH-}" pythonpath_was_set="${PYTHONPATH+x}"
export PYTHONPATH="$work/import-shadow"
expect_unknown 'PYTHONPATH json module cannot forge complete no-match'
INFO_PAYLOAD="$matching"
expect_identity 'PYTHONPATH does not break valid matching identity' 0 fixture:p1
if [ "$pythonpath_was_set" = x ]; then export PYTHONPATH="$saved_pythonpath"; else unset PYTHONPATH; fi
for payload in 'not-json' '{}' '' 'null' '[]' '{"result":{}}' \
  '{"result":{"process_info":{}}}' \
  '{"result":{"process_info":{"foreground_processes":null}}}' \
  '{"result":{"process_info":{"foreground_processes":{}}}}' \
  '{"result":{"process_info":{"foreground_processes":[{}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":null}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":"123"}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":0}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":-1}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":1.5}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":2147483648}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":1e10000}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":1e-10000}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":Infinity}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":NaN}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":true}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[{"pid":1.0}]}}}' \
  '{"result":{"process_info":{"foreground_processes":[],"foreground_processes":[]}}}'; do
  INFO_PAYLOAD="$payload"
  expect_unknown "incomplete or invalid process response: ${payload:-<empty>}"
done
INFO_PAYLOAD="$(printf '{"result":{"process_info":{"foreground_processes":[{"pid":+%s}]}}}' "$PPID")"
expect_unknown 'non-JSON plus-prefixed PID cannot identify caller'
INFO_PAYLOAD="$(printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s.000000000000001}]}}}' "$PPID")"
expect_unknown 'fractional PID must not round to matching caller'
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
# Emit raw NUL bytes from the transport fixture itself: shell variables and
# escaped JSON strings cannot reproduce Bash's lossy pre-validation capture.
RAW_PANES=1
for payload in '{"panes":[{"pane_id":"fixture:p\0001"}]}' \
  '\000{"panes":[{"pane_id":"fixture:p1"}]}' \
  '{"panes":[{"pane_id":"fixture:p1"}]}\000' \
  '{"panes":[{"pane_id":"fixture:p1","label":"\377"}]}'; do
  PANES_PAYLOAD="$payload" INFO_PAYLOAD="$matching"
  expect_unknown 'malformed raw pane transport cannot normalize to matching caller'
  INFO_PAYLOAD='{"result":{"process_info":{"foreground_processes":[]}}}'
  expect_unknown 'malformed raw pane transport cannot prove outside caller'
done
RAW_PANES=0 PANES_PAYLOAD="$valid_panes" RAW_INFO=1
for payload in '{"result":{"process_info":{"foreground_pro\000cesses":[]}}}' \
  '{"result":{"process_info":{"foreground_processes":[]}}}\000' \
  '\000{"result":{"process_info":{"foreground_processes":[]}}}' \
  '{"result":{"process_info":{"foreground_processes":[],"label":"\377"}}}'; do
  INFO_PAYLOAD="$payload"
  expect_unknown 'malformed raw process transport cannot prove outside caller'
done
INFO_PAYLOAD="${matching/foreground_processes/foreground_pro\\000cesses}"
expect_unknown 'raw NUL process transport cannot normalize to matching caller'
RAW_INFO=0 INFO_PAYLOAD="$matching" INFO_FAILURE=2
expect_unknown 'valid process JSON followed by producer failure'
INFO_FAILURE=0 LIST_FAILURE=2
expect_unknown 'valid pane JSON followed by producer failure'
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
for transport in pane process pane_utf8 process_utf8; do
  RAW_PANES=0 RAW_INFO=0 PANES_PAYLOAD="$valid_panes"
  INFO_PAYLOAD='{"result":{"process_info":{"foreground_processes":[]}}}'
  if [ "$transport" = pane ]; then
    RAW_PANES=1 PANES_PAYLOAD='{"panes":[{"pane_id":"fixture:p\0001"}]}'
  elif [ "$transport" = process ]; then
    RAW_INFO=1 INFO_PAYLOAD='{"result":{"process_info":{"foreground_pro\000cesses":[]}}}'
  elif [ "$transport" = pane_utf8 ]; then
    RAW_PANES=1 PANES_PAYLOAD='{"panes":[{"pane_id":"fixture:p1","label":"\377"}]}'
  else
    RAW_INFO=1 INFO_PAYLOAD='{"result":{"process_info":{"foreground_processes":[],"label":"\377"}}}'
  fi
  out="$(bash "$here/designate-main.sh" --force fixture:p1 --reason fixture 2>&1)"; rc=$?
  if [ "$rc" = 3 ] && printf '%s' "$out" | grep -q -- '--force is only for a shell outside herdr'; then
    printf 'PASS force consumer refuses malformed raw %s transport at caller gate\n' "$transport"
    passed=$((passed+1))
  else
    printf 'FAIL malformed raw force consumer: expected caller refusal, got rc=%s %s\n' "$rc" "$out" >&2
    failed=$((failed+1))
  fi
done
printf 'passed=%s failed=%s; live designations=0\n' "$passed" "$failed"
[ "$failed" = 0 ]
