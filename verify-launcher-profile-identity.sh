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
# Default mode is CI-safe: sections 1-3 build their OWN stub launcher and
# an isolated copy of this checkout (same technique verify-offline-mcp-
# profile.sh uses for its own launcher-adjacent checks) rather than
# depending on the real installed $HERDR_OMP_BIN, which does not exist on
# CI/ubuntu-latest -- an earlier version of this script exited SKIP
# immediately when that binary was absent, so CI never actually exercised
# bound_config_path() or the --dry-run resolution at all (independent
# review finding, PR #400). No network, no secrets, no real spawn, no
# write outside $WORK (removed on exit).
#
# --live additionally does the real thing, against the REAL installed
# launcher: spawns a real deep-review worker, proves a live OMP process
# started, then closes it through the registered close-done-workers.sh
# path with the outcome actually checked (never --live without this:
# close-done-workers.sh settles its registry row BEFORE it even attempts
# the physical `herdr pane close`, so a non-zero close-done-workers.sh
# exit, or a pane that is still live afterward, must fail this check --
# trusting its printed "closed N" text alone is not proof, an independent
# review finding, PR #400). Skips (not fail) if HERDR_OMP_BIN is absent.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/config.sh"
live=0
[ "${1:-}" = --live ] && live=1

fails=0
ok()   { printf 'OK   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'SKIP %s\n' "$*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. unit: bound_config_path, against a STUB launcher (CI-safe) --------
# Extract and run it in isolation rather than sourcing all of spawn-task.sh
# (which has side effects from its own top-level arg parsing). The stub
# implements exactly the one contract bound_config_path() relies on --
# `<bin> --herdr-bound-check --config <path>` exits 0 iff <path> is the
# one path it was told to accept -- the same shape the real omp-herdr-
# bound wrapper's --config allowlist has, minus its hash-pin machinery,
# which bound_config_path() never reads.
fn="$(awk '/^bound_config_path\(\) \{/,/^\}$/' "$here/spawn-task.sh")"
if [ -z "$fn" ]; then
  bad "bound_config_path() not found in spawn-task.sh"
else
  eval "$fn"
  accept="$WORK/accepted/offline-mcp-profile.yml"
  mkdir -p "$(dirname "$accept")"; printf 'accepted-content\n' > "$accept"
  foreign="$WORK/foreign/offline-mcp-profile.yml"
  mkdir -p "$(dirname "$foreign")"; cp "$accept" "$foreign"  # content-IDENTICAL, path differs
  stub="$WORK/stub-omp"
  cat > "$stub" << STUBEOF
#!/bin/sh
[ "\$1" = --herdr-bound-check ] && [ "\$2" = --config ] && [ "\$3" = "$accept" ] && exit 0
exit 78
STUBEOF
  chmod +x "$stub"
  HERDR_OMP_BIN="$stub"
  got="$(bound_config_path "$accept")"
  [ "$got" = "$accept" ] && ok "bound_config_path accepts the path the stub launcher names" \
    || bad "bound_config_path rejected the path the stub launcher accepts"
  got="$(bound_config_path "$foreign")"
  [ -z "$got" ] && ok "bound_config_path refuses a content-identical file at an unrecognized path (proves it checks the ARGUMENT STRING, not just content hash)" \
    || bad "bound_config_path accepted a foreign path ($foreign) the stub launcher should have refused"
  got="$(bound_config_path "$accept" "$foreign")"
  [ "$got" = "$accept" ] && ok "bound_config_path prefers an earlier accepted candidate over a later one" \
    || bad "bound_config_path did not prefer the first accepted candidate (got '$got')"
fi

# ---- 2. integration: spawn-task.sh --dry-run resolves the ACCEPTED path, --
# ---- not $here, against an ISOLATED copy (CI-safe) -------------------------
# job class 'deep-review' defaults secrets to withhold (secrets_default_for_job:
# *review* substring match), which triggers the offline-MCP profile path
# regardless of --approval mode -- this is the exact job class the bug
# report named ("a registered deep-review worker").
#
# $ctl: an isolated copy of THIS checkout, playing the role of "wherever
# spawn-task.sh happens to be invoked from" -- the exact wrong location the
# bug report named (a dev checkout). $app_dir: a SEPARATE directory holding
# a content-identical lib/offline-mcp-profile.yml, playing the role of the
# real deployed app dir the bound launcher hardcodes. A stub launcher
# pinned into $ctl/config.sh accepts ONLY the $app_dir copy. Neither the
# real installed launcher nor the real ~/.local/share/herdr-control/app is
# touched or required to exist (same reasoning as section 1, and the same
# isolated-copy technique verify-offline-mcp-profile.sh already uses).
ctl="$WORK/ctl"; mkdir -p "$ctl"
git -C "$here" archive HEAD | tar -x -C "$ctl"
probe_repo="$WORK/probe_repo"; mkdir -p "$probe_repo"; git -C "$probe_repo" init -q 2>/dev/null
app_dir="$WORK/app_dir"; mkdir -p "$app_dir/lib"
cp "$ctl/lib/offline-mcp-profile.yml" "$app_dir/lib/offline-mcp-profile.yml"
ctl_stub="$WORK/ctl-stub-omp"
cat > "$ctl_stub" << STUBEOF
#!/bin/sh
[ "\$1" = --herdr-bound-check ] && [ "\$2" = --config ] && [ "\$3" = "$app_dir/lib/offline-mcp-profile.yml" ] && exit 0
exit 78
STUBEOF
chmod +x "$ctl_stub"
ctl_stub_sha="$(shasum -a 256 "$ctl_stub" | awk '{print $1}')"
old_bin_line="$(grep -m1 '^HERDR_OMP_BIN=' "$ctl/config.sh")"
old_sha_line="$(grep -m1 '^HERDR_OMP_LAUNCHER_SHA256=' "$ctl/config.sh")"
if [ -z "$old_bin_line" ] || [ -z "$old_sha_line" ]; then
  bad "could not find HERDR_OMP_BIN/HERDR_OMP_LAUNCHER_SHA256 pins in \$ctl/config.sh to rewire for the isolated test"
else
  ctl_cfg="$(cat "$ctl/config.sh")"
  ctl_cfg="${ctl_cfg//$old_bin_line/HERDR_OMP_BIN=\"$ctl_stub\"}"
  ctl_cfg="${ctl_cfg//$old_sha_line/HERDR_OMP_LAUNCHER_SHA256=\"$ctl_stub_sha\"}"
  printf '%s\n' "$ctl_cfg" > "$ctl/config.sh"
  dry_out="$(HERDR_CONTROL_APP_DIR="$app_dir" HERDR_RUN_STATE_DIR="$WORK/state" \
    bash "$ctl/spawn-task.sh" --dry-run "$probe_repo" "verify-launcher-profile-identity-dry-$$" deep-review omp 2>&1)"
  dry_rc=$?
  if [ "$dry_rc" != 0 ]; then
    bad "spawn-task.sh --dry-run exited $dry_rc for a deep-review spawn:\n$dry_out"
  else
    launch_line="$(printf '%s\n' "$dry_out" | grep '^  launch    :')"
    case "$launch_line" in
      *"--config $app_dir/lib/offline-mcp-profile.yml"*)
        ok "deep-review --dry-run resolves --config to the bound app dir's offline-mcp profile, not \$here" ;;
      *"--config $ctl/lib/offline-mcp-profile.yml"*)
        bad "deep-review --dry-run resolved --config to \$here (the isolated dev-checkout copy) instead of the bound app dir — this is the exact regression" ;;
      *)
        bad "deep-review --dry-run launch line did not contain an offline-mcp --config flag at all:\n$launch_line" ;;
    esac
  fi
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
#  - the close-done-workers.sh call must stay bound to both --task= (the
#    precise identifier) and --pane= (the pane_birth-disambiguated
#    convenience form, close-done-workers.sh:87-88,110-137) -- an earlier
#    version called --apply with no filter at all: batch mode, would close
#    every OTHER eligible pane in the registry, not just this canary;
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
# These checks scan ONLY section 4 below (sed range from the "---- 4."
# marker) -- a plain `grep -q PATTERN "$0"` would also match this check's
# own comment prose and bad-message text, which necessarily contain the
# same words, and always pass/fail regardless of what section 4 actually
# does. Scoping past this point is what makes the check real.
live_section="$(sed -n '/^# ---- 4\./,$p' "$here/verify-launcher-profile-identity.sh")"
if printf '%s' "$live_section" | grep -q -- '--task="\$task_id" --pane="\$pane"'; then
  ok "close-done-workers.sh call binds BOTH --task=\$task_id and --pane=\$pane (never unscoped batch mode)"
else
  bad "close-done-workers.sh call no longer binds --task=/--pane= together — this would close every OTHER eligible pane in the registry, not just this test's own canary"
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
if printf '%s' "$live_section" | grep -q -- '\[ "\$close_rc" = 0 \]'; then
  ok "--live requires close_rc=0 explicitly, not just a text match on close-done-workers.sh's own summary line"
else
  bad "--live no longer requires close_rc=0 -- close-done-workers.sh settles its registry row BEFORE attempting the physical pane close (close-done-workers.sh:766-797), so its own exit code and summary text are not proof the pane actually closed; trusting them alone is the exact gap independent review found in PR #400"
fi
if printf '%s' "$live_section" | grep -q 'post_status="\$(pane_status_now'; then
  ok "--live independently re-queries herdr for the target pane's live status after closing, rather than trusting close-done-workers.sh's own report"
else
  bad "--live does not independently verify the target pane is actually absent after closing — close-done-workers.sh can report success while the physical pane close silently failed (independent review finding, PR #400)"
fi

# ---- 4. --live: a real registered deep-review worker actually reaches OMP -
if [ "$live" = 1 ]; then
  if [ ! -x "$HERDR_OMP_BIN" ]; then
    skip "--live: HERDR_OMP_BIN not installed/executable ($HERDR_OMP_BIN) — nothing to spawn against"
  else
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
      pane_status_now() {  # <pane_id> -> herdr's current agent_status for it, or empty
        herdr pane list 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
panes = d.get('result', {}).get('panes') or d.get('panes') or []
for p in panes:
    if p.get('pane_id') == '$1':
        print(p.get('agent_status', ''))
        break
" 2>/dev/null
      }
      status="$(pane_status_now "$pane")"
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
      # PR #400. Bound to exactly this canary via BOTH --task= (the precise
      # identifier) and --pane= (pane_birth-disambiguated convenience form,
      # close-done-workers.sh:87-88,110-137).
      #
      # close-done-workers.sh settles its registry row to `completed` BEFORE
      # it even attempts the physical `herdr pane close` (close-done-
      # workers.sh:766-797, by design -- a stale `running` row forever is
      # worse) -- its own "closed N" text and exit code are proof the
      # REGISTRY accepted the transition, not proof the pane itself is
      # actually gone (independent review finding, PR #400; the same PR
      # also fixed close-done-workers.sh to WARN and fail its own run on a
      # genuine pane-close failure instead of discarding that exit code).
      # Trust neither alone: require close_rc=0 AND independently re-query
      # herdr afterward for the pane's own live status.
      if [ -z "$pane" ] || [ -z "$task_id" ]; then
        bad "--live: pane ('$pane') or task_id ('$task_id') was not parsed from spawn-task.sh's output -- cannot clean up the canary"
      else
        close_out="$(bash "$here/close-done-workers.sh" --apply --reason=no-follow-on --task="$task_id" --pane="$pane" 2>&1)"
        close_rc=$?
        if [ "$close_rc" = 0 ]; then
          ok "--live: close-done-workers.sh exited 0 for canary $pane/$task_id"
        else
          bad "--live: close-done-workers.sh exited $close_rc for canary $pane/$task_id:\n$close_out"
        fi
        post_status="$(pane_status_now "$pane")"
        if [ -z "$post_status" ]; then
          ok "--live: canary $pane confirmed ABSENT from herdr after close-done-workers.sh --apply (independently re-queried, not trusting its own report)"
        else
          bad "--live: canary $pane is still LIVE after close-done-workers.sh --apply (agent_status=$post_status) — the registry row settled but the physical pane close did not take; close it by hand"
        fi
      fi
    fi
  fi
fi

[ $fails -eq 0 ] && { echo "PASS: 0 failing"; exit 0; } || { echo "FAIL: $fails failing"; exit 1; }
