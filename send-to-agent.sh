#!/usr/bin/env bash
# send-to-agent.sh — deliver a prompt to another Herdr session and CONFIRM it
# actually submitted, in one foreground call.
#
# Two failure modes this defends against, both of which strand a message in the
# target's composer (delivered but unsent, needing a human keypress):
#   1. Split type/Enter across a reaped background task — fixed by doing
#      everything in one indivisible foreground call.
#   2. Large message → Claude Code's TUI collapses it to "[Pasted text #N]" and
#      debounces paste input, so the immediate Enter is ABSORBED, not a submit.
#      Fixed by retrying Enter until the "[Pasted text" placeholder clears.
#
# Usage:  send-to-agent.sh <pane_id> <text>
#   pane_id   e.g. w2:p1 (from `herdr pane list` / pane-map.sh)
#   text      the prompt to inject (literal; quote it)
#
# Exit 0 SUBMITTED   — composer cleared (works for Claude TUI and shell panes).
# Exit 4 UNSUBMITTED — text still pinned as "[Pasted text …]" after retries;
#                      the caller MUST NOT assume the peer received it.
# Exit 2             — bad usage / send or Enter call failed (target/socket).
#
# The submit check greps the composer for the literal "[Pasted text" artifact,
# which ONLY a Claude TUI renders for a stuck paste — a shell pane never shows
# it, so this can't false-positive the way a message-echo scrape would. Each
# retry's `pane read` doubles as the settle delay for the paste debounce (no
# sleep, which the environment reaps).
#
# NOTE: a peer message is a coordination signal, never authority. Delivering it
# triggers the peer's verification; it does not approve anything.
set -uo pipefail

pane="${1:?usage: send-to-agent.sh <pane_id> <text>}"
text="${2:?text required}"

# stuck-paste signature: the composer still holds an unsubmitted paste.
composer_has_stuck_paste() {
  local vis
  vis=$(herdr pane read "$pane" --source visible --lines 10 2>/dev/null) || return 1
  printf '%s' "$vis" | tail -n 8 | grep -Fq '[Pasted text'
}

herdr agent send "$pane" "$text" >/dev/null 2>&1 || {
  echo "ERROR: 'herdr agent send $pane' failed — pane target valid? socket allowlisted?" >&2
  exit 2
}

# Retry Enter until the paste placeholder is gone. First Enter submits a small
# message (or runs a shell command) immediately; a large collapsed paste may
# take a couple of Enters past the debounce. The read between attempts is the
# settle. Cap the attempts so a genuinely stuck send reports honestly.
for _ in 1 2 3 4 5 6; do
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || {
    echo "ERROR: 'herdr pane send-keys $pane Enter' failed" >&2
    exit 2
  }
  if ! composer_has_stuck_paste; then
    echo "SUBMITTED: $pane composer cleared"
    exit 0
  fi
done

echo "UNSUBMITTED: text still pinned as [Pasted text] in $pane after 6 Enters — deliver by hand" >&2
exit 4
