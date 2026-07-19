#!/usr/bin/env bash
# herdr-notify.sh [--pane <id>] [--cwd <path>] [--dry-run] <text...>
#
# Post an alert to your herdrbot DM AS the bot (the outbound half of the 2-way
# conversation — replaces the one-way OMC/OMX webhook). Tags the pane it's about
# and records ts->pane so a threaded REPLY routes straight back to that pane.
#
#   herdr-notify.sh --pane w8:p2 "tourguide: needs a decision — merge comps fix?"
#   HERDR_PANE_ID=w8:p2 herdr-notify.sh "blocked on your call"   # pane from env
#   herdr-notify.sh "blocked on your call"        # pane auto-resolved (below)
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

# ── pane resolution ─────────────────────────────────────────────────────────
# Order: --pane > $HERDR_PANE_ID > tmux-session match > UNIQUE cwd > untagged.
#
# The pane in a tag is not a label. The bridge records ts->pane, so a threaded
# reply is injected into that pane and SUBMITTED. Naming the wrong pane does not
# mislabel an alert — it hands your instructions to a different agent. So every
# step here either identifies the pane exactly or declines.
#
# WHY the tmux step is needed: herdr does inject HERDR_PANE_ID, but only into
# processes it starts. OMC launches the agent inside a DETACHED tmux session and
# the herdr pane merely runs `tmux attach-session -t <name>`, so the agent is a
# child of the tmux server, not of the pane shell, and inherits none of the
# HERDR_* vars. (Same reason herdr's own claude integration hook no-ops: it opens
# with `[ -n "$HERDR_PANE_ID" ] || exit 0`.) Our tmux session name appears in the
# pane's foreground-process cmdline, which recovers the pane exactly.
#
# WHY cwd is last and must be UNIQUE: several agents routinely share one repo
# cwd, so a first-match cwd guess is a coin flip between live agents. Ambiguous
# means untagged: the alert still reaches you, only reply-routing is dropped.

_pane_ids() {
  herdr pane list 2>/dev/null | jq -r '(.result.panes // .panes)[]?.pane_id // empty' 2>/dev/null
}

_only_one() {  # stdin: candidate lines -> echo the single line, or fail
  local uniq n
  uniq=$(sed '/^[[:space:]]*$/d' | sort -u)
  n=$(printf '%s' "$uniq" | grep -c . || true)
  [ "$n" = 1 ] || return 1
  printf '%s' "$uniq"
}

_resolve_by_tmux() {
  [ -n "${TMUX_PANE:-}" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  local sess id cl hits=""
  sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || return 1
  [ -n "$sess" ] || return 1
  for id in $(_pane_ids); do
    while IFS= read -r cl; do
      # Match the session name as a whole argument, never a substring, so
      # "omc-x" cannot claim the pane attached to "omc-x-2".
      case " $cl " in
        *" $sess "*) hits="${hits}${id}"$'\n'; break ;;
      esac
    done <<EOF
$(herdr pane process-info --pane "$id" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[]?.cmdline // empty' 2>/dev/null)
EOF
  done
  printf '%s' "$hits" | _only_one
}

_resolve_by_cwd() {
  local c="${1:-}"
  [ -n "$c" ] || return 1
  herdr pane list 2>/dev/null \
    | jq -r --arg c "$c" '(.result.panes // .panes)[]? | select((.foreground_cwd // .cwd // "")==$c) | .pane_id' 2>/dev/null \
    | _only_one
}

pane=""
cwd_hint=""
dry=0
while :; do
  case "${1:-}" in
    --pane) pane="${2:-}"; shift 2 ;;
    --cwd)  cwd_hint="${2:-}"; shift 2 ;;
    # --dry-run resolves the pane and reports it WITHOUT posting. Pane
    # resolution decides where a threaded reply gets injected, so it needs to be
    # checkable without DMing yourself to find out.
    --dry-run) dry=1; shift ;;
    *) break ;;
  esac
done
[ -n "$pane" ] || pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || pane="$(_resolve_by_tmux || true)"
[ -n "$pane" ] || pane="$(_resolve_by_cwd "${cwd_hint:-$PWD}" || true)"

text="$*"
[ -n "$text" ] || { echo "herdr-notify: empty text" >&2; exit 2; }

if [ "$dry" = 1 ]; then
  echo "dry-run: pane=${pane:-none} text=${text}"
  exit 0
fi

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
