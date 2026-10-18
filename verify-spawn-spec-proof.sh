#!/usr/bin/env bash
# verify-spawn-spec-proof.sh — proves spawn-task.sh's half of
# project-contract-plan.md item 1: every new worktree gets a `.handoffs/
# SPEC.md` (goal + acceptance + proof contract) and an empty `.handoffs/
# PROOF.md`, SPEC.md is filled from `--brief FILE` when one is passed and a
# bare template otherwise, and identity.json tells the worker where both live
# plus the closure-reason vocabulary set_task_state now enforces.
#
#   bash verify-spawn-spec-proof.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# Same herdr stub as verify-spawn-op-env.sh: a workspace/tab/pane come back
# real-shaped, and "pane run" captures the composed launch line instead of
# executing anything.
stub_dir=$(mktemp -d)
cat > "$stub_dir/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
	"tab create") printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1","terminal_id":"term1"}}}\n' ;;
	"pane run")   : ;;
	"pane list")  printf '{"result":{"panes":[]}}\n' ;;
	*)            printf '{"result":{"workspace":{"workspace_id":"w1"},"workspaces":[],"panes":[],"tabs":[]}}\n' ;;
esac
STUB
chmod +x "$stub_dir/herdr"

WT_ROOT=$(mktemp -d); WT_ROOT=$(cd "$WT_ROOT" && pwd -P)
run_spawn() {  # <branch> [extra args...]
  env HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" \
    HERDR_WT_DIR="$WT_ROOT" HERDR_RUN_STATE_DIR="$(mktemp -d)" \
    bash "$here/spawn-task.sh" "$probe_repo" "$@" quick /bin/true
}

probe_repo=$(mktemp -d); git -C "$probe_repo" init -q -b main 2>/dev/null
git -C "$probe_repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

printf '== no --brief: SPEC.md is the template, PROOF.md is empty ==\n'
run_spawn no-brief-branch >/tmp/spawn-out-$$.log 2>&1 || bad "spawn (no brief) failed: $(cat /tmp/spawn-out-$$.log)"
wt="$WT_ROOT/$(basename "$probe_repo")/no-brief-branch"
spec="$wt/.handoffs/SPEC.md"; proof="$wt/.handoffs/PROOF.md"
[ -f "$spec" ] && ok "SPEC.md written" || bad "SPEC.md missing at $spec"
[ -f "$proof" ] && ok "PROOF.md written" || bad "PROOF.md missing at $proof"
[ -s "$proof" ] && bad "PROOF.md is not empty: $(cat "$proof")" || ok "PROOF.md starts empty"
grep -q '## Goal' "$spec" 2>/dev/null && ok "template SPEC.md has a Goal section" || bad "no Goal section: $(cat "$spec" 2>/dev/null)"
grep -q '## Acceptance' "$spec" 2>/dev/null && ok "template SPEC.md has an Acceptance section" || bad "no Acceptance section"
grep -q '## Proof contract' "$spec" 2>/dev/null && ok "template SPEC.md carries the proof contract" || bad "no proof contract"
grep -q 'no-follow-on' "$spec" 2>/dev/null && ok "proof contract names the closure-reason vocabulary" || bad "vocabulary not named"

printf '== --brief FILE: SPEC.md is the brief, plus the proof contract appended ==\n'
brief_file=$(mktemp)
printf '# Do the thing\n\n## Acceptance\n- [ ] it works\n' > "$brief_file"
run_spawn brief-branch --brief "$brief_file" >/tmp/spawn-out2-$$.log 2>&1 || bad "spawn (--brief) failed: $(cat /tmp/spawn-out2-$$.log)"
wt2="$WT_ROOT/$(basename "$probe_repo")/brief-branch"
spec2="$wt2/.handoffs/SPEC.md"; proof2="$wt2/.handoffs/PROOF.md"
grep -q 'Do the thing' "$spec2" 2>/dev/null && ok "SPEC.md carries the brief's own content" || bad "brief content missing: $(cat "$spec2" 2>/dev/null)"
grep -q '## Proof contract' "$spec2" 2>/dev/null && ok "proof contract appended even when a real brief was passed" || bad "proof contract not appended to a real brief"
[ -f "$proof2" ] && [ ! -s "$proof2" ] && ok "PROOF.md still starts empty with --brief" || bad "PROOF.md wrong with --brief"

printf '== --brief pointing at a missing file refuses the spawn, nothing created ==\n'
before_dirs=$(find "$WT_ROOT/$(basename "$probe_repo")" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if run_spawn ghost-branch --brief /no/such/file >/tmp/spawn-out3-$$.log 2>&1; then
  bad "spawn with an unreadable --brief file was ACCEPTED"
else
  ok "spawn with an unreadable --brief file refused"
fi
after_dirs=$(find "$WT_ROOT/$(basename "$probe_repo")" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
check "no worktree created for the refused spawn" "$after_dirs" "$before_dirs"

printf '== re-spawn on the SAME branch: never truncates an existing PROOF.md or SPEC.md ==\n'
# Simulate a worker that already collected evidence and edited its own
# SPEC.md, then got re-spawned (a real supported path — see the worktree
# reuse branch around spawn-task.sh's "worktree: create or reuse" section).
printf 'verified: ran the suite, 12/12 passed\n' > "$proof"
printf '# SPEC\n\n## Goal\nCUSTOM-MARKER-EDITED-IN-PLACE\n' > "$spec"
run_spawn no-brief-branch >/tmp/spawn-out4-$$.log 2>&1 || bad "re-spawn (no brief) failed: $(cat /tmp/spawn-out4-$$.log)"
grep -q 'ran the suite, 12/12 passed' "$proof" 2>/dev/null \
  && ok "re-spawn without --brief leaves PROOF.md bytes untouched" \
  || bad "PROOF.md wiped by re-spawn: $(cat "$proof" 2>/dev/null)"
grep -q 'CUSTOM-MARKER-EDITED-IN-PLACE' "$spec" 2>/dev/null \
  && ok "re-spawn without --brief leaves an existing SPEC.md untouched" \
  || bad "SPEC.md replaced by re-spawn: $(cat "$spec" 2>/dev/null)"

printf '== re-spawn WITH --brief: replaces SPEC.md (a real new brief), still never touches PROOF.md ==\n'
brief_file2=$(mktemp)
printf '# A genuinely new brief\n\n## Acceptance\n- [ ] the second round\n' > "$brief_file2"
run_spawn no-brief-branch --brief "$brief_file2" >/tmp/spawn-out5-$$.log 2>&1 \
  || bad "re-spawn (--brief) failed: $(cat /tmp/spawn-out5-$$.log)"
grep -q 'A genuinely new brief' "$spec" 2>/dev/null \
  && ok "re-spawn WITH --brief does replace SPEC.md" || bad "new brief not applied: $(cat "$spec" 2>/dev/null)"
grep -q 'ran the suite, 12/12 passed' "$proof" 2>/dev/null \
  && ok "re-spawn WITH --brief still leaves PROOF.md bytes untouched" \
  || bad "PROOF.md wiped by a --brief re-spawn: $(cat "$proof" 2>/dev/null)"

printf '== --brief pointing AT the worktree'"'"'s own SPEC.md does not truncate before reading it ==\n'
printf '# SPEC\n\nSELF-REFERENTIAL-MARKER-BEFORE-RESPAWN\n' > "$spec"
run_spawn no-brief-branch --brief "$spec" >/tmp/spawn-out6-$$.log 2>&1 \
  || bad "re-spawn (--brief == own SPEC.md) failed: $(cat /tmp/spawn-out6-$$.log)"
grep -q 'SELF-REFERENTIAL-MARKER-BEFORE-RESPAWN' "$spec" 2>/dev/null \
  && ok "cat completed before the target path was ever touched — no self-truncation" \
  || bad "self-referential --brief truncated SPEC.md: $(cat "$spec" 2>/dev/null)"
grep -q '## Proof contract' "$spec" 2>/dev/null \
  && ok "proof contract still appended after the self-referential read" || bad "proof contract missing"

printf '== --brief pointing at a SPEC.md that ALREADY carries a Proof contract heading: not duplicated ==\n'
run_spawn no-brief-branch --brief "$spec" >/tmp/spawn-out7-$$.log 2>&1 \
  || bad "re-spawn (--brief == spec already containing proof contract) failed: $(cat /tmp/spawn-out7-$$.log)"
check "exactly one Proof contract heading, not duplicated" \
  "$(grep -c '## Proof contract' "$spec" 2>/dev/null)" "1"
grep -q 'SELF-REFERENTIAL-MARKER-BEFORE-RESPAWN' "$spec" 2>/dev/null \
  && ok "brief's own body content preserved" || bad "brief body lost: $(cat "$spec" 2>/dev/null)"

printf '== re-spawn into a worktree archive-worktrees.sh has locked: refused, SPEC.md untouched ==\n'
# archive-worktrees.sh --apply holds this lock across its archive-to-remove
# window (review r2 H1 of PR #236); a re-spawn writing .handoffs/ there
# would be deleted unarchived by the `git worktree remove` that follows.
git -C "$probe_repo" worktree lock --reason "archive-worktrees.sh pid 1: archiving, about to remove" "$wt"
spec_before=$(shasum -a 256 "$spec" | cut -d' ' -f1)
if run_spawn no-brief-branch --brief "$brief_file2" >/tmp/spawn-out8-$$.log 2>&1; then
  bad "re-spawn into an archive-locked worktree was ACCEPTED"
elif grep -q 'locked by an archive-worktrees.sh run' /tmp/spawn-out8-$$.log; then
  ok "re-spawn into an archive-locked worktree refused"
else
  bad "re-spawn refused for another reason: $(cat /tmp/spawn-out8-$$.log)"
fi
check "SPEC.md untouched by the refused re-spawn" "$(shasum -a 256 "$spec" | cut -d' ' -f1)" "$spec_before"
git -C "$probe_repo" worktree unlock "$wt"

printf '== identity.json tells the worker where SPEC/PROOF live and the closure vocabulary ==\n'
idjson="$wt/.handoffs/identity.json"
[ -f "$idjson" ] && ok "identity.json written" || bad "identity.json missing"
check "spec_file points at SPEC.md" "$(jq -r .spec_file "$idjson" 2>/dev/null)" "$spec"
check "proof_file points at PROOF.md" "$(jq -r .proof_file "$idjson" 2>/dev/null)" "$proof"
[ "$(jq -r '.closure_reasons | length' "$idjson" 2>/dev/null)" = "5" ] \
  && ok "closure_reasons lists all five reasons" || bad "closure_reasons wrong: $(jq -c .closure_reasons "$idjson" 2>/dev/null)"
printf '%s' "$(jq -r .how_to_complete "$idjson" 2>/dev/null)" | grep -qi 'closure reason' \
  && ok "how_to_complete explains the closure-reason requirement" || bad "how_to_complete silent on closure reasons"

printf '== --dry-run --brief FILE: spec line shows the brief path exactly once (regression) ==\n'
dryrun_brief=$(mktemp)
printf '# dry run brief\n' > "$dryrun_brief"
dryrun_out=$(env HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" \
  HERDR_WT_DIR="$WT_ROOT" HERDR_RUN_STATE_DIR="$(mktemp -d)" \
  bash "$here/spawn-task.sh" "$probe_repo" dry-brief-branch quick /bin/true --dry-run --brief "$dryrun_brief" 2>&1)
spec_line=$(printf '%s\n' "$dryrun_out" | grep '^  spec ')
occurrences=$(printf '%s' "$spec_line" | grep -o -F "$dryrun_brief" | wc -l | tr -d ' ')
check "dry-run spec line shows brief path exactly once" "$occurrences" "1"
printf '%s' "$spec_line" | grep -qF "(from --brief $dryrun_brief)" \
  && ok "dry-run spec line format matches 'from --brief <path>'" || bad "dry-run spec line malformed: $spec_line"

printf '== --dry-run with no --brief: spec line still says template — no --brief passed ==\n'
dryrun_out2=$(env HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" \
  HERDR_WT_DIR="$WT_ROOT" HERDR_RUN_STATE_DIR="$(mktemp -d)" \
  bash "$here/spawn-task.sh" "$probe_repo" dry-nobrief-branch quick /bin/true --dry-run 2>&1)
printf '%s' "$dryrun_out2" | grep -qF '(template — no --brief passed)' \
  && ok "dry-run no-brief spec line unchanged" || bad "dry-run no-brief spec line wrong: $dryrun_out2"

printf '== bashlex preflight (fix/bashlex-preflight): fresh worktree gets a working parser, or fails closed with why ==\n'
# .venv-bashlex is gitignored and relative to the worktree it runs in
# (lib/command-policy.sh _cp_bashlex_findgit_present), so a worktree
# `git worktree add` just cut never has one -- the find/git parser gate
# escalated every shaped command with no indication why until this fix.
# lib/bashlex-preflight.sh's provision_worktree_bashlex_venv is called right
# after worktree creation (spawn-task.sh, same section as the SPEC.md/
# PROOF.md writes this file already exercises above).
. "$here/lib/bashlex-preflight.sh"

# A fake `python3` that answers exactly the two invocations
# provision_worktree_bashlex_venv makes, with no real interpreter or network
# -- same stubbing technique as the herdr stub above.
make_fake_bashlex_venv() {  # <dir> <bashlex-version>
  local dir="$1" ver="$2"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/python3" <<PYSTUB
#!/usr/bin/env bash
case "\$*" in
  *importlib.metadata*) echo "$ver" ;;
  *"import bashlex"*)   exit 0 ;;
  *)                    exit 1 ;;
esac
PYSTUB
  chmod +x "$dir/bin/python3"
}

pinned_ver="$(sed -n 's/^bashlex==\([0-9.][0-9.]*\).*/\1/p' "$here/lib/bashlex-requirements.txt" | head -1)"
check "pin sanity: lib/bashlex-requirements.txt pins 0.18" "$pinned_ver" "0.18"

empty_app_dir=$(mktemp -d)  # deterministic "no deployed app" candidate for every case below

printf -- '-- case 1: shared checkout has a venv at the PINNED version -> linked, provenance records it --\n'
src1=$(mktemp -d); make_fake_bashlex_venv "$src1/.venv-bashlex" "$pinned_ver"
wt1=$(mktemp -d)
HERDR_APP_DIR="$empty_app_dir" provision_worktree_bashlex_venv "$wt1" "$src1"
bashlex_rc1=$?
check "case 1: provision returns success" "$bashlex_rc1" "0"
[ -L "$wt1/.venv-bashlex" ] && ok "case 1: worktree .venv-bashlex is a symlink" || bad "case 1: no symlink created"
check "case 1: symlink targets the shared checkout's venv" "$(readlink "$wt1/.venv-bashlex" 2>/dev/null)" "$src1/.venv-bashlex"
"$wt1/.venv-bashlex/bin/python3" -c 'import bashlex' >/dev/null 2>&1 \
  && ok "case 1: linked interpreter imports bashlex through the worktree-local path" \
  || bad "case 1: linked interpreter does not import"
grep -q "linked" "$wt1/.handoffs/bashlex-provenance.txt" 2>/dev/null \
  && ok "case 1: provenance records a link" || bad "case 1: provenance missing/wrong: $(cat "$wt1/.handoffs/bashlex-provenance.txt" 2>/dev/null)"
grep -q "$pinned_ver" "$wt1/.handoffs/bashlex-provenance.txt" 2>/dev/null \
  && ok "case 1: provenance records the matched version" || bad "case 1: version not recorded"

printf -- '-- case 2: no venv anywhere (shared checkout or deployed app) -> no link, fails closed, says why --\n'
src2=$(mktemp -d)  # no .venv-bashlex at all
wt2=$(mktemp -d)
HERDR_APP_DIR="$empty_app_dir" provision_worktree_bashlex_venv "$wt2" "$src2"
bashlex_rc2=$?
check "case 2: provision returns failure (rc!=0)" "$([ "$bashlex_rc2" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
[ -e "$wt2/.venv-bashlex" ] && bad "case 2: a symlink was created with no valid source" || ok "case 2: no symlink created"
grep -q "NOT linked" "$wt2/.handoffs/bashlex-provenance.txt" 2>/dev/null \
  && ok "case 2: provenance says NOT linked" || bad "case 2: provenance missing/wrong: $(cat "$wt2/.handoffs/bashlex-provenance.txt" 2>/dev/null)"
grep -qi "install.sh --apply" "$wt2/.handoffs/bashlex-provenance.txt" 2>/dev/null \
  && ok "case 2: provenance names the actionable fix" || bad "case 2: no actionable fix in provenance"

printf -- '-- case 3: shared checkout has a venv at the WRONG version (0.17 vs pinned %s) -> refused, no link --\n' "$pinned_ver"
src3=$(mktemp -d); make_fake_bashlex_venv "$src3/.venv-bashlex" "0.17"
wt3=$(mktemp -d)
HERDR_APP_DIR="$empty_app_dir" provision_worktree_bashlex_venv "$wt3" "$src3"
bashlex_rc3=$?
check "case 3: provision returns failure (rc!=0)" "$([ "$bashlex_rc3" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
[ -e "$wt3/.venv-bashlex" ] && bad "case 3: a symlink was created from a version-mismatched venv" || ok "case 3: no symlink created"
grep -q "0.17 != pinned $pinned_ver" "$wt3/.handoffs/bashlex-provenance.txt" 2>/dev/null \
  && ok "case 3: provenance names the exact version mismatch against lib/bashlex-requirements.txt's pin" \
  || bad "case 3: mismatch not explained: $(cat "$wt3/.handoffs/bashlex-provenance.txt" 2>/dev/null)"

printf -- "-- end-to-end: a REAL spawn-task.sh run links a fresh task worktree's .venv-bashlex --\n"
e2e_repo=$(mktemp -d); git -C "$e2e_repo" init -q -b main 2>/dev/null
git -C "$e2e_repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
make_fake_bashlex_venv "$e2e_repo/.venv-bashlex" "$pinned_ver"
env HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" HERDR_APP_DIR="$empty_app_dir" \
  HERDR_WT_DIR="$WT_ROOT" HERDR_RUN_STATE_DIR="$(mktemp -d)" \
  bash "$here/spawn-task.sh" "$e2e_repo" bashlex-e2e-branch quick /bin/true >/tmp/spawn-bashlex-e2e-$$.log 2>&1 \
  || bad "end-to-end spawn failed: $(cat /tmp/spawn-bashlex-e2e-$$.log)"
e2e_wt="$WT_ROOT/$(basename "$e2e_repo")/bashlex-e2e-branch"
[ -L "$e2e_wt/.venv-bashlex" ] && ok "end-to-end: spawn-task.sh linked .venv-bashlex into the real new worktree" \
  || bad "end-to-end: no .venv-bashlex symlink in $e2e_wt"
"$e2e_wt/.venv-bashlex/bin/python3" -c 'import bashlex' >/dev/null 2>&1 \
  && ok "end-to-end: the real worktree's linked interpreter imports bashlex" \
  || bad "end-to-end: linked interpreter broken in the real worktree"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
