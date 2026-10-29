#!/usr/bin/env bash
# verify-completion-harvest.sh — docs/design/completion-harvest-dispatch.md.
# Hermetic: no live herdr, no live panes, no network, no real registry.
#
# Covers the new lib/run-registry.sh primitives (completion receipt dedup,
# lane assignment, successor queue "latest wins", hold/release isolation)
# directly against a scratch registry, plus one end-to-end integration
# check through the real stall-watchdog.sh cmd_wake, reusing the same
# stub-herdr pattern verify-stall-watchdog.sh's Section A already
# establishes.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
export WORK
export HERDR_RUN_STATE_DIR="$WORK/runs"
export SENT="$WORK/sent.log"
: > "$SENT"

COND="w9:p1"; CONDB="w9term"
export COND CONDB
CM="$WORK/cond.txt"
export CM
printf ' $ \n ready\n' > "$CM"

# Minimal fake herdr, the exact command-name shape verify-stall-watchdog.sh's
# Section A already proves: process-info/list (reachable + birth match),
# read (pane text), send-text/send-keys (typed delivery, unused here since
# HERDR_STALL_WATCHDOG_SEND below bypasses it, kept for completeness).
herdr() {
  case "$1 $2" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"}]}}\n' "$COND" "$CONDB" ;;
    "pane read")
      cat "$CM" 2>/dev/null ;;
    "pane send-text")
      printf 'send-text %s\n' "$3" >> "$SENT"
      printf '%s' "$4" > "$WORK/wake_pending.txt" ;;
    "pane send-keys")
      printf 'send-keys %s %s\n' "$3" "$4" >> "$SENT"
      if [ "$4" = "Enter" ]; then
        { printf ' %s\n' "$(cat "$WORK/wake_pending.txt" 2>/dev/null)"
          printf '\n submitted\n $ \n ready\n'; } > "$CM"
      fi
      ;;
    *) return 0 ;;
  esac
}
export -f herdr

SEND_STUB="$WORK/send-stub.sh"
cat > "$SEND_STUB" <<'EOF'
#!/usr/bin/env bash
# Review REVIEW-HARVEST-6a20224: two armed, one-shot failure modes a test
# can drop a marker file for, consumed on use so the NEXT call (the real
# watchdog's own M3 retry) sees normal behavior again -- lets a test
# prove "a failed send still gets retried with the note intact" and "an
# unconfirmed (typed) send is never retried at all" against the REAL
# cmd_wake retry gate, not a mock of it.
if [ -e "$WORK/fail_once_marker" ]; then
  rm -f "$WORK/fail_once_marker"
  echo "simulated transient send failure" >&2
  exit 7
fi
if [ -e "$WORK/exit4_once_marker" ]; then
  rm -f "$WORK/exit4_once_marker"
  printf 'send-text %s\n' "$1" >> "$SENT"
  printf '%s\n' "$3" >> "$WORK/last-msg.txt"
  echo "unsubmitted"
  exit 4
fi
printf 'send-text %s\n' "$1" >> "$SENT"
printf '%s\n' "$3" >> "$WORK/last-msg.txt"
echo "delivered"
exit 0
EOF
chmod +x "$SEND_STUB"
export HERDR_STALL_WATCHDOG_SEND="$SEND_STUB"

. "$here/lib/run-registry.sh"
registry_init
_q() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$1" 2>/dev/null; }

echo "== 1: completion receipt dedup -- identical (task, content) is a no-op, different content re-arms =="
r1a=1; record_completion_receipt taskR tmp/commit-msg.txt aaa111 && r1a=0
r1b=1; record_completion_receipt taskR tmp/commit-msg.txt aaa111 && r1b=0
r1c=1; record_completion_receipt taskR tmp/commit-msg.txt bbb222 && r1c=0
[ "$r1a" = 0 ] && ok "1: first receipt for (taskR, aaa111) is newly claimed" \
  || bad "1: first receipt (rc=$r1a)"
[ "$r1b" = 1 ] && ok "1: an identical second call for the SAME content is a no-op (dedup)" \
  || bad "1: duplicate receipt was NOT deduped (rc=$r1b)"
[ "$r1c" = 0 ] && ok "1: DIFFERENT content for the same task re-arms (new sha, new event)" \
  || bad "1: changed-content receipt (rc=$r1c)"
n_receipts=$(_q "SELECT count(*) FROM events WHERE task_id='taskR' AND type='completion_receipt';")
[ "$n_receipts" = "2" ] && ok "1: exactly 2 durable receipt rows for taskR (one per distinct content)" \
  || bad "1: expected 2 receipt rows, got $n_receipts"

echo "== 2: lane assignment is immutable (claim_once) =="
r2a=1; assign_lane taskR laneX && r2a=0
r2b=1; assign_lane taskR laneY && r2b=0
got_lane="$(read_lane_for_task taskR)"
[ "$r2a" = 0 ] && [ "$r2b" = 1 ] && [ "$got_lane" = laneX ] \
  && ok "2: first assignment wins, a later attempt to reassign is refused, read returns laneX" \
  || bad "2: assign/read (r2a=$r2a r2b=$r2b lane=[$got_lane])"

echo "== 3: successor queue -- latest queued plan for a lane always wins on read =="
queue_successor laneX "spawn implement round 1" conductor >/dev/null
queue_successor laneX "spawn implement round 2 (replanned)" conductor >/dev/null
succ3="$(read_successor_for_lane laneX)"
[ "$succ3" = "spawn implement round 2 (replanned)" ] \
  && ok "3: the MOST RECENTLY queued successor is what reads back, not the first" \
  || bad "3: read_successor_for_lane (got [$succ3])"
succ3_other="$(read_successor_for_lane laneZ)"
[ -z "$succ3_other" ] && ok "3: a lane nothing was ever queued for reads back empty" \
  || bad "3: unqueued lane returned [$succ3_other]"

echo "== 4: held lane isolation -- holding laneX never touches laneY's independent queue =="
queue_successor laneY "spawn implement for lane Y" conductor >/dev/null
hold_lane laneX "waiting on a human decision" conductor >/dev/null
admitX=1; lane_successor_admits laneX >/dev/null 2>&1 && admitX=0
admitY="$(lane_successor_admits laneY 2>/dev/null)"
[ "$admitX" = 1 ] && ok "4: a HELD lane's successor is never surfaced" \
  || bad "4: held laneX still admitted a successor (rc=$admitX)"
[ "$admitY" = "spawn implement for lane Y" ] \
  && ok "4: an independent, non-held lane is completely unaffected by laneX's hold" \
  || bad "4: laneY admit (got [$admitY])"
release_lane laneX conductor >/dev/null
admitX_after="$(lane_successor_admits laneX 2>/dev/null)"
[ "$admitX_after" = "spawn implement round 2 (replanned)" ] \
  && ok "4: releasing laneX restores its successor visibility, laneY still unaffected throughout" \
  || bad "4: laneX after release (got [$admitX_after])"
admitY_still="$(lane_successor_admits laneY 2>/dev/null)"
[ "$admitY_still" = "spawn implement for lane Y" ] \
  && ok "4: laneY's own successor is still exactly what it was, never perturbed by laneX's hold/release cycle" \
  || bad "4: laneY after laneX release (got [$admitY_still])"

echo "== 5: restart mid-transition -- a fresh shell against the SAME registry reads identical state =="
(
  . "$here/lib/run-registry.sh"
  lane5="$(read_lane_for_task taskR)"
  succ5="$(lane_successor_admits "$lane5" 2>/dev/null)"
  [ "$lane5" = laneX ] && [ "$succ5" = "spawn implement round 2 (replanned)" ] && exit 0
  exit 1
)
if [ "$?" = 0 ]; then
  ok "5: a fresh process (simulated restart) reads back the exact same lane + successor state"
else
  bad "5: fresh-process readback diverged from the continuous-process view"
fi

echo "== 6: missed event -- cmd_wake still records a receipt and wakes even on a plain (no lane) task =="
register_task runH taskH workerH condH "$COND" "$CONDB" paneH paneHbirth repo/h "$WORK/wtH" labelH >/dev/null
mkdir -p "$WORK/wtH/tmp"
printf 'commit message body\n' > "$WORK/wtH/tmp/commit-msg.txt"
: > "$SENT"; : > "$WORK/last-msg.txt" 2>/dev/null || true
bash "$here/stall-watchdog.sh" wake taskH artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
n_sent6=$(grep -c "send-text $COND" "$SENT" || true)
n_receipt6=$(_q "SELECT count(*) FROM events WHERE task_id='taskH' AND type='completion_receipt';")
[ "$n_sent6" = "1" ] && ok "6: the wake itself is unaffected -- sends exactly once, same as before this feature" \
  || bad "6: expected 1 send, got $n_sent6"
[ "$n_receipt6" = "1" ] && ok "6: a durable completion receipt was recorded for the artifact's real content" \
  || bad "6: expected 1 completion_receipt row, got $n_receipt6"
grep -q "Pre-planned next" "$WORK/last-msg.txt" 2>/dev/null \
  && bad "6: a task with no assigned lane must NOT claim a pre-planned successor" \
  || ok "6: no lane assigned -- message degrades to exactly today's bare wake text"

echo "== 7: a lane WITH a queued successor folds it into the real wake message =="
register_task runI taskI workerI condI "$COND" "$CONDB" paneI paneIbirth repo/i "$WORK/wtI" labelI >/dev/null
mkdir -p "$WORK/wtI/tmp"
printf 'another commit message\n' > "$WORK/wtI/tmp/commit-msg.txt"
assign_lane taskI laneQ >/dev/null
queue_successor laneQ "spawn plan on herdr-control feat/next-thing" conductor >/dev/null
: > "$SENT"; : > "$WORK/last-msg.txt"
bash "$here/stall-watchdog.sh" wake taskI artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
grep -q "Pre-planned next (lane laneQ): spawn plan on herdr-control feat/next-thing" "$WORK/last-msg.txt" \
  && ok "7: the real wake message carries the receipt-triggered, pre-planned successor" \
  || bad "7: last message missing the pre-planned successor: $(cat "$WORK/last-msg.txt" 2>/dev/null)"
grep -q "/stall-ack.sh taskI artifact" "$WORK/last-msg.txt" \
  && ok "7: the existing ack instruction is still present -- additive, not a replacement" \
  || bad "7: ack instruction missing from the augmented message"
n_dispatch7=$(successor_dispatch_count laneQ)
[ "$n_dispatch7" = "1" ] && ok "7: idle+artifact with a queued successor records exactly ONE dispatch claim" \
  || bad "7: expected 1 successor_dispatched row for laneQ, got $n_dispatch7"

echo "== 8: a HELD lane's completion still receipts but never surfaces its successor in the real wake =="
register_task runJ taskJ workerJ condJ "$COND" "$CONDB" paneJ paneJbirth repo/j "$WORK/wtJ" labelJ >/dev/null
mkdir -p "$WORK/wtJ/tmp"
printf 'held lane commit\n' > "$WORK/wtJ/tmp/commit-msg.txt"
assign_lane taskJ laneHeld >/dev/null
queue_successor laneHeld "spawn deep-review on herdr-control feat/held-thing" conductor >/dev/null
hold_lane laneHeld "awaiting Terrence" conductor >/dev/null
: > "$SENT"; : > "$WORK/last-msg.txt"
bash "$here/stall-watchdog.sh" wake taskJ artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
n_sent8=$(grep -c "send-text $COND" "$SENT" || true)
n_receipt8=$(_q "SELECT count(*) FROM events WHERE task_id='taskJ' AND type='completion_receipt';")
[ "$n_sent8" = "1" ] && ok "8: the wake still fires normally for a held lane's task" \
  || bad "8: expected 1 send, got $n_sent8"
[ "$n_receipt8" = "1" ] && ok "8: the completion is still durably receipted even though the lane is held" \
  || bad "8: expected 1 completion_receipt row, got $n_receipt8"
grep -q "Pre-planned next" "$WORK/last-msg.txt" 2>/dev/null \
  && bad "8: a HELD lane's successor leaked into the wake message" \
  || ok "8: the held lane's queued successor was correctly withheld from the message"
n_dispatch8=$(successor_dispatch_count laneHeld)
[ "$n_dispatch8" = "0" ] && ok "8: a HELD lane -- NO dispatch claim is ever recorded, not just withheld from the message" \
  || bad "8: expected 0 successor_dispatched rows for a held lane, got $n_dispatch8"

echo "== 9: a non-completion signal (denied) never triggers a receipt or a successor lookup =="
register_task runK taskK workerK condK "$COND" "$CONDB" paneK paneKbirth repo/k "$WORK/wtK" labelK >/dev/null
assign_lane taskK laneQ >/dev/null
: > "$SENT"
bash "$here/stall-watchdog.sh" wake taskK denied approvalZ "a deny was never followed up"
n_receipt9=$(_q "SELECT count(*) FROM events WHERE task_id='taskK' AND type='completion_receipt';")
[ "$n_receipt9" = "0" ] && ok "9: 'denied' is not a completion signal -- no receipt, no successor lookup attempted" \
  || bad "9: expected 0 completion_receipt rows for a denied signal, got $n_receipt9"

echo "== 10: duplicate harvest (two tasks racing the SAME lane's one queued successor) -- a single dispatch =="
register_task runL1 taskL1 workerL1 condL1 "$COND" "$CONDB" paneL1 paneL1birth repo/l1 "$WORK/wtL1" labelL1 >/dev/null
register_task runL2 taskL2 workerL2 condL2 "$COND" "$CONDB" paneL2 paneL2birth repo/l2 "$WORK/wtL2" labelL2 >/dev/null
mkdir -p "$WORK/wtL1/tmp" "$WORK/wtL2/tmp"
printf 'first completion for shared lane\n' > "$WORK/wtL1/tmp/commit-msg.txt"
printf 'second completion for shared lane\n' > "$WORK/wtL2/tmp/commit-msg.txt"
assign_lane taskL1 laneDup >/dev/null
assign_lane taskL2 laneDup >/dev/null
queue_successor laneDup "spawn implement on herdr-control feat/shared-next" conductor >/dev/null
: > "$SENT"; : > "$WORK/last-msg.txt"
bash "$here/stall-watchdog.sh" wake taskL1 artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
cp "$WORK/last-msg.txt" "$WORK/last-msg-L1.txt"
: > "$WORK/last-msg.txt"
bash "$here/stall-watchdog.sh" wake taskL2 artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
cp "$WORK/last-msg.txt" "$WORK/last-msg-L2.txt"
n_dispatch10=$(successor_dispatch_count laneDup)
[ "$n_dispatch10" = "1" ] && ok "10: two independent completions racing the SAME lane's successor still record exactly ONE dispatch claim total" \
  || bad "10: expected 1 successor_dispatched row for laneDup, got $n_dispatch10"
notes10=0
grep -q "Pre-planned next" "$WORK/last-msg-L1.txt" 2>/dev/null && notes10=$((notes10+1))
grep -q "Pre-planned next" "$WORK/last-msg-L2.txt" 2>/dev/null && notes10=$((notes10+1))
[ "$notes10" = "1" ] && ok "10: exactly ONE of the two wakes carried the pre-planned successor note, never both, never zero" \
  || bad "10: expected exactly 1 of 2 messages to carry the note, got $notes10 (L1=$(cat "$WORK/last-msg-L1.txt" 2>/dev/null) | L2=$(cat "$WORK/last-msg-L2.txt" 2>/dev/null))"
n_sent10=$(grep -c "send-text $COND" "$SENT" || true)
[ "$n_sent10" = "2" ] && ok "10: both underlying wakes still sent normally -- the dispatch race affects only the successor note, never the wake itself" \
  || bad "10: expected 2 sends (one per task), got $n_sent10"
n_receipt10=$(( $(_q "SELECT count(*) FROM events WHERE task_id='taskL1' AND type='completion_receipt';") \
               + $(_q "SELECT count(*) FROM events WHERE task_id='taskL2' AND type='completion_receipt';") ))
[ "$n_receipt10" = "2" ] && ok "10: both completions are still independently, durably receipted regardless of who won the dispatch race" \
  || bad "10: expected 2 total completion_receipt rows across taskL1+taskL2, got $n_receipt10"

echo "== 11 (REVIEW-HARVEST-6a20224 HIGH): a send that fails outright leaves the successor re-dispatchable on retry =="
register_task runM taskM workerM condM "$COND" "$CONDB" paneM paneMbirth repo/m "$WORK/wtM" labelM >/dev/null
mkdir -p "$WORK/wtM/tmp"
printf 'a completion whose first delivery attempt fails\n' > "$WORK/wtM/tmp/commit-msg.txt"
assign_lane taskM laneFail >/dev/null
queue_successor laneFail "spawn implement on herdr-control feat/after-retry" conductor >/dev/null
: > "$SENT"; : > "$WORK/last-msg.txt"
: > "$WORK/fail_once_marker"
bash "$here/stall-watchdog.sh" wake taskM artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
n_sent11a=$(grep -c "send-text $COND" "$SENT" || true)
[ "$n_sent11a" = "0" ] && ok "11: the first attempt's send genuinely failed -- nothing recorded as sent" \
  || bad "11: expected 0 sends after the armed failure, got $n_sent11a"
n_dispatch11a=$(successor_dispatch_count laneFail)
[ "$n_dispatch11a" = "1" ] && ok "11: the dispatch claim is won on the FIRST attempt regardless of whether delivery succeeded" \
  || bad "11: expected the claim already taken after attempt 1, got $n_dispatch11a"
bash "$here/stall-watchdog.sh" wake taskM artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
n_dispatch11b=$(successor_dispatch_count laneFail)
[ "$n_dispatch11b" = "1" ] && ok "11: the retry does NOT take a second claim -- still exactly one dispatch for laneFail" \
  || bad "11: expected the claim count to stay at 1 across the retry, got $n_dispatch11b"
grep -q "Pre-planned next (lane laneFail): spawn implement on herdr-control feat/after-retry" "$WORK/last-msg.txt" \
  && ok "11: the retry's actually-delivered message still carries the successor note -- not silently dropped by the earlier failure" \
  || bad "11: the successor note was lost on retry: $(cat "$WORK/last-msg.txt" 2>/dev/null)"
n_sent11b=$(grep -c "send-text $COND" "$SENT" || true)
[ "$n_sent11b" = "1" ] && ok "11: exactly one real delivery total -- the failed first attempt never counted as a send" \
  || bad "11: expected exactly 1 send across both attempts, got $n_sent11b"

echo "== 12 (REVIEW-HARVEST-6a20224): an uncertain (exit 4, typed-but-unsubmitted) send must never double-dispatch =="
register_task runN taskN workerN condN "$COND" "$CONDB" paneN paneNbirth repo/n "$WORK/wtN" labelN >/dev/null
mkdir -p "$WORK/wtN/tmp"
printf 'a completion whose first delivery attempt is unconfirmed\n' > "$WORK/wtN/tmp/commit-msg.txt"
assign_lane taskN laneUncertain >/dev/null
queue_successor laneUncertain "spawn review on herdr-control feat/uncertain" conductor >/dev/null
: > "$SENT"; : > "$WORK/last-msg.txt"
: > "$WORK/exit4_once_marker"
bash "$here/stall-watchdog.sh" wake taskN artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
grep -q "Pre-planned next (lane laneUncertain)" "$WORK/last-msg.txt" \
  && ok "12: the one (uncertain) attempt did legitimately carry the note" \
  || bad "12: expected the first, typed-but-unsubmitted attempt to carry the note: $(cat "$WORK/last-msg.txt" 2>/dev/null)"
bash "$here/stall-watchdog.sh" wake taskN artifact "tmp/commit-msg.txt:1" "ready" "tmp/commit-msg.txt"
n_sent12=$(grep -c "send-text $COND" "$SENT" || true)
[ "$n_sent12" = "1" ] && ok "12: N4's own gate (already typed, never confirmed) blocks the retry entirely -- no second send attempted" \
  || bad "12: expected exactly 1 send (no retry once typed), got $n_sent12"
n_dispatch12=$(successor_dispatch_count laneUncertain)
[ "$n_dispatch12" = "1" ] && ok "12: exactly one dispatch claim -- an uncertain send never burns a second claim nor needs to" \
  || bad "12: expected exactly 1 successor_dispatched row for laneUncertain, got $n_dispatch12"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
