#!/usr/bin/env bash
# verify-namespaced-leases.sh — pins the P2 substrate primitives added to
# lib/claims.sh and lib/run-registry.sh (.handoffs/SPEC.md feat/orch-p2-substrate):
#   * pane:/proj: are reserved namespaces claim_acquire/claim_release/
#     claim_release_force always refuse, regardless of caller;
#   * claim_acquire_proj grants proj: claims ONLY to the live roles['main']
#     caller, and a re-grant bumps the generation;
#   * register_task writes the pane:<worker>@<birth> lease (holder =
#     conductor) in the same transaction as the task row;
#   * set_task_conductor swaps that lease (release old holder, insert new
#     with a bumped generation) in the same transaction as the CAS, and
#     refuses a handover to an orchestrator@* pane that holds no proj:
#     claim for the task's repo.
#
# Runs entirely against a THROWAWAY registry (HERDR_RUN_STATE_DIR in a temp
# dir) — never the real control plane.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

TMPROOT=$(mktemp -d)
export HERDR_RUN_STATE_DIR="$TMPROOT/state"
# shellcheck source=lib/run-registry.sh
source "$HERE/lib/run-registry.sh"
# shellcheck source=lib/claims.sh
source "$HERE/lib/claims.sh"
registry_init >/dev/null

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }

REPO_HC="$TMPROOT/herdr-control"; REPO_KB="$TMPROOT/knowledge-base"
mkdir -p "$REPO_HC" "$REPO_KB"

printf '\n== pane:/proj: are reserved — claim_acquire/claim_release(_force) always refuse ==\n'
out=$(claim_acquire "proj:$REPO_KB" w:p1 2>&1); rc=$?
check "claim_acquire proj: refused (rc=1)" "$rc" "1"
case "$out" in *reserved*) ok "refusal names it a reserved namespace" ;; *) bad "refusal message" "$out" ;; esac
out=$(claim_acquire "pane:p9@birth9" w:p1 2>&1); rc=$?
check "claim_acquire pane: refused (rc=1)" "$rc" "1"
claim_acquire "path:$REPO_HC" w:p1 >/dev/null 2>&1
out=$(claim_release "proj:$REPO_KB" w:p1 2>&1); rc=$?
check "claim_release proj: refused (rc=1)" "$rc" "1"
out=$(claim_release_force "pane:p9@birth9" 2>&1); rc=$?
check "claim_release_force pane: refused (rc=1)" "$rc" "1"
claim_release "path:$REPO_HC" w:p1 >/dev/null 2>&1

printf '\n== claim_acquire_proj: Main-only, and generation bumps on every re-grant ==\n'
out=$(claim_acquire_proj "proj:$REPO_HC" nomain:p nomain:birth orch:p1 orchbirth1 2>&1); rc=$?
check "a non-main caller is refused (rc=1)" "$rc" "1"
case "$out" in *main*) ok "refusal names main as the required caller" ;; *) bad "refusal message" "$out" ;; esac
[ "$(_sql "SELECT count(*) FROM claims WHERE scope=$(_sq "proj:$REPO_HC");" 2>/dev/null)" = "0" ] \
  && ok "the refused call created no row" || bad "a row was created despite refusal"

register_role_cas main main:pane main:birth sess1 ws1 "" "" >/dev/null
out=$(claim_acquire_proj "proj:$REPO_HC" main:pane main:birth orch:p1 orchbirth1 "orchestrator@herdr-control" 2>&1); rc=$?
check "live main caller is granted (rc=0)" "$rc" "0"
gen1=$(printf '%s' "$out" | jq -r .generation)
check "first grant is generation 1" "$gen1" "1"
holder_pane=$(printf '%s' "$out" | jq -r .pane_id)
check "holder is the orchestrator pane (not the caller)" "$holder_pane" "orch:p1"

claim_release_force_proj "proj:$REPO_HC" main:pane main:birth >/dev/null 2>&1
out=$(claim_acquire_proj "proj:$REPO_HC" main:pane main:birth orch:p1 orchbirth1 2>&1); rc=$?
check "re-grant after force-release succeeds" "$rc" "0"
gen2=$(printf '%s' "$out" | jq -r .generation)
check "re-grant bumps the generation past the old one" "$gen2" "2"
case "$gen1" in "$gen2") bad "generation did not change across force-release+re-grant" ;; esac

printf '\n== stale generation: a caller holding the OLD generation is no longer current ==\n'
# This is the primitive the SPEC's "stale owner (old fencing generation)
# refused" negative proof rests on: spawn-task.sh (lib/claims.sh-backed)
# re-reads this same generation immediately before registering, and a
# mismatch against $gen1 here is exactly what it refuses on (verify-spawn-scope.sh).
live=$(claim_holder "proj:$REPO_HC")
live_gen=$(printf '%s' "$live" | jq -r .generation)
check "the live generation is the re-granted one, not the stale $gen1" "$live_gen" "$gen2"

printf '\n== register_task writes the pane: lease in the SAME transaction (plan v2 §4.1) ==\n'
run_id=$(gen_id run); task_id=$(gen_id task)
register_task "$run_id" "$task_id" worker1 cond1 cpane1 cbirth1 wpane1 wbirth1 "$REPO_HC" "$TMPROOT/wt1" lbl1 br1 trunk1 >/dev/null
lease=$(claim_holder "pane:wpane1@wbirth1")
[ -n "$lease" ] && ok "pane: lease exists after register_task" || bad "no pane: lease after register_task"
lease_pane=$(printf '%s' "$lease" | jq -r .pane_id)
check "lease holder is the CONDUCTOR pane, not the worker pane" "$lease_pane" "cpane1"
lease_gen=$(printf '%s' "$lease" | jq -r .generation)
check "first registration's lease is generation 1" "$lease_gen" "1"

printf '\n== set_task_conductor swaps the pane: lease and bumps its generation ==\n'
set_task_conductor "$run_id" "$task_id" cpane1 cbirth1 cpane2 cbirth2 cond2 test-handover >/dev/null 2>&1
rc=$?
check "ordinary handover (no orchestrator target) succeeds" "$rc" "0"
lease2=$(claim_holder "pane:wpane1@wbirth1")
lease2_pane=$(printf '%s' "$lease2" | jq -r .pane_id)
check "lease holder moved to the new conductor" "$lease2_pane" "cpane2"
lease2_gen=$(printf '%s' "$lease2" | jq -r .generation)
check "handover bumps the lease generation" "$lease2_gen" "2"
old_count=$(_sql "SELECT count(*) FROM claims WHERE scope=$(_sq "pane:wpane1@wbirth1") AND released_at IS NOT NULL;" 2>/dev/null)
check "exactly one prior lease row was released, not deleted" "$old_count" "1"

printf '\n== set_task_conductor refuses a handover to an orchestrator@* pane with no proj: claim for the repo ==\n'
run_id2=$(gen_id run); task_id2=$(gen_id task)
register_task "$run_id2" "$task_id2" worker2 cond1 cpaneA cbirthA wpane2 wbirth2 "$REPO_KB" "$TMPROOT/wt2" lbl2 br2 trunk2 >/dev/null
# orch:p1/orchbirth1 holds proj:$REPO_HC (above), NOT proj:$REPO_KB.
register_role_cas "orchestrator@herdr-control" orch:p1 orchbirth1 sess2 ws2 "" "" >/dev/null
out=$(set_task_conductor "$run_id2" "$task_id2" cpaneA cbirthA orch:p1 orchbirth1 "orchestrator@herdr-control" test 2>&1); rc=$?
check "handover to an out-of-scope orchestrator refused (rc=1)" "$rc" "1"
still=$(_sql "SELECT conductor_pane_id FROM tasks WHERE run_id=$(_sq "$run_id2") AND task_id=$(_sq "$task_id2");" 2>/dev/null)
check "conductor_pane_id unchanged by the refused handover" "$still" "cpaneA"
refused_ev=$(_sql "SELECT count(*) FROM events WHERE task_id=$(_sq "$task_id2") AND type='conductor_handover_refused';" 2>/dev/null)
check "a conductor_handover_refused event names the refusal" "$refused_ev" "1"

printf '\n== ...but succeeds once that orchestrator DOES hold proj: for the repo ==\n'
claim_acquire_proj "proj:$REPO_KB" main:pane main:birth orch:p1 orchbirth1 "orchestrator@herdr-control" >/dev/null 2>&1
out=$(set_task_conductor "$run_id2" "$task_id2" cpaneA cbirthA orch:p1 orchbirth1 "orchestrator@herdr-control" test 2>&1); rc=$?
check "handover to an in-scope orchestrator succeeds" "$rc" "0"

printf '\n== role_for_live_pane: the registry fact a caller cannot fake ==\n'
check "resolves a live orchestrator@* role from exact pane+birth" "$(role_for_live_pane orch:p1 orchbirth1 'orchestrator@')" "orchestrator@herdr-control"
check "a non-matching birth resolves to nothing" "$(role_for_live_pane orch:p1 wrong-birth 'orchestrator@')" ""
check "a plain unregistered pane resolves to nothing" "$(role_for_live_pane w:p99 b99 'orchestrator@')" ""

printf '\n== summary ==\n'
printf '  %d passed, %d failed\n' "$pass" "$fail"
rm -rf "$TMPROOT" 2>/dev/null
[ "$fail" = 0 ] || exit 1
