#!/usr/bin/env bash
# verify-stage2.sh — proves stage2-diagnose.sh tells the truth about the
# diagnose lane, against the 2026-08/09 incident chain: three consecutive
# monthly passes emitted `succeeded` at dispatch (or at a weekly skip) and were
# then lost with zero commits — the ledger said the month was fine while the
# worker idled, died, or was never briefed.
#
# What this pins:
#   * the SCHEDULED path refuses to spawn an unattended unisolated executory
#     worker (2026-09-04 policy) and emits a failed isolation-required row —
#     an actionable page, not a fake success and not a silent no-op;
#   * --record-completion only emits `succeeded` after verifying a tracking
#     doc actually COMMITTED on the pass branch (not inherited from
#     origin/main), and records the truth in the run registry — including the
#     "worker finished but its pane was closed and the sweep buried it as
#     lost" case, where the terminal state stays settled and the evidence
#     lands as an audited event instead.
#
# The KB ledger writer is stubbed via $HOME (emit_loop_run resolves
# $HOME/Code/knowledge-base), so nothing touches the real ledger. Registry
# runs against a throwaway HERDR_RUN_STATE_DIR.
#
#   bash verify-stage2.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# ---- stub the loop ledger ----------------------------------------------------
# emit_loop_run shells out to $HOME/Code/knowledge-base/.venv/bin/python3; a
# fake python that logs its argv IS the emit capture.
export EMITLOG="$WORK/emit.log"; : > "$EMITLOG"
mkdir -p "$WORK/Code/knowledge-base/.venv/bin"
cat > "$WORK/Code/knowledge-base/.venv/bin/python3" <<'EOS'
#!/usr/bin/env bash
echo "$@" >> "$EMITLOG"
exit 0
EOS
chmod +x "$WORK/Code/knowledge-base/.venv/bin/python3"

export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_WT_DIR="$WORK/wt"
export STAGE2_THURBER_OS_REPO="$WORK/thurber-os"

run_stage2() {  # <args...> -> stage2 with stubbed HOME; echoes rc
  HOME="$WORK" bash "$here/stage2-diagnose.sh" "$@" \
    >"$WORK/s2.out" 2>"$WORK/s2.err"
  printf '%s' "$?"
}

printf '== scheduled first-Friday: refuses dispatch, pages isolation-required ==\n'
# STAGE2_ASSUME_FIRST_FRIDAY is the deliberate test seam: it can only force
# the branch that REFUSES, never one that spawns.
rc=$(STAGE2_ASSUME_FIRST_FRIDAY=1 run_stage2 --scheduled)
[ "$rc" = "1" ] && ok "scheduled dispatch exits 1 (fails closed)" || bad "exit $rc: $(cat "$WORK/s2.err")"
grep -q -- '--state failed' "$EMITLOG" \
  && ok "diagnose lane fed a FAILED row, not a fake success" || bad "emit log: $(cat "$EMITLOG")"
grep -q 'isolation-required' "$EMITLOG" \
  && ok "the failure names the actionable condition (isolation-required)" || bad "emit log: $(cat "$EMITLOG")"
grep -q 'REFUSING scheduled dispatch' "$WORK/s2.err" \
  && ok "refusal explained on stderr" || bad "silent refusal: $(cat "$WORK/s2.err")"
grep -qi 'spawn' "$WORK/s2.out" \
  && bad "scheduled path still reached a spawn" || ok "no worker spawned"

printf '== record-completion: no committed doc -> refused, no succeeded row ==\n'
# A real repo with a real origin/main, so the inherited-doc guard is exercised
# against actual git plumbing rather than stubs.
git init -q -b main "$WORK/thurber-os"
git -C "$WORK/thurber-os" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
BR="evolution-loop/stage2-diagnose-20260904"
git clone -q "$WORK/thurber-os" "$HERDR_WT_DIR/thurber-os/$BR"
git -C "$HERDR_WT_DIR/thurber-os/$BR" checkout -q -b "$BR"
: > "$EMITLOG"
rc=$(run_stage2 --record-completion "$BR")
[ "$rc" = "2" ] && ok "no evidence -> exit 2" || bad "exit $rc: $(cat "$WORK/s2.err")"
grep -q -- '--state succeeded' "$EMITLOG" \
  && bad "succeeded emitted without evidence" || ok "no succeeded row without a committed doc"

printf '== record-completion: doc inherited from origin/main is NOT evidence ==\n'
git -C "$WORK/thurber-os" checkout -q main 2>/dev/null || true
mkdir -p "$WORK/thurber-os/docs/tracking"
echo "old pass" > "$WORK/thurber-os/docs/tracking/2026-08-07-stage2-diagnose-pass.md"
git -C "$WORK/thurber-os" -c user.email=t@t -c user.name=t add docs/tracking
git -C "$WORK/thurber-os" -c user.email=t@t -c user.name=t commit -q -m "prior month's pass"
git -C "$HERDR_WT_DIR/thurber-os/$BR" fetch -q origin
git -C "$HERDR_WT_DIR/thurber-os/$BR" merge -q origin/main
: > "$EMITLOG"
rc=$(run_stage2 --record-completion "$BR")
[ "$rc" = "2" ] && ok "inherited doc refused (exit 2)" || bad "exit $rc: $(cat "$WORK/s2.err")"
grep -q 'inherited from origin/main' "$WORK/s2.err" \
  && ok "refusal explains the doc is not this pass's work" || bad "stderr: $(cat "$WORK/s2.err")"
grep -q -- '--state succeeded' "$EMITLOG" \
  && bad "succeeded emitted for inherited evidence" || ok "no succeeded row for inherited evidence"

printf '== record-completion: committed doc on the branch -> registry + ledger truth ==\n'
. "$here/lib/run-registry.sh"
register_task runS taskS w condS cp cb paneS birthS "$WORK/thurber-os" "$HERDR_WT_DIR/thurber-os/$BR" "review:stage2" >/dev/null 2>&1 \
  || bad "register taskS failed"
set_task_state runS taskS running >/dev/null 2>&1
echo "this month's findings" > "$HERDR_WT_DIR/thurber-os/$BR/docs/tracking/2026-09-04-stage2-diagnose-pass.md"
git -C "$HERDR_WT_DIR/thurber-os/$BR" -c user.email=t@t -c user.name=t add docs/tracking
git -C "$HERDR_WT_DIR/thurber-os/$BR" -c user.email=t@t -c user.name=t commit -q -m "stage2 pass doc"
: > "$EMITLOG"
rc=$(run_stage2 --record-completion "$BR" 3)
[ "$rc" = "0" ] && ok "verified completion exits 0" || bad "exit $rc: $(cat "$WORK/s2.err")"
grep -q -- '--state succeeded' "$EMITLOG" \
  && ok "succeeded row emitted only now, with evidence" || bad "emit log: $(cat "$EMITLOG")"
grep -q 'verified: docs/tracking/2026-09-04-stage2-diagnose-pass.md' "$EMITLOG" \
  && ok "ledger note names the verified artifact" || bad "emit log: $(cat "$EMITLOG")"
grep -q -- '--findings 3' "$EMITLOG" \
  && ok "findings count carried through" || bad "emit log: $(cat "$EMITLOG")"
check_state=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "SELECT state FROM tasks WHERE task_id='taskS';")
[ "$check_state" = "completed" ] && ok "registry task marked completed" || bad "registry state=$check_state"
n_rec=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "SELECT count(*) FROM events WHERE task_id='taskS' AND type='completion_recorded';")
[ "$n_rec" = "1" ] && ok "completion_recorded event carries the evidence" || bad "completion_recorded rows: $n_rec"

printf '== record-completion: a buried (lost) task stays settled, evidence still lands ==\n'
# The exact incident: worker finishes, its pane is closed, the sweep marks it
# lost (terminal, correctly non-resurrectable). Recording completion must not
# resurrect the state machine — and must not lose the evidence either.
BR2="evolution-loop/stage2-diagnose-20260905"
git clone -q "$WORK/thurber-os" "$HERDR_WT_DIR/thurber-os/$BR2"
git -C "$HERDR_WT_DIR/thurber-os/$BR2" checkout -q -b "$BR2"
echo "findings" > "$HERDR_WT_DIR/thurber-os/$BR2/docs/tracking/2026-09-05-stage2-diagnose-pass.md"
git -C "$HERDR_WT_DIR/thurber-os/$BR2" -c user.email=t@t -c user.name=t add docs/tracking
git -C "$HERDR_WT_DIR/thurber-os/$BR2" -c user.email=t@t -c user.name=t commit -q -m "pass doc"
register_task runL taskL w condL cp cb paneL birthL "$WORK/thurber-os" "$HERDR_WT_DIR/thurber-os/$BR2" "review:stage2-lost" >/dev/null 2>&1 \
  || bad "register taskL failed"
set_task_state runL taskL running >/dev/null 2>&1
set_task_state runL taskL lost >/dev/null 2>&1
: > "$EMITLOG"
rc=$(run_stage2 --record-completion "$BR2")
[ "$rc" = "0" ] && ok "evidence for a lost task still records (exit 0)" || bad "exit $rc: $(cat "$WORK/s2.err")"
lost_state=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "SELECT state FROM tasks WHERE task_id='taskL';")
[ "$lost_state" = "lost" ] && ok "lost stays terminal (no resurrection)" || bad "state=$lost_state"
n_ev=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "SELECT count(*) FROM events WHERE task_id='taskL' AND type='completion_evidence';")
[ "$n_ev" = "1" ] && ok "completion_evidence event audited against the buried task" || bad "completion_evidence rows: $n_ev"
grep -q -- '--state succeeded' "$EMITLOG" \
  && ok "ledger still gets the verified success" || bad "emit log: $(cat "$EMITLOG")"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
