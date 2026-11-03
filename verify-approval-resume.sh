#!/usr/bin/env bash
# verify-approval-resume.sh — offline fixtures for the approval/resume path
# (conductor task, 2026-10-30, worktree feat/alert-fix-it-button): exact
# request + identity binding, DEFERRED no-panel prompts answered only by
# approval_request_id + core_arguments_digest + payload sha256, and a saved
# hub answer applied exactly once across repeated "restarts".
#
# Every property below already has deep piecemeal coverage elsewhere
# (verify-approval-payload.sh, verify-omp-hooks.sh, verify-prompt-occurrence.py,
# verify-pretool-enforce.sh, verify-task-authorization-gates.sh) — this suite
# does not re-litigate those. Its own, narrower claim: a single DEFERRED
# occurrence resolved by exact identity (section A), chained with a human
# action request whose SAVED hub answer survives FOUR separate cold
# `herdr-action.sh tick` invocations (section B) — each tick is a genuinely
# new process reading only the persisted sqlite registry and the on-disk
# form file, the same shape a real hub restart has — and is applied exactly
# once, never re-decided or re-notified on any later restart.
#
# Temp registries only: HERDR_RUN_STATE_DIR/HERDR_STATE_ROOT point at a
# mktemp scratch dir for the whole run; no real ~/.local/state/herdr path is
# ever read or written. herdr, send, notify and formserve are all local
# fixtures (same scaffolding as verify-pretool-enforce.sh); no live herdr,
# Slack or hub process is invoked. No production code is modified.
#
#   bash verify-approval-resume.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export HERDR_RUN_STATE_DIR="$work/runs" HERDR_STATE_ROOT="$work/state"
export XDG_RUNTIME_DIR="$work/runtime"
mkdir -p "$XDG_RUNTIME_DIR" "$HERDR_STATE_ROOT/forms" "$work/bin"
export PANE='w1:p1' BIRTH='gen-1' CPANE='w9:p9' CBIRTH='cgen-1'
export HERDR_PANE_ID="$PANE" HERDR_RUN_ID='run1' HERDR_TASK_ID='task1'
wt="$work/worktree"; mkdir -p "$wt/.handoffs"

HERDR_CALLS_LOG="$work/herdr-calls.log"; : > "$HERDR_CALLS_LOG"
cat > "$work/bin/herdr" <<EOF
#!/bin/bash
if [ "\$1 \$2" = "pane list" ]; then
  printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \\
    "$PANE" "\${FAKE_BIRTH:-$BIRTH}" "$CPANE" "\${FAKE_CBIRTH:-$CBIRTH}"
else
  printf '%s\n' "\$*" >> "$HERDR_CALLS_LOG"
fi
EOF
cat > "$work/bin/send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$work/sent"
exit \${FAKE_SEND_RC:-0}
EOF
cat > "$work/bin/notify" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$work/notified"
EOF
cat > "$work/bin/formserve" <<EOF
#!/bin/bash
id="\$(date -u +%Y%m%dT%H%M%S)-\$RANDOM\$RANDOM"
jq -nc --arg f "\$1" '{form_path:\$f, status:"open"}' > "$HERDR_STATE_ROOT/forms/\$id.json"
EOF
chmod +x "$work/bin/"*

# Exported functions take precedence over any real herdr/ps binary. Every
# call other than "pane list"/"pane process-info" is logged, never acted on
# live — section A asserts this log stays empty across a DEFERRED resolution.
herdr() {
  if [ "$1 $2" = 'pane process-info' ]; then
    local pid=999999
    [ "${4:-}" != "${HERDR_FIXTURE_CALLER_PANE:-}" ] || pid="$PPID"
    printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"omp","cmdline":"omp"}]}}}\n' "$pid"
  else "$HERDR_FIXTURE_HERDR" "$@"; fi
}
ps() { printf '1\n'; }
export HERDR_FIXTURE_HERDR="$work/bin/herdr"
export -f herdr ps
export HERDR_ACTION_SEND="$work/bin/send" HERDR_ACTION_NOTIFY="$work/bin/notify"
export HERDR_ACTION_FORMSERVE="$work/bin/formserve" HERDR_ACTION_PYTHON=bash
export HERDR_ACTION_NO_SURFACE=1

. "$here/lib/pretool-shadow.sh"
. "$here/tests/fixtures/task-authorization.sh"
fixture_register_task run1 task1 worker1 cond1 "$CPANE" "$CBIRTH" "$PANE" "$BIRTH" /repo "$wt" "impl:task1" feat/x main "" "" hook >/dev/null \
  || { echo "fixture registration failed"; exit 1; }
set_task_state run1 task1 running >/dev/null
DB="$(registry_db)"
OCC=(python3 "$here/lib/prompt-occurrence.py")

good=0 bad=0
ok() { good=$((good + 1)); printf '  ok    %s\n' "$1"; }
not_ok() { bad=$((bad + 1)); printf '  FAIL  %s\n' "$1"; }
q() { sqlite3 "$DB" "$1"; }
act() { HERDR_FIXTURE_CALLER_PANE="${HERDR_PANE_ID:-}" bash "$here/herdr-action.sh" "$@"; }
authorized_count() { q "SELECT count(*) FROM events WHERE type='prompt_occ_authorized' AND json_extract(payload,'\$.occ_key')='$1';"; }

# The exact canonical body lib/prompt-occurrence.py's own payload_sha256()
# hashes, computed independently here (the sha a reviewer would compute off
# the complete recorded payload, same approach as verify-approval-payload.sh).
input_sha() {                            # <tool> <input-json> -> <hex, no prefix -- matches payload_sha256()>
  python3 - "$1" "$2" <<'PY'
import hashlib, json, sys
body = json.dumps({"tool": sys.argv[1], "input": json.loads(sys.argv[2]), "known": True},
                  sort_keys=True, separators=(",", ":"), default=str)
print(hashlib.sha256(body.encode()).hexdigest())
PY
}

printf '== A: exact identity (approval_request_id + core_arguments_digest + payload sha) resolves a DEFERRED occurrence with zero panel calls ==\n'
REQ_A="req-resume-a"; DIGEST_A="sha256:$(printf 'core-args-a' | shasum -a 256 | awk '{print $1}')"
INPUT_A='{"path":".handoffs/resume-a.md","content":"deferred payload a"}'
SHA_A="$(input_sha write "$INPUT_A")"
seen_a="$(printf '%s' "$INPUT_A" | "${OCC[@]}" seen --db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" \
  --session sess-a --call-id call-a --tool write --input-json - \
  --approval-request-id "$REQ_A" --core-arguments-digest "$DIGEST_A" --binding-protocol omp.tool-approval-binding.v1)"
OCC_A="$(printf '%s' "$seen_a" | jq -r .occ_key)"
[ -n "$OCC_A" ] && [ "$(printf '%s' "$seen_a" | jq -r .written)" = seen ] \
  && ok "setup: a DEFERRED occurrence is recorded (no screen, no pane ever read)" \
  || not_ok "setup seen: $seen_a"

auth_a="$("${OCC[@]}" authorize-bound --db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" \
  --session sess-a --call-id call-a --approval-request-id "$REQ_A" --core-arguments-digest "$DIGEST_A" \
  --worktree "$wt" --conductor-pane "$CPANE" --conductor-birth "$CBIRTH" \
  --approval-id appr-resume-a --choice Approve --authority conductor --decided-by test-resume \
  --review-reason "reviewed the complete recorded payload" --review-category branch-work --reviewer "$CPANE" \
  --audit-text "resume fixture a" --expect-payload-sha "$SHA_A")"
[ "$(printf '%s' "$auth_a" | jq -r .written)" = authorized ] && [ "$(authorized_count "$OCC_A")" = 1 ] \
  && ok "exact request_id + digest + payload sha resolve the DEFERRED occurrence (authorized, no panel)" \
  || not_ok "authorize-bound exact identity: $auth_a"
[ ! -s "$HERDR_CALLS_LOG" ] && [ ! -s "$work/sent" ] \
  && ok "no pane was ever read or typed into -- DEFERRED means there is no panel to paint" \
  || not_ok "unexpected herdr/send activity: $(cat "$HERDR_CALLS_LOG" "$work/sent" 2>/dev/null)"

auth_a2="$("${OCC[@]}" authorize-bound --db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" \
  --session sess-a --call-id call-a --approval-request-id "$REQ_A" --core-arguments-digest "$DIGEST_A" \
  --worktree "$wt" --conductor-pane "$CPANE" --conductor-birth "$CBIRTH" \
  --approval-id appr-resume-a-2 --choice Approve --authority conductor --decided-by test-resume \
  --review-reason "reviewed again" --review-category branch-work --reviewer "$CPANE" \
  --audit-text "resume fixture a replay" --expect-payload-sha "$SHA_A")"
[ "$(printf '%s' "$auth_a2" | jq -r .written)" = closed_or_mismatched ] && [ "$(authorized_count "$OCC_A")" = 1 ] \
  && ok "a replayed identical approval is a no-op -- delivered exactly once" \
  || not_ok "replay: $auth_a2"

printf '== A2: a mismatched request_id, digest or payload sha each independently refuse the SAME occurrence ==\n'
REQ_B="req-resume-b"; DIGEST_B="sha256:$(printf 'core-args-b' | shasum -a 256 | awk '{print $1}')"
INPUT_B='{"path":".handoffs/resume-b.md","content":"deferred payload b"}'
SHA_B="$(input_sha write "$INPUT_B")"
WRONG="sha256:$(printf 'not-the-real-one' | shasum -a 256 | awk '{print $1}')"
seen_b="$(printf '%s' "$INPUT_B" | "${OCC[@]}" seen --db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" \
  --session sess-b --call-id call-b --tool write --input-json - \
  --approval-request-id "$REQ_B" --core-arguments-digest "$DIGEST_B" --binding-protocol omp.tool-approval-binding.v1)"
OCC_B="$(printf '%s' "$seen_b" | jq -r .occ_key)"

bound_b() {                              # req digest sha -> written
  "${OCC[@]}" authorize-bound --db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" \
    --session sess-b --call-id call-b --approval-request-id "$1" --core-arguments-digest "$2" \
    --worktree "$wt" --conductor-pane "$CPANE" --conductor-birth "$CBIRTH" \
    --approval-id "appr-resume-b-$RANDOM" --choice Approve --authority conductor --decided-by test-resume \
    --review-reason "reviewed" --review-category branch-work --reviewer "$CPANE" \
    --audit-text "resume fixture b" --expect-payload-sha "$3" | jq -r .written
}
[ "$(bound_b "req-resume-WRONG" "$DIGEST_B" "$SHA_B")" = request_changed ] \
  && ok "wrong approval_request_id: refused (request_changed)" || not_ok "wrong request_id was not refused"
[ "$(bound_b "$REQ_B" "$WRONG" "$SHA_B")" = request_changed ] \
  && ok "wrong core_arguments_digest: refused (request_changed)" || not_ok "wrong digest was not refused"
[ "$(bound_b "$REQ_B" "$DIGEST_B" "$WRONG")" = request_changed ] \
  && ok "wrong payload sha: refused (request_changed)" || not_ok "wrong payload sha was not refused"
[ "$(authorized_count "$OCC_B")" = 0 ] \
  && ok "none of the three mismatches landed a durable authorization" || not_ok "a mismatch leaked an authorized row"

auth_b_ok="$(bound_b "$REQ_B" "$DIGEST_B" "$SHA_B")"
[ "$auth_b_ok" = authorized ] && [ "$(authorized_count "$OCC_B")" = 1 ] \
  && ok "the exact triple still resolves after three mismatched attempts (negatives never corrupted the pending occurrence)" \
  || not_ok "positive control after mismatches: $auth_b_ok"

printf '== B: a saved hub answer is delivered exactly once across repeated cold tick \"restarts\" ==\n'
RID="$(action_request_create run1 task1 bash resume-action-sha 'echo resume-fixture' escalate "offline resume fixture" human once '' '')"
[ -n "$RID" ] && [ "$(q "SELECT status FROM action_requests WHERE request_id='$RID';")" = pending ] \
  && ok "setup: a pending human-route action request exists" || not_ok "setup request: $RID"

# tick #1: the hub's first pass over this request -- a cold process with
# nothing in memory, everything read from the persisted registry.
act tick >/dev/null
FID="$(q "SELECT form_record FROM action_requests WHERE request_id='$RID';")"
[ -n "$FID" ] && [ -f "$HERDR_STATE_ROOT/forms/$FID.json" ] && [ "$(jq -r .status "$HERDR_STATE_ROOT/forms/$FID.json")" = open ] \
  && ok "tick #1 serves and pins an open hub form" || not_ok "tick #1 did not pin a form (form_record=$FID)"

# A "saved hub answer" -- exactly the durable artifact a real human decision
# leaves on disk; nothing live is involved from here on, the form file IS
# the saved answer.
jq -c --arg id "$RID" '.status="answered" | .answers={request_id:$id, action_sha256:"resume-action-sha", decision:"approve", reason:"offline resume fixture"}' \
  "$HERDR_STATE_ROOT/forms/$FID.json" > "$HERDR_STATE_ROOT/forms/$FID.json.t" \
  && mv "$HERDR_STATE_ROOT/forms/$FID.json.t" "$HERDR_STATE_ROOT/forms/$FID.json"

# tick #2 ("restart" 1): a brand-new cold process must apply the saved answer.
act tick >/dev/null
[ "$(q "SELECT status||'/'||authority FROM action_requests WHERE request_id='$RID';")" = approved/human ] \
  && ok "restart 1: the saved hub answer is applied (approved, authority human)" \
  || not_ok "restart 1: $(q "SELECT status||'/'||authority FROM action_requests WHERE request_id='$RID';")"
[ "$(q "SELECT count(*) FROM events WHERE type='action_decided' AND json_extract(payload,'\$.request_id')='$RID';")" = 1 ] \
  && ok "exactly one action_decided event lands" || not_ok "action_decided event count is wrong"
[ "$(grep -c "\[HERDR-ACTION\] $RID APPROVED" "$work/sent" 2>/dev/null || echo 0)" = 1 ] \
  && ok "the worker is told exactly once" || not_ok "worker notification count is wrong: $(cat "$work/sent" 2>/dev/null)"

# tick #3, #4, #5 ("restart" 2, 3, 4): further cold processes over the SAME
# persisted state. This is the actual proof that a crash/restart loop never
# re-delivers a saved answer -- not merely that two invocations don't.
for _n in 2 3 4; do act tick >/dev/null; done
[ "$(q "SELECT status||'/'||authority FROM action_requests WHERE request_id='$RID';")" = approved/human ] \
  && ok "restarts 2-4: status is unchanged (never re-decided)" \
  || not_ok "restarts 2-4 changed status: $(q "SELECT status||'/'||authority FROM action_requests WHERE request_id='$RID';")"
[ "$(q "SELECT count(*) FROM events WHERE type='action_decided' AND json_extract(payload,'\$.request_id')='$RID';")" = 1 ] \
  && ok "restarts 2-4: still exactly one action_decided event" || not_ok "action_decided was duplicated across restarts"
[ "$(grep -c "\[HERDR-ACTION\] $RID APPROVED" "$work/sent" 2>/dev/null || echo 0)" = 1 ] \
  && ok "restarts 2-4: the worker is never re-notified" || not_ok "worker was re-notified: $(cat "$work/sent" 2>/dev/null)"
[ "$(jq -r .status "$HERDR_STATE_ROOT/forms/$FID.json")" = answered ] \
  && ok "the saved form record is left exactly as answered -- a real answer is never overwritten or re-served" \
  || not_ok "form record was mutated: $(jq -c . "$HERDR_STATE_ROOT/forms/$FID.json")"

printf '\n%d ok, %d FAIL\n' "$good" "$bad"
[ "$bad" -eq 0 ]
