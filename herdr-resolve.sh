#!/usr/bin/env bash
# herdr-resolve.sh — retract Slack alerts whose prompt has already been answered.
#
# If you answer a permission prompt in the terminal (herdr / iTerm / the TUI),
# the Slack alert for it is now a lie: it sits there looking pending, and the
# only way to find out it is stale is to reply and get a refusal. That trains
# you to distrust the alerts, which is worse than not sending them.
#
# So: for every alert we recorded as awaiting an answer, if its pane is no
# longer showing a numbered prompt — or no longer EXISTS — the question is
# settled or unanswerable, so the message goes.
#
# Deliberately conservative:
#   - only alerts herdr-notify recorded as HAVING a live prompt are tracked, so
#     ordinary informational alerts are never deleted
#   - a pane that still exists but cannot be READ is left alone (unreadable !=
#     answered); a pane herdr no longer lists is GONE, and an alert for a gone
#     pane can never be answered by anyone, so it is retracted
#   - if the pane list itself cannot be read, nothing is treated as gone
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
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# Retraction budget for ONE run. chat.delete is rate limited and this runs from
# an async hook (10s timeout in settings.example.json), so the work per pass is
# bounded and the queue drains across passes rather than being truncated
# mid-sweep. The normal case is 1–2 alerts and never reaches either limit.
# The budget must FIT the hook's 10s timeout: 3 deletes are 2 x PACE of sleep
# plus 3 round trips. The first draft said 8 at 1s, which cannot finish — and
# with the old end-of-run rewrite that meant the queue was never persisted and
# the sweep re-deleted the same messages on every tool call forever.
MAX="${HERDR_RESOLVE_MAX_PER_RUN:-3}"
PACE="${HERDR_RESOLVE_PACE_S:-1}"
# Give up on an alert Slack has refused for this many days. See the check in the
# loop: the keep-on-uncertain rule has no other bound.
MAX_AGE_D="${HERDR_RESOLVE_MAX_AGE_D:-7}"
done_n=0
# Test seam: the suite stubs the Slack call, since asserting on rate-limit and
# unreachable handling is the entire point and neither can be provoked for real.
CURL="${HERDR_RESOLVE_CURL:-curl}"

# Fast path: nothing outstanding. This is the overwhelmingly common case, and it
# must stay free — no pane list, no credential, no Slack.
[ -s "$PENDING" ] || exit 0

. "$here/lib/prompt-parse.sh"

# A dry run deletes nothing, so it must not ask for a credential: the real
# bridge env resolves both tokens through `op read`, which falls back to a
# 1Password Touch ID prompt in any shell without OP_SERVICE_ACCOUNT_TOKEN.
# Same rule as herdr-notify's --dry-run prescan — a check must never need a
# human finger.
user=""
if [ "$DRY" = 0 ]; then
  ENV_FILE="${HERDR_BRIDGE_ENV:-$HOME/.config/herdr-bridge.env}"
  [ -f "$ENV_FILE" ] || exit 0
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || exit 0
  [ -n "${SLACK_BOT_TOKEN:-}" ] || exit 0
  user="${HERDR_BRIDGE_ALLOW_USERS%%,*}"
  [ -n "$user" ] || exit 0
fi

# One pane-list call for the whole sweep. A pane herdr no longer lists cannot
# paint a prompt, cannot be answered from Slack, and will never be resolved by
# anyone — its alert is pure noise. But "no list" must never read as "everything
# is gone", so an unreadable or empty list disables gone-detection entirely
# instead of deleting the queue.
live_panes=$(herdr pane list 2>/dev/null \
  | jq -r '(.result.panes // .panes)[]?.pane_id // empty' 2>/dev/null)

# Serialise the sweep against the other two writers. Bounded wait plus stale
# reclaim live in lib/pending-queue.sh — a one-shot `mkdir || exit` skipped the
# work whenever any other session was mid-sweep, and a SIGKILL at the hook
# timeout left the lock behind and stopped retraction permanently.
. "$here/lib/pending-queue.sh"
lockdir="$STATE/.pending.lock"
if [ "$DRY" = 0 ]; then
  pending_lock "$lockdir" || exit 0
  trap 'pending_unlock "$lockdir"' EXIT HUP INT TERM
fi

# Work from a snapshot, but NEVER write the snapshot back. herdr-notify appends
# a new alert the moment a worker hits a prompt, and herdr-select removes the
# one answered in Slack; a `cat snapshot > pending.jsonl` at the end of a
# multi-second sweep would erase an alert that arrived mid-sweep (leaving a
# live, armed Slack message with no record, permanently un-retractable) and
# resurrect one that was legitimately untracked (so the next pass would delete
# the message carrying the operator's own decision). Both are the failure
# classes this file exists to prevent.
#
# Instead each settled entry is subtracted from the LIVE file by its ts, so
# concurrent appends survive by construction.
snapshot=$(mktemp "${TMPDIR:-/tmp}/herdr-pending.XXXXXX") || exit 0
trap 'rm -f "$snapshot"; [ "$DRY" = 1 ] || pending_unlock "$lockdir"' EXIT HUP INT TERM
cp "$PENDING" "$snapshot" || exit 0

settle() { pending_drop "$PENDING" ts "$1"; }

while IFS= read -r line; do
  [ -n "$line" ] || continue
  ts=$(printf '%s' "$line" | jq -r '.ts // empty' 2>/dev/null)
  pane=$(printf '%s' "$line" | jq -r '.pane // empty' 2>/dev/null)
  if [ -z "$ts" ] || [ -z "$pane" ]; then continue; fi
  # BUDGET FIRST, before any per-entry RPC. Checking it after the pane probes
  # made a run cost O(queue), not O(MAX): three herdr RPCs plus a prompt parse
  # per still-listed pane, on every queued line, on every tool call in every
  # session. With the (correct) keep-on-uncertain rule a stuck queue then makes
  # every hook run exceed the same 10s timeout the lock's safety depends on.
  # A dry run has no budget: its whole job is to report the entire queue.
  if [ "$DRY" = 0 ] && [ "$done_n" -ge "$MAX" ]; then continue; fi

  # Bound the queue in TIME. `keep unless definitive` is right, but Slack has
  # permanent refusals this cannot enumerate (missing_scope,
  # compliance_exports_prevent_deletion, ekm_access_denied, org_login_required),
  # and nothing trims this file the way herdr-notify trims registry.jsonl. An
  # entry that has failed for days is not going to succeed; keeping it forever
  # pins the queue and burns the per-run budget on it every pass.
  if [ "$DRY" = 0 ] && [ -n "${ts%%.*}" ] \
     && [ "$(( $(date +%s) - ${ts%%.*} ))" -gt "$(( MAX_AGE_D * 86400 ))" ]; then
    echo "herdr-resolve: giving up on alert ts=$ts pane=$pane after ${MAX_AGE_D}d" \
         "— it is still in Slack; delete it by hand if it matters" >&2
    settle "$ts"
    continue
  fi

  gone=0
  if [ -n "$live_panes" ] && ! printf '%s\n' "$live_panes" | grep -qxF "$pane"; then
    gone=1
  fi
  if [ "$gone" = 0 ]; then
    # Unreadable but still-listed pane: leave the alert queued. We cannot prove
    # it was answered, and deleting on "no evidence" drops live questions.
    # "Queued" now means "not settled" — nothing is rewritten, so skipping is
    # all it takes to keep an entry.
    if ! herdr pane read "$pane" --source visible --lines 5 >/dev/null 2>&1; then
      continue
    fi
    # Still asking: keep. BOTH prompt shapes, or this deletes live questions —
    # omp's approval prompt is an arrow menu with no numbers on screen, so a
    # prompt_options-only check reads every one of them as already answered and
    # retracts an alert whose worker is still blocked on it.
    if [ -n "$(prompt_options "$pane")$(prompt_menu_options "$pane")" ]; then
      continue
    fi
  fi

  if [ "$DRY" = 1 ]; then
    printf 'retract ts=%s pane=%s (%s)\n' "$ts" "$pane" \
      "$([ "$gone" = 1 ] && echo 'pane gone' || echo 'prompt answered')"
    continue
  fi

  [ "$done_n" = 0 ] || sleep "$PACE"
  done_n=$((done_n + 1))

  # Answered elsewhere, or unanswerable — retract it.
  resp=$(printf 'header = "Authorization: Bearer %s"\n' "$SLACK_BOT_TOKEN" \
    | $CURL -s -X POST --config - -H 'Content-type: application/json' \
        --data "$(jq -nc --arg c "$user" --arg ts "$ts" '{channel:$c,ts:$ts}')" \
        https://slack.com/api/chat.delete 2>/dev/null)
  ok=$(printf '%s' "$resp" | jq -r '.ok // false' 2>/dev/null)
  err=$(printf '%s' "$resp" | jq -r '.error // empty' 2>/dev/null)

  # KEEP unless the outcome is definitive. The rule is deliberately inverted:
  # an allowlist of retryable errors meant every UNLISTED `ok:false` dropped the
  # entry with the message still in Slack — and `invalid_auth` / `token_expired`
  # / `token_revoked` / `not_authed` / `account_inactive` are exactly that. A
  # rotated bot token would then drain the whole queue within seconds (the hook
  # fires on every tool call in every session), leaving armed alerts in Slack
  # with no ts->pane record left, so no later run could ever retract them: the
  # very failure this file exists to prevent, made permanent.
  #
  # Definitive means "asking again cannot change the answer": the message is
  # gone, or Slack will refuse this delete forever.
  case "$ok:$err" in
    true:*) ;;                        # deleted
    *:message_not_found|*:cant_delete_message|*:msg_too_old|*:channel_not_found|*:bad_timestamp) ;;
    *) continue ;;                    # anything else (incl. no reply at all): keep, retry next pass
  esac
  settle "$ts"
done < "$snapshot"
