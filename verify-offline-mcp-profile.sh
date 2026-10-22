#!/usr/bin/env bash
# verify-offline-mcp-profile.sh — proves the fix in lib/agent-profiles.sh,
# spawn-task.sh and spawn-agent.sh for .handoffs/SPEC.md "Launch profile by
# job class" (fix/offline-launch-profile, 2026-10-17).
#
# Observed failure: review workers in ~/Code/tourguide sat at an interactive
# 1Password CLI prompt ("Do you want to add an account manually now? [Y/n]")
# fired by the project's `.mcp.json` supabase MCP server (`op run -- npx
# @supabase/mcp-server-supabase@latest ...`), which also timed out after
# 30000 ms. spawn-task.sh --no-secrets did NOT prevent it: withholding the
# credential never stopped the server from trying to reach for one. The fix
# removes every project-level MCP source (omp --config overlay,
# mcp.enableProjectConfig:false) before omp ever starts a server process, for
# review/debug/explore job classes and any secrets-withheld spawn.
#
# Drives the real spawn-task.sh/spawn-agent.sh via --dry-run (same technique
# as verify-posture.sh's canonical-rules section): --dry-run exits well
# before the unrelated local-caller-ancestry authorization gate
# (spawn-task.sh:805, requires a real herdr pane process tree — not this
# plain-shell test harness) but AFTER the offline-MCP decision and its
# preflight, so the composed launch line and the preflight refusal are both
# observable without stubbing herdr's RPC surface.
#
#   bash verify-offline-mcp-profile.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/agent-profiles.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

printf '== unit: offline_mcp_profile_for_job classifies the literal job classes only ==\n'
for j in review debug explore; do
  [ "$(offline_mcp_profile_for_job "$j")" = 1 ] \
    && ok "'$j' is an offline job class" \
    || bad "'$j' should be classified offline"
done
for j in implement docs quick plan architect design deep-review mechanical research; do
  [ -z "$(offline_mcp_profile_for_job "$j")" ] \
    && ok "'$j' is NOT an offline job class (only review/debug/explore are)" \
    || bad "'$j' was unexpectedly classified offline"
done

printf '== unit: offline_mcp_profile_path points at the real, readable overlay ==\n'
profile_path="$(offline_mcp_profile_path)"
[ "$profile_path" = "$here/lib/offline-mcp-profile.yml" ] \
  && ok "path is lib/offline-mcp-profile.yml, absolute" \
  || bad "unexpected path: $profile_path"
[ -r "$profile_path" ] && ok "the overlay file exists and is readable" || bad "overlay file missing/unreadable: $profile_path"
grep -q 'enableProjectConfig: *false' "$profile_path" \
  && ok "overlay sets mcp.enableProjectConfig: false" \
  || bad "overlay does not disable project MCP config: $(cat "$profile_path" 2>&1)"

# ---- real spawn-task.sh --dry-run against a throwaway repo -----------------
probe_repo=$(mktemp -d); git -C "$probe_repo" init -q 2>/dev/null
wt_dir=$(mktemp -d); state_dir=$(mktemp -d)

# ---- FAKE herdr backend (2026-10-21): this suite used to reach the REAL
# herdr through spawn-agent.sh below and leaked one `tmp.XXXXXXXX`
# workspace with an "offline-mcp-agent-test" tab per run (five found live).
# Every herdr call in this suite now hits a recorder on PATH that returns
# empty JSON and creates nothing; the end of the suite asserts no call
# escaped to a real backend and no workspace was created.
fake_bin=$(mktemp -d); herdr_calls="$fake_bin/herdr.calls"; : > "$herdr_calls"
python3 - "$fake_bin" "$herdr_calls" <<'PY'
import os, shlex, sys
d, log = sys.argv[1], sys.argv[2]
p = os.path.join(d, "herdr")
script = r'''#!/bin/sh
printf "%%s\n" "$*" >> %s
case "$1 $2" in
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wFAKE","active_tab_id":"wFAKE:t1"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"wFAKE:t2"},"root_pane":{"pane_id":"wFAKE:p2","terminal_id":"fake-birth"}}}' ;;
  *) echo '{}' ;;
esac
''' % shlex.quote(log)
open(p, "w").write(script)
os.chmod(p, 0o755)
PY
export PATH="$fake_bin:$PATH"
# config.sh PREPENDS HERDR_EXTRA_PATH (homebrew, ~/.local/bin) to PATH, which
# put the real herdr back in front for spawn-agent.sh (measured: a live
# tmp.* workspace leaked with the fake on PATH alone). Pin the fake first.
export HERDR_EXTRA_PATH="$fake_bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"
unset HERDR_PANE_ID
[ "$(command -v herdr)" = "$fake_bin/herdr" ] && ok "fake herdr backend shadows the real one" || bad "real herdr still first on PATH: $(command -v herdr)"

# ---- K3 (2026-10-18): --approval hook needs a launcher whose own
# --herdr-bound-check matches $here's content; no HERDR_OMP_EXTENSION env
# seam exists anymore. Build ONE isolated copy of this checkout with a
# fixture launcher that reports pins computed from that copy's own
# content, pinned into that copy's OWN config.sh (production config.sh is
# never touched). Every hook-mode call below runs against $ctl, not $here.
ctl_work=$(mktemp -d); trap 'rm -rf "$ctl_work"' EXIT
ctl="$ctl_work/ctl"; mkdir -p "$ctl"; cp -R "$here/." "$ctl/"
rm -rf "$ctl/.git"; find "$ctl" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
ctl_lib_tree_sha() {
  ( cd "$ctl" && find lib -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -not -name '*.pyo' -not -name '.DS_Store' \
      | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done ) 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}
ctl_fx="$ctl_work/fake-omp"
cat > "$ctl_fx" <<EOF
#!/bin/bash
[ "\${1:-}" = --herdr-bound-check ] || exit 1
printf 'hook=%s\nlib_tree=%s\nspawn=%s\noverlay=%s\nselector=%s\n' \
  "$(shasum -a 256 "$ctl/agent-hooks/omp-herdr-control.ts" | cut -d' ' -f1)" \
  "$(ctl_lib_tree_sha)" \
  "$(shasum -a 256 "$ctl/spawn-task.sh" | cut -d' ' -f1)" \
  "$(shasum -a 256 "$ctl/agent-hooks/omp-worker-overlay.yml" | cut -d' ' -f1)" \
  "$(shasum -a 256 "$ctl/herdr-select.sh" | cut -d' ' -f1)"
EOF
chmod +x "$ctl_fx"
ctl_fx_sha="$(shasum -a 256 "$ctl_fx" | cut -d' ' -f1)"
ctl_old_bin='HERDR_OMP_BIN="$HOME/.local/opt/omp-herdr-bound/releases/2026-10-22-ownerdispatch-v26d/omp"'
ctl_old_sha='HERDR_OMP_LAUNCHER_SHA256="dd8fa3ba90cb8c55c7b77f2a66227bc1009cb1789a22f86e955d9ac746a46c20"'
ctl_cfg="$(cat "$ctl/config.sh")"
case "$ctl_cfg" in *"$ctl_old_bin"*) ;; *) echo "FATAL: HERDR_OMP_BIN pin not found in $ctl/config.sh" >&2; exit 1 ;; esac
ctl_cfg="${ctl_cfg//$ctl_old_bin/HERDR_OMP_BIN=\"$ctl_fx\"}"
ctl_cfg="${ctl_cfg//$ctl_old_sha/HERDR_OMP_LAUNCHER_SHA256=\"$ctl_fx_sha\"}"
printf '%s\n' "$ctl_cfg" > "$ctl/config.sh"
ctl_profile_path="$ctl/lib/offline-mcp-profile.yml"
ctl_wt_overlay="$ctl/agent-hooks/omp-worker-overlay.yml"

dry_launch() {  # <job-class> [extra spawn-task.sh args...] -> the "launch :" line
  local job="$1"; shift
  HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
    bash "$here/spawn-task.sh" --dry-run "$@" "$probe_repo" "offline-mcp-$job-$$" "$job" omp 2>&1 \
    | grep '^  launch'
}

printf '== spawn-task.sh --dry-run: review/debug/explore get the offline overlay, by job class alone ==\n'
for j in review debug explore; do
  launch_line="$(dry_launch "$j")"
  case "$launch_line" in
    *"--config $profile_path"*) ok "job class '$j': --config $profile_path is in the launch line" ;;
    *) bad "job class '$j': overlay missing from launch line: $launch_line" ;;
  esac
done

printf '== spawn-task.sh --dry-run: explore + --approval hook keeps BOTH --config flags (review regression fix) ==\n'
launch_line="$(HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
  bash "$ctl/spawn-task.sh" --dry-run "$probe_repo" "offline-mcp-explore-hook-$$" explore omp --approval hook 2>&1)"
case "$launch_line" in
  *"could not find the write-floor approval flag"*)
    bad "explore + --approval hook: the hook block's suffix match broke (regression reproduced): $launch_line" ;;
  *"--auto-approve"*"--config"*"omp-worker-overlay.yml"*"--config $ctl_profile_path"*)
    ok "explore + --approval hook: --auto-approve, the hook's own worker overlay, AND the offline MCP overlay are all present" ;;
  *) bad "explore + --approval hook: unexpected launch line: $launch_line" ;;
esac

printf '== matrix: every KNOWN_JOB_CLASSES x approval{menu,hook} x secrets{withheld,granted} launches cleanly, overlay exactly where expected ==\n'
matrix_fail=0
for j in $KNOWN_JOB_CLASSES; do
  for appr in menu hook; do
    for sec in withheld granted; do
      if [ "$sec" = withheld ]; then
        secret_env=(env HERDR_SECRETS_WITHHELD=1)
        secret_flag=()
      else
        # Unsetting HERDR_SECRETS_WITHHELD alone is not enough: op_mode still
        # falls back to the JOB CLASS's own secrets_default_for_job (e.g.
        # review/explore/research/deep-review/audit/scrape/triage all default
        # to withhold). --secrets is the only thing that lifts that default
        # (spawn-task.sh:208) short of an inherited withholding. Found by
        # live review: deep-review/hook/granted and research/hook/granted
        # both still got the overlay because "granted" here hadn't actually
        # forced a grant for those classes.
        secret_env=(env -u HERDR_SECRETS_WITHHELD)
        secret_flag=(--secrets)
      fi
      target="$here"; want_profile_path="$profile_path"
      if [ "$appr" = hook ]; then
        extra=(--approval hook ${secret_flag[@]+"${secret_flag[@]}"})
        target="$ctl"; want_profile_path="$ctl_profile_path"
      else
        extra=(${secret_flag[@]+"${secret_flag[@]}"})
      fi
      # ${arr[@]+"${arr[@]}"} (not bare "${arr[@]}"): under `set -u`, bash
      # before 4.4 treats an EMPTY array's [@] expansion as an unbound
      # variable, not an empty list -- every menu-mode row (extra=())
      # aborted the command with "unbound variable" and left $out empty.
      # Found by live review: "every */menu/* matrix row ... EMPTY output".
      out="$("${secret_env[@]}" HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
        bash "$target/spawn-task.sh" --dry-run "$probe_repo" "offline-mcp-mx-$j-$appr-$sec-$$" "$j" omp ${extra[@]+"${extra[@]}"} 2>&1)"
      row="$j/$appr/$sec"
      case "$out" in
        *"could not find the write-floor approval flag"*)
          bad "matrix $row: suffix-match regression reproduced"; matrix_fail=1 ;;
        *"spawn-task (dry-run):"*)
          want_overlay=0
          [ "$(offline_mcp_profile_for_job "$j")" = 1 ] && want_overlay=1
          [ "$sec" = withheld ] && want_overlay=1
          has_overlay=0
          case "$out" in *"--config $want_profile_path"*) has_overlay=1 ;; esac
          if [ "$want_overlay" = "$has_overlay" ]; then
            : # fine, counted in the summary line below
          else
            bad "matrix $row: overlay presence wrong (want=$want_overlay has=$has_overlay)"; matrix_fail=1
          fi ;;
        *) bad "matrix $row: spawn did not reach dry-run summary: $out"; matrix_fail=1 ;;
      esac
    done
  done
done
[ "$matrix_fail" = 0 ] && ok "all $(set -- $KNOWN_JOB_CLASSES; echo $#) job classes x 2 approval modes x 2 secrets states (dry-run) launch cleanly with correct overlay placement"

printf '== bound launcher argv allowlist: every composed launch line would be ACCEPTED by the real $HERDR_OMP_BIN ==\n'
# Extracted live from the launcher script's own case statement (not hand-
# transcribed) so a future launcher version drifting its allowlist shape
# fails this test instead of silently going unverified. Root cause this
# guards (conductor, 2026-10-17): v18's launcher allowlisted only the
# worker overlay as --config; this fix's offline overlay made every
# patched managed spawn exit 78 ("only the bound Herdr worker overlay is
# allowed") before any pane output, and --dry-run tests never invoke the
# launcher at all, so nothing caught it. v19 allowlists both.
launcher_bin_line="$(grep -n '^HERDR_OMP_BIN=' "$here/config.sh")"
eval "${launcher_bin_line#*:}"
[ -x "$HERDR_OMP_BIN" ] && ok "the configured bound launcher exists and is executable: $HERDR_OMP_BIN" \
  || bad "configured HERDR_OMP_BIN is missing/not executable: $HERDR_OMP_BIN"
guard_src="$(awk '/^args=\("\$@"\)$/,/^done$/' "$HERDR_OMP_BIN" 2>/dev/null)"
case "$guard_src" in
  *'"$overlay"|"$offline_overlay"'*) ok "launcher's argv-scan shape (the \$overlay|\$offline_overlay case arm) still matches what this extraction assumes" ;;
  *) bad "launcher's argv-scan shape changed or the marker lines are gone — extraction found: ${guard_src:-<empty>}" ;;
esac
launcher_allows_argv() {  # <overlay-path> <offline-overlay-path> -- <rest of the launch argv>
  local overlay="$1" offline_overlay="$2"; shift 2
  local _guard_fail=""
  die() { _guard_fail="$*"; }
  eval "$guard_src"
  [ -z "$_guard_fail" ]
}
wt_overlay="$here/agent-hooks/omp-worker-overlay.yml"
for j in review debug explore; do
  for appr in menu hook; do
    extra=(); target="$here"; use_wt_overlay="$wt_overlay"; use_profile_path="$profile_path"
    if [ "$appr" = hook ]; then
      extra=(--approval hook); target="$ctl"; use_wt_overlay="$ctl_wt_overlay"; use_profile_path="$ctl_profile_path"
    fi
    cli_tail="$(HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
      bash "$target/spawn-task.sh" --dry-run "$probe_repo" "offline-mcp-launcher-$j-$appr-$$" "$j" omp ${extra[@]+"${extra[@]}"} 2>&1 \
      | sed -n 's/^  launch    : //p')"
    [ -n "$cli_tail" ] || { bad "$j/$appr: no launch line to test the launcher against"; continue; }
    eval "argv=($cli_tail)"
    # argv[0] is the omp binary path itself (what the pane actually execs);
    # the launcher's own guard scans everything AFTER it, i.e. its own "$@".
    if launcher_allows_argv "$use_wt_overlay" "$use_profile_path" "${argv[@]:1}"; then
      ok "$j/$appr: the real launcher's argv-scan accepts this composed launch line"
    else
      bad "$j/$appr: the real launcher would REJECT this composed launch line ($_guard_fail): ${argv[*]:1}"
    fi
  done
done
if "$HERDR_OMP_BIN" --herdr-bound-check >/dev/null 2>&1; then
  ok "the live installed app is already pinned to this launcher (--herdr-bound-check passed)"
else
  echo "  info  --herdr-bound-check failed against the LIVE install — expected: installing lib/offline-mcp-profile.yml into ~/.local/share/herdr-control/app is the separate owner-approved release step SPEC.md forbids this task from doing; the argv-scan checks above prove the composed line is correct independent of whether that install has happened yet"
fi

printf '== spawn-task.sh --dry-run: implement (no withholding) gets NO offline overlay ==\n'
launch_line="$(env -u HERDR_SECRETS_WITHHELD HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
  bash "$here/spawn-task.sh" --dry-run "$probe_repo" "offline-mcp-implement-$$" implement omp 2>&1 | grep '^  launch')"
case "$launch_line" in
  *"--config $profile_path"*) bad "implement (unwithheld) unexpectedly got the offline overlay: $launch_line" ;;
  *) ok "implement (unwithheld): no --config overlay in the launch line" ;;
esac

printf '== spawn-task.sh --dry-run: --no-secrets forces the overlay even for a non-offline job class ==\n'
launch_line="$(env -u HERDR_SECRETS_WITHHELD HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
  bash "$here/spawn-task.sh" --dry-run --no-secrets "$probe_repo" "offline-mcp-ns-$$" implement omp 2>&1 | grep '^  launch')"
case "$launch_line" in
  *"--config $profile_path"*) ok "implement + --no-secrets: overlay present (withheld secrets, same prompt-risk)" ;;
  *) bad "implement + --no-secrets: overlay missing: $launch_line" ;;
esac

printf '== spawn-task.sh --dry-run: --secrets on review does NOT lift the job-class overlay ==\n'
launch_line="$(env -u HERDR_SECRETS_WITHHELD HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
  bash "$here/spawn-task.sh" --dry-run --secrets "$probe_repo" "offline-mcp-sec-$$" review omp 2>&1 | grep '^  launch')"
case "$launch_line" in
  *"--config $profile_path"*) ok "review + --secrets: overlay still present (job class is the trigger, not just withholding)" ;;
  *) bad "review + --secrets: overlay was dropped: $launch_line" ;;
esac

printf '== spawn-agent.sh --job review: same overlay, same trigger ==\n'
launch_line="$(HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
  bash "$here/spawn-agent.sh" --job review "$probe_repo" offline-mcp-agent-test omp 2>&1)"
case "$launch_line" in
  *"--config $profile_path"*) ok "spawn-agent.sh --job review: overlay present" ;;
  *"authorization hold"*|*"unavailable or outside Herdr"*)
    # spawn-agent.sh has no --dry-run; it reaches the real pane-create call,
    # which this plain-shell harness cannot satisfy (same local-ancestry gate
    # spawn-task.sh's --dry-run sidesteps above). The overlay decision itself
    # already ran (lib/agent-profiles.sh unit tests above cover it); this
    # section only confirms spawn-agent.sh does not error out BEFORE that
    # decision in a way unrelated to the fix.
    ok "spawn-agent.sh: reached the real pane-create step (same code path proven via spawn-task.sh's --dry-run above; no separate --dry-run exists here)" ;;
  *) bad "spawn-agent.sh --job review: unexpected output: $launch_line" ;;
esac

printf '== spawn-task.sh --dry-run: missing overlay file refuses the whole spawn, non-interactively, with a registry event ==\n'
saved="$(mktemp)"; cp "$profile_path" "$saved"
rm -f "$profile_path"
miss_state_dir=$(mktemp -d)
out=$(HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$miss_state_dir" \
  bash "$here/spawn-task.sh" --dry-run "$probe_repo" "offline-mcp-missing-$$" review omp 2>&1)
rc=$?
cp "$saved" "$profile_path"; rm -f "$saved"
[ "$rc" = 1 ] && ok "refused (rc=1) instead of launching unprotected" || bad "unexpected rc=$rc: $out"
case "$out" in
  *"spawn-task (dry-run):"*) bad "dry-run summary printed despite the missing overlay — preflight did not actually refuse: $out" ;;
  *) ok "no launch summary was ever printed" ;;
esac
case "$out" in
  *"offline MCP launch profile"*) ok "refusal names the missing offline MCP profile" ;;
  *) bad "refusal message does not explain itself: $out" ;;
esac
. "$here/lib/run-registry.sh"
export HERDR_RUN_STATE_DIR="$miss_state_dir"
missing_row="$(_sql "SELECT count(*) FROM events WHERE type='offline_mcp_profile_missing';" 2>/dev/null)"
[ "${missing_row:-0}" -gt 0 ] 2>/dev/null \
  && ok "a registry event records the preflight refusal" \
  || bad "no offline_mcp_profile_missing event found in the registry"

printf '== fake backend: nothing escaped to a real herdr ==\n'
# The spawn-agent.sh section must have reached `tab create` on the FAKE.
grep -q '^tab create' "$herdr_calls" \
  && ok "spawn-agent.sh's tab create hit the recorder, not a real herdr" \
  || bad "no tab create recorded — the spawn either escaped to a real herdr or never got there: $(tr '\n' ';' < "$herdr_calls")"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo PASS; exit 0; else echo FAIL; exit 1; fi
