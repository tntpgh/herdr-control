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
# 5 target looks like it is sitting on a permission prompt (refused),
# 7 target pane was recycled since its registered task was spawned (refused).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"
here=$(cd "$(dirname "$0")" && pwd)

# --force must come FIRST, before the target. The Slack bridge always passes the
# target as its own first argv element, so attacker-controlled message text can
# never land in this position — the override stays a human-at-a-terminal act and
# is deliberately NOT reachable from Slack, which is the whole point of the
# permission-prompt guard it overrides.
force=""
if [ "${1:-}" = "--force" ]; then force="--force"; shift; fi

target="${1:?usage: herdr-deliver.sh [--force] <pane|tab|label|--blocked> <text...>}"; shift
text="$*"
[ -n "$text" ] || { echo "herdr-deliver: empty message" >&2; exit 2; }

panes=$(herdr pane list 2>/dev/null) || { echo "herdr-deliver: pane list failed" >&2; exit 1; }

# A pane id from Slack is untrusted. Delivery is "write literal text, then press
# Enter" — in an agent that is a prompt, but in a plain SHELL pane it is a
# command. The gate for that lives in lib/pane-guard.sh, shared with
# herdr-select.sh so the two input paths cannot drift apart.
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"

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

# herdr-select.sh already does this unconditionally before pressing a key;
# herdr-deliver.sh didn't, which left the Slack free-text reply path (the
# common case: a threaded reply resolves via a pane id recorded in the
# bridge's OWN registry.jsonl at alert time, with no freshness check of its
# own) able to misdeliver into a pane that was closed and reissued to an
# unrelated process since the alert fired. Only enforces when the target IS
# a registered task's pane (spawn-agent.sh panes have nothing to check
# against and pass through unchanged, same as herdr-select.sh).
require_pane_birth_match "$pane" || exit 7

bash "$here/send-to-agent.sh" "$pane" ${force:+"$force"} "$text"
rc=$?
[ "$rc" -eq 0 ] && echo "delivered to $pane" || echo "herdr-deliver: send to $pane returned $rc (may be stranded)" >&2
exit "$rc"
