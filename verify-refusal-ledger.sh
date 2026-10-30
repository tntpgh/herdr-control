#!/usr/bin/env bash
# verify-refusal-ledger.sh — proves lib/refusal-ledger.sh fires on a real
# retry of a refused operation and stays quiet everywhere else.
#
# SPEC: .handoffs/SPEC.md. "A real negative" here means: an
# `approval_escalated` row shaped EXACTLY like herdr-select.sh's
# `_refuse_non_human` already writes today (verdict/reason/pane/prompt_id/
# command), via the SAME append_event function herdr-select.sh calls --
# nothing here reimplements or stubs that shape. This suite seeds rows with
# append_event directly (no herdr-select.sh invocation: this module reads
# the registry, it does not need the script that happens to write it today)
# into a sandboxed registry (HERDR_RUN_STATE_DIR), never the live one.
#
#   bash verify-refusal-ledger.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"

# shellcheck source=/dev/null
. "$here/lib/run-registry.sh"
# shellcheck source=/dev/null
. "$here/lib/command-policy.sh"
# shellcheck source=/dev/null
. "$here/lib/refusal-ledger.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# seed_refusal <run> <task> <reason> <command> — exactly the payload shape
# herdr-select.sh's _refuse_non_human already appends today.
seed_refusal() {
  local run="$1" task="$2" reason="$3" cmd="$4"
  append_event "$run" "$task" approval_escalated \
    "$(jq -nc --arg v reserved --arg r "$reason" --arg p w1:p1 --arg pid deadbeef --arg c "$cmd" \
       '{verdict:$v, reason:$r, pane:$p, prompt_id:$pid, command:$c}')" >/dev/null
}

RUN=run_test1; TASK=task_test1
REASON='merge, governance, push, or control weakening remains human-only'
seed_refusal "$RUN" "$TASK" "$REASON" \
  "cp lib/escalation.sh lib/run-registry.sh tmp/r5/mutant-n6/"

printf '== a real negative: reworded retry of the exact refused command ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" \
  "git show 83f72c1:lib/run-registry.sh | grep -n foo | head -20")"; rc=$?
[ "$rc" -eq 1 ] && ok "reworded git-show retry is refused (rc=1)" || bad "rc=$rc, expected 1"
case "$out" in
  *"retry of an already-refused operation"*"run-registry.sh"*) ok "reason names 'retry of an already-refused operation' and the path" ;;
  *) bad "reason missing expected text: [$out]" ;;
esac

printf '== split across more than one call, different tool shape ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" "cat lib/run-registry.sh")"; rc=$?
[ "$rc" -eq 1 ] && ok "cat retry (different verb entirely) is refused" || bad "rc=$rc, expected 1"

printf '== different tool, same protected path, no filename-matching wording in common ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" \
  "tar -czf /tmp/x.tgz lib/run-registry.sh")"; rc=$?
[ "$rc" -eq 1 ] && ok "tar retry is refused" || bad "rc=$rc, expected 1"

printf '== bulk git-archive after a refusal in this run+task, no filename in argv at all ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" \
  "git archive 83f72c1 | tar -x -C tmp/base")"; rc=$?
[ "$rc" -eq 1 ] && ok "bulk archive after a refusal is flagged (rc=1)" || bad "rc=$rc, expected 1"
case "$out" in
  *"bulk archive/extraction after an earlier protected-path refusal"*) ok "reason names the bulk-extraction rule" ;;
  *) bad "reason missing expected text: [$out]" ;;
esac

printf '== goes quiet on an unrelated op in the SAME refused run+task ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" "git status")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "unrelated git status is untouched" || bad "rc=$rc out=[$out]"
out="$(refusal_ledger_check "$RUN" "$TASK" "git commit -m 'wip'")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "unrelated git commit is untouched" || bad "rc=$rc out=[$out]"

printf '== goes quiet on an unrelated run+task that was never refused ==\n'
out="$(refusal_ledger_check run_other task_other "cat lib/run-registry.sh")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a fresh run+task is unaffected by another task's refusal" || bad "rc=$rc out=[$out]"
out="$(refusal_ledger_check run_other task_other "git archive HEAD | tar -x -C /tmp/y")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "bulk archive in a never-refused run+task is untouched" || bad "rc=$rc out=[$out]"

printf '== goes quiet on the FIRST attempt (nothing refused yet) ==\n'
out="$(refusal_ledger_check run_fresh task_fresh "cat lib/run-registry.sh")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a never-refused run+task's first protected-path command is the classifier's job, not the ledger's" || bad "rc=$rc out=[$out]"

printf '== a refusal unrelated to any protected path never pollutes the ledger ==\n'
RUN2=run_test2; TASK2=task_test2
seed_refusal "$RUN2" "$TASK2" "write/edit approval is human-only (#277)" \
  "Allow tool: write [complete payload not verified; panel text withheld]"
out="$(refusal_ledger_check "$RUN2" "$TASK2" "cat lib/run-registry.sh")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a non-protected-path refusal records no target; retry of an unrelated file stays quiet" || bad "rc=$rc out=[$out]"
out="$(refusal_ledger_check "$RUN2" "$TASK2" "git archive HEAD | tar -x -C /tmp/z")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "bulk-archive rule only arms on an ACTUAL protected-path refusal, not any refusal" || bad "rc=$rc out=[$out]"

printf '== a second, different protected file in the same run+task is tracked independently ==\n'
RUN3=run_test3; TASK3=task_test3
seed_refusal "$RUN3" "$TASK3" "$REASON" "sed -i '' 's/x/y/' lib/command-policy.sh"
out="$(refusal_ledger_check "$RUN3" "$TASK3" "cat lib/command-policy.sh")"; rc=$?
[ "$rc" -eq 1 ] && ok "retry on the SAME refused file (command-policy.sh) is refused" || bad "rc=$rc"
out="$(refusal_ledger_check "$RUN3" "$TASK3" "cat lib/task-reservation.py")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a DIFFERENT protected file, never itself refused, stays quiet" || bad "rc=$rc out=[$out]"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
