#!/usr/bin/env bash
# verify-wait-for-blocked.sh — proof that wait-for-blocked.sh's argument
# parsing, watch-list scoping, and blocked/timeout reporting behave as
# documented — in particular a regression test for the single-argument-form
# bug (independent review finding): `shift 2` is all-or-nothing in bash, so
# a lone `poll_seconds` argument used to leave itself sitting in $* and get
# mistaken for a pane id, silently degrading "watch everything" into "watch
# a pane that doesn't exist."
#
# herdr is stubbed as an exported bash FUNCTION (same technique as
# verify-select-policy.sh/verify-layout.sh) serving canned `pane list`/
# `pane read` responses, so what's verified is the shipping script's
# argument handling and output, not a reimplementation of it.
#
#   bash verify-wait-for-blocked.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# ---- the stub ---------------------------------------------------------------
# HERDR_PANES_JSON drives `pane list`; HERDR_READ_TEXT drives `pane read`.
export HERDR_PANES_JSON="$WORK/panes.json"
export HERDR_READ_TEXT="$WORK/read.txt"
herdr() {
  case "$1 $2" in
    "pane list") cat "$HERDR_PANES_JSON" ;;
    "pane read") cat "$HERDR_READ_TEXT" 2>/dev/null ;;
    *) echo "stub herdr: unhandled call: $*" >&2; return 1 ;;
  esac
}
export -f herdr

none_blocked() { printf '{"result":{"panes":[{"pane_id":"w1:p1","label":"idle","workspace_id":"ws1","agent_status":"working"}]}}\n' > "$HERDR_PANES_JSON"; }
one_blocked()  { printf '{"result":{"panes":[{"pane_id":"w1:p1","label":"idle","workspace_id":"ws1","agent_status":"working"},{"pane_id":"w2:p1","label":"stuck","workspace_id":"ws2","agent_status":"blocked"}]}}\n' > "$HERDR_PANES_JSON"; }
two_blocked()  { printf '{"result":{"panes":[{"pane_id":"w2:p1","label":"stuck-a","workspace_id":"ws2","agent_status":"blocked"},{"pane_id":"w3:p1","label":"stuck-b","workspace_id":"ws3","agent_status":"blocked"}]}}\n' > "$HERDR_PANES_JSON"; }
printf 'Do you want to proceed?\n1. Yes\n2. No\n' > "$HERDR_READ_TEXT"

wfb() { bash "$here/wait-for-blocked.sh" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt"; }

printf '== 0 args: default interval/max, watches every pane ==\n'
one_blocked
wfb; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 (found a blocked pane)" || bad "exit $rc (expected 0): $(cat "$WORK/err.txt")"
grep -q "w2:p1" "$WORK/out.txt" && ok "reports the blocked pane" || bad "blocked pane missing: $(cat "$WORK/out.txt")"
grep -q "Do you want to proceed" "$WORK/out.txt" && ok "shows the prompt text so the caller can answer without another round trip" || bad "prompt not shown"

printf '== REGRESSION: a single numeric argument (poll_seconds only) still watches every pane ==\n'
# Before the fix, `shift 2` failed on exactly one positional arg and left it
# in $*, so watch_list became "1" — a bogus pane id nothing ever matches —
# and this call would have timed out (exit 3) instead of finding w2:p1.
one_blocked
wfb 1; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 — watches all panes, not a phantom pane named \"1\"" || bad "exit $rc (expected 0) — single-arg form is broken again"
grep -q "w2:p1" "$WORK/out.txt" && ok "still reports the blocked pane" || bad "blocked pane missing: $(cat "$WORK/out.txt")"

printf '== 2 args (interval + max, no pane ids): watches every pane ==\n'
one_blocked
wfb 1 5; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc (expected 0)"
grep -q "w2:p1" "$WORK/out.txt" && ok "reports the blocked pane" || bad "blocked pane missing"

printf '== 3+ args (interval + max + pane ids): watches ONLY the named panes ==\n'
two_blocked
wfb 1 5 w3:p1; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 — the named pane is blocked" || bad "exit $rc (expected 0)"
grep -q "w3:p1" "$WORK/out.txt" && ok "reports the named blocked pane" || bad "named pane missing: $(cat "$WORK/out.txt")"
grep -q "w2:p1" "$WORK/out.txt" && bad "reported a pane that was never in the watch list!" || ok "did NOT report the other blocked pane — it wasn't being watched"

printf '== an unwatched blocked pane is correctly ignored -> times out ==\n'
one_blocked   # only w2:p1 is blocked, and we watch a DIFFERENT pane
wfb 0 2 w9:p9; rc=$?
[ "$rc" -eq 3 ] && ok "exit 3 (timed out) — the blocked pane wasn't on our watch list" || bad "exit $rc (expected 3)"
grep -q "nothing blocked" "$WORK/err.txt" || grep -q "nothing blocked" "$WORK/out.txt" && ok "explains the timeout" || bad "no timeout explanation"

printf '== nothing ever blocks: times out after max*interval, explains on stdout ==\n'
none_blocked
wfb 0 2; rc=$?
[ "$rc" -eq 3 ] && ok "exit 3 on timeout" || bad "exit $rc (expected 3)"
grep -q "nothing blocked after" "$WORK/out.txt" && ok "explains the timeout with the elapsed budget" || bad "no explanation: $(cat "$WORK/out.txt")"

printf '== herdr not on PATH (and no stub function in scope): exit 2, explains ==\n'
out=$(env -i PATH=/nonexistent "$(command -v bash)" "$here/wait-for-blocked.sh" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "exit 2" || bad "exit $rc (expected 2)"
printf '%s' "$out" | grep -q "herdr not on PATH" && ok "explains the missing dependency" || bad "no explanation: $out"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
