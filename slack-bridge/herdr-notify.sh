#!/usr/bin/env bash
# herdr-notify.sh [--pane <id>] [--cwd <path>] [--dry-run] <text...>
#
# Post an alert to your herdrbot DM AS the bot (the outbound half of the 2-way
# conversation — replaces the one-way OMC/OMX webhook). Tags the pane it's about
# and records ts->pane so a threaded REPLY routes straight back to that pane.
#
#   herdr-notify.sh --pane w8:p2 "myproject: needs a decision — merge fix?"
#   HERDR_PANE_ID=w8:p2 herdr-notify.sh "blocked on your call"   # pane from env
#   herdr-notify.sh "blocked on your call"        # pane auto-resolved (below)
#
# Reads SLACK_BOT_TOKEN + HERDR_BRIDGE_ALLOW_USERS from the bridge env file. Posts
# to the first allowlisted user's DM (chat.postMessage channel=<user id>, works
# with chat:write — no im:write needed). Prints the ts.
#
# Symptoms-only filtering (.handoffs/SPEC.md, 2026-09-24): a --choices alert
# with nothing to show (no numbered/menu options AND no plain context — the
# prompt this call was about already vanished) is DROPPED, not posted blind.
# And at most ONE real post ever goes out per prompt_id, however many times a
# caller re-fires for the same still-unanswered prompt (see lib/alert-gate.sh
# alert_claim). HERDR_SLACK_VERBOSE=1 disables both and restores the old
# always-post behaviour.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"

# --dry-run never posts, so it must not need a Slack token — and asking for one
# here is not free. The bridge env file resolves both tokens through `op read`,
# which uses OP_SERVICE_ACCOUNT_TOKEN when it is present and otherwise falls back
# to the 1Password desktop app: a Touch ID prompt, per invocation, per token.
#
# launchd has that service-account token in its environment, so the daemon itself
# is quiet. An interactive shell generally does NOT — so every `--dry-run` from a
# terminal, and every run of verify-omp-hooks.sh (which dry-runs this script to
# check an alert renders), demanded a thumbprint. Two, in fact. AGENTS.md step 7
# tells an operator to dry-run this as a verification step; that step should not
# cost a biometric prompt, and a test suite must never need a human finger.
#
# Pre-scanned rather than folded into the arg loop below, because the loop runs
# well after this point and the whole aim is to decide BEFORE sourcing anything.
_dry_prescan=0
for _a in "$@"; do
  [ "$_a" = "--dry-run" ] && { _dry_prescan=1; break; }
done

user=""
if [ "$_dry_prescan" = 0 ]; then
  ENV_FILE="${HERDR_BRIDGE_ENV:-$HOME/.config/herdr-bridge.env}"
  [ -f "$ENV_FILE" ] && . "$ENV_FILE" || { echo "herdr-notify: no bridge env ($ENV_FILE)" >&2; exit 1; }
  : "${SLACK_BOT_TOKEN:?herdr-notify: SLACK_BOT_TOKEN unset}"
  user="${HERDR_BRIDGE_ALLOW_USERS%%,*}"
  [ -n "$user" ] || { echo "herdr-notify: HERDR_BRIDGE_ALLOW_USERS unset" >&2; exit 1; }
fi

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
  # What a click would actually do. The value is the whole contract between an
  # immortal Slack message and herdr-select: target pane, option, and the
  # fingerprint of the question it was posted for.
  if [ -n "$blocks" ]; then
    echo "--- button values ---"
    printf '%s' "$blocks" | jq -r '.[] | select(.type=="actions") | .elements[].value'
  fi
  exit 0
}

_lib="$(cd "$(dirname "$0")/.." && pwd)/lib"

# Name the pane the way the operator named it. "w3:p1" identifies nothing to a
# human reading this on a phone; "project-a — Main" does. The raw id stays as a
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
# sitting on a prompt, show the ACTUAL options and make them answerable — as a
# threaded number (works with no Slack app configuration) and as buttons (dormant
# until Interactivity is enabled on the app). Both routes end in herdr-select.sh,
# so a choice is validated and recorded identically.
blocks=""
# Declared at this scope, not inside the --choices branch below, because the
# registry write near the end of the file expands it unconditionally. Set only
# in that branch, a plain informational alert (no --choices) died on `set -u`
# with "pid: unbound variable", exit 1, and no registry record at all — i.e.
# this file's own change broke every alert that is not an approval prompt.
# Caught in review 2026-09-12; the dry-run path returns before the write, which
# is why the existing suites could not see it.
pid=""
if [ "$choices" = 1 ] && [ -n "$pane" ]; then
  . "$_lib/prompt-parse.sh"
  # The Notification hook fires when the agent DECIDES it needs permission,
  # which can be before the TUI has painted the prompt box. Reading once loses
  # that race and silently degrades to scrollback, so the alert arrives without
  # the question — which is exactly the failure this whole feature exists to
  # avoid. Poll briefly for the options to appear. Costs nothing when they are
  # already there, and the hook is async so a short wait is free.
  #
  # BOTH prompt shapes, MENU first — the same order herdr-select.sh's
  # _current_offer() and prompt_id() now use. It was numbered-ONLY until
  # 2026-08-01, which made every omp alert unanswerable: omp renders an
  # Approve/Deny highlight menu with no numbers on screen, so prompt_options
  # always returned empty, the alert fell through to the plain-context branch,
  # and with no options there were no buttons, no "reply with 1/2" line, and
  # nothing written to pending.jsonl (so herdr-resolve.sh never tracked or
  # retracted it either). Observed live: the alert arrived and could only be
  # read, not acted on.
  #
  # The order was then numbered-first, and on an omp pane that is worse than
  # unanswerable — it is WRONGLY answerable. omp paints its steering queue
  # ("1. Conductor: …") above the panel, so prompt_options matched the QUEUE:
  # Slack rendered those lines as the choices while the button carried the
  # panel's fingerprint, and a click on "1" pressed Approve on a command the
  # operator never saw. The bridge sets HERDR_SELECT_VIA, so that click counts
  # as human authority and the command-policy gate does not run. Menu-first
  # closes it: an approval panel is described by the panel.
  #
  # prompt_menu_options numbers the rows 1..N top-to-bottom — deliberately the
  # same convention as prompt_options — so everything downstream (the threaded
  # number, the button values, herdr-select.sh) works unchanged and neither the
  # operator nor Slack ever needs to know which mechanism is being driven.
  opts=""
  mech=""
  pid=""
  for _ in 1 2 3 4 5 6 7 8; do
    opts=$(prompt_menu_options "$pane"); [ -n "$opts" ] && { mech=menu; break; }
    opts=$(prompt_options "$pane");      [ -n "$opts" ] && { mech=numbered; break; }
    sleep 0.25
  done
  # Fingerprint the prompt that produced THESE options, taken here rather than
  # after the body is built. prompt_id has no failure mode: with the prompt gone
  # it hashes two empty strings and returns the sha256 of a lone newline
  # (observed constant below). Shipping that as a button value posts buttons
  # that render as actionable but are refused on every click by herdr-select's
  # --expect-prompt-id check, which is worse than no fingerprint at all.
  [ -n "$opts" ] && pid=$(prompt_id "$pane")
  _EMPTY_PROMPT_ID=01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b
  if [ "$pid" = "$_EMPTY_PROMPT_ID" ]; then
    # The prompt vanished between the poll and this read, so we have options
    # but no question to pin them to. This used to fall back to a two-field
    # button value and post the buttons anyway, reasoning that herdr-select
    # still refuses unless the option is on offer. That reasoning is wrong on
    # the surface it matters most (review of PR #62, 2026-09-12): a Slack
    # button is IMMORTAL and carries human authority, and every omp approval
    # panel offers the same two labels — "Approve"/"Deny" — so the
    # option-still-on-offer check cannot tell one panel from another. An
    # unpinned button is therefore a permanent one-click Approve on whatever
    # question that pane shows next, with no policy gate.
    #
    # So: no fingerprint, no actionable alert. Drop the options and fall
    # through to the plain-context branch — the operator still gets told the
    # pane needs attention, and answers it in a terminal where the prompt is
    # actually visible.
    pid=""
    opts=""
    mech=""
  fi
  if [ -n "$opts" ]; then
    # The question extractor must MATCH the parser that produced the options.
    # prompt_question finds "the last non-empty line above the first numbered
    # option" — with no numbered option on screen it never stops early and
    # returns the last line of the window instead, which for omp is the TUI's
    # box-drawing rule. Choosing it by "is prompt_question empty" therefore does
    # not work: it is not empty, it is wrong, and the alert led with a row of
    # ─── characters where the command should be.
    if [ "$mech" = menu ]; then
      question=$(prompt_menu_question "$pane")
    else
      question=$(prompt_question "$pane")
    fi
    list=$(printf '%s\n' "$opts" | awk -F'\t' '{printf "  *%s.* %s\n", $1, $2}')
    nums=$(printf '%s\n' "$opts" | awk -F'\t' '{printf "%s%s", sep, $1; sep=", "}')
    body="$(_hdr)"
    [ -n "$question" ] && body="${body}"$'\n\n'"${question}"
    body="${body}"$'\n'"${list}"$'\n'"_Reply in thread with ${nums}._"
    # The button value carries the prompt FINGERPRINT as well as the target, so
    # a click can only ever answer the question the button was posted for. A
    # Slack message is permanent: without this, a button from a closed pane
    # stays armed forever and a click lands on whatever prompt occupies that
    # pane id next (herdr recycles them). herdr-select refuses on a mismatch.
    blocks=$(printf '%s\n' "$opts" | jq -R -s --arg body "$body" --arg pane "$pane" \
      --arg pid "$pid" '
      [ split("\n")[] | select(length>0) | split("\t") | {num:.[0], label:.[1]} ] as $o
      | [ {type:"section", text:{type:"mrkdwn", text:$body}},
          {type:"actions",
           elements: ($o | map({
             type:"button",
             text:{type:"plain_text", text:("\(.num). " + (.label|.[0:70]))},
             value:($pane + "|" + .num + (if $pid == "" then "" else "|" + $pid end)),
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
      # No numbered/menu options here, so pid stays empty — no real
      # fingerprint to dedupe on. Still worth deduping: hash pane+context so
      # repeated firings for this SAME plain-context prompt collapse to one
      # post too (PR #131 review, P2: this branch skipped dedupe entirely —
      # 3 firings, 3 posts). \x1e (record separator) joins pane and context
      # so a pane id that happens to be a prefix of the context text can
      # never collide with a different pane+context pairing.
      ctx_key=$(printf '%s\x1e%s' "$pane" "$ctx" | shasum -a 256 | cut -d' ' -f1)
    else
      nothing_to_show=1
    fi
  fi
fi

# ---- drop: the prompt this call was about is already gone -----------------
# choices=1 with no numbered/menu options AND no plain context means nothing
# is actually on screen to alert about — the common cause is the prompt was
# answered between the hook firing and this poll finishing. Posting the bare
# header anyway ("<agent> needs input  ·  <pane>") used to ship a
# content-free ping every time that race lost (SPEC: "anything already
# answered by the time the post would go out"). HERDR_SLACK_VERBOSE=1
# restores the old always-post behaviour.
if [ "${nothing_to_show:-0}" = 1 ] && [ "${HERDR_SLACK_VERBOSE:-0}" != 1 ]; then
  if [ "$dry" = 1 ]; then
    echo "dry-run: would SKIP — no prompt or context visible on $pane (already answered?)"
    exit 0
  fi
  echo "herdr-notify: no prompt or context visible for $pane; skipping (already answered?)" >&2
  exit 0
fi

# ---- dedupe: at most ONE Slack post per (pane, key), within a TTL --------
# Three hook firings for the same still-unanswered prompt used to post three
# times — see lib/alert-gate.sh's alert_claim for the measurement, the pane
# scoping, and the TTL-expiry reasoning (a global permanent ledger silently
# dropped a second pane's identical prompt, and any re-ask — PR #131 review,
# P1). dedupe_key falls back to ctx_key when there is no numbered-prompt
# fingerprint (the plain-context branch above — PR #131 review, P2).
# HERDR_SLACK_VERBOSE=1 restores the old always-post behaviour.
dedupe_key="${pid:-${ctx_key:-}}"
if [ -n "$dedupe_key" ] && [ "${HERDR_SLACK_VERBOSE:-0}" != 1 ]; then
  . "$_lib/alert-gate.sh"
  if [ "$dry" = 1 ]; then
    if alert_already_posted "$pane" "$dedupe_key"; then
      echo "dry-run: would SKIP — already alerted for $pane (duplicate)"
      exit 0
    fi
  elif ! alert_claim "$pane" "$dedupe_key"; then
    echo "herdr-notify: already alerted for $pane, skipping duplicate" >&2
    exit 0
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
  # This claim protected a send that did NOT happen — release it so a later
  # retry (grace_realert, the wake-fail backstop, a fresh hook firing) is not
  # permanently told "already posted" for a prompt Slack never actually saw.
  [ -n "$dedupe_key" ] && command -v alert_release >/dev/null 2>&1 && alert_release "$pane" "$dedupe_key"
  exit 1
fi
ts=$(printf '%s' "$resp" | jq -r '.ts')

# Record ts -> pane so a threaded reply resolves the target (bridge reads this).
if [ -n "$pane" ]; then
  reg_dir="${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}"
  mkdir -p "$reg_dir"
  # registry.jsonl/pending.jsonl here map Slack thread timestamps (and, via
  # herdr-select.sh, authorised choices) to live agent panes. `mkdir -p` alone
  # leaves the mode wherever the process umask lands — permissive on any host
  # that isn't already running with umask 077 — so a co-resident local user
  # could read or tamper with pane-routing state. Force 0700 explicitly every
  # time rather than relying on the umask of whichever script gets here first.
  chmod 700 "$reg_dir"
  reg="$reg_dir/registry.jsonl"
  # `pid` too, not just the pane. Without it a threaded reply had nothing to
  # pin itself to and landed on whatever prompt the pane showed by then
  # (detonation pass F1, 2026-09-12) — the alert could say "run the suite"
  # while the pane had moved on to a push. The bridge passes it back as
  # --expect-prompt-id, exactly as the button route already did.
  jq -nc --arg ts "$ts" --arg pane "$pane" --arg pid "$pid" '{ts:$ts,pane:$pane,prompt_id:$pid}' >> "$reg"
  # Track it as AWAITING AN ANSWER only if we actually showed a live prompt.
  # If you then answer in the terminal, herdr-resolve.sh retracts this message
  # so it does not sit in Slack looking pending. Informational alerts carry no
  # question, so they are never tracked and never deleted.
  #
  # Under the same mutex the sweep and herdr-select use: this is the only
  # APPENDER, and herdr-resolve's settle() does a jq-read then rename, so an
  # append landing inside that window would be dropped — an armed Slack message
  # with no record, which is precisely the un-retractable state this queue
  # exists to prevent. If the wait is exhausted, append anyway and say so: a
  # possibly-lost record beats never recording a live question at all.
  if [ -n "$blocks" ]; then
    . "$_lib/pending-queue.sh"
    _pl="$reg_dir/.pending.lock"
    pending_lock "$_pl" || echo "herdr-notify: pending queue locked; appending unserialised" >&2
    jq -nc --arg ts "$ts" --arg pane "$pane" '{ts:$ts,pane:$pane}' >> "$reg_dir/pending.jsonl"
    pending_unlock "$_pl"
  fi
  # Keep the registry bounded (last 500 alerts).
  if [ "$(wc -l < "$reg" 2>/dev/null || echo 0)" -gt 600 ]; then
    tail -n 500 "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
  fi
fi

echo "notified (ts=$ts pane=${pane:-none})"
