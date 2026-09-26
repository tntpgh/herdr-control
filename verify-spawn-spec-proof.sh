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

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
