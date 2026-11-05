#!/usr/bin/env bash
# firstmate-dashboard/launchd.sh — render, install or remove the dashboard's
# launchd agent (com.firstmate.dashboard).
#
#   launchd.sh render    [--home DIR] [--port N]   print the plist, change nothing
#   launchd.sh install   [--home DIR] [--port N]   write ~/Library/LaunchAgents/… and load it
#   launchd.sh uninstall                           unload it and remove the plist
#   launchd.sh status                              is it loaded, does the port answer
#
# --home defaults to $FM_HOME, then ~/Code/firstmate. --port defaults to 8600,
# the port the omp status line and fleet-tools.ts read.
#
# install refuses while herdr-control's hub agent is loaded or the port is
# taken: two servers cannot share 8600, and the herdr hub is not ours to stop.
set -euo pipefail

LABEL=com.firstmate.dashboard
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TEMPLATE="$HERE/$LABEL.plist.template"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/firstmate-dashboard.log"
DOMAIN="gui/$(id -u)"

die() { printf 'launchd.sh: %s\n' "$*" >&2; exit 1; }

cmd=${1:-}
[ -n "$cmd" ] || die "usage: launchd.sh render|install|uninstall|status [--home DIR] [--port N]"
shift
fm_home=${FM_HOME:-$HOME/Code/firstmate}
port=8600
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -ge 2 ] || die "--home needs a value"; fm_home=$2; shift 2 ;;
    --port) [ "$#" -ge 2 ] || die "--port needs a value"; port=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$port" in ''|*[!0-9]*) die "--port must be a number" ;; esac

render() {
  local python tasks_axi path_dirs="" d nm
  python=$("$REPO/launchd/resolve-hub-python.sh") || die "no pinned python >=3.11 (launchd/resolve-hub-python.sh)"
  [ -x "$fm_home/bin/fm-tasks-axi.sh" ] || die "$fm_home is not a Firstmate home (no bin/fm-tasks-axi.sh)"
  tasks_axi=$(command -v tasks-axi) || die "tasks-axi is not on PATH; the Firstmate CLIs need it"
  # launchd starts with no shell PATH: carry the directories the CLIs need.
  nm=$(command -v no-mistakes 2>/dev/null) || nm=""
  for d in "$(dirname "$tasks_axi")" ${nm:+"$(dirname "$nm")"} "$HOME/.local/bin" \
           /opt/homebrew/bin /usr/local/bin /usr/bin /bin; do
    case ":$path_dirs:" in *":$d:"*) ;; *) path_dirs=${path_dirs:+$path_dirs:}$d ;; esac
  done
  # Substitution in python, not sed/awk: both treat `&` in a replacement as
  # "the matched text", and XML-escaping a path is exactly what produces one.
  "$python" - "$TEMPLATE" "$python" "$HERE/server.py" "$fm_home" "$port" "$path_dirs" "$LOG" <<'PY'
import sys
from xml.sax.saxutils import escape
tpl, *vals = sys.argv[1:]
text = open(tpl).read()
for key, val in zip(("__PYTHON__", "__SERVER__", "__FM_HOME__", "__PORT__", "__PATH__", "__LOG_PATH__"), vals):
    text = text.replace(key, escape(val))
sys.stdout.write(text)
PY
}

port_busy() { lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; }

case "$cmd" in
  render)
    render
    ;;
  install)
    if launchctl print "$DOMAIN/com.herdr-control.hub" >/dev/null 2>&1; then
      die "com.herdr-control.hub is loaded and owns port 8600; turn herdr-control off first"
    fi
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && die "$LABEL is already loaded; uninstall first"
    port_busy && die "port $port is already in use"
    out=$(render)
    mkdir -p "$(dirname "$TARGET")" "$(dirname "$LOG")"
    printf '%s\n' "$out" > "$TARGET"
    plutil -lint "$TARGET" >/dev/null || { rm -f "$TARGET"; die "rendered plist failed plutil -lint"; }
    launchctl bootstrap "$DOMAIN" "$TARGET"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -fsS --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
        echo "installed: http://127.0.0.1:$port/ (log $LOG)"; exit 0
      fi
      sleep 1
    done
    die "loaded, but http://127.0.0.1:$port/healthz did not answer in 10s; see $LOG"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || echo "$LABEL was not loaded"
    rm -f "$TARGET"
    echo "removed $TARGET"
    ;;
  status)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then echo "loaded: $LABEL"; else echo "not loaded: $LABEL"; fi
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then echo "port $port answers"; else echo "port $port silent"; fi
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
