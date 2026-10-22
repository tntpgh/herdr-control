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
# NO-SPAWN CONTRACT (2026-10-22: run from inside a herdr pane, the old
# spawn-agent.sh probe created a REAL workspace + omp pane, twice). This script
# never executes spawn-agent.sh, the real bound launcher, or any spawn script
# in $here. Every subprocess and write path, exhaustively:
#   - sourced pure functions: $here/lib/agent-profiles.sh (unit section) and
#     $ctl/lib/run-registry.sh (final read of a TEMP registry);
#   - mktemp dirs under $TMPDIR (stub dir, probe repo, worktree dir, state
#     dirs, isolated copy $ctl): all removed by the EXIT trap;
#   - git init / rev-parse ONLY inside the temp probe repo;
#   - cp -R $here -> $ctl (reads $here, writes temp); $ctl/config.sh is
#     rewritten to point at a FAKE launcher in temp; the missing-overlay case
#     deletes the overlay in $ctl, never in $here;
#   - `bash $ctl/spawn-task.sh --dry-run ...` only (the isolated copy). It reads
#     git/config, writes run-registry events to a temp HERDR_RUN_STATE_DIR and,
#     in hook mode, runs the FAKE launcher;
#   - read-only grep/awk/sed/shasum of $here files, incl. the real launcher's
#     SOURCE text (read, never executed) and spawn-agent.sh's source (static
#     assertion, never executed).
# Subprocess boundary: a stub dir is FIRST on PATH for herdr, omp, op, npx,
# claude and codex; the script refuses to run unless each resolves to its stub.
# `herdr pane list` / `herdr workspace list` return EMPTY JSON (the real herdr
# is never called); every other stub call is a VIOLATION (exit 97). Any
# VIOLATION fails the run, so any spawn attempt is a test failure.
# HERDR_PANE_ID / _WORKSPACE_ID / _TAB_ID are unset first.
#
#   bash verify-offline-mcp-profile.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/agent-profiles.sh"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID

# Temp dirs are created and registered in THIS shell (never inside $(...), whose
# array append would be lost). cleanup removes only paths that are directories
# directly under the mktemp root and named tmp.*; anything else is reported, kept.
tmp_root=$(cd "${TMPDIR:-/tmp}" && pwd -P)
tmp_paths=()
cleanup() {
  local d
  for d in ${tmp_paths[@]+"${tmp_paths[@]}"}; do
    case "$d" in
      "$tmp_root"/tmp.*) [ -d "$d" ] && [ "$(dirname "$d")" = "$tmp_root" ] && rm -rf -- "$d" ;;
      *) echo "cleanup: refusing unexpected path $d" >&2 ;;
    esac
  done
}
trap cleanup EXIT
mk_tmp() {  # mk_tmp <varname>: mktemp -d under $tmp_root, registered in this shell
  local d; d=$(mktemp -d "$tmp_root/tmp.XXXXXXXXXX") || { echo "FATAL: mktemp failed" >&2; exit 2; }
  tmp_paths+=("$d"); printf -v "$1" '%s' "$d"
}

mk_tmp stub_dir; stub_log="$stub_dir/calls.log"; : > "$stub_log"
for b in omp op npx claude codex; do
  printf '#!/bin/bash\nprintf "VIOLATION %s %%s\\n" "$*" >> %q\nexit 97\n' "$b" "$stub_log" > "$stub_dir/$b"
done
cat > "$stub_dir/herdr" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "pane list") printf 'herdr %s\\n' "\$*" >> "$stub_log"; echo '{"result":{"panes":[]}}' ;;
  "workspace list") printf 'herdr %s\\n' "\$*" >> "$stub_log"; echo '{"result":{"workspaces":[]}}' ;;
  *) printf 'VIOLATION herdr %s\\n' "\$*" >> "$stub_log"; exit 97 ;;
esac
EOF
chmod 700 "$stub_dir"/*
# Child environment, exported ONCE so every child inherits it:
# - config.sh prepends $HERDR_EXTRA_PATH to PATH, so the stub dir must lead it;
# - state/cache go to temp dirs; OP_ENV_FILE is an empty temp file (names only,
#   never the real service-account file); HERDR_CANONICAL_RULES is unset.
mk_tmp child_state; mk_tmp child_cache
op_env_tmp="$child_state/op-env-empty"; : > "$op_env_tmp"
export HERDR_EXTRA_PATH="$stub_dir:/opt/homebrew/bin:/usr/local/bin"
export PATH="$stub_dir:$PATH"
export HERDR_STATE_DIR="$child_state" XDG_CACHE_HOME="$child_cache" OP_ENV_FILE="$op_env_tmp"
unset HERDR_CANONICAL_RULES
for b in herdr omp op npx claude codex; do
  [ "$(command -v "$b")" = "$stub_dir/$b" ] || { echo "FATAL: subprocess boundary not in effect for $b; refusing to run" >&2; exit 2; }
done

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

# ---- isolated spawn-task.sh --dry-run ($ctl copy only) against a temp repo ---
mk_tmp probe_repo; git -C "$probe_repo" init -q 2>/dev/null
mk_tmp wt_dir; mk_tmp state_dir

# ---- K3 (2026-10-18): --approval hook needs a launcher whose own
# --herdr-bound-check matches $here's content; no HERDR_OMP_EXTENSION env
# seam exists anymore. Build ONE isolated copy of this checkout with a
# fixture launcher that reports pins computed from that copy's own
# content, pinned into that copy's OWN config.sh (production config.sh is
# never touched). Every hook-mode call below runs against $ctl, not $here.
mk_tmp ctl_work
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
child_check="$(bash -c '. "$1/config.sh" >/dev/null 2>&1
  for b in herdr omp op npx claude codex; do printf "%s=%s\n" "$b" "$(command -v "$b")"; done
  printf "HERDR_STATE_DIR=%s\nXDG_CACHE_HOME=%s\nOP_ENV_FILE=%s\nCANON=%s\n" "$HERDR_STATE_DIR" "$XDG_CACHE_HOME" "$OP_ENV_FILE" "${HERDR_CANONICAL_RULES:-}"' _ "$ctl")"
want_check="$(for b in herdr omp op npx claude codex; do printf '%s=%s\n' "$b" "$stub_dir/$b"; done
  printf 'HERDR_STATE_DIR=%s\nXDG_CACHE_HOME=%s\nOP_ENV_FILE=%s\nCANON=\n' "$child_state" "$child_cache" "$op_env_tmp")"
[ "$child_check" = "$want_check" ] || { printf 'FATAL: boundary not in effect inside a config-sourced child:\n%s\n' "$child_check" >&2; exit 2; }
ctl_wt_overlay="$ctl/agent-hooks/omp-worker-overlay.yml"

dry_launch() {  # <job-class> [extra spawn-task.sh args...] -> the "launch :" line
  local job="$1"; shift
  HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
    bash "$ctl/spawn-task.sh" --dry-run "$@" "$probe_repo" "offline-mcp-$job-$$" "$job" omp 2>&1 \
    | grep '^  launch'
}

printf '== spawn-task.sh --dry-run: review/debug/explore get the offline overlay, by job class alone ==\n'
for j in review debug explore; do
  launch_line="$(dry_launch "$j")"
  case "$launch_line" in
    *"--config $ctl_profile_path"*) ok "job class '$j': --config $ctl_profile_path is in the launch line" ;;
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
      want_profile_path="$ctl_profile_path"
      if [ "$appr" = hook ]; then
        extra=(--approval hook ${secret_flag[@]+"${secret_flag[@]}"})
      else
        extra=(${secret_flag[@]+"${secret_flag[@]}"})
      fi
      # ${arr[@]+"${arr[@]}"} (not bare "${arr[@]}"): under `set -u`, bash
      # before 4.4 treats an EMPTY array's [@] expansion as an unbound
      # variable, not an empty list -- every menu-mode row (extra=())
      # aborted the command with "unbound variable" and left $out empty.
      # Found by live review: "every */menu/* matrix row ... EMPTY output".
      out="$("${secret_env[@]}" HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
        bash "$ctl/spawn-task.sh" --dry-run "$probe_repo" "offline-mcp-mx-$j-$appr-$sec-$$" "$j" omp ${extra[@]+"${extra[@]}"} 2>&1)"
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
# Guard source, two modes (OFFLINE_MCP_GUARD_SOURCE):
#   installed (default, Mac): extract from the configured bound launcher AND
#     require it to equal the checked-in fixture (drift = FAIL).
#   fixture (CI only): use tests/fixtures/launcher-argv-guard.v26d.sh, pinned by
#     digest. Proves the CONTRACT only; it says nothing about the installed wrapper.
# Every load fails closed: missing/empty/shape-wrong/digest-mismatch = no guard.
guard_fixture="$here/tests/fixtures/launcher-argv-guard.v26d.sh"
guard_fixture_sha=fe11df1da5b9daae025256c10b12bc68ab2b1a2c41b89d889e3ba1ac3eacabbd
guard_block_of() {  # <file>: the argv-scan block (fixture header lines dropped)
  [ -f "$1" ] || return 1
  awk '/^args=\("\$@"\)$/,/^done$/' "$1" 2>/dev/null
}
guard_shape_ok() {  # <block>
  case "$1" in
    'args=("$@")'*'"$overlay"|"$offline_overlay"'*done) return 0 ;;
    *) return 1 ;;
  esac
}
guard_digest() { printf '%s\n' "$1" | shasum -a256 | cut -c1-64; }
load_fixture_guard() {  # <file> <pinned-sha>: prints block, nonzero on any defect
  local b; b="$(guard_block_of "$1")" || return 1
  [ -n "$b" ] && guard_shape_ok "$b" && [ "$(guard_digest "$b")" = "$2" ] || return 1
  printf '%s' "$b"
}
guard_src=""
fixture_src="$(load_fixture_guard "$guard_fixture" "$guard_fixture_sha")" \
  && ok "guard fixture present, shape ok, digest pinned ($guard_fixture_sha)" \
  || bad "guard fixture missing/empty/wrong shape/digest mismatch: $guard_fixture"
case "${OFFLINE_MCP_GUARD_SOURCE:-installed}" in
  fixture)
    printf '  note  FIXTURE MODE (CI): the installed launcher is NOT checked; contract only\n'
    guard_src="$fixture_src" ;;
  installed)
    launcher_bin_line="$(grep -n '^HERDR_OMP_BIN=' "$here/config.sh")"
    eval "${launcher_bin_line#*:}"
    [ -x "$HERDR_OMP_BIN" ] && ok "the configured bound launcher exists and is executable: $HERDR_OMP_BIN" \
      || bad "configured HERDR_OMP_BIN is missing/not executable: $HERDR_OMP_BIN"
    inst_src="$(guard_block_of "$HERDR_OMP_BIN")" || inst_src=""
    if [ -n "$inst_src" ] && guard_shape_ok "$inst_src"; then
      ok "launcher's argv-scan shape (the \$overlay|\$offline_overlay case arm) still matches what this extraction assumes"
      guard_src="$inst_src"
      [ "$inst_src" = "$fixture_src" ] && ok "installed launcher argv-scan == checked-in fixture" \
        || bad "installed launcher argv-scan differs from the fixture (refresh the fixture from a reviewed release)"
    else
      bad "launcher's argv-scan shape changed or the marker lines are gone — extraction found: ${inst_src:-<empty>}"
    fi ;;
  *) bad "unknown OFFLINE_MCP_GUARD_SOURCE=${OFFLINE_MCP_GUARD_SOURCE}" ;;
esac
launcher_allows_argv() {  # <overlay-path> <offline-overlay-path> -- <rest of the launch argv>
  # Evaluated in a subshell where die EXITS, as in the launcher; any error
  # (incl. set -u on a missing --config value) is a denial: fail closed.
  _guard_fail=""
  [ -n "$guard_src" ] || { _guard_fail="no guard source loaded (fail closed)"; return 1; }
  _guard_fail="$( overlay="$1" offline_overlay="$2"; shift 2
    die() { printf '%s' "$*"; exit 78; }
    eval "$guard_src" 2>/dev/null; exit 0 )" && return 0
  _guard_fail="${_guard_fail:-guard evaluation error}"; return 1
}

printf '== guard contract: deny/allow cases (pure; no launcher invoked) ==\n'
gov=/x/overlay.yml; goff=/x/offline.yml
launcher_allows_argv "$gov" "$goff" --config "$gov" -p hi && ok "allow: --config <worker overlay>" || bad "deny of a valid --config <worker overlay>: $_guard_fail"
launcher_allows_argv "$gov" "$goff" --config "$goff" && ok "allow: --config <offline overlay>" || bad "deny of a valid --config <offline overlay>: $_guard_fail"
for neg in "--config /x/other.yml" "--config" "--config=/x/overlay.yml" "--profile p" "--profile=p" "--no-extensions" \
           "-e x" "-ex" "--extension x" "--extension=x" "--hook h" "--hook=h" "--plugin-dir d" "--plugin-dir=d" "--plugin-url u" "--plugin-url=u"; do
  # shellcheck disable=SC2086
  launcher_allows_argv "$gov" "$goff" $neg && bad "guard ALLOWED forbidden argv: $neg" || ok "deny: $neg"
done
saved_guard="$guard_src"; guard_src=""
launcher_allows_argv "$gov" "$goff" --config "$gov" && bad "empty guard allowed argv (must fail closed)" || ok "empty guard fails closed"
guard_src="$saved_guard"
mk_tmp guard_neg
load_fixture_guard "$guard_neg/absent.sh" "$guard_fixture_sha" >/dev/null && bad "missing fixture loaded" || ok "missing fixture fails closed"
: > "$guard_neg/empty.sh"
load_fixture_guard "$guard_neg/empty.sh" "$guard_fixture_sha" >/dev/null && bad "empty fixture loaded" || ok "empty fixture fails closed"
printf '%s\n' "$fixture_src" | awk '{ sub(/only the bound/, "only THE bound"); print }' > "$guard_neg/tampered.sh"
load_fixture_guard "$guard_neg/tampered.sh" "$guard_fixture_sha" >/dev/null && bad "tampered fixture loaded" || ok "tampered fixture: digest mismatch fails closed"
load_fixture_guard "$guard_fixture" 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null && bad "wrong pin accepted" || ok "wrong pinned digest fails closed"
printf 'args=("$@")\nfor x in; do :\ndone\n' > "$guard_neg/shape.sh"
load_fixture_guard "$guard_neg/shape.sh" "$(guard_digest "$(guard_block_of "$guard_neg/shape.sh")")" >/dev/null && bad "wrong-shape guard loaded" || ok "wrong-shape guard fails closed even with a matching digest"
wt_overlay="$here/agent-hooks/omp-worker-overlay.yml"
for j in review debug explore; do
  for appr in menu hook; do
    extra=(); use_wt_overlay="$ctl_wt_overlay"; use_profile_path="$ctl_profile_path"
    if [ "$appr" = hook ]; then
      extra=(--approval hook)
    fi
    cli_tail="$(HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
      bash "$ctl/spawn-task.sh" --dry-run "$probe_repo" "offline-mcp-launcher-$j-$appr-$$" "$j" omp ${extra[@]+"${extra[@]}"} 2>&1 \
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
# The real launcher is never EXECUTED here (no --herdr-bound-check): its pins are
# a release-time check (verify-launcher-release.sh), not part of this suite.

printf '== spawn-task.sh --dry-run: implement (no withholding) gets NO offline overlay ==\n'
launch_line="$(env -u HERDR_SECRETS_WITHHELD HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
  bash "$ctl/spawn-task.sh" --dry-run "$probe_repo" "offline-mcp-implement-$$" implement omp 2>&1 | grep '^  launch')"
case "$launch_line" in
  *"--config $ctl_profile_path"*) bad "implement (unwithheld) unexpectedly got the offline overlay: $launch_line" ;;
  *) ok "implement (unwithheld): no --config overlay in the launch line" ;;
esac

printf '== spawn-task.sh --dry-run: --no-secrets forces the overlay even for a non-offline job class ==\n'
launch_line="$(env -u HERDR_SECRETS_WITHHELD HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
  bash "$ctl/spawn-task.sh" --dry-run --no-secrets "$probe_repo" "offline-mcp-ns-$$" implement omp 2>&1 | grep '^  launch')"
case "$launch_line" in
  *"--config $ctl_profile_path"*) ok "implement + --no-secrets: overlay present (withheld secrets, same prompt-risk)" ;;
  *) bad "implement + --no-secrets: overlay missing: $launch_line" ;;
esac

printf '== spawn-task.sh --dry-run: --secrets on review does NOT lift the job-class overlay ==\n'
launch_line="$(env -u HERDR_SECRETS_WITHHELD HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$state_dir" \
  bash "$ctl/spawn-task.sh" --dry-run --secrets "$probe_repo" "offline-mcp-sec-$$" review omp 2>&1 | grep '^  launch')"
case "$launch_line" in
  *"--config $ctl_profile_path"*) ok "review + --secrets: overlay still present (job class is the trigger, not just withholding)" ;;
  *) bad "review + --secrets: overlay was dropped: $launch_line" ;;
esac

printf '== spawn-agent.sh --job review: same overlay rule (STATIC source assertion; spawn-agent.sh is never executed) ==\n'
# spawn-agent.sh has no --dry-run: executing it reaches real workspace/pane
# creation. Assert instead, from its source text, that its launch composition
# applies the SAME selector (offline_mcp_profile_for_job / withheld secrets)
# and appends the SAME overlay path as spawn-task.sh, and that it refuses when
# the overlay is unreadable.
sa_src="$(cat "$here/spawn-agent.sh")"
case "$sa_src" in
  *'. "$here/lib/agent-profiles.sh"'*) ok "spawn-agent.sh sources lib/agent-profiles.sh (same selector functions)" ;;
  *) bad "spawn-agent.sh no longer sources lib/agent-profiles.sh" ;;
esac
case "$sa_src" in
  *'"$(offline_mcp_profile_for_job "$job_class")" = 1 ] || [ "$op_mode" = withhold ]'*) ok "spawn-agent.sh gates the overlay on offline_mcp_profile_for_job OR withheld secrets" ;;
  *) bad "spawn-agent.sh overlay condition changed (static assertion found no job-class/withhold gate)" ;;
esac
case "$sa_src" in
  *'offline_mcp_cfg="$(offline_mcp_profile_path)"'*'cli="$cli --config $(printf '"'"'%q'"'"' "$offline_mcp_cfg")"'*) ok "spawn-agent.sh appends --config <offline_mcp_profile_path> to the launch line" ;;
  *) bad "spawn-agent.sh no longer appends the offline overlay via offline_mcp_profile_path" ;;
esac
case "$sa_src" in
  *"requires the offline MCP launch profile, but it is missing or unreadable"*) ok "spawn-agent.sh refuses when the overlay is missing/unreadable" ;;
  *) bad "spawn-agent.sh missing-overlay refusal text not found" ;;
esac

printf '== run registry interpreter: canonical resolver, positive and negative (no registry is opened) ==\n'
# Cause of the 2026-10-22 CI red (run 39797211751): lib/run-registry.sh pins
# python3.11+ via launchd/resolve-hub-python.sh, which searches only
# ${HERDR_HUB_PYTHON_DIRS:-/opt/homebrew/bin:/usr/local/bin}; with none found,
# registry_init refuses and spawn-task swallows append_event's error, so the
# event never lands. Name that cause here instead of as a missing event.
resolver="$ctl/launchd/resolve-hub-python.sh"
res_py="$(bash "$resolver" </dev/null 2>/dev/null)"; res_rc=$?
[ "$res_rc" = 0 ] && [ -n "$res_py" ] && [ -x "$res_py" ] \
  && ok "resolver emits an executable python3.11+: $res_py" \
  || bad "resolver found no python3.11+ (rc=$res_rc, out='${res_py}'); registry events cannot be recorded (set HERDR_HUB_PYTHON_DIRS)"
mk_tmp no_py_dir
neg_py="$(HERDR_HUB_PYTHON_DIRS="$no_py_dir" bash "$resolver" </dev/null 2>/dev/null)"; neg_rc=$?
[ "$neg_rc" != 0 ] && [ -z "$neg_py" ] \
  && ok "causal: resolver refuses with no python3.11+ on HERDR_HUB_PYTHON_DIRS (the CI cause)" \
  || bad "resolver accepted an empty HERDR_HUB_PYTHON_DIRS (rc=$neg_rc, out='$neg_py')"

# run_bounded <secs> <outfile> <cmd...>: stdin /dev/null, stdout+stderr to
# <outfile>; returns the command's rc, or 124 after killing it on timeout.
# ceiling: kills the direct child only, not grandchildren; enough to keep this
# suite from hanging, and a timeout is itself a FAIL.
run_bounded() {
  local secs="$1" outf="$2" pid n=0; shift 2
  "$@" </dev/null >"$outf" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    [ "$n" -ge $((secs * 5)) ] && { kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
    sleep 0.2; n=$((n + 1))
  done
  wait "$pid"
}

printf '== spawn-task.sh --dry-run: missing overlay file refuses the whole spawn, non-interactively, with a registry event ==\n'
mk_tmp saved_dir; saved="$saved_dir/overlay.yml"; cp "$ctl_profile_path" "$saved"
rm -f "$ctl_profile_path"
mk_tmp miss_state_dir
mk_tmp miss_io
[ -z "$(ls -A "$miss_state_dir")" ] && [ -n "$(find "$miss_state_dir" -maxdepth 0 -perm 700)" ] \
  && ok "registry root is an exact empty private (0700) temp dir: $miss_state_dir" \
  || bad "registry root not empty/0700 before the dry-run: $miss_state_dir"
run_bounded 60 "$miss_io/spawn.out" env HERDR_WT_DIR="$wt_dir" HERDR_RUN_STATE_DIR="$miss_state_dir" \
  bash "$ctl/spawn-task.sh" --dry-run "$probe_repo" "offline-mcp-missing-$$" review omp
rc=$?
out="$(cat "$miss_io/spawn.out")"
cp "$saved" "$ctl_profile_path"
[ "$rc" = 124 ] && bad "stage spawn-task: dry-run did not finish in 60s (killed); output so far: $out"
[ "$rc" = 1 ] && ok "refused (rc=1) instead of launching unprotected" || bad "unexpected rc=$rc: $out"
case "$out" in
  *"spawn-task (dry-run):"*) bad "dry-run summary printed despite the missing overlay — preflight did not actually refuse: $out" ;;
  *) ok "no launch summary was ever printed" ;;
esac
case "$out" in
  *"offline MCP launch profile"*) ok "refusal names the missing offline MCP profile" ;;
  *) bad "refusal message does not explain itself: $out" ;;
esac
if [ -f "$miss_state_dir/registry.sqlite3" ]; then
  run_bounded 20 "$miss_io/event.out" env HERDR_RUN_STATE_DIR="$miss_state_dir" bash -c \
    '. "$1/lib/run-registry.sh" && _sql "SELECT count(*) FROM events WHERE type='"'"'offline_mcp_profile_missing'"'"';"' _ "$ctl"
  erc=$?; missing_row="$(cat "$miss_io/event.out")"
  if [ "$erc" = 124 ]; then bad "stage event-read: registry query did not finish in 20s (killed)"
  elif [ "$erc" != 0 ]; then bad "stage event-read: query failed rc=$erc: $missing_row"
  elif [ "${missing_row:-0}" -gt 0 ] 2>/dev/null; then ok "a registry event records the preflight refusal"
  else bad "stage event-write: registry exists but has no offline_mcp_profile_missing event (got '$missing_row')"
  fi
else
  bad "stage registry-init: spawn-task created no registry at $miss_state_dir (append_event failed silently; see the resolver check above)"
fi

printf '== subprocess boundary: no spawn/launcher/provider call was attempted ==\n'
if grep -q '^VIOLATION' "$stub_log"; then
  bad "stubbed command(s) were called: $(grep '^VIOLATION' "$stub_log" | sort | uniq -c | tr '\n' ';')"
else
  ok "0 VIOLATION calls; herdr read stubs answered $(grep -c '^herdr ' "$stub_log") list call(s) with empty JSON"
fi

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo PASS; exit 0; else echo FAIL; exit 1; fi
