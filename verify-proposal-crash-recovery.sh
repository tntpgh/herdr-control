#!/usr/bin/env bash
# verify-proposal-crash-recovery.sh — pins the crash-consistency fix for the
# non-atomic gap in record_seen's proposal() closure (lib/prompt-occurrence.py):
# the prompt_occ_seen DB row commits strictly BEFORE _write_proposal writes
# proposals/<key>.json, so a writer that dies between those two steps (a
# crash, an OOM-kill, a SIGTERM to a long-running hub.py mid-event -- hub.py
# calls record_seen IN-PROCESS, not via subprocess) leaves a durably "seen"
# occurrence with no proposal file. Before the fix: `decide` failed closed
# (exit 8, no approvals row) with only a generic FileNotFoundError message,
# and nothing ever repaired the gap -- a retried `seen` with the identical
# payload silently no-opped as "duplicate". herdr-control
# debug/orch-decide-proposal-missing, 2026-10-19 (PROOF.md has the full
# investigation + the scratch-only fault-injection repro this generalizes).
#
# Fixture technique (per the fix brief): pre-create the DB row without the
# file by calling the REAL `seen` once (writes both) and then deleting the
# proposal file -- the exact end state a mid-write kill leaves, with zero
# test-only code paths in the shipped fix.
#
#   bash verify-proposal-crash-recovery.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_BRIDGE_STATE="$WORK/bridge"
DB="$HERDR_RUN_STATE_DIR/registry.sqlite3"
PROPOSALS_DIR="$HERDR_RUN_STATE_DIR/proposals"
SCREEN_DIR="$WORK/screens"; DETECTION_DIR="$WORK/detection"; COUNTER="$WORK/enter-count"
KEYS="$WORK/keys.log"; SENDTEXT="$WORK/send-text.log"
mkdir -p "$SCREEN_DIR" "$DETECTION_DIR"

HC_RAW=$(mktemp -d -p "$WORK"); git -C "$HC_RAW" init -q -b main 2>/dev/null
git -C "$HC_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
HC=$(cd "$HC_RAW" && pwd -P)
ORCH_WT="$WORK/orch-wt"; mkdir -p "$ORCH_WT/tmp"
CHILD_WT="$WORK/child-wt"; mkdir -p "$CHILD_WT"

MAIN_PANE="mainpane1"; MAIN_BIRTH="mainbirth1"
ORCH_PANE="orcpane1"; ORCH_BIRTH="orcbirth1"
CHILD_PANE="childpane1"; CHILD_BIRTH="childbirth1"
export MAIN_PANE MAIN_BIRTH ORCH_PANE ORCH_BIRTH CHILD_PANE CHILD_BIRTH
export SCREEN_DIR DETECTION_DIR COUNTER KEYS SENDTEXT WORK

_stub_ancestry() {
  case "$1 $2" in
    "pane process-info")
      local pid=999999
      [ "${4:-}" = "${HERDR_FIXTURE_CALLER_PANE:-}" ] && pid="$PPID"
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"claude","cmdline":"claude"}]}}}\n' "$pid" ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
        "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "$CHILD_PANE" "$CHILD_BIRTH" ;;
    *) return 1 ;;
  esac
}
herdr() {
  _stub_ancestry "$@" 2>/dev/null && return 0
  case "$1 $2" in
    "pane read") printf '❯\n' ;;
    "pane send-text") printf '%s\n' "$4" >>"$SENDTEXT" ;;
    "pane send-keys") printf '%s\n' "$4" >>"$KEYS" ;;
    *) return 0 ;;
  esac
}
ps() { printf '1\n'; }
export -f _stub_ancestry herdr ps

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

. "$here/lib/run-registry.sh"
. "$here/lib/claims.sh"
. "$here/tests/fixtures/task-authorization.sh"
registry_init >/dev/null

register_role_cas main "$MAIN_PANE" "$MAIN_BIRTH" sess ws "" "" >/dev/null
register_role_cas "orchestrator@herdr-control" "$ORCH_PANE" "$ORCH_BIRTH" sess ws "" "" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null

fixture_register_task run_child task_orch worker_orch conductor_main \
  "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "$HC" "$ORCH_WT" \
  orch-label orch-branch "" herdr-control "" hook >/dev/null || { echo "fixture: task_orch failed" >&2; exit 1; }
set_task_state run_child task_orch running >/dev/null

fixture_register_task run_child task_child worker_child conductor_main \
  "$ORCH_PANE" "$ORCH_BIRTH" "$CHILD_PANE" "$CHILD_BIRTH" "$HC" "$CHILD_WT" \
  child-label child-branch "" herdr-control "" hook >/dev/null || { echo "fixture: task_child failed" >&2; exit 1; }
set_task_state run_child task_child running >/dev/null

bash_input() { jq -nc --arg c "$1" '{command:$c}'; }
input_sha() { python3 - "$1" "$2" <<'PY'
import hashlib, json, sys
body = json.dumps({"tool": sys.argv[1], "input": json.loads(sys.argv[2]), "known": True},
                  sort_keys=True, separators=(",", ":"), default=str)
print(hashlib.sha256(body.encode()).hexdigest())
PY
}
OCC=(python3 "$here/lib/prompt-occurrence.py")

seen_once() {   # call_id req_id command -> echoes "DIGEST SHA" to stdout
  local call="$1" req="$2" cmd="$3"
  local input_json json digest sha
  input_json="$(bash_input "$cmd")"
  json="$(printf '%s' "$input_json" | jq -cS .)"
  digest="sha256:$(printf '%s' "$json" | shasum -a 256 | awk '{print $1}')"
  sha="$(input_sha bash "$input_json")"
  printf '%s' "$(jq -nc --argjson i "$input_json" --arg j "$json" '{input:$i,core_arguments_json:$j}')" \
    | "${OCC[@]}" seen --db "$DB" --run run_child --task task_child --pane "$CHILD_PANE" \
      --birth "$CHILD_BIRTH" --session "sess-cr" --call-id "$call" --tool bash --input-json - \
      --bound-envelope --approval-request-id "$req" --core-arguments-digest "$digest" \
      --binding-protocol "omp.tool-approval-binding.v1" --cwd "$CHILD_WT" \
      --dispatched-at-ms "$(python3 -c 'import time; print(int(time.time()*1000))')" >/dev/null
  printf '%s %s' "$digest" "$sha"
}
occ_key_for() {   # call_id -> occ_key from the registry
  sqlite3 "$DB" "SELECT json_extract(payload,'\$.occ_key') FROM events WHERE task_id='task_child' AND event_id LIKE 'prompt_occ_seen_%' AND json_extract(payload,'\$.tool_call_id')='$1';" 2>/dev/null
}
decide_once() {   # call_id req_id digest sha decision -> prints "RC OUT"
  local call="$1" req="$2" digest="$3" sha="$4" decision="${5:-approve}"
  jq -nc --arg req "$req" --arg call "$call" --arg dg "$digest" --arg sha "$sha" --arg dec "$decision" \
    '{approval_request_id:$req, tool_call_id:$call, arguments_digest:$dg, payload_sha:$sha, decision:$dec, category:"local-build", reason:"crash-recovery suite"}' \
    >"$ORCH_WT/tmp/decide-$call.json"
  local out rc
  out="$(( HERDR_FIXTURE_CALLER_PANE="$ORCH_PANE" HERDR_PANE_ID="$ORCH_PANE" \
    bash "$here/orch-dispatch-child.sh" decide "$CHILD_PANE" "$ORCH_WT/tmp/decide-$call.json" ) 2>&1)"; rc=$?
  printf '%s\x1f%s' "$rc" "$out"
}
# Excludes outcome='lost-race' on purpose: herdr-select.sh:349-356 /
# orch-approve-child.sh:306-312 deliberately write a SEPARATE audited row
# for a concurrent decide that lost the authorize-bound race (never a
# keystroke, never an execution -- lib/prompt-occurrence.py's
# _correlate_approval_actor excludes it the same way; verify-approval-payload.sh
# pins it as "the losing concurrent decision is explicitly audited"). That
# row is the CORRECT, intentional audit trail of a race happening, not the
# duplicate-approval bug this suite guards against.
approvals_count() { sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE choice_text='Approve' AND (outcome IS NULL OR outcome != 'lost-race');" 2>/dev/null || echo 0; }
lost_race_rows_for() { sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE prompt_id='$1' AND outcome='lost-race';" 2>/dev/null || echo 0; }
seen_rows_for() { sqlite3 "$DB" "SELECT count(*) FROM events WHERE task_id='task_child' AND event_id='prompt_occ_seen_$1';" 2>/dev/null || echo 0; }

printf '== CASE 1: DB row with no proposal file (simulated crash) -- decide fails closed with a named, recoverable reason; re-seen repairs; decide then succeeds exactly once ==\n'
read -r DIGEST1 SHA1 < <(seen_once call-c1 req-c1 "git status")
K1="$(occ_key_for call-c1)"
check "case1 setup: proposal file written by the real seen call" "$([ -e "$PROPOSALS_DIR/$K1.json" ] && echo yes || echo no)" "yes"
rm -f "$PROPOSALS_DIR/$K1.json"
check "case1 setup: proposal file now absent (simulated crash)" "$([ -e "$PROPOSALS_DIR/$K1.json" ] && echo yes || echo no)" "no"
check "case1 setup: prompt_occ_seen DB row still present" "$(seen_rows_for "$K1")" "1"

before1="$(approvals_count)"
IFS=$'\x1f' read -r rc1 out1 < <(decide_once call-c1 req-c1 "$DIGEST1" "$SHA1")
check "case1: decide fails closed (exit 8) with no file to approve against" "$rc1" "8"
check "case1: no approvals row from the failed-closed decide" "$(approvals_count)" "$before1"
printf '%s' "$out1" | grep -qF "recoverable" && ok "case1: refusal names the condition RECOVERABLE (not just a bare exception)" \
  || bad "case1: refusal did not name it recoverable -- got: $out1"
printf '%s' "$out1" | grep -qF "fresh \`seen\`" && ok "case1: refusal says exactly how to recover (re-issue seen)" \
  || bad "case1: refusal did not say how to recover -- got: $out1"

read -r DIGEST1b SHA1b < <(seen_once call-c1 req-c1 "git status")
check "case1: re-seen with the SAME payload is still the same occurrence key" "$(occ_key_for call-c1)" "$K1"
check "case1: re-seen REPAIRED the proposal file" "$([ -e "$PROPOSALS_DIR/$K1.json" ] && echo yes || echo no)" "yes"
check "case1: re-seen did NOT duplicate the prompt_occ_seen DB row" "$(seen_rows_for "$K1")" "1"

IFS=$'\x1f' read -r rc1r out1r < <(decide_once call-c1 req-c1 "$DIGEST1b" "$SHA1b")
check "case1: decide now succeeds exactly once (exit 0)" "$rc1r" "0"
check "case1: exactly one new approvals row" "$(approvals_count)" "$((before1 + 1))"
printf '%s' "$out1r" | jq -e '.resolved == true and .decision == "Approve"' >/dev/null \
  && ok "case1: resolved JSON reports Approve" || bad "case1: unexpected output: $out1r"

printf '\n== CASE 2: retried seen is idempotent (same payload); a DIFFERENT payload on the same key is refused, never silently overwriting ==\n'
read -r DIGEST2 SHA2 < <(seen_once call-c2 req-c2 "git status")
K2="$(occ_key_for call-c2)"
content_before="$(cat "$PROPOSALS_DIR/$K2.json" 2>/dev/null)"
mtime_before="$(stat -f %m "$PROPOSALS_DIR/$K2.json" 2>/dev/null)"
sleep 1
read -r DIGEST2dup SHA2dup < <(seen_once call-c2 req-c2 "git status")
check "case2: idempotent retry keeps the identical payload digest" "$DIGEST2dup" "$DIGEST2"
content_after="$(cat "$PROPOSALS_DIR/$K2.json" 2>/dev/null)"
check "case2: idempotent retry leaves the proposal file BYTE-IDENTICAL (no rewrite)" "$content_after" "$content_before"
mtime_after="$(stat -f %m "$PROPOSALS_DIR/$K2.json" 2>/dev/null)"
check "case2: idempotent retry does not even touch the file (mtime unchanged -- _write_proposal's exists() fast path, not a rewrite)" "$mtime_after" "$mtime_before"
check "case2: idempotent retry does not duplicate the DB row" "$(seen_rows_for "$K2")" "1"

seen_once call-c2 req-c2 "git log -1" >/dev/null
mismatch_rows="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE task_id='task_child' AND type='prompt_occ_mismatch' AND json_extract(payload,'\$.occ_key')='$K2';" 2>/dev/null)"
check "case2: a DIFFERENT payload on the same key is recorded as a mismatch" "$mismatch_rows" "1"
content_after_mismatch="$(cat "$PROPOSALS_DIR/$K2.json" 2>/dev/null)"
check "case2: the mismatch NEVER overwrote the original proposal file" "$content_after_mismatch" "$content_before"

printf '\n== CASE 3: concurrent decides on the SAME key never produce more than one approvals row ==\n'
read -r DIGEST3 SHA3 < <(seen_once call-c3 req-c3 "git status")
before3="$(approvals_count)"
rm -f "$WORK/case3-a.out" "$WORK/case3-b.out"
( decide_once call-c3 req-c3 "$DIGEST3" "$SHA3" >"$WORK/case3-a.out" ) &
pidA=$!
( decide_once call-c3 req-c3 "$DIGEST3" "$SHA3" >"$WORK/case3-b.out" ) &
pidB=$!
wait "$pidA" "$pidB"
after3="$(approvals_count)"
check "case3: concurrent same-key decides produce EXACTLY one new (non-lost-race) approvals row" "$after3" "$((before3 + 1))"
check "case3: the losing decide is explicitly audited as lost-race, not silently dropped" "$(lost_race_rows_for req-c3)" "1"
outA="$(cat "$WORK/case3-a.out" 2>/dev/null)"; outB="$(cat "$WORK/case3-b.out" 2>/dev/null)"
approved_count=0
printf '%s' "$outA" | cut -d$'\x1f' -f2 | jq -e '.resolved == true and .decision == "Approve"' >/dev/null 2>&1 && approved_count=$((approved_count + 1))
printf '%s' "$outB" | cut -d$'\x1f' -f2 | jq -e '.resolved == true and .decision == "Approve"' >/dev/null 2>&1 && approved_count=$((approved_count + 1))
check "case3: exactly ONE of the two racing decides reports resolved Approve (the other sees it already closed)" "$approved_count" "1"

printf '\n== CASE 4: concurrent repairing seen calls on a crashed (file-missing) key never corrupt the proposal file ==\n'
read -r DIGEST4 SHA4 < <(seen_once call-c4 req-c4 "git status")
K4="$(occ_key_for call-c4)"
rm -f "$PROPOSALS_DIR/$K4.json"
( seen_once call-c4 req-c4 "git status" >/dev/null ) &
pidC=$!
( seen_once call-c4 req-c4 "git status" >/dev/null ) &
pidD=$!
wait "$pidC" "$pidD"
check "case4: concurrent repair leaves exactly one, valid proposal file" \
  "$(python3 -c "import json,sys; json.load(open('$PROPOSALS_DIR/$K4.json')); print('valid')" 2>&1)" "valid"
check "case4: concurrent repair still has exactly one prompt_occ_seen DB row" "$(seen_rows_for "$K4")" "1"
check "case4: the repaired file's occ_key matches" \
  "$(python3 -c "import json; print(json.load(open('$PROPOSALS_DIR/$K4.json'))['occ_key'])")" "$K4"

printf '\n-----\npassed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
