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

prelude=$(op_env_prelude)                 # default: least privilege
ambient=$(op_env_prelude ambient)         # --secrets: opt-in vault-read credential

# 1. DEFAULT LEAKS NO CREDENTIAL AT ALL. The service account reads one vault,
#    249 items; a worker that does not need that must not be handed it.
case "$prelude" in
	*'service-account.env'*|*"OP_SERVICE_ACCOUNT_TOKEN"*)
		check "default spawn stays least-privilege" 1 "$prelude" ;;
	*) check "default spawn stays least-privilege" 0 "no token sourced: $prelude" ;;
esac

# 2. Both modes disarm the TCC probe. With a valid token but without this,
#    `op` blocks forever from a background session
#    (1Password/shell-plugins#606 — the 2026-09-06 Slack-bridge deadlock).
for p in "$prelude" "$ambient"; do
	case "$p" in
		*"OP_BIOMETRIC_UNLOCK_ENABLED=false"*) check "TCC probe disarmed" 0 "$p" ;;
		*) check "TCC probe disarmed" 1 "missing OP_BIOMETRIC_UNLOCK_ENABLED=false in: $p" ;;
	esac
done

# 3. The opt-in mode names the file and interpolates nothing. The string is
#    TYPED into a live pane, so a literal value would land in scrollback, in
#    herdr's pane history, and in every log that reads a pane.
case "$ambient" in
	*"ops_"*|*"OP_SERVICE_ACCOUNT_TOKEN="*) check "--secrets carries no credential value" 1 "$ambient" ;;
	*'.config/op/service-account.env'*)     check "--secrets carries no credential value" 0 "sources the file, interpolates nothing" ;;
	*)                                      check "--secrets sources the service-account file" 1 "$ambient" ;;
esac

# 4. Both entry points apply the prelude AND accept the flag. A lib nothing
#    calls is the failure mode this repo has already shipped once.
for s in spawn-task.sh spawn-agent.sh; do
	if grep -q 'op_env_prelude "$op_mode"' "$here/$s" && grep -q -- '--secrets) op_mode=ambient' "$here/$s"; then
		check "$s wires the prelude and --secrets" 0 "op_env_prelude \"\$op_mode\" + --secrets flag"
	else
		check "$s wires the prelude and --secrets" 1 "missing in $here/$s"
	fi
done

# 5. END TO END, in a real shell. `env -i` is the launchd/trimmed-parent case:
#    default must yield NO token, --secrets must yield one.
probe_token() { env -i HOME="$HOME" PATH="$PATH" /bin/sh -c "$1"' [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && echo TOKEN_PRESENT || echo TOKEN_ABSENT' 2>&1; }
case "$(probe_token "$prelude")" in
	*TOKEN_ABSENT*) check "default: trimmed parent gets no token" 0 "env -i + default -> TOKEN_ABSENT" ;;
	*) check "default: trimmed parent gets no token" 1 "default prelude leaked a token" ;;
esac
case "$(probe_token "$ambient")" in
	*TOKEN_PRESENT*) check "--secrets: trimmed parent gets a token" 0 "env -i + --secrets -> TOKEN_PRESENT" ;;
	*) check "--secrets: trimmed parent gets a token" 1 "is ~/.config/op/service-account.env installed, mode 600?" ;;
esac

# 6. And that identity actually works non-interactively — a token that is
#    present but rejected is worse than none, because it fails deep in a run.
if command -v op >/dev/null 2>&1; then
	probe=$(env -i HOME="$HOME" PATH="$PATH" /bin/sh -c "$ambient"' op user get --me --format json 2>&1 | head -c 400' 2>&1)
	case "$probe" in
		*SERVICE_ACCOUNT*) check "op authenticates non-interactively" 0 "op user get --me -> SERVICE_ACCOUNT" ;;
		*) check "op authenticates non-interactively" 1 "op user get --me -> ${probe:-<no output>}" ;;
	esac
else
	check "op authenticates non-interactively" 1 "op not on PATH"
fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
