#!/usr/bin/env bash
# verify-orch-child-dispatch.sh — pins orch-dispatch-child.sh (fix/
# orch-child-dispatch): a live bound orchestrator@<project> pane may deliver
# a brief to its OWN registered child (kickoff) and decide its child's bound
# approval (decide) via ONE fixed-argv file, and ONLY that.
#
# This is the regression test for the pilot r5 case (thurber-os/.handoffs/
# closed-panes/website-pilot-r5/REGRESSION-CASE-orch-dispatch.md): a
# hook-mode orchestrator's own bash tool could not deliver its own child's
# kickoff by any shape of calling send-to-agent.sh. The POSITIVE case below
# ("preserved case") is that exact shape, now via the structured entry
# point, asserting SUBMITTED.
#
# Harness: combines verify-orch-child-approve.sh's ancestry/role/claim stub
# (pane process-info / pane list) with verify-send-to-agent.sh's
# state-machine pane-read/send-text/send-keys stub, plus a throwaway
# registry (HERDR_RUN_STATE_DIR in mktemp — never the live registry).
#
#   bash verify-orch-child-dispatch.sh
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
# Fixture-only, not a runtime default: this suite's bash/decide fixtures are
# bound-request proposals, which lib/prompt-occurrence.py's PROPOSAL_TOOLS
# only includes "bash"/"shell" for when HERDR_BOUND_BASH=1 (its own
# runtime gate, unchanged here). Without this export the suite silently
# depended on that var being ambiently 1 in the invoking shell/pane -- true
# in a bound-launcher pane, false from a plain/conductor shell or CI, which
# is the real trigger behind the deploy-window passed=31 failed=3 report
# (herdr-control debug/orch-decide-proposal-missing, 2026-10-19).
export HERDR_BOUND_BASH=1
DB="$HERDR_RUN_STATE_DIR/registry.sqlite3"
SCREEN_DIR="$WORK/screens"; DETECTION_DIR="$WORK/detection"; COUNTER="$WORK/enter-count"
KEYS="$WORK/keys.log"; SENDTEXT="$WORK/send-text.log"
mkdir -p "$SCREEN_DIR" "$DETECTION_DIR"

HC_RAW=$(mktemp -d -p "$WORK"); git -C "$HC_RAW" init -q -b main 2>/dev/null
git -C "$HC_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
KB_RAW=$(mktemp -d -p "$WORK"); git -C "$KB_RAW" init -q -b main 2>/dev/null
git -C "$KB_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
HC=$(cd "$HC_RAW" && pwd -P)
KB=$(cd "$KB_RAW" && pwd -P)
ORCH_WT="$WORK/orch-wt"; mkdir -p "$ORCH_WT/tmp"
OTHER_ORCH_WT="$WORK/other-orch-wt"; mkdir -p "$OTHER_ORCH_WT/tmp"
CHILD_WT="$WORK/child-wt"; mkdir -p "$CHILD_WT"
OTHER_WT="$WORK/other-wt"; mkdir -p "$OTHER_WT"
KB_WT="$WORK/kb-wt"; mkdir -p "$KB_WT"
OUTSIDE="$WORK/outside"; mkdir -p "$OUTSIDE"

MAIN_PANE="mainpane1"; MAIN_BIRTH="mainbirth1"
ORCH_PANE="orcpane1"; ORCH_BIRTH="orcbirth1"
CHILD_PANE="childpane1"; CHILD_BIRTH="childbirth1"
PLAIN_PANE="plainpane1"; PLAIN_BIRTH="plainbirth1"
OTHER_WORKER_PANE="otherworker1"; OTHER_WORKER_BIRTH="otherworkerbirth1"
KB_CHILD_PANE="kbchildpane1"; KB_CHILD_BIRTH="kbchildbirth1"
OTHER_ORCH_PANE="otherorchpane1"; OTHER_ORCH_BIRTH="otherorchbirth1"
export MAIN_PANE MAIN_BIRTH ORCH_PANE ORCH_BIRTH CHILD_PANE CHILD_BIRTH \
  PLAIN_PANE PLAIN_BIRTH OTHER_WORKER_PANE OTHER_WORKER_BIRTH KB_CHILD_PANE KB_CHILD_BIRTH \
  OTHER_ORCH_PANE OTHER_ORCH_BIRTH
export SCREEN_DIR DETECTION_DIR COUNTER KEYS SENDTEXT WORK

# ---- combined stub: ancestry/role resolution (process-info/pane list) +
# send-to-agent's state-machine pane-read/send-text/send-keys. ------------
_stub_ancestry() {
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
    *) return 1 ;;
  esac
}
herdr() {
  _stub_ancestry "$@" 2>/dev/null && return 0
  case "$1 $2" in
    "pane read")
      local idx f source=visible i
      for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "--source" ]; then i=$((i + 1)); source="${!i}"; break; fi
      done
      idx=$(cat "$COUNTER" 2>/dev/null); idx="${idx:-0}"
      if [ "$source" = "detection" ] && { [ -f "$DETECTION_DIR/$idx" ] || [ -f "$DETECTION_DIR/last" ]; }; then
        f="$DETECTION_DIR/$idx"; [ -f "$f" ] || f="$DETECTION_DIR/last"
      else
        f="$SCREEN_DIR/$idx"; [ -f "$f" ] || f="$SCREEN_DIR/last"
      fi
      cat "$f" 2>/dev/null ;;
    "pane send-text")
      printf '%s\n' "$4" >>"$SENDTEXT" ;;
    "pane send-keys")
      printf '%s\n' "$4" >>"$KEYS"
      if [ "$4" = "Enter" ]; then
        local idx; idx=$(cat "$COUNTER" 2>/dev/null); idx="${idx:-0}"
        echo $((idx + 1)) >"$COUNTER"
      fi ;;
    *) return 0 ;;
  esac
}
ps() { printf '1\n'; }
export -f _stub_ancestry herdr ps

reset_screens() {
  rm -rf "$SCREEN_DIR" "$DETECTION_DIR"; mkdir -p "$SCREEN_DIR" "$DETECTION_DIR"
  echo 0 >"$COUNTER"; : >"$KEYS"; : >"$SENDTEXT"
}
screen() { cat >"$SCREEN_DIR/$1"; }
detection() { cat >"$DETECTION_DIR/$1"; }
last_as() { cp "$SCREEN_DIR/$1" "$SCREEN_DIR/last"; }
detection_last_as() { cp "$DETECTION_DIR/$1" "$DETECTION_DIR/last"; }
enters_pressed() { grep -c '^Enter$' "$KEYS" 2>/dev/null; }

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

. "$here/lib/run-registry.sh"
. "$here/lib/claims.sh"
. "$here/tests/fixtures/task-authorization.sh"
registry_init >/dev/null

# ---- fixtures: registry roles/claims -------------------------------------
register_role_cas main "$MAIN_PANE" "$MAIN_BIRTH" sess ws "" "" >/dev/null
register_role_cas "orchestrator@herdr-control" "$ORCH_PANE" "$ORCH_BIRTH" sess ws "" "" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null

# The orchestrator's OWN task (conductor_pane_id=main, repo=$HC, its own
# worktree $ORCH_WT) -- what orch-dispatch-child.sh bounds <data_file> and
# "same run" to.
fixture_register_task run_child task_orch worker_orch conductor_main \
  "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "$HC" "$ORCH_WT" \
  orch-label orch-branch "" herdr-control "" hook >/dev/null || { echo "fixture: task_orch failed" >&2; exit 1; }
set_task_state run_child task_orch running >/dev/null

# The orchestrator's own child: conductor_pane_id/birth = the orchestrator,
# SAME run_id (run_child), repo = $HC, bound (hook), running.
fixture_register_task run_child task_child worker_child conductor_main \
  "$ORCH_PANE" "$ORCH_BIRTH" "$CHILD_PANE" "$CHILD_BIRTH" "$HC" "$CHILD_WT" \
  child-label child-branch "" herdr-control "" hook >/dev/null || { echo "fixture: task_child failed" >&2; exit 1; }
set_task_state run_child task_child running >/dev/null

# A plain Main-conducted worker in a DIFFERENT run (control: non-child/other-run).
fixture_register_task run_other task_other worker_other conductor_main \
  "$MAIN_PANE" "$MAIN_BIRTH" "$OTHER_WORKER_PANE" "$OTHER_WORKER_BIRTH" "$HC" "$OTHER_WT" \
  other-label other-branch "" herdr-control "" hook >/dev/null || { echo "fixture: task_other failed" >&2; exit 1; }
set_task_state run_other task_other running >/dev/null

# A task whose conductor is the SAME orchestrator pane but repo=$KB (cross-project).
fixture_register_task run_child task_kb worker_kb conductor_main \
  "$ORCH_PANE" "$ORCH_BIRTH" "$KB_CHILD_PANE" "$KB_CHILD_BIRTH" "$KB" "$KB_WT" \
  kb-label kb-branch "" knowledge-base "" hook >/dev/null || { echo "fixture: task_kb failed" >&2; exit 1; }
set_task_state run_child task_kb running >/dev/null

# ---- harness: run the REAL script as a fresh process ---------------------
kickoff_as() {   # <acting_pane> <child_pane> <message_file>
  ( HERDR_FIXTURE_CALLER_PANE="$1" HERDR_PANE_ID="$1" \
    bash "$here/orch-dispatch-child.sh" kickoff "$2" "$3" )
}

printf '== PRESERVED CASE (pilot r5 regression): the bound orchestrator dispatches a kickoff to its OWN live registered child via the structured entry point ==\n'
reset_screens
screen 0 <<'EOF'

───────────────────
❯
───────────────────
EOF
screen 1 <<'EOF'
❯ Your identity.json: ... fix the quarantine tests.

✻ Cogitated for 1s
───────────────────
❯
───────────────────
EOF
last_as 1
echo "Your identity.json: /fake/identity.json. Task: fix the quarantine tests." >"$ORCH_WT/tmp/brief.md"
out="$(kickoff_as "$ORCH_PANE" "$CHILD_PANE" "$ORCH_WT/tmp/brief.md" 2>&1)"; rc=$?
check "preserved case: exit 0 SUBMITTED (was refused pre-fix, every shape)" "$rc" "0"
printf '%s' "$out" | grep -qF SUBMITTED && ok "preserved case: reported SUBMITTED" || bad "preserved case out: $out"
check "preserved case: exactly one Enter" "$(enters_pressed)" "1"
check "preserved case: text delivered via send-text" "$(cat "$SENDTEXT")" "Your identity.json: /fake/identity.json. Task: fix the quarantine tests."
delivered_audit="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='orch_child_dispatch_delivered';")"
check "preserved case: audit event recorded" "$delivered_audit" "1"

printf '\n== N1 (non-child pane): a task this orchestrator does not conduct is refused ==\n'
reset_screens; screen 0 <<'EOF'
❯
EOF
last_as 0
echo "not my child" >"$ORCH_WT/tmp/n1.md"
out="$(kickoff_as "$ORCH_PANE" "$OTHER_WORKER_PANE" "$ORCH_WT/tmp/n1.md" 2>&1)"; rc=$?
check "N1: non-child pane refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "is not registered in the caller's own run" && ok "N1: refusal names the gate that fires first (other-run, since this fixture is also cross-run)" || bad "N1 message: $out"
check "N1: no Enter pressed (nothing delivered)" "$(enters_pressed)" "0"

printf '\n== N1b (other run): a child registered under a DIFFERENT run than the caller'"'"'s own task is refused ==\n'
echo "wrong run" >"$ORCH_WT/tmp/n1b.md"
out="$(kickoff_as "$ORCH_PANE" "$OTHER_WORKER_PANE" "$ORCH_WT/tmp/n1b.md" 2>&1)"; rc=$?
check "N1b: other-run child refused (exit 8)" "$rc" "8"

printf '\n== N2 (other project / cross-project): a child in a repo the orchestrator holds no claim for is refused ==\n'
echo "cross project" >"$ORCH_WT/tmp/n2.md"
out="$(kickoff_as "$ORCH_PANE" "$KB_CHILD_PANE" "$ORCH_WT/tmp/n2.md" 2>&1)"; rc=$?
check "N2: cross-project child refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "no live orchestrator role + proj: claim" && ok "N2: refusal names the eligibility gate (checked against the CHILD's repo)" || bad "N2 message: $out"

printf '\n== N3 (expired lease): an expired project claim is refused despite a historically-live role ==\n'
echo "expired claim attempt" >"$ORCH_WT/tmp/n3.md"
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" 1 >/dev/null
sleep 2
out="$(kickoff_as "$ORCH_PANE" "$CHILD_PANE" "$ORCH_WT/tmp/n3.md" 2>&1)"; rc=$?
check "N3: expired lease refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "no live orchestrator role + proj: claim" && ok "N3: refusal names the eligibility gate" || bad "N3 message: $out"
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null

printf '\n== N4 (foreign/stale-generation lease): claim re-granted to a DIFFERENT pane refuses the superseded orchestrator ==\n'
echo "stale generation attempt" >"$ORCH_WT/tmp/n4.md"
register_role_cas "orchestrator@other-co" "$OTHER_ORCH_PANE" "$OTHER_ORCH_BIRTH" sess ws "" "" >/dev/null
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$OTHER_ORCH_PANE" "$OTHER_ORCH_BIRTH" "orchestrator@other-co" >/dev/null
out="$(kickoff_as "$ORCH_PANE" "$CHILD_PANE" "$ORCH_WT/tmp/n4.md" 2>&1)"; rc=$?
check "N4: stale-generation holder refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "no live orchestrator role + proj: claim" && ok "N4: refusal names the eligibility gate" || bad "N4 message: $out"
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null

printf '\n== N5 (non-orchestrator caller): the plain pane holds no orchestrator role at all ==\n'
echo "not an orchestrator" >"$ORCH_WT/tmp/n5.md"
out="$(kickoff_as "$PLAIN_PANE" "$CHILD_PANE" "$ORCH_WT/tmp/n5.md" 2>&1)"; rc=$?
check "N5: non-orchestrator caller refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "not a live registered orchestrator" && ok "N5: refusal names the identity gate" || bad "N5 message: $out"

printf '\n== N6 (arbitrary shell): shell metacharacters in argv are inert -- fixed argv, no free shell ==\n'
rm -f "$WORK/pwned"
reset_screens; screen 0 <<'EOF'
❯
EOF
last_as 0
printf '; touch %s #' "$WORK/pwned" >"$ORCH_WT/tmp/n6-pane.md"
out="$(kickoff_as "$ORCH_PANE" '$(touch '"$WORK"'/pwned)' "$ORCH_WT/tmp/n6-pane.md" 2>&1)"; rc=$?
[ ! -e "$WORK/pwned" ] && ok "N6: shell metacharacters in child_pane never executed" || bad "N6: pwned file exists -- shell injection via argv"
check "N6: unresolvable pane name is simply not a registered task (exit 8)" "$rc" "8"

printf '\n== N7 (outside-worktree file): a message file outside the caller'"'"'s OWN worktree is refused ==\n'
echo "not mine to read" >"$OUTSIDE/brief.md"
out="$(kickoff_as "$ORCH_PANE" "$CHILD_PANE" "$OUTSIDE/brief.md" 2>&1)"; rc=$?
check "N7: outside-worktree file refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "does not resolve inside the caller's own worktree" && ok "N7: refusal names the write-scope gate" || bad "N7 message: $out"
check "N7: no Enter pressed (nothing delivered)" "$(enters_pressed)" "0"

printf '\n== N7b (dot-dot traversal): a message_file path with a literal .. escaping the worktree is refused ==\n'
reset_screens; screen 0 <<'EOF'
❯
EOF
last_as 0
echo "top secret outside content" >"$OUTSIDE/secret.md"
out="$(kickoff_as "$ORCH_PANE" "$CHILD_PANE" "$ORCH_WT/tmp/../../outside/secret.md" 2>&1)"; rc=$?
check "N7b: dot-dot traversal refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "does not resolve inside the caller's own worktree" && ok "N7b: refusal names the write-scope gate" || bad "N7b message: $out"
check "N7b: secret content never delivered" "$(cat "$SENDTEXT" 2>/dev/null)" ""

printf '\n== N7c (symlink escape): a symlink INSIDE the worktree whose TARGET is outside it is refused, not followed ==\n'
reset_screens; screen 0 <<'EOF'
❯
EOF
last_as 0
echo "exfiltrated host secret: AKIA-fake-outside-content" >"$OUTSIDE/payload.txt"
ln -sf "$OUTSIDE/payload.txt" "$ORCH_WT/tmp/evil-link.md"
out="$(kickoff_as "$ORCH_PANE" "$CHILD_PANE" "$ORCH_WT/tmp/evil-link.md" 2>&1)"; rc=$?
check "N7c: symlink-escape message_file refused (exit 8)" "$rc" "8"
printf '%s' "$out" | grep -qF "is a symlink" && ok "N7c: refusal names the symlink rejection" || bad "N7c message: $out"
check "N7c: outside target content never delivered (not just unsubmitted -- never typed)" "$(cat "$SENDTEXT" 2>/dev/null)" ""
check "N7c: no Enter pressed (nothing delivered)" "$(enters_pressed)" "0"

printf '\n== N8 (missing file): a message file that does not exist is refused, not silently skipped ==\n'
out="$(kickoff_as "$ORCH_PANE" "$CHILD_PANE" "$ORCH_WT/tmp/does-not-exist.md" 2>&1)"; rc=$?
check "N8: missing file refused (exit 8)" "$rc" "8"

printf '\n== decide: orch-dispatch-child.sh decide reuses orch-approve-child.sh'"'"'s decide verbatim via a payload file ==\n'
bash_input() { jq -nc --arg c "$1" '{command:$c}'; }
input_sha() { python3 - "$1" "$2" <<'PY'
import hashlib, json, sys
body = json.dumps({"tool": sys.argv[1], "input": json.loads(sys.argv[2]), "known": True},
                  sort_keys=True, separators=(",", ":"), default=str)
print(hashlib.sha256(body.encode()).hexdigest())
PY
}
OCC=(python3 "$here/lib/prompt-occurrence.py")
record_bash() {   # run task pane birth wt cmd req
  local run="$1" task="$2" pane="$3" birth="$4" wt="$5" cmd="$6" req="$7"
  local input_json; input_json="$(bash_input "$cmd")"
  local json; json="$(printf '%s' "$input_json" | jq -cS .)"
  DIGEST="sha256:$(printf '%s' "$json" | shasum -a 256 | awk '{print $1}')"
  SHA="$(input_sha bash "$input_json")"
  append_event "$run" "$task" input_required \
    "$(jq -nc --arg pid "noscreen-dp" '{message:"needs permission", prompt_id:$pid, command:"", tool:"bash"}')" >/dev/null 2>&1
  local id=(--db "$DB" --run "$run" --task "$task" --pane "$pane" --birth "$birth" --session "sess-dp" --call-id "call-dp")
  local recorded_input; recorded_input="$(jq -nc --argjson i "$input_json" --arg j "$json" '{input:$i,core_arguments_json:$j}')"
  printf '%s' "$recorded_input" | "${OCC[@]}" seen "${id[@]}" --tool bash --input-json - --bound-envelope \
    --approval-request-id "$req" --core-arguments-digest "$DIGEST" --binding-protocol "omp.tool-approval-binding.v1" \
    --cwd "$wt" --dispatched-at-ms "$(python3 -c 'import time; print(int(time.time()*1000))')" >/dev/null
}
record_bash run_child task_child "$CHILD_PANE" "$CHILD_BIRTH" "$CHILD_WT" "git status" "req-dp-1"
approves_before="$(sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE choice_text='Approve';" 2>/dev/null || echo 0)"
jq -nc --arg req "req-dp-1" --arg call "call-dp" --arg dg "$DIGEST" --arg sha "$SHA" \
  '{approval_request_id:$req, tool_call_id:$call, arguments_digest:$dg, payload_sha:$sha, decision:"approve", category:"local-build", reason:"reviewed via dispatch payload file"}' \
  >"$ORCH_WT/tmp/decide-1.json"
out="$(( HERDR_FIXTURE_CALLER_PANE="$ORCH_PANE" HERDR_PANE_ID="$ORCH_PANE" \
  bash "$here/orch-dispatch-child.sh" decide "$CHILD_PANE" "$ORCH_WT/tmp/decide-1.json" ) 2>&1)"; rc=$?
check "decide: exit 0" "$rc" "0"
approves_after="$(sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE choice_text='Approve';" 2>/dev/null || echo 0)"
check "decide: approvals row written (reused orch-approve-child.sh logic)" "$approves_after" "$((approves_before + 1))"
printf '%s' "$out" | jq -e '.resolved == true and .decision == "Approve"' >/dev/null \
  && ok "decide: resolved JSON reports Approve" || bad "decide: unexpected output: $out"

printf '\n== decide N (malformed payload): a payload file missing a required field is rejected before any registry read (exit 2) ==\n'
echo '{"approval_request_id":"x"}' >"$ORCH_WT/tmp/decide-bad.json"
out="$(( HERDR_FIXTURE_CALLER_PANE="$ORCH_PANE" HERDR_PANE_ID="$ORCH_PANE" \
  bash "$here/orch-dispatch-child.sh" decide "$CHILD_PANE" "$ORCH_WT/tmp/decide-bad.json" ) 2>&1)"; rc=$?
check "decide: malformed payload rejected (exit 2)" "$rc" "2"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
