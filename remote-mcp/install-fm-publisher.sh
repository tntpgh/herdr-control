#!/usr/bin/env bash
# remote-mcp/install-fm-publisher.sh — render, install or remove the Firstmate
# publisher LaunchAgent (com.firstmate.fm-mcp-publisher). Standalone on purpose:
# install.sh --apply also re-wires the retired herdr hooks.
#
#   bash remote-mcp/install-fm-publisher.sh [--dry-run]   render + lint, print the plist; changes nothing (default)
#   bash remote-mcp/install-fm-publisher.sh --apply       install and start it (captain-approved activation only)
#   bash remote-mcp/install-fm-publisher.sh --uninstall   stop it and remove the plist (the kill switch)
#   bash remote-mcp/install-fm-publisher.sh --status      launchd state + the publisher's status.json
#   options: --fm-home PATH (default ~/Code/firstmate)
#
# --apply refuses while com.herdr-control.remote-mcp is loaded: two publishers
# would overwrite each other's snapshot and both lease the owner outbox.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../launchd/agent-lib.sh
. "$HERE/../launchd/agent-lib.sh"

LABEL=com.firstmate.fm-mcp-publisher
OLD_LABEL=com.herdr-control.remote-mcp
TEMPLATE="$HERE/$LABEL.plist.template"
LIVE="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_PATH="$HOME/Library/Logs/$LABEL.log"
DOMAIN="gui/$(id -u)"
mode=dry-run
fm_home="$HOME/Code/firstmate"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) mode=dry-run ;;
    --apply) mode=apply ;;
    --uninstall) mode=uninstall ;;
    --status) mode=status ;;
    --fm-home) [ "$#" -ge 2 ] || { echo "--fm-home needs a path" >&2; exit 64; }; fm_home=$2; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

render() {  # <out-file>
  local out=$1 py v
  py="$(resolve_hub_python)" || { echo "no pinned python3.11+ found; refusing to render" >&2; return 1; }
  [ -d "$fm_home" ] || { echo "Firstmate home not found: $fm_home" >&2; return 1; }
  [ -x "$fm_home/bin/fm-inbox.sh" ] && [ -x "$fm_home/bin/fm-fleet-snapshot.sh" ] && [ -x "$fm_home/bin/fm-crew-state.sh" ] \
    || { echo "$fm_home/bin lacks fm-inbox.sh / fm-fleet-snapshot.sh / fm-crew-state.sh" >&2; return 1; }
  for v in "$py" "$HERE/fm_publisher.py" "$fm_home" "$LOG_PATH"; do
    case "$v" in *[\&\<\>]*) echo "refusing a path that would need XML escaping: $v" >&2; return 1 ;; esac
  done
  sed -e "s|__FM_MCP_PYTHON__|$(_sed_rhs "$py")|" \
      -e "s|__FM_MCP_PY__|$(_sed_rhs "$HERE/fm_publisher.py")|" \
      -e "s|__FM_HOME__|$(_sed_rhs "$fm_home")|" \
      -e "s|__LOG_PATH__|$(_sed_rhs "$LOG_PATH")|g" \
      "$TEMPLATE" > "$out"
  if grep -q '__[A-Z_]*__' "$out"; then
    echo "unrendered placeholder left in $out" >&2
    return 1
  fi
  plutil -lint "$out" >/dev/null || { echo "rendered plist fails plutil -lint" >&2; return 1; }
}

case "$mode" in
  dry-run)
    tmp="$(mktemp "${TMPDIR:-/tmp}/$LABEL.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    render "$tmp"
    cat "$tmp"
    echo "# dry run: rendered and linted; nothing installed. --apply would write $LIVE and bootstrap $DOMAIN/$LABEL." >&2
    if launchctl print "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1; then
      echo "# note: $OLD_LABEL is loaded; --apply will refuse until: launchctl bootout $DOMAIN/$OLD_LABEL" >&2
    fi
    ;;
  apply)
    if launchctl print "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1; then
      echo "refusing: $OLD_LABEL is loaded. Stop it first: launchctl bootout $DOMAIN/$OLD_LABEL" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$LIVE")" "$(dirname "$LOG_PATH")"
    tmp="$(mktemp "${TMPDIR:-/tmp}/$LABEL.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    render "$tmp"
    stage_plist "$tmp" "$LIVE"
    reload_agent "$LABEL" "$LIVE"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$LIVE"
    echo "$LABEL stopped and removed. The Worker reports the Mac disconnected after 90 s."
    ;;
  status)
    echo "$LABEL: $(agent_status "$LABEL")"
    echo "$OLD_LABEL: $(agent_status "$OLD_LABEL")"
    status_file="$HOME/.local/state/fm-mcp/status.json"
    if [ -f "$status_file" ]; then cat "$status_file"; echo; else echo "no $status_file yet"; fi
    ;;
esac
