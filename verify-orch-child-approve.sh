#!/usr/bin/env bash
# verify-orch-child-approve.sh — pins orch-approve-child.sh
# (.handoffs/SPEC.md "narrow orchestrator -> child approval interface"):
# a live bound orchestrator@<project> pane may review and resolve its OWN
# child's pending bound approval request, and ONLY that.
#
# Runs the REAL orch-approve-child.sh as a fresh bash process against a
# stubbed `herdr` (same ancestry-stub pattern verify-approval-payload.sh
# uses) and a throwaway registry (HERDR_RUN_STATE_DIR in mktemp — never
# the live registry). The property that matters on every negative case:
# NO approvals row is written, and the pending occurrence stays
# `requested` (still answerable afterward by a human through the normal
# path) -- a refusal must never silently consume the request.
#
#   bash verify-orch-child-approve.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

if [ ! -x "$here/.venv-bashlex/bin/python3" ] ||
   [ "$(printf 'true' | "$here/.venv-bashlex/bin/python3" "$here/lib/bashlex_classify.py" 2>/dev/null)" != ALLOW ]; then
  echo "PREREQ MISSING: $here/.venv-bashlex (bash parser helper); run install.sh --apply — suite not run" >&2
  exit 2
fi

WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_BRIDGE_STATE="$WORK/bridge"
DB="$HERDR_RUN_STATE_DIR/registry.sqlite3"

HC_RAW=$(mktemp -d -p "$WORK"); git -C "$HC_RAW" init -q -b main 2>/dev/null
git -C "$HC_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
KB_RAW=$(mktemp -d -p "$WORK"); git -C "$KB_RAW" init -q -b main 2>/dev/null
git -C "$KB_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
HC=$(cd "$HC_RAW" && pwd -P)
KB=$(cd "$KB_RAW" && pwd -P)
CHILD_WT="$WORK/child-wt"; mkdir -p "$CHILD_WT"
OTHER_WT="$WORK/other-wt"; mkdir -p "$OTHER_WT"
KB_WT="$WORK/kb-wt"; mkdir -p "$KB_WT"

MAIN_PANE="mainpane1"; MAIN_BIRTH="mainbirth1"
ORCH_PANE="orcpane1"; ORCH_BIRTH="orcbirth1"
CHILD_PANE="childpane1"; CHILD_BIRTH="childbirth1"
PLAIN_PANE="plainpane1"; PLAIN_BIRTH="plainbirth1"
OTHER_WORKER_PANE="otherworker1"; OTHER_WORKER_BIRTH="otherworkerbirth1"
KB_CHILD_PANE="kbchildpane1"; KB_CHILD_BIRTH="kbchildbirth1"
OTHER_ORCH_PANE="otherorchpane1"; OTHER_ORCH_BIRTH="otherorchbirth1"
# Exported: the stub below is an exported FUNCTION, re-executed inside the
# fresh `bash orch-approve-child.sh` subprocess each harness call spawns --
# its body crosses that boundary, but a plain (unexported) variable it
# closes over does not, so without this every fixture pane_id/birth would
# read back empty in the child and every ancestry resolution would refuse.
export MAIN_PANE MAIN_BIRTH ORCH_PANE ORCH_BIRTH CHILD_PANE CHILD_BIRTH \
  PLAIN_PANE PLAIN_BIRTH OTHER_WORKER_PANE OTHER_WORKER_BIRTH KB_CHILD_PANE KB_CHILD_BIRTH \
  OTHER_ORCH_PANE OTHER_ORCH_BIRTH

# ---- stub herdr: ancestry resolves to whichever pane HERDR_FIXTURE_CALLER_PANE
# names, exactly verify-approval-payload.sh's pattern (required so a caller's
# own PPID is reported as that pane's live foreground process). A static pane
# inventory covers every fixture pane's birth; "pane list" never changes.
_stub() {
  case "$1 $2" in
    "pane process-info")
      local pid=999999
      [ "${4:-}" = "${HERDR_FIXTURE_CALLER_PANE:-}" ] && pid="$PPID"
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"claude","cmdline":"claude"}]}}}\n' "$pid" ;;
    "pane list")
      printf '{"result":{"panes":[
        {"pane_id":"%s","terminal_id":"%s"},
        {"pane_id":"%s","terminal_id":"%s"},
        {"pane_id":"%s","terminal_id":"%s"},
        {"pane_id":"%s","terminal_id":"%s"},
        {"pane_id":"%s","terminal_id":"%s"},
        {"pane_id":"%s","terminal_id":"%s"},
        {"pane_id":"%s","terminal_id":"%s"}
      ]}}\n' \
        "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "$CHILD_PANE" "$CHILD_BIRTH" \
        "$PLAIN_PANE" "$PLAIN_BIRTH" "$OTHER_WORKER_PANE" "$OTHER_WORKER_BIRTH" \
        "$KB_CHILD_PANE" "$KB_CHILD_BIRTH" "$OTHER_ORCH_PANE" "$OTHER_ORCH_BIRTH" ;;
    *) printf '%s\n' "$*" >> "$WORK/herdr-calls.log"; return 0 ;;
  esac
}
herdr() { _stub "$@"; }
ps() { printf '1\n'; }
export -f _stub herdr ps

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

. "$here/lib/run-registry.sh"
. "$here/lib/claims.sh"
. "$here/tests/fixtures/task-authorization.sh"
registry_init >/dev/null

approve_rows() { sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE choice_text='Approve';" 2>/dev/null || echo 0; }
deny_rows() { sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE choice_text='Deny';" 2>/dev/null || echo 0; }
occ_lifecycle() { python3 "$here/lib/prompt-occurrence.py" fold --db "$DB" --run "$1" --task "$2" | jq -r --arg k "$3" '.[$k].lifecycle // empty'; }

# ---- fixtures: registry roles/claims -----------------------------------
register_role_cas main "$MAIN_PANE" "$MAIN_BIRTH" sess ws "" "" >/dev/null
register_role_cas "orchestrator@herdr-control" "$ORCH_PANE" "$ORCH_BIRTH" sess ws "" "" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null

# The orchestrator's own child: conductor_pane_id/birth = the orchestrator,
# repo = $HC (the orchestrator's claimed project), bound (hook), running --
# the exact shape bound-orchestrator mode routes a child approval wake to.
fixture_register_task run_child task_child worker_child conductor_main \
  "$ORCH_PANE" "$ORCH_BIRTH" "$CHILD_PANE" "$CHILD_BIRTH" "$HC" "$CHILD_WT" \
  child-label child-branch "" herdr-control "" hook >/dev/null || { echo "fixture: task_child failed" >&2; exit 1; }
set_task_state run_child task_child running >/dev/null

# A plain Main-conducted worker (control: "non-child" -- the orchestrator
# must never resolve a request it does not itself conduct).
fixture_register_task run_other task_other worker_other conductor_main \
  "$MAIN_PANE" "$MAIN_BIRTH" "$OTHER_WORKER_PANE" "$OTHER_WORKER_BIRTH" "$HC" "$OTHER_WT" \
  other-label other-branch "" herdr-control "" hook >/dev/null || { echo "fixture: task_other failed" >&2; exit 1; }
set_task_state run_other task_other running >/dev/null

# A task whose conductor is the SAME orchestrator pane but repo=$KB, a
# project the orchestrator holds NO live proj: claim for (cross-project
# control; this shape should never arise through set_task_conductor's own
# gate -- written directly here to test THIS script's independent re-check).
fixture_register_task run_kb task_kb worker_kb conductor_main \
  "$ORCH_PANE" "$ORCH_BIRTH" "$KB_CHILD_PANE" "$KB_CHILD_BIRTH" "$KB" "$KB_WT" \
  kb-label kb-branch "" knowledge-base "" hook >/dev/null || { echo "fixture: task_kb failed" >&2; exit 1; }
set_task_state run_kb task_kb running >/dev/null

# ---- pending-request fixture helpers (bound bash occurrences) -----------
OCC=(python3 "$here/lib/prompt-occurrence.py")
bash_input() { jq -nc --arg c "$1" '{command:$c}'; }
input_sha() { python3 - "$1" "$2" <<'PY'
import hashlib, json, sys
body = json.dumps({"tool": sys.argv[1], "input": json.loads(sys.argv[2]), "known": True},
                  sort_keys=True, separators=(",", ":"), default=str)
print(hashlib.sha256(body.encode()).hexdigest())
PY
}
CALL=0
# record_bash <run> <task> <pane> <birth> <worktree> <command> <request_id>
# -> sets CALL_ID, DIGEST, SHA (no screen/prompt id: the bound path never
# reads one, by construction -- proposal_check's bound_lookup branch never
# consults `display`).
record_bash() {
  local run="$1" task="$2" pane="$3" birth="$4" wt="$5" cmd="$6" req="$7"
  CALL=$((CALL + 1)); CALL_ID="call-$CALL"
  local input_json; input_json="$(bash_input "$cmd")"
  local json; json="$(printf '%s' "$input_json" | jq -cS .)"
  DIGEST="sha256:$(printf '%s' "$json" | shasum -a 256 | awk '{print $1}')"
  SHA="$(input_sha bash "$input_json")"
  append_event "$run" "$task" input_required \
    "$(jq -nc --arg pid "noscreen-$CALL" '{message:"needs permission", prompt_id:$pid, command:"", tool:"bash"}')" >/dev/null 2>&1
  local id=(--db "$DB" --run "$run" --task "$task" --pane "$pane" --birth "$birth" --session "sess-$CALL" --call-id "$CALL_ID")
  local recorded_input; recorded_input="$(jq -nc --argjson i "$input_json" --arg j "$json" '{input:$i,core_arguments_json:$j}')"
  OCC_KEY="$(printf '%s' "$recorded_input" | "${OCC[@]}" seen "${id[@]}" --tool bash --input-json - --bound-envelope \
    --approval-request-id "$req" --core-arguments-digest "$DIGEST" --binding-protocol "omp.tool-approval-binding.v1" \
    --cwd "$wt" --dispatched-at-ms "$(python3 -c 'import time; print(int(time.time()*1000))')" | jq -r .occ_key)"
}

# ---- harness: run the REAL script as a fresh process ---------------------
decide_as() {   # <acting_pane> <child_pane> <req> <call_id> <digest> <sha> <decision> <category> <reason>
  ( HERDR_FIXTURE_CALLER_PANE="$1" HERDR_PANE_ID="$1" \
    bash "$here/orch-approve-child.sh" decide "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" )
}
review_as() {   # <acting_pane> <child_pane> <req> <call_id> <digest>
  ( HERDR_FIXTURE_CALLER_PANE="$1" HERDR_PANE_ID="$1" \
    bash "$here/orch-approve-child.sh" review "$2" "$3" "$4" "$5" )
}

printf '== POSITIVE: the bound orchestrator reviews and approves its own child'"'"'s read-only command ==\n'
record_bash run_child task_child "$CHILD_PANE" "$CHILD_BIRTH" "$CHILD_WT" "git status" "req-pos-1"
REQ="req-pos-1"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
review_out="$(review_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG")"; review_rc=$?
echo "$review_out" | grep -qF 'tool: bash' && echo "$review_out" | grep -qF 'git status' \
  && check "review step: rc 0" "$review_rc" "0" \
  || bad "review step: rc=$review_rc out=$review_out"
approves_before="$(approve_rows)"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "reviewed: read-only git status in the child's own worktree")"; rc=$?
check "positive: decide exits 0" "$rc" "0"
check "positive: approvals row written" "$(approve_rows)" "$((approves_before + 1))"
printf '%s' "$out" | jq -e '.resolved == true and .decision == "Approve"' >/dev/null \
  && ok "positive: resolved JSON reports Approve" || bad "positive: unexpected output: $out"
decided_audit="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='orch_child_approval_decided' AND json_extract(payload,'\$.approval_request_id')='$REQ';")"
check "positive: audit event recorded" "$decided_audit" "1"

printf '\n== N1 (stale generation): claim re-granted to a DIFFERENT pane refuses the superseded orchestrator ==\n'
record_bash run_child task_child "$CHILD_PANE" "$CHILD_BIRTH" "$CHILD_WT" "git status" "req-n1"
REQ="req-n1"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
register_role_cas "orchestrator@other-co" "$OTHER_ORCH_PANE" "$OTHER_ORCH_BIRTH" sess ws "" "" >/dev/null
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$OTHER_ORCH_PANE" "$OTHER_ORCH_BIRTH" "orchestrator@other-co" >/dev/null
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "stale generation attempt" 2>&1)"; rc=$?
check "N1: superseded holder refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "no live orchestrator role + proj: claim" && ok "N1: refusal names the eligibility gate" || bad "N1 message: $out"
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "re-granted, now eligible again")"; rc=$?
check "N1-restore: re-granting back makes the orchestrator eligible again (exit 0)" "$rc" "0"

printf '\n== N2 (expired claim): an expired grant is refused despite a historically-live role ==\n'
record_bash run_child task_child "$CHILD_PANE" "$CHILD_BIRTH" "$CHILD_WT" "git status" "req-n2"
REQ="req-n2"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" 1 >/dev/null
sleep 2
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "expired claim attempt" 2>&1)"; rc=$?
check "N2: expired claim refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "no live orchestrator role + proj: claim" && ok "N2: refusal names the eligibility gate" || bad "N2 message: $out"
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "fresh claim, now eligible again")"; rc=$?
check "N2-restore: a fresh grant resolves the same still-pending request (exit 0)" "$rc" "0"

printf '\n== N3 (cross-project): a child in a repo the orchestrator holds no claim for is refused ==\n'
record_bash run_kb task_kb "$KB_CHILD_PANE" "$KB_CHILD_BIRTH" "$KB_WT" "git status" "req-n3"
REQ="req-n3"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
out="$(decide_as "$ORCH_PANE" "$KB_CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "cross-project attempt" 2>&1)"; rc=$?
check "N3: cross-project child refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "no live orchestrator role + proj: claim" && ok "N3: refusal names the eligibility gate (checked against the CHILD's repo)" || bad "N3 message: $out"
check "N3: no approval row leaked for the KB request" "$(sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE prompt_id='$REQ';")" "0"

printf '\n== N4 (spoofed env pane): HERDR_PANE_ID asserting the orchestrator is ignored -- ancestry governs ==\n'
record_bash run_child task_child "$CHILD_PANE" "$CHILD_BIRTH" "$CHILD_WT" "git status" "req-n4"
REQ="req-n4"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
out="$(HERDR_FIXTURE_CALLER_PANE="$PLAIN_PANE" HERDR_PANE_ID="$ORCH_PANE" \
  bash "$here/orch-approve-child.sh" decide "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "spoofed env attempt" 2>&1)"; rc=$?
check "N4: spoofed HERDR_PANE_ID refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "not a live registered orchestrator" && ok "N4: refusal uses the ancestry-resolved identity, not the env assertion" || bad "N4 message: $out"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "the real orchestrator, by ancestry")"; rc=$?
check "N4-control: the SAME request still resolves for the true (ancestry-verified) orchestrator (exit 0)" "$rc" "0"

printf '\n== N5 (replay/resolved): a second decision on an already-resolved request is refused ==\n'
record_bash run_child task_child "$CHILD_PANE" "$CHILD_BIRTH" "$CHILD_WT" "git status" "req-n5"
REQ="req-n5"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "first resolution")"; rc=$?
check "N5: first resolution succeeds (exit 0)" "$rc" "0"
approves_before="$(approve_rows)"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "replay attempt" 2>&1)"; rc=$?
check "N5: replay of the same resolved request refused (exit 8)" "$rc" "8"
check "N5: no duplicate approval row from the replay" "$(approve_rows)" "$approves_before"
printf '%s' "$out" | grep -qF "verification failed" && ok "N5: refusal is the proposal re-verification, not a crash" || bad "N5 message: $out"

printf '\n== N6 (reserved-command): a conductor-reserved bound bash command cannot be Approved ==\n'
record_bash run_child task_child "$CHILD_PANE" "$CHILD_BIRTH" "$CHILD_WT" "git push origin main" "req-n6"
REQ="req-n6"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
approves_before="$(approve_rows)"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "trying to approve a push" 2>&1)"; rc=$?
check "N6: reserved command refused despite valid identity (exit 8)" "$rc" "8"
check "N6: no approval row for the reserved command" "$(approve_rows)" "$approves_before"
printf '%s' "$out" | grep -qF "human-only" && ok "N6: refusal names the human-only reservation" || bad "N6 message: $out"
deny_before="$(deny_rows)"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" deny branch-work "denying the push" 2>&1)"; rc=$?
check "N6b: Deny of the SAME reserved command still resolves (executes nothing, exit 0)" "$rc" "0"
check "N6b: deny row recorded" "$(deny_rows)" "$((deny_before + 1))"

printf '\n== N7 (non-child): a task this orchestrator does not conduct is refused ==\n'
record_bash run_other task_other "$OTHER_WORKER_PANE" "$OTHER_WORKER_BIRTH" "$OTHER_WT" "git status" "req-n7"
REQ="req-n7"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
out="$(decide_as "$ORCH_PANE" "$OTHER_WORKER_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "not my child" 2>&1)"; rc=$?
check "N7: non-child task refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "not this child's live registered conductor" && ok "N7: refusal names the conductor-ownership gate" || bad "N7 message: $out"
check "N7: the main-conducted task's own pending request is untouched" "$(occ_lifecycle run_other task_other "$OCC_KEY")" "requested"

printf '\n== N7b (deny by a non-owner): even a Deny of a RESERVED command on a task this orchestrator does not conduct is refused ==\n'
record_bash run_other task_other "$OTHER_WORKER_PANE" "$OTHER_WORKER_BIRTH" "$OTHER_WT" "git push origin main" "req-n7b"
REQ="req-n7b"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
deny_before="$(deny_rows)"
out="$(decide_as "$ORCH_PANE" "$OTHER_WORKER_PANE" "$REQ" "$CID" "$DG" "$SH" deny branch-work "not my child, denying anyway" 2>&1)"; rc=$?
check "N7b: non-owner Deny of a reserved command refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "not this child's live registered conductor" \
  && ok "N7b: refusal is the ownership gate, not the (irrelevant for Deny) command classifier" || bad "N7b message: $out"
check "N7b: no deny row from the non-owner attempt" "$(deny_rows)" "$deny_before"
check "N7b: the main-conducted task's own pending request is untouched" "$(occ_lifecycle run_other task_other "$OCC_KEY")" "requested"

printf '\n== N8 (wrong digest): a mismatched arguments digest is refused, no cross-binding ==\n'
record_bash run_child task_child "$CHILD_PANE" "$CHILD_BIRTH" "$CHILD_WT" "git status" "req-n8"
REQ="req-n8"; CID="$CALL_ID"; SH="$SHA"
WRONG_DIGEST="sha256:$(printf 'not-the-real-digest' | shasum -a 256 | awk '{print $1}')"
approves_before="$(approve_rows)"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$WRONG_DIGEST" "$SH" approve local-read "wrong digest attempt" 2>&1)"; rc=$?
check "N8: wrong digest refused (exit 8)" "$rc" "8"
check "N8: no approval row from the mismatched digest" "$(approve_rows)" "$approves_before"
printf '%s' "$out" | grep -qF "verification failed" && ok "N8: refusal is the exact-identity re-check" || bad "N8 message: $out"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DIGEST" "$SH" approve local-read "correct digest resolves the same request")"; rc=$?
check "N8-control: the correct digest still resolves the same request (exit 0)" "$rc" "0"

printf '\n== usage: unknown decision/category are rejected before any registry read (exit 2) ==\n'
record_bash run_child task_child "$CHILD_PANE" "$CHILD_BIRTH" "$CHILD_WT" "git status" "req-usage"
REQ="req-usage"; CID="$CALL_ID"; DG="$DIGEST"; SH="$SHA"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" maybe local-read "bad decision enum" 2>&1)"; rc=$?
check "usage: unknown decision value rejected (exit 2)" "$rc" "2"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve owned-cleanup "category not in the narrower allowed set" 2>&1)"; rc=$?
check "usage: owned-cleanup is NOT in this entry point's narrower category set (exit 2)" "$rc" "2"
out="$(decide_as "$ORCH_PANE" "$CHILD_PANE" "$REQ" "$CID" "$DG" "$SH" approve local-read "" 2>&1)"; rc=$?
check "usage: empty reason rejected (exit 2)" "$rc" "2"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
