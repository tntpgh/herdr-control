#!/usr/bin/env bash
# hub-connection-alert.sh <connected|disconnected> [error text]
#
# Slack backstop for the ONE symptom a per-pane alert can never describe: the
# herdr control plane itself going blind. Called by hub.py's LiveState
# (lib/herdr_live.py on_connection_change) on a genuine connected<->
# disconnected flip — never on a same-state resubscribe or redundant
# re-affirm, so this fires at most once per real outage and once per
# recovery.
#
# .handoffs/SPEC.md KEEP list: "hub down / herdr stream disconnected". While
# the subscription is down, agent-edge.sh's own probe (pane_probe) cannot
# tell "the worker cleared" from "I could not ask" — every per-pane backstop
# in the fleet is guessing at once, and nothing today says so in one place.
#
# GRACED, same discipline as everything else here (lib/alert-gate.sh,
# agent-edge.sh): herdr_live.py's own reconnect loop starts at a 0.5s backoff
# and a transient blip recovers on its own well inside a few seconds, so
# paging on the FIRST disconnect event would be noise, not a symptom. Waits
# HERDR_HUB_ALERT_GRACE_S, then asks the hub's own API (not a cached flag —
# the hub may have reconnected in the meantime) whether it is STILL down
# before posting. HERDR_SLACK_VERBOSE=1 skips the grace and pages immediately
# (restores "any flip pages"), matching the escape hatch documented in
# slack-bridge/herdr-notify.sh.
#
# Dedup: ONE alert per outage, tracked by a marker file (not the prompt_id
# ledger in lib/alert-gate.sh — this alert is not about any single prompt).
# `connected` clears the marker and posts a recovery line, but only if we
# actually alerted; a connect with no prior alert is normal startup, not news.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
status="${1:-}"
err="${2:-}"
[ -n "$status" ] || { echo "usage: hub-connection-alert.sh <connected|disconnected> [error]" >&2; exit 0; }

STATE_DIR="${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}"
MARK="$STATE_DIR/hub-down-alerted"
GRACE="${HERDR_HUB_ALERT_GRACE_S:-30}"
case "$GRACE" in ''|*[!0-9]*) GRACE=30 ;; esac
NOTIFY="${HERDR_EDGE_NOTIFY:-$here/slack-bridge/herdr-notify.sh}"
CURL="${HERDR_EDGE_CURL:-curl}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

case "$status" in
  disconnected)
    if [ "${HERDR_SLACK_VERBOSE:-0}" = 1 ]; then
      # Restores the pre-fix "any flip pages" behaviour outright: no grace
      # wait, no live re-verify, no outage-marker dedup — the same escape
      # hatch slack-bridge/herdr-notify.sh documents for its own gating.
      [ -f "$NOTIFY" ] || exit 0
      bash "$NOTIFY" \
        "herdr control-plane subscription is DOWN${err:+ ($err)} — every alert and backstop is blind until it reconnects" \
        >/dev/null 2>&1 || true
      exit 0
    fi
    sleep "$GRACE"
    # Re-verify against the hub's OWN api, not a value captured before the
    # sleep — a blip that recovered during the grace window must never page.
    url="${HERDR_HUB_URL:-http://127.0.0.1:${HERDR_HUB_PORT:-8600}/}"
    body=$("$CURL" -s --max-time 3 "${url}api/panes" 2>/dev/null) || body=""
    if printf '%s' "$body" | jq -e '.connected == true' >/dev/null 2>&1; then
      exit 0   # recovered within the grace window — no alert
    fi
    [ -e "$MARK" ] && exit 0   # already alerted for this outage
    : > "$MARK"
    [ -f "$NOTIFY" ] || exit 0
    bash "$NOTIFY" \
      "herdr control-plane subscription is DOWN${err:+ ($err)} — every alert and backstop is blind until it reconnects" \
      >/dev/null 2>&1 || true
    ;;
  connected)
    [ -e "$MARK" ] || exit 0   # never alerted for this outage -> nothing to recover from
    rm -f "$MARK"
    [ -f "$NOTIFY" ] || exit 0
    bash "$NOTIFY" "herdr control-plane subscription is back up" >/dev/null 2>&1 || true
    ;;
  *)
    echo "hub-connection-alert: unknown status '$status'" >&2
    ;;
esac
exit 0
