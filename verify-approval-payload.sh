#!/usr/bin/env bash
# verify-approval-payload.sh — herdr-control #277 end to end.
#
# The pinned omp patch exposes a request-id-targeted, digest-bound resolver.
# Herdr may resolve a write/edit only when that exact v1 binding is present;
# without it write/edit remains HUMAN-ONLY. The complete-payload review
# artifact and shared audit rows retain only header + sha256, never raw body.
#
# Runs the REAL herdr-select.sh against the same exported-function herdr stub
# verify-select-policy.sh uses. The property that matters: on every non-human
# write/edit attempt, NO KEY IS PRESSED. Bound approval also presses no key.
#
#   LC_ALL=C bash verify-approval-payload.sh
#
# Prerequisite (not a test): the bash-parser helper (.venv-bashlex, provisioned
# by install.sh --apply). Without it every non-human approval is held by
# _sp_shell_policy_ready, so this suite refuses to run rather than report
# those holds as passes or failures of the path under test.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

if [ ! -x "$here/.venv-bashlex/bin/python3" ] ||
   [ "$(printf 'true' | "$here/.venv-bashlex/bin/python3" "$here/lib/bashlex_classify.py" 2>/dev/null)" != ALLOW ]; then
  echo "PREREQ MISSING: $here/.venv-bashlex (bash parser helper); run install.sh --apply — suite not run" >&2
  exit 2
fi

WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"; export WORK   # the stub runs under herdr-select's set -u
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_BRIDGE_STATE="$WORK/bridge"
export XDG_RUNTIME_DIR="$WORK/runtime"; mkdir -p "$XDG_RUNTIME_DIR"
export SCREEN="$WORK/screen.txt" KEYS="$WORK/keys.log"
: > "$KEYS"
PANE="w1:p1"; BIRTH="term-abc-123"; SESSION="sess-1"
export PANE BIRTH
WT="$WORK/wt"; mkdir -p "$WT/.handoffs" "$WORK/outside"

# herdr stub: pane reads return $SCREEN; send-keys is logged.
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
fixture_register_task run1 task1 w1 c1 "w9:p9" "cond-birth" "$PANE" "$BIRTH" /repo "$WT" "impl:payload" >/dev/null 2>&1 \
  || { echo "fixture registration failed (task1)"; exit 1; }
DB="$HERDR_RUN_STATE_DIR/registry.sqlite3"
OCC=(python3 "$here/lib/prompt-occurrence.py")
[ "$(task_for_pane "$PANE" | jq -r '.task_id + " " + .pane_birth + " " + .worktree')" = "task1 $BIRTH $WT" ] \
  || { echo "fixture identity wrong: $(task_for_pane "$PANE")"; exit 1; }
set_task_state run1 task1 blocked >/dev/null 2>&1

sel() { ( HERDR_FIXTURE_CALLER_PANE="${HERDR_PANE_ID:-}" bash "$here/herdr-select.sh" "$PANE" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" ); }
# The conductor's operational prerequisites (category, reason, prompt id) are
# always supplied, so every refusal below is the write/edit rule's, not a usage error.
conductor() { ( export HERDR_PANE_ID=w9:p9
  sel 1 --authority conductor --review-category branch-work \
    --review-reason "Reviewed the complete recorded payload and its target." \
    --expect-prompt-id "$(prompt_id "$PANE")" "$@" ); }
conductor_bound_choice() { ( c="$1"; shift; export HERDR_PANE_ID=w9:p9
  export HERDR_SELECT_ACTOR=bound-conductor
  sel "$c" --authority conductor --review-category branch-work \
    --review-reason "Reviewed the complete recorded payload and its target." \
    --approval-request-id "$BOUND_REQUEST" --expect-arguments-digest "$BOUND_DIGEST" \
    --expect-tool-call-id "$CALL_ID" --expect-payload-sha "$BOUND_PAYLOAD_SHA" "$@" ); }
conductor_bound() { conductor_bound_choice 1; }

# The legacy panel paints a selectable menu. OMP 18.10.4's native approval
# overlay instead paints an action footer (`Q approve · Esc deny`) with no
# highlighted row. The installed-stack regression exercises both.
# shows `Path:` and `Content:` with each field clipped at 2000 chars plus
# "[…Nch elided…]"; an edit shows only one `File:` row per section.
render_panel() {                        # <tool> <input-json> -> panel text
  python3 - "$1" "$2" <<'PY'
import json, re, sys
tool, inp = sys.argv[1], json.loads(sys.argv[2])
clip = lambda s: s if len(s) <= 2000 else s[:2000] + f"[\u2026{len(s) - 2000}ch elided\u2026]"
if tool == "write":
    body = f"Path: {clip(inp['path'])}\nContent:\n{clip(inp['content'])}"
else:
    body = "\n".join(f"File: {clip(m)}" for m in re.findall(r"^\[([^#\]]+)#", inp["input"], re.M))
sys.stdout.write(f"Allow tool: {tool}\n{body}\n\n\033[48;2;42;47;65m Approve\033[0m\n Deny\n\n"
                 "up/down navigate  enter select  esc cancel\n")
PY
}
render_keyhint_panel() {                # <tool> <input-json> -> OMP 18.10.4 panel
  python3 - "$1" "$2" <<'PY'
import json, re, sys
tool, inp = sys.argv[1], json.loads(sys.argv[2])
if tool == "write":
    detail = [f"Path: {inp['path']}", "Content: 1 line in the tool call"]
else:
    detail = [f"File: {m}" for m in re.findall(r"^\[([^#\]]+)#", inp["input"], re.M)]
print("╭─ Allow tool: " + tool)
for row in detail:
    print("│ " + row)
print("├────────────────")
print("│ ⌃↵/⌃Q approve · Esc deny")
print("╰────────────────")
PY
}
# What the hook records: input_required (tool identity) + the occurrence with
# its complete input (seen, on stdin as the hook sends it) + the correlated
# screen prompt id. The panel is painted from the same input.
CALL=0
record() {                              # <tool> <input-json> -> PID CALL_ID OCC_KEY
  if [ "${PANEL_STYLE:-menu}" = keyhint ]; then
    render_keyhint_panel "$1" "$2" > "$SCREEN"
  else
    render_panel "$1" "$2" > "$SCREEN"
  fi
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
}
show() { "${OCC[@]}" proposal --db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" --prompt-id "$PID" --worktree "$WT" --show "$@"; }
# The sha a reviewer reads from `proposal --show`, computed independently.
input_sha() { python3 - "$1" "$2" <<'PY'
import hashlib, json, sys
body = json.dumps({"tool": sys.argv[1], "input": json.loads(sys.argv[2]), "known": True},
                  sort_keys=True, separators=(",", ":"), default=str)
print(hashlib.sha256(body.encode()).hexdigest())
PY
}
approve_rows() { sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE choice_text='Approve';" 2>/dev/null || echo 0; }
last_escalation() { sqlite3 "$DB" "SELECT json_extract(payload,'\$.command') FROM events WHERE type='approval_escalated' ORDER BY sequence DESC LIMIT 1;"; }
# A non-human Enter attempt on a write/edit: exit 8, no key, no Approve row,
# refused by the human-only rule.
human_only() {                          # <label>
  if [ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] && [ "$(approve_rows)" = "$approves_before" ] &&
     grep -qF "write/edit approvals are human-only" "$WORK/err.txt"; then
    ok "$1"
  else
    bad "$1: rc=$rc keys=$(keys_pressed) approve_rows=$(approve_rows)/$approves_before; $(tail -2 "$WORK/err.txt")"
  fi
}
attempt_all() {                         # <label> : peer, conductor, conductor with every flag
  approves_before="$(approve_rows)"
  reset_keys; sel 1 --authority peer; rc=$?; human_only "peer: $1"
  reset_keys; conductor; rc=$?; human_only "conductor: $1"
}
write_input() { jq -nc --arg p "$1" --arg c "$2" '{path:$p, content:$c}'; }
LONG="$(for i in $(seq 1 60); do printf 'row %03d: value %d, note: keep row %d intact.\n' "$i" "$((i * 7))" "$i"; done)"

printf '== complete payload capture and review artifact ==\n'
PLAN="$WT/.handoffs/plan.md"
IN="$(write_input "$PLAN" "$LONG")"; record write "$IN"; SHA="$(input_sha write "$IN")"; LONG_SHA="$SHA"
show > "$WORK/show.txt"
grep -qF "row 060: value 420, note: keep row 60 intact." "$WORK/show.txt" && grep -qF "payload_sha256: $SHA" "$WORK/show.txt" \
  && ok "--show prints the complete ${#LONG}-byte payload (last row included) with its independently computed sha256" \
  || bad "--show incomplete: $(head -5 "$WORK/show.txt")"
show --expect-sha "$SHA" | grep -q '^payload_sha256:' && ok "--expect-sha accepts the reviewed sha" || bad "--expect-sha rejected the reviewed sha"
show --expect-sha "$(printf '0%.0s' $(seq 1 64))" | grep -q '^REFUSED: payload changed since review' \
  && ok "--expect-sha refuses a different sha" || bad "--expect-sha accepted a different sha"
seen_row="$(sqlite3 "$DB" "SELECT payload FROM events WHERE type='prompt_occ_seen' AND json_extract(payload,'\$.occ_key')='$OCC_KEY';")"
[ "$(printf '%s' "$seen_row" | jq -r .payload_sha256)" = "$SHA" ] && ok "registry row carries the full payload sha256" || bad "seen row: $seen_row"
case "$seen_row" in *"row 0"*) bad "raw content in the events table" ;; *) ok "no raw content in the events table" ;; esac

printf '== exact bound request resolves without terminal input ==\n'
BOUND_REQUEST="request-277"; BOUND_PROTOCOL="omp.tool-approval-binding.v1"
SENTINEL="PRIVATE-SENTINEL-DO-NOT-AUDIT"
BOUND_INPUT="$(write_input "$WT/.handoffs/bound.md" "$SENTINEL bound payload")"
BOUND_JSON="$(printf '%s' "$BOUND_INPUT" | jq -cS .)"
BOUND_DIGEST="sha256:$(printf '%s' "$BOUND_JSON" | shasum -a 256 | awk '{print $1}')"
PANEL_STYLE=keyhint record write "$BOUND_INPUT"
[ "$(prompt_occurrence_display "$PANE")" = pending_parseable ] \
  && ok "OMP 18.10.4 key-hint approval panel is parseable for occurrence correlation" \
  || bad "OMP 18.10.4 key-hint panel was not parseable"
[ "$(prompt_menu_options "$PANE")" = $'1\tApprove\n2\tDeny' ] && [ -z "$(prompt_menu_selected "$PANE")" ] \
  && ok "key-hint panel exposes choices but no selectable default" \
  || bad "key-hint choices/default contract failed"
approves_before="$(approve_rows)"; reset_keys; conductor; rc=$?
authorized_count="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_authorized' AND json_extract(payload,'$.occ_key')='$OCC_KEY';")"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" = 0 ] && [ "$authorized_count" = 1 ] && [ "$(approve_rows)" = $((approves_before + 1)) ]; then
  ok "v1 request+digest binding records approval and sends no terminal key"
else
  bad "bound approval: rc=$rc keys=$(keys_pressed) authorized=$authorized_count approve_rows=$(approve_rows)/$approves_before; $(tail -2 "$WORK/err.txt")"
fi
if ! grep -R -F "$SENTINEL" "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$HERDR_BRIDGE_STATE/selections.jsonl" 2>/dev/null; then
  ok "bound payload sentinel is absent from shared registry, selection log, and bridge state"
else
  bad "bound payload sentinel leaked into shared audit state"
fi
BOUND_REQUEST=""; BOUND_DIGEST=""; BOUND_PROTOCOL=""

printf '== exact deferred request resolves with no painted panel ==\n'
BOUND_REQUEST="request-277-no-panel"; BOUND_PROTOCOL="omp.tool-approval-binding.v1"
BOUND_INPUT="$(write_input "$WT/.handoffs/bound-no-panel.md" "private deferred payload")"
BOUND_JSON="$(printf '%s' "$BOUND_INPUT" | jq -cS .)"
BOUND_DIGEST="sha256:$(printf '%s' "$BOUND_JSON" | shasum -a 256 | awk '{print $1}')"
PANEL_STYLE=keyhint record write "$BOUND_INPUT"; BOUND_PAYLOAD_SHA="$(input_sha write "$BOUND_INPUT")"
: > "$SCREEN"
approves_before="$(approve_rows)"; reset_keys; conductor_bound; rc=$?
authorized_count="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_authorized' AND json_extract(payload,'$.occ_key')='$OCC_KEY';")"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" = 0 ] && [ "$authorized_count" = 1 ] && [ "$(approve_rows)" = $((approves_before + 1)) ]; then
  ok "request id + tool call + arguments digest + payload sha resolve without a panel or terminal key"
else
  bad "no-panel bound approval: rc=$rc keys=$(keys_pressed) authorized=$authorized_count; $(tail -3 "$WORK/err.txt")"
fi
reset_keys; conductor_bound; rc=$?
[ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] && ok "duplicate bound resolution is refused" \
  || bad "duplicate bound resolution: rc=$rc keys=$(keys_pressed)"

printf '== automated write/edit resolves by its own exact OMP request id, never the painted screen (Finding 1) ==\n'
BOUND_REQUEST="request-exact-1"; BOUND_PROTOCOL="omp.tool-approval-binding.v1"
EXACT_INPUT="$(write_input "$WT/.handoffs/exact.md" "exact routing payload")"
EXACT_JSON="$(printf '%s' "$EXACT_INPUT" | jq -cS .)"
BOUND_DIGEST="sha256:$(printf '%s' "$EXACT_JSON" | shasum -a 256 | awk '{print $1}')"
record write "$EXACT_INPUT"
EXACT_OCC="$OCC_KEY"
approves_before="$(approve_rows)"; reset_keys; sel 1 --authority peer; rc=$?
authorized_count="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_authorized' AND json_extract(payload,'$.occ_key')='$EXACT_OCC';")"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" = 0 ] && [ "$authorized_count" = 1 ] && [ "$(approve_rows)" = $((approves_before + 1)) ]; then
  ok "automated peer approval resolves the sole pending bound write by its own exact request id, no key pressed"
else
  bad "automated exact-id approval: rc=$rc keys=$(keys_pressed) authorized=$authorized_count; $(tail -3 "$WORK/err.txt")"
fi
set_task_state run1 task1 blocked >/dev/null 2>&1

printf '== two concurrent pending bound write/edit occurrences: automated approval refuses (Finding 1 ambiguity) ==\n'
BOUND_REQUEST="request-exact-x"
X_INPUT="$(write_input "$WT/.handoffs/exact-x.md" "X payload, still pending, no fresh screen write of its own")"
X_JSON="$(printf '%s' "$X_INPUT" | jq -cS .)"
BOUND_DIGEST="sha256:$(printf '%s' "$X_JSON" | shasum -a 256 | awk '{print $1}')"
PANEL_STYLE=keyhint record write "$X_INPUT"; X_CALL="$CALL_ID"; X_OCC="$OCC_KEY"
BOUND_REQUEST="request-exact-y"
Y_INPUT="$(write_input "$WT/.handoffs/exact-y.md" "Y payload, genuinely the one painted")"
Y_JSON="$(printf '%s' "$Y_INPUT" | jq -cS .)"
BOUND_DIGEST="sha256:$(printf '%s' "$Y_JSON" | shasum -a 256 | awk '{print $1}')"
PANEL_STYLE=keyhint record write "$Y_INPUT"; Y_CALL="$CALL_ID"; Y_OCC="$OCC_KEY"
approves_before="$(approve_rows)"; reset_keys; sel 1 --authority peer; rc=$?
x_authorized="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_authorized' AND json_extract(payload,'$.occ_key')='$X_OCC';")"
y_authorized="$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_authorized' AND json_extract(payload,'$.occ_key')='$Y_OCC';")"
if [ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] && [ "$x_authorized" = 0 ] && [ "$y_authorized" = 0 ] && \
   [ "$(approve_rows)" = "$approves_before" ] && grep -qF "write/edit approvals are human-only" "$WORK/err.txt"; then
  ok "two simultaneously pending bound write/edit occurrences: automated approval refuses instead of guessing which panel owns the screen"
else
  bad "ambiguous bound occurrences: rc=$rc keys=$(keys_pressed) x_authorized=$x_authorized y_authorized=$y_authorized; $(tail -3 "$WORK/err.txt")"
fi
id=(--db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" --session "$SESSION")
"${OCC[@]}" withdrawn "${id[@]}" --call-id "$X_CALL" --reason test >/dev/null
"${OCC[@]}" withdrawn "${id[@]}" --call-id "$Y_CALL" --reason test >/dev/null
BOUND_REQUEST=""; BOUND_DIGEST=""; BOUND_PROTOCOL=""

printf '== deferred request revalidates ownership and resolves once under a race ==\n'
BOUND_REQUEST="request-277-owner-change"
BOUND_INPUT="$(write_input "$WT/.handoffs/bound-owner.md" "owner must remain current")"
BOUND_JSON="$(printf '%s' "$BOUND_INPUT" | jq -cS .)"
BOUND_DIGEST="sha256:$(printf '%s' "$BOUND_JSON" | shasum -a 256 | awk '{print $1}')"
PANEL_STYLE=keyhint record write "$BOUND_INPUT"; BOUND_PAYLOAD_SHA="$(input_sha write "$BOUND_INPUT")"; : > "$SCREEN"
sqlite3 "$DB" "UPDATE tasks SET conductor_pane_id='w8:p8', conductor_pane_birth='other-birth' WHERE run_id='run1' AND task_id='task1';"
reset_keys; conductor_bound; rc=$?
[ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] && ok "a former conductor cannot resolve after ownership changes" \
  || bad "ownership handoff: rc=$rc keys=$(keys_pressed)"
sqlite3 "$DB" "UPDATE tasks SET conductor_pane_id='w9:p9', conductor_pane_birth='cond-birth' WHERE run_id='run1' AND task_id='task1';"

BOUND_REQUEST="request-277-race"
BOUND_INPUT="$(write_input "$WT/.handoffs/bound-race.md" "one decision wins")"
BOUND_JSON="$(printf '%s' "$BOUND_INPUT" | jq -cS .)"
BOUND_DIGEST="sha256:$(printf '%s' "$BOUND_JSON" | shasum -a 256 | awk '{print $1}')"
PANEL_STYLE=keyhint record write "$BOUND_INPUT"; BOUND_PAYLOAD_SHA="$(input_sha write "$BOUND_INPUT")"; : > "$SCREEN"
( conductor_bound_choice 1 >"$WORK/race-approve.out" 2>"$WORK/race-approve.err"; printf '%s' "$?" >"$WORK/race-approve.rc" ) & race_a=$!
( conductor_bound_choice 2 >"$WORK/race-deny.out" 2>"$WORK/race-deny.err"; printf '%s' "$?" >"$WORK/race-deny.rc" ) & race_d=$!
wait "$race_a"; wait "$race_d"
race_rcs="$(cat "$WORK/race-approve.rc") $(cat "$WORK/race-deny.rc")"
case "$race_rcs" in "0 8"|"8 0") ok "concurrent opposite decisions have exactly one successful resolver" ;;
  *) bad "concurrent opposite decisions returned $race_rcs" ;;
esac
[ "$(keys_pressed)" = 0 ] && ok "concurrent bound decisions send no terminal key" || bad "race sent terminal keys"
[ "$(sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE prompt_id='$BOUND_REQUEST' AND outcome='lost-race';")" = 1 ] \
  && ok "the losing concurrent decision is explicitly audited as lost-race" \
  || bad "concurrent loser was not audited as lost-race"
[ "$(sqlite3 "$DB" "SELECT count(*) FROM approvals WHERE prompt_id='$BOUND_REQUEST' AND outcome IN ('bound-request','lost-race') AND decided_by='bound-conductor';")" = 2 ] \
  && ok "both bound race outcomes retain asserted selector actor provenance" \
  || bad "bound race approvals lost selector actor provenance"
[ "$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='prompt_occ_authorized' AND json_extract(payload,'$.decided_by')='bound-conductor' AND json_extract(payload,'$.choice') IN ('Approve','Deny');")" -ge 1 ] \
  && ok "the winning bound occurrence retains asserted selector actor provenance" \
  || bad "bound occurrence event lost selector actor provenance"

atomic_claim() {
  "${OCC[@]}" authorize-bound --db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" \
    --session "$SESSION" --call-id "$CALL_ID" --approval-request-id "$BOUND_REQUEST" \
    --core-arguments-digest "$BOUND_DIGEST" --expect-payload-sha "$BOUND_PAYLOAD_SHA" \
    --worktree "$WT" --conductor-pane w9:p9 --conductor-birth cond-birth \
    --approval-id "appr-atomic-$CALL_ID" --choice Approve --authority conductor \
    --decided-by atomic-test \
    --review-reason reviewed --review-category branch-work --reviewer w9:p9 --audit-text header
}
for terminal in declined withdrawn mismatch; do
  BOUND_REQUEST="request-277-$terminal"
  BOUND_INPUT="$(write_input "$WT/.handoffs/bound-$terminal.md" "closed request stays closed")"
  BOUND_JSON="$(printf '%s' "$BOUND_INPUT" | jq -cS .)"
  BOUND_DIGEST="sha256:$(printf '%s' "$BOUND_JSON" | shasum -a 256 | awk '{print $1}')"
  PANEL_STYLE=keyhint record write "$BOUND_INPUT"; BOUND_PAYLOAD_SHA="$(input_sha write "$BOUND_INPUT")"
  case "$terminal" in
    declined) "${OCC[@]}" declined --db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" --session "$SESSION" --call-id "$CALL_ID" --reason test >/dev/null ;;
    withdrawn) "${OCC[@]}" withdrawn --db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" --session "$SESSION" --call-id "$CALL_ID" --reason test >/dev/null ;;
    mismatch) append_event run1 task1 prompt_occ_mismatch "$(jq -nc --arg k "$OCC_KEY" '{occ_key:$k}')" >/dev/null ;;
  esac
  atomic_result="$(atomic_claim)"
  [ "$(printf '%s' "$atomic_result" | jq -r '.written // empty')" = closed_or_mismatched ] \
    && ok "atomic claim refuses an occurrence already $terminal" \
    || bad "atomic claim accepted $terminal occurrence: $atomic_result"
done
BOUND_REQUEST=""; BOUND_DIGEST=""; BOUND_PROTOCOL=""
SHA="$LONG_SHA"

printf '== older OMP processes remain fail-closed after shared-hook reload ==\n'
PANEL_STYLE=keyhint record write "$(write_input "$WT/.handoffs/legacy.md" "no binding from older OMP")"
attempt_all "key-hint write with no exact binding from an older OMP process"

printf '== every non-human write/edit Enter attempt is refused (former positives) ==\n'
record write "$IN"
attempt_all "long in-worktree write"
esc="$(last_escalation)"
case "$esc" in
  *"row 0"*) bad "approval_escalated copied raw payload" ;;
  "Allow tool: write Path: $PLAN [complete payload sha256 $SHA, "*) ok "refusal audited by header + sha256 only" ;;
  *) bad "approval_escalated command: $esc" ;;
esac
grep -qF "proposal --db $DB --run run1 --task task1 --pane $PANE --prompt-id $PID --worktree $WT --show" "$WORK/err.txt" \
  && ok "refusal points the human at the complete-payload review command" || bad "no review command: $(cat "$WORK/err.txt")"
approves_before="$(approve_rows)"; reset_keys
conductor --expect-payload-sha "$SHA"; rc=$?
[ "$rc" -eq 2 ] && [ "$(keys_pressed)" = 0 ] && ok "the removed --expect-payload-sha binding is not accepted (usage error, no key)" \
  || bad "--expect-payload-sha: rc=$rc keys=$(keys_pressed)"
NP="$(jq -nc '{heading:"h", content:"c"}')"
record write "$(write_input "xd://notepad_append" "$NP")"
attempt_all "xd://notepad_append write (approvable by a peer before #277)"
record write "$(write_input "$WT/.handoffs/short.md" "one line")"
attempt_all "one-line in-worktree write"
printf 'a\n' > "$WT/a.txt"; printf 'b\n' > "$WT/b.txt"
EDIT="$(printf '[a.txt#1A2B]\n'; for i in $(seq 1 30); do printf 'PUT >%d:\n+inserted line %d\n' "$i" "$i"; done; printf '[b.txt#3C4D]\nCUT 1\n')"
record edit "$(jq -nc --arg i "$EDIT" '{input:$i}')"
attempt_all "two-file edit"
# No recorded occurrence at all: still the same refusal (the rule is the tool).
render_panel write "$(write_input "$WT/.handoffs/w.md" "no occurrence")" > "$SCREEN"
append_event run1 task1 input_required "$(jq -nc --arg pid "$(prompt_id "$PANE")" '{message:"m", prompt_id:$pid, command:"", tool:"write"}')" >/dev/null 2>&1
attempt_all "write with no recorded occurrence"

printf '== identical-render queued prompts (no screen check can tell them apart) ==\n'
# Two queued edits of the same file: omp paints only the file name.
EA="$(jq -nc '{input:"[a.txt#1A2B]\nCUT 1\n"}')"; EB="$(jq -nc '{input:"[a.txt#1A2B]\nPUT >1:\n+rm -rf important\n"}')"
[ "$(render_panel edit "$EA")" = "$(render_panel edit "$EB")" ] && [ "$(input_sha edit "$EA")" != "$(input_sha edit "$EB")" ] \
  && ok "fixture: two different same-file edits render byte-identical panels" || bad "same-file edit fixture"
record edit "$EA"; attempt_all "same-file edit A (reviewed)"
record edit "$EB"; attempt_all "same-file edit B painted in A's place"
# Two writes sharing target, first 2000 UTF-16 units and remaining length.
HEAD2K="$(printf 'x%.0s' $(seq 1 2000))"
WA="$(write_input "$PLAN" "${HEAD2K}tail-A-safe")"; WB="$(write_input "$PLAN" "${HEAD2K}tail-B-evil")"
[ "$(render_panel write "$WA")" = "$(render_panel write "$WB")" ] && [ "$(input_sha write "$WA")" != "$(input_sha write "$WB")" ] \
  && ok "fixture: two different long writes render byte-identical panels" || bad "identical-render write fixture"
record write "$WA"; attempt_all "identical-render write A (reviewed)"
record write "$WB"; attempt_all "identical-render write B painted in A's place"

printf '== refusal audit never carries raw write/edit content, whatever the proposal state ==\n'
# A sentinel in the payload must reach no shared store: not the events/
# approvals tables (approval_escalated, and the wake's input_required row),
# not any herdr call (the conductor wake), not the bridge state. The proposal
# file is the one place it may live. A wake_held row makes the refusal really
# release the held wake, so the wake path runs.
: > "$WORK/herdr-calls.log"
no_raw() {                              # <label> <sentinel> <expected escalation command>
  grep -qF "$2" "$SCREEN" || { bad "$1: control: sentinel not on the panel"; return; }
  sleep 3   # the released wake runs in the background
  local dump; dump="$(sqlite3 "$DB" .dump)"
  [ "$(last_escalation)" = "$3" ] && ok "$1: escalation is '$3'" || bad "$1: escalation command: $(last_escalation)"
  if printf '%s' "$dump" | grep -qF "$2" || grep -rqF "$2" "$WORK/herdr-calls.log" "$HERDR_BRIDGE_STATE" 2>/dev/null; then
    bad "$1: raw content reached a shared store or the wake"
  else
    ok "$1: no raw content in registry, wake or bridge state"
  fi
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='wake_hold_released' AND json_extract(payload,'\$.prompt_id')='$PID';")" = 1 ] \
    && ok "$1: the held wake was released (wake path exercised)" || bad "$1: wake not released"
}
hold() { append_event run1 task1 wake_held "$(jq -nc --arg pid "$PID" '{prompt_id:$pid}')" >/dev/null 2>&1; }
WITHHELD="complete payload not verified; panel text withheld"
S=SENTINEL277valid; IN="$(write_input "$WT/.handoffs/s1.md" "$S body")"; record write "$IN"; hold
approves_before="$(approve_rows)"; reset_keys; sel 1 --authority peer; rc=$?; human_only "peer: valid proposal"
no_raw "valid proposal" "$S" "Allow tool: write Path: $WT/.handoffs/s1.md [complete payload sha256 $(input_sha write "$IN"), 21 bytes]"
S=SENTINEL277missing; record write "$(write_input "$WT/.handoffs/s2.md" "$S body")"; hold
rm -f "$HERDR_RUN_STATE_DIR/proposals/$OCC_KEY.json"
approves_before="$(approve_rows)"; reset_keys; sel 1 --authority peer; rc=$?; human_only "peer: missing proposal"
no_raw "missing proposal" "$S" "Allow tool: write [$WITHHELD]"
S=SENTINEL277hash; record write "$(write_input "$WT/.handoffs/s3.md" "$S body")"; hold
PF="$HERDR_RUN_STATE_DIR/proposals/$OCC_KEY.json"; jq -c '.input.content |= .[0:5]' "$PF" > "$WORK/pf.t" && cat "$WORK/pf.t" > "$PF"
approves_before="$(approve_rows)"; reset_keys; sel 1 --authority peer; rc=$?; human_only "peer: hash-refused (truncated) proposal"
no_raw "hash-refused proposal" "$S" "Allow tool: write [$WITHHELD]"
S=SENTINEL277malformed; record edit "$(jq -nc --arg s "$S" '{input:("[" + $s + ".txt#1A2B]\nCUT 1\n")}')"; hold
printf 'not json' > "$HERDR_RUN_STATE_DIR/proposals/$OCC_KEY.json"
approves_before="$(approve_rows)"; reset_keys; sel 1 --authority peer; rc=$?; human_only "peer: malformed edit proposal"
no_raw "malformed edit proposal" "$S" "Allow tool: edit [$WITHHELD]"
S=SENTINEL277noocc; render_panel write "$(write_input "$WT/.handoffs/s5.md" "$S body")" > "$SCREEN"; PID="$(prompt_id "$PANE")"
append_event run1 task1 input_required "$(jq -nc --arg pid "$PID" '{message:"m", prompt_id:$pid, command:"", tool:"write"}')" >/dev/null 2>&1; hold
approves_before="$(approve_rows)"; reset_keys; sel 1 --authority peer; rc=$?; human_only "peer: no recorded occurrence"
no_raw "no recorded occurrence" "$S" "Allow tool: write [$WITHHELD]"

printf '== hard links and path escapes: the review artifact refuses them ==\n'
HL="$WT/.handoffs/linked.md"; printf 'old\n' > "$HL"; ln "$HL" "$WORK/outside/other-name.md"
record write "$(write_input "$HL" "new")"
show | grep -q '^REFUSED: target .* is a hard link' && ok "--show refuses a hard-linked target" || bad "hard link: $(show)"
attempt_all "write to a hard-linked target"
ln -s "$WORK/outside" "$WT/.handoffs/out-link"
for target in "$WORK/outside/a.md" "../outside/b.md" ".handoffs/out-link/c.md" ".git/config"; do
  record write "$(write_input "$target" "payload for $target")"
  show | grep -q '^REFUSED: ' && ok "--show refuses target $target" || bad "--show accepted $target"
done
P3="$WT/.handoffs/x.md"; IN="$(write_input "$P3" "$LONG")"; record write "$IN"
PF="$HERDR_RUN_STATE_DIR/proposals/$OCC_KEY.json"; cp "$PF" "$WORK/pf.orig"
jq -c '.input.content |= .[0:900]' "$WORK/pf.orig" > "$PF"
show | grep -q '^REFUSED: proposal does not hash' && ok "--show refuses a truncated proposal" || bad "truncated proposal shown"
rm -f "$PF"; show | grep -q '^REFUSED: proposal file missing' && ok "--show refuses a missing proposal" || bad "missing proposal shown"

printf '== lifecycle evidence for a human-approved write (synthetic fixture timing) ==\n'
P9="$WT/.handoffs/human.md"; IN="$(write_input "$P9" "$LONG")"; record write "$IN"
id=(--db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" --session "$SESSION" --call-id "$CALL_ID")
"${OCC[@]}" authorized "${id[@]}" --decided-by human --choice approve >/dev/null
"${OCC[@]}" started "${id[@]}" >/dev/null
printf '%s' "$LONG" > "$P9"
"${OCC[@]}" completed "${id[@]}" >/dev/null
timeline="$(sqlite3 -json "$DB" "SELECT type, payload FROM events WHERE json_extract(payload,'\$.occ_key')='$OCC_KEY' ORDER BY sequence;" |
  jq -r '(map({(.type): (.payload | fromjson)}) | add) as $e
    | [["dispatched", $e.prompt_occ_seen.dispatched_at_ms], ["proposal_created", $e.prompt_occ_seen.at_ms],
       ["approval_resolved", $e.prompt_occ_authorized.at_ms], ["exec_start", $e.prompt_occ_started.at_ms],
       ["exec_end_result", $e.prompt_occ_completed.at_ms]]
    | .[0][1] as $t0 | map("\(.[0])=+\(.[1] - $t0)ms") | join(" ")' 2>&1)"
echo "    synthetic: $timeline"
printf '%s' "$timeline" | grep -Eq '^dispatched=\+0ms proposal_created=\+[0-9]+ms approval_resolved=\+[0-9]+ms exec_start=\+[0-9]+ms exec_end_result=\+[0-9]+ms$' \
  && ok "every lifecycle timestamp is recorded, in order" || bad "timeline incomplete: $timeline"
[ ! -e "$HERDR_RUN_STATE_DIR/proposals/$OCC_KEY.json" ] && ok "proposal file deleted once the occurrence resolved" || bad "proposal retained after completion"

printf '== unknown authorization choices never validate completion ==\n'
record write "$(write_input "$WT/.handoffs/unknown-choice.md" "unknown is not approval")"
unknown_id=(--db "$DB" --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" --session "$SESSION" --call-id "$CALL_ID")
"${OCC[@]}" authorized "${unknown_id[@]}" --decided-by fixture --choice future-choice >/dev/null
"${OCC[@]}" completed "${unknown_id[@]}" >/dev/null
unknown_lifecycle="$("${OCC[@]}" fold --db "$DB" --run run1 --task task1 | jq -r --arg k "$OCC_KEY" '.[$k].lifecycle // empty')"
[ "$unknown_lifecycle" = resolved:withdrawn ] \
  && ok "unrecognized choice plus completion is withdrawn, not approved" \
  || bad "unrecognized choice completion folded as $unknown_lifecycle"

printf '== bash approvals are untouched ==\n'
printf 'Allow tool: bash\nCommand: ls -la\n\n\033[48;2;42;47;65m Approve\033[0m\n Deny\n\nup/down navigate  enter select  esc cancel\n' > "$SCREEN"; reset_keys
append_event run1 task1 input_required "$(jq -nc --arg pid "$(prompt_id "$PANE")" '{message:"m", prompt_id:$pid, command:"ls -la", tool:"bash"}')" >/dev/null 2>&1
sel 1 --authority peer; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$KEYS")" = Enter ] && ok "peer bash approval still presses Enter (positive control: the stub and selector work)" \
  || bad "bash approval: rc=$rc keys=$(keys_pressed); $(tail -3 "$WORK/err.txt")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
