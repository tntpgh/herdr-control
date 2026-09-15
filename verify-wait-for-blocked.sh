#!/usr/bin/env bash
# verify-wait-for-blocked.sh — proof that wait-for-blocked.sh's argument
# parsing, watch-list scoping, and blocked/timeout reporting behave as
# documented — in particular a regression test for the single-argument-form
# bug (independent review finding): `shift 2` is all-or-nothing in bash, so
# a lone `poll_seconds` argument used to leave itself sitting in $* and get
# mistaken for a pane id, silently degrading "watch everything" into "watch
# a pane that doesn't exist."
#
# herdr is stubbed as an exported bash FUNCTION (same technique as
# verify-select-policy.sh/verify-layout.sh) serving canned `pane list`/
# `pane read` responses, so what's verified is the shipping script's
# argument handling and output, not a reimplementation of it.
#
#   bash verify-wait-for-blocked.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# ---- the stub ---------------------------------------------------------------
# HERDR_PANES_JSON drives `pane list`; HERDR_READ_TEXT drives `pane read`.
export HERDR_PANES_JSON="$WORK/panes.json"
export HERDR_READ_TEXT="$WORK/read.txt"
herdr() {
  # Every call is logged when HERDR_CALL_LOG is set, so the hub-mode section
  # can assert that discovery asked herdr NOTHING.
  [ -n "${HERDR_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
  case "$1 $2" in
    "pane list") cat "$HERDR_PANES_JSON" ;;
    "pane read") cat "$HERDR_READ_TEXT" 2>/dev/null ;;
    "pane process-info") printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp"}]}}}\n' ;;
    *) echo "stub herdr: unhandled call: $*" >&2; return 1 ;;
  esac
}
export -f herdr

none_blocked() { printf '{"result":{"panes":[{"pane_id":"w1:p1","label":"idle","workspace_id":"ws1","agent_status":"working"}]}}\n' > "$HERDR_PANES_JSON"; }
one_blocked()  { printf '{"result":{"panes":[{"pane_id":"w1:p1","label":"idle","workspace_id":"ws1","agent_status":"working"},{"pane_id":"w2:p1","label":"stuck","workspace_id":"ws2","agent_status":"blocked"}]}}\n' > "$HERDR_PANES_JSON"; }
two_blocked()  { printf '{"result":{"panes":[{"pane_id":"w2:p1","label":"stuck-a","workspace_id":"ws2","agent_status":"blocked"},{"pane_id":"w3:p1","label":"stuck-b","workspace_id":"ws3","agent_status":"blocked"}]}}\n' > "$HERDR_PANES_JSON"; }
printf 'Do you want to proceed?\n1. Yes\n2. No\n' > "$HERDR_READ_TEXT"

# Everything below the hub section drives the POLLING path deliberately. The
# shipping default is the hub's long-poll (`/api/blocked/wait`), and without
# this the suite would silently talk to whatever real hub is running on this
# machine, ignore every fixture, and hang until the harness timeout — which is
# exactly how it failed on 2026-09-15.
export HERDR_WAIT_MODE=poll

wfb() { bash "$here/wait-for-blocked.sh" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt"; }

printf '== 0 args: default interval/max, watches every pane ==\n'
one_blocked
wfb; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 (found a blocked pane)" || bad "exit $rc (expected 0): $(cat "$WORK/err.txt")"
grep -q "w2:p1" "$WORK/out.txt" && ok "reports the blocked pane" || bad "blocked pane missing: $(cat "$WORK/out.txt")"
grep -q "Do you want to proceed" "$WORK/out.txt" && ok "shows the prompt text so the caller can answer without another round trip" || bad "prompt not shown"

printf '== REGRESSION: a single numeric argument (poll_seconds only) still watches every pane ==\n'
# Before the fix, `shift 2` failed on exactly one positional arg and left it
# in $*, so watch_list became "1" — a bogus pane id nothing ever matches —
# and this call would have timed out (exit 3) instead of finding w2:p1.
one_blocked
wfb 1; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 — watches all panes, not a phantom pane named \"1\"" || bad "exit $rc (expected 0) — single-arg form is broken again"
grep -q "w2:p1" "$WORK/out.txt" && ok "still reports the blocked pane" || bad "blocked pane missing: $(cat "$WORK/out.txt")"

printf '== 2 args (interval + max, no pane ids): watches every pane ==\n'
one_blocked
wfb 1 5; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc (expected 0)"
grep -q "w2:p1" "$WORK/out.txt" && ok "reports the blocked pane" || bad "blocked pane missing"

printf '== 3+ args (interval + max + pane ids): watches ONLY the named panes ==\n'
two_blocked
wfb 1 5 w3:p1; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 — the named pane is blocked" || bad "exit $rc (expected 0)"
grep -q "w3:p1" "$WORK/out.txt" && ok "reports the named blocked pane" || bad "named pane missing: $(cat "$WORK/out.txt")"
grep -q "w2:p1" "$WORK/out.txt" && bad "reported a pane that was never in the watch list!" || ok "did NOT report the other blocked pane — it wasn't being watched"

printf '== an unwatched blocked pane is correctly ignored -> times out ==\n'
one_blocked   # only w2:p1 is blocked, and we watch a DIFFERENT pane
wfb 0 2 w9:p9; rc=$?
[ "$rc" -eq 3 ] && ok "exit 3 (timed out) — the blocked pane wasn't on our watch list" || bad "exit $rc (expected 3)"
grep -q "nothing blocked" "$WORK/err.txt" || grep -q "nothing blocked" "$WORK/out.txt" && ok "explains the timeout" || bad "no timeout explanation"

printf '== nothing ever blocks: times out after max*interval, explains on stdout ==\n'
none_blocked
wfb 0 2; rc=$?
[ "$rc" -eq 3 ] && ok "exit 3 on timeout" || bad "exit $rc (expected 3)"
grep -q "nothing blocked after" "$WORK/out.txt" && ok "explains the timeout with the elapsed budget" || bad "no explanation: $(cat "$WORK/out.txt")"

printf '== omp approval is visible even when herdr reports working ==\n'
printf '{"result":{"panes":[{"pane_id":"w1:p1","agent":"omp","agent_status":"working"}]}}\n' > "$HERDR_PANES_JSON"
printf '╭─ Allow tool: bash ─╮\n│\n│ Command: printf smoke │\n│\n│ Approve │\n│ Deny │\n│\n│ up/down navigate  enter select  esc cancel │\n╰──╯\n' > "$HERDR_READ_TEXT"
wfb 0 1 w1:p1; rc=$?
[ "$rc" -eq 0 ] && ok "visible menu wakes the conductor despite working status" || bad "missed omp approval (exit $rc)"
wfb 0 1 w9:p9; rc=$?
[ "$rc" -eq 3 ] && ok "visible-menu fallback still respects watch scope" || bad "unwatched menu woke the conductor"
printf 'Allow tool: bash\n\nApprove\nAlways allow\nDeny\nup/down navigate  enter select  esc cancel\n' > "$HERDR_READ_TEXT"
wfb 0 1 w1:p1; rc=$?
[ "$rc" -eq 0 ] && ok "unknown menu wakes for review without auto-selecting" || bad "unknown approval hidden"
printf 'Working on the task; no approval requested.\n' > "$HERDR_READ_TEXT"
wfb 0 1 w1:p1; rc=$?
[ "$rc" -eq 3 ] && ok "ordinary working output does not wake the conductor" || bad "false approval detection"

printf '== herdr not on PATH (and no stub function in scope): exit 2, explains ==\n'
out=$(env -i PATH=/nonexistent "$(command -v bash)" "$here/wait-for-blocked.sh" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "exit 2" || bad "exit $rc (expected 2)"
printf '%s' "$out" | grep -q "herdr not on PATH" && ok "explains the missing dependency" || bad "no explanation: $out"

printf '== HUB MODE: waits on the subscription, and makes NO herdr call to find out ==\n'
# A stub hub, because the point of this path is that the answer comes from the
# hub's herdr subscription rather than from herdr: the stub `herdr` function
# above records every call it receives, and this section asserts there were
# none.
HUB_DIR="$WORK/hub"; mkdir -p "$HUB_DIR"
cat > "$HUB_DIR/hub.py" <<'PYHUB'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
STATE = os.environ["STUB_HUB_STATE"]
class H(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        body = json.load(open(STATE))
        path = self.path.split("?")[0]
        if path == "/api/panes":
            out = {"connected": body["connected"], "version": 1, "stats": {},
                   "panes": body["panes"], "blocked": [p for p in body["panes"] if p["agent_status"] == "blocked"]}
        else:
            out = {"connected": body["connected"], "version": 1, "changed": True,
                   "blocked": [p for p in body["panes"] if p["agent_status"] == "blocked"]}
        raw = json.dumps(out).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYHUB
export STUB_HUB_STATE="$HUB_DIR/state.json"
hub_state() { printf '%s\n' "$1" > "$STUB_HUB_STATE"; }
hub_state '{"connected": true, "panes": [{"pane_id":"w2:p1","label":"stuck","workspace":"ws2","agent_status":"blocked"}]}'
PORT=8712
python3 "$HUB_DIR/hub.py" "$PORT" & HUB_PID=$!
trap '{ kill "$HUB_PID"; wait "$HUB_PID"; } 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s --max-time 1 "http://127.0.0.1:$PORT/api/blocked" >/dev/null 2>&1 && break
  sleep 0.3
done

: > "$WORK/herdr-calls"
export HERDR_CALL_LOG="$WORK/herdr-calls"
env HERDR_WAIT_MODE=auto HERDR_HUB_URL="http://127.0.0.1:$PORT/" HERDR_WAIT_SCRAPE_EVERY=0 \
  bash "$here/wait-for-blocked.sh" 5 4 >"$WORK/out.txt" 2>"$WORK/err.txt"; rc=$?
[ "$rc" -eq 0 ] && ok "hub mode exits 0 on a blocked pane" || bad "exit $rc: $(cat "$WORK/err.txt")"
grep -q "w2:p1" "$WORK/out.txt" && ok "reports the pane the subscription named" || bad "pane missing: $(cat "$WORK/out.txt")"
[ ! -s "$WORK/herdr-calls" ] || grep -qv 'pane list' "$WORK/herdr-calls" \
  && ok "discovery made no \`herdr pane list\` call — the hub answered" \
  || bad "hub mode still polled herdr: $(cat "$WORK/herdr-calls")"

hub_state '{"connected": true, "panes": [{"pane_id":"w1:p1","label":"fine","workspace":"ws1","agent_status":"working"}]}'
env HERDR_WAIT_MODE=auto HERDR_HUB_URL="http://127.0.0.1:$PORT/" HERDR_WAIT_SCRAPE_EVERY=0 \
  bash "$here/wait-for-blocked.sh" 1 2 >"$WORK/out.txt" 2>"$WORK/err.txt"; rc=$?
[ "$rc" -eq 3 ] && ok "hub mode times out when nobody is blocked" || bad "exit $rc (expected 3)"

printf '== HUB DOWN / SUBSCRIPTION DOWN: falls back to polling, never goes blind ==\n'
hub_state '{"connected": false, "panes": []}'
one_blocked
env HERDR_WAIT_MODE=auto HERDR_HUB_URL="http://127.0.0.1:$PORT/" \
  bash "$here/wait-for-blocked.sh" 1 3 >"$WORK/out.txt" 2>"$WORK/err.txt"; rc=$?
[ "$rc" -eq 0 ] && grep -q "w2:p1" "$WORK/out.txt" \
  && ok "a subscription reporting connected:false degrades to polling and still finds the pane" \
  || bad "exit $rc, out=$(cat "$WORK/out.txt") err=$(cat "$WORK/err.txt")"

env HERDR_WAIT_MODE=auto HERDR_HUB_URL="http://127.0.0.1:59999/" \
  bash "$here/wait-for-blocked.sh" 1 3 >"$WORK/out.txt" 2>"$WORK/err.txt"; rc=$?
[ "$rc" -eq 0 ] && grep -q "w2:p1" "$WORK/out.txt" \
  && ok "no hub at all degrades to polling too" \
  || bad "exit $rc, out=$(cat "$WORK/out.txt") err=$(cat "$WORK/err.txt")"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
