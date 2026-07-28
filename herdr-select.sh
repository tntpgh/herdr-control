#!/usr/bin/env bash
# herdr-select.sh <pane_id> <option-number> [--expect-prompt-id ID]
#
# Answer a numbered prompt an agent is showing, by pressing that option's key.
#
# This is the ONE path allowed to answer a permission prompt, and it exists
# because the alternative is worse: without it you get a notification you cannot
# act on, and the temptation is to let ordinary text delivery press Enter — which
# silently accepts whatever option happened to be highlighted. Here the human has
# read the actual options and named one. That is consent; a blind Enter is not.
#
# Everything below exists to keep that distinction true:
#   - the target must be an agent pane (shared gate, lib/pane-guard.sh)
#   - a prompt must actually be on screen RIGHT NOW
#   - the chosen number must be one of the options currently offered
#   - the choice is recorded before it is sent, so what was authorised is on
#     disk even if the keypress or the agent then misbehaves
#
# --expect-prompt-id closes a time-of-check/time-of-use gap that only matters
# once a decision and its injection can be separated in time (a conductor
# reads a pushed wake, decides, THEN calls this) — the options check above
# already re-reads the screen at call time, but nothing previously proved the
# prompt being answered is the SAME prompt the decision was made about. Pass
# the prompt_id captured at decision time (lib/prompt-parse.sh's prompt_id)
# and this refuses to press anything if the on-screen prompt has since
# changed, vanished, or the pane now belongs to a different task. Omit it and
# behavior is unchanged — a human deciding and pressing in one motion has no
# such gap.
#
# Exit 0 selected, 2 usage, 3 not an agent pane, 6 no prompt / bad option / prompt changed.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"

pane="${1:?usage: herdr-select.sh <pane_id> <option-number> [--expect-prompt-id ID]}"
choice="${2:?option number required}"
shift 2

expect_id=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-prompt-id) expect_id="${2:?--expect-prompt-id needs a value}"; shift 2 ;;
    *) echo "herdr-select: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

case "$choice" in
  ''|*[!0-9]*) echo "herdr-select: option must be a number, got '$choice'" >&2; exit 2 ;;
esac

require_agent_pane "$pane" || exit 3

options=$(prompt_options "$pane")
[ -n "$options" ] || {
  echo "herdr-select: $pane is not showing a numbered prompt — nothing to select." >&2
  echo "herdr-select: refusing to press a key into a pane that did not ask a question." >&2
  exit 6
}

label=$(printf '%s\n' "$options" | awk -F'\t' -v c="$choice" '$1==c {print $2; found=1} END{exit !found}') || {
  echo "herdr-select: option '$choice' is not on offer in $pane. Currently:" >&2
  printf '%s\n' "$options" | awk -F'\t' '{printf "  %s. %s\n", $1, $2}' >&2
  exit 6
}

# Right before we act — the closest this synchronous script can get to
# "immediately before injection" — confirm the prompt is still the one a
# decision was made about, if the caller told us which one that was.
current_prompt_id=$(prompt_id "$pane")
if [ -n "$expect_id" ] && [ "$current_prompt_id" != "$expect_id" ]; then
  echo "herdr-select: the prompt in $pane no longer matches the one the decision was made about." >&2
  echo "herdr-select: expected prompt_id $expect_id, currently $current_prompt_id — refusing to answer a different prompt." >&2
  exit 6
fi

# Record BEFORE sending. If the keypress fails or the agent does something
# unexpected, the audit trail still shows exactly what was authorised and when.
log_dir="${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}"
mkdir -p "$log_dir"
jq -nc --arg pane "$pane" --arg choice "$choice" --arg label "$label" \
       --arg via "${HERDR_SELECT_VIA:-cli}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg prompt_id "$current_prompt_id" \
  '{at:$at,pane:$pane,choice:($choice|tonumber),label:$label,via:$via,prompt_id:$prompt_id}' \
  >> "$log_dir/selections.jsonl"

# Claude's and Codex's selection prompts both take the bare digit — no Enter,
# which is the point: Enter is the keystroke that accepts a DEFAULT, and a
# default is precisely what we are refusing to send on someone's behalf.
herdr pane send-keys "$pane" "$choice" >/dev/null 2>&1 || {
  echo "herdr-select: failed to send key '$choice' to $pane" >&2
  exit 2
}

# Answered HERE, so stop tracking it as pending. herdr-resolve retracts alerts
# whose prompt has vanished — correct when you answered in the terminal, wrong
# when you answered in Slack: it would delete the very message carrying your
# choice and the confirmation under it. Untrack, and the record stays.
pending="$log_dir/pending.jsonl"
if [ -s "$pending" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/herdr-pending.XXXXXX") && {
    jq -c --arg p "$pane" 'select(.pane != $p)' < "$pending" > "$tmp" 2>/dev/null \
      && cat "$tmp" > "$pending"
    rm -f "$tmp"
  }
fi

echo "selected $choice ($label) in $pane"
