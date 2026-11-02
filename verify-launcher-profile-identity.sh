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

# ---- 3. regression guard: receipt parsing + close-done-workers scoping ----
# Exercises the exact parsing --live depends on against a frozen fixture of
# spawn-task.sh's real (non-dry) output shape, so a future output-format
# edit to either script breaks THIS cheap, always-on check immediately
# instead of silently breaking --live's extraction. This is the exact bug
# an earlier version shipped (independent review, PR #400): the task_id
# regex matched the literal substring "task=", which never appears in
# "task_id=..." (so task_id always came out empty), and the worktree path
# was reconstructed via `git rev-parse --show-toplevel` run from inside
# THIS script's own linked worktree -- which returns that worktree's own
# root, not the shared repo root spawn-task.sh actually used (the exact
# bug class spawn-task.sh's own repo_root() comment warns about,
# spawn-task.sh:407-411).
fixture_out='spawned deep-review:smoke/example ws=w9T tab=w9T:t1 pane=w9T:p1  [background]
  worktree: /Users/thurbs/.herdr/worktrees/herdr-control/smoke/example
  launch:   /path/to/omp --model opus ...
HERDR_SPAWN_RECEIPT task_id=task_20261102T012630Z_14770_60d75ff3994d4c43 run_id=run_20261102T012630Z_14770_a2c1dfd68b4c816b'
f_pane="$(printf '%s\n' "$fixture_out" | sed -n 's/.*pane=\([^ ]*\).*/\1/p')"
f_task="$(printf '%s\n' "$fixture_out" | sed -n 's/.*task_id=\([^ ]*\).*/\1/p')"
f_wt="$(printf '%s\n' "$fixture_out" | sed -n 's/^  worktree: //p')"
[ "$f_pane" = "w9T:p1" ] && ok "fixture: pane= extraction correct" \
  || bad "fixture: pane= extraction got '$f_pane', want w9T:p1"
[ "$f_task" = "task_20261102T012630Z_14770_60d75ff3994d4c43" ] \
  && ok "fixture: task_id= extraction correct (matches 'task_id=', not the bare 'task=' substring that never appears in real output)" \
  || bad "fixture: task_id= extraction got '$f_task', want task_20261102T012630Z_14770_60d75ff3994d4c43"
[ "$f_wt" = "/Users/thurbs/.herdr/worktrees/herdr-control/smoke/example" ] \
  && ok "fixture: worktree path read directly from spawn-task.sh's own '  worktree: ' line, never reconstructed" \
  || bad "fixture: worktree extraction got '$f_wt', want /Users/thurbs/.herdr/worktrees/herdr-control/smoke/example"
# Static source check (not just a fixture exercise): a future edit that
# drops the --pane= filter from the real close-done-workers.sh call below
# fails THIS check on every default run, not only a rare --live one.
if grep -q 'close-done-workers.sh" --apply --reason=no-follow-on --pane="\$pane"' "$here/verify-launcher-profile-identity.sh"; then
  ok "close-done-workers.sh call stays scoped to --pane=\$pane (never unscoped batch mode)"
else
  bad "close-done-workers.sh call is no longer scoped by --pane= -- this would close every OTHER eligible pane in the registry, not just this test's own canary"
fi

# ---- 4. --live: a real registered deep-review worker actually reaches OMP -
if [ "$live" = 1 ]; then
  branch="smoke/launcher-profile-identity-$$"
  out="$(bash "$here/spawn-task.sh" "$here" "$branch" deep-review omp --no-focus 2>&1)"
  rc=$?
  if [ "$rc" != 0 ]; then
    bad "--live: real spawn exited $rc:\n$out"
  else
    # Parse spawn-task.sh's OWN printed values rather than reconstructing
    # them -- a prior version of this script rebuilt the worktree path via
    # `git rev-parse --show-toplevel`, which (run from inside a linked
    # worktree, as this script itself is) returns the WORKTREE's own
    # root, not the shared repo root spawn-task.sh actually used (the
    # exact bug class spawn-task.sh's own repo_root() comment warns
    # about, spawn-task.sh:407-411) -- and matched on "task=" which
    # never appears in the real HERDR_SPAWN_RECEIPT line (it prints
    # "task_id=", not "task="), so task_id always came out empty.
    # spawn-task.sh prints `  worktree: <path>` unconditionally on a real
    # (non-dry) run (spawn-task.sh:1379) -- read that path directly.
    pane="$(printf '%s\n' "$out" | sed -n 's/.*pane=\([^ ]*\).*/\1/p')"
    task_id="$(printf '%s\n' "$out" | sed -n 's/.*task_id=\([^ ]*\).*/\1/p')"
    wt="$(printf '%s\n' "$out" | sed -n 's/^  worktree: //p')"
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
    # events.jsonl does not pre-exist at spawn time (no worker turn has run
    # yet to create it) -- `>>` creates it, so gate on the .handoffs/ DIR
    # existing (proves $wt resolved to the real worktree) rather than the
    # file, which would always be false for a freshly-spawned canary.
    if [ -n "$wt" ] && [ -d "$wt/.handoffs" ]; then
      printf '{"event":"deep-review:%s_done","status":"completed","reason":"no-follow-on","proof":"verify-launcher-profile-identity.sh --live smoke check"}\n' "$branch" >> "$wt/.handoffs/events.jsonl"
    else
      bad "--live: could not resolve the spawned worktree's .handoffs dir (parsed wt='$wt') -- not posting a completion event"
    fi
    # SCOPED to exactly this canary -- --pane=/--task= is close-done-workers.sh's
    # own documented filter (its usage header shows --task=; --pane= is the
    # "convenience form" of the same scoping, close-done-workers.sh:87-88,110-137).
    # An earlier version of this script called --apply with NO filter, which
    # is batch mode: it would close every OTHER eligible idle/clean pane in
    # the registry too, not just the one this test spawned -- unacceptable
    # blast radius for a routine regression check (independent review finding,
    # PR #400). Only attempted when $pane actually resolved.
    if [ -n "$pane" ]; then
      bash "$here/close-done-workers.sh" --apply --reason=no-follow-on --pane="$pane" >/dev/null 2>&1 || true
    fi
  fi
fi

[ $fails -eq 0 ] && { echo "PASS: 0 failing"; exit 0; } || { echo "FAIL: $fails failing"; exit 1; }
