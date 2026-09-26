#!/usr/bin/env bash
# Red proof for the pre-tool native-delegation guard.
# Fleet-creating native tools are always refused; ordinary tools still follow
# their existing policy.
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

printf '== native fleet creation refuses even for registered workers ==\n'
HERDR_TASK_ID=missing run_guard task "$wt"; rc=$?
[ "$rc" -eq 8 ] && ok 'unregistered delegation refused' || not_ok "unregistered rc=$rc"
HERDR_TASK_ID=missing run_guard taskcreate "$wt"; rc=$?
[ "$rc" -eq 8 ] && ok 'unregistered taskcreate refused' || not_ok "unregistered taskcreate rc=$rc"
grep -q 'spawn-task.sh' "$work/err" && ok 'refusal points to registered spawn path' || not_ok "message: $(cat "$work/err")"
run_guard task "$wt/src"; rc=$?
[ "$rc" -eq 8 ] && ok 'current registered worker still cannot create native task descendants' || not_ok "current task rc=$rc"
run_guard agent "$wt/src"; rc=$?
[ "$rc" -eq 8 ] && ok 'native agent creation refused' || not_ok "native agent rc=$rc"
run_guard taskcreate "$wt/src"; rc=$?
[ "$rc" -eq 8 ] && ok 'current registered worker still cannot taskcreate native descendants' || not_ok "current taskcreate rc=$rc"

printf '== MCP delegation-shaped tools fail closed, read-only MCP observers pass ==\n'
for tool in mcp__taskcreate mcp__spawn mcp__delegate; do
  run_guard "$tool" "$wt/src"; rc=$?
  [ "$rc" -eq 8 ] && ok "shell guard blocks $tool" || not_ok "$tool rc=$rc"
done
run_guard mcp__filesystem__read_file "$wt/src"; rc=$?
[ "$rc" -eq 0 ] && ok 'shell guard allows audited safe MCP read' || not_ok "safe MCP read rc=$rc"

run_extension_guard() {
  TEST_CWD="$1" TEST_TOOL="${2:-task}" bun -e 'const mod = await import("./agent-hooks/omp-herdr-control.ts"); const handlers = {}; mod.default({on: (event, handler) => { handlers[event] = handler; }}); const result = handlers.tool_call({toolName:process.env.TEST_TOOL, input:{cwd:process.env.TEST_CWD}}); console.log(result?.block ? "BLOCK" : "ALLOW");' 2>"$work/bun.err"
}

printf '== OMP tool_call wiring blocks native delegation ==\n'
[ "$(HERDR_TASK_ID=missing run_extension_guard "$wt")" = BLOCK ] \
  && ok 'OMP hook blocks unregistered native delegation' \
  || not_ok "OMP unregistered result: $(cat "$work/bun.err")"
[ "$(HERDR_TASK_ID=missing run_extension_guard "$wt" taskcreate)" = BLOCK ] \
  && ok 'OMP hook blocks unregistered native taskcreate' \
  || not_ok "OMP unregistered taskcreate result: $(cat "$work/bun.err")"
[ "$(run_extension_guard "$wt/src")" = BLOCK ] \
  && ok 'OMP hook blocks current registered native delegation' \
  || not_ok "OMP current-task result: $(cat "$work/bun.err")"
[ "$(run_extension_guard "$wt/src" taskcreate)" = BLOCK ] \
  && ok 'OMP hook blocks current registered native taskcreate' \
  || not_ok "OMP current-task taskcreate result: $(cat "$work/bun.err")"
for tool in mcp__taskcreate mcp__spawn mcp__delegate; do
  [ "$(run_extension_guard "$wt/src" "$tool")" = BLOCK ] \
    && ok "OMP hook blocks $tool" \
    || not_ok "OMP $tool result: $(cat "$work/bun.err")"
done
[ "$(run_extension_guard "$wt/src" mcp__filesystem__read_file)" = ALLOW ] \
  && ok 'OMP hook allows audited safe MCP read' \
  || not_ok "OMP safe MCP read result: $(cat "$work/bun.err")"
run_guard taskupdate "$wt/src"; rc=$?
[ "$rc" -eq 0 ] && ok 'native taskupdate observer stays allowed' || not_ok "taskupdate rc=$rc"
[ "$(run_extension_guard "$wt/src" taskupdate)" = ALLOW ] \
  && ok 'OMP hook leaves native taskupdate allowed' \
  || not_ok "OMP taskupdate result: $(cat "$work/bun.err")"


printf '== unregistered ordinary tools remain outside this guard ==\n'
HERDR_TASK_ID=missing run_guard bash "$wt"; rc=$?
[ "$rc" -eq 0 ] && ok 'ordinary tool delegated to existing policy' || not_ok "ordinary tool rc=$rc"

printf '\n%d passed, %d failed\n' "$good" "$bad"
[ "$bad" -eq 0 ]
