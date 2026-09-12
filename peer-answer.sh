#!/usr/bin/env bash
# peer-answer.sh — keep answering allow-class approval prompts on a set of
# agent panes, as a PEER, until the panes are gone or the round budget is spent.
#
#   peer-answer.sh [--interval S] [--max-rounds N] [--cwd-prefix DIR] [--agent LABEL] [pane_id ...]
#
# Why it exists: an omp session started outside spawn-task.sh (a weawr lab
# worker, a hand-started pane) gets no push-wake (agent-hooks/omp-notify.sh),
# so under `--approval-mode write` it blocks on EVERY exec — `pwd`, `git
# status`, the test suite — until someone presses Approve. Measured on the
# plan-012 smoke run 2026-09-12: a 20-second task took 6 minutes, all of it
# waiting on a human for two read-only commands.
#
# What it does NOT do: decide anything. Every keypress goes through
# herdr-select.sh with --authority peer, which is the ONE path allowed to
# answer a prompt and which presses nothing unless the panel is a COMPLETE
# recognized `Allow tool:` menu whose command classifies `allow` AND is not on
# the human-reserved list (merge/push to main, credential values, remote
# mutation, governance, control weakening — docs/approval-policy.md rule 1).
# On a complete omp panel option 1 is always Approve (lib/prompt-parse.sh
# `_prompt_menu` emits the fixed pair 1 Approve / 2 Deny); the loop only calls
# herdr-select when `prompt_menu_options` reports that complete panel, so the
# numbered-prompt fallback inside herdr-select is never reached from here.
#
# How this path meets docs/approval-policy.md, rule by rule:
#   1  peer only: the loop adds no authority; refusal is herdr-select's.
#   2  decided/attempted/confirmed are herdr-select's three records; a
#      keypress this loop caused is attributable to the approvals row it wrote.
#   3  revalidation before injection is herdr-select's (pane birth, re-offer,
#      current decision); this loop re-reads the pane list every round and
#      never caches a prompt across rounds.
#   4  capability is declared, not sniffed: --agent (default `omp`) selects
#      only panes whose reported agent is one `agent_has_capability … menu-prompt`
#      declares; furniture text is checked after that, never instead of it.
#   7  this IS an executory loop, and it is attended in the policy's sense: it
#      exercises only the peer default that a human already granted to
#      automation, on same-user host workers, and everything it presses is
#      auditable in `approvals`. It holds no credential and no control socket.
#
# A policy refusal (rc=8) is reported once per prompt and left on screen for a
# human — never retried, never a bare Enter. Any OTHER failure (torn frame,
# audit write, pane recycled) is logged and simply re-examined next round: a
# transient error must not strand an allow-class prompt.
#
# Two locks (mkdir, lib/pending-queue.sh style): one per pane around the
# keypress so two loops cannot double-Enter, and one per instance keyed by
# the watch set so a restarted loop refuses to run beside a live one.
#
# Exit: 0 when explicit panes are all gone (or nothing to watch at the round
# budget), 3 when --max-rounds is spent with panes still live, 2 on a missing
# dependency or a live duplicate instance.
set -uo pipefail
command -v herdr >/dev/null 2>&1 || { echo "peer-answer: herdr not on PATH" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"
. "$here/lib/agent-profiles.sh"

interval=10; max=0; prefix=""; agent_label="omp"; panes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) interval="${2:?}"; shift 2 ;;
    --max-rounds) max="${2:?}"; shift 2 ;;
    --cwd-prefix) prefix="${2:?}"; shift 2 ;;
    --agent) agent_label="${2:?}"; shift 2 ;;
    *) panes+=("$1"); shift ;;
  esac
done
[ -n "$prefix" ] || [ "${#panes[@]}" -gt 0 ] || {
  echo "usage: peer-answer.sh [--interval S] [--max-rounds N] [--cwd-prefix DIR] [--agent LABEL] [pane_id ...]" >&2; exit 2; }
prefix="${prefix%/}"
agent_has_capability "$agent_label" menu-prompt || {
  echo "peer-answer: agent '$agent_label' does not declare menu-prompt (lib/agent-profiles.sh); nothing here could answer it" >&2; exit 2; }

lockroot="${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}/peer-answer-locks"
mkdir -p "$lockroot"
instance="$lockroot/instance-$(printf '%s|%s|%s' "$prefix" "$agent_label" "${panes[*]:-}" | shasum -a 256 | cut -c1-16)"
if ! mkdir "$instance" 2>/dev/null; then
  other="$(cat "$instance/pid" 2>/dev/null || printf '')"
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    echo "peer-answer: another instance (pid $other) already watches this set; refusing to run beside it" >&2; exit 2
  fi
  rm -rf "$instance"; mkdir "$instance" || exit 2   # stale lock from a dead loop
fi
printf '%s\n' "$$" > "$instance/pid"
trap 'rm -rf "$instance"' EXIT

# Panes to watch this round: the explicit list plus every pane under
# --cwd-prefix whose reported agent is exactly --agent. Read fresh each
# round — pane ids are recycled and lab panes come and go.
watched() {
  {
    printf '%s\n' "${panes[@]:-}"
    if [ -n "$prefix" ]; then
      herdr pane list 2>/dev/null | python3 -c '
import json, sys
prefix, agent = sys.argv[1], sys.argv[2]
try:
    data = json.load(sys.stdin)
    for p in (data.get("result") or data).get("panes") or []:
        cwd = str(p.get("cwd") or "")
        if p.get("agent") == agent and (cwd == prefix or cwd.startswith(prefix + "/")):
            print(p["pane_id"])
except Exception:
    pass
' "$prefix" "$agent_label"
    fi
  } | grep -v '^$' | sort -u
}

# One keypress per pane at a time, across every loop on this machine.
with_pane_lock() {  # <pane> <cmd...>
  local lock="$lockroot/pane-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')" rc
  shift
  mkdir "$lock" 2>/dev/null || return 9
  "$@"; rc=$?
  rmdir "$lock" 2>/dev/null
  return "$rc"
}

declare -a refused=()   # "<pane>:<panel-hash>" refused by POLICY — do not nag
rounds=0
while :; do
  live=0
  while read -r pane; do
    [ -n "$pane" ] || continue
    pane_is_agent "$pane" 2>/dev/null || continue
    live=$((live + 1))
    # Only a COMPLETE recognized panel (Approve + Deny rows, nothing stray).
    [ -n "$(prompt_menu_options "$pane" 2>/dev/null)" ] || continue
    # The panel's own header/detail rows identify the prompt — not prompt_id,
    # which tries the numbered parser first and can fingerprint omp's queued
    # "N. …" messages instead of the panel (PR #58 review, PA-2).
    key="$pane:$(prompt_menu_question "$pane" 2>/dev/null | shasum -a 256 | cut -c1-16)"
    skip=0; for r in "${refused[@]:-}"; do [ "$r" = "$key" ] && skip=1 && break; done
    [ "$skip" = 1 ] && continue
    out="$(with_pane_lock "$pane" bash "$here/herdr-select.sh" "$pane" 1 --authority peer 2>&1)"; rc=$?
    case "$rc" in
      0) echo "$(date '+%H:%M:%S') $pane approved: $(printf '%s' "$out" | tail -1)" ;;
      8) echo "$(date '+%H:%M:%S') $pane left for a human: $(printf '%s' "$out" | grep -m1 'REFUSED\|refusing' || printf '%s' "$out" | tail -1)"
         refused+=("$key") ;;
      9) : ;;   # another loop holds this pane right now; look again next round
      *) echo "$(date '+%H:%M:%S') $pane not answered this round (rc=$rc): $(printf '%s' "$out" | tail -1)" ;;
    esac
  done <<EOF
$(watched)
EOF
  # Explicit panes: done when they are all gone. --cwd-prefix: panes appear
  # and vanish as a lab dispatches, so an empty round is just an empty round;
  # the loop runs until --max-rounds or the supervisor stops it.
  if [ "$live" -eq 0 ] && [ -z "$prefix" ]; then
    echo "peer-answer: no watched agent pane remains"; exit 0
  fi
  rounds=$((rounds + 1))
  if [ "$max" -gt 0 ] && [ "$rounds" -ge "$max" ]; then
    [ "$live" -gt 0 ] && echo "peer-answer: round budget spent with $live pane(s) still live" >&2 && exit 3
    echo "peer-answer: round budget spent, nothing to watch"; exit 0
  fi
  sleep "$interval"
done
