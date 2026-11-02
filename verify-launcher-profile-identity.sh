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
# "task_id=..." (so task_id always came out empty).
fixture_out='spawned deep-review:smoke/example ws=w9T tab=w9T:t1 pane=w9T:p1  [background]
  worktree: /Users/thurbs/.herdr/worktrees/herdr-control/smoke/example
  launch:   /path/to/omp --model opus ...
HERDR_SPAWN_RECEIPT task_id=task_20261102T012630Z_14770_60d75ff3994d4c43 run_id=run_20261102T012630Z_14770_a2c1dfd68b4c816b'
f_pane="$(printf '%s\n' "$fixture_out" | sed -n 's/.*pane=\([^ ]*\).*/\1/p')"
f_task="$(printf '%s\n' "$fixture_out" | sed -n 's/.*task_id=\([^ ]*\).*/\1/p')"
[ "$f_pane" = "w9T:p1" ] && ok "fixture: pane= extraction correct" \
  || bad "fixture: pane= extraction got '$f_pane', want w9T:p1"
[ "$f_task" = "task_20261102T012630Z_14770_60d75ff3994d4c43" ] \
  && ok "fixture: task_id= extraction correct (matches 'task_id=', not the bare 'task=' substring that never appears in real output)" \
  || bad "fixture: task_id= extraction got '$f_task', want task_20261102T012630Z_14770_60d75ff3994d4c43"
# Static source checks (not just a fixture exercise) on the real --live
# code path below:
#  - the close-done-workers.sh call must stay --pane=-scoped (an earlier
#    version called --apply with no filter at all: batch mode, would close
#    every OTHER eligible pane in the registry, not just this canary);
#  - --live must never fabricate a completion event to get its own canary
#    closed. close-done-workers.sh's own closability rule for
#    --reason=no-follow-on is purely "pane idle + worktree clean + no
#    unpushed commits" (close-done-workers.sh:30-45,125-178) -- no proof,
#    no event required, no --reason=shipped/abandoned/superseded in play.
#    An earlier version wrote a synthetic `{"status":"completed",...}`
#    event into the spawned worktree's events.jsonl before closing it --
#    pure fabrication with zero functional effect on close-done-workers.sh,
#    but a forged audit record in a real events.jsonl, and a test that
#    could mask whether the close genuinely succeeded (independent review
#    finding, PR #400). The real closure outcome must be captured and
#    checked, never thrown away with `|| true`.
# These three checks scan ONLY section 4 below (sed range from the "---- 4."
# marker) -- a plain `grep -q PATTERN "$0"` would also match this check's
# own comment prose and bad-message text, which necessarily contain the
# same words, and always pass/fail regardless of what section 4 actually
# does. Scoping past this point is what makes the check real.
live_section="$(sed -n '/^# ---- 4\./,$p' "$here/verify-launcher-profile-identity.sh")"
if printf '%s' "$live_section" | grep -q 'close-done-workers.sh" --apply --reason=no-follow-on --pane="\$pane"'; then
  ok "close-done-workers.sh call stays scoped to --pane=\$pane (never unscoped batch mode)"
else
  bad "close-done-workers.sh call is no longer scoped by --pane= -- this would close every OTHER eligible pane in the registry, not just this test's own canary"
fi
if printf '%s' "$live_section" | grep -q 'events\.jsonl'; then
  bad "--live still writes to events.jsonl -- no-follow-on needs no proof/event; a fabricated completion event is a forged audit record (independent review finding, PR #400)"
else
  ok "--live never fabricates a completion event -- relies only on close-done-workers.sh's real idle+clean-worktree closability check"
fi
if printf '%s' "$live_section" | grep -q -- '|| true'; then
  bad "--live swallows a command's outcome with '|| true' -- a genuine cleanup failure would be silently hidden instead of failing the check"
else
  ok "--live captures and checks every command's real outcome (a failure fails this check, never silently swallowed)"
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
    pane="$(printf '%s\n' "$out" | sed -n 's/.*pane=\([^ ]*\).*/\1/p')"
    task_id="$(printf '%s\n' "$out" | sed -n 's/.*task_id=\([^ ]*\).*/\1/p')"
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
    # Cleanup: no completion event is posted. close-done-workers.sh's own
    # --reason=no-follow-on closability rule is purely idle pane + clean
    # worktree + no unpushed commits (close-done-workers.sh:30-45) -- this
    # canary does zero work, so it already satisfies that honestly, with
    # no proof and no --reason=shipped/abandoned/superseded in play
    # (close-done-workers.sh:125-178 only gates those three). An earlier
    # version of this script invented a synthetic status:completed record
    # for a task that never did anything -- a forged audit entry with no
    # functional effect on the close, caught by independent review of
    # PR #400. SCOPED to exactly this canary via --pane= (close-done-
    # workers.sh:87-88,110-137) -- an earlier version called --apply with
    # no filter at all, which is batch mode and would close every OTHER
    # eligible pane in the registry too. The outcome is captured and
    # checked below, never discarded: a cleanup failure must fail this
    # check, not vanish.
    if [ -z "$pane" ]; then
      bad "--live: no pane id was parsed from spawn-task.sh's output -- cannot clean up the canary"
    else
      close_out="$(bash "$here/close-done-workers.sh" --apply --reason=no-follow-on --pane="$pane" 2>&1)"
      close_rc=$?
      case "$close_out" in
        *"closed 1, held back 0, refused 0"*)
          ok "--live: canary $pane closed cleanly (close-done-workers.sh --reason=no-follow-on --pane=$pane)" ;;
        *)
          bad "--live: close-done-workers.sh did not cleanly close its own canary $pane (rc=$close_rc):\n$close_out" ;;
      esac
    fi
  fi
fi

[ $fails -eq 0 ] && { echo "PASS: 0 failing"; exit 0; } || { echo "FAIL: $fails failing"; exit 1; }
