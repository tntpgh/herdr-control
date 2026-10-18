#!/usr/bin/env bash
# verify-bound-orchestrator.sh — pins brief-bound-orchestrator-mode.md
# (incident 2026-10-18, website pilot, .handoffs/closed-panes/website-pilot-orch/):
# a pane can be BOTH bound (every tool call hook-approved by Main) AND
# conductor-eligible for its own children, but ONLY while it is the live
# roles['orchestrator@<p>'] holder PLUS a live proj: claim under its exact
# pane+birth.
#
# Two layers, tested two different ways:
#   - ELIGIBILITY (lib/pane-guard.sh pane_is_conductor_eligible's new
#     optional root_real argument) is reached ONLY from spawn-task.sh's
#     MANAGED-launch local-authority gate. This worker's sandbox cannot
#     authenticate as a conductor-eligible pane for a real, non-dry-run
#     MANAGED spawn (the SAME known limitation documented in
#     verify-startup-failure-reconciliation.sh and already affecting
#     verify-spawn-manifest-r32.sh here) -- so, like that suite, eligibility
#     is tested by calling the real function directly against a stubbed
#     `herdr` (same pattern verify-conductor-handover.sh uses for this exact
#     function), bit-for-bit the shipped code, never a hand-copied duplicate.
#   - ROUTING, the worker CAP, and cross-project scope are reached from
#     spawn-task.sh regardless of managed/unmanaged (register_task and the
#     P2 proj: scope check both run unconditionally) -- those run the REAL,
#     full, non-dry-run pipeline end to end, same fixture pattern as
#     verify-spawn-scope.sh.
#
#   HERDR_RUN_STATE_DIR is always a mktemp dir here -- never the live registry.
#   bash verify-bound-orchestrator.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/repo-root.sh
source "$HERE/lib/repo-root.sh"

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

WT_ROOT=$(mktemp -d); WT_ROOT=$(cd "$WT_ROOT" && pwd -P)
STATE_ROOT=$(mktemp -d)   # ONE shared throwaway registry for the whole suite

HC_RAW=$(mktemp -d); git -C "$HC_RAW" init -q -b main 2>/dev/null
git -C "$HC_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
KB_RAW=$(mktemp -d); git -C "$KB_RAW" init -q -b main 2>/dev/null
git -C "$KB_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
HC=$(cd "$(repo_root "$HC_RAW")" && pwd -P)
KB=$(cd "$(repo_root "$KB_RAW")" && pwd -P)

ORCH_PANE="orcpane1"; ORCH_BIRTH="orcbirth1"
MAIN_PANE="mainpane1"; MAIN_BIRTH="mainbirth1"
PLAIN_PANE="plainpane1"; PLAIN_BIRTH="plainbirth1"
STARTING_PANE="startingpane1"; STARTING_BIRTH="startingbirth1"
OTHER_PANE="otherorch1"; OTHER_BIRTH="otherbirth1"
RACE_PANE="racepane1"; RACE_BIRTH="racebirth1"

# ---- stub herdr: PATH binary (real spawn-task.sh invocations) ---------------
stub_dir=$(mktemp -d)
cat > "$stub_dir/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "tab create")
    printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1","terminal_id":"term1"}}}\n' ;;
  "pane run") : ;;
  "pane list")
    if [ -n "\${HERDR_FG_PANE:-}" ]; then
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"}]}}\n' \\
        "\$HERDR_FG_PANE" "\${HERDR_FG_BIRTH:-birth}"
    else
      printf '{"result":{"panes":[]}}\n'
    fi ;;
  "pane process-info")
    if [ -n "\${HERDR_FG_PID:-}" ]; then
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s}]}}}\n' "\$HERDR_FG_PID"
    else
      printf '{"result":{"process_info":{"foreground_processes":[]}}}\n'
    fi ;;
  *) printf '{"result":{"workspace":{"workspace_id":"w1"},"workspaces":[],"panes":[],"tabs":[]}}\n' ;;
esac
STUB
chmod +x "$stub_dir/herdr"

run_as() {   # <fg_pane|""> <fg_birth> <script> <repo> <branch> [extra args...]
  local fg_pane="$1" fg_birth="$2" script="$3" repo="$4" branch="$5"; shift 5
  # This suite may itself be running inside a real herdr-spawned pane -- its
  # own HERDR_PANE_ID/HERDR_PANE_BIRTH must never leak into the fixture
  # (conductor_pane_id routing reads HERDR_PANE_ID directly, same convention
  # verify-conductor-handover.sh documents for this exact leak risk).
  env -u HERDR_MCP_CONDUCTOR_PANE -u HERDR_MCP_CONDUCTOR_BIRTH -u HERDR_CONDUCTOR_ID \
    HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" \
    HERDR_WT_DIR="$WT_ROOT" HERDR_RUN_STATE_DIR="$STATE_ROOT" \
    HERDR_PANE_ID="$fg_pane" HERDR_PANE_BIRTH="$fg_birth" \
    HERDR_FG_PANE="$fg_pane" HERDR_FG_BIRTH="$fg_birth" HERDR_FG_PID="$$" \
    bash "$HERE/$script" "$repo" "$branch" "$@" quick /bin/true
}

# reg <function> [args...] — call a lib/run-registry.sh or lib/claims.sh
# function in a fresh subshell sourced against the shared STATE_ROOT.
reg() {
  ( export HERDR_RUN_STATE_DIR="$STATE_ROOT"
    # shellcheck source=lib/run-registry.sh
    source "$HERE/lib/run-registry.sh"
    # shellcheck source=lib/claims.sh
    source "$HERE/lib/claims.sh"
    registry_init >/dev/null
    "$@" )
}

reg_sql() {   # <sql> — raw SQL against the shared throwaway registry (test-only)
  ( export HERDR_RUN_STATE_DIR="$STATE_ROOT"
    source "$HERE/lib/run-registry.sh"
    registry_init >/dev/null
    _sql "$1" )
}

# ---- fixtures -----------------------------------------------------------
reg register_role_cas main "$MAIN_PANE" "$MAIN_BIRTH" sess ws "" "" >/dev/null
reg register_role_cas "orchestrator@herdr-control" "$ORCH_PANE" "$ORCH_BIRTH" sess ws "" "" >/dev/null
reg claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null

# The orchestrator's OWN task: registered by Main, bound (hook), running --
# this is the exact shape of the incident (a spawn-task.sh-launched bound
# worker, registered as orchestrator@<project>, holding a proj: lease,
# whose OWN task state is `running`).
reg register_task run_orch task_orch worker_orch conductor_main \
  "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "$HC" "$HC-wt-orch" \
  orch-label orch-branch "" herdr-control "" hook "" >/dev/null
reg set_task_state run_orch task_orch running >/dev/null

# A plain bound worker (no orchestrator role) with its own running task --
# the "every OTHER running worker stays refused, exactly as today" control.
reg register_task run_plain task_plain worker_plain conductor_main \
  "$MAIN_PANE" "$MAIN_BIRTH" "$PLAIN_PANE" "$PLAIN_BIRTH" "$HC" "$HC-wt-plain" \
  plain-label plain-branch "" herdr-control "" hook "" >/dev/null
reg set_task_state run_plain task_plain running >/dev/null

# An orchestrator-role pane whose own task never left `starting` -- proves
# the carve-out widens ONLY `running`, never `starting`/`blocked`.
reg register_role_cas "orchestrator@starting-co" "$STARTING_PANE" "$STARTING_BIRTH" sess ws "" "" >/dev/null
reg claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$STARTING_PANE" "$STARTING_BIRTH" "orchestrator@starting-co" >/dev/null
# claim_acquire_proj just moved proj:$HC's holder to STARTING_PANE; restore
# it to ORCH_PANE before any other fixture reads it.
reg claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
reg claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null
# STARTING_PANE needs its OWN scope to test "starting is never eligible even
# with a live role+claim" without touching ORCH_PANE's grant; use $KB.
reg claim_acquire_proj "proj:$KB" "$MAIN_PANE" "$MAIN_BIRTH" "$STARTING_PANE" "$STARTING_BIRTH" "orchestrator@starting-co" >/dev/null
reg register_task run_starting task_starting worker_starting conductor_main \
  "$MAIN_PANE" "$MAIN_BIRTH" "$STARTING_PANE" "$STARTING_BIRTH" "$KB" "$KB-wt-starting" \
  starting-label starting-branch "" knowledge-base "" hook "" >/dev/null
# (left at the default `starting` state -- never transitioned to running)

printf '== ELIGIBILITY (direct, stubbed herdr — spawn-task.sh cannot be run managed in this sandbox) ==\n'
export HERDR_RUN_STATE_DIR="$STATE_ROOT"
source "$HERE/lib/run-registry.sh"
source "$HERE/lib/pane-guard.sh"
source "$HERE/lib/claims.sh"
herdr() {
  case "$1 $2" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":1,"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
        "$ORCH_PANE" "$ORCH_BIRTH" "$PLAIN_PANE" "$PLAIN_BIRTH" "$STARTING_PANE" "$STARTING_BIRTH" \
        "$OTHER_PANE" "$OTHER_BIRTH" "$MAIN_PANE" "$MAIN_BIRTH" "$RACE_PANE" "$RACE_BIRTH" ;;
    *) return 0 ;;
  esac
}
_elig() { pane_is_conductor_eligible "$1" "$2" 2>/dev/null && echo eligible || echo refused; }

check "E1: orchestrator (role+live proj:\$HC claim, own task running) is eligible for \$HC" \
  "$(_elig "$ORCH_PANE" "$HC")" "eligible"
check "E2: no-root-arg call keeps TODAY's behavior (running -> refused, unchanged)" \
  "$(_elig "$ORCH_PANE" "")" "refused"
check "N1: a plain running bound worker (no orchestrator role) stays refused" \
  "$(_elig "$PLAIN_PANE" "$HC")" "refused"
check "E3: the SAME orchestrator pane is refused for a project it holds no claim for" \
  "$(_elig "$ORCH_PANE" "$KB")" "refused"
check "N7: starting (never running) is refused even with a live role+claim" \
  "$(_elig "$STARTING_PANE" "$KB")" "refused"

printf -- '-- N3: stale generation (claim re-granted to a DIFFERENT pane) --\n'
register_role_cas "orchestrator@kb-other" "$OTHER_PANE" "$OTHER_BIRTH" sess ws "" "" >/dev/null
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$OTHER_PANE" "$OTHER_BIRTH" "orchestrator@kb-other" >/dev/null
check "N3: the superseded holder is refused (claim_holder now returns someone else)" \
  "$(_elig "$ORCH_PANE" "$HC")" "refused"
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null
check "N3-restore: re-granting back to ORCH_PANE makes it eligible again" \
  "$(_elig "$ORCH_PANE" "$HC")" "eligible"

printf -- '-- N4: expired claim --\n'
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" 1 >/dev/null
sleep 2
check "N4: an expired grant is refused (claim_holder's own expiry check)" \
  "$(_elig "$ORCH_PANE" "$HC")" "refused"
claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null

printf -- '-- N5: role unregistered (claim still live) --\n'
_sql "DELETE FROM roles WHERE label='orchestrator@herdr-control';" >/dev/null
check "N5: no live orchestrator role -> refused despite a live proj: claim" \
  "$(_elig "$ORCH_PANE" "$HC")" "refused"
register_role_cas "orchestrator@herdr-control" "$ORCH_PANE" "$ORCH_BIRTH" sess ws "" "" >/dev/null
check "N5-restore: re-registering the role makes it eligible again" \
  "$(_elig "$ORCH_PANE" "$HC")" "eligible"
unset -f herdr _elig
printf '== P1 (full pipeline, unmanaged — proves the EXISTING unconditional P2 scope check still lets this through) ==\n'
out=$(run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-task.sh "$HC_RAW" p1-branch 2>&1); rc=$?
check "exit 0" "$rc" "0"
[ "$rc" != 0 ] && echo "$out"

printf '== R1: the P1 child is routed to the ORCHESTRATOR, not Main (conductor_pane_id/birth) ==\n'
row=$(reg_sql "SELECT conductor_pane_id,conductor_pane_birth,state FROM tasks WHERE repo='$HC' AND branch='p1-branch';")
check "child conductor_pane_id=orchestrator" "$(printf '%s' "$row" | cut -d'|' -f1)" "$ORCH_PANE"
check "child conductor_pane_birth=orchestrator" "$(printf '%s' "$row" | cut -d'|' -f2)" "$ORCH_BIRTH"
printf '== R2: the orchestrator'"'"'s OWN task conductor is still Main (its own approvals are unaffected) ==\n'
orow=$(reg_sql "SELECT conductor_pane_id,conductor_pane_birth FROM tasks WHERE task_id='task_orch';")
check "orchestrator's own conductor_pane_id=Main" "$(printf '%s' "$orow" | cut -d'|' -f1)" "$MAIN_PANE"

printf '== F1 (security review #334): conductor_pane_id is bound to ancestry, never a self-asserted HERDR_PANE_ID ==\n'
out=$(env -u HERDR_MCP_CONDUCTOR_PANE -u HERDR_MCP_CONDUCTOR_BIRTH -u HERDR_CONDUCTOR_ID \
  HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" HERDR_WT_DIR="$WT_ROOT" HERDR_RUN_STATE_DIR="$STATE_ROOT" \
  HERDR_PANE_ID="not-the-orchestrator" HERDR_PANE_BIRTH="spoof-birth" \
  HERDR_FG_PANE="$ORCH_PANE" HERDR_FG_BIRTH="$ORCH_BIRTH" HERDR_FG_PID="$$" \
  bash "$HERE/spawn-task.sh" "$HC_RAW" f1-spoof quick /bin/true 2>&1); rc=$?
check "F1: spoofed HERDR_PANE_ID refused (exit 1)" "$rc" "1"
check "F1: no child row registered for the spoofed spawn" \
  "$(reg_sql "SELECT count(*) FROM tasks WHERE repo='$HC' AND branch='f1-spoof';")" "0"

printf '== F2 (security review #334): an orchestrator@* pane cannot use spawn-agent.sh (no task row -> no cap) ==\n'
out=$(run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-agent.sh "$HC_RAW" f2-agent 2>&1); rc=$?
check "F2: in-scope spawn-agent.sh by the orchestrator refused (exit 2)" "$rc" "2"
case "$out" in *"spawn only via spawn-task.sh"*) ok "F2: refusal names spawn-task.sh" ;; *) bad "F2: refusal message ($out)" ;; esac

printf '== N2: cross-project spawn refused (existing P2 check keeps passing, bound or not) ==\n'
out=$(run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-task.sh "$KB_RAW" n2-branch 2>&1); rc=$?
check "exit 2" "$rc" "2"

printf '== CAP: a 3rd concurrent/sequential child is refused (pilot cap=2); atomic with registration ==\n'
# P1 above already registered one non-terminal child under ORCH_PANE. Add a
# second directly (bypassing the slow tab/worktree machinery) to reach the cap.
reg register_task run_cap2 task_cap2 worker_cap2 conductor_x \
  "$ORCH_PANE" "$ORCH_BIRTH" cap2pane cap2birth "$HC" "$HC-wt-cap2" \
  cap2-label cap2-branch "" herdr-control "" hook "" >/dev/null
out=$(run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-task.sh "$HC_RAW" cap3-branch 2>&1); rc=$?
check "3rd child refused (exit 1)" "$rc" "1"
case "$out" in *"registration or source binding failed"*) ok "refusal surfaces as a registration failure" ;; *) bad "refusal message: $out" ;; esac

printf '== CAP-RACE: N concurrent register() calls for the SAME orchestrator never exceed the cap (TOCTOU) ==\n'
# A dedicated role/pane (RACE_PANE) so this never touches ORCH_PANE's own
# fixture rows -- the cap check only needs a live orchestrator@* role, no
# proj: claim (that gate is spawn-task.sh's P2 check, upstream of register()).
reg register_role_cas "orchestrator@race-co" "$RACE_PANE" "$RACE_BIRTH" sess ws "" "" >/dev/null
race_one() {   # n -> register one race-fixture child task
  local n="$1"
  ( export HERDR_RUN_STATE_DIR="$STATE_ROOT"
    source "$HERE/lib/run-registry.sh"
    task_json=$(jq -nc --arg run_id "race_run_$n" --arg task_id "race_task_$n" --arg worker_id "w$n" \
      --arg conductor_id "c" --arg conductor_pane_id "$RACE_PANE" --arg conductor_pane_birth "$RACE_BIRTH" \
      --arg pane_id "racepane$n" --arg pane_birth "racebirth$n" --arg repo "$HC" --arg worktree "$HC-wt-race$n" \
      --arg branch "race-br-$n" --arg trunk "" --arg project "herdr-control" --arg manifest "" --arg approval "hook" --arg label "race$n" \
      '$ARGS.named')
    _task_authorization_adapter register "$task_json" "" )
}
race_one 1 >/tmp/vb-race1.out 2>&1 &
race_one 2 >/tmp/vb-race2.out 2>&1 &
race_one 3 >/tmp/vb-race3.out 2>&1 &
wait
succ=$(reg_sql "SELECT COUNT(*) FROM tasks WHERE task_id LIKE 'race_task_%' AND state IN ('starting','running','blocked');")
check "exactly cap=2 of 3 racing registrations landed" "$succ" "2"

printf '== LEASE END: release ends future spawns (existing P2 check fires first); existing children keep running ==\n'
reg claim_release_force_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" >/dev/null
out=$(run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-task.sh "$HC_RAW" lease-end-branch 2>&1); rc=$?
# The orchestrator no longer holds a live proj: claim for $HC at all, so
# spawn-task.sh's EXISTING, unconditional P2 scope check (lines ~468-484,
# predates this feature) refuses first, before eligibility is ever
# consulted -- documented below (design note) rather than re-fenced here.
check "post-release spawn refused (exit 2, the existing scope check)" "$rc" "2"
row=$(reg_sql "SELECT state,conductor_pane_id FROM tasks WHERE task_id='task_cap2';")
check "existing child's task row untouched (still non-terminal)" "$(printf '%s' "$row" | cut -d'|' -f1)" "starting"
check "existing child's conductor_pane_id untouched (still the orchestrator)" "$(printf '%s' "$row" | cut -d'|' -f2)" "$ORCH_PANE"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
rm -rf "$stub_dir" "$WT_ROOT" "$STATE_ROOT" "$HC_RAW" "$KB_RAW" /tmp/vb-race1.out /tmp/vb-race2.out /tmp/vb-race3.out 2>/dev/null
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
