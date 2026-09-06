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
MAX="${HERDR_RESOLVE_MAX_PER_RUN:-8}"
PACE="${HERDR_RESOLVE_PACE_S:-1}"
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

keep=$(mktemp "${TMPDIR:-/tmp}/herdr-pending.XXXXXX") || exit 0
trap 'rm -f "$keep"' EXIT HUP INT TERM

while IFS= read -r line; do
  [ -n "$line" ] || continue
  ts=$(printf '%s' "$line" | jq -r '.ts // empty' 2>/dev/null)
  pane=$(printf '%s' "$line" | jq -r '.pane // empty' 2>/dev/null)
  if [ -z "$ts" ] || [ -z "$pane" ]; then continue; fi

  gone=0
  if [ -n "$live_panes" ] && ! printf '%s\n' "$live_panes" | grep -qxF "$pane"; then
    gone=1
  fi
  if [ "$gone" = 0 ]; then
    # Unreadable but still-listed pane: keep the alert. We cannot prove it was
    # answered, and deleting on "no evidence" would silently drop live questions.
    if ! herdr pane read "$pane" --source visible --lines 5 >/dev/null 2>&1; then
      printf '%s\n' "$line" >> "$keep"; continue
    fi
    # Still asking: keep. BOTH prompt shapes, or this deletes live questions —
    # omp's approval prompt is an arrow menu with no numbers on screen, so a
    # prompt_options-only check reads every one of them as already answered and
    # retracts an alert whose worker is still blocked on it.
    if [ -n "$(prompt_options "$pane")$(prompt_menu_options "$pane")" ]; then
      printf '%s\n' "$line" >> "$keep"; continue
    fi
  fi

  if [ "$DRY" = 1 ]; then
    printf 'retract ts=%s pane=%s (%s)\n' "$ts" "$pane" \
      "$([ "$gone" = 1 ] && echo 'pane gone' || echo 'prompt answered')"
    continue
  fi

  # Bound the deletes per run. chat.delete is rate limited (~1/s sustained) and
  # this runs from an async hook with a 10s timeout, so a large backlog must
  # drain across runs instead of being cut off mid-sweep. Everything past the
  # budget stays queued, untouched.
  if [ "$done_n" -ge "$MAX" ]; then
    printf '%s\n' "$line" >> "$keep"; continue
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
  # Drop it only on a DEFINITIVE answer: deleted, or a refusal that will refuse
  # again (message_not_found, cant_delete_message, …). Keep it when Slack was
  # unreachable — and keep it when Slack said "not now": `ratelimited` and the
  # 5xx-class errors are retryable, and treating them as definitive silently
  # loses the retraction. Observed live 2026-09-06: sweeping 85 orphans at
  # ~5/s got the last 2 rate limited, and both were dropped from the queue as
  # though deleted — they were still sitting in Slack afterwards.
  case "$err" in
    ratelimited|internal_error|service_unavailable|fatal_error|request_timeout|accesslimited)
      printf '%s\n' "$line" >> "$keep"; continue ;;
  esac
  if [ "$ok" != true ] && [ -z "$ok" ]; then
    printf '%s\n' "$line" >> "$keep"
  fi
done < "$PENDING"

# A dry run reports; it never rewrites the queue.
[ "$DRY" = 1 ] || cat "$keep" > "$PENDING"
