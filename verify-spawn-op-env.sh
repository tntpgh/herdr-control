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

# 3. Both modes disarm the TCC probe: with a token but without this, `op`
#    blocks forever from a background session (1Password/shell-plugins#606 —
#    the 2026-09-06 Slack-bridge deadlock).
for p in "$prelude" "$withheld"; do
	case "$p" in
		*"OP_BIOMETRIC_UNLOCK_ENABLED=false"*) check "TCC probe disarmed" 0 "OP_BIOMETRIC_UNLOCK_ENABLED=false" ;;
		*) check "TCC probe disarmed" 1 "missing in: $p" ;;
	esac
done

# 4. Both entry points apply the prelude AND accept the flag. A lib nothing
#    calls is the failure mode this repo has already shipped once.
for s in spawn-task.sh spawn-agent.sh; do
	if grep -q 'op_env_prelude "$op_mode"' "$here/$s" && grep -q -- '--no-secrets) op_mode=withhold' "$here/$s"; then
		check "$s wires the prelude and --no-secrets" 0 "op_env_prelude \"\$op_mode\" + --no-secrets flag"
	else
		check "$s wires the prelude and --no-secrets" 1 "missing in $here/$s"
	fi
done

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
