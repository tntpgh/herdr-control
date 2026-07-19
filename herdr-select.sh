#!/usr/bin/env bash
# herdr-select.sh <pane_id> <option-number>
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
# Exit 0 selected, 2 usage, 3 not an agent pane, 6 no prompt / bad option.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"

pane="${1:?usage: herdr-select.sh <pane_id> <option-number>}"
choice="${2:?option number required}"

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

# Record BEFORE sending. If the keypress fails or the agent does something
# unexpected, the audit trail still shows exactly what was authorised and when.
log_dir="${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}"
mkdir -p "$log_dir"
jq -nc --arg pane "$pane" --arg choice "$choice" --arg label "$label" \
       --arg via "${HERDR_SELECT_VIA:-cli}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{at:$at,pane:$pane,choice:($choice|tonumber),label:$label,via:$via}' \
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
