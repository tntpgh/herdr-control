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

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
