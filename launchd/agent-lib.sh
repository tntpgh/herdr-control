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
# ── the deployed app: what the SERVICE runs, pinned to a revision ───────────
# `hub.py` used to be launched straight out of the working checkout, so
# production behaviour depended on which branch happened to be checked out.
# That is the same defect class as the git-hook shims that pointed into a
# branch-local path on 2026-09-15 and killed every commit in 18 repos after a
# switch — one directory over. Concretely: a reboot, a KeepAlive respawn, or
# `restart.sh` while a feature branch was checked out would silently run that
# branch's hub, and nothing would say so.
#
# The service now runs from a git WORKTREE at a stable path, checked out
# DETACHED at a specific commit. A branch switch in the developer checkout
# cannot move it, because a detached worktree has no branch to follow. Deploying
# is an explicit act with a sha, and rollback is the same command with an older
# one.
#
# A worktree rather than a file copy because hub.py resolves `lib/`,
# `agent-edge.sh`, `formserve.py`, `herdr-deliver.sh` and `send-to-agent.sh`
# relative to its OWN path: copying one file would leave it reading a mixture of
# deployed and checked-out code, which is worse than either.
HERDR_APP_DIR="${HERDR_APP_DIR:-$HOME/.local/share/herdr-control/app}"

app_rev_sha() {                 # -> the bare sha, for internal comparisons
  git -C "$HERDR_APP_DIR" rev-parse --short HEAD 2>/dev/null
}

app_rev_sha_full() {            # -> the full sha; plugin pins need all 40
  git -C "$HERDR_APP_DIR" rev-parse HEAD 2>/dev/null
}

app_rev() {                     # -> what is deployed, `-dirty` if it is not that
  # `rev-parse` cannot see a modified tree, so a hand-edit in the deployed dir
  # made every report — this, and /api/summary's `rev` — a provenance claim
  # that was false. `--dirty` is the difference between a sha and a promise.
  git -C "$HERDR_APP_DIR" describe --always --dirty --abbrev=7 2>/dev/null \
    || git -C "$HERDR_APP_DIR" rev-parse --short HEAD 2>/dev/null
}

# ── the herdr PLUGIN serves a revision too ──────────────────────────────────
#
# herdr-control ships a plugin (herdr-plugin.toml: Projects, Quick Actions,
# Sort Tabs, Name This Tab, What Needs Me) and it was installed as
# `local:/Users/thurbs/Code/herdr-control` — so every action executed out of
# whatever branch that SHARED checkout happened to be sitting on. Measured
# 2026-09-18: that checkout was on another session's PR branch, five commits
# behind main, and `guard-raw-prompt-answer.sh` did not exist there at all.
#
# Same defect as the hub before #84 and the hook scanner before #89, in a third
# place. So the plugin is pinned to a commit (`herdr plugin install ... --ref
# <sha>`, which clones into its own managed root), and the pin moves HERE, with
# the deploy — because a release whose second step a human has to remember is
# how 18 repos ended up running an open PR's scanner.
#
# HERDR_PLUGIN_CLI is the test seam: verify-deploy.sh points it at a stub so
# these paths are exercised without touching the operator's live plugin.
HERDR_PLUGIN_ID="${HERDR_PLUGIN_ID:-tntpgh.herdr-control}"
HERDR_PLUGIN_REPO="${HERDR_PLUGIN_REPO:-tntpgh/herdr-control}"

plugin_state() {                # -> "<kind> <detail>": github <sha> | local <path> | none
  # Read plugins.json, the file the herdr SERVER keeps, rather than shelling
  # out: `plugin list --json` is not guaranteed across herdr versions, and a
  # state read that invokes the CLI cannot be distinguished — by a caller or a
  # test — from one that CHANGES something.
  local f="${HERDR_PLUGINS_JSON:-$HOME/.config/herdr/plugins.json}"
  [ -r "$f" ] || { printf 'none\n'; return 0; }
  # A READ THAT FAILS MUST SAY SO. This printed nothing when python3 was absent
  # or broken (the ordinary macOS "no developer tools" state) — and an empty
  # state then fell through plugin_pin's case into an install, against a machine
  # that might be holding a local dev link, while the failure message claimed
  # the plugin was uninstalled. Silence is the one answer a state read may not
  # give.
  local out
  out="$(python3 - "$f" "$HERDR_PLUGIN_ID" <<'PY'

import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    print("none"); raise SystemExit(0)
for p in rows if isinstance(rows, list) else []:
    if p.get("plugin_id") == sys.argv[2]:
        src = p.get("source") or {}
        kind = src.get("kind", "unknown")
        if kind == "github":
            print("github %s" % (src.get("resolved_commit") or "unknown"))
        elif kind == "local":
            print("local %s" % (src.get("path") or p.get("plugin_root") or "?"))
        else:
            print("%s %s" % (kind, p.get("plugin_root") or "?"))
        raise SystemExit(0)
print("none")
PY
)" || { printf 'unreadable %s\n' "$f"; return 2; }
  [ -n "$out" ] || { printf 'unreadable %s\n' "$f"; return 2; }
  printf '%s\n' "$out"
}

# plugin_report <deployed-sha> — the one line `--verify` prints about the
# plugin, and its verdict. A FUNCTION rather than inline shell in restart.sh
# because the review that found the bug below had to transplant the block into
# a harness to drive it; a gate that can only be tested by copying it is a gate
# whose branches go untested.
#
# Returns: 0 agrees with the deployed rev · 1 MUST FAIL the verify · 2 a
# deliberate local dev link (reported, not a failure).
plugin_report() {
  local want="${1:-}" state kind detail
  state="$(plugin_state)" || true
  kind="${state%% *}"; detail="${state#* }"
  case "$kind" in
    github)
      if [ -z "$want" ]; then
        echo "${detail:0:7} (nothing deployed to compare against)"; return 0
      elif [ "$detail" = "$want" ]; then
        echo "${detail:0:7} (== the deployed rev)"; return 0
      else
        echo "${detail:0:7} != deployed ${want:0:7}"
        echo "    repair: ./restart.sh --deploy   (pins the plugin with the app)" >&2
        return 1
      fi ;;
    local)
      echo "LOCAL LINK ($detail) — actions run from that checkout's branch"
      echo "    its scripts are whatever is checked out there, which is what a" >&2
      echo "    pinned install exists to prevent; deliberate during development." >&2
      return 2 ;;
    none)
      echo "NOT INSTALLED — Projects / Quick Actions / What Needs Me are unavailable"
      echo "    repair: herdr plugin install $HERDR_PLUGIN_REPO --ref \$(git -C $HERDR_APP_DIR rev-parse HEAD) -y" >&2
      return 1 ;;
    *)
      # An unclassifiable state used to print itself and leave the verdict
      # untouched, so `--verify` passed with a BLANK row when the read failed —
      # a surface answering without saying what it answers from, which is the
      # defect this whole change removes, reproduced in its own gate.
      echo "UNKNOWN STATE ('${state:-<could not be read>}')"
      echo "    the plugin's revision cannot be established; inspect" >&2
      echo "    ${HERDR_PLUGINS_JSON:-$HOME/.config/herdr/plugins.json}" >&2
      return 1 ;;
  esac
}

# plugin_pin <revision> — make the SERVED plugin that revision.
#
# Returns 0 pinned (or already), 1 left alone deliberately, 2 failed.
# A LOCAL link is left alone: someone is developing against it, and a deploy
# that silently replaced a dev link would be the same class of surprise this
# function exists to remove. It says so loudly instead.
plugin_pin() {
  local rev="${1:-}" state kind detail _bad cli="${HERDR_PLUGIN_CLI:-herdr}"
  # An EMPTY revision reached here as one empty argument from
  # `plugin_pin "$(app_rev_sha_full)"` when nothing is deployed — `$1` is bound,
  # so `set -u` never fired. The github arm then UNINSTALLED a correct pin and
  # ran `install --ref "" -y`: a working pin destroyed to chase a revision that
  # does not exist.
  [ -n "$rev" ] || {
    echo "plugin: no revision to pin to (is $HERDR_APP_DIR deployed?) — plugin left as it is" >&2
    return 2; }
  # A pin must be a FULL sha, because herdr records the RESOLVED commit and the
  # read-back below compares against what was asked for. `plugin_pin main`
  # would install correctly and then report failure. Refuse at the door instead
  # of letting the read-back lie.
  case "$rev" in
    *[^0-9a-f]*|"") _bad=1 ;;
    *) [ "${#rev}" = 40 ] && _bad=0 || _bad=1 ;;
  esac
  [ "$_bad" = 0 ] || {
    echo "plugin: '$rev' is not a full 40-char sha; resolve it first" >&2
    echo "  e.g. plugin_pin \"\$(git -C \"\$HERDR_APP_DIR\" rev-parse HEAD)\"" >&2
    return 2; }
  command -v "${cli%% *}" >/dev/null 2>&1 || {
    echo "plugin: $cli not on PATH — plugin left as it is" >&2; return 1; }
  state="$(plugin_state)"; kind="${state%% *}"; detail="${state#* }"
  case "$kind" in
    local)
      echo "plugin: LEFT AS A LOCAL LINK ($detail) — a dev link is deliberate," >&2
      echo "  so the deploy will not replace it. Its actions run from whatever" >&2
      echo "  branch that checkout is on. To serve the deployed revision:" >&2
      echo "    herdr plugin unlink $HERDR_PLUGIN_ID && herdr plugin install $HERDR_PLUGIN_REPO --ref $rev -y" >&2
      return 1 ;;
    github)
      [ "$detail" = "$rev" ] && { echo "plugin:    already pinned at ${rev:0:7}"; return 0; }
      # Reinstall is the update path; there is no `plugin update` subcommand,
      # and installing over an existing id REFUSES rather than swapping
      # (verified 2026-09-18), so the uninstall is required, not tidiness.
      #
      # And it is CHECKED. `|| true` here was the last silent write in this
      # function: when the uninstall failed, the install was then refused for
      # the id that still existed, and the operator was told "the plugin is now
      # UNINSTALLED, not stale" while the record still read the old pin — with
      # both printed recovery commands wrong, since the install refuses again
      # and the link would swap a correct, still-present pin for the shared
      # checkout. Branching here also lets this path say the much better true
      # thing: nothing was lost.
      if ! $cli plugin uninstall "$HERDR_PLUGIN_ID" >/dev/null 2>&1; then
        echo "plugin: uninstall of $HERDR_PLUGIN_ID FAILED — STILL PINNED at ${detail:0:7}." >&2
        echo "  Nothing was lost: the install was not attempted, because it would" >&2
        echo "  be refused over an id that still exists. The old revision is live." >&2
        echo "  inspect: ${cli} plugin list" >&2
        return 2
      fi ;;
    none) : ;;
    *)
      # Anything this function cannot CLASSIFY it must not touch: an unreadable
      # record, a `source` key herdr adds later (`worktree`, `path`), a shape
      # from a future version. Falling through to install was how the
      # "a deploy will not replace a local link" guarantee became void exactly
      # when the state read failed.
      echo "plugin: cannot classify the installed plugin (record says '$state')" >&2
      echo "  refusing to touch it — inspect ${HERDR_PLUGINS_JSON:-$HOME/.config/herdr/plugins.json}" >&2
      return 2 ;;
  esac
  $cli plugin install "$HERDR_PLUGIN_REPO" --ref "$rev" -y >/dev/null 2>&1 || {
    echo "plugin: install of $HERDR_PLUGIN_REPO@${rev:0:7} FAILED — the plugin is now" >&2
    echo "  UNINSTALLED, not stale. Recover with either:" >&2
    echo "    herdr plugin install $HERDR_PLUGIN_REPO --ref $rev -y" >&2
    echo "    herdr plugin link ${HERDR_PLUGIN_LOCAL:-$HOME/Code/herdr-control}" >&2
    return 2; }
  state="$(plugin_state)"
  [ "$state" = "github $rev" ] \
    && { echo "plugin:    pinned at ${rev:0:7}"; return 0; } \
    || { echo "plugin: install reported success but the record says '$state'" >&2; return 2; }
}

# deploy_app [<revision>] — point the deployed worktree at a committed revision
# (default: origin/main). Never touches the developer checkout's HEAD.
deploy_app() {
  local want="${1:-origin/main}" src rev prev fetched=""
  # HERDR_APP_SRC exists so verify-deploy.sh can exercise this against a
  # scratch repo with a deliberately unparseable commit — the rollback path
  # cannot be tested against real history, which always compiles. Unset in
  # every real invocation, where the source is the checkout this lib lives in.
  src="${HERDR_APP_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "deploy: $src is not a git checkout" >&2; return 2; }

  # A fetch that failed must SAY so. `-q ... 2>/dev/null || true` hid every
  # failure — offline, VPN down, expired credentials — and `$want` then
  # resolved from whatever the remote-tracking ref was left at, while the
  # deploy reported success "on origin/main". Continuing from a known ref is
  # the right default (refusing to deploy offline would be worse); reporting
  # it as current is not. thurber-os/scripts/audit_launchd.py carries the same
  # note: "a comparison against an unfetched remote is not a comparison".
  if ! git -C "$src" fetch -q origin 2>/dev/null; then
    fetched=" [STALE: fetch failed; '$want' resolved from remote-tracking refs]"
    echo "deploy: fetch failed — resolving '$want' from local remote-tracking refs" >&2
  fi
  rev="$(git -C "$src" rev-parse --verify "$want^{commit}" 2>/dev/null)" || {
    echo "deploy: cannot resolve revision '$want'" >&2; return 2; }

  if [ ! -e "$HERDR_APP_DIR/.git" ]; then
    mkdir -p "$(dirname "$HERDR_APP_DIR")"
    # PRUNE FIRST. `git worktree add` refuses a path still registered in
    # .git/worktrees, so if the app dir is ever lost — a cleanup, a disk
    # repair, a mv, a Migration Assistant restore — every later deploy fails
    # with "missing but already registered worktree". The plist still points
    # at the vanished path, launchd KeepAlive-loops a missing hub.py, and BOTH
    # documented repairs (install.sh --hub --apply, restart.sh --deploy)
    # refuse forever. The only way out was a `git worktree prune` the operator
    # had to already know about. The first cutover was never the risk; every
    # recovery after it was.
    git -C "$src" worktree prune
    git -C "$src" worktree add -q --detach "$HERDR_APP_DIR" "$rev" || {
      echo "deploy: could not create the deployed worktree at $HERDR_APP_DIR" >&2; return 2; }
  else
    prev="$(app_rev_sha)"
    # --force + clean: the deploy is AUTHORITATIVE. A plain checkout carries
    # non-conflicting local edits and untracked files forward, so a hand-patch
    # made in the deployed tree during an incident survived a deploy that
    # reported a clean sha — recreating the "two sources of what is running"
    # this whole change exists to remove.
    git -C "$HERDR_APP_DIR" checkout -q --detach --force "$rev" || {
      echo "deploy: could not check out $rev in $HERDR_APP_DIR" >&2; return 2; }
    git -C "$HERDR_APP_DIR" clean -qfdx
  fi

  # Syntax-check what is about to be SERVED, and check the TREE, not one file:
  # hub.py inserts its own `lib/` on sys.path and imports from it at module
  # load, so a revision whose lib/*.py does not parse passed a hub.py-only
  # gate and crash-looped the service on the next reload. Most changes here
  # touch lib/.
  if ! python3 -m compileall -q "$HERDR_APP_DIR/hub.py" "$HERDR_APP_DIR/lib" >/dev/null 2>&1; then
    if [ -n "${prev:-}" ] && git -C "$HERDR_APP_DIR" checkout -q --detach --force "$prev"; then
      echo "deploy: $rev does not compile — rolled back to $prev" >&2
    else
      # Claiming a rollback that did not happen is worse than the failure.
      echo "deploy: $rev does not compile and NOTHING was rolled back —" >&2
      echo "  $HERDR_APP_DIR holds a revision that cannot start." >&2
    fi
    return 1
  fi
  find "$HERDR_APP_DIR" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
  echo "  deployed $(app_rev) $(git -C "$HERDR_APP_DIR" log -1 --format=%s | cut -c1-56)${fetched}"
}

# render_hub_plist <template> <out> — one implementation, so the suite can
# assert the RENDERED file instead of grepping install.sh for a sed expression.
render_hub_plist() {
  local tpl="$1" out="$2"
  sed -e "s|__HUB_PY__|$HERDR_APP_DIR/hub.py|" \
      -e "s|__LOG_PATH__|$HOME/Library/Logs/com.herdr-control.hub.log|g" \
    "$tpl" > "$out"
}

HERDR_SERVICES=(
  "com.herdr-control.hub|http://127.0.0.1:8600/|200 302"
  "com.herdr-control.bridge||"
  "com.herdr-control.auth-broker|http://127.0.0.1:8765/|401 200 404"
  "com.herdr-control.auth-gateway|http://127.0.0.1:4000/|401 200 404"
)
