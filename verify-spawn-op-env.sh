#!/usr/bin/env bash
# verify-spawn-op-env.sh — prove a spawned worker starts with a usable,
# non-interactive 1Password identity, and that no secret is typed into its pane.
#
# The failure this guards against is silent and expensive: the worker starts
# fine, works for ten minutes, then stops on a credential-shaped approval
# prompt that only a human may answer — so an overnight run is simply parked
# until morning. thurber-os's scripts/audit_launchd.py enforces the identical
# rule for launchd jobs; this is the same rule for spawns.
#
# Usage: verify-spawn-op-env.sh
# Exit:  0 all checks passed, 1 a check failed (each printed with its evidence)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/op-env.sh"

fail=0
check() {  # <name> <condition-result> <evidence>
	if [ "$2" = 0 ]; then printf 'ok   %s\n       %s\n' "$1" "$3"
	else printf 'FAIL %s\n       %s\n' "$1" "$3"; fail=1; fi
}

prelude=$(op_env_prelude)                  # default: the worker has an identity
withheld=$(op_env_prelude withhold)        # --no-secrets: it must not

# 1. The DEFAULT gives a worker an identity — that is the whole point, and an
#    opt-in flag was measured to be the wrong default for this fleet: nearly
#    every task reads a secret, so a forgotten flag parks an overnight run.
case "$prelude" in
	*'.config/op/service-account.env'*) check "default spawn has an op identity" 0 "sources the service-account file" ;;
	*) check "default spawn has an op identity" 1 "$prelude" ;;
esac

# 2. NEITHER mode carries a value. The string is TYPED into a live pane, so a
#    literal token would land in scrollback, pane history, and every log.
for p in "$prelude" "$withheld"; do
	case "$p" in
		*"ops_"*|*"OP_SERVICE_ACCOUNT_TOKEN="*) check "prelude carries no credential value" 1 "$p" ;;
		*) check "prelude carries no credential value" 0 "names the file, interpolates nothing" ;;
	esac
done

# 3. BOTH modes disarm the TCC probe. Without it, `op` blocks forever from a
#    background session (1Password/shell-plugins#606 — the 2026-09-06
#    Slack-bridge deadlock). This check was inverted for withhold mode until
#    SPAWN-OPENV-011: "a stalling op is a signal" holds when a human typed
#    --no-secrets, but withhold is now a job-class DEFAULT, and an armed probe
#    there means a 25s hang on a prompt nobody can answer — the parked-run
#    failure the whole design exists to prevent.
for p in "$prelude" "$withheld"; do
	case "$p" in
		*"OP_BIOMETRIC_UNLOCK_ENABLED=false"*) check "TCC probe disarmed" 0 "a token-less op fails fast instead of hanging" ;;
		*) check "TCC probe disarmed" 1 "missing in: $p" ;;
	esac
done

# 3b. Withhold must never emit a no-op `unset ;` (SPAWN-OPENV-009). The names
#     come from a file this repo does not own; an empty result used to mean the
#     prelude removed nothing while the spawner printed WITHHELD.
case "$withheld" in
	*"unset OP_SERVICE_ACCOUNT_TOKEN"*|*" OP_SERVICE_ACCOUNT_TOKEN "*)
		check "withhold always unsets the op token by name" 0 "the literal is in the unset list regardless of the file" ;;
	*) check "withhold always unsets the op token by name" 1 "unset list does not name the token: $withheld" ;;
esac
empty=$(OP_ENV_FILE=/dev/null bash -c '. '"$here"'/lib/op-env.sh; op_env_prelude withhold')
case "$empty" in
	*"unset OP_SERVICE_ACCOUNT_TOKEN"*) check "withhold survives an unreadable/empty credential file" 0 "OP_ENV_FILE=/dev/null still unsets the token" ;;
	*) check "withhold survives an unreadable/empty credential file" 1 "fails open: $empty" ;;
esac

# 3c. THE OUT-OF-REPO HALF. Withholding only survives a `zsh -c` child because
#     ~/.zshenv skips sourcing the credential file when the marker is set. This
#     repo neither installs nor owns that line (SPAWN-OPENV-001-R), so its
#     absence must be loud, not silent.
if op_env_guard_installed; then
	check "the ~/.zshenv withhold guard is installed" 0 "HERDR_SECRETS_WITHHELD honoured by the shell profile"
else
	check "the ~/.zshenv withhold guard is installed" 1 \
		"MISSING — --no-secrets clears one shell and the worker's first 'zsh -c' child re-sources the token. Add: [ \"\${HERDR_SECRETS_WITHHELD:-}\" = 1 ] || { [ -r \"\$HOME/.config/op/service-account.env\" ] && . \"\$HOME/.config/op/service-account.env\"; }"
fi

# 4. Both entry points apply the prelude AND accept the flag. A lib nothing
#    calls is the failure mode this repo has already shipped once.
for s in spawn-task.sh spawn-agent.sh; do
	# `grep` for the call is not enough — it matches a COMMENTED-OUT line, so the
	# check could stay green while every worker silently lost the prelude
	# (SPAWN-OPENV-002). Strip comments before looking.
	if sed 's/#.*//' "$here/$s" | grep -q 'op_env_prelude "$op_mode"' \
		&& sed 's/#.*//' "$here/$s" | grep -q -- '--no-secrets) secrets_req=withhold'; then
		check "$s wires the prelude and --no-secrets" 0 "live call (not a comment) + the flag"
	else
		check "$s wires the prelude and --no-secrets" 1 "missing, or only present in a comment, in $here/$s"
	fi
done

# 4b. THE COMPOSED LINE, not just the lib's return value. This is what actually
#     gets typed into the pane, and it is where a future edit would interpolate
#     something. Stub `herdr` the way verify-layout.sh does and capture argv.
run_log=$(mktemp)
stub_dir=$(mktemp -d)
cat > "$stub_dir/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
	"tab create") printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1","terminal_id":"term1"}}}\n' ;;
	"pane run")   printf '%s\n' "\$4" >> "$run_log" ;;
	"pane list")  printf '{"result":{"panes":[]}}\n' ;;
	# ensure-workspace.sh runs first and EXITS the spawn if it cannot resolve a
	# workspace id, which is why an empty-object catch-all captured nothing.
	# (No backticks in this heredoc: it is unquoted so $run_log expands, which
	#  means a backticked word would be run as a command at write time.)
	*)            printf '{"result":{"workspace":{"workspace_id":"w1"},"workspaces":[],"panes":[],"tabs":[]}}\n' ;;
esac
STUB
chmod +x "$stub_dir/herdr"
probe_repo=$(mktemp -d); git -C "$probe_repo" init -q 2>/dev/null
env HERDR_EXTRA_PATH="$stub_dir" PATH="$stub_dir:$PATH" HERDR_WT_DIR="$(mktemp -d)" HERDR_RUN_STATE_DIR="$(mktemp -d)" \
	bash "$here/spawn-task.sh" "$probe_repo" verify-op-env quick /bin/true >/dev/null 2>&1
typed=$(cat "$run_log" 2>/dev/null)
if [ -z "$typed" ]; then
	check "the composed launch line is inspectable" 1 "stub captured no 'pane run' — harness broken, not the code"
else
	case "$typed" in
		*"ops_"*) check "composed line carries no credential value" 1 "a token literal reached the typed command" ;;
		*) check "composed line carries no credential value" 0 "argv captured from a stubbed herdr, no literal in it" ;;
	esac
	case "$typed" in
		# quick + a literal command = UNMANAGED, so this one must be withheld.
		*"HERDR_SECRETS_WITHHELD=1"*) check "unmanaged spawn types the withhold prelude" 0 "withhold marker present in the typed line" ;;
		*) check "unmanaged spawn types the withhold prelude" 1 "unmanaged launch was not withheld: ${typed%% *}…" ;;
	esac
fi
rm -rf "$stub_dir" "$probe_repo" "$run_log"

# 4c. PIN THE GRANT. The default prelude sources a file this repo does not own,
#     so "one broad read-only credential and nothing else" is prose unless the
#     name set is checked. Names only — values are never read (SPAWN-OPENV-004).
op_file="${OP_ENV_FILE:-$HOME/.config/op/service-account.env}"
if [ -r "$op_file" ]; then
	got=$(op_env_names)
	case "$got" in
		"OP_BIOMETRIC_UNLOCK_ENABLED OP_SERVICE_ACCOUNT_TOKEN "|"OP_SERVICE_ACCOUNT_TOKEN ")
			check "the ambient grant is still only the op credential" 0 "exports: $got" ;;
		*) check "the ambient grant is still only the op credential" 1 "file now exports MORE than the op token: $got" ;;
	esac
else
	check "the ambient grant is still only the op credential" 1 "cannot read $op_file"
fi

# 5. END TO END in a real shell, both directions. `env -i` is the
#    launchd/trimmed-parent case the login-shell path never covered.
probe_token() { env -i HOME="$HOME" PATH="$PATH" /bin/sh -c "$1"' [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && echo TOKEN_PRESENT || echo TOKEN_ABSENT' 2>&1; }
case "$(probe_token "$prelude")" in
	*TOKEN_PRESENT*) check "default: trimmed parent still gets a token" 0 "env -i + default -> TOKEN_PRESENT" ;;
	*) check "default: trimmed parent still gets a token" 1 "is ~/.config/op/service-account.env installed, mode 600?" ;;
esac

# 6. --no-secrets must withhold even when the PARENT already has one — the
#    normal case, since a conductor pane is a login shell. A mode that only
#    works from an already-empty environment withholds nothing in practice.
inherited=$(env -i HOME="$HOME" PATH="$PATH" OP_SERVICE_ACCOUNT_TOKEN=inherited-parent-value \
	/bin/sh -c "$withheld"' [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && echo TOKEN_PRESENT || echo TOKEN_ABSENT' 2>&1)
case "$inherited" in
	*TOKEN_ABSENT*) check "--no-secrets withholds an INHERITED token" 0 "parent token set -> TOKEN_ABSENT in worker" ;;
	*) check "--no-secrets withholds an INHERITED token" 1 "worker kept the parent's token: $inherited" ;;
esac

# 6b. THE REGAIN PATH THAT ACTUALLY EXISTS. Check 6 runs /bin/sh, which never
#     reads ~/.zshenv — so it could not have caught SPAWN-OPENV-001, where the
#     worker's first `zsh -c` child got the token straight back. Probe zsh.
#     Presence/absence only; the value is never printed.
if command -v zsh >/dev/null 2>&1; then
	regain=$(env -i HOME="$HOME" PATH="$PATH" /bin/sh -c "$withheld"' zsh -c '"'"'[ -n "$OP_SERVICE_ACCOUNT_TOKEN" ] && echo REGAINED || echo ABSENT'"'"'' 2>&1)
	case "$regain" in
		*ABSENT*) check "--no-secrets survives a zsh child" 0 "zsh -c under withhold -> ABSENT (~/.zshenv honours HERDR_SECRETS_WITHHELD)" ;;
		*) check "--no-secrets survives a zsh child" 1 "zsh -c REGAINED the token — ~/.zshenv is re-sourcing it; the flag is theatre" ;;
	esac
else
	check "--no-secrets survives a zsh child" 1 "zsh not on PATH"
fi

# 7. And the default identity actually works non-interactively — a token that
#    is present but rejected is worse than none, because it fails deep in a run.
if command -v op >/dev/null 2>&1; then
	probe=$(env -i HOME="$HOME" PATH="$PATH" /bin/sh -c "$prelude"' op user get --me --format json 2>&1 | head -c 400' 2>&1)
	case "$probe" in
		*SERVICE_ACCOUNT*) check "op authenticates non-interactively" 0 "op user get --me -> SERVICE_ACCOUNT" ;;
		*) check "op authenticates non-interactively" 1 "op user get --me -> ${probe:-<no output>}" ;;
	esac
else
	check "op authenticates non-interactively" 1 "op not on PATH"
fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
