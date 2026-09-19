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
# OP_BIOMETRIC_UNLOCK_ENABLED=false is unconditional in both modes: it is not a
# credential, it just stops `op` blocking forever on a TCC prompt from a
# background session (1Password/shell-plugins#606 — the 2026-09-06 Slack-bridge
# deadlock, 25s hang vs 0.68s).
#
# NO SECRET IS INTERPOLATED IN EITHER MODE. The string is TYPED into the
# worker's live shell by `herdr pane run`, so it names the file and lets the
# shell read it, exactly as the launchd plists do.
#
# $1: "withhold" for a worker that must not hold the credential; anything else
#     gets the default identity.
op_env_prelude() {
	if [ "${1:-}" = withhold ]; then
		printf '%s' 'unset OP_SERVICE_ACCOUNT_TOKEN; export OP_BIOMETRIC_UNLOCK_ENABLED=false;'
	else
		printf '%s' '[ -r "$HOME/.config/op/service-account.env" ] && . "$HOME/.config/op/service-account.env"; export OP_BIOMETRIC_UNLOCK_ENABLED=false;'
	fi
}
