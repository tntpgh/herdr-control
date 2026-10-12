#!/usr/bin/env bash
# verify-select-occurrence.sh — proves herdr-select.sh's occurrence-corroboration
# gate (docs/plans/dot-herdr-recovery-slices.md §2 item 3): an APPROVING press is
# refused when the hook-recorded occurrence for THIS EXACT on-screen prompt
# (screen_prompt_id == current_prompt_id) has identity_verified=false or its
# last recorded display was not pending_parseable, and is UNAFFECTED (legacy
# behavior) when no matching occurrence was ever recorded at all.
#
# Runs the real herdr-select.sh against a stubbed herdr, same stub shape as
# verify-select-policy.sh (herdr is an exported bash FUNCTION, since
# herdr-select.sh re-exports PATH with system directories first).
#
#   bash verify-select-occurrence.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_BRIDGE_STATE="$WORK/bridge"
export XDG_RUNTIME_DIR="$WORK/runtime"; mkdir -p "$XDG_RUNTIME_DIR"
export SCREEN="$WORK/screen.txt"
export KEYS="$WORK/keys.log"
: > "$KEYS"

PANE="w1:p1"
BIRTH="term-abc-123"
export PANE BIRTH

_std_herdr_stub() {
  case "$1 $2" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":999999,"name":"claude","cmdline":"claude --model sonnet"}]}}}\n' ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"},{"pane_id":"w9:p9","terminal_id":"cond-birth","cwd":"/tmp"}]}}\n' "$PANE" "$BIRTH" ;;
    "pane read")
      cat "$SCREEN" ;;
    "pane send-keys")
      printf '%s\n' "$4" >> "$KEYS" ;;
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

set_menu() {                            # <command-text>
  printf 'Allow tool: bash\nCommand: %s\n\n\033[48;2;42;47;65m Approve\033[0m\nDeny\n\nup/down navigate  enter select  esc cancel\n' "$1" > "$SCREEN"
}
set_menu_deny() {                       # <command-text>
  printf 'Allow tool: bash\nCommand: %s\n\nApprove\n\033[48;2;42;47;65m Deny\033[0m\n\nup/down navigate  enter select  esc cancel\n' "$1" > "$SCREEN"
}
seed_input_required() {                 # <command-text>
  append_event run1 task1 input_required \
    "$(jq -nc --arg msg "omp needs permission" --arg pid "$(prompt_id "$PANE")" --arg cmd "$1" --arg tool bash \
       '{message:$msg, prompt_id:$pid, command:$cmd, tool:$tool}')" >/dev/null 2>&1
}

reset_keys()   { : > "$KEYS"; }
keys_pressed() { wc -l < "$KEYS" | tr -d ' '; }

. "$here/lib/run-registry.sh"
. "$here/lib/prompt-parse.sh"
. "$here/tests/fixtures/task-authorization.sh"
fixture_register_task run1 task1 w1 c1 "w9:p9" "cond-birth" "$PANE" "$BIRTH" /repo /wt "impl:test" >/dev/null 2>&1 || exit 1

sel() { ( bash "$here/herdr-select.sh" "$PANE" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" ); }

_seed_call_n=0
seed_occ() {    # <display> <identity-verified: true|false>
  local display="$1" verified="$2" pid birth session call
  pid="$(prompt_id "$PANE")"
  _seed_call_n=$((_seed_call_n + 1)); call="seedcall$_seed_call_n"
  if [ "$verified" = true ]; then birth="$BIRTH"; session="native-sess-1"
  else birth=""; session=""; fi
  # `seen` first: fold_task only sets pane_id/pane_birth/native_session (and
  # computes identity_verified) from a prompt_occ_seen event — a bare
  # `screen` event never carries them (lib/prompt-occurrence.py fold_task,
  # the prompt_occ_seen branch). Production records `seen` from
  # onApprovalRequested before omp-notify.sh's `screen` probe
  # (agent-hooks/omp-herdr-control.ts occurrenceIdentityArgs), so this
  # mirrors the real write order rather than inventing a shortcut order
  # that would never happen outside this test.
  python3 "$here/lib/prompt-occurrence.py" seen \
    --db "$(registry_db)" --run run1 --task task1 --pane "$PANE" \
    --birth "$birth" --session "$session" --call-id "$call" \
    --tool bash --source test >/dev/null
  python3 "$here/lib/prompt-occurrence.py" screen \
    --db "$(registry_db)" --run run1 --task task1 --pane "$PANE" \
    --birth "$birth" --session "$session" --call-id "$call" \
    --display "$display" --prompt-id "$pid" >/dev/null
}

printf '== no matching occurrence recorded at all -> legacy behavior unaffected, SAFE command still allowed ==\n'
set_menu "git status"; reset_keys
seed_input_required "git status"
sel 1 --authority peer; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 (no occurrence to corroborate against)" || bad "exit $rc (expected 0); stderr: $(cat "$WORK/err.txt")"
[ "$(keys_pressed)" = "1" ] && ok "key pressed" || bad "keys pressed=$(keys_pressed)"

printf '== round 6 (MEDIUM): resolver unavailable end-to-end -> still HELD (never approved), via registry_init'"'"'s own fail-closed gate ==\n'
# A BLANKET resolver failure also empties own_run/own_task (task_for_pane
# calls registry_init, which itself now refuses when _registry_python
# fails — round 5), so this scenario is caught by #191's EARLIER
# tool-identity gate (herdr-select.sh:589) before ever reaching the
# occurrence block this round touches: a different message, same safe
# outcome. That is why the test immediately below this one, not this one,
# is what actually discriminates round 6's fix — this one only confirms
# the end-to-end outcome stayed HELD after the fix, not regressed to
# approve by some other interaction.
set_menu "git status"; reset_keys
seed_input_required "git status"
EMPTY_PY_DIR="$WORK/no-python-here"; mkdir -p "$EMPTY_PY_DIR"
HERDR_HUB_PYTHON_DIRS="$EMPTY_PY_DIR" sel 1 --authority peer; rc=$?
[ "$rc" -eq 8 ] && ok "exit 8 (still held end-to-end on a blanket resolver failure)" || bad "exit $rc (expected 8); stderr: $(cat "$WORK/err.txt")"
[ "$(keys_pressed)" = "0" ] && ok "NO KEY PRESSED" || bad "keys pressed=$(keys_pressed) on a resolver failure!"

printf '== round 6 (MEDIUM) discriminator: the occurrence block ITSELF holds on a resolver/query failure, not just via a downstream coincidence ==\n'
# own_run/own_task empties under a blanket failure (above), which means a
# black-box run of the full script cannot isolate herdr-select.sh:356-384's
# OWN behavior from #191's unrelated tool-identity gate catching the same
# blanket case first. This checks the actual code shape instead: at
# 42f7ea44 the block was `occ_summary=""; if occ_py=... ; then ...; fi` —
# a resolver failure left occ_summary empty and fell through to approve,
# indistinguishable from "no occurrence recorded". At head it is
# `if ! occ_py=...; then ... exit 8; fi` — an explicit, immediate HOLD
# before occ_summary is ever touched. Fails at 42f7ea44 (grep finds
# nothing), passes at head.
grep -q 'if ! occ_py="\$(_registry_python 2>/dev/null)"; then' "$here/herdr-select.sh" \
  && grep -A2 'if ! occ_py="\$(_registry_python 2>/dev/null)"; then' "$here/herdr-select.sh" | grep -q 'exit 8' \
  && ok "occurrence block exits 8 immediately on a resolver failure, before the empty-occ_summary fallthrough" \
  || bad "occurrence block no longer holds on a resolver failure at its own source location"

printf '== matching occurrence, identity_verified=true, display=pending_parseable -> still allowed ==\n'
set_menu "git status"; reset_keys
seed_input_required "git status"
seed_occ pending_parseable true
sel 1 --authority peer; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 (occurrence corroborates cleanly)" || bad "exit $rc (expected 0); stderr: $(cat "$WORK/err.txt")"
[ "$(keys_pressed)" = "1" ] && ok "key pressed" || bad "keys pressed=$(keys_pressed)"

printf '== matching occurrence, identity_verified=false -> refused, no key pressed ==\n'
set_menu "git status"; reset_keys
seed_input_required "git status"
seed_occ pending_parseable false
sel 1 --authority peer; rc=$?
[ "$rc" -eq 8 ] && ok "exit 8 (identity not verified)" || bad "exit $rc (expected 8); stderr: $(cat "$WORK/err.txt")"
[ "$(keys_pressed)" = "0" ] && ok "NO KEY PRESSED" || bad "keys pressed=$(keys_pressed) on a refusal!"
grep -q 'identity_verified=false' "$WORK/err.txt" && ok "refusal names identity_verified=false" || bad "stderr: $(cat "$WORK/err.txt")"

printf '== matching occurrence, identity_verified=true but display=pending_unreadable -> refused, no key pressed ==\n'
set_menu "git status"; reset_keys
seed_input_required "git status"
seed_occ pending_unreadable true
sel 1 --authority peer; rc=$?
[ "$rc" -eq 8 ] && ok "exit 8 (display not cleanly parseable)" || bad "exit $rc (expected 8); stderr: $(cat "$WORK/err.txt")"
[ "$(keys_pressed)" = "0" ] && ok "NO KEY PRESSED" || bad "keys pressed=$(keys_pressed) on a refusal!"
grep -q 'display=pending_unreadable' "$WORK/err.txt" && ok "refusal names display=pending_unreadable" || bad "stderr: $(cat "$WORK/err.txt")"

printf '== a Decline is exempt from the occurrence gate even with a bad occurrence recorded ==\n'
set_menu_deny "git status"; reset_keys
seed_input_required "git status"
seed_occ pending_unreadable false
sel 2 --authority peer; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 (decline bypasses the corroboration gate)" || bad "exit $rc (expected 0); stderr: $(cat "$WORK/err.txt")"
[ "$(keys_pressed)" = "1" ] && ok "key pressed" || bad "keys pressed=$(keys_pressed)"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
