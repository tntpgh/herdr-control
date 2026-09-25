#!/usr/bin/env bash
# Red proof for the pre-tool registration/ownership guard.
# A fleet-creating tool is allowed only for the current registered pane
# generation and worktree; ordinary tools still follow their existing policy.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export HERDR_RUN_STATE_DIR="$work/runs"
export PANE='w1:p1'
export BIRTH='generation-1'
export HERDR_PANE_ID="$PANE"
export HERDR_RUN_ID='run1'
export HERDR_TASK_ID='task1'
wt="$work/worktree"
mkdir -p "$wt/src"

herdr() {
  case "$1 $2" in
    'pane list')
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"}]}}\n' "$PANE" "$BIRTH" ;;
    *) return 0 ;;
  esac
}
export -f herdr

. "$here/lib/run-registry.sh"
register_task run1 task1 worker1 conductor1 w9:p9 cond-birth "$PANE" generation-1 /repo "$wt" 'impl:guard' feat/guard main >/dev/null
set_task_state run1 task1 running

good=0
bad=0
ok() { good=$((good + 1)); printf '  ok    %s\n' "$1"; }
not_ok() { bad=$((bad + 1)); printf '  FAIL  %s\n' "$1"; }
run_guard() { bash "$here/lib/pretool-registration.sh" "$@" >/dev/null 2>"$work/err"; }

printf '== unregistered worker refuses a fleet-creating tool ==\n'
HERDR_TASK_ID=missing run_guard task "$wt"; rc=$?
[ "$rc" -eq 8 ] && ok 'unregistered identity refused' || not_ok "unregistered rc=$rc"
grep -q 'not registered' "$work/err" && ok 'refusal names registration' || not_ok "message: $(cat "$work/err")"
run_extension_guard() {
  TEST_CWD="$1" bun -e 'const mod = await import("./agent-hooks/omp-herdr-control.ts"); const handlers = {}; mod.default({on: (event, handler) => { handlers[event] = handler; }}); const result = handlers.tool_call({toolName:"task", input:{cwd:process.env.TEST_CWD}}); console.log(result?.block ? "BLOCK" : "ALLOW");' 2>"$work/bun.err"
}

printf '== recycled pane generation refuses before the tool runs ==\n'
BIRTH=generation-2 run_guard task "$wt"; rc=$?
[ "$rc" -eq 8 ] && ok 'stale generation refused' || not_ok "stale generation rc=$rc"
grep -q 'recycled' "$work/err" && ok 'refusal names recycled pane' || not_ok "message: $(cat "$work/err")"
BIRTH=generation-1

printf '== current registered task owns the pane and worktree ==\n'
run_guard task "$wt/src"; rc=$?
[ "$rc" -eq 0 ] && ok 'current generation allowed' || not_ok "current task rc=$rc: $(cat "$work/err")"
printf '== OMP tool_call wiring blocks and allows the same cases ==\n'
[ "$(HERDR_TASK_ID=missing run_extension_guard "$wt")" = BLOCK ] \
  && ok 'OMP hook blocks an unregistered delegation' \
  || not_ok "OMP unregistered result: $(cat "$work/bun.err")"
BIRTH=generation-2
[ "$(run_extension_guard "$wt")" = BLOCK ] \
  && ok 'OMP hook blocks a recycled generation' \
  || not_ok "OMP stale-generation result: $(cat "$work/bun.err")"
BIRTH=generation-1
[ "$(run_extension_guard "$wt/src")" = ALLOW ] \
  && ok 'OMP hook allows the current registered task' \
  || not_ok "OMP current-task result: $(cat "$work/bun.err")"


printf '== unregistered ordinary tools remain outside this guard ==\n'
HERDR_TASK_ID=missing run_guard bash "$wt"; rc=$?
[ "$rc" -eq 0 ] && ok 'ordinary tool delegated to existing policy' || not_ok "ordinary tool rc=$rc"

printf '\n%d passed, %d failed\n' "$good" "$bad"
[ "$bad" -eq 0 ]
