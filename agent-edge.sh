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
birth="${6:-}"                          # herdr's terminal_id for this pane, if known
[ -n "$pane" ] && [ -n "$status" ] || { echo "usage: agent-edge.sh <pane_id> <status> [previous] [agent] [cwd] [birth]" >&2; exit 0; }

# shellcheck source=config.sh
. "$here/config.sh" 2>/dev/null || true
# shellcheck source=lib/run-registry.sh
. "$here/lib/run-registry.sh" 2>/dev/null || true

STATE_DIR="${HERDR_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-control}"
LOG="$STATE_DIR/agent-edges.jsonl"
BRIDGE_STATE="${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}"
PENDING="$BRIDGE_STATE/pending.jsonl"
# The backstop must never beat lib/alert-gate.sh to Slack. The gate holds a
# non-human-reserved prompt for HERDR_ALERT_GRACE_S (default 90) precisely so
# an allow-class approval a peer answers in seconds does not page anybody —
# that hold is the fix for the 2026-09-12 Slack flood. A 20s backstop wins that
# race every time: it would page every held prompt (the dominant path under
# --approval-mode write), and then the gate's own re-alert would post a SECOND
# message for the same prompt at 90s.
#
# So the backstop waits for the gate to have had its turn, plus a margin. By
# then a hook that works has already posted AND recorded the alert in
# pending.jsonl, so the dedupe below suppresses us — and we only speak for the
# panes the gate never covered, which is the whole point of a backstop.
GRACE="${HERDR_EDGE_ALERT_GRACE_S:-$(( ${HERDR_ALERT_GRACE_S:-90} + 30 ))}"
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
#
# Built with jq, not interpolation: `agent` and the pane label are whatever an
# integration reported, so a value containing a quote or a newline could forge
# records in the very file that is supposed to answer "did the fleet notice?".
# Same discipline as herdr-notify.sh and lib/run-registry.sh.
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
  local want="$1" task run_id task_id reg_birth err
  command -v task_for_pane >/dev/null 2>&1 || { printf 'reg=no-registry'; return 0; }
  task=$(task_for_pane "$pane" 2>/dev/null) || { printf 'reg=lookup-failed'; return 0; }
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

# THREE answers, not two: blocked | cleared | unknown.
#
# This used to be a curl+jq pipeline read as a boolean, so every failure —
# hub restarting (./restart.sh does exactly that), a response slower than
# --max-time, malformed JSON, curl missing — came back "not blocked", which
# suppressed the alert AND wrote `cleared within grace, no alert` into the
# audit file. The alert was dropped precisely when the control plane was least
# healthy, and the record asserted the prompt had cleared. A monitor must never
# confuse "it is fine" with "I could not look".
pane_probe() {
  local url="${HERDR_HUB_URL:-http://127.0.0.1:${HERDR_HUB_PORT:-8600}/}" body
  body=$("$CURL" -s --max-time 3 "${url}api/panes" 2>/dev/null) || { printf 'unknown'; return 0; }
  printf '%s' "$body" | jq -e '.connected == true and (.panes | type) == "array"' >/dev/null 2>&1 \
    || { printf 'unknown'; return 0; }
  if printf '%s' "$body" | jq -e --arg p "$pane" \
       'any(.panes[]?; .pane_id == $p and .agent_status == "blocked")' >/dev/null 2>&1; then
    printf 'blocked'
  else
    printf 'cleared'
  fi
}

case "$status" in
  blocked)
    reg=$(follow_registry blocked)
    if [ -z "$previous" ]; then
      # First observation: the hub just started or re-bootstrapped. The prompt
      # may be hours old and already alerted. Record the truth, alert nothing.
      #
      # But ANSWERING is not alerting, and skipping it here strands every
      # prompt that was already blocked when the hub restarted. Measured
      # 2026-09-18, the night standing authority was granted: the hub came up
      # with three tntpgh-dev review lanes already blocked, every one of them on
      # an allow-class command, and none was ever answered — a blocked pane
      # produces no further transition by definition, so there is no second
      # chance. The conductor had to press every one by hand.
      #
      # The classifier is still the only gate: peer-answer re-parses the menu
      # and command-policy decides, so this answers exactly what it would have
      # answered one transition later. Alerting stays suppressed either way.
      if [ "${HERDR_EDGE_PEER_ANSWER:-0}" = "1" ]; then
        bash "$PEER_ANSWER" --interval 1 --max-rounds 3 ${agent:+--agent "$agent"} "$pane" >/dev/null 2>&1 || true
        note "peer-answer(first observation, 3 rounds) $reg"
      else
        note "registry-follow-only (first observation) $reg"
      fi
      exit 0
    fi
    if [ "${HERDR_EDGE_PEER_ANSWER:-0}" = "1" ]; then
      # The blocked edge can precede the menu paint by a frame. Three short
      # rounds preserve the one-pane edge cost while retrying that race; a
      # policy refusal is still remembered by peer-answer and is not nagged.
      bash "$PEER_ANSWER" --interval 1 --max-rounds 3 ${agent:+--agent "$agent"} "$pane" >/dev/null 2>&1 || true
      note "peer-answer(3 rounds)"
    fi
    sleep "$GRACE"
    case "$(pane_probe)" in
      cleared)
        note "cleared within grace, no alert"
        exit 0 ;;
      unknown)
        # Could not ask. Fail toward alerting: a missed page on a blocked
        # worker is the failure this script exists to prevent, and a duplicate
        # is recoverable (the hook's own entry, if any, dedupes below).
        note "probe unreachable — alerting anyway" ;;
    esac
    if pane_has_pending_alert; then
      note "already alerted by the worker's own hook"
      exit 0
    fi
    msg="$agent needs input"
    [ -n "$cwd" ] && msg="$msg  ·  ${cwd##*/}"
    # --choices, exactly like the hook path (agent-hooks/omp-notify.sh:110).
    # Without it herdr-notify never builds `blocks`, and its pending.jsonl
    # append is gated on `blocks` — so the message would be posted with NO
    # queue record: un-retractable by herdr-resolve.sh (the "armed Slack
    # message with no record" state it exists to prevent), invisible to the
    # dedupe above (so every later prompt on that pane posts another one), and
    # button-less, i.e. strictly weaker than the alert it stands in for.
    bash "$NOTIFY" --choices --pane "$pane" \
      "${msg} (no hook alert after ${GRACE}s — control-plane backstop)" >/dev/null 2>&1 || true
    if pane_has_pending_alert; then
      note "backstop alert (queued for retraction) $reg"
    else
      note "backstop alert NOT QUEUED — retraction will not find it $reg"
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
