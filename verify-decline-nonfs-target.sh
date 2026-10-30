#!/usr/bin/env bash
# verify-decline-nonfs-target.sh — fix/decline-nonfs-target
#
# DEFECT: a deferred `write` whose target is not a plain filesystem path
# (OMP's own bound resolver writing to a job's stdin, e.g. `proc://bg_10/kill`,
# to kill it) could be neither approved NOR declined: lib/prompt-occurrence.py
# proposal_check's per-target loop (_canonical_target) ran its scheme/symlink/
# worktree-boundary/directory/hardlink SHAPE checks on the decline path too,
# so herdr-select.sh's bound Deny failed exactly like its bound Approve,
# leaving the prompt stuck -- undeclinable, same as unapprovable.
#
# FIX: herdr-select.sh's _bound_proposal passes `--decline` to
# prompt-occurrence.py's `proposal` command only when label=Deny, which
# threads decline=True into _canonical_target to skip ONLY the target-SHAPE
# checks. Approve never sets it, so proc:// (or any other unsafe/non-fs
# target) stays rejected on Approve. Every other proposal_check gate --
# occurrence match, identity_verified, lifecycle/terminal-state, the exact
# approval_request_id+digest+tool_call_id binding, the payload hash, audit
# logging -- is unchanged and still runs on the decline path.
#
# Isolated: HOME, HERDR_STATE_ROOT, HERDR_RUN_STATE_DIR and TMPDIR are all
# fresh mktemp dirs; nothing here touches a live ~/.local/state/herdr.
#
#   LC_ALL=C bash verify-decline-nonfs-target.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"; export WORK   # the stub runs under herdr-select's set -u
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export HERDR_STATE_ROOT="$WORK/state"
export HERDR_RUN_STATE_DIR="$WORK/runs"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export HERDR_BRIDGE_STATE="$WORK/bridge"
export XDG_RUNTIME_DIR="$WORK/runtime"; mkdir -p "$XDG_RUNTIME_DIR"
export SCREEN="$WORK/screen.txt" KEYS="$WORK/keys.log"
: > "$KEYS"
PANE="w1:p1"; BIRTH="term-abc-123"; SESSION="sess-1"
export PANE BIRTH
WT="$WORK/wt"; mkdir -p "$WT/.handoffs"

# herdr stub: pane reads return $SCREEN; send-keys is logged. Same shape as
# verify-approval-payload.sh's stub -- the bound-request branch never reads
# the screen, but `pane list`/`pane process-info` still back require_agent_pane
# and caller_pane_from_ancestry.
_stub() {
  case "$1 $2" in
    "pane process-info")
      local pid=999999
      [ "${4:-}" != "${HERDR_FIXTURE_CALLER_PANE:-}" ] || pid="$PPID"
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"claude","cmdline":"claude"}]}}}\n' "$pid" ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"},{"pane_id":"w9:p9","terminal_id":"cond-birth","cwd":"/tmp"}]}}\n' "$PANE" "$BIRTH" ;;
    "pane read") cat "$SCREEN" ;;
    "pane send-keys") printf '%s\n' "$4" >> "$KEYS" ;;
    *) printf '%s\n' "$*" >> "$WORK/herdr-calls.log"; return 0 ;;
  esac
}
herdr() { _stub "$@"; }
ps() { printf '1\n'; }
export -f _stub herdr ps

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
reset_keys()   { : > "$KEYS"; }
keys_pressed() { wc -l < "$KEYS" | tr -d ' '; }

. "$here/lib/run-registry.sh"
. "$here/lib/prompt-parse.sh"
. "$here/tests/fixtures/task-authorization.sh"
fixture_register_task run1 task1 w1 c1 "w9:p9" "cond-birth" "$PANE" "$BIRTH" /repo "$WT" "impl:decline-nonfs" >/dev/null 2>&1 \
  || { echo "fixture registration failed (task1)"; exit 1; }
DB="$HERDR_RUN_STATE_DIR/registry.sqlite3"
OCC=(python3 "$here/lib/prompt-occurrence.py")
[ "$(task_for_pane "$PANE" | jq -r '.task_id + " " + .pane_birth + " " + .worktree')" = "task1 $BIRTH $WT" ] \
  || { echo "fixture identity wrong: $(task_for_pane "$PANE")"; exit 1; }
set_task_state run1 task1 blocked >/dev/null 2>&1

sel() { ( HERDR_FIXTURE_CALLER_PANE="${HERDR_PANE_ID:-}" bash "$here/herdr-select.sh" "$PANE" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" ); }
conductor_bound_choice() { ( c="$1"; shift; export HERDR_PANE_ID=w9:p9
  export HERDR_SELECT_ACTOR=bound-conductor
  sel "$c" --authority conductor --review-category branch-work \
    --review-reason "Reviewed the complete recorded payload and its target." \
    --approval-request-id "$BOUND_REQUEST" --expect-arguments-digest "$BOUND_DIGEST" \
    --expect-tool-call-id "$CALL_ID" --expect-payload-sha "$BOUND_PAYLOAD_SHA" "$@" )
}

render_keyhint_panel() {                # <tool> <input-json> -> OMP 18.10.4 panel
  python3 - "$1" "$2" <<'PY'
import json, re, sys
tool, inp = sys.argv[1], json.loads(sys.argv[2])
if tool == "write":
    detail = [f"Path: {inp['path']}", "Content: 1 line in the tool call"]
else:
    detail = [f"File: {m}" for m in re.findall(r"^\[([^#\]]+)#", inp["input"], re.M)]
print("\u256d\u2500 Allow tool: " + tool)
for row in detail:
    print("\u2502 " + row)
print("\u251c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500")
print("\u2502 \u2303\u21b5/\u2303Q approve \u00b7 Esc deny")
print("\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500")
PY
}
CALL=0
record() {                              # <tool> <input-json> -> PID CALL_ID OCC_KEY
  render_keyhint_panel "$1" "$2" > "$SCREEN"
  CALL=$((CALL + 1)); CALL_ID="call-$CALL"
  PID="$(prompt_id "$PANE")"
  append_event run1 task1 input_required \
    "$(jq -nc --arg pid "$PID" --arg tool "$1" '{message:"omp needs permission", prompt_id:$pid, command:"", tool:$tool}')" >/dev/null 2>&1
  local id=(--db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" --session "$SESSION" --call-id "$CALL_ID")
  local recorded_input="$2" bound_envelope=""
  if [ -n "${BOUND_REQUEST:-}" ]; then
    bound_envelope="--bound-envelope"
    recorded_input="$(jq -nc --argjson i "$2" --arg j "$(printf '%s' "$2" | jq -cS .)" '{input:$i,core_arguments_json:$j}')"
  fi
  OCC_KEY="$(printf '%s' "$recorded_input" | "${OCC[@]}" seen "${id[@]}" --tool "$1" --input-json - $bound_envelope --source tool_approval_requested \
    ${BOUND_REQUEST:+--approval-request-id "$BOUND_REQUEST"} \
    ${BOUND_DIGEST:+--core-arguments-digest "$BOUND_DIGEST"} \
    ${BOUND_PROTOCOL:+--binding-protocol "$BOUND_PROTOCOL"} \
    --cwd "$WT" --dispatched-at-ms "$(python3 -c 'import time; print(int(time.time()*1000))')" | jq -r .occ_key)"
  "${OCC[@]}" screen "${id[@]}" --display pending_parseable --prompt-id "$PID" >/dev/null
  : > "$SCREEN"   # OMP's v1 deferred resolver paints no panel; Path A never reads the screen for it.
}
write_input() { jq -nc --arg p "$1" --arg c "$2" '{path:$p, content:$c}'; }
# The sha a reviewer reads from `proposal --show`, computed independently.
input_sha() { python3 - "$1" "$2" <<'PY'
import hashlib, json, sys
body = json.dumps({"tool": sys.argv[1], "input": json.loads(sys.argv[2]), "known": True},
                  sort_keys=True, separators=(",", ":"), default=str)
print(hashlib.sha256(body.encode()).hexdigest())
PY
}
declined_rows() { sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE choice_text='Deny';" 2>/dev/null || echo 0; }
decline_reason() { sqlite3 "$DB" "SELECT json_extract(payload,'\$.reason') FROM events WHERE type='prompt_occ_declined' AND json_extract(payload,'\$.occ_key')='$1' ORDER BY sequence DESC LIMIT 1;"; }

# OMP's own deferred bound write to a background job's stdin to kill it --
# NOT a plain filesystem path, the exact shape that used to be stuck.
NONFS_PATH="proc://bg_10/kill"
new_nonfs_occurrence() {                # <request-id> -> sets BOUND_REQUEST/DIGEST/PAYLOAD_SHA/CALL_ID/OCC_KEY
  BOUND_REQUEST="$1"; BOUND_PROTOCOL="omp.tool-approval-binding.v1"
  NONFS_INPUT="$(write_input "$NONFS_PATH" "kill")"
  NONFS_JSON="$(printf '%s' "$NONFS_INPUT" | jq -cS .)"
  BOUND_DIGEST="sha256:$(printf '%s' "$NONFS_JSON" | shasum -a 256 | awk '{print $1}')"
  record write "$NONFS_INPUT"
  BOUND_PAYLOAD_SHA="$(input_sha write "$NONFS_INPUT")"
}

printf '== (a) decline of a malformed (non-filesystem) target succeeds ==\n'
new_nonfs_occurrence request-nonfs-decline
A_OCC="$OCC_KEY"
before="$(declined_rows)"; reset_keys; conductor_bound_choice 2; rc=$?
authorized_count="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_authorized' AND json_extract(payload,'\$.occ_key')='$A_OCC';")"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" = 0 ] && [ "$authorized_count" = 1 ] && [ "$(declined_rows)" = $((before + 1)) ]; then
  ok "Deny on proc://bg_10/kill resolves: exit 0, no key pressed, exactly one Deny recorded"
else
  bad "decline of malformed target: rc=$rc keys=$(keys_pressed) authorized_count=$authorized_count; $(cat "$WORK/err.txt")"
fi
BOUND_REQUEST=""; BOUND_DIGEST=""; BOUND_PROTOCOL=""

printf '== (b) approve of the same malformed target is still rejected (fresh occurrence) ==\n'
new_nonfs_occurrence request-nonfs-approve
B_OCC="$OCC_KEY"
reset_keys; conductor_bound_choice 1; rc=$?
b_authorized="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_authorized' AND json_extract(payload,'\$.occ_key')='$B_OCC';")"
if [ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] && [ "$b_authorized" = 0 ] && grep -qF "is not a plain filesystem path" "$WORK/err.txt"; then
  ok "Approve of proc://bg_10/kill is refused: exit 8, no key, no authorization, target-shape reason on stderr"
else
  bad "approve of malformed target: rc=$rc keys=$(keys_pressed) authorized=$b_authorized; $(cat "$WORK/err.txt")"
fi
case "$(decline_reason "$B_OCC")" in
  *"is not a plain filesystem path"*) ok "the refused Approve is itself audited as prompt_occ_declined with the target-shape reason (#277 terminal-state contract)" ;;
  *) bad "refused approve not audited as declined: $(decline_reason "$B_OCC")" ;;
esac
BOUND_REQUEST=""; BOUND_DIGEST=""; BOUND_PROTOCOL=""

printf '== (c) identity mismatch and staleness are still refused on the decline path ==\n'
new_nonfs_occurrence request-nonfs-callid
real_call="$CALL_ID"
CALL_ID="call-not-this-one"
reset_keys; conductor_bound_choice 2; rc=$?
[ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] && grep -qF "exact bound request verification failed" "$WORK/err.txt" \
  && ok "a Deny with the wrong tool_call_id is refused (decline does not bypass binding identity)" \
  || bad "wrong call id decline: rc=$rc keys=$(keys_pressed); $(cat "$WORK/err.txt")"
CALL_ID="$real_call"
reset_keys; conductor_bound_choice 2; rc=$?
[ "$rc" -eq 0 ] && ok "the same request declines once its exact call id is used" \
  || bad "decline after bad-call-id attempt: rc=$rc; $(cat "$WORK/err.txt")"
BOUND_REQUEST=""; BOUND_DIGEST=""; BOUND_PROTOCOL=""

new_nonfs_occurrence request-nonfs-stale
STALE_OCC="$OCC_KEY"
STALE_AT="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
sqlite3 "$DB" "UPDATE events SET occurred_at='$STALE_AT' WHERE json_extract(payload,'\$.occ_key')='$STALE_OCC';"
reset_keys; conductor_bound_choice 2; rc=$?
[ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] && grep -qF "exact bound request verification failed" "$WORK/err.txt" \
  && ok "a stale (>1h) bound request is refused on the decline path too" \
  || bad "stale decline: rc=$rc keys=$(keys_pressed); $(cat "$WORK/err.txt")"
BOUND_REQUEST=""; BOUND_DIGEST=""; BOUND_PROTOCOL=""

printf '== (d) a race between two decline attempts on the same occurrence resolves exactly once ==\n'
new_nonfs_occurrence request-nonfs-race
: > "$SCREEN"
( conductor_bound_choice 2 >"$WORK/race-a.out" 2>"$WORK/race-a.err"; printf '%s' "$?" >"$WORK/race-a.rc" ) & race_a=$!
( conductor_bound_choice 2 >"$WORK/race-b.out" 2>"$WORK/race-b.err"; printf '%s' "$?" >"$WORK/race-b.rc" ) & race_b=$!
wait "$race_a"; wait "$race_b"
race_rcs="$(cat "$WORK/race-a.rc") $(cat "$WORK/race-b.rc")"
case "$race_rcs" in "0 8"|"8 0") ok "concurrent decline attempts on the same occurrence: exactly one wins (rcs: $race_rcs)" ;;
  *) bad "concurrent declines returned $race_rcs" ;;
esac
[ "$(keys_pressed)" = 0 ] && ok "the race sends no terminal key either way" || bad "race sent terminal keys"
BOUND_REQUEST=""; BOUND_DIGEST=""; BOUND_PROTOCOL=""

printf '== (e) a decline of an already-resolved occurrence is rejected (replay) ==\n'
new_nonfs_occurrence request-nonfs-replay
reset_keys; conductor_bound_choice 2; rc=$?
[ "$rc" -eq 0 ] && [ "$(keys_pressed)" = 0 ] && ok "first decline resolves" \
  || bad "first decline failed: rc=$rc; $(cat "$WORK/err.txt")"
reset_keys; conductor_bound_choice 2; rc=$?
[ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] && ok "a replayed decline of the same, now-resolved request is refused" \
  || bad "replayed decline: rc=$rc keys=$(keys_pressed); $(cat "$WORK/err.txt")"
reset_keys; conductor_bound_choice 1; rc=$?
[ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] && ok "an Approve of an already-declined request is refused too" \
  || bad "approve after decline: rc=$rc keys=$(keys_pressed); $(cat "$WORK/err.txt")"
BOUND_REQUEST=""; BOUND_DIGEST=""; BOUND_PROTOCOL=""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
