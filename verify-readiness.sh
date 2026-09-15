#!/usr/bin/env bash
# verify-readiness.sh — probe_http must WAIT for readiness, not ask once.
#
# WHY: `launchctl kickstart` returning means the process was SPAWNED, not that
# it is listening. restart.sh called probe_http immediately afterwards, so a
# perfectly healthy restart printed DOWN, exited nonzero, and told the operator
# to reinstall a fleet that was fine two seconds later. That is the same false
# alarm the auth-pair start-order fix removed (agent-lib.sh's own comment: a
# --verify that cries wolf "trains the operator to ignore exactly the field
# that would show a real crash"), arriving by a different route.
#
# The contract this pins:
#   * an already-listening service answers on the FIRST attempt — the read-only
#     `--verify` path must not get slower;
#   * a service that comes up DURING the window is reported UP, with how long
#     it took, because "ready after 6s" is the fact that tells you whether the
#     restart was healthy or lucky;
#   * a dead port still FAILS, after the budget, with the wanted codes named;
#   * PROBE_READY_SECS=0 restores single-shot for a caller that wants a
#     point-in-time answer;
#   * a 401 is still HEALTHY (auth-broker/auth-gateway answer that to an
#     unauthenticated probe) — a readiness loop that treated it as "not ready
#     yet" would wait out the whole budget on both of them, on every restart.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/launchd/agent-lib.sh"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
SERVERS=()
# `kill $(jobs -p)` makes bash print "Terminated: 15" plus the whole heredoc
# for every server, which buries the suite's own output. Track the pids and
# disown them instead: the message is the SHELL reporting on a job it owns.
cleanup() {
    local p
    for p in "${SERVERS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# A one-shot HTTP responder that starts after $1 seconds and answers $2.
serve_after() {                 # <delay> <status> <port>
    python3 - "$1" "$2" "$3" <<'PY' &
import http.server, sys, time
delay, status, port = float(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
time.sleep(delay)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(status); self.end_headers(); self.wfile.write(b"x")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
    SERVERS+=("$!")
    disown 2>/dev/null || true
}

now() { python3 -c 'import time;print(f"{time.time():.3f}")'; }
elapsed() { python3 -c "import sys;print(f'{float(sys.argv[2])-float(sys.argv[1]):.1f}')" "$1" "$(now)"; }

printf '== an already-listening service is not slowed down ==\n'
P="$(free_port)"; serve_after 0 200 "$P"; sleep 1
T0="$(now)"
if OUT="$(PROBE_READY_SECS=20 probe_http up "http://127.0.0.1:$P/" 200 2>&1)"; then
    ok "a live service answers UP"
else
    bad "a live service read as DOWN: $OUT"
fi
E="$(elapsed "$T0")"
python3 -c "import sys;sys.exit(0 if float(sys.argv[1]) < 2 else 1)" "$E" \
    && ok "it answers on the first attempt (${E}s)" \
    || bad "a healthy probe took ${E}s — the readiness loop is running when it should not"
printf '%s' "$OUT" | grep -q "ready after" \
    && bad "reported a wait for a service that was already up: $OUT" \
    || ok "and says nothing about waiting"

printf '== a 401 is HEALTHY, not "not ready yet" ==\n'
P="$(free_port)"; serve_after 0 401 "$P"; sleep 1
T0="$(now)"
if OUT="$(PROBE_READY_SECS=20 probe_http authpair "http://127.0.0.1:$P/" 401 2>&1)"; then
    ok "401 reads as UP when it is an expected code"
else
    bad "401 read as DOWN: $OUT"
fi
E="$(elapsed "$T0")"
python3 -c "import sys;sys.exit(0 if float(sys.argv[1]) < 2 else 1)" "$E" \
    && ok "immediately (${E}s), not after the whole budget" \
    || bad "waited ${E}s on a healthy 401 — every restart would pay this twice"

printf '== a service that comes up DURING the window ==\n'
P="$(free_port)"; serve_after 4 200 "$P"
T0="$(now)"
if OUT="$(PROBE_READY_SECS=20 probe_http late "http://127.0.0.1:$P/" 200 2>&1)"; then
    ok "a late starter is reported UP instead of failing the restart"
else
    bad "a service that started 4s in was called DOWN: $OUT"
fi
printf '%s' "$OUT" | grep -q "ready after" \
    && ok "and reports how long it took (evidence the restart was healthy, not lucky)" \
    || bad "no wait reported for a late starter: $OUT"
E="$(elapsed "$T0")"
python3 -c "import sys;sys.exit(0 if 3 <= float(sys.argv[1]) <= 12 else 1)" "$E" \
    && ok "returning as soon as it was ready (${E}s), not at the end of the budget" \
    || bad "took ${E}s for a service ready at 4s"

printf '== a dead port still fails ==\n'
DEAD="$(free_port)"
T0="$(now)"
if OUT="$(PROBE_READY_SECS=3 probe_http dead "http://127.0.0.1:$DEAD/" 200 2>&1)"; then
    bad "a dead port was reported UP: $OUT"
else
    ok "a dead port is DOWN"
fi
printf '%s' "$OUT" | grep -q "wanted: 200" \
    && ok "and names the codes it wanted" || bad "refusal is not actionable: $OUT"
printf '%s' "$OUT" | grep -q "after 3s" \
    && ok "and says it waited, so the operator knows it was not a single miss" \
    || bad "does not report the wait: $OUT"
E="$(elapsed "$T0")"
python3 -c "import sys;sys.exit(0 if float(sys.argv[1]) <= 8 else 1)" "$E" \
    && ok "bounded by the budget (${E}s)" || bad "overran its budget: ${E}s"

printf '== PROBE_READY_SECS=0 restores single-shot ==\n'
T0="$(now)"
PROBE_READY_SECS=0 probe_http oneshot "http://127.0.0.1:$DEAD/" 200 >/dev/null 2>&1 \
    && bad "single-shot mode reported a dead port UP" \
    || ok "single-shot still fails a dead port"
E="$(elapsed "$T0")"
python3 -c "import sys;sys.exit(0 if float(sys.argv[1]) < 2 else 1)" "$E" \
    && ok "and returns immediately (${E}s)" || bad "single-shot waited ${E}s"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
