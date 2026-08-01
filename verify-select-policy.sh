#!/usr/bin/env bash
# verify-select-policy.sh — end-to-end proof that herdr-select.sh gates PEER
# automation on command policy and records the three-phase approval lifecycle.
#
# Runs the REAL herdr-select.sh against a stubbed herdr, so what is verified is
# the shipping script's behaviour rather than a reimplementation of it. The
# single property that matters most is negative: on a refusal, NO KEY IS PRESSED.
#
# herdr is stubbed as an exported bash FUNCTION rather than a binary on PATH,
# because herdr-select.sh re-exports PATH with the system directories first — a
# stub directory would silently lose to the real herdr and this would quietly be
# exercising the live machine.
#
#   bash verify-select-policy.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_BRIDGE_STATE="$WORK/bridge"
export SCREEN="$WORK/screen.txt"
export KEYS="$WORK/keys.log"
: > "$KEYS"

PANE="w1:p1"
BIRTH="term-abc-123"
export PANE BIRTH

# ---- the stub -------------------------------------------------------------
# Implements exactly the four herdr calls this path makes:
#   pane process-info --pane <id>   lib/pane-guard.sh: pane_is_agent
#   pane list                       pane_birth_now / require_pane_birth_match
#   pane read <id> ...              lib/prompt-parse.sh, both prompt shapes
#   pane send-keys <id> <key>       the thing that must NOT happen on a refusal
herdr() {
  case "$1 $2" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"claude","cmdline":"claude --model sonnet"}]}}}\n' ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"}]}}\n' "$PANE" "$BIRTH" ;;
    "pane read")
      cat "$SCREEN" ;;
    "pane send-keys")
      # argv is: pane send-keys <pane> <key> — the KEY is $4, not $3.
      printf '%s\n' "$4" >> "$KEYS" ;;
    *) return 0 ;;
  esac
}
export -f herdr

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

set_screen() {                          # <command-text>
  cat > "$SCREEN" <<EOF
 Bash command
   $1
   (a description line)

 Do you want to proceed?
 ❯ 1. Yes
   2. No
EOF
}

reset_keys()   { : > "$KEYS"; }
keys_pressed() { wc -l < "$KEYS" | tr -d ' '; }

. "$here/lib/run-registry.sh"
register_task run1 task1 w1 c1 "w9:p9" "cond-birth" "$PANE" "$BIRTH" /repo /wt "impl:test" >/dev/null 2>&1

sel() { ( bash "$here/herdr-select.sh" "$PANE" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" ); }

q_appr() {
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT COALESCE($1,'') FROM approvals ORDER BY decided_at DESC, rowid DESC LIMIT 1;" 2>/dev/null
}
count_events() {
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT count(*) FROM events WHERE type='$1';" 2>/dev/null
}

printf '== SAFE command, peer authority -> allowed, key pressed ==\n'
set_screen "ls -la /tmp"; reset_keys
sel 1 --authority peer; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc (expected 0); stderr: $(cat "$WORK/err.txt")"
[ "$(keys_pressed)" = "1" ] && ok "exactly one key pressed" || bad "keys pressed=$(keys_pressed)"
[ "$(cat "$KEYS")" = "1" ] && ok "the pressed key was the chosen digit" || bad "pressed '$(cat "$KEYS")'"
[ "$(q_appr policy_verdict)" = "allow" ] && ok "verdict recorded allow" || bad "verdict=$(q_appr policy_verdict)"
[ "$(q_appr authority)" = "peer" ] && ok "authority recorded peer" || bad "authority=$(q_appr authority)"
[ -n "$(q_appr decided_at)" ]   && ok "decided_at set"   || bad "decided_at empty"
[ -n "$(q_appr attempted_at)" ] && ok "attempted_at set" || bad "attempted_at empty"
[ -n "$(q_appr confirmed_at)" ] && ok "confirmed_at set (delivery confirmed)" || bad "confirmed_at empty"
[ "$(q_appr outcome)" = "pressed" ] && ok "outcome recorded" || bad "outcome=$(q_appr outcome)"

printf '== DESTRUCTIVE command, peer authority -> REFUSED, no key pressed ==\n'
set_screen "rm -rf /tmp/scratch"; reset_keys
before_esc=$(count_events approval_escalated)
sel 1 --authority peer; rc=$?
[ "$rc" -eq 8 ] && ok "exit 8 (policy refusal)" || bad "exit $rc (expected 8)"
[ "$(keys_pressed)" = "0" ] && ok "NO KEY PRESSED — the property that matters" || bad "keys pressed=$(keys_pressed) on a refusal!"
grep -q 'REFUSED' "$WORK/err.txt" && ok "refusal explained on stderr" || bad "no REFUSED on stderr"
[ "$(( $(count_events approval_escalated) - before_esc ))" = "1" ] && ok "approval_escalated event recorded" || bad "escalation not recorded"

printf '== the SAME destructive prompt, HUMAN authority -> allowed, verdict still recorded ==\n'
set_screen "rm -rf /tmp/scratch"; reset_keys
sel 1 --authority human; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 (a human is the authority)" || bad "exit $rc; stderr: $(cat "$WORK/err.txt")"
[ "$(keys_pressed)" = "1" ] && ok "key pressed for the human" || bad "keys pressed=$(keys_pressed)"
[ "$(q_appr policy_verdict)" = "escalate" ] && ok "escalate verdict RECORDED even though allowed" || bad "verdict=$(q_appr policy_verdict)"

printf '== default authority is human (no flag) ==\n'
set_screen "rm -rf /tmp/scratch"; reset_keys
sel 1; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 without --authority" || bad "exit $rc"
[ "$(q_appr authority)" = "human" ] && ok "authority defaults to human" || bad "authority=$(q_appr authority)"

printf '== HERDR_SELECT_AUTHORITY env also gates ==\n'
set_screen "git push --force origin main"; reset_keys
( export HERDR_SELECT_AUTHORITY=peer; bash "$here/herdr-select.sh" "$PANE" 1 >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 8 ] && ok "env var refuses a force-push" || bad "exit $rc (expected 8)"
[ "$(keys_pressed)" = "0" ] && ok "no key pressed" || bad "keys pressed=$(keys_pressed)"

printf '== a dangerous command far up the pane / past column 200 is STILL classified ==\n'
# The fail-open that giving prompt_command_text its OWN untruncated read closed.
# It used to borrow prompt_context, which ends in `tail -n 8 | cut -c1-200` —
# display trimming. Both defeats are exercised at once: the dangerous verb sits
# beyond column 200 AND more than eight non-empty lines above the bottom of the
# pane, so the old path classified the leftovers as `allow` and pressed the key.
{
  printf ' Bash command\n'
  printf '   echo %s && rm -rf /tmp/scratch\n' "$(printf 'x%.0s' $(seq 1 250))"
  for i in 1 2 3 4 5 6 7 8 9 10; do printf '   filler detail line %s\n' "$i"; done
  printf '\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n'
} > "$SCREEN"
reset_keys
sel 1 --authority peer; rc=$?
[ "$rc" -eq 8 ] && ok "still refused despite distance and line length" || bad "exit $rc (expected 8) — truncation fail-open is back"
[ "$(keys_pressed)" = "0" ] && ok "no key pressed" || bad "keys pressed=$(keys_pressed)"

printf '== an unreadable pane refuses rather than classifying blind ==\n'
: > "$SCREEN"
reset_keys
sel 1 --authority peer; rc=$?
[ "$rc" -ne 0 ] && ok "refused an unreadable pane (exit $rc)" || bad "exit 0 on an unreadable pane"
[ "$(keys_pressed)" = "0" ] && ok "no key pressed" || bad "keys pressed=$(keys_pressed)"

printf '== a recycled pane refuses, ahead of any policy question ==\n'
set_screen "ls -la /tmp"; reset_keys
BIRTH="term-DIFFERENT-999"
sel 1 --authority peer; rc=$?
[ "$rc" -eq 7 ] && ok "exit 7 (pane recycled)" || bad "exit $rc (expected 7)"
[ "$(keys_pressed)" = "0" ] && ok "no key pressed" || bad "keys pressed=$(keys_pressed)"
BIRTH="term-abc-123"

printf '== operator rules tighten the gate (HERDR_POLICY_EXTRA_RULES) ==\n'
set_screen "npm publish --access public"; reset_keys
sel 1 --authority peer; rc=$?
[ "$rc" -eq 0 ] && ok "npm publish allowed by default" || bad "exit $rc (expected 0)"
reset_keys
( export HERDR_POLICY_EXTRA_RULES="$(printf 'escalate\tnpm publish\tsite rule')"
  bash "$here/herdr-select.sh" "$PANE" 1 --authority peer >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 8 ] && ok "operator rule escalates it" || bad "exit $rc (expected 8)"
[ "$(keys_pressed)" = "0" ] && ok "no key pressed under the operator rule" || bad "keys pressed=$(keys_pressed)"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
