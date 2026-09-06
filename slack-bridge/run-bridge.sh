#!/usr/bin/env bash
# run-bridge.sh — start the Slack -> herdr bridge daemon.
# Sources tokens from an env file (default ~/.config/herdr-bridge.env, which reads
# them out of 1Password), builds a venv on first run, then execs the daemon.
# Run it in a herdr pane, or under launchd for always-on.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

ENV_FILE="${HERDR_BRIDGE_ENV:-$HOME/.config/herdr-bridge.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  echo "run-bridge: no env file at $ENV_FILE — copy herdr-bridge.env.example there and fill it in" >&2
  exit 1
fi

# A background session cannot resolve op:// at all — `op` probes Apple Events /
# AppData TCC on every invocation and blocks forever with no TTY to answer the
# prompt (1Password/shell-plugins#606). If the env file falls back to `op read`
# there, this daemon does not fail: it HANGS. launchctl reports it running, the
# log stays empty, and Slack silently loses every alert and phone approval.
# That was the live incident on 2026-09-06.
#
# So refuse, loudly, instead: with no TTY and no pre-resolved token, exit
# non-zero so KeepAlive turns it into a visible crash-loop with a log line that
# names the fix. The alerting path failing closed and audibly beats it looking
# alive while being dead.
if [ ! -t 0 ] && [ -z "${SLACK_BOT_TOKEN:-}" ]; then
  echo "run-bridge: no TTY and SLACK_BOT_TOKEN is unset after sourcing $ENV_FILE." >&2
  echo "run-bridge: \`op read\` cannot run from a launchd/background session — it would hang," >&2
  echo "run-bridge: not fail. Put pre-resolved SLACK_BOT_TOKEN and SLACK_APP_TOKEN in" >&2
  echo "run-bridge: ~/.config/op/launchd-secrets.env (chmod 600) and have the plist source it;" >&2
  echo "run-bridge: resolve their values from an INTERACTIVE shell, where op works." >&2
  exit 1
fi

VENV="${HERDR_BRIDGE_VENV:-$HOME/.config/herdr-bridge-venv}"
if [ ! -x "$VENV/bin/python" ]; then
  echo "run-bridge: creating venv at $VENV" >&2
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r "$here/requirements.txt"
fi

exec "$VENV/bin/python" "$here/slack-herdr-bridge.py"
