#!/usr/bin/env bash
# verify-ack.sh — an ack may never hide a worker that needs attention.
#
# An ack is the only way a row leaves the attention surface without the work
# being resolved, so the whole risk lives in WHICH rows it can be written for.
# Review proved the first version wrote markers for blocked, stalled and
# running rows that merely shared a branch suffix — latent silencers: the
# moment such a pane went idle with its evidence time unchanged, the ack fired
# and the row left every surface, including this tool's own listing, so --undo
# could not even name it.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; kill %1 2>/dev/null' EXIT
PORT=8679

# A fixture hub: four tasks sharing the branch suffix `pr520`, one of each state.
cat > "$WORK/fixture.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
BODY = json.dumps({"tasks": [
    {"task_id": "t_ready",   "label": "review:pr520",    "state": "ready_review",
     "pane_id": "w1:p1", "worktree": "/tmp/x", "evidence_at": 1000.0},
    {"task_id": "t_stalled", "label": "implement:pr520", "state": "stalled",
     "pane_id": "w1:p2", "worktree": "/tmp/x", "evidence_at": 900.0},
    {"task_id": "t_blocked", "label": "fix:pr520",       "state": "blocked",
     "pane_id": "w1:p3", "worktree": "/tmp/x", "evidence_at": 880.0},
    {"task_id": "t_running", "label": "other:pr520",     "state": "running",
     "pane_id": "w1:p4", "worktree": "/tmp/x", "evidence_at": 870.0},
]}).encode()
SHAPE = sys.argv[2] if len(sys.argv) > 2 else "good"
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = BODY
        if SHAPE == "string":  body = b'{"tasks": "not a list"}'
        if SHAPE == "nulls":   body = b'{"tasks": [null, 42]}'
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

start_hub() { python3 "$WORK/fixture.py" "$PORT" "${1:-good}" & sleep 0.7; }
stop_hub()  { kill %1 2>/dev/null; wait %1 2>/dev/null; }
ack() { HERDR_ACK_FILE="$WORK/ack.json" HERDR_HUB_PORT="$PORT" bash "$here/ack.sh" "$@" 2>&1; }
marks() { cat "$WORK/ack.json" 2>/dev/null || printf '{}'; }

printf '== which rows an ack may be written for ==\n'
start_hub good
: > "$WORK/ack.json"
OUT="$(ack pr520)"
case "$(marks)" in
  *t_ready*) ok "the ready_review row is acked" ;;
  *) bad "the ready_review row was not acked: $(marks)" ;;
esac
for t in t_stalled t_blocked t_running; do
  case "$(marks)" in
    *"$t"*) bad "a marker was written for $t — that is a latent silencer" ;;
    *) ok "no marker for $t" ;;
  esac
done

printf '== --all is the same rule ==\n'
: > "$WORK/ack.json"; OUT="$(ack --all)"
[ "$(python3 -c "import json;print(len(json.load(open('$WORK/ack.json'))))" 2>/dev/null)" = 1 ] \
  && ok "--all acks only the ready_review rows" \
  || bad "--all wrote $(marks)"

printf '== a marker binds to the evidence time, not to now ==\n'
: > "$WORK/ack.json"; ack --all >/dev/null
[ "$(python3 -c "import json;print(json.load(open('$WORK/ack.json'))['t_ready'])")" = "1000.0" ] \
  && ok "the marker is the row's evidence time" \
  || bad "marker is not the evidence time: $(marks)"

printf '== undo may look everywhere, because it only ever reveals ==\n'
python3 -c "import json;json.dump({'t_blocked':880.0}, open('$WORK/ack.json','w'))"
OUT="$(ack --undo fix:pr520)"
case "$(marks)" in
  *t_blocked*) bad "--undo could not remove a stray marker: $OUT" ;;
  *) ok "--undo removes a marker on a non-ready row (it can only make things visible)" ;;
esac

printf '== a wrong-shape response is a message, not a traceback ==\n'
stop_hub
for shape in string nulls; do
  start_hub "$shape"
  OUT="$(ack pr520)"; rc=$?
  case "$OUT" in
    *Traceback*|*AttributeError*) bad "a $shape response produced a traceback" ;;
    *) ok "a $shape response is handled without a traceback (rc=$rc)" ;;
  esac
  stop_hub
done

printf '== an unreachable hub says so ==\n'
OUT="$(HERDR_ACK_FILE="$WORK/ack.json" HERDR_HUB_PORT=9 bash "$here/ack.sh" --all 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && case "$OUT" in *"not answering"*) true ;; *) false ;; esac; } \
  && ok "an unreachable hub exits 2 and says which port" \
  || bad "unreachable hub: rc=$rc $OUT"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
