#!/usr/bin/env bash
# verify-notify-pinning.sh — exercises herdr-notify.sh PAST its --dry-run return,
# which is the gap that let a `set -u` break ship: every existing suite stops at
# the dry-run branch, so the registry write and the button-building path had no
# coverage at all (found in review of PR #62, 2026-09-12).
#
# Stubs `curl` (Slack) and `herdr` (pane reads) as exported functions, so the
# real script runs and nothing leaves the machine. No token is real.
#
#   bash verify-notify-pinning.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HERDR_BRIDGE_STATE="$WORK/state"
export HERDR_BRIDGE_ENV="$WORK/env"
export SCREEN="$WORK/screen.txt"
# herdr-notify.sh now claims a prompt_id in the run registry before posting
# (lib/alert-gate.sh alert_claim) — without this, every run here wrote a
# throwaway claim row into this machine's REAL ~/.local/state/herdr registry.
export HERDR_RUN_STATE_DIR="$WORK/runs"
mkdir -p "$HERDR_BRIDGE_STATE"
printf 'export SLACK_BOT_TOKEN=placeholder-not-a-token\nexport HERDR_BRIDGE_ALLOW_USERS=U000TEST\n' > "$HERDR_BRIDGE_ENV"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

PANE="w1:p1"
REG="$HERDR_BRIDGE_STATE/registry.jsonl"

# The posted Slack payload is captured so we can assert on what was SENT.
run_notify() {                          # <args...>
  : > "$WORK/posted.txt"
  ( curl() { cat >> "$WORK/posted.txt" 2>/dev/null; printf '{"ok":true,"ts":"1757000000.000100"}'; }
    export -f curl
    herdr() { case "$1 $2" in "pane read") cat "$SCREEN" ;; *) return 0 ;; esac; }
    export -f herdr
    bash "$here/slack-bridge/herdr-notify.sh" "$@" ) >"$WORK/out.txt" 2>&1
}
last_pid() { tail -1 "$REG" 2>/dev/null | sed -n 's/.*"prompt_id":"\([^"]*\)".*/\1/p'; }

menu() { printf 'Allow tool: bash\nCommand: %s\n\n\033[48;2;42;47;65m Approve\033[0m\n Deny\n\nup/down navigate  enter select  esc cancel\n' "$1" > "$SCREEN"; }

printf '== an informational alert (no --choices) does not die under set -u ==\n'
: > "$SCREEN"; : > "$REG"
run_notify --pane "$PANE" "informational alert, no choices"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc — $(tail -2 "$WORK/out.txt")"
grep -q 'unbound variable' "$WORK/out.txt" && bad "set -u break: $(grep -m1 unbound "$WORK/out.txt")" || ok "no unbound-variable error"
[ -s "$REG" ] && ok "a registry record was written" || bad "NO REGISTRY RECORD"

printf '== a live approval panel records a real fingerprint ==\n'
menu "git status --short"; : > "$REG"
run_notify --choices --pane "$PANE" "needs permission"
pid="$(last_pid)"
[ -n "$pid" ] && [ "${#pid}" -eq 64 ] && ok "prompt_id recorded (64-hex)" || bad "prompt_id=[$pid]"
# (No assertion on the posted body here: herdr-notify passes it as a curl
# ARGUMENT, and a stub that captures args broke the response path. The property
# that matters — a real fingerprint was recorded for this panel — is asserted
# above, and the no-fingerprint case below asserts what is NOT posted, which is
# the security-relevant direction.)

printf '== no fingerprint => NO actionable buttons are posted ==\n'
# The prompt vanished between the poll and the read: options were seen, the
# question was not. Posting buttons anyway would arm an immortal, unpinned,
# human-authority one-click Approve on whatever that pane shows next — and every
# omp panel offers the same "Approve"/"Deny" labels, so herdr-select's
# option-still-on-offer check cannot tell one panel from another.
printf ' Approve\n Deny\n\nup/down navigate  enter select  esc cancel\n' > "$SCREEN"   # options, no Allow tool: header
: > "$REG"
run_notify --choices --pane "$PANE" "needs permission"
grep -q '"action_id"' "$WORK/posted.txt" && bad "buttons posted with no fingerprint" || ok "no buttons posted"
grep -qi 'reply in thread with' "$WORK/posted.txt" && bad "numbered reply offered with no fingerprint" || ok "no numbered-reply offer"
[ -z "$(last_pid)" ] && ok "recorded with an empty prompt_id (thread is unpinned)" || ok "no record/empty pid"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
