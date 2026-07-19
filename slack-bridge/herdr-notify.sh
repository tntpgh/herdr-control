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
choices=0
while :; do
  case "${1:-}" in
    # ${2:?} not ${2:-}: with a trailing flag and no value, `shift 2` FAILS and
    # shifts nothing, and since there is no `set -e` the `while :` re-reads the
    # same $1 forever — a wedged process spinning a core, which under launchd
    # KeepAlive never resolves. Erroring out is the only safe response.
    # Distinguish ABSENT from EMPTY. `${2:?}` would also abort on an explicitly
    # empty value, so a wrapper written as `--pane "$HERDR_PANE_ID"` would die
    # exactly when that var is unset — which is the normal case the tmux
    # resolution below exists to handle. An empty value should fall through to
    # auto-resolution, not kill the notification.
    --pane) [ $# -ge 2 ] || { echo "herdr-notify: --pane needs a value" >&2; exit 2; }
            pane="$2"; shift 2 ;;
    --cwd)  [ $# -ge 2 ] || { echo "herdr-notify: --cwd needs a value" >&2; exit 2; }
            cwd_hint="$2"; shift 2 ;;
    # --dry-run resolves the pane and reports it WITHOUT posting. Pane
    # resolution decides where a threaded reply gets injected, so it needs to be
    # checkable without DMing yourself to find out.
    --dry-run) dry=1; shift ;;
    # Show the agent's actual options and make them answerable.
    --choices) choices=1; shift ;;
    *) break ;;
  esac
done
[ -n "$pane" ] || pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || pane="$(_resolve_by_tmux || true)"
# cwd only when a caller EXPLICITLY offers one — never an implicit $PWD.
# Uniqueness is not identity: if we happen to run from a directory where exactly
# one unrelated pane sits, _only_one is satisfied and we would tag that pane, so
# a threaded reply lands in an agent that has nothing to do with this alert.
# _only_one defends against ambiguity, not coincidence.
[ -n "$pane" ] || { [ -n "$cwd_hint" ] && pane="$(_resolve_by_cwd "$cwd_hint" || true)"; }

text="$*"
[ -n "$text" ] || { echo "herdr-notify: empty text" >&2; exit 2; }

_dry_report() {
  echo "dry-run: pane=${pane:-none}${blocks:+ (with buttons)}"
  echo "--- message body ---"
  printf '%s\n' "$body"
  exit 0
}

_lib="$(cd "$(dirname "$0")/.." && pwd)/lib"

# Name the pane the way the operator named it. "w3:p1" identifies nothing to a
# human reading this on a phone; "thurber-os — Main" does. The raw id stays as a
# small suffix because it is what you type to target a pane by hand.
where=""
if [ -n "$pane" ]; then
  . "$_lib/pane-name.sh"
  where="$(pane_display_name "$pane")"
fi
_hdr() {  # the alert's first line
  if [ -n "$pane" ]; then printf '🔔 *%s*  ·  %s\n`%s`' "$where" "$text" "$pane"
  else printf '🔔 %s' "$text"; fi
}

body="$text"
[ -n "$pane" ] && body="$(_hdr)"

# --choices: an alert you cannot act on is half a feature. When the pane is
# sitting on a numbered prompt, show the ACTUAL options and make them
# answerable — as a threaded number (works with no Slack app configuration) and
# as buttons (dormant until Interactivity is enabled on the app). Both routes
# end in herdr-select.sh, so a choice is validated and recorded identically.
blocks=""
if [ "$choices" = 1 ] && [ -n "$pane" ]; then
  . "$_lib/prompt-parse.sh"
  # The Notification hook fires when the agent DECIDES it needs permission,
  # which can be before the TUI has painted the prompt box. Reading once loses
  # that race and silently degrades to scrollback, so the alert arrives without
  # the question — which is exactly the failure this whole feature exists to
  # avoid. Poll briefly for the options to appear. Costs nothing when they are
  # already there, and the hook is async so a short wait is free.
  opts=""
  for _ in 1 2 3 4 5 6 7 8; do
    opts=$(prompt_options "$pane")
    [ -n "$opts" ] && break
    sleep 0.25
  done
  if [ -n "$opts" ]; then
    question=$(prompt_question "$pane")
    list=$(printf '%s\n' "$opts" | awk -F'\t' '{printf "  *%s.* %s\n", $1, $2}')
    nums=$(printf '%s\n' "$opts" | awk -F'\t' '{printf "%s%s", sep, $1; sep=", "}')
    body="$(_hdr)"
    [ -n "$question" ] && body="${body}"$'\n\n'"${question}"
    body="${body}"$'\n'"${list}"$'\n'"_Reply in thread with ${nums}._"
    blocks=$(printf '%s\n' "$opts" | jq -R -s --arg body "$body" --arg pane "$pane" '
      [ split("\n")[] | select(length>0) | split("\t") | {num:.[0], label:.[1]} ] as $o
      | [ {type:"section", text:{type:"mrkdwn", text:$body}},
          {type:"actions",
           elements: ($o | map({
             type:"button",
             text:{type:"plain_text", text:("\(.num). " + (.label|.[0:70]))},
             value:($pane + "|" + .num),
             action_id:("herdr_choice_" + .num)}))} ]')
  else
    # No numbered list to parse — but "Claude needs your permission to use Bash"
    # on its own means you answer BLIND. Send what is actually on screen: the
    # command, the reason, the question. This is the common case, not the edge
    # case: a prompt auto-mode already dismissed, a non-numbered confirmation,
    # or a plan approval all land here.
    ctx=$(prompt_context "$pane")
    if [ -n "$ctx" ]; then
      body="$(_hdr)"$'\n\n```\n'"${ctx}"$'\n```'
    fi
  fi
fi

# The bot token goes in via --config on STDIN, never as an argv element: a
# `-H "Authorization: Bearer xoxb-…"` argument is readable by any same-user
# process through `ps`. --config keeps it off the process table entirely.
[ "$dry" = 1 ] && _dry_report

if [ -n "$blocks" ]; then
  payload=$(jq -nc --arg c "$user" --arg t "$body" --argjson b "$blocks" \
    '{channel:$c,text:$t,blocks:$b}')
else
  payload=$(jq -nc --arg c "$user" --arg t "$body" '{channel:$c,text:$t}')
fi
resp=$(printf 'header = "Authorization: Bearer %s"\n' "$SLACK_BOT_TOKEN" \
  | curl -s -X POST --config - -H 'Content-type: application/json' \
      --data "$payload" \
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
  # Track it as AWAITING AN ANSWER only if we actually showed a live prompt.
  # If you then answer in the terminal, herdr-resolve.sh retracts this message
  # so it does not sit in Slack looking pending. Informational alerts carry no
  # question, so they are never tracked and never deleted.
  [ -n "$blocks" ] && jq -nc --arg ts "$ts" --arg pane "$pane" \
    '{ts:$ts,pane:$pane}' >> "$reg_dir/pending.jsonl"
  # Keep the registry bounded (last 500 alerts).
  if [ "$(wc -l < "$reg" 2>/dev/null || echo 0)" -gt 600 ]; then
    tail -n 500 "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
  fi
fi

echo "notified (ts=$ts pane=${pane:-none})"
