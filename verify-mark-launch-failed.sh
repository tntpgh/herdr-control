#!/usr/bin/env bash
# verify-mark-launch-failed.sh — proves mark-launch-failed.sh (fix/launch-
# receipt-r2) against a SCRATCH registry (never the live one at
# ~/.local/state/herdr/runs) with a stubbed herdr: deadness is re-verified
# from the pane, never taken on the caller's word; `--superseded-by` is
# re-checked against a real registered task (same worktree+branch, created
# later); an already-terminal row and a genuinely LIVE agent pane both
# refuse.
#
#   bash verify-mark-launch-failed.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
. "$here/lib/run-registry.sh"
registry_init
DB="$HERDR_RUN_STATE_DIR/registry.sqlite3"
_q() { sqlite3 -noheader "$DB" "$1" 2>/dev/null; }

# ---- the stub ----------------------------------------------------------------
# PANES / FG_PID (space-separated "pane:birth" pairs / pid) drive what
# `pane list` / `pane process-info` report, so each scenario below controls
# exactly what mark-launch-failed.sh's own deadness re-check sees.
herdr() {
  case "$1 $2" in
    "pane list")
      printf '{"result":{"panes":['
      local first=1 pb
      for pb in ${PANES:-}; do
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"pane_id":"%s","terminal_id":"%s"}' "${pb%%:*}" "${pb##*:}"
      done
      printf ']}}\n' ;;
    "pane process-info")
      local target=""; local i
      for ((i=1; i<=$#; i++)); do [ "${!i}" = "--pane" ] && { j=$((i+1)); target="${!j}"; }; done
      if [ "$target" = "${AGENT_PANE:-}" ]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"name":"claude","cmdline":"claude"}]}}}\n'
      else
        printf '{"result":{"process_info":{"foreground_processes":[{"name":"zsh","cmdline":"-zsh"}]}}}\n'
      fi ;;
    *) printf '{"result":{}}\n' ;;
  esac
}
export -f herdr

run() {  # run <run_id> <task_id> [args...]
  env PANES="${PANES:-}" AGENT_PANE="${AGENT_PANE:-}" HERDR_RUN_STATE_DIR="$HERDR_RUN_STATE_DIR" \
    PATH="$PATH" bash "$here/mark-launch-failed.sh" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt"
}
reg() {  # reg <task_id> <pane_id> <pane_birth> <worktree> <branch> [created_at_offset_seconds]
  local task_id="$1" pane_id="$2" pane_birth="$3" wt="$4" branch="$5" off="${6:-0}"
  register_task r1 "$task_id" w1 c1 "" "" "$pane_id" "$pane_birth" repo "$wt" "label:$task_id" "$branch" trunk >/dev/null
  if [ "$off" != 0 ]; then
    _q "UPDATE tasks SET created_at = strftime('%Y-%m-%dT%H:%M:%SZ', created_at, '$off seconds') WHERE task_id='$task_id';" >/dev/null
  fi
}
state_of() { _q "SELECT state FROM tasks WHERE task_id='$1';"; }
last_event() { _q "SELECT payload FROM events WHERE task_id='$1' AND type='launch_failed_marked' ORDER BY sequence DESC LIMIT 1;"; }

printf '== no such task: refused, exit 1 ==\n'
PANES="" AGENT_PANE=""
run r1 ghost-task; rc=$?
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
grep -q 'no task' "$WORK/err.txt" && ok "names the reason" || bad "stderr: $(cat "$WORK/err.txt")"

printf '== already-terminal task (completed): refused, exit 1, no double-marking ==\n'
reg t-done pD birthD /wt/done br-done
set_task_state r1 t-done completed shipped "local test" >/dev/null 2>&1 || true
# shipped needs real proof; fall back to no-follow-on, which needs none.
set_task_state r1 t-done completed no-follow-on >/dev/null 2>&1 || true
PANES="" AGENT_PANE=""
run r1 t-done; rc=$?
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
grep -q 'already terminal' "$WORK/err.txt" && ok "names the reason" || bad "stderr: $(cat "$WORK/err.txt")"

printf '== pane genuinely alive and running an agent: refused, state unchanged ==\n'
reg t-alive pAlive birthAlive /wt/alive br-alive
set_task_state r1 t-alive running >/dev/null
PANES="pAlive:birthAlive" AGENT_PANE="pAlive"
run r1 t-alive; rc=$?
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
grep -qi 'is alive and running an agent' "$WORK/err.txt" && ok "names the reason" || bad "stderr: $(cat "$WORK/err.txt")"
[ "$(state_of t-alive)" = "running" ] && ok "state untouched (still running)" || bad "state=$(state_of t-alive)"

printf '== pane gone entirely: marked launch_failed, disposition=launch_failed, default reason ==\n'
reg t-gone pGone birthGone /wt/gone br-gone
set_task_state r1 t-gone running >/dev/null
PANES="" AGENT_PANE=""
run r1 t-gone; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
[ "$(state_of t-gone)" = "launch_failed" ] && ok "state=launch_failed" || bad "state=$(state_of t-gone)"
printf '%s' "$(last_event t-gone)" | jq -e '.disposition == "launch_failed"' >/dev/null 2>&1 \
  && ok "event disposition=launch_failed" || bad "event: $(last_event t-gone)"
printf '%s' "$(last_event t-gone)" | jq -e '.dead_evidence | contains("no longer exists")' >/dev/null 2>&1 \
  && ok "event names the pane as gone" || bad "event: $(last_event t-gone)"
printf '%s' "$(last_event t-gone)" | jq -e '.reason == "operator-marked dead task"' >/dev/null 2>&1 \
  && ok "default reason recorded" || bad "event: $(last_event t-gone)"

printf '== pane recycled (live birth != registered birth): marked launch_failed, custom reason ==\n'
reg t-recycled pRecy birthOld /wt/recy br-recy
set_task_state r1 t-recycled running >/dev/null
PANES="pRecy:birthNEW" AGENT_PANE=""
run r1 t-recycled --reason "confirmed dead by conductor after pB6:p2 incident review"; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
[ "$(state_of t-recycled)" = "launch_failed" ] && ok "state=launch_failed" || bad "state=$(state_of t-recycled)"
printf '%s' "$(last_event t-recycled)" | jq -e '.dead_evidence | contains("recycled")' >/dev/null 2>&1 \
  && ok "event names the pane as recycled" || bad "event: $(last_event t-recycled)"
printf '%s' "$(last_event t-recycled)" | jq -e '.reason | contains("pB6:p2")' >/dev/null 2>&1 \
  && ok "custom reason recorded verbatim" || bad "event: $(last_event t-recycled)"

printf '== pane alive but a bare shell (not a recognized agent): marked launch_failed — the wB6:p2 shape ==\n'
reg t-shell pShell birthShell /wt/shell br-shell
set_task_state r1 t-shell running >/dev/null
PANES="pShell:birthShell" AGENT_PANE=""
run r1 t-shell; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
[ "$(state_of t-shell)" = "launch_failed" ] && ok "state=launch_failed" || bad "state=$(state_of t-shell)"
printf '%s' "$(last_event t-shell)" | jq -e '.dead_evidence | contains("bare shell")' >/dev/null 2>&1 \
  && ok "event names the pane as a bare shell" || bad "event: $(last_event t-shell)"

printf '== --superseded-by a REAL newer same-worktree/branch task: marked launch_failed, disposition=superseded ==\n'
reg t-old-1 pOld1 birthOld1 /wt/super br-super
set_task_state r1 t-old-1 running >/dev/null
reg t-new-1 pNew1 birthNew1 /wt/super br-super 5
PANES="" AGENT_PANE=""
run r1 t-old-1 --superseded-by t-new-1; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
[ "$(state_of t-old-1)" = "launch_failed" ] && ok "state=launch_failed (same terminal state, not a second one)" || bad "state=$(state_of t-old-1)"
printf '%s' "$(last_event t-old-1)" | jq -e '.disposition == "superseded"' >/dev/null 2>&1 \
  && ok "event disposition=superseded" || bad "event: $(last_event t-old-1)"
printf '%s' "$(last_event t-old-1)" | jq -e '.superseded_by == "t-new-1"' >/dev/null 2>&1 \
  && ok "event names the superseding task" || bad "event: $(last_event t-old-1)"

printf '== --superseded-by a task in a DIFFERENT worktree: refused, not marked ==\n'
reg t-old-2 pOld2 birthOld2 /wt/super2 br-super2
set_task_state r1 t-old-2 running >/dev/null
reg t-other wtOther birthOther /wt/unrelated br-unrelated 5
PANES="" AGENT_PANE=""
run r1 t-old-2 --superseded-by t-other; rc=$?
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
grep -q 'does not match' "$WORK/err.txt" && ok "names the mismatch" || bad "stderr: $(cat "$WORK/err.txt")"
[ "$(state_of t-old-2)" = "running" ] && ok "state untouched" || bad "state=$(state_of t-old-2)"

printf '== --superseded-by a task registered BEFORE this one: refused, not marked ==\n'
reg t-new-3 pNew3 birthNew3 /wt/super3 br-super3
set_task_state r1 t-new-3 running >/dev/null
reg t-old-3 pOld3 birthOld3 /wt/super3 br-super3 -10
PANES="" AGENT_PANE=""
run r1 t-new-3 --superseded-by t-old-3; rc=$?
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
grep -q 'not registered after' "$WORK/err.txt" && ok "names the ordering problem" || bad "stderr: $(cat "$WORK/err.txt")"
[ "$(state_of t-new-3)" = "running" ] && ok "state untouched" || bad "state=$(state_of t-new-3)"

printf '== --superseded-by a nonexistent task: refused ==\n'
reg t-old-4 pOld4 birthOld4 /wt/super4 br-super4
set_task_state r1 t-old-4 running >/dev/null
PANES="" AGENT_PANE=""
run r1 t-old-4 --superseded-by no-such-task; rc=$?
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc: $(cat "$WORK/out.txt") $(cat "$WORK/err.txt")"
grep -q 'does not match any registered task' "$WORK/err.txt" && ok "names the problem" || bad "stderr: $(cat "$WORK/err.txt")"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo PASS; exit 0; else echo FAIL; exit 1; fi
