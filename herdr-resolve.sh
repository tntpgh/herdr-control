#!/usr/bin/env bash
# herdr-resolve.sh — retract Slack alerts whose prompt has already been answered.
#
# If you answer a permission prompt in the terminal (herdr / iTerm / the TUI),
# the Slack alert for it is now a lie: it sits there looking pending, and the
# only way to find out it is stale is to reply and get a refusal. That trains
# you to distrust the alerts, which is worse than not sending them.
#
# So: for every alert we recorded as awaiting an answer, if its pane is no
# longer showing a numbered prompt, the question is settled — delete the message.
#
# Deliberately conservative:
#   - only alerts herdr-notify recorded as HAVING a live prompt are tracked, so
#     ordinary informational alerts are never deleted
#   - a pane we cannot READ is left alone (unreadable != answered)
#   - a pane still showing a prompt is left alone
#   - chat.delete only ever touches messages this bot posted
#
# Runs from a hook after every tool call, so the common case (nothing pending)
# must cost nothing: it exits before reading any credential or touching Slack.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"
here=$(cd "$(dirname "$0")" && pwd)

STATE="${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}"
PENDING="$STATE/pending.jsonl"

# Fast path: nothing outstanding. This is the overwhelmingly common case.
[ -s "$PENDING" ] || exit 0

. "$here/lib/prompt-parse.sh"

ENV_FILE="${HERDR_BRIDGE_ENV:-$HOME/.config/herdr-bridge.env}"
[ -f "$ENV_FILE" ] || exit 0
# shellcheck disable=SC1090
. "$ENV_FILE" 2>/dev/null || exit 0
[ -n "${SLACK_BOT_TOKEN:-}" ] || exit 0
user="${HERDR_BRIDGE_ALLOW_USERS%%,*}"
[ -n "$user" ] || exit 0

keep=$(mktemp "${TMPDIR:-/tmp}/herdr-pending.XXXXXX") || exit 0
trap 'rm -f "$keep"' EXIT HUP INT TERM

while IFS= read -r line; do
  [ -n "$line" ] || continue
  ts=$(printf '%s' "$line" | jq -r '.ts // empty' 2>/dev/null)
  pane=$(printf '%s' "$line" | jq -r '.pane // empty' 2>/dev/null)
  if [ -z "$ts" ] || [ -z "$pane" ]; then continue; fi

  # Unreadable pane: keep the alert. We cannot prove it was answered, and
  # deleting on "no evidence" would silently drop live questions.
  if ! herdr pane read "$pane" --source visible --lines 5 >/dev/null 2>&1; then
    printf '%s\n' "$line" >> "$keep"; continue
  fi
  # Still asking: keep.
  if [ -n "$(prompt_options "$pane")" ]; then
    printf '%s\n' "$line" >> "$keep"; continue
  fi

  # Answered elsewhere — retract it.
  ok=$(printf 'header = "Authorization: Bearer %s"\n' "$SLACK_BOT_TOKEN" \
    | curl -s -X POST --config - -H 'Content-type: application/json' \
        --data "$(jq -nc --arg c "$user" --arg ts "$ts" '{channel:$c,ts:$ts}')" \
        https://slack.com/api/chat.delete 2>/dev/null | jq -r '.ok // false')
  # If Slack refused (already gone, too old, transient), drop it from the queue
  # anyway on a definitive error — but keep it if we simply could not reach
  # Slack, so a network blip does not lose a live question.
  if [ "$ok" != true ] && [ -z "$ok" ]; then
    printf '%s\n' "$line" >> "$keep"
  fi
done < "$PENDING"

cat "$keep" > "$PENDING"
