#!/usr/bin/env bash
# herdr-notify.sh [--pane <id>] <text...>
#
# Post an alert to your herdrbot DM AS the bot (the outbound half of the 2-way
# conversation — replaces the one-way OMC/OMX webhook). Tags the pane it's about
# and records ts->pane so a threaded REPLY routes straight back to that pane.
#
#   herdr-notify.sh --pane w8:p2 "tourguide: needs a decision — merge comps fix?"
#   HERDR_PANE_ID=w8:p2 herdr-notify.sh "blocked on your call"   # pane from env
#
# Reads SLACK_BOT_TOKEN + HERDR_BRIDGE_ALLOW_USERS from the bridge env file. Posts
# to the first allowlisted user's DM (chat.postMessage channel=<user id>, works
# with chat:write — no im:write needed). Prints the ts.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"

ENV_FILE="${HERDR_BRIDGE_ENV:-$HOME/.config/herdr-bridge.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE" || { echo "herdr-notify: no bridge env ($ENV_FILE)" >&2; exit 1; }
: "${SLACK_BOT_TOKEN:?herdr-notify: SLACK_BOT_TOKEN unset}"
user="${HERDR_BRIDGE_ALLOW_USERS%%,*}"
[ -n "$user" ] || { echo "herdr-notify: HERDR_BRIDGE_ALLOW_USERS unset" >&2; exit 1; }

pane=""
if [ "${1:-}" = "--pane" ]; then pane="$2"; shift 2; fi
[ -n "$pane" ] || pane="${HERDR_PANE_ID:-}"
text="$*"
[ -n "$text" ] || { echo "herdr-notify: empty text" >&2; exit 2; }

# Prefix the pane so it's visible even on a non-threaded reply.
body="$text"
[ -n "$pane" ] && body="🔔 \`${pane}\`  ${text}"

resp=$(curl -s -X POST -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H 'Content-type: application/json' \
  --data "$(jq -nc --arg c "$user" --arg t "$body" '{channel:$c,text:$t}')" \
  https://slack.com/api/chat.postMessage 2>/dev/null)
if [ "$(printf '%s' "$resp" | jq -r '.ok')" != true ]; then
  echo "herdr-notify: slack error: $(printf '%s' "$resp" | jq -r '.error // "unknown"')" >&2
  exit 1
fi
ts=$(printf '%s' "$resp" | jq -r '.ts')

# Record ts -> pane so a threaded reply resolves the target (bridge reads this).
if [ -n "$pane" ]; then
  reg_dir="${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}"
  mkdir -p "$reg_dir"
  reg="$reg_dir/registry.jsonl"
  jq -nc --arg ts "$ts" --arg pane "$pane" '{ts:$ts,pane:$pane}' >> "$reg"
  # Keep the registry bounded (last 500 alerts).
  if [ "$(wc -l < "$reg" 2>/dev/null || echo 0)" -gt 600 ]; then
    tail -n 500 "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
  fi
fi

echo "notified (ts=$ts pane=${pane:-none})"
