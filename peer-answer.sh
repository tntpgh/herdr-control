#!/usr/bin/env bash
# peer-answer.sh — keep answering allow-class approval prompts on a set of
# agent panes, as a PEER, until the panes are gone or the round budget is spent.
#
#   peer-answer.sh [--interval S] [--max-rounds N] [--cwd-prefix DIR] [pane_id ...]
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
# answer a prompt and which presses nothing unless the panel is a recognized
# `Allow tool:` menu whose command classifies `allow` AND is not on the
# human-reserved list (merge/push to main, credential values, remote
# mutation, governance, control weakening — docs/approval-policy.md rule 1).
# A refusal is logged once per prompt and left on screen for a human; this
# loop never retries a refused prompt and never sends a bare Enter.
# approval-policy.md rules 2 and 3 (three-record approvals, revalidate before
# injection) are herdr-select.sh's and are inherited, not reimplemented.
#
# Pane selection: explicit pane ids, and/or --cwd-prefix DIR to pick every
# agent pane whose cwd is under DIR on each round (a lab's worktree root, so
# panes that appear later are covered without restarting the loop).
#
# Exit: 0 when no watched pane remains an agent pane, 3 when --max-rounds is
# spent with panes still live, 2 on a missing dependency.
set -uo pipefail
command -v herdr >/dev/null 2>&1 || { echo "peer-answer: herdr not on PATH" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"

interval=10; max=0; prefix=""; panes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) interval="${2:?}"; shift 2 ;;
    --max-rounds) max="${2:?}"; shift 2 ;;
    --cwd-prefix) prefix="${2:?}"; shift 2 ;;
    *) panes+=("$1"); shift ;;
  esac
done
[ -n "$prefix" ] || [ "${#panes[@]}" -gt 0 ] || {
  echo "usage: peer-answer.sh [--interval S] [--max-rounds N] [--cwd-prefix DIR] [pane_id ...]" >&2; exit 2; }
prefix="${prefix%/}"

# Panes to watch this round: the explicit list plus every agent pane under
# --cwd-prefix. Read fresh each round — pane ids are recycled and lab panes
# come and go.
watched() {
  {
    printf '%s\n' "${panes[@]:-}"
    if [ -n "$prefix" ]; then
      herdr pane list 2>/dev/null | python3 -c '
import json, sys
prefix = sys.argv[1]
try:
    data = json.load(sys.stdin)
    for p in (data.get("result") or data).get("panes") or []:
        cwd = str(p.get("cwd") or "")
        if p.get("agent") and (cwd == prefix or cwd.startswith(prefix + "/")):
            print(p["pane_id"])
except Exception:
    pass
' "$prefix"
    fi
  } | grep -v '^$' | sort -u
}

declare -a refused=()   # "<pane>:<prompt_id>" already refused — do not nag
rounds=0
while :; do
  live=0
  while read -r pane; do
    [ -n "$pane" ] || continue
    pane_is_agent "$pane" 2>/dev/null || continue
    live=$((live + 1))
    prompt_menu_visible "$pane" 2>/dev/null || continue
    pid="$(prompt_id "$pane" 2>/dev/null || printf '')"
    key="$pane:$pid"
    skip=0; for r in "${refused[@]:-}"; do [ "$r" = "$key" ] && skip=1 && break; done
    [ "$skip" = 1 ] && continue
    if out="$(bash "$here/herdr-select.sh" "$pane" 1 --authority peer 2>&1)"; then
      echo "$(date '+%H:%M:%S') $pane approved: $(printf '%s' "$out" | tail -1)"
    else
      rc=$?
      echo "$(date '+%H:%M:%S') $pane left for a human (rc=$rc): $(printf '%s' "$out" | grep -m1 'REFUSED\|refusing' || printf '%s' "$out" | tail -1)"
      refused+=("$key")
    fi
  done <<EOF
$(watched)
EOF
  [ "$live" -gt 0 ] || { echo "peer-answer: no watched agent pane remains"; exit 0; }
  rounds=$((rounds + 1))
  if [ "$max" -gt 0 ] && [ "$rounds" -ge "$max" ]; then
    echo "peer-answer: round budget spent with $live pane(s) still live" >&2; exit 3
  fi
  sleep "$interval"
done
