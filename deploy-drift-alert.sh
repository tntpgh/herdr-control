#!/usr/bin/env bash
# deploy-drift-alert.sh <repo> <drifted|synced> [behind_minutes] [deployed] [main]
#
# .handoffs/SPEC.md KEEP list: "deploy drift > 30 min ... if trivially
# reachable". It was not, when that line was written — this repo had no
# push/alerting hook for it, only lib/sentinel-watch.sh's pull-model CLI
# status line. hub.py's deploy_drift_data() (PR #130) landed on main mid-
# branch and changed that: it already computes behind_minutes per repo on a
# 60s prime loop, and its own dashboard card already treats >30min as "hot"
# (hub.py deploy_drift_rows). Reusing that exact cache and threshold — not
# inventing a second deploy-drift detector — is what makes this trivial now.
#
# Called by hub.py's _deploy_drift_alert_check, once per repo per prime-loop
# tick (60s). Cheap to call unconditionally: the marker file makes every
# call after the first a single stat, and `synced` with no prior alert is a
# same no-op — the script itself decides whether there is anything to do.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo="${1:-}"; status="${2:-}"; minutes="${3:-0}"; deployed="${4:-}"; main_sha="${5:-}"
[ -n "$repo" ] && [ -n "$status" ] || {
  echo "usage: deploy-drift-alert.sh <repo> <drifted|synced> [behind_minutes] [deployed] [main]" >&2
  exit 0
}

STATE_DIR="${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}"
# Sanitized: repo is a config-file value today, but this becomes a filename —
# never trust it to be path-safe just because it currently only ever is.
safe_repo=$(printf '%s' "$repo" | tr -c 'A-Za-z0-9_.-' '_')
MARK="$STATE_DIR/deploy-drift-alerted-${safe_repo}"
NOTIFY="${HERDR_EDGE_NOTIFY:-$here/slack-bridge/herdr-notify.sh}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

case "$status" in
  drifted)
    [ -e "$MARK" ] && exit 0   # already alerted for this drift episode
    : > "$MARK"
    [ -f "$NOTIFY" ] || exit 0
    bash "$NOTIFY" \
      "deploy drift: ${repo} is ${minutes}m behind main (deployed ${deployed}, main ${main_sha}) — a deploy or restart.sh --verify is overdue" \
      >/dev/null 2>&1 || true
    ;;
  synced)
    [ -e "$MARK" ] || exit 0   # never alerted -> nothing to recover from
    rm -f "$MARK"
    [ -f "$NOTIFY" ] || exit 0
    bash "$NOTIFY" "deploy drift resolved: ${repo} is back in sync with main" >/dev/null 2>&1 || true
    ;;
  *)
    echo "deploy-drift-alert: unknown status '$status'" >&2
    ;;
esac
exit 0
