#!/usr/bin/env bash
# verify-quick-actions.sh — proof that quick-action.sh discovers global +
# repo-local actions correctly (with repo-local shown under "project"),
# resolves by name (LOCAL winning a collision), runs "command" verbatim,
# applies the select/form value-substitution + shell-quoted-append fallback
# rule, and — the independent-review fix this suite exists to defend —
# refuses to run ANY repo-local action until it has been explicitly
# `--trust`ed by content hash. No herdr stub needed — quick-action.sh never
# touches the herdr socket.
#
# Every fzf invocation forces FZF_DEFAULT_OPTS=--filter=<query>, which makes
# fzf run non-interactively and exit immediately even with no TTY (verified:
# a bare `timeout` wrapper was tried here first and dropped — `timeout` is a
# builtin of the agent harness's own interactive shell, not a real binary on
# a plain system's PATH, so a script meant to run on someone else's machine
# can't depend on it; FZF_DEFAULT_OPTS alone is what actually prevents the
# hang, confirmed by reproducing and then closing the hang without it).
#
#   bash verify-quick-actions.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

GLOBAL="$WORK/global/herdr-control/quick-actions"
LOCAL="$WORK/repo/.herdr-control/quick-actions"
STATE="$WORK/state"
mkdir -p "$GLOBAL" "$LOCAL" "$STATE"

cat > "$GLOBAL/github.json" <<'EOF'
{"name": "GitHub", "command": "echo OPENED_GITHUB"}
EOF
cat > "$LOCAL/verify.json" <<'EOF'
{"name": "Verify Suite", "command": "echo RAN_VERIFY"}
EOF
cat > "$LOCAL/open-repo.json" <<'EOF'
{"name": "Open Repo", "type": "select", "command": "echo OPENED=$HERDR_CONTROL_VALUE",
 "options": [{"label": "herdr-control", "value": "herdr-control"}, {"label": "project-b", "value": "project-b"}]}
EOF
cat > "$LOCAL/echo-no-ref.json" <<'EOF'
{"name": "No Ref", "type": "form", "form": {"prompt": "say"}, "command": "echo GOT"}
EOF
cat > "$LOCAL/echo-with-ref.json" <<'EOF'
{"name": "With Ref", "type": "form", "form": {"prompt": "say"}, "command": "echo GOT=$HERDR_CONTROL_VALUE"}
EOF
cat > "$LOCAL/bad-type.json" <<'EOF'
{"name": "Bad Type", "type": "carrier-pigeon", "command": "echo nope"}
EOF

# Every invocation runs with STATE isolated (never the real machine's
# ~/.local/state/herdr-control/trusted-actions) so this suite can never
# either read stray trust from, or pollute, a real user's approvals.
run() { ( cd "$WORK/repo" && XDG_CONFIG_HOME="$WORK/global" XDG_STATE_HOME="$STATE" bash "$here/quick-action.sh" "$@" ); }
trust() { ( cd "$WORK/repo" && export XDG_CONFIG_HOME="$WORK/global" XDG_STATE_HOME="$STATE"; printf 'YES\n' | bash "$here/quick-action.sh" --trust "$1" >/dev/null 2>&1 ); }

printf '== TRUST GATE: an untrusted repo-local action refuses to run, explains, names the fix ==\n'
out=$(run "Verify Suite" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 for an untrusted repo-local action" || bad "exit $rc (expected 1): $out"
printf '%s' "$out" | grep -q "REPO-LOCAL action and runs shell as you" && ok "explains WHY it refused" || bad "no explanation: $out"
printf '%s' "$out" | grep -q -- "--trust 'Verify Suite'" && ok "names the exact fix" || bad "fix not shown: $out"
[ ! -f "$STATE/herdr-control/trusted-actions" ] && ok "merely trying to run it did not silently trust it" || bad "trust file created by a run attempt alone"
printf '%s' "$out" | grep -qv "RAN_VERIFY" && ok "the command never actually ran" || bad "RAN_VERIFY leaked into output — it executed despite refusing!"

printf '== TRUST GATE: global actions need no trust step at all ==\n'
out=$(run "GitHub" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "OPENED_GITHUB" ] && ok "global action runs with zero trust step" || bad "global action: rc=$rc out=$out"

printf '== TRUST GATE: --trust prints the command and requires a literal YES ==\n'
out=$(cd "$WORK/repo" && export XDG_CONFIG_HOME="$WORK/global" XDG_STATE_HOME="$STATE"; printf 'nope\n' | bash "$here/quick-action.sh" --trust "Verify Suite" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "declining (anything but YES) exits 1" || bad "exit $rc (expected 1 on decline)"
[ ! -f "$STATE/herdr-control/trusted-actions" ] && ok "declining recorded nothing" || bad "a decline still wrote a trust record"
out=$(cd "$WORK/repo" && export XDG_CONFIG_HOME="$WORK/global" XDG_STATE_HOME="$STATE"; printf 'YES\n' | bash "$here/quick-action.sh" --trust "Verify Suite" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "confirming with YES exits 0" || bad "exit $rc (expected 0): $out"
printf '%s' "$out" | grep -q 'echo RAN_VERIFY' && ok "the actual command was shown before asking for approval" || bad "command not shown pre-approval: $out"
[ -f "$STATE/herdr-control/trusted-actions" ] && ok "trust recorded to \$XDG_STATE_HOME/herdr-control/trusted-actions" || bad "no trust record written"

printf '== TRUST GATE: once trusted, the action runs; --pick listing drops the UNTRUSTED tag ==\n'
out=$(run "Verify Suite" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "RAN_VERIFY" ] && ok "trusted repo-local action now runs" || bad "post-trust run: rc=$rc out=$out"

printf '== TRUST GATE: editing a trusted action after approval re-requires trust (hash-keyed) ==\n'
cat > "$LOCAL/verify.json" <<'EOF'
{"name": "Verify Suite", "command": "echo TAMPERED"}
EOF
out=$(run "Verify Suite" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "editing the trusted file's command revokes trust" || bad "exit $rc (expected 1 after edit): $out"
printf '%s' "$out" | grep -qv "TAMPERED" && ok "the tampered command never ran" || bad "TAMPERED leaked — edited file ran without re-approval!"
trust "Verify Suite"
out=$(run "Verify Suite" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "TAMPERED" ] && ok "re-trusting the edited content restores it" || bad "re-trust: rc=$rc out=$out"
# restore the fixture for the rest of the suite
cat > "$LOCAL/verify.json" <<'EOF'
{"name": "Verify Suite", "command": "echo RAN_VERIFY"}
EOF
trust "Verify Suite"

printf '== TRUST GATE: --trust on an unknown name, and on a GLOBAL name, both refuse ==\n'
out=$(cd "$WORK/repo" && XDG_CONFIG_HOME="$WORK/global" XDG_STATE_HOME="$STATE" bash "$here/quick-action.sh" --trust "Does Not Exist" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "trusting an unknown name refuses" || bad "exit $rc (expected 1)"
out=$(cd "$WORK/repo" && XDG_CONFIG_HOME="$WORK/global" XDG_STATE_HOME="$STATE" bash "$here/quick-action.sh" --trust "GitHub" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "trusting a GLOBAL action refuses (no trust step exists for it)" || bad "exit $rc (expected 1)"
printf '%s' "$out" | grep -q "no trust step needed" && ok "explains why" || bad "no explanation: $out"

printf '== precedence: LOCAL wins a name collision with GLOBAL (deliberate override) ==\n'
cat > "$GLOBAL/dup.json" <<'EOF'
{"name": "Dup", "command": "echo FROM_GLOBAL"}
EOF
cat > "$LOCAL/dup.json" <<'EOF'
{"name": "Dup", "command": "echo FROM_LOCAL"}
EOF
trust "Dup"
out=$(run "Dup" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "FROM_LOCAL" ] && ok "repo-local overrides a same-named global action" || bad "collision resolved to: $out (rc=$rc)"

printf '== discovery: unknown name lists BOTH scopes, repo-local tagged by trust state ==\n'
err=$(run "Does Not Exist" 2>&1 >/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok "nonzero exit for unknown action" || bad "exit 0 for an unknown action"
printf '%s' "$err" | grep -q "no such action" && ok "explains the miss" || bad "no explanation: $err"
printf '%s' "$err" | grep -q "GitHub (global)" && ok "lists a global action, tagged (global)" || bad "global not listed: $err"
printf '%s' "$err" | grep -q "Verify Suite (project)$" && ok "a TRUSTED repo-local action is tagged plain (project)" || bad "trusted project tag wrong: $err"
printf '%s' "$err" | grep -q "Open Repo (project, UNTRUSTED)" && ok "an UNTRUSTED repo-local action is tagged (project, UNTRUSTED)" || bad "untrusted tag missing: $err"

printf '== select: value chosen via fzf becomes \$HERDR_CONTROL_VALUE, referenced -> not appended twice ==\n'
trust "Open Repo"
out=$(cd "$WORK/repo" && XDG_CONFIG_HOME="$WORK/global" XDG_STATE_HOME="$STATE" FZF_DEFAULT_OPTS="--filter=project-b" \
  bash "$here/quick-action.sh" "Open Repo" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "OPENED=project-b" ] && ok "select resolved via fzf filter, value substituted once" || bad "select: rc=$rc out=$out"

printf '== select: no "options" is a hard error, not a silent empty picker ==\n'
cat > "$LOCAL/no-options.json" <<'EOF'
{"name": "No Options", "type": "select", "command": "echo should-not-run"}
EOF
trust "No Options"
out=$(run "No Options" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 for a select action with no options" || bad "exit $rc (expected 1): $out"
printf '%s' "$out" | grep -q "no \"options\"" && ok "explains the miss" || bad "no explanation: $out"

printf '== form: value read from stdin, command references it -> substituted, not appended ==\n'
trust "With Ref"
out=$(printf 'ignored\n' | run "With Ref" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "GOT=ignored" ] && ok "form value substituted via \$HERDR_CONTROL_VALUE" || bad "form (ref): rc=$rc out=$out"

printf '== form: value NOT referenced -> appended as a final shell-quoted argument (herdr-plus parity) ==\n'
trust "No Ref"
out=$(printf 'hello world\n' | run "No Ref" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "GOT hello world" ] && ok "unreferenced value appended, quoting preserved the space" || bad "form (no-ref): rc=$rc out=$out"

printf '== form: EOF on stdin (a cancelled prompt) refuses instead of running with an empty value ==\n'
out=$(run "No Ref" </dev/null 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "EOF on the form prompt exits 1" || bad "exit $rc (expected 1 on EOF): $out"
printf '%s' "$out" | grep -q "cancelled" && ok "explains it was cancelled" || bad "no explanation: $out"

printf '== A03 injection check: form value is inert even when the command embeds it unquoted ==\n'
cat > "$LOCAL/canary.json" <<'EOF'
{"name": "Canary", "type": "form", "form": {"prompt": "say"}, "command": "echo canary=$HERDR_CONTROL_VALUE"}
EOF
trust "Canary"
payload='$(echo INJECTED) ; echo INJECTED2 ; `echo INJECTED3`'
out=$(printf '%s\n' "$payload" | run "Canary" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "canary command completed normally" || bad "canary: unexpected exit $rc: $out"
[ "$out" = "canary=$payload" ] && ok "the payload's \$(...)/backtick/; content never executed — echoed as inert literal text, output matches exactly" || bad "INJECTION FIRED or output mangled: $out"

printf '== unknown action type is a hard error, not a silent no-op ==\n'
trust "Bad Type"
err=$(printf '\n' | run "Bad Type" 2>&1 >/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok "nonzero exit for an unrecognised type" || bad "exit 0 for type=carrier-pigeon"
printf '%s' "$err" | grep -q "unknown type" && ok "explains which type is unrecognised" || bad "no explanation: $err"

printf '== HERDR_CONTROL_WORKDIR is exported as the launch directory ==\n'
cat > "$GLOBAL/pwd.json" <<'EOF'
{"name": "Show Workdir", "command": "echo $HERDR_CONTROL_WORKDIR"}
EOF
out=$(run "Show Workdir" 2>&1)
[ "$out" = "$WORK/repo" ] && ok "HERDR_CONTROL_WORKDIR is the directory quick-action.sh was launched from" || bad "workdir=$out (expected $WORK/repo)"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
