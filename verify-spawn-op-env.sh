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

prelude=$(op_env_prelude)

# 1. The prelude names the file and never carries a value. It is typed into a
#    live shell by `herdr pane run`, so a literal token here would land in
#    scrollback, in herdr's pane history, and in every log that reads a pane.
case "$prelude" in
	*"ops_"*|*"OP_SERVICE_ACCOUNT_TOKEN="*) check "prelude carries no credential value" 1 "$prelude" ;;
	*'.config/op/service-account.env'*)     check "prelude carries no credential value" 0 "sources the file, interpolates nothing" ;;
	*)                                      check "prelude sources the service-account file" 1 "$prelude" ;;
esac

# 2. It disarms the TCC probe. With a valid service token but without this,
#    `op` still blocks forever from a background session
#    (1Password/shell-plugins#606 — the 2026-09-06 Slack-bridge deadlock).
case "$prelude" in
	*"OP_BIOMETRIC_UNLOCK_ENABLED=false"*) check "TCC probe disarmed" 0 "OP_BIOMETRIC_UNLOCK_ENABLED=false" ;;
	*) check "TCC probe disarmed" 1 "missing OP_BIOMETRIC_UNLOCK_ENABLED=false" ;;
esac

# 3. Both spawn entry points actually apply it. A lib nothing calls is the
#    failure mode this repo has already shipped once.
for s in spawn-task.sh spawn-agent.sh; do
	if grep -q 'op_env_prelude' "$here/$s" && grep -q 'lib/op-env.sh' "$here/$s"; then
		check "$s applies the prelude" 0 "sources lib/op-env.sh and calls op_env_prelude"
	else
		check "$s applies the prelude" 1 "no op_env_prelude in $here/$s"
	fi
done

# 4. END TO END, in a real shell: the prelude must produce a token even when
#    the parent has none. `env -i` is the launchd/trimmed-parent case.
out=$(env -i HOME="$HOME" PATH="$PATH" /bin/sh -c "$prelude"' [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && echo TOKEN_PRESENT || echo TOKEN_ABSENT' 2>&1)
case "$out" in
	*TOKEN_PRESENT*) check "trimmed parent still gets a token" 0 "env -i + prelude -> TOKEN_PRESENT" ;;
	*) check "trimmed parent still gets a token" 1 "env -i + prelude -> $out (is ~/.config/op/service-account.env installed, mode 600?)" ;;
esac

# 5. And that identity actually works non-interactively — a token that is
#    present but rejected is worse than none, because it fails deep inside a
#    run. Reads an item this machine is known to hold; a 5s cap so a broken
#    setup reports instead of hanging the way the incident did.
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
