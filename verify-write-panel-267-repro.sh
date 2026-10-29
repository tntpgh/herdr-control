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
#     authority on both the 7098 B and 7706 B panels WHEN the Approve/Deny
#     footer is fully captured — once the fixture starts with Deny already
#     highlighted (the same convention verify-select-policy.sh uses for
#     every Deny case; its stubbed pane never moves its own highlight on a
#     keypress — set_menu_deny/set_rows_deny).
#   - Deny-not-pressable IS reproduced (herdr-control#267, live GBP wB4:p4
#     ~03:45Z) once a "Steering · N" queued-message block sits above a
#     write panel tall enough that the captured/visible window ends BEFORE
#     the Approve/Deny footer: prompt_menu_options's _menu_gate (needs
#     "navigate"/"select" from the footer) fails, so _current_offer falls
#     through to the numbered-prompt parser, which DOES match the
#     Steering block's own "N. Conductor: ..." rows. "option 2" then
#     resolves to the steering row's text, not "Deny" — herdr-select.sh:477
#     never sets `declining=1`, so the conductor/peer non-human-authority
#     gates (:1015, :1063) apply classify_command's #267 ceiling verdict as
#     if Deny were an Approve attempt. One root cause explains both halves
#     of the live report (the byte ceiling AND the steering mis-resolution).
#   - gap2 ("tool 'write' is not the write/edit tool on screen ('bash')")
#     IS reproduced exactly, mechanically, two ways: (1) a direct --tool
#     cross-check mismatch against `proposal_check`
#     (lib/prompt-occurrence.py, called by herdr-select.sh:889-891 as the
#     `proposal` subcommand — not `pending-bound`, a different, exact-
#     binding-only lookup used later at :904-906); (2) end-to-end (live
#     incident, dashboard w9T:p4Q ~03:48Z) via the REAL
#     task_input_required_tool lookup (lib/run-registry.sh:1968) against a
#     stale bash Approve/Deny box still on screen: a deferred write
#     occurrence (`seen` at dispatch, `screen` recording whatever the probe
#     actually saw — the stale bash panel, since the write never painted
#     its own) gets its cross-check tool resolved from the MOST RECENT
#     on-screen panel, not from itself — any tool call that paints no panel
#     of its own inherits whatever panel was already there.
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

# ---- gap2 v2 (live incident, w9T:p4Q ~03:48Z): a deferred write occurrence
# with NO panel painted (tool=write, e.g. proc://preview-http/kill), while
# the screen still shows the PREVIOUS bash command's complete Approve/Deny
# box. Unlike the repro above (which hand-passed --tool bash), this drives
# --tool through the REAL herdr-select.sh lookup
# (task_input_required_tool, lib/run-registry.sh:1968) against the stale
# bash panel's own prompt_id -- proving the mismatch arises from whichever
# tool call most recently painted a panel, not from anything specific to
# the write occurrence itself.
printf '== gap2 repro v2: deferred write occurrence, stale bash box still on screen ==\n'
printf 'Allow tool: bash\nCommand: pkill -f preview-http\n\n Approve\nDeny\n\nup/down navigate  enter select  esc cancel\n' > "$SCREEN"
stale_pid="$(prompt_id "$PANE" 2>/dev/null)"
append_event run1 task1 input_required \
  "$(jq -nc --arg msg "omp needs permission" --arg pid "$stale_pid" --arg tool "bash" \
     '{message:$msg, prompt_id:$pid, command:"pkill -f preview-http", tool:$tool}')" >/dev/null 2>&1
# The deferred write: 'seen' at dispatch, 'screen' records whatever the
# probe actually saw -- the stale bash box, since the write never painted
# its own panel. Same two-step write order production uses.
write_call="occcall-write-$RANDOM"
"$occ_py" "$here/lib/prompt-occurrence.py" seen \
  --db "$(registry_db)" --run run1 --task task1 --pane "$PANE" \
  --birth "$BIRTH" --session "native-sess-1" --call-id "$write_call" \
  --tool write --source test --input-json "$(jq -nc '{path:"proc://preview-http/kill", content:""}')" >/dev/null
"$occ_py" "$here/lib/prompt-occurrence.py" screen \
  --db "$(registry_db)" --run run1 --task task1 --pane "$PANE" \
  --birth "$BIRTH" --session "native-sess-1" --call-id "$write_call" \
  --display pending_parseable --prompt-id "$stale_pid" >/dev/null

current_pid="$(prompt_id "$PANE" 2>/dev/null)"
registry_tool="$(task_input_required_tool run1 task1 "$current_pid" 2>/dev/null)"
registry_tool_lc="$(printf '%s' "$registry_tool" | tr '[:upper:]' '[:lower:]')"
echo "    current screen is still the stale bash panel: $([ "$current_pid" = "$stale_pid" ] && echo yes || echo no)"
echo "    task_input_required_tool resolved: '$registry_tool_lc' (from the stale box, not the deferred write)"
gap2_v2_json="$("$occ_py" "$here/lib/prompt-occurrence.py" proposal --db "$(registry_db)" \
  --run run1 --task task1 --pane "$PANE" --birth "$BIRTH" \
  --prompt-id "$current_pid" --worktree "$here" --tool "$registry_tool_lc" 2>&1)"
echo "    $gap2_v2_json"
case "$gap2_v2_json" in
  *'is not the write/edit tool on screen'*)
    ok "gap2 v2: reproduced end-to-end via task_input_required_tool against a real stale bash box" ;;
  *)
    bad "gap2 v2 did not reproduce: $gap2_v2_json" ;;
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

# ---- Deny-not-pressable (live incident, GBP wB4:p4 ~03:45Z): herdr-select
# wB4:p4 2 --expect-prompt-id ... was refused for TWO reasons that turn out
# to be one root cause. omp paints a "Steering · N" queued-message block
# ABOVE the write panel; when the panel's wrapped content is tall enough
# that the visible/captured window (lib/prompt-parse.sh _PANE_WINDOW_LINES,
# bounded in practice by the real pane's height) ends BEFORE the
# Approve/Deny footer, prompt_menu_options's _menu_gate (needs "navigate"
# and "select" from the footer) fails, so _current_offer falls through to
# the numbered-prompt parser -- which DOES match the Steering block's own
# "N. Conductor: ..." rows. "option 2" then resolves to the SECOND
# steering row's text, not "Deny": herdr-select.sh:477's case statement
# does not recognize that text, so `declining` stays 0. Downstream,
# classify_command denies on the >4096-byte ceiling (#267's original bug)
# and, because declining=0, the conductor/peer non-human-authority gates
# (herdr-select.sh:1015, :1063) apply that refusal as if Deny were an
# Approve attempt -- Deny becomes genuinely unpressable.
printf '== Deny-not-pressable repro: Steering block above a truncated-viewport write panel ==\n'
PANE="wB4:p4"; BIRTH="term-gbp-1"
seed_write_menu_steering_truncated() {  # <path> <content_chars>
  local content
  content="$(printf 'g%.0s' $(seq 1 "$2"))"
  {
    printf ' Steering · 2\n'
    printf '   1. Conductor: your oversized write was refused (herdr-control#267) -- split or shorten it\n'
    printf '   2. Conductor: please retry once under the 4096-byte panel limit\n'
    printf '\n'
    # Real omp panel shape -- right-bordered, padded box, same convention
    # as verify-select-policy.sh's boxed_panel (:1304-1314) -- a write
    # panel shows only the first ~2000 UTF-16 units of content
    # (docs/design/complete-approval-payload.md), so the >4KB total the
    # live incident reported comes from this structural overhead (border,
    # padding, one row per wrapped line), not from raw content bytes.
    printf '╭─ Allow tool: write %s╮\n' "$(printf '─%.0s' $(seq 1 180))"
    printf '│ %-198s │\n' "Path: $1"
    printf '%s' "$content" | fold -w 198 | while IFS= read -r r; do printf '│ %-198s │\n' "$r"; done
    # Truncated here: the viewport is tall enough to show the steering
    # block and the start of the panel, but not tall enough to reach
    # Approve/Deny/the footer -- the panel's own content pushed them out,
    # same shape as the 2026-09-13 "header off-screen" precedent
    # (lib/prompt-parse.sh:741-742) one layer further: here the FOOTER is
    # off-screen instead, which the footer-anchored fallback cannot help
    # with (it IS the footer).
  } > "$SCREEN"
  local pid owner run task
  pid="$(prompt_id "$PANE" 2>/dev/null)"
  owner="$(task_for_pane "$PANE" 2>/dev/null)"
  run="$(printf '%s' "$owner" | jq -r '.run_id // empty')"
  task="$(printf '%s' "$owner" | jq -r '.task_id // empty')"
  append_event "$run" "$task" input_required \
    "$(jq -nc --arg msg "omp needs permission" --arg pid "$pid" --arg tool write \
       '{message:$msg, prompt_id:$pid, command:"", tool:$tool}')" >/dev/null 2>&1
  local call="occcall-write-steer-$RANDOM"
  "$occ_py" "$here/lib/prompt-occurrence.py" seen \
    --db "$(registry_db)" --run "$run" --task "$task" --pane "$PANE" \
    --birth "$BIRTH" --session "native-sess-1" --call-id "$call" \
    --tool write --source test --input-json "$(jq -nc --arg p "$1" --arg c "$content" '{path:$p, content:$c}')" >/dev/null
  "$occ_py" "$here/lib/prompt-occurrence.py" screen \
    --db "$(registry_db)" --run "$run" --task "$task" --pane "$PANE" \
    --birth "$BIRTH" --session "native-sess-1" --call-id "$call" \
    --display pending_parseable --prompt-id "$pid" >/dev/null
  printf '%s' "$pid"
}
steer_pid="$(seed_write_menu_steering_truncated "tmp/out/gbp-notes.md" 4000)"
echo "    scraped bytes: $(wc -c < "$SCREEN" | tr -d ' '), rows: $(wc -l < "$SCREEN" | tr -d ' ')"
menu_opts="$(prompt_menu_options "$PANE" 2>/dev/null)"
numbered_opts="$(prompt_options "$PANE" 2>/dev/null)"
echo "    prompt_menu_options: [${menu_opts:-<empty>}]"
echo "    prompt_options (numbered fallback): [${numbered_opts:-<empty>}]"
reset_keys
sel 2 --authority peer --expect-prompt-id "$steer_pid"; rc=$?
err_tail="$(tail -3 "$WORK/err.txt")"
echo "    rc=$rc keys=$(keys_pressed) stderr: $err_tail"
if [ -z "$menu_opts" ] && [ -n "$numbered_opts" ] \
  && [ "$(printf '%s' "$numbered_opts" | awk -F'\t' '$1==2{print $2}')" != Deny ] \
  && [ "$rc" -ne 0 ] && [ "$(keys_pressed)" = 0 ]; then
  ok "REPRODUCED: menu detection fails, numbered fallback matches the steering row, Deny refused (rc=$rc, 0 keys)"
else
  bad "did not reproduce the full Deny-not-pressable chain: menu_opts=[$menu_opts] numbered_opts=[$numbered_opts] rc=$rc keys=$(keys_pressed)"
fi

# ---------------------------------------------------------------------------
# Operational fix (proposal, herdr-control#267 follow-up):
# docs/design/stuck-save-operational-fix.md. Both pieces below are
# zero-caller additions -- herdr-select.sh's live _current_offer and the
# #277/gap2 blocks (:834-931) are untouched, so nothing here changes any
# live pane's resolution.
# ---------------------------------------------------------------------------

# ---- (a) Deny stays pressable on a tall write panel whose FOOTER (not its
# Approve/Deny rows) is what got clipped -- lib/prompt-parse.sh's new
# _prompt_footer_clipped_options(), a narrower detector alongside the
# hardened pass-1/pass-2 parser, not a change to it.
printf '\n== footer-clipped menu detector: positive (header + Approve/Deny, no footer) ==\n'
printf '╭─ Allow tool: write ─────────╮\n│ Path: tmp/out/x.md          │\n│ some wrapped content row    │\n\n Approve\nDeny\n' > "$SCREEN"
clipped_opts="$(_prompt_footer_clipped_options options < "$SCREEN")"
if [ "$clipped_opts" = "$(printf '1\tApprove\n2\tDeny\n')" ]; then
  ok "_prompt_footer_clipped_options resolves Approve/Deny when the footer is clipped"
else
  bad "_prompt_footer_clipped_options did not resolve: [$clipped_opts]"
fi

printf '\n== footer-clipped menu detector: mutant (same fixture, OLD code still fails) ==\n'
old_menu_opts="$(_menu_gate "$(cat "$SCREEN")" && prompt_menu_options "$PANE" 2>/dev/null)"
if [ -z "$old_menu_opts" ]; then
  ok "mutant confirmed: the existing hardened parser (unmodified) still returns nothing for this fixture -- the new detector does genuine new work"
else
  bad "mutant did not confirm the gap: old parser unexpectedly resolved [$old_menu_opts]"
fi

printf '\n== footer-clipped menu detector: negative, no allow-widening (no header at all) ==\n'
printf 'just some ordinary pane output\nthat happens to end in\n Approve\nDeny\n' > "$SCREEN"
v="$(_prompt_footer_clipped_options options < "$SCREEN")"
[ -z "$v" ] && ok "no 'Allow tool:' header present -> refuses, does not widen allow" \
  || bad "FALSE POSITIVE on header-less text: [$v]"

printf '\n== footer-clipped menu detector: negative, refuses a poisoned (two-header) window ==\n'
printf '╭─ Allow tool: write ─╮\n│ some row            │\nAllow tool: bash\n\n Approve\nDeny\n' > "$SCREEN"
v="$(_prompt_footer_clipped_options options < "$SCREEN")"
[ -z "$v" ] && ok "two 'Allow tool:' headers (injection shape) -> refuses" \
  || bad "FALSE POSITIVE on a poisoned/double-header window: [$v]"

printf '\n== footer-clipped menu detector: negative, still refuses when Approve/Deny are ALSO clipped ==\n'
printf 'Allow tool: write\nPath: x\nSteering · 1\n  1. Conductor: hi\n' > "$SCREEN"
v="$(_prompt_footer_clipped_options options < "$SCREEN")"
[ -z "$v" ] && ok "header present but no Approve/Deny rows visible -> correctly refuses (nothing to resolve)" \
  || bad "FALSE POSITIVE with no Approve/Deny rows at all: [$v]"

printf '\n== footer-clipped menu detector: negative, defers when the real footer IS present ==\n'
printf 'Allow tool: write\nPath: x\n\n Approve\nDeny\n\nup/down navigate  enter select  esc cancel\n' > "$SCREEN"
v="$(_prompt_footer_clipped_options options < "$SCREEN")"
[ -z "$v" ] && ok "real footer present -> defers to the hardened parser, never doubles as a second source of truth" \
  || bad "fired even though the real footer was present: [$v]"

printf '\n== footer-clipped menu detector: selected mode, highlight ambiguity refuses (HIGH, REVIEW-187fc9f) ==\n'
hl_approve="$(printf '\033[48;2;42;47;65m Approve\033[0m')"
hl_deny="$(printf '\033[48;2;42;47;65m Deny\033[0m')"
win_both="$(printf 'Allow tool: write\nPath: x\nContent: g\n\n%s\n%s\n' "$hl_approve" "$hl_deny")"
v="$(printf '%s' "$win_both" | _prompt_footer_clipped_options selected)"; rc=$?
[ "$rc" -ne 0 ] && [ -z "$v" ] \
  && ok "BOTH Approve and Deny highlighted -> refuses, never guesses (rc=$rc)" \
  || bad "both-highlighted window did not refuse: rc=$rc v=[$v]"
win_neither="$(printf 'Allow tool: write\nPath: x\nContent: g\n\n Approve\nDeny\n')"
v="$(printf '%s' "$win_neither" | _prompt_footer_clipped_options selected)"; rc=$?
[ "$rc" -ne 0 ] && [ -z "$v" ] \
  && ok "NEITHER Approve nor Deny highlighted -> refuses, never guesses (rc=$rc)" \
  || bad "neither-highlighted window did not refuse: rc=$rc v=[$v]"
# Sanity control: each alone still resolves (the guard is "both or
# neither", not "never" -- proves the two refusals above are the
# ambiguity guard firing, not the function being broken outright).
win_deny_only="$(printf 'Allow tool: write\nPath: x\nContent: g\n\n Approve\n%s\n' "$hl_deny")"
v="$(printf '%s' "$win_deny_only" | _prompt_footer_clipped_options selected)"
[ "$v" = 2 ] && ok "Deny alone highlighted -> resolves to 2 (sanity control for the two refusals above)" \
  || bad "Deny-alone-highlighted did not resolve to 2: [$v]"

printf '\n== footer-clipped menu detector: negative, G1 -- menu_gate=true still defers (MEDIUM, REVIEW-187fc9f) ==\n'
# _menu_gate only requires the SUBSTRINGS "navigate" and "select" to
# appear anywhere in the window (lib/prompt-parse.sh:596-599) -- here they
# appear in ordinary prose, nowhere near a real footer, while Approve/Deny
# are (coincidentally) still the last two lines. Correct code must defer
# the instant _menu_gate is true, regardless of what follows: if the
# early `if _menu_gate "$win"; then return 1; fi` is ever disabled, this
# fixture resolves instead of deferring (G1 mutant, REVIEW-187fc9f).
win_g1="$(printf 'Allow tool: write\nPath: x\nsome unrelated text: please navigate carefully and select your words\n\n Approve\nDeny\n')"
v="$(printf '%s' "$win_g1" | _prompt_footer_clipped_options options)"
[ -z "$v" ] && ok "_menu_gate true anywhere in the window -> defers even though Approve/Deny are still the trailing rows" \
  || bad "G1 MUTANT-SHAPE: fired even though _menu_gate(win) is true: [$v]"

printf '\n== footer-clipped menu detector: negative, G4 -- reversed Deny/Approve order refuses (MEDIUM, REVIEW-187fc9f) ==\n'
# Real omp always renders Approve above Deny. The last-two-rows check
# must require that exact order, not just "both labels present" -- if it
# is ever loosened to accept either order (G4 mutant, REVIEW-187fc9f),
# this reversed fixture would resolve instead of refusing.
win_g4="$(printf 'Allow tool: write\nPath: x\nContent: g\n\nDeny\n Approve\n')"
v="$(printf '%s' "$win_g4" | _prompt_footer_clipped_options options)"
[ -z "$v" ] && ok "Deny-before-Approve (reversed order) -> refuses, order is significant" \
  || bad "G4 MUTANT-SHAPE: reversed order resolved instead of refusing: [$v]"

# ---- end-to-end, through the REAL (now wired) herdr-select.sh: the raw
# detector tests above prove the function's own shape rules; these prove
# the wiring in _current_offer (herdr-select.sh:420-454) and the
# navigation loop's highlight fallback (prompt_footer_clipped_selected,
# herdr-select.sh:1352-1357/1371-1377) actually resolve a keypress.
seed_write_menu_footer_clipped() {      # <path> <content> <tool> [highlight=approve|deny]
  local hl="${4:-deny}" approve_row=" Approve" deny_row="Deny"
  if [ "$hl" = deny ]; then
    deny_row="$(printf '\033[48;2;42;47;65m Deny\033[0m')"
  else
    approve_row="$(printf '\033[48;2;42;47;65m Approve\033[0m')"
  fi
  # SAME shape as seed_write_menu, minus the trailing navigation-hint
  # line -- the one byte difference this detector exists for.
  printf 'Allow tool: %s\nPath: %s\nContent: %s\n\n%s\n%s\n' \
    "$3" "$1" "$2" "$approve_row" "$deny_row" > "$SCREEN"
  local pid owner run task
  pid="$(prompt_id "$PANE" 2>/dev/null)"
  owner="$(task_for_pane "$PANE" 2>/dev/null)"
  run="$(printf '%s' "$owner" | jq -r '.run_id // empty')"
  task="$(printf '%s' "$owner" | jq -r '.task_id // empty')"
  append_event "$run" "$task" input_required \
    "$(jq -nc --arg msg "omp needs permission" --arg pid "$pid" --arg tool "$3" \
       '{message:$msg, prompt_id:$pid, command:"", tool:$tool}')" >/dev/null 2>&1
  local call="occcall-clip-$3-$RANDOM"
  "$occ_py" "$here/lib/prompt-occurrence.py" seen \
    --db "$(registry_db)" --run "$run" --task "$task" --pane "$PANE" \
    --birth "$BIRTH" --session "native-sess-1" --call-id "$call" \
    --tool "$3" --source test --input-json "$(jq -nc --arg p "$1" --arg c "$2" '{path:$p, content:$c}')" >/dev/null
  "$occ_py" "$here/lib/prompt-occurrence.py" screen \
    --db "$(registry_db)" --run "$run" --task "$task" --pane "$PANE" \
    --birth "$BIRTH" --session "native-sess-1" --call-id "$call" \
    --display pending_parseable --prompt-id "$pid" >/dev/null
}

printf '\n== footer-clipped end-to-end: generic write panel, Deny (peer authority) ==\n'
PANE="wB4:p4"; BIRTH="term-gbp-1"
seed_write_menu_footer_clipped "tmp/out/x.md" "$(printf 'g%.0s' $(seq 1 500))" write deny
reset_keys
sel 2 --authority peer; rc=$?
echo "    rc=$rc keys=$(keys_pressed) stderr: $(cat "$WORK/err.txt" | tail -3)"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" -gt 0 ]; then
  ok "Deny resolves end-to-end when only the footer is clipped (wiring confirmed)"
else
  bad "DENY REFUSED end-to-end: rc=$rc keys=$(keys_pressed)"
fi

printf '\n== footer-clipped end-to-end: GBP-sized (7098 B) regression, Deny ==\n'
seed_write_menu_footer_clipped "$gbp_path" "$gbp_content" write deny
reset_keys
sel 2 --authority peer; rc=$?
echo "    rc=$rc keys=$(keys_pressed) stderr: $(cat "$WORK/err.txt" | tail -3)"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" -gt 0 ]; then
  ok "GBP-sized (7098 B) footer-clipped panel: Deny resolves for the right reason (prompt_footer_clipped_options/_selected)"
else
  bad "GBP-sized regression DENY REFUSED: rc=$rc keys=$(keys_pressed)"
fi

printf '\n== footer-clipped end-to-end: Intel-sized (7706 B) regression, Deny ==\n'
PANE="wB2:p7"; BIRTH="term-intel-1"
# run2/task2 already registered by the earlier "Intel repro" section above --
# re-registering the same run/task id a second time fails (duplicate key).
seed_write_menu_footer_clipped "$intel_path" "$intel_content" write deny
reset_keys
sel 2 --authority peer; rc=$?
echo "    rc=$rc keys=$(keys_pressed) stderr: $(cat "$WORK/err.txt" | tail -3)"
if [ "$rc" -eq 0 ] && [ "$(keys_pressed)" -gt 0 ]; then
  ok "Intel-sized (7706 B) footer-clipped panel: Deny resolves for the right reason"
else
  bad "Intel-sized regression DENY REFUSED: rc=$rc keys=$(keys_pressed)"
fi

printf '\n== footer-clipped end-to-end: ORIGINAL Steering case STILL fails closed post-wiring ==\n'
echo "    (re-asserted: the unmodified 'Deny-not-pressable repro' test above already ran" \
     "against the REAL, now-wired _current_offer -- its own PASS re-confirms this; this" \
     "line exists only to name the requirement explicitly, not to re-run the fixture.)"
if [ "$fail" = 0 ]; then
  ok "no fail yet in this run -> the Steering-truncated case above still correctly refused post-wiring"
else
  bad "a prior failure means the post-wiring re-confirmation of the Steering case is unverified by this run"
fi

printf '\n== footer-clipped end-to-end: negative, header-only (nothing to resolve) ==\n'
PANE="wB4:p4"; BIRTH="term-gbp-1"
printf 'Allow tool: write\nPath: tmp/out/x.md\n' > "$SCREEN"
reset_keys
sel 2 --authority peer; rc=$?
echo "    rc=$rc keys=$(keys_pressed) stderr: $(cat "$WORK/err.txt" | tail -3)"
[ "$rc" -ne 0 ] && [ "$(keys_pressed)" = 0 ] \
  && ok "header-only panel (no Approve/Deny at all) -> refuses, never guesses" \
  || bad "header-only panel did not refuse: rc=$rc keys=$(keys_pressed)"

printf '\n== footer-clipped end-to-end: negative, choice ambiguous (invalid choice requested) ==\n'
seed_write_menu_footer_clipped "tmp/out/x.md" "$(printf 'g%.0s' $(seq 1 500))" write deny
reset_keys
sel 3 --authority peer; rc=$?
echo "    rc=$rc keys=$(keys_pressed) stderr: $(cat "$WORK/err.txt" | tail -3)"
[ "$rc" -ne 0 ] && [ "$(keys_pressed)" = 0 ] \
  && ok "requesting an option not on offer (3) -> refuses, never guesses a choice" \
  || bad "ambiguous/invalid choice was not refused: rc=$rc keys=$(keys_pressed)"

# ---- (b) Deny on the deferred path (no panel of its own) resolves
# truthfully via the EXISTING authorized/record_authorized primitive,
# which needs no screen state at all (identity-only: run/task/pane/birth/
# session/call-id) and is UNAFFECTED by the stale-panel cross-check gap2
# reproduces above -- confirmed directly against the real
# prompt-occurrence.py, same db/identity shape as the gap2 v2 fixture.
printf '\n== deferred-occurrence Deny: authorized --choice deny resolves truthfully, no screen dependency ==\n'
DPANE="wB4:p4"; DBIRTH="term-gbp-1"
deferred_call="occcall-deferred-deny-$RANDOM"
"$occ_py" "$here/lib/prompt-occurrence.py" seen \
  --db "$(registry_db)" --run run1 --task task1 --pane "$DPANE" \
  --birth "$DBIRTH" --session "native-sess-1" --call-id "$deferred_call" \
  --tool write --source test --input-json "$(jq -nc '{path:"proc://preview-http/kill", content:""}')" >/dev/null
"$occ_py" "$here/lib/prompt-occurrence.py" screen \
  --db "$(registry_db)" --run run1 --task task1 --pane "$DPANE" \
  --birth "$DBIRTH" --session "native-sess-1" --call-id "$deferred_call" \
  --display pending_parseable --prompt-id "some-unrelated-stale-prompt-id" >/dev/null
# Mutant / regression proof: the normal proposal cross-check genuinely
# cannot resolve this occurrence (same shape as gap2 v2 above) -- proving
# a keypress-navigation path has nothing to act on for it.
deferred_proposal_json="$("$occ_py" "$here/lib/prompt-occurrence.py" proposal --db "$(registry_db)" \
  --run run1 --task task1 --pane "$DPANE" --birth "$DBIRTH" \
  --prompt-id "some-unrelated-stale-prompt-id" --worktree "$here" --tool bash 2>&1)"
case "$deferred_proposal_json" in
  *'"ok": false'*|*'"ok":false'*)
    ok "mutant confirmed: the stale-screen cross-check cannot resolve the deferred occurrence (reason: $(printf '%s' "$deferred_proposal_json" | jq -r .reason 2>/dev/null))" ;;
  *)
    bad "expected the cross-check to fail for the deferred occurrence: $deferred_proposal_json" ;;
esac
# The fix: authorized --choice deny needs none of that -- identity alone.
authorized_json="$("$occ_py" "$here/lib/prompt-occurrence.py" authorized --db "$(registry_db)" \
  --run run1 --task task1 --pane "$DPANE" --birth "$DBIRTH" --session "native-sess-1" \
  --call-id "$deferred_call" --decided-by "human:test" --choice deny 2>&1)"
echo "    $authorized_json"
case "$authorized_json" in
  *'"written": "authorized"'*|*'"written":"authorized"'*)
    ok "authorized --choice deny resolved the deferred occurrence truthfully, independent of screen state" ;;
  *)
    bad "authorized --choice deny did not resolve: $authorized_json" ;;
esac

echo
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
