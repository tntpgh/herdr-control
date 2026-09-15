#!/usr/bin/env bash
# agent-edge.sh — the ONE place a live agent-status transition turns into action.
#
#   agent-edge.sh <pane_id> <status> [previous] [agent] [cwd]
#
# Called by the hub (hub.py `_on_agent_edge`) for every transition its herdr
# subscription observes — `blocked`, `working`, `idle`, `done`, or the synthetic
# `gone` when a pane disappears. `previous` is EMPTY on a first observation:
# hub start, or a reconnect diff. That distinction is load-bearing (see below).
#
# ---- why this exists --------------------------------------------------------
# Until now every consumer answered "who needs a human?" by polling herdr:
# wait-for-blocked.sh at 15s with a `pane list` plus a per-candidate
# process-info and screen read, peer-answer.sh at 10s, a retraction sweep on
# every tool call. herdr already emits the transition; this is the subscriber's
# hand-off into the shell that owns alerting, answering and the durable record.
#
# ---- what herdr's agent_status is and is not authoritative for --------------
# It is authoritative for WHO TO LOOK AT. omp reports it from its own
# `tool_approval_requested`/`tool_approval_resolved` events through herdr's
# integration, so a blocked omp worker is a fact, not a heuristic.
#
# It is NOT authoritative for WHAT TO PRESS. herdr-gates.sh:19-25 records
# agent_status being wrong in both directions for agents with no reporting
# integration (`working` with a menu painted, `done` mid-stream). So nothing
# here presses a key off the status alone: peer-answer.sh re-parses the panel
# with prompt_menu_options and refuses anything that is not a complete,
# recognised menu, and herdr-select.sh re-checks again before the keystroke.
#
# ---- what it will not do ----------------------------------------------------
# Auto-answering is OFF by default. peer-answer.sh presses keys on a worker's
# behalf under lib/command-policy.sh, and today a human starts it deliberately.
# Wiring that to every blocked edge would hand an automatic answerer new
# standing authority as a side effect of a performance change, so it is opt-in:
#   HERDR_EDGE_PEER_ANSWER=1
#
# The Slack backstop is GRACED, not immediate: omp's own hook alerts within
# ~1.5s of the approval and records the alert in pending.jsonl. This waits
# HERDR_EDGE_ALERT_GRACE_S (default 20) and alerts only if the pane is STILL
# blocked and STILL has no pending alert — which is what covers panes with no
# hook at all (a hand-started session, Claude/Codex without the notify hook, a
# crashed hook) without double-posting for the ones that have one.
#
# Always exits 0: a control-plane edge handler must never be able to wedge the
# subscription that called it.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
pane="${1:-}"
status="${2:-}"
previous="${3:-}"
agent="${4:-}"
cwd="${5:-}"
[ -n "$pane" ] && [ -n "$status" ] || { echo "usage: agent-edge.sh <pane_id> <status> [previous] [agent] [cwd]" >&2; exit 0; }

# shellcheck source=config.sh
. "$here/config.sh" 2>/dev/null || true
# shellcheck source=lib/run-registry.sh
. "$here/lib/run-registry.sh" 2>/dev/null || true

STATE_DIR="${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}"
LOG="$STATE_DIR/agent-edges.jsonl"
BRIDGE_STATE="${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}"
PENDING="$BRIDGE_STATE/pending.jsonl"
GRACE="${HERDR_EDGE_ALERT_GRACE_S:-20}"
# Test seams, same convention as herdr-resolve.sh's HERDR_RESOLVE_CURL: the
# suite must be able to exercise every branch without posting to Slack,
# pressing a key, or needing a hub. config.sh exports its own PATH, so
# shadowing these by PATH does not work — they are explicit for that reason.
CURL="${HERDR_EDGE_CURL:-curl}"
NOTIFY="${HERDR_EDGE_NOTIFY:-$here/slack-bridge/herdr-notify.sh}"
RESOLVE="${HERDR_EDGE_RESOLVE:-$here/herdr-resolve.sh}"
PEER_ANSWER="${HERDR_EDGE_PEER_ANSWER_SH:-$here/peer-answer.sh}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# The audit trail for a control plane that now ACTS on events: every edge and
# what it decided to do, trimmed so it can never fill the disk. Without this,
# "did the fleet notice?" is unanswerable after the fact.
note() {
  printf '{"at":"%s","pane":"%s","status":"%s","previous":"%s","agent":"%s","did":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pane" "$status" "$previous" "$agent" "$1" >> "$LOG" 2>/dev/null || true
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 1000 "$LOG" > "$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG" 2>/dev/null || true
  fi
}

# ---- the durable record follows the live truth ------------------------------
# set_task_state enforces its own legality (lib/run-registry.sh:386) — terminal
# states are never resurrected and an unknown pane is simply not a task — so
# this cannot invent history, it can only stop the registry from lying about a
# live worker. `idle` and `working` both map to `running`: the task exists and
# nobody is waiting on a person. `done`/`unknown`/`gone` are deliberately NOT
# mapped; completion is the worker's own handoff to declare, and pane death is
# lib/reconcile.sh's `lost` detection, not a UI status.
# Prints a short outcome token that goes into the audit line, because a
# silently-swallowed `|| true` is how a heal that never happened looks exactly
# like one that did: on 2026-09-15 the log said `registry-heal` while the row
# stayed `blocked` for another 16 seconds, and only a by-hand call proved the
# code path worked. `reg=` now says which.
follow_registry() {
  local want="$1" task run_id task_id err
  command -v task_for_pane >/dev/null 2>&1 || { printf 'reg=no-registry'; return 0; }
  task=$(task_for_pane "$pane" 2>/dev/null) || { printf 'reg=lookup-failed'; return 0; }
  [ -n "$task" ] || { printf 'reg=no-task'; return 0; }
  run_id=$(printf '%s' "$task" | jq -r '.run_id // empty' 2>/dev/null)
  task_id=$(printf '%s' "$task" | jq -r '.task_id // empty' 2>/dev/null)
  [ -n "$run_id" ] && [ -n "$task_id" ] || { printf 'reg=unidentified'; return 0; }
  if err=$(set_task_state "$run_id" "$task_id" "$want" 2>&1 >/dev/null); then
    printf 'reg=%s' "$want"
  else
    printf 'reg=refused(%s)' "$(printf '%s' "$err" | tr -d '"' | tr '\n' ' ' | cut -c1-90)"
  fi
}

pane_has_pending_alert() {
  [ -s "$PENDING" ] || return 1
  jq -e --arg p "$pane" -s 'any(.[]; .pane == $p)' "$PENDING" >/dev/null 2>&1
}

still_blocked() {
  # Ask the hub, not herdr: the subscription already knows, and this must not
  # reintroduce a per-edge `herdr pane read`.
  local url="${HERDR_HUB_URL:-http://127.0.0.1:${HERDR_HUB_PORT:-8600}/}"
  "$CURL" -s --max-time 3 "${url}api/panes" 2>/dev/null \
    | jq -e --arg p "$pane" 'any(.panes[]?; .pane_id == $p and .agent_status == "blocked")' >/dev/null 2>&1
}

case "$status" in
  blocked)
    reg=$(follow_registry blocked)
    if [ -z "$previous" ]; then
      # First observation: the hub just started or re-bootstrapped. The prompt
      # may be hours old and already alerted. Record the truth, alert nothing.
      note "registry-follow-only (first observation) $reg"
      exit 0
    fi
    if [ "${HERDR_EDGE_PEER_ANSWER:-0}" = "1" ]; then
      # One round, this pane only. peer-answer re-parses and refuses anything
      # that is not a complete recognised menu, and command-policy decides
      # whether it may answer at all.
      bash "$PEER_ANSWER" --max-rounds 1 "$pane" >/dev/null 2>&1 || true
      note "peer-answer(1 round)"
    fi
    sleep "$GRACE"
    if ! still_blocked; then
      note "cleared within grace, no alert"
      exit 0
    fi
    if pane_has_pending_alert; then
      note "already alerted by the worker's own hook"
      exit 0
    fi
    msg="$agent needs input"
    [ -n "$cwd" ] && msg="$msg  ·  ${cwd##*/}"
    bash "$NOTIFY" --pane "$pane" \
      "${msg} (no hook alert after ${GRACE}s — control-plane backstop)" >/dev/null 2>&1 || true
    note "backstop alert $reg"
    ;;
  working|idle)
    if [ -z "$previous" ]; then
      # First observation of a pane nobody is waiting on. The only thing worth
      # doing is healing a registry row still recording `blocked` from a prompt
      # that was answered while the hub was down — set_task_state is a no-op
      # unless the row actually disagrees, and terminal rows are untouchable.
      # This is why a hub restart is a reconciliation, not just a reconnect.
      reg=$(follow_registry running)
      note "registry-heal (first observation) $reg"
      exit 0
    fi
    [ "$previous" = "blocked" ] || { note "noop"; exit 0; }
    reg=$(follow_registry running)
    # The prompt is answered, so any Slack alert for it is now a lie. This is
    # the same retraction the omp hook fires on tool_approval_resolved; for a
    # pane with no hook it is the only one.
    bash "$RESOLVE" >/dev/null 2>&1 || true
    note "unblocked: registry running + retract $reg"
    ;;
  *)
    note "noop"
    ;;
esac
exit 0
