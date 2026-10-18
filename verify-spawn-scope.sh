#!/usr/bin/env bash
# verify-spawn-scope.sh — pins plan v2 §6.1 (.handoffs/SPEC.md
# feat/orch-p2-substrate): an orchestrator@<project> pane may spawn only
# into a repo it holds a live proj: claim for. Reuses the fixture pattern
# verify-spawn-spec-proof.sh already uses (herdr stub, real spawn-task.sh /
# spawn-agent.sh via PATH, a throwaway registry) and extends the stub so
# `herdr pane list` + `herdr pane process-info` make caller_pane_from_ancestry
# resolve to a FIXTURE pane via this process's real ancestry (HERDR_FG_PID),
# not a self-asserted id — the same signal spawn-task.sh itself trusts.
#
#   bash verify-spawn-scope.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/repo-root.sh
source "$HERE/lib/repo-root.sh"

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# stub herdr: `pane list` returns whichever fixture pane HERDR_FG_PANE names
# (empty -> no panes, so caller_pane_from_ancestry fails closed-to-"no
# identity" and the project-scope check is a no-op, same as an ordinary
# human/Main caller today); `pane process-info` maps that pane's foreground
# process to HERDR_FG_PID, which test runs set to THIS SCRIPT's own $$ (the
# real parent of the `bash spawn-task.sh` child it launches) — so ancestry
# resolution is exercised for real, never faked by an env var spawn-task.sh
# itself would read.
stub_dir=$(mktemp -d)
cat > "$stub_dir/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create")
    printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1","terminal_id":"term1"}}}\n' ;;
  "pane run") : ;;
  "pane list")
    if [ -n "${HERDR_FG_PANE:-}" ]; then
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
        "$HERDR_FG_PANE" "${HERDR_FG_BIRTH:-birth}"
    else
      printf '{"result":{"panes":[]}}\n'
    fi ;;
  "pane process-info")
    if [ -n "${HERDR_FG_PID:-}" ]; then
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s}]}}}\n' "$HERDR_FG_PID"
    else
      printf '{"result":{"process_info":{"foreground_processes":[]}}}\n'
    fi ;;
  *) printf '{"result":{"workspace":{"workspace_id":"w1"},"workspaces":[],"panes":[],"tabs":[]}}\n' ;;
esac
STUB
chmod +x "$stub_dir/herdr"

WT_ROOT=$(mktemp -d); WT_ROOT=$(cd "$WT_ROOT" && pwd -P)
STATE_ROOT=$(mktemp -d)   # ONE shared registry for the whole suite: roles/claims must persist across calls

HC_RAW=$(mktemp -d); git -C "$HC_RAW" init -q -b main 2>/dev/null
git -C "$HC_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
KB_RAW=$(mktemp -d); git -C "$KB_RAW" init -q -b main 2>/dev/null
git -C "$KB_RAW" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# Normalize exactly the way spawn-task.sh itself does (repo_root, then pwd -P)
# so the proj: scope granted below is byte-identical to the one it checks.
HC=$(cd "$(repo_root "$HC_RAW")" && pwd -P)
KB=$(cd "$(repo_root "$KB_RAW")" && pwd -P)

ORCH_PANE="orcpane1"; ORCH_BIRTH="orcbirth1"
MAIN_PANE="mainpane1"; MAIN_BIRTH="mainbirth1"

run_as() {   # <fg_pane|""> <fg_birth> <script> <repo> <branch> [extra args...]
  local fg_pane="$1" fg_birth="$2" script="$3" repo="$4" branch="$5"; shift 5
  env HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" \
    HERDR_WT_DIR="$WT_ROOT" HERDR_RUN_STATE_DIR="$STATE_ROOT" \
    HERDR_FG_PANE="$fg_pane" HERDR_FG_BIRTH="$fg_birth" HERDR_FG_PID="$$" \
    bash "$HERE/$script" "$repo" "$branch" "$@" quick /bin/true
}

# ---- fixtures: Main grants orch@herdr-control exactly proj:$HC -------------
( # subshell: source the registry libs against the shared STATE_ROOT once,
  # to seed roles + the proj: claim without duplicating a CLI.
  export HERDR_RUN_STATE_DIR="$STATE_ROOT"
  # shellcheck source=lib/run-registry.sh
  source "$HERE/lib/run-registry.sh"
  # shellcheck source=lib/claims.sh
  source "$HERE/lib/claims.sh"
  registry_init >/dev/null
  register_role_cas main "$MAIN_PANE" "$MAIN_BIRTH" sess ws "" "" >/dev/null
  register_role_cas "orchestrator@herdr-control" "$ORCH_PANE" "$ORCH_BIRTH" sess ws "" "" >/dev/null
  claim_acquire_proj "proj:$HC" "$MAIN_PANE" "$MAIN_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" "orchestrator@herdr-control" >/dev/null
) || { echo "fixture setup failed" >&2; exit 1; }

printf '== S1: orchestrator@herdr-control spawns into knowledge-base (no proj: claim) -> refused ==\n'
before=$(find "$WT_ROOT" -mindepth 1 -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')
out=$(run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-task.sh "$KB_RAW" s1-branch 2>&1); rc=$?
check "exit 2" "$rc" "2"
case "$out" in *"spawn_scope"*|*"may spawn only into its own project"*) ok "refusal names project scope" ;; *) bad "refusal message: $out" ;; esac
after=$(find "$WT_ROOT" -mindepth 1 -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')
check "nothing created (no worktree, no tab)" "$after" "$before"

printf '== S2: --project herdr-control does not change the real check (label ignored) ==\n'
out=$(run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-task.sh "$KB_RAW" s2-branch --project herdr-control 2>&1); rc=$?
check "still refused (rc=2)" "$rc" "2"

printf '== S3: an inherited _spawn_scope_authorized_by_receipt=1 cannot skip P2 (only a verified, claimed receipt can) ==\n'
out=$(_spawn_scope_authorized_by_receipt=1 run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-task.sh "$KB_RAW" s3-branch 2>&1); rc=$?
check "env-injected receipt flag still refused (rc=2)" "$rc" "2"

printf '== S4: ancestry resolves the orchestrator; HERDR_PANE_ID pointing at Main does not override it ==\n'
out=$(HERDR_PANE_ID="$MAIN_PANE" HERDR_PANE_BIRTH="$MAIN_BIRTH" \
  HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" HERDR_WT_DIR="$WT_ROOT" HERDR_RUN_STATE_DIR="$STATE_ROOT" \
  HERDR_FG_PANE="$ORCH_PANE" HERDR_FG_BIRTH="$ORCH_BIRTH" HERDR_FG_PID="$$" \
  bash "$HERE/spawn-task.sh" "$KB_RAW" s4-branch quick /bin/true 2>&1); rc=$?
check "ancestry wins over a Main-pointing HERDR_PANE_ID (rc=2)" "$rc" "2"

printf '== S5: claim_acquire proj: directly from the orchestrator (not Main) is refused ==\n'
out=$( (export HERDR_RUN_STATE_DIR="$STATE_ROOT"; source "$HERE/lib/run-registry.sh"; source "$HERE/lib/claims.sh"; \
       claim_acquire_proj "proj:$KB" "$ORCH_PANE" "$ORCH_BIRTH" "$ORCH_PANE" "$ORCH_BIRTH" 2>&1) ); rc=$?
check "orchestrator cannot self-grant proj: (rc=1)" "$rc" "1"

printf '== S6: spawn-agent.sh gets the same refusal ==\n'
out=$(run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-agent.sh "$KB_RAW" s6-branch 2>&1); rc=$?
check "spawn-agent.sh refuses too (rc=2)" "$rc" "2"

printf '\n== P+: positive controls (S1-S6 are not vacuous) ==\n'
out=$(run_as "$ORCH_PANE" "$ORCH_BIRTH" spawn-task.sh "$HC_RAW" p-pos-branch 2>&1); rc=$?
check "orchestrator spawning into ITS OWN project succeeds" "$rc" "0"
out=$(run_as "" "" spawn-task.sh "$KB_RAW" p-main-branch 2>&1); rc=$?
check "an ordinary caller (no orchestrator role resolved) is unaffected" "$rc" "0"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
rm -rf "$stub_dir" "$WT_ROOT" "$STATE_ROOT" "$HC_RAW" "$KB_RAW" 2>/dev/null
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
