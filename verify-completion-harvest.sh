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

# Minimal fake herdr: enough for stall-watchdog.sh's owner-resolution path
# (process-info "is this pane alive and running omp", capture "is it the
# same birth") to resolve a reachable, matching conductor pane.
herdr() {
  case "$1 $2" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    "pane capture")
      cat "$CM" ;;
    "pane birth")
      printf '%s\n' "$CONDB" ;;
    "pane send-text")
      printf 'send-text %s\n' "$3" >> "$SENT" ;;
    *) return 1 ;;
  esac
}
export -f herdr

SEND_STUB="$WORK/send-stub.sh"
cat > "$SEND_STUB" <<'EOF'
#!/usr/bin/env bash
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

echo "== 9: a non-completion signal (denied) never triggers a receipt or a successor lookup =="
register_task runK taskK workerK condK "$COND" "$CONDB" paneK paneKbirth repo/k "$WORK/wtK" labelK >/dev/null
assign_lane taskK laneQ >/dev/null
: > "$SENT"
bash "$here/stall-watchdog.sh" wake taskK denied approvalZ "a deny was never followed up"
n_receipt9=$(_q "SELECT count(*) FROM events WHERE task_id='taskK' AND type='completion_receipt';")
[ "$n_receipt9" = "0" ] && ok "9: 'denied' is not a completion signal -- no receipt, no successor lookup attempted" \
  || bad "9: expected 0 completion_receipt rows for a denied signal, got $n_receipt9"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
