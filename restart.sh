#!/usr/bin/env bash
# restart.sh — restart the herdr-control control plane, and prove it came back.
#
#   ./restart.sh              restart all four services, then verify
#   ./restart.sh --verify     check only; changes nothing
#   ./restart.sh --panes      also close every agent pane first (clean slate)
#   ./restart.sh hub bridge   restart only the named services
#   ./restart.sh --deploy     deploy origin/main to the app worktree, then restart
#   ./restart.sh --deploy=<rev>   deploy that revision (rollback is a sha)
#
# WHY THIS EXISTS, rather than a remembered launchctl incantation:
#
#   * `launchctl load` and `kickstart -k` on an already-loaded label reuse the
#     CACHED job definition, so an edited plist silently does not take effect.
#     Confirmed live 2026-09-06 — a kickstart after editing the bridge plist
#     restarted the OLD argv and the daemon hung in `op read`.
#   * `bootout` is ASYNCHRONOUS; bootstrapping straight after it races the
#     teardown, fails with "Bootstrap failed: 5: Input/output error", and
#     leaves the service DOWN. That is how install.sh took the auth plane out
#     on 2026-09-13 (#68).
#   * A service is not "up" because bootstrap returned 0. It is up when it
#     still holds the same pid a second later.
#
# All of that lives in launchd/agent-lib.sh, shared with install.sh.
#
# WHAT THIS DELIBERATELY DOES NOT TOUCH:
#   ~/.herdr/worktrees      live git worktrees with branches and possibly
#                           uncommitted work — deleting these loses work
#   ~/.herdr/isolated-worker isolated agent state
#   .handoffs/ buses        other sessions read them
# A clean CONTROL PLANE is these four services plus (optionally) panes. Agent
# state is a different thing, and conflating them costs you work.
#
# ROLLBACK: these are KeepAlive agents; rerun this script. If a plist itself is
# wrong, re-render it from source of truth:
#   ./install.sh --hub --bridge --auth --apply

set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=launchd/agent-lib.sh
. "$here/launchd/agent-lib.sh"

VERIFY_ONLY=0; PANES=0; DEPLOY=""; WANT=()
for a in "$@"; do
  case "$a" in
    --verify)   VERIFY_ONLY=1 ;;
    --panes)    PANES=1 ;;
    --deploy)   DEPLOY="origin/main" ;;
    --deploy=*) DEPLOY="${a#--deploy=}" ;;
    -h|--help)  # Stop at the first non-comment line instead of a fixed window:
                # the window silently dropped the ROLLBACK block when two
                # --deploy lines were added above it, and that block is the one
                # thing an operator reaches for when the plane is down.
                sed -n '2,/^[^#]/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown flag: $a (try --help)" >&2; exit 2 ;;
    *)          WANT+=("$a") ;;
  esac
done

# Resolve "hub" / "auth-gateway" to full labels; default to all four.
# NOTE: callers MUST read this line-by-line, never `for x in $(services)`. The
# expected-codes field contains spaces, so word-splitting turns "200 302" into
# two bogus service names. (macOS bash 3.2 has no mapfile; use while-read over
# process substitution so loop variables survive.)
services() {
  local entry label short w
  for entry in "${HERDR_SERVICES[@]}"; do
    label=${entry%%|*}; short=${label#com.herdr-control.}
    if [ ${#WANT[@]} -eq 0 ]; then echo "$entry"; continue; fi
    for w in "${WANT[@]}"; do
      if [ "$w" = "$short" ] || [ "$w" = "$label" ]; then echo "$entry"; fi
    done
  done
}

# An unrecognised name must be an ERROR, not an empty selection: `restart.sh
# bogus` used to restart nothing and then print "Control plane up", which is
# the worst possible outcome — a confident report that you did something.
if [ ${#WANT[@]} -gt 0 ]; then
  known=""; for entry in "${HERDR_SERVICES[@]}"; do
    label=${entry%%|*}; known="$known ${label#com.herdr-control.}"
  done
  for w in "${WANT[@]}"; do
    case " $known " in
      *" $w "*) ;;
      *) echo "unknown service: $w" >&2
         echo "known:$known" >&2; exit 2 ;;
    esac
  done
fi

verify() {
  local fail=0 entry label url want st live
  echo "===== VERIFY ====="
  # macOS ships bash 3.2: no mapfile. A while-read over process substitution
  # keeps `fail` in this shell (a pipe would not).
  while IFS= read -r entry; do
    label=${entry%%|*}
    printf "  %-34s " "$label"
    st=$(agent_status "$label") || fail=1
    echo "$st"
  done < <(services)
  echo
  while IFS= read -r entry; do
    IFS='|' read -r label url want <<<"$entry"
    [ -z "$url" ] && continue
    # shellcheck disable=SC2086
    probe_http "${label#com.herdr-control.}" "$url" $want || fail=1
  done < <(services)
  # The hub's herdr subscription is a service in its own right now: every
  # blocked-worker surface reads it, and a listener answering 200 while the
  # subscription is dead would report an empty, silent fleet. `connected` is
  # the only honest check.
  #
  # It connects AFTER the listener binds — the HTTP probe above passing is not
  # evidence this is up yet — so this waits on the same budget rather than
  # asking once and declaring a healthy restart broken.
  # WHICH REVISION is serving. The whole point of the deployed worktree is
  # that this is a fact rather than an inference from which branch happens to
  # be checked out; printing it is what makes that fact checkable.
  printf "  %-34s " "hub deployed revision"
  _plist="$HOME/Library/LaunchAgents/com.herdr-control.hub.plist"
  _plist_app=0
  grep -qF "$HERDR_APP_DIR/hub.py" "$_plist" 2>/dev/null && _plist_app=1
  if [ ! -d "$HERDR_APP_DIR" ]; then
    if [ "$_plist_app" = 1 ]; then
      # The plist points at a directory that is not there: launchd is
      # KeepAlive-looping a missing hub.py. That IS the outage.
      echo "MISSING — the plist points at $HERDR_APP_DIR, which does not exist" >&2
      echo "    repair: ./restart.sh --deploy   (prunes the stale worktree registration)" >&2
      fail=1
    else
      # Not deployed yet, and the plist does not expect it to be. All four
      # services can be up and serving; failing here would be exactly the
      # cried wolf this file's own header warns about.
      echo "not deployed (plist still runs a working checkout — ./install.sh --hub --apply)"
    fi
  else
    _rev="$(app_rev)"
    _head="$(git -C "$HERDR_APP_DIR" rev-parse HEAD 2>/dev/null)"
    _main="$(git -C "$HERDR_APP_DIR" rev-parse origin/main 2>/dev/null)"
    # IDENTITY, not a one-way count. `rev-list --count <rev>..origin/main`
    # counts only what main has and the deployed rev does not, so ANY
    # descendant of — or branch off — main scored 0 and was reported
    # "== origin/main". That made the one line intended to prove provenance
    # assert that unmerged code was reviewed main.
    if [ -z "$_main" ]; then
      echo "$_rev (origin/main does not resolve here — cannot compare)"
    elif [ "$_head" = "$_main" ]; then
      echo "$_rev (== origin/main)"
    else
      set -- $(git -C "$HERDR_APP_DIR" rev-list --left-right --count "$_main...$_head" 2>/dev/null || echo "? ?")
      echo "$_rev — ${1:-?} behind / ${2:-?} ahead of origin/main"
    fi
    case "$_rev" in
      *-dirty) echo "    ! the deployed tree has LOCAL EDITS; that sha is not what is running" >&2; fail=1 ;;
    esac
  fi
  # THE assertion that "the port answers" cannot make: does the process
  # THE PLUGIN'S revision, next to the hub's, because it is the same question
  # asked of a different surface — and the one that was wrong for weeks without
  # anybody noticing, because a local link never disagrees with itself.
  printf "  %-34s " "plugin pinned revision"
  _pstate="$(plugin_state)"
  case "$_pstate" in
    github*)
      _psha="${_pstate#github }"
      _want_full="$(git -C "$HERDR_APP_DIR" rev-parse HEAD 2>/dev/null)"
      if [ -z "$_want_full" ]; then
        echo "${_psha:0:7} (nothing deployed to compare against)"
      elif [ "$_psha" = "$_want_full" ]; then
        echo "${_psha:0:7} (== the deployed rev)"
      else
        echo "${_psha:0:7} != deployed ${_want_full:0:7}" >&2
        echo "    repair: ./restart.sh --deploy   (pins the plugin with the app)" >&2
        fail=1
      fi ;;
    local*)
      echo "LOCAL LINK (${_pstate#local }) — actions run from that checkout's branch" >&2
      echo "    its scripts are whatever is checked out there, which is what a" >&2
      echo "    pinned install exists to prevent; deliberate during development." >&2 ;;
    none)
      echo "NOT INSTALLED — Projects / Quick Actions / What Needs Me are unavailable" >&2
      echo "    repair: herdr plugin install $HERDR_PLUGIN_REPO --ref \$(cd $HERDR_APP_DIR && git rev-parse HEAD) -y" >&2
      fail=1 ;;
    *) echo "$_pstate" ;;
  esac

  # answering :8600 run the revision that was deployed?
  #
  # hub.py exits 0 immediately if the port is already open ("already
  # serving"), and the omp extension starts a hub FROM THE CHECKOUT on session
  # start. If such a process holds the port when the deployed job is
  # bootstrapped, the deployed copy exits on the spot, KeepAlive respawns it
  # forever, and every check here still passes — probe_http gets its 200,
  # /api/panes reports connected — served by the stale checkout process.
  # reload_agent's two-sample pid check is the only other thing that catches
  # it, and asking the PORT structurally cannot.
  if [ -d "$HERDR_APP_DIR" ]; then
    printf "  %-34s " "hub serving the deployed rev"
    _served="$(curl -s --max-time 5 "http://127.0.0.1:${HERDR_HUB_PORT:-8600}/api/summary" 2>/dev/null \
               | sed -n 's/.*"rev": *"\([^"]*\)".*/\1/p')"
    _want="$(app_rev)"
    if [ -z "$_served" ]; then
      echo "no answer (hub not serving, or too old to report a rev)" >&2
    elif [ "$_served" = "$_want" ]; then
      echo "yes ($_served)"
    else
      echo "NO — serving $_served, deployed $_want" >&2
      echo "    something else holds :8600 (hub.py exits 0 when the port is taken," >&2
      echo "    and the omp extension starts one from the checkout). Find it:" >&2
      echo "      lsof -nP -iTCP:${HERDR_HUB_PORT:-8600} -sTCP:LISTEN" >&2
      fail=1
    fi
  fi
  printf "  %-34s " "hub herdr subscription"
  local waited=0 budget="${PROBE_READY_SECS:-20}"
  while :; do
    live=$(curl -s --max-time 5 "http://127.0.0.1:${HERDR_HUB_PORT:-8600}/api/panes" 2>/dev/null)
    printf '%s' "$live" | jq -e '.connected == true' >/dev/null 2>&1 && break
    [ "$waited" -ge "$budget" ] && break
    sleep 1; waited=$((waited + 1))
  done
  if printf '%s' "$live" | jq -e '.connected == true' >/dev/null 2>&1; then
    echo "UP   ($(printf '%s' "$live" | jq -r '"\(.panes | length) panes, \(.stats.events) events, \(.stats.reconnects) reconnects, \(.blocked | length) blocked"')$([ "$waited" -gt 0 ] && printf ', ready after %ss' "$waited"))"
  else
    echo "DOWN ($(printf '%s' "$live" | jq -r '.stats.last_error // "no response"' 2>/dev/null || echo 'no response'))" >&2
    fail=1
  fi
  if command -v herdr >/dev/null 2>&1; then
    echo
    echo "  panes open: $(herdr pane list 2>/dev/null | grep -o '"pane_id"' | wc -l | tr -d ' ')"
  fi
  return $fail
}

if [ "$VERIFY_ONLY" = 1 ]; then verify; exit $?; fi

# Deploy BEFORE restarting, so the service comes back on the revision asked
# for — and only if it compiled. deploy_app rolls back on its own if not.
if [ -n "$DEPLOY" ]; then
  echo "===== DEPLOY ====="
  deploy_app "$DEPLOY" || { echo "deploy failed; nothing was restarted" >&2; exit 2; }
  # The plugin serves a revision too, and it moves WITH the deploy — see
  # plugin_pin. Not fatal: a failed pin leaves the services deployable, and the
  # message says how to recover. A local dev link is left alone and reported.
  plugin_pin "$(app_rev_sha_full)" || true
  echo
fi

if [ "$PANES" = 1 ]; then
  echo "Closing every agent pane — including the shell you may be reading this in."
  echo "Ctrl-C within 3s to abort."; sleep 3
  for p in $(herdr pane list 2>/dev/null | grep -oE '"pane_id":"[^"]+"' | cut -d'"' -f4); do
    printf "  closing %s ... " "$p"
    herdr pane close "$p" >/dev/null 2>&1 && echo ok || echo failed
  done
  echo
fi

echo "===== RESTART ====="
rc=0
while IFS= read -r entry; do
  label=${entry%%|*}
  plist="$HOME/Library/LaunchAgents/$label.plist"
  if [ ! -f "$plist" ]; then
    echo "  ! $label: not installed ($plist) — run ./install.sh --apply" >&2
    rc=1; continue
  fi
  reload_agent "$label" "$plist" || rc=1
done < <(services)
echo
verify || rc=1
echo
if [ "$rc" = 0 ]; then
  echo "Control plane up."
else
  echo "Something did not come back. Re-render from source of truth:" >&2
  echo "  $here/install.sh --hub --bridge --auth --apply" >&2
fi
exit $rc
