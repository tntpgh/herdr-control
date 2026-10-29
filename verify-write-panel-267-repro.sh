#!/usr/bin/env bash
# verify-write-panel-267-repro.sh — synthetic reproduction of the GBP
# (wB4:p4, 7098 B) and Intel (wB2:p7, 7706 B) stuck write-panel saves, built
# on the SAME harness pattern as verify-select-policy.sh (stubbed herdr, the
# REAL herdr-select.sh, a fixture task registry) — never against a live pane.
# See docs/design/write-panel-ceiling-267.md for the full writeup of what
# this does and does not confirm.
#
# Findings, both against the REAL (unmodified) herdr-select.sh and
# prompt-occurrence.py, not a reimplementation:
#   - Approve correctly refuses (rc=8) for peer/human-excluded authority on
#     both panels, per #277 — write/edit stays categorically human-only
#     regardless of size. Unaffected by this work.
#   - Deny SUCCEEDS (rc=0, one key pressed) for both peer and human
#     authority on both the 7098 B and 7706 B panels, once the fixture
#     starts with Deny already highlighted — the same convention
#     verify-select-policy.sh uses for every Deny case (its stubbed pane
#     never moves its own highlight on a keypress; see that file's
#     set_menu_deny/set_rows_deny). A static "Deny also refused" code
#     defect was NOT reproduced this way.
#   - gap2 ("tool 'write' is not the write/edit tool on screen ('bash')")
#     IS reproduced exactly, mechanically: `proposal_check`
#     (lib/prompt-occurrence.py, called by herdr-select.sh:889-891 as the
#     `proposal` subcommand — not `pending-bound`, a different, exact-
#     binding-only lookup used later at :904-906) refuses whenever its
#     --tool cross-check argument (task_input_required_tool's answer for
#     the CURRENT screen prompt) disagrees with the tool recorded on the
#     occurrence itself (from the hook's own `seen` call at dispatch time).
#     This reproduction proves the MECHANISM; it does not prove WHY the two
#     signals would disagree for a genuine write panel in production — that
#     needs either the live incident's actual registry rows or tracing
#     whatever derives task_input_required_tool's answer (a scrape-based
#     signal, unlike `seen`'s hook-level one) for a real oversized panel.
#
#   bash verify-write-panel-267-repro.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$here/tmp/repro267"
mkdir -p "$WORK"
rm -f "$WORK/runs/registry.sqlite3" "$WORK/runs/registry.sqlite3-wal" "$WORK/runs/registry.sqlite3-shm"
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_BRIDGE_STATE="$WORK/bridge"
export HERDR_PROMPT_SETTLE_WAIT_S=0
export XDG_RUNTIME_DIR="$WORK/runtime"; mkdir -p "$XDG_RUNTIME_DIR"
export SCREEN="$WORK/screen.txt"
export KEYS="$WORK/keys.log"
: > "$KEYS"

PANE="wB4:p4"
BIRTH="term-gbp-1"
export PANE BIRTH

_std_herdr_stub() {
  case "$1 $2" in
    "pane process-info")
      local pid=999999
      [ "${4:-}" != "${HERDR_FIXTURE_CALLER_PANE:-}" ] || pid="$PPID"
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"claude","cmdline":"claude --model sonnet"}]}}}\n' "$pid" ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"},{"pane_id":"w9:p9","terminal_id":"cond-birth","cwd":"/tmp"}]}}\n' "$PANE" "$BIRTH" ;;
    "pane read") cat "$SCREEN" ;;
    "pane send-keys") printf '%s\n' "$4" >> "$KEYS" ;;
    "pane send-text") : ;;
    *) return 0 ;;
  esac
}
herdr() { _std_herdr_stub "$@"; }
export -f _std_herdr_stub
export -f herdr
ps() { printf '1\n'; }
export -f ps

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
occ_py="$(command -v python3.11 || command -v python3)"

. "$here/lib/run-registry.sh"
. "$here/tests/fixtures/task-authorization.sh"
. "$here/lib/prompt-parse.sh"
fixture_register_task run1 task1 wB4 c1 "w9:p9" "cond-birth" "$PANE" "$BIRTH" "$here" "$here" "explore:gbp-setup-check" >/dev/null 2>&1 || { echo "fixture setup failed"; exit 1; }
set_task_state run1 task1 running >/dev/null 2>&1

reset_keys()   { : > "$KEYS"; }
keys_pressed() { wc -l < "$KEYS" | tr -d ' '; }

seed_write_menu() {                     # <path> <content> <tool> [highlight=approve|deny]
  local hl="${4:-approve}" approve_row=" Approve" deny_row="Deny"
  if [ "$hl" = deny ]; then
    deny_row="$(printf '\033[48;2;42;47;65m Deny\033[0m')"
  else
    approve_row="$(printf '\033[48;2;42;47;65m Approve\033[0m')"
  fi
  printf 'Allow tool: %s\nPath: %s\nContent: %s\n\n%s\n%s\n\nup/down navigate  enter select  esc cancel\n' \
    "$3" "$1" "$2" "$approve_row" "$deny_row" > "$SCREEN"
  local pid owner run task
  pid="$(prompt_id "$PANE" 2>/dev/null)"
  owner="$(task_for_pane "$PANE" 2>/dev/null)"
  run="$(printf '%s' "$owner" | jq -r '.run_id // empty')"
  task="$(printf '%s' "$owner" | jq -r '.task_id // empty')"
  append_event "$run" "$task" input_required \
    "$(jq -nc --arg msg "omp needs permission" --arg pid "$pid" --arg tool "$3" \
       '{message:$msg, prompt_id:$pid, command:"", tool:$tool}')" >/dev/null 2>&1
  # The complete-payload occurrence record (#277), same two-step write order
  # production uses (onApprovalRequested's `seen`, then omp-notify.sh's
  # `screen` probe) — needed for herdr-select.sh's proposal/pending-bound
  # lookups, a SEPARATE registry stream from the input_required event above.
  local call="occcall-$3-$RANDOM"
  "$occ_py" "$here/lib/prompt-occurrence.py" seen \
    --db "$(registry_db)" --run "$run" --task "$task" --pane "$PANE" \
    --birth "$BIRTH" --session "native-sess-1" --call-id "$call" \
    --tool "$3" --source test --input-json "$(jq -nc --arg p "$1" --arg c "$2" '{path:$p, content:$c}')" >/dev/null
  "$occ_py" "$here/lib/prompt-occurrence.py" screen \
    --db "$(registry_db)" --run "$run" --task "$task" --pane "$PANE" \
    --birth "$BIRTH" --session "native-sess-1" --call-id "$call" \
    --display pending_parseable --prompt-id "$pid" >/dev/null
}

sel() { ( HERDR_FIXTURE_CALLER_PANE="${HERDR_PANE_ID:-}" bash "$here/herdr-select.sh" "$PANE" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" ); }

# ---- GBP: 7098-byte write panel, tmp/out/*.md inside a worktree -----------
printf '== GBP repro: 7098 B write panel, Approve (peer authority) ==\n'
gbp_path="tmp/out/gbp-notes.md"
pad_len=$((7098 - ${#gbp_path} - 40))
gbp_content="$(printf 'g%.0s' $(seq 1 "$pad_len"))"
seed_write_menu "$gbp_path" "$gbp_content" write
gbp_pid="$(prompt_id "$PANE" 2>/dev/null)"
sel 1 --authority peer; rc=$?
echo "    rc=$rc keys=$(keys_pressed) stderr: $(cat "$WORK/err.txt" | tail -3)"
[ "$rc" -eq 8 ] && [ "$(keys_pressed)" = 0 ] \
  && ok "Approve refused, no key pressed (expected: write/edit is human-only per #277 regardless of size)" \
  || bad "unexpected: rc=$rc keys=$(keys_pressed)"

# ---- gap2: deferred write occurrence reported against the wrong on-screen
# tool ('write' recorded, cross-check passed 'bash'). herdr-select.sh:889-891
# calls prompt-occurrence.py's `proposal` subcommand (not `pending-bound`,
# which is a DIFFERENT, exact-binding-only lookup used later at :904-906)
# with --tool set to the hook-recorded tool for the CURRENT screen prompt.
# Reproduce that exact call shape with a mismatched --tool, BEFORE any
# later re-seed adds a second occurrence for the same screen prompt (which
# would itself refuse as ambiguous, a different and uninteresting reason).
printf '== gap2 repro: proposal tool cross-check, registered=write, cross-check=bash ==\n'
gap2_json="$("$occ_py" "$here/lib/prompt-occurrence.py" proposal --db "$(registry_db)" \
  --run run1 --task task1 --pane "wB4:p4" --birth "term-gbp-1" \
  --prompt-id "$gbp_pid" --worktree "$here" --tool bash 2>&1)"
echo "    $gap2_json"
case "$gap2_json" in
  *'is not the write/edit tool on screen'*)
    ok "reproduced the exact gap2 message against the real proposal_check()" ;;
  *)
    bad "did not reproduce the exact gap2 message: $gap2_json" ;;
esac

printf '== GBP repro: SAME 7098 B write panel, Deny (peer authority) ==\n'
seed_write_menu "$gbp_path" "$gbp_content" write deny
reset_keys
sel 2 --authority peer; rc=$?
echo "    rc=$rc keys=$(keys_pressed) stderr: $(cat "$WORK/err.txt" | tail -3)"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" -gt 0 ]; then
  ok "Deny succeeded (key(s) pressed), rc=0"
else
  bad "DENY REFUSED: rc=$rc keys=$(keys_pressed) -- this is the symptom under investigation"
fi

printf '== GBP repro: SAME 7098 B write panel, Deny (human authority) ==\n'
seed_write_menu "$gbp_path" "$gbp_content" write deny
reset_keys
sel 2 --authority human; rc=$?
echo "    rc=$rc keys=$(keys_pressed) stderr: $(cat "$WORK/err.txt" | tail -3)"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" -gt 0 ]; then
  ok "Deny (human) succeeded"
else
  bad "DENY (human) REFUSED: rc=$rc keys=$(keys_pressed)"
fi

# ---- Intel: 7706-byte write panel, different pane/worktree ----------------
PANE="wB2:p7"; BIRTH="term-intel-1"
fixture_register_task run2 task2 wB2 c2 "w9:p9" "cond-birth" "$PANE" "$BIRTH" "$here" "$here" "explore:intel-office-recon" >/dev/null 2>&1 || { echo "intel fixture setup failed"; exit 1; }
set_task_state run2 task2 running >/dev/null 2>&1

printf '== Intel repro: 7706 B write panel, Deny (peer authority) ==\n'
intel_path="tmp/out/intel-notes.md"
pad_len=$((7706 - ${#intel_path} - 40))
intel_content="$(printf 'i%.0s' $(seq 1 "$pad_len"))"
seed_write_menu "$intel_path" "$intel_content" write deny
reset_keys
sel 2 --authority peer; rc=$?
echo "    rc=$rc keys=$(keys_pressed) stderr: $(cat "$WORK/err.txt" | tail -3)"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" -gt 0 ]; then
  ok "Deny succeeded"
else
  bad "DENY REFUSED: rc=$rc keys=$(keys_pressed)"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
