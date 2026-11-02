#!/usr/bin/env bash
# verify-launcher-profile-identity.sh [--live]
#
# Regression test for the launcher/profile identity-handoff bug
# (2026-11-02): spawn-task.sh built --config paths from $here (wherever it
# happens to be invoked from) instead of the deployed app dir the bound
# omp launcher hardcodes as `$control`. omp-herdr-bound literal-compares
# every --config argument against its own `$control/...` paths -- content
# hash is not enough, the argument STRING must match -- so a spawn built
# from the dev checkout died "only the bound Herdr worker overlays are
# allowed" AFTER worktree/registry setup already ran, leaving a registered
# task and worktree with no live agent (a "shell").
#
# Default mode is cheap and side-effect-free: it probes the REAL installed
# bound launcher (--herdr-bound-check, no agent spawn, no write — see
# spawn-task.sh's bound_config_path header) and a spawn-task.sh --dry-run,
# proving the regression is fixed without registering a task or spawning a
# worker. --live additionally does the real thing: spawns a real
# deep-review worker, proves a live OMP process started, then closes it
# through the registered close-done-workers.sh path. Requires HERDR_OMP_BIN
# to resolve to an installed bound release; skips (not fail) if absent, so
# this runs clean in an environment with no bound launcher installed.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/config.sh"
live=0
[ "${1:-}" = --live ] && live=1

fails=0
ok()   { printf 'OK   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'SKIP %s\n' "$*"; }

if [ ! -x "$HERDR_OMP_BIN" ]; then
  skip "HERDR_OMP_BIN not installed/executable ($HERDR_OMP_BIN) — nothing to probe against"
  exit 0
fi

# ---- 1. unit: bound_config_path must exist and behave as specified ---------
# Extract and run it in isolation rather than sourcing all of spawn-task.sh
# (which has side effects from its own top-level arg parsing).
fn="$(awk '/^bound_config_path\(\) \{/,/^\}$/' "$here/spawn-task.sh")"
if [ -z "$fn" ]; then
  bad "bound_config_path() not found in spawn-task.sh"
else
  eval "$fn"
  # 1a. the configured app dir's offline-mcp profile must be ACCEPTED.
  app_cfg="$HERDR_CONTROL_APP_DIR/lib/offline-mcp-profile.yml"
  if [ -r "$app_cfg" ]; then
    got="$(bound_config_path "$app_cfg")"
    [ "$got" = "$app_cfg" ] && ok "bound_config_path accepts the configured app dir's offline-mcp profile ($app_cfg)" \
      || bad "bound_config_path rejected the configured app dir's offline-mcp profile ($app_cfg) — HERDR_CONTROL_APP_DIR drifted from the bound launcher's hardcoded \$control, or the file is stale"
  else
    bad "configured app dir's offline-mcp profile missing/unreadable: $app_cfg (HERDR_CONTROL_APP_DIR=$HERDR_CONTROL_APP_DIR)"
  fi
  # 1b. a content-identical file at a DIFFERENT path (simulating the dev
  # checkout, or any other invocation location) must be REJECTED — this is
  # the exact regression: content hash is not what the bound launcher
  # checks, the literal path is.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/lib"
  [ -r "$app_cfg" ] && cp "$app_cfg" "$tmp/lib/offline-mcp-profile.yml"
  foreign="$tmp/lib/offline-mcp-profile.yml"
  if [ -r "$foreign" ]; then
    got="$(bound_config_path "$foreign")"
    [ -z "$got" ] && ok "bound_config_path refuses a content-identical file at an unrecognized path (proves it checks the ARGUMENT STRING, not just content hash)" \
      || bad "bound_config_path accepted a foreign path ($foreign) — the bound launcher's own --config allowlist should have refused this"
  fi
  # 1c. candidate order: app dir first, here second — app dir wins when
  # both would be accepted (it's the one actually pinned in production).
  if [ -r "$app_cfg" ]; then
    got="$(bound_config_path "$app_cfg" "$foreign")"
    [ "$got" = "$app_cfg" ] && ok "bound_config_path prefers the configured app dir over a later candidate" \
      || bad "bound_config_path did not prefer the app dir candidate (got '$got')"
  fi
fi

# ---- 2. spawn-task.sh --dry-run resolves the ACCEPTED path, not $here -----
# job class 'deep-review' defaults secrets to withhold (secrets_default_for_job:
# *review* substring match), which triggers the offline-MCP profile path
# regardless of --approval mode — this is the exact job class the bug
# report named ("a registered deep-review worker").
dry_out="$(bash "$here/spawn-task.sh" --dry-run "$here" "verify-launcher-profile-identity-dry-$$" deep-review omp 2>&1)"
dry_rc=$?
if [ "$dry_rc" != 0 ]; then
  bad "spawn-task.sh --dry-run exited $dry_rc for a deep-review spawn:\n$dry_out"
else
  launch_line="$(printf '%s\n' "$dry_out" | grep '^  launch    :')"
  case "$launch_line" in
    *"--config $HERDR_CONTROL_APP_DIR/lib/offline-mcp-profile.yml"*)
      ok "deep-review --dry-run resolves --config to the bound app dir's offline-mcp profile" ;;
    *"--config $here/lib/offline-mcp-profile.yml"*)
      bad "deep-review --dry-run resolved --config to \$here ($here/lib/offline-mcp-profile.yml) instead of the bound app dir — this is the exact regression" ;;
    *)
      bad "deep-review --dry-run launch line did not contain an offline-mcp --config flag at all:\n$launch_line" ;;
  esac
fi

# ---- 3. --live: a real registered deep-review worker actually reaches OMP -
if [ "$live" = 1 ]; then
  branch="smoke/launcher-profile-identity-$$"
  out="$(bash "$here/spawn-task.sh" "$here" "$branch" deep-review omp --no-focus 2>&1)"
  rc=$?
  if [ "$rc" != 0 ]; then
    bad "--live: real spawn exited $rc:\n$out"
  else
    pane="$(printf '%s\n' "$out" | sed -n 's/.*pane=\([^ ]*\).*/\1/p')"
    task_id="$(printf '%s\n' "$out" | sed -n 's/.*task=\([^ ]*\)$/\1/p')"
    sleep 8
    status="$(herdr pane list 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
panes = d.get('result', {}).get('panes') or d.get('panes') or []
for p in panes:
    if p.get('pane_id') == '$pane':
        print(p.get('agent_status', ''))
        break
" 2>/dev/null)"
    if [ "$status" = idle ] || [ "$status" = working ]; then
      ok "--live: registered deep-review worker ($pane, $task_id) reached OMP (agent_status=$status)"
    else
      bad "--live: registered deep-review worker ($pane, $task_id) did not reach a live OMP status (agent_status='${status:-<pane not found>}')"
    fi
    wt="$HOME/.herdr/worktrees/$(basename "$(cd "$here" && git rev-parse --show-toplevel)")/$branch"
    if [ -f "$wt/.handoffs/events.jsonl" ]; then
      printf '{"event":"deep-review:%s_done","status":"completed","reason":"no-follow-on","proof":"verify-launcher-profile-identity.sh --live smoke check"}\n' "$branch" >> "$wt/.handoffs/events.jsonl"
    fi
    bash "$here/close-done-workers.sh" --apply --reason=no-follow-on >/dev/null 2>&1 || true
  fi
fi

[ $fails -eq 0 ] && { echo "PASS: 0 failing"; exit 0; } || { echo "FAIL: $fails failing"; exit 1; }
