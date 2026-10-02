#!/usr/bin/env bash
# chrome-relay.sh — open Terrence's REAL Chrome (default user-data-dir, the
# profile that carries OMP Browser Relay + 1Password + ChatGPT), never an omp
# automation instance.
#
# Why: omp launches its own Chrome from the same app bundle with
# --user-data-dir=~/.omp/browser-profiles/<name> (no login, no extensions). When
# the real Chrome is not running, clicking the Dock icon re-opens THAT instance,
# which looks like "signed out, extensions gone". `open -na` with no
# --user-data-dir always lands on the default data dir: it starts the real
# Chrome, or (singleton) forwards to it and opens a window in $CHROME_PROFILE.
#
# Usage: chrome-relay.sh [--status] [--close-strays]
#   --status        report only; launch nothing
#   --close-strays  SIGTERM omp-profile Chromes that have no CDP client attached
# Env: CHROME_PROFILE (default "Profile 1"), OMP_RELAY_PORT (default 9224)
# Exit 0 = real Chrome running and relay connected (or no omp relay listening).
set -euo pipefail

APP="/Applications/Google Chrome.app"
BIN="$APP/Contents/MacOS/Google Chrome"
UDD="$HOME/Library/Application Support/Google/Chrome"
OMP_PROFILES="$HOME/.omp/browser-profiles"
PROFILE="${CHROME_PROFILE:-Profile 1}"
RELAY_PORT="${OMP_RELAY_PORT:-9224}"

status_only=0 close_strays=0
for a in "$@"; do
  case "$a" in
    --status) status_only=1 ;;
    --close-strays) close_strays=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

[[ -d "$UDD/$PROFILE" ]] || { echo "no Chrome profile dir: $UDD/$PROFILE" >&2; exit 2; }

udd_of() { # $1 = full args; prints --user-data-dir value or nothing
  local a="$1"
  [[ $a == *--user-data-dir=* ]] || return 0
  a=${a#*--user-data-dir=}
  printf '%s\n' "${a%% --*}"
}

scan() { # sets real_pid and strays from main Chrome processes (helpers live under Frameworks/)
  real_pid="" strays=()
  local pid args udd
  while read -r pid args; do
    [[ $args == "$BIN" || $args == "$BIN "* ]] || continue
    udd=$(udd_of "$args")
    if [[ -z $udd || $udd == "$UDD" ]]; then real_pid=$pid
    elif [[ $udd == "$OMP_PROFILES"/* ]]; then strays+=("$pid")
    fi
  done < <(ps -axo pid=,args=)
}
scan

for pid in ${strays[@]+"${strays[@]}"}; do
  args=$(ps -o args= -p "$pid")
  port=$(grep -oE -- '--remote-debugging-port=[0-9]+' <<<"$args" | cut -d= -f2 || true)
  clients=""
  [[ -n $port ]] && clients=$(lsof -nP -t -iTCP:"$port" -sTCP:ESTABLISHED 2>/dev/null | grep -vx "$pid" | sort -u | tr '\n' ' ' || true)
  echo "stray omp Chrome pid=$pid profile=$(udd_of "$args") cdp=${port:-none} clients=${clients:-none}"
  if (( close_strays )); then
    if [[ -z $clients ]]; then kill -TERM "$pid" && echo "  closed (idle)"
    else echo "  kept: in use by pid(s) $clients"
    fi
  fi
done

if (( ! status_only )); then
  open -na "$APP" --args --profile-directory="$PROFILE"
  for _ in $(seq 1 20); do scan; [[ -n $real_pid ]] && break; sleep 0.5; done
fi

[[ -n $real_pid ]] || { echo "real Chrome: NOT running"; exit 1; }
echo "real Chrome: pid=$real_pid profile='$PROFILE'"

relay_connected() { # an established :RELAY_PORT socket owned by a child of the real Chrome
  local p
  for p in $(lsof -nP -t -iTCP:"$RELAY_PORT" -sTCP:ESTABLISHED 2>/dev/null | sort -u); do
    [[ $(ps -o ppid= -p "$p" | tr -d ' ') == "$real_pid" ]] && return 0
  done
  return 1
}

if ! lsof -nP -iTCP:"$RELAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "relay: no omp listening on :$RELAY_PORT; the extension connects when an omp session starts"
  exit 0
fi
for _ in $(seq 1 30); do relay_connected && { echo "relay: connected on :$RELAY_PORT"; exit 0; }; sleep 0.5; done
echo "relay: NOT connected on :$RELAY_PORT; check OMP Browser Relay is enabled in chrome://extensions ($PROFILE)"
exit 1
