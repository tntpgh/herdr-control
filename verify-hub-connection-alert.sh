#!/usr/bin/env bash
# verify-hub-connection-alert.sh — proves hub-connection-alert.sh (the "hub
# down / herdr stream disconnected" KEEP case from .handoffs/SPEC.md):
#
#   - a disconnect that recovers within the grace window pages nobody
#   - a disconnect that outlives the grace window pages exactly once
#   - a second "disconnected" call for the same outage does not page again
#   - reconnecting after a real alert posts a recovery line and clears the
#     marker; reconnecting with no prior alert (ordinary startup) is silent
#
# Stubs curl (both the herdr /api/panes probe AND the Slack call resolve
# through the same exported function here — nothing leaves the machine) and
# HERDR_EDGE_NOTIFY as a recording stub, same discipline as agent-edge.sh's
# own verify-herdr-live.sh suite.
#
#   bash verify-hub-connection-alert.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HERDR_STATE_DIR="$WORK/state"
mkdir -p "$HERDR_STATE_DIR"
MARK="$HERDR_STATE_DIR/hub-down-alerted"

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

# HERDR_EDGE_CURL stubs the hub's own /api/panes probe. CONNECTED_NOW toggles
# what it reports, so a test can simulate "still down" vs "recovered".
CONNECTED_NOW="false"
export CONNECTED_NOW
cat > "$WORK/curl.sh" <<'EOS'
#!/usr/bin/env bash
printf '{"connected":%s}' "$CONNECTED_NOW"
EOS
chmod +x "$WORK/curl.sh"
export HERDR_EDGE_CURL="$WORK/curl.sh"

run_alert() { HERDR_HUB_ALERT_GRACE_S="$1" bash "$here/hub-connection-alert.sh" "$2" "${3:-}"; }

printf '== a disconnect that recovers within the grace window pages nobody ==\n'
: > "$NOTIFIED"; rm -f "$MARK"
CONNECTED_NOW="true"     # by the time the grace window is checked, we are back
run_alert 1 disconnected "socket reset"
[ ! -s "$NOTIFIED" ] && ok "recovered blip: 0 posts" || bad "paged for a blip: $(cat "$NOTIFIED")"
[ ! -e "$MARK" ] && ok "no marker left behind" || bad "marker created for a blip that recovered"

printf '== a disconnect that outlives the grace window pages exactly once ==\n'
: > "$NOTIFIED"; rm -f "$MARK"
CONNECTED_NOW="false"
run_alert 1 disconnected "connection refused"
[ -s "$NOTIFIED" ] && ok "1 post after the grace window" || bad "no post for a real outage"
grep -qi 'DOWN' "$NOTIFIED" && ok "post names the symptom" || bad "post text missing: $(cat "$NOTIFIED")"
[ -e "$MARK" ] && ok "marker recorded for this outage" || bad "no marker recorded"

printf '== a second disconnect event for the SAME outage does not page again ==\n'
: > "$NOTIFIED"
run_alert 1 disconnected "connection refused"
[ ! -s "$NOTIFIED" ] && ok "no duplicate page while already marked down" || bad "paged twice for one outage: $(cat "$NOTIFIED")"

printf '== reconnecting after a real alert posts a recovery line and clears the marker ==\n'
: > "$NOTIFIED"
run_alert 1 connected
[ -s "$NOTIFIED" ] && ok "recovery line posted" || bad "no recovery post"
grep -qi 'back up' "$NOTIFIED" && ok "recovery text names it" || bad "recovery text wrong: $(cat "$NOTIFIED")"
[ ! -e "$MARK" ] && ok "marker cleared" || bad "marker survived the recovery"

printf '== reconnecting with no prior alert (ordinary startup) is silent ==\n'
: > "$NOTIFIED"; rm -f "$MARK"
run_alert 1 connected
[ ! -s "$NOTIFIED" ] && ok "ordinary connect: 0 posts" || bad "paged on a plain startup connect: $(cat "$NOTIFIED")"

printf '== HERDR_SLACK_VERBOSE=1 skips the grace wait ==\n'
: > "$NOTIFIED"; rm -f "$MARK"
CONNECTED_NOW="true"   # would have recovered during a real grace wait
HERDR_SLACK_VERBOSE=1 run_alert 30 disconnected "would time out the test otherwise"
[ -s "$NOTIFIED" ] && ok "verbose mode pages immediately, no grace wait" || bad "verbose mode still waited/held"
rm -f "$MARK"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
