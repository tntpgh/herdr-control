#!/usr/bin/env bash
# lib/op-env.sh — the 1Password service-account prelude every spawned worker
# shell runs before its agent starts.
#
# WHY. An unattended run must never need a human finger, and two separate
# mechanisms were taking one away:
#
#   1. NO TOKEN. A worker's shell only has OP_SERVICE_ACCOUNT_TOKEN because
#      ~/.zshenv sources ~/.config/op/service-account.env. That holds for a
#      herdr pane started from a login zsh (measured 2026-09-19: TOKEN:SET),
#      and NOT for a pane whose parent was launchd, an ssh command, or any
#      process started with a trimmed environment. The launchd fleet already
#      solved this the same way — every com.teamthurber.* plist sources this
#      exact file, and thurber-os's scripts/audit_launchd.py FAILS a job that
#      reaches `op` without it. A spawned agent deserves the same guarantee;
#      it just never had it written down anywhere.
#
#   2. THE TCC PROBE. `op` probes Apple Events / AppData on every invocation
#      and, from a background session, blocks forever on a prompt nobody can
#      answer (1Password/shell-plugins#606; the 2026-09-06 Slack-bridge
#      deadlock — 25s timeout without the file, 0.68s with it).
#      OP_BIOMETRIC_UNLOCK_ENABLED=false turns that probe off even when a
#      valid service token is present, which is the same fix
#      knowledge-base's server/env_bootstrap.py applies around its own `op run`.
#
# NO SECRET IS INTERPOLATED HERE. The prelude is TYPED into the worker's live
# shell by `herdr pane run`, so it must never contain a credential value: it
# names the file and lets the shell read it, exactly as the plists do.
#
# What this deliberately does NOT do: pre-resolve per-service secrets
# (SLACK_BOT_TOKEN, NEON_CONNECTION_STRING, …). Those live in
# ~/.config/op/launchd-secrets.env and are sourced only by the jobs that need
# them — the 2026-09-06 split exists so one broad read-only credential, and
# nothing else, is ambient. A repo's own bootstrap resolves what it needs from
# `.env.op` using the token this prelude provides.

# Shell text that gives a worker a working, non-interactive `op` identity.
#
# DEFAULT IS ON, and that is a deliberate reversal of where this started.
# Least privilege argued for opt-in; the actual workload says otherwise: almost
# every task in this fleet reads a secret, so an opt-in flag is a checkpoint
# that is remembered 90% of the time and silently parks an overnight run the
# other 10%. A control whose failure mode is "the work did not happen, and
# nobody was told" is not buying the safety it appears to.
#
# What the grant actually is, measured 2026-09-19: the service account reads
# exactly ONE vault — `Secrets`, 249 items — and cannot write (`op whoami` ->
# SERVICE_ACCOUNT; `op vault list` -> one entry). And it is not new capability
# for the worker: an agent with a shell and $HOME can read
# ~/.config/op/service-account.env itself at any time. Withholding it removes a
# human checkpoint, not an ability. The checkpoint is worth keeping only where
# the worker handles material we did not write — third-party code review, a
# web-facing scrape, anything parsing untrusted input that could carry an
# injected instruction. That case gets `--no-secrets`.
#
# Narrower is still better where it is free: a repo whose own bootstrap reads
# the same file (knowledge-base server/env_bootstrap.py, #352) resolves its 52
# keys with nothing ambient at all, and keeps working under `--no-secrets`.
# This prelude is the floor for repos that have no such bootstrap yet.
#
# OP_BIOMETRIC_UNLOCK_ENABLED=false is set in the DEFAULT mode only. It is not a
# credential — it stops `op` blocking forever on a TCC prompt from a background
# session (1Password/shell-plugins#606 — the 2026-09-06 Slack-bridge deadlock,
# 25s hang vs 0.68s). Withhold mode deliberately leaves it alone: in the mode
# that means "this worker has no business calling op", a stalling `op` is a
# signal, not a defect.
#
# NO SECRET IS INTERPOLATED IN EITHER MODE. The string is TYPED into the
# worker's live shell by `herdr pane run`, so it names the file and lets the
# shell read it, exactly as the launchd plists do. `op_env_names` reads only
# variable NAMES out of that file — never a value — so withhold clears whatever
# the file currently grants instead of one hardcoded literal that silently
# stops covering the file the day someone adds a line to it.

OP_ENV_FILE="${OP_ENV_FILE:-$HOME/.config/op/service-account.env}"

# Variable names exported by the service-account file. Names only, by
# construction: the value side of every line is discarded by the regex.
#
# ALWAYS includes the two literals we know the file carries. Reading the file
# was meant to future-proof the unset list; on its own it also fails OPEN — a
# readable file with no `NAME=` lines yields the empty string, the prelude
# emits `unset ;` (a no-op), the pane shell has already sourced ~/.zshenv, and
# the spawner prints WITHHELD over a worker that still holds the token
# (security review 2026-09-19, SPAWN-OPENV-009).
op_env_names() {
	names=""
	[ -r "$OP_ENV_FILE" ] && names=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$OP_ENV_FILE" \
		| sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' | sort -u | tr '\n' ' ')
	case " $names " in
		*" OP_SERVICE_ACCOUNT_TOKEN "*) ;;
		*) names="OP_SERVICE_ACCOUNT_TOKEN $names" ;;
	esac
	printf '%s' "$names"
}

# Is the ~/.zshenv guard that makes withholding survive a zsh child installed?
# Half of the withhold mechanism lives in a file this repo does not own
# (SPAWN-OPENV-001-R). Without it, `unset` clears one shell and the worker's
# first `zsh -c` child re-sources the token — so callers MUST degrade their
# reporting rather than print an unconditional "WITHHELD".
op_env_guard_installed() {
	grep -q 'HERDR_SECRETS_WITHHELD' "$HOME/.zshenv" 2>/dev/null
}

# $1: "withhold" for a worker that must not hold the credential; anything else
#     gets the default identity.
op_env_prelude() {
	if [ "${1:-}" = withhold ]; then
		# HERDR_SECRETS_WITHHELD is load-bearing twice over, and the `unset`
		# alone was theatre without it (security review 2026-09-19,
		# SPAWN-OPENV-001):
		#   * ~/.zshenv sources the service-account file for EVERY zsh — that is
		#     deliberate, so `zsh -c` and `ssh host cmd` have an identity — so a
		#     withheld worker's first zsh child got the token straight back. That
		#     file now skips sourcing when this marker is set.
		#   * it is exported, so a child spawn made from inside a withheld worker
		#     inherits the restriction. Tighten-only, like HERDR_POSTURE_FLOOR.
		# It is NOT a sandbox: the file is mode 600 owned by this uid, and a pane
		# the worker asks herdr to create is a child of the herdr server, not of
		# the worker, so it starts outside the withholding (SPAWN-OPENV-013).
		# What this removes is ambient inheritance down the worker's own tree.
		#
		# OP_BIOMETRIC_UNLOCK_ENABLED=false is set in BOTH modes. It is not a
		# credential. Withholding it was defensible while withhold meant "an
		# operator typed --no-secrets"; once a job-class table can withhold by
		# DEFAULT, an armed TCC probe means a token-less `op` hangs 25s on a
		# prompt nobody can answer — reintroducing exactly the parked-overnight-
		# run failure this design exists to prevent (SPAWN-OPENV-011). Disarmed,
		# it fails fast and loudly instead, and the WITHHELD line is the signal.
		printf 'export HERDR_SECRETS_WITHHELD=1; unset %s; export OP_BIOMETRIC_UNLOCK_ENABLED=false;' "$(op_env_names)"
	else
		printf '[ -r %s ] && . %s; export OP_BIOMETRIC_UNLOCK_ENABLED=false;' '"$HOME/.config/op/service-account.env"' '"$HOME/.config/op/service-account.env"'
	fi
}
