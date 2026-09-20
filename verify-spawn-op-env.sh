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

# 3. The DEFAULT disarms the TCC probe — with a token but without it, `op`
#    blocks forever from a background session (1Password/shell-plugins#606 —
#    the 2026-09-06 Slack-bridge deadlock). WITHHOLD deliberately does not: in
#    the mode that means "this worker has no business calling op", a stalling
#    `op` is a signal, and silencing it would hide an unauthorized call.
case "$prelude" in
	*"OP_BIOMETRIC_UNLOCK_ENABLED=false"*) check "default disarms the TCC probe" 0 "OP_BIOMETRIC_UNLOCK_ENABLED=false" ;;
	*) check "default disarms the TCC probe" 1 "missing in: $prelude" ;;
esac
case "$withheld" in
	*"OP_BIOMETRIC_UNLOCK_ENABLED=false"*) check "withhold leaves the TCC probe armed" 1 "withhold silenced the probe: $withheld" ;;
	*) check "withhold leaves the TCC probe armed" 0 "an op call from a withheld worker still surfaces" ;;
esac

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
