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
  *"bulk archive/recursive-copy after an earlier refusal"*) ok "reason names the bulk-extraction rule" ;;
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

printf '== B5: a refusal naming no protected file (e.g. #277 write/edit human-only) still does not arm STAGE-1 target matching ==\n'
RUN2=run_test2; TASK2=task_test2
seed_refusal "$RUN2" "$TASK2" "write/edit approval is human-only (#277)" \
  "Allow tool: write [complete payload not verified; panel text withheld]"
out="$(refusal_ledger_check "$RUN2" "$TASK2" "cat lib/run-registry.sh")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "retry of a file never itself refused stays quiet (no prior row named it)" || bad "rc=$rc out=[$out]"

printf '== B5: review finding — that SAME filename-less refusal MUST still arm the bulk rule ==\n'
out="$(refusal_ledger_check "$RUN2" "$TASK2" "git archive HEAD | tar -x -C /tmp/z")"; rc=$?
[ "$rc" -eq 1 ] && ok "bulk archive is flagged even though the arming refusal named no file (B5 fix)" || bad "rc=$rc, expected 1"

printf '== a second, different protected file in the same run+task is tracked independently ==\n'
RUN3=run_test3; TASK3=task_test3
seed_refusal "$RUN3" "$TASK3" "$REASON" "sed -i '' 's/x/y/' lib/command-policy.sh"
out="$(refusal_ledger_check "$RUN3" "$TASK3" "cat lib/command-policy.sh")"; rc=$?
[ "$rc" -eq 1 ] && ok "retry on the SAME refused file (command-policy.sh) is refused" || bad "rc=$rc"
out="$(refusal_ledger_check "$RUN3" "$TASK3" "cat lib/task-reservation.py")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a DIFFERENT protected file, never itself refused, stays quiet" || bad "rc=$rc out=[$out]"

printf '== B1 (review): single-quote-split filename bypasses literal-text matching ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" "cat lib/run-'registry'.sh")"; rc=$?
[ "$rc" -eq 1 ] && ok "single-quote-split filename is refused" || bad "rc=$rc, expected 1"

printf '== B1 (review): backslash-escaped filename bypasses literal-text matching ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" 'cat lib/run-registr\y.sh')"; rc=$?
[ "$rc" -eq 1 ] && ok "backslash-escaped filename is refused" || bad "rc=$rc, expected 1"

printf '== B1 (review): same-command shell-variable bypasses literal-text matching ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" 'f=run-registry; cat "lib/'"\$"'f.sh"')"; rc=$?
[ "$rc" -eq 1 ] && ok "variable-built filename is refused" || bad "rc=$rc, expected 1"

printf '== B1 (review): glob pattern bypasses literal-text matching ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" "cat lib/run-reg*.sh")"; rc=$?
[ "$rc" -eq 1 ] && ok "glob pattern naming the refused file is refused" || bad "rc=$rc, expected 1"

printf '== documented NOT-covered boundary: non-shell string concatenation (python3 -c) ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" 'python3 -c "open(chr(108)+chr(105)+chr(98))"')"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a value built by executing code is NOT resolved — documented gap, not a silent one; refusal_ledger_targets never executes text to classify it" || bad "rc=$rc out=[$out] — if this now fires, lib/refusal-ledger.sh's header comment claiming this is uncovered is stale"

printf '== B2 (review): uppercase filename bypasses case-sensitive matching (APFS is case-insensitive) ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" "cat lib/RUN-REGISTRY.SH")"; rc=$?
[ "$rc" -eq 1 ] && ok "uppercase filename is refused" || bad "rc=$rc, expected 1"

printf '== B3 (review): git -C/-c global options before archive were missed by the old bare regex ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" "git -C . archive HEAD | tar -x -C /tmp/out1")"; rc=$?
[ "$rc" -eq 1 ] && ok "git -C … archive is flagged" || bad "rc=$rc, expected 1"
out="$(refusal_ledger_check "$RUN" "$TASK" "git -c foo=bar archive HEAD | tar -x -C /tmp/out2")"; rc=$?
[ "$rc" -eq 1 ] && ok "git -c … archive is flagged" || bad "rc=$rc, expected 1"

printf '== B3 (review): recursive cp of an already-extracted tree (this repo'"'"'s actual 2026-10-29 shape) ==\n'
out="$(refusal_ledger_check "$RUN" "$TASK" "cp -R tmp/extracted /tmp/out3")"; rc=$?
[ "$rc" -eq 1 ] && ok "cp -R of a directory is flagged" || bad "rc=$rc, expected 1"
out="$(refusal_ledger_check "$RUN" "$TASK" "cp --recursive tmp/extracted /tmp/out4")"; rc=$?
[ "$rc" -eq 1 ] && ok "cp --recursive is flagged" || bad "rc=$rc, expected 1"
out="$(refusal_ledger_check run_other2 task_other2 "cp -R tmp/extracted /tmp/out5")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "cp -R in a never-refused run+task stays quiet" || bad "rc=$rc out=[$out]"
out="$(refusal_ledger_check "$RUN" "$TASK" "cp notes.txt /tmp/out6")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a non-recursive cp of one file stays quiet (not the bulk shape)" || bad "rc=$rc out=[$out]"

printf '== drift guard: hand-maintained _RL_PROTECTED_NAMES matches the real _CP_POLICY_FILE_RE ==\n'
drift_ok=1
while IFS= read -r n; do
  [ -n "$n" ] || continue
  _cp_imatch "$_CP_POLICY_FILE_RE" "a $n b" || { bad "name '$n' no longer matches _CP_POLICY_FILE_RE — update _RL_PROTECTED_NAMES"; drift_ok=0; }
done <<NAMES
$_RL_PROTECTED_NAMES
NAMES
[ "$drift_ok" -eq 1 ] && ok "every hand-listed protected name still matches the real regex"
name_count=$(printf '%s\n' "$_RL_PROTECTED_NAMES" | wc -l | tr -d ' ')
[ "$name_count" -eq 14 ] && ok "_RL_PROTECTED_NAMES has the expected 14 entries" || bad "_RL_PROTECTED_NAMES has $name_count entries, expected 14"
# 2 boundary-group pipes + 12 top-level separators (13 top-level items) + 1
# nested (py|sh) pipe = 15. A changed count here means _CP_POLICY_FILE_RE's
# shape changed (an added/removed protected file, most likely) and
# _RL_PROTECTED_NAMES needs a matching, hand-made update.
pipe_count=$(printf '%s' "$_CP_POLICY_FILE_RE" | grep -o '|' | wc -l | tr -d ' ')
[ "$pipe_count" -eq 15 ] && ok "_CP_POLICY_FILE_RE's pipe count is still 15 (no un-mirrored addition/removal)" || bad "_CP_POLICY_FILE_RE has $pipe_count pipes, expected 15 — update _RL_PROTECTED_NAMES to match"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
