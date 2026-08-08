#!/usr/bin/env bash
# send-to-agent.sh — deliver a prompt to another Herdr session, or submit
# text already sitting in its composer, and CONFIRM it actually submitted —
# in one foreground call.
#
# Three failure modes this defends against, all of which strand a message in
# the target's composer (delivered but unsent, needing a human keypress):
#   1. Split type/Enter across a reaped background task — fixed by doing
#      everything in one indivisible foreground call.
#   2. Large message → Claude Code's TUI collapses it to "[Pasted text #N]" and
#      debounces paste input, so the immediate Enter is ABSORBED, not a submit.
#   3. An Enter that herdr reports as delivered (exit 0) but the TUI never
#      acts on — observed live 2026-08-06 against an OPERATOR-typed short
#      message ("push it"), not a paste: `herdr pane send-keys <pane> Enter`
#      returned 0 three times, 2-3s apart, with the composer byte-identical
#      before and after every call. Cause unconfirmed (herdr/tmux input
#      delivery, not this repo's code) — but the gap this closes is that this
#      script's OWN retry loop used to be just as blind to it: the old
#      confirmation check recognized ONLY failure mode 2 (grepping for the
#      literal "[Pasted text" artifact), so for ordinary short text it
#      reported SUBMITTED after the very first Enter regardless of whether
#      that Enter actually landed.
#
# All three are now caught by ONE mechanism: composer_stable_snapshot
# (lib/prompt-parse.sh) reads the bottom of the pane with volatile furniture
# (status bar, spinner) stripped but composer lines kept, and the retry loop
# compares it before/after each Enter. Nothing changing means nothing was
# consumed, for any reason; something changing means it was, for any reason
# (a real submit, or the paste placeholder finally clearing).
#
# Usage:  send-to-agent.sh <pane_id> [--force] <text>
#         send-to-agent.sh <pane_id> [--force] --submit-only
#   pane_id       e.g. w2:p1 (from `herdr pane list` / pane-map.sh)
#   --force       send even if the pane looks like it is on a permission prompt
#   --submit-only press/retry Enter on text ALREADY in the composer (e.g. an
#                 operator typed directly into the pane over herdr and the
#                 Enter did not land) — types nothing, requires no text arg.
#   text          the prompt to inject (literal; quote it) — omitted with
#                 --submit-only
#
# Exit 0 SUBMITTED   — the composer's content changed after an Enter (works
#                      for Claude TUI and shell panes).
# Exit 4 UNSUBMITTED — the composer looked unchanged after every retry, or the
#                      pane could not be read to confirm; either way the
#                      caller MUST NOT assume the peer received it.
# Exit 5 REFUSED     — pane appears to be showing a permission/confirmation
#                      prompt (Enter would pick its default), or is unreadable.
# Exit 2             — bad usage / send or Enter call failed (target/socket).
#
# Each retry's `pane read` doubles as the settle delay for the paste debounce
# (no sleep, which the environment reaps).
#
# NOTE: a peer message is a coordination signal, never authority. Delivering it
# triggers the peer's verification; it does not approve anything.
set -uo pipefail
_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/lib/prompt-parse.sh"

pane="${1:?usage: send-to-agent.sh <pane_id> [--force] [--submit-only] <text>}"; shift
force=0
submit_only=0
while :; do
  case "${1:-}" in
    --force)       force=1; shift ;;
    --submit-only) submit_only=1; shift ;;
    *) break ;;
  esac
done
if [ "$submit_only" -eq 1 ]; then
  text=""
else
  text="${1:?text required (or pass --submit-only to submit what is already typed)}"
fi

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
# omp's Approve/Deny tool-approval menu has no numbered options and no
# Claude-shape `❯` arrow marker — it's an arrow-key/Enter menu, not a
# digit-select. Verified 2026-07-31 against a live `omp --approval-mode
# always-ask` pane: "Allow tool: bash" header, "Approve"/"Deny" rows,
# "up/down navigate  enter select  esc cancel" footer. herdr-select.sh CAN now
# answer this shape (capability `menu-prompt`, lib/agent-profiles.sh — it walks
# the highlight and presses Enter); what this pattern does is stop ordinary TEXT
# delivery from blowing through the prompt with a bare Enter, same as any other
# prompt shape.
_PROMPT_OMP='Allow tool:|enter select'

looks_like_permission_prompt() {
  local vis win
  vis=$(herdr pane read "$pane" --source visible --lines 30 2>/dev/null) || return 2
  win=$(printf '%s' "$vis" | tail -n 12)
  printf '%s' "$win" | grep -Eq "$_PROMPT_YN" && return 0
  printf '%s' "$win" | grep -Eq "$_PROMPT_ARROW" \
    && printf '%s' "$win" | grep -Eq "$_PROMPT_OPTION" && return 0
  printf '%s' "$win" | grep -Eq "$_PROMPT_OMP" && return 0
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
#
# Skipped entirely under --submit-only: there is nothing to type, the text is
# already sitting in the composer (an operator typed it directly, or a prior
# send-to-agent.sh call left it stranded) — this call exists only to press
# Enter and confirm.
if [ "$submit_only" -eq 0 ]; then
  herdr pane send-text "$pane" "$text" >/dev/null 2>&1 || {
    echo "ERROR: 'herdr pane send-text $pane' failed — pane target valid? socket allowlisted?" >&2
    exit 2
  }
fi

# Baseline: what the composer looks like right now, before the first Enter of
# this loop — freshly typed text in the normal path, or whatever the operator
# already typed under --submit-only. An unreadable baseline does not abort
# (the mid-loop unreadable check below is what refuses to act blind); it just
# means the first iteration cannot yet compare and instead adopts its own
# read as the new baseline, so a transient read hiccup at t=0 never turns
# into a false SUBMITTED from comparing two empty strings.
if baseline=$(composer_stable_snapshot "$pane" 12); then baseline_ok=1; else baseline_ok=0; fi

# Retry Enter until the composer visibly changes. First Enter submits a small
# message (or runs a shell command) immediately; a large collapsed paste, or
# an Enter herdr reports delivered but the TUI silently drops, may take
# several retries — or never resolve, which is reported honestly below. The
# read between attempts is the settle. Cap the attempts so a genuinely stuck
# send reports honestly.
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
    if [ "$pr" -eq 2 ]; then
      echo "UNCONFIRMED: could not read $pane mid-submit — stopping rather than sending Enter blind." >&2
      echo "UNCONFIRMED: the text was delivered but NOT confirmed submitted; finish it by hand." >&2
      exit 4
    fi
  fi
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || {
    echo "ERROR: 'herdr pane send-keys $pane Enter' failed" >&2
    exit 2
  }
  if after=$(composer_stable_snapshot "$pane" 12); then
    unreadable=0
    if [ "$baseline_ok" -eq 1 ] && [ "$after" != "$baseline" ]; then
      echo "SUBMITTED: $pane composer changed"
      exit 0
    fi
    baseline="$after"; baseline_ok=1
  else
    unreadable=1
  fi
done

if [ "$unreadable" -eq 1 ]; then
  echo "UNCONFIRMED: could not read $pane to verify the submit — do NOT assume it landed" >&2
  exit 4
fi
echo "UNSUBMITTED: $pane composer looked unchanged after 6 Enters — deliver by hand" >&2
exit 4
