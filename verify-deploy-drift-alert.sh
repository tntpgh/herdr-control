#!/usr/bin/env bash
# verify-deploy-drift-alert.sh — proves deploy-drift-alert.sh (the "deploy
# drift > 30 min" KEEP case from .handoffs/SPEC.md, wired once PR #130's
# hub.py deploy_drift_data() made it trivially reachable):
#
#   - under 30 minutes behind -> 0 posts
#   - over 30 minutes behind -> exactly 1 post, naming the repo and minutes
#   - a second "drifted" call for the SAME episode does not page again
#   - catching back up posts a recovery line and clears the marker
#   - an unverified repo (fetch failed) does not manufacture a recovery post
#
# Stubs HERDR_EDGE_NOTIFY as a recording script — nothing leaves the machine.
#
#   bash verify-deploy-drift-alert.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HERDR_STATE_DIR="$WORK/state"
mkdir -p "$HERDR_STATE_DIR"
REPO="herdr-control"
MARK="$HERDR_STATE_DIR/deploy-drift-alerted-${REPO}"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

export NOTIFIED="$WORK/notified.log"
cat > "$WORK/notify.sh" <<'EOS'
#!/usr/bin/env bash
printf 'notified %s\n' "$*" >> "$NOTIFIED"
exit 0
EOS
chmod +x "$WORK/notify.sh"
export HERDR_EDGE_NOTIFY="$WORK/notify.sh"

run() { bash "$here/deploy-drift-alert.sh" "$@"; }

printf '== under 30 minutes behind -> 0 posts ==\n'
: > "$NOTIFIED"; rm -f "$MARK"
run "$REPO" synced 12 abc123 def456
[ ! -s "$NOTIFIED" ] && ok "12m behind, reported as synced by the caller: 0 posts" || bad "posted for a non-drift call: $(cat "$NOTIFIED")"

printf '== over 30 minutes behind -> exactly 1 post ==\n'
: > "$NOTIFIED"; rm -f "$MARK"
run "$REPO" drifted 45 abc123 def456
[ -s "$NOTIFIED" ] && ok "1 post for a real drift" || bad "no post for a 45m drift"
grep -q "$REPO" "$NOTIFIED" && grep -q '45' "$NOTIFIED" && ok "post names the repo and the minutes" \
  || bad "post text incomplete: $(cat "$NOTIFIED")"
[ -e "$MARK" ] && ok "marker recorded for this episode" || bad "no marker recorded"

printf '== a second drifted call for the SAME episode does not page again ==\n'
: > "$NOTIFIED"
run "$REPO" drifted 50 abc123 def456
[ ! -s "$NOTIFIED" ] && ok "no duplicate page while already marked drifted" || bad "paged twice for one episode: $(cat "$NOTIFIED")"

printf '== catching back up posts a recovery line and clears the marker ==\n'
: > "$NOTIFIED"
run "$REPO" synced 0 def456 def456
[ -s "$NOTIFIED" ] && ok "recovery line posted" || bad "no recovery post"
grep -qi 'resolved' "$NOTIFIED" && ok "recovery text names it" || bad "recovery text wrong: $(cat "$NOTIFIED")"
[ ! -e "$MARK" ] && ok "marker cleared" || bad "marker survived the recovery"

printf '== a plain synced call with no prior alert is silent ==\n'
: > "$NOTIFIED"; rm -f "$MARK"
run "$REPO" synced 0 def456 def456
[ ! -s "$NOTIFIED" ] && ok "ordinary in-sync tick: 0 posts" || bad "paged on a plain in-sync tick: $(cat "$NOTIFIED")"

printf '== Python: _deploy_drift_alert_check dispatch — 29m, 31m, fetch_ok=False, error ==\n'
# Isolates the DECISION logic (which repos get a spawn, with what status arg)
# from deploy-drift-alert.sh's own marker/dedup behaviour, already proven
# above at the shell level. DEPLOY_DRIFT_ALERT is repointed at a plain
# recording stub, not the real script.
DISPATCH_LOG="$WORK/dispatch.log"; : > "$DISPATCH_LOG"
cat > "$WORK/record-stub.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DISPATCH_LOG"
EOS
chmod +x "$WORK/record-stub.sh"
DISPATCH_LOG="$DISPATCH_LOG" STUB="$WORK/record-stub.sh" python3 - "$here" <<'PY'
import importlib.util, os, sys, time
from pathlib import Path

repo_dir = sys.argv[1]
spec = importlib.util.spec_from_file_location("hub_under_test", str(Path(repo_dir) / "hub.py"))
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)
hub.DEPLOY_DRIFT_ALERT = Path(os.environ["STUB"])

hub._deploy_drift_alert_check({"repos": [
    {"repo": "repo-29m", "behind_minutes": 29, "fetch_ok": True, "deployed": "a", "main": "b"},
    {"repo": "repo-31m", "behind_minutes": 31, "fetch_ok": True, "deployed": "a", "main": "b"},
    {"repo": "repo-nofetch", "behind_minutes": 45, "fetch_ok": False, "deployed": "a", "main": "b"},
    {"repo": "repo-error", "behind_minutes": 45, "fetch_ok": True, "error": "boom", "deployed": "a", "main": "b"},
]})
time.sleep(0.5)   # let the spawned subprocesses finish writing before this process exits
PY
grep -qE '^repo-29m synced ' "$DISPATCH_LOG" && ok "29m (under threshold) dispatched as synced" \
  || bad "29m row wrong or missing: $(cat "$DISPATCH_LOG")"
grep -qE '^repo-31m drifted ' "$DISPATCH_LOG" && ok "31m (over threshold) dispatched as drifted" \
  || bad "31m row wrong or missing: $(cat "$DISPATCH_LOG")"
grep -q 'repo-nofetch' "$DISPATCH_LOG" && bad "fetch_ok=False repo was dispatched anyway" \
  || ok "fetch_ok=False repo left alone (no false recovery, no false drift)"
grep -q 'repo-error' "$DISPATCH_LOG" && bad "repo carrying an error was dispatched anyway" \
  || ok "errored repo left alone"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
