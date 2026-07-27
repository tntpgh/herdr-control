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
# Usage:  send-to-agent.sh <pane_id> [--force] <text>
#   pane_id   e.g. w2:p1 (from `herdr pane list` / pane-map.sh)
#   --force   send even if the pane looks like it is on a permission prompt
#   text      the prompt to inject (literal; quote it)
#
# Exit 0 SUBMITTED   — composer cleared (works for Claude TUI and shell panes).
# Exit 4 UNSUBMITTED — text still pinned as "[Pasted text …]" after retries, or
#                      the pane could not be read to confirm; either way the
#                      caller MUST NOT assume the peer received it.
# Exit 5 REFUSED     — pane appears to be showing a permission/confirmation
#                      prompt (Enter would pick its default), or is unreadable.
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

pane="${1:?usage: send-to-agent.sh <pane_id> [--force] <text>}"; shift
force=0
if [ "${1:-}" = "--force" ]; then force=1; shift; fi
text="${1:?text required}"

# stuck-paste signature: the composer still holds an unsubmitted paste.
# 0 = stuck, 1 = clear, 2 = COULD NOT READ.
# The unreadable case must stay distinct: this used to `return 1` on a failed
# read, and the caller reads 1 as "clear" — so a socket hiccup was reported as
# SUBMITTED and relayed to Slack with a checkmark, which is exactly the false
# assurance the header promises not to give.
composer_has_stuck_paste() {
  local vis
  vis=$(herdr pane read "$pane" --source visible --lines 10 2>/dev/null) || return 2
  printf '%s' "$vis" | tail -n 8 | grep -Fq '[Pasted text' && return 0
  return 1
}

# A pane whose agent is BLOCKED is usually sitting on a permission prompt, not an
# empty composer. There, typed text is largely inert and the Enter we send lands
# on the highlighted DEFAULT option — so an innocuous reply becomes an approval.
# The default Slack route (bare text -> the one blocked agent) is the most likely
# to hit this, and spawn-task launches Claude with --permission-mode acceptEdits,
# so the blast radius is real. Refuse by default; --force is the deliberate
# override. Unreadable also refuses: if we cannot see what we are answering, we
# do not answer it.
# 0 = prompt visible, 1 = no prompt, 2 = could not read.
#
# Only the BOTTOM of the pane is examined. A live prompt is anchored there, while
# text we just delivered scrolls up — matching the whole viewport meant a message
# that merely CONTAINED "Do you want" refused every later send to that pane.
#
# Patterns cover more than Claude's first option: any arrowed selection (❯ 2.,
# ❯ 3.), y/n and [Y/n] confirmations, and Codex's approval wording, since
# spawn-task launches codex too. This is a heuristic and cannot be exhaustive —
# it is the reason --force exists.
# The composer sits INSIDE the bottom window, so this reads back our own text.
# Bare words are therefore unusable: "Approve the PR once CI is green" and
# "Do you want me to update the tests too" are ordinary instructions, and
# matching them stranded the message in the composer. Require STRUCTURE that
# prose does not have — a selected numbered option (❯ 2.) together with a
# numbered option list, or an explicit y/n bracket.
_PROMPT_ARROW='❯[[:space:]]*[0-9]+\.'
_PROMPT_OPTION='^[[:space:]]*[0-9]+\.[[:space:]]'
_PROMPT_YN='\([Yy]/[Nn]\)|\[[Yy]/[Nn]\]'

looks_like_permission_prompt() {
  local vis win
  vis=$(herdr pane read "$pane" --source visible --lines 30 2>/dev/null) || return 2
  win=$(printf '%s' "$vis" | tail -n 12)
  printf '%s' "$win" | grep -Eq "$_PROMPT_YN" && return 0
  printf '%s' "$win" | grep -Eq "$_PROMPT_ARROW" \
    && printf '%s' "$win" | grep -Eq "$_PROMPT_OPTION" && return 0
  return 1
}

if [ "$force" -eq 0 ]; then
  looks_like_permission_prompt; pr=$?
  if [ "$pr" -eq 0 ]; then
    echo "REFUSED: $pane is showing what looks like a permission/confirmation prompt." >&2
    echo "REFUSED: Enter would select its default option. Answer it yourself, or re-send with --force." >&2
    exit 5
  fi
  if [ "$pr" -eq 2 ]; then
    echo "REFUSED: cannot read $pane to check for a pending prompt — refusing to send blind (use --force)." >&2
    exit 5
  fi
fi

# `herdr agent send` DOES NOT EXIST — the agent verbs are list/get/read/
# send-keys/prompt/rename/focus/wait/attach. This call therefore failed on EVERY
# invocation, which silently killed the Slack->herdr reply path: a choice tapped
# in Slack never reached the pane. Use the pane API, which the Enter loop below
# already uses, so the whole script speaks one interface.
herdr pane send-text "$pane" "$text" >/dev/null 2>&1 || {
  echo "ERROR: 'herdr pane send-text $pane' failed — pane target valid? socket allowlisted?" >&2
  exit 2
}

# Retry Enter until the paste placeholder is gone. First Enter submits a small
# message (or runs a shell command) immediately; a large collapsed paste may
# take a couple of Enters past the debounce. The read between attempts is the
# settle. Cap the attempts so a genuinely stuck send reports honestly.
unreadable=0
for _ in 1 2 3 4 5 6; do
  # Re-check before EVERY Enter, not just the first. The agent processes our
  # text between iterations and can raise a permission prompt mid-loop — firing
  # the remaining Enters into it would answer it with its default, which is
  # exactly what the pre-send guard exists to prevent. A guard that only runs
  # once protects the first keystroke and nothing after it.
  if [ "$force" -eq 0 ]; then
    looks_like_permission_prompt; pr=$?
    if [ "$pr" -eq 0 ]; then
      echo "REFUSED: a prompt appeared in $pane mid-submit — stopping rather than answering it." >&2
      echo "REFUSED: the text was delivered but NOT submitted; finish it by hand." >&2
      exit 5
    fi
  fi
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || {
    echo "ERROR: 'herdr pane send-keys $pane Enter' failed" >&2
    exit 2
  }
  composer_has_stuck_paste; st=$?
  if [ "$st" -eq 1 ]; then
    echo "SUBMITTED: $pane composer cleared"
    exit 0
  fi
  [ "$st" -eq 2 ] && unreadable=1
done

if [ "$unreadable" -eq 1 ]; then
  echo "UNCONFIRMED: could not read $pane to verify the submit — do NOT assume it landed" >&2
  exit 4
fi
echo "UNSUBMITTED: text still pinned as [Pasted text] in $pane after 6 Enters — deliver by hand" >&2
exit 4
