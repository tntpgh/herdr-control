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
# process-info and screen read, peer-answer.sh at 10s. herdr already emits the
# transition; this is the subscriber's hand-off into the shell that owns
# answering and the durable record.
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
# Always exits 0: a control-plane edge handler must never be able to wedge the
# subscription that called it.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
pane="${1:-}"
status="${2:-}"
previous="${3:-}"
agent="${4:-}"
cwd="${5:-}"
birth="${6:-}"                          # herdr's terminal_id for this pane, if known
[ -n "$pane" ] && [ -n "$status" ] || { echo "usage: agent-edge.sh <pane_id> <status> [previous] [agent] [cwd] [birth]" >&2; exit 0; }

# shellcheck source=config.sh
. "$here/config.sh" 2>/dev/null || true
# shellcheck source=lib/run-registry.sh
. "$here/lib/run-registry.sh" 2>/dev/null || true

STATE_DIR="${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}"
LOG="$STATE_DIR/agent-edges.jsonl"
# Test seams: the suite must be able to exercise every branch without
# pressing a key or needing a hub. config.sh exports its own PATH, so
# shadowing these by PATH does not work — they are explicit for that reason.
CURL="${HERDR_EDGE_CURL:-curl}"
PEER_ANSWER="${HERDR_EDGE_PEER_ANSWER_SH:-$here/peer-answer.sh}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# The audit trail for a control plane that now ACTS on events: every edge and
# what it decided to do, trimmed so it can never fill the disk. Without this,
# "did the fleet notice?" is unanswerable after the fact.
#
# Built with jq, not interpolation: `agent` and the pane label are whatever an
# integration reported, so a value containing a quote or a newline could forge
# records in the very file that is supposed to answer "did the fleet notice?".
# Same discipline as lib/run-registry.sh.
note() {
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pane "$pane" \
     --arg status "$status" --arg previous "$previous" --arg agent "$agent" \
     --arg did "$1" \
     '{at:$at,pane:$pane,status:$status,previous:$previous,agent:$agent,did:$did}' \
     >> "$LOG" 2>/dev/null || true
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
  local want="$1" task="${2:-}" generation="${3:-}" expected="${4:-}" run_id task_id reg_birth err
  command -v task_for_pane >/dev/null 2>&1 || { printf 'reg=no-registry'; return 0; }
  if [ -z "$task" ]; then
    task=$(task_for_pane "$pane" 2>/dev/null) || { printf 'reg=lookup-failed'; return 0; }
  fi
  [ -n "$task" ] || { printf 'reg=no-task'; return 0; }
  run_id=$(printf '%s' "$task" | jq -r '.run_id // empty' 2>/dev/null)
  task_id=$(printf '%s' "$task" | jq -r '.task_id // empty' 2>/dev/null)
  [ -n "$run_id" ] && [ -n "$task_id" ] || { printf 'reg=unidentified'; return 0; }
  # PANE IDS ARE RECYCLED. task_for_pane returns the most-recently-updated row
  # for this id, so without a birth comparison this writer can flip a DEAD
  # worker's row (and append a state_changed event) because an unrelated new
  # pane inherited its id. Every other writer here already refuses on a
  # mismatch — herdr-select.sh gates its identical bookkeeping write on it,
  # lib/pane-guard.sh refuses input, lib/reconcile.sh calls it pane_recycled —
  # and the security review found this was the one path that could not, because
  # the live record carried no terminal_id. It does now, passed in as $6.
  #
  # Refuse only on a DEFINITE disagreement: an empty birth on either side means
  # unknown (a status event carries no terminal_id, and an older registration
  # may predate the field), and refusing on unknown would stop healing the very
  # rows this exists to heal.
  reg_birth=$(printf '%s' "$task" | jq -r '.pane_birth // empty' 2>/dev/null)
  if [ -n "$reg_birth" ] && [ -n "$birth" ] && [ "$reg_birth" != "$birth" ]; then
    printf 'reg=refused(pane recycled: registered %s, live %s)' \
      "$(printf '%s' "$reg_birth" | cut -c1-12)" "$(printf '%s' "$birth" | cut -c1-12)"
    return 0
  fi
  if [ -n "$generation" ]; then
    err=$(set_task_state_if_generation "$run_id" "$task_id" "$want" "$expected" "$generation" 2>&1 >/dev/null)
  else
    err=$(set_task_state "$run_id" "$task_id" "$want" 2>&1 >/dev/null)
  fi
  if [ $? -eq 0 ]; then
    printf 'reg=%s' "$want"
  else
    printf 'reg=refused(%s)' "$(printf '%s' "$err" | tr -d '"' | tr '\n' ' ' | cut -c1-90)"
  fi
}

# THREE answers, not two: blocked | cleared | unknown.
#
# A curl+jq pipeline read as a boolean once turned every failure — hub
# restarting (./restart.sh does exactly that), a response slower than
# --max-time, malformed JSON, curl missing — into "not blocked", so the
# record asserted the prompt had cleared precisely when the control plane was
# least healthy. A monitor must never confuse "it is fine" with "I could not
# look".
pane_probe() {
  local url="${HERDR_HUB_URL:-http://127.0.0.1:${HERDR_HUB_PORT:-8600}/}" body rec live_birth live_status
  body=$("$CURL" -s --max-time 3 "${url}api/panes" 2>/dev/null) || { printf 'unknown'; return 0; }
  printf '%s' "$body" | jq -e '.connected == true and (.panes | type) == "array"' >/dev/null 2>&1 \
    || { printf 'unknown'; return 0; }
  # Absence is not a clear. It can mean pane removal/recycling or an
  # incomplete snapshot; lost/reconcile owns that lifecycle. Likewise, a
  # recycled pane id is not evidence about the registered pane occurrence.
  rec=$(printf '%s' "$body" | jq -c --arg p "$pane" 'first(.panes[]? | select(.pane_id == $p)) // empty' 2>/dev/null)
  [ -n "$rec" ] || { printf 'unknown'; return 0; }
  live_birth=$(printf '%s' "$rec" | jq -r '.birth // .terminal_id // empty' 2>/dev/null)
  if [ -n "$birth" ] && [ -n "$live_birth" ] && [ "$birth" != "$live_birth" ]; then
    printf 'unknown'
    return 0
  fi
  live_status=$(printf '%s' "$rec" | jq -r '.agent_status // "unknown"' 2>/dev/null)
  case "$live_status" in
    blocked) printf 'blocked' ;;
    working|idle|done) printf 'cleared' ;;
    *) printf 'unknown' ;;
  esac
}

case "$status" in
  blocked)
    reg=$(follow_registry blocked)
    # A first observation (empty previous: the hub just started or
    # re-bootstrapped) is answered too: skipping it stranded every prompt that
    # was already blocked when the hub restarted. Measured 2026-09-18: the hub
    # came up with three tntpgh-dev review lanes already blocked on
    # allow-class commands, and none was ever answered — a blocked pane
    # produces no further transition by definition, so there is no second
    # chance. The classifier is still the only gate: peer-answer re-parses the
    # menu and command-policy decides.
    first=""
    [ -z "$previous" ] && first="first observation, "
    if [ "${HERDR_EDGE_PEER_ANSWER:-0}" = "1" ]; then
      # The blocked edge can precede the menu paint by a frame. Three short
      # rounds preserve the one-pane edge cost while retrying that race; a
      # policy refusal is still remembered by peer-answer and is not nagged.
      bash "$PEER_ANSWER" --interval 1 --max-rounds 3 ${agent:+--agent "$agent"} "$pane" >/dev/null 2>&1 || true
      note "peer-answer(${first}3 rounds) $reg"
    else
      note "registry-follow-only${first:+ (first observation)} $reg"
    fi
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
    # The edge argument can be older than the hub's current pane state. Bind
    # this clear to the exact registry occurrence observed before asking the
    # hub. If a newer block lands between the probe and the write, the event
    # generation CAS below refuses it (including blocked->running->blocked
    # ABA); if the hub is unavailable, fail closed and keep the row blocked.
    edge_task=$(task_for_pane "$pane" 2>/dev/null || true)
    edge_run=$(printf '%s' "$edge_task" | jq -r '.run_id // empty' 2>/dev/null)
    edge_id=$(printf '%s' "$edge_task" | jq -r '.task_id // empty' 2>/dev/null)
    edge_state=""
    edge_generation=""
    if [ -n "$edge_run" ] && [ -n "$edge_id" ]; then
      edge_snapshot=$(task_state_snapshot "$edge_run" "$edge_id" 2>/dev/null || true)
      edge_state=$(printf '%s' "$edge_snapshot" | jq -r '.state // empty' 2>/dev/null)
      edge_generation=$(printf '%s' "$edge_snapshot" | jq -r '.generation // empty' 2>/dev/null)
    fi
    case "$(pane_probe)" in
      blocked) note "ignored stale unblocked edge: hub still blocked"; exit 0 ;;
      unknown) note "ignored unverified unblocked edge: hub unavailable"; exit 0 ;;
    esac
    if [ "$edge_state" != blocked ] || [ -z "$edge_generation" ]; then
      note "ignored unbound unblocked edge: no blocked registry occurrence"
      exit 0
    fi
    reg=$(follow_registry running "$edge_task" "$edge_generation" blocked)
    case "$reg" in reg=running) ;; *) note "ignored raced unblocked edge: $reg"; exit 0 ;; esac
    note "unblocked: registry running $reg"
    ;;
  *)
    note "noop"
    ;;
esac
exit 0
