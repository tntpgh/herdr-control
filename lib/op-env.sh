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
# DEFAULT IS LEAST PRIVILEGE, and the measurement is why. The service account
# sees exactly one vault, read-only — `Secrets`, 249 items (measured
# 2026-09-19). Sourcing the file into a worker's shell therefore hands every
# task, and every subprocess it spawns, read access to all 249. The common case
# does not need that: knowledge-base #352 has its bootstrap read the same file
# itself, and a real spawned worker resolved 52 keys and did a live Neon read
# with the variable absent from its environment. A secret a process reads for
# itself is narrower than a credential left lying in its environment.
#
# So by default the prelude only disarms the TCC probe (harmless, and it stops
# `op` blocking forever from a background session even when some other code
# path does hold a token — 1Password/shell-plugins#606). The ambient token is
# opt-in per spawn: `--secrets`, for a task in a repo with no bootstrap of its
# own that genuinely must run `op` from the shell.
#
# $1: "ambient" to source the token, anything else for the default.
op_env_prelude() {
	if [ "${1:-}" = ambient ]; then
		printf '%s' '[ -r "$HOME/.config/op/service-account.env" ] && . "$HOME/.config/op/service-account.env"; export OP_BIOMETRIC_UNLOCK_ENABLED=false;'
	else
		printf '%s' 'export OP_BIOMETRIC_UNLOCK_ENABLED=false;'
	fi
}
