#!/usr/bin/env bash
# launchd/agent-lib.sh — the one correct way to touch a herdr-control
# LaunchAgent. Sourced by install.sh (which renders plists and reloads them)
# and by restart.sh (which reloads what is already installed). Not executable
# on its own.
#
# Every hard-won launchd fact in this repo lives here rather than being
# re-derived at each call site, which is how install.sh ended up with three
# different reload methods, two of them broken (see #68).

# ── reload_agent LABEL PLIST ─────────────────────────────────────────────────
# The one correct way to (re)load a LaunchAgent in this repo. Three call sites
# used to do this three different ways and two of them were wrong.
#
#  1. `launchctl load` / `kickstart -k` on an already-loaded label reuse the
#     CACHED job definition, so an edited ProgramArguments silently does not
#     take effect. Confirmed live 2026-09-06: a kickstart after editing the
#     bridge plist restarted the OLD argv and the daemon hung in `op read`.
#     So: bootout + bootstrap, always.
#  2. `bootout` is ASYNCHRONOUS. Bootstrapping immediately after it races the
#     teardown and fails with "Bootstrap failed: 5: Input/output error" —
#     which leaves the service BOOTED OUT AND NOT RELOADED, i.e. a routine
#     reinstall takes your auth plane down. Hit live 2026-09-13 on
#     auth-broker, auth-gateway and bridge simultaneously. So: wait for the
#     label to actually disappear, then bootstrap, and retry once on a race.
#  3. Nothing verified the service was RUNNING afterwards, only that the
#     bootstrap command returned 0. A KeepAlive job that crash-loops reports a
#     pid of "-"; that is a failure and must be reported as one.
reload_agent() {
  local label="$1" plist="$2" domain="gui/$(id -u)" i pid pid2

  if ! plutil -lint "$plist" >/dev/null 2>&1; then
    echo "  ! $label: rendered plist is not valid ($plist) — refusing to load" >&2
    return 1
  fi

  launchctl bootout "$domain/$label" 2>/dev/null
  # Bounded wait for teardown: ~5s is far longer than observed (<1s) and still
  # returns promptly on the common path.
  for i in $(seq 1 25); do
    launchctl print "$domain/$label" >/dev/null 2>&1 || break
    sleep 0.2
  done

  if ! launchctl bootstrap "$domain" "$plist" 2>/dev/null; then
    sleep 1
    if ! launchctl bootstrap "$domain" "$plist" 2>/dev/null; then
      echo "  ! $label: bootstrap failed — service is NOT running." >&2
      echo "    retry: launchctl bootstrap $domain $plist" >&2
      return 1
    fi
  fi

  # Verify it is actually RUNNING, not merely accepted. Two samples ~1.2s
  # apart, because one sample is not enough: a job that exits immediately is
  # still visible with a real pid for a moment, so a single check reports
  # success for a service that is already dead (measured — /usr/bin/true
  # returned pid 66265 before this was a two-sample check). A KeepAlive job
  # that crash-loops shows either pid "-" or a DIFFERENT pid on the second
  # sample; both mean "not up".
  _pid_of() { launchctl list 2>/dev/null | awk -v l="$label" '$3==l {print $1}'; }
  for i in $(seq 1 15); do
    pid=$(_pid_of)
    [ -n "${pid:-}" ] && [ "$pid" != "-" ] && break
    sleep 0.2
  done
  if [ -z "${pid:-}" ] || [ "$pid" = "-" ]; then
    echo "  ! $label: loaded but not running (pid '-') — check its log" >&2
    return 1
  fi
  sleep 1.2
  pid2=$(_pid_of)
  if [ "$pid2" = "$pid" ]; then
    echo "  $label loaded (pid $pid)"
    return 0
  fi
  if [ -z "${pid2:-}" ] || [ "$pid2" = "-" ]; then
    echo "  ! $label: started then EXITED (pid $pid is gone) — check its log" >&2
  else
    echo "  ! $label: crash-looping (pid $pid -> $pid2) — check its log" >&2
  fi
  return 1
}

# ── agent_status LABEL ───────────────────────────────────────────────────────
# Prints "RUNNING pid=N last_exit=S", "LOADED-NOT-RUNNING", or "NOT-LOADED".
agent_status() {
  local label="$1" line pid status
  line=$(launchctl list 2>/dev/null | awk -v l="$label" '$3==l {print}')
  [ -z "$line" ] && { echo "NOT-LOADED"; return 1; }
  pid=$(awk '{print $1}' <<<"$line"); status=$(awk '{print $2}' <<<"$line")
  [ "$pid" = "-" ] && { echo "LOADED-NOT-RUNNING last_exit=$status"; return 1; }
  echo "RUNNING pid=$pid last_exit=$status"; return 0
}

# ── probe_http NAME URL EXPECTED... ──────────────────────────────────────────
# A 401 from auth-gateway/auth-broker is HEALTHY: the listener is up and
# refusing an unauthenticated probe. Reading 401 as "down" is the standing
# false alarm here, so expected codes are always explicit.
#
# This WAITS for readiness instead of asking once. `restart.sh` called it
# immediately after `launchctl kickstart` returned, and kickstart returning
# means the process was SPAWNED, not that it is listening — so a healthy
# restart printed DOWN, exited nonzero, and told the operator to reinstall a
# fleet that was fine two seconds later. That is the same false alarm the
# start-order fix below removed from the auth pair, arriving by a different
# route: a --verify that cries wolf teaches you to ignore the one field that
# would show a real crash.
#
# A process that is already up answers on the first attempt, so the ordinary
# read-only `--verify` path is not slowed down at all. PROBE_READY_SECS=0
# restores the old single-shot behaviour.
probe_http() {
  local name="$1" url="$2"; shift 2
  local want=" $* " code waited=0 budget="${PROBE_READY_SECS:-20}"
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)
    if [[ "$want" == *" $code "* ]]; then
      if [ "$waited" -gt 0 ]; then
        echo "  UP   $name ($url -> $code, ready after ${waited}s)"
      else
        echo "  UP   $name ($url -> $code)"
      fi
      return 0
    fi
    [ "$waited" -ge "$budget" ] && break
    sleep 1; waited=$((waited + 1))
  done
  local note=""
  [ "$budget" -gt 0 ] && note=" after ${budget}s"
  echo "  DOWN $name ($url -> ${code:-no response}; wanted: $*)$note" >&2; return 1
}

# The services, in start order, with their health probes.
# Format: label|url|expected codes  (url empty = no HTTP surface)
#
# ORDER IS LOAD-BEARING for the auth pair: `omp auth-gateway serve` probes its
# upstream broker (http://127.0.0.1:8765/v1/snapshot) while starting and EXITS
# 1 on ConnectionRefused — it does not retry. With the gateway listed first,
# every `./restart.sh` (and every login, where launchd starts both at once)
# produced a dead first run that KeepAlive then replaced: observed 2026-09-15
# after a reboot as `RUNNING pid=7172 last_exit=1`, `runs = 2`, with
# `code: "ConnectionRefused"` in the gateway log. Self-healing, but it makes
# `--verify` report a nonzero exit on a healthy fleet, which trains the
# operator to ignore exactly the field that would show a real crash. The
# broker owns no upstream, so starting it first removes the race from the one
# path we control. (Login order is launchd's; the gateway retrying instead of
# exiting is omp's own binary to fix, not this repo's.)
HERDR_SERVICES=(
  "com.herdr-control.hub|http://127.0.0.1:8600/|200 302"
  "com.herdr-control.bridge||"
  "com.herdr-control.auth-broker|http://127.0.0.1:8765/|401 200 404"
  "com.herdr-control.auth-gateway|http://127.0.0.1:4000/|401 200 404"
)
