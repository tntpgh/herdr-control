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

VENV="${HERDR_BRIDGE_VENV:-$HOME/.config/herdr-bridge-venv}"
if [ ! -x "$VENV/bin/python" ]; then
  echo "run-bridge: creating venv at $VENV" >&2
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r "$here/requirements.txt"
fi

exec "$VENV/bin/python" "$here/slack-herdr-bridge.py"
