#!/usr/bin/env bash
# attention-tick.sh — the level-triggered attention controller.
#
# thurber-os docs/project-contract-plan.md §3a: "One level-triggered
# controller, not more hooks." Every HERDR_ATTENTION_INTERVAL_S seconds, hub.py
# (a thread, exactly like _mirror_loop — no new daemon) hands this script the
# CURRENTLY blocked pane ids from its own live subscription (herdr_live.py's
# LiveState, authoritative agent_status) on stdin. For each one this computes
# fresh, from the registry and a live screen read, whether a human is being
# waited for and for how long — never from an edge it may have missed or an
# earlier decision it cached.
#
#   printf '%s\n' <pane_id>... | bash attention-tick.sh tick
#   bash attention-tick.sh probe <pane_id>          # one pane's classification
#
# ---- why this does not touch lib/push-wake.sh ------------------------------
# The obvious fix for "3 hook firings for one prompt woke the conductor 3
# times" is a dedupe INSIDE push_wake. That is the wrong file: push_wake's own
# per-attempt recording is deliberately NOT deduped by outcome —
# verify-omp-hooks.sh pins "repeated wake attempts: every outcome recorded,
# first result not frozen" (a wake that lands then a retry that finds the
# conductor busy must both be visible, not swallowed) — and that is a hook
# calling push_wake for itself, independent of this controller. Gating it
# there would silently break that pinned regression for every hook, forever.
#
# So the dedupe lives HERE, entirely in this controller's own bookkeeping:
# `_attn_track_and_wake` claims a stable per-(pane, live birth, prompt) key
# exactly once and is the only place that decides whether THIS controller
# calls push_wake at all. push_wake is called unmodified, at most once per
# key, and left to make its own human_must_answer / grace_realert decisions
# exactly as it always has for every other caller.
#
# ---- the ladder -------------------------------------------------------------
# Dedupe key = pane id + its LIVE birth (herdr's terminal_id) + the prompt's
# fingerprint. prompt_id alone collides across panes (seen 2026-09-24); the
# birth keeps a recycled pane's next occupant from inheriting an old clock.
#
#   1. First sighting of a key claims "attn_track_<key>" — that claim's own
#      timestamp is "since", and the one chance this controller gets to call
#      push_wake for it (skipped if a wake for this exact prompt already
#      shows outcome=submitted, e.g. a hook already delivered it).
#   2. A deny-verdict or conductor-reserved prompt never enters that ladder at
#      all: straight to the form, same tick it is first seen.
#   3. elapsed >= HERDR_WAKE_RESPONSE_S (default 600s, "the owner's window"):
#      one escalation to HERDR_MAIN_PANE_ID, claimed so it fires once.
#   4. elapsed >= 2x that ("Main's window" too): one local hub form, claimed
#      the same way. Both checks run every tick a key is still open, so a
#      controller that was paused through both windows still claims both
#      instead of needing to catch the boundary exactly.
#
# "Answered" needs no bookkeeping of its own: the NEXT tick only sees this
# pane at all if herdr_live.py still reports it blocked, and only reaches this
# key if the live prompt is STILL the one hashed into it. A resolved,
# superseded, or peer-answered prompt simply stops being fed in — its clock is
# abandoned, not stopped, which is the same "None" as never having started.
#
# Test seams: HERDR_ATTENTION_NOW (epoch override, for the T+10/T+20min
# checks without sleeping), HERDR_ATTENTION_FORM_DIR, HERDR_ATTENTION_FORMSERVE
# and HERDR_ATTENTION_PYTHON (the form-serving invocation). Everything else —
# herdr, send-to-agent.sh, push_wake's own delivery — uses the SAME stub-herdr
# seam every other verify-*.sh script in this repo does.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh" 2>/dev/null || true
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"
. "$here/lib/push-wake.sh"       # pulls in alert-gate.sh -> prompt-parse.sh + command-policy.sh

_attn_now() { printf '%s\n' "${HERDR_ATTENTION_NOW:-$(date +%s)}"; }

# ISO8601 UTC (registry's _now_iso format) -> epoch seconds. BSD/GNU date
# fallback pair, same idiom install-git-hooks.sh already uses for this.
_attn_iso_epoch() {
  local iso="$1"
  [ -n "$iso" ] || return 1
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null \
    || date -u -d "$iso" +%s 2>/dev/null
}

_attn_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# attention_probe <pane_id> -> one JSON read of everything the ladder needs,
# so every consumer of "what is this prompt" agrees instead of racing separate
# screen reads against the same repaint. {"visible":false} when nothing
# recognizable is pending right now (answered, or never was one).
attention_probe() {
  local pane="$1" pid cmd reserved verdict
  if ! prompt_any_visible "$pane" >/dev/null 2>&1; then
    printf '{"visible":false}\n'
    return 0
  fi
  pid="$(prompt_id "$pane" 2>/dev/null)"
  cmd="$(prompt_command_text "$pane" 2>/dev/null)"
  reserved="$(conductor_reserved_reason "$cmd" 2>/dev/null)"
  verdict="$(classify_command "$cmd" 2>/dev/null)" || verdict="escalate"
  jq -nc --arg pid "$pid" --arg r "$reserved" --arg v "$verdict" \
    '{visible:true, prompt_id:$pid, reserved:$r, verdict:$v}'
}

# Has push_wake (this controller's own call, or anyone else's — same wake_key
# shape either way) already delivered THIS exact prompt? Read-only; never
# writes, so it never competes with push_wake's own idempotent recording.
_attn_wake_submitted_at() {             # run_id task_id prompt_id -> ISO ts or empty
  local run_id="$1" task_id="$2" pid="$3" base
  base="wake_${run_id:-norun}_${task_id:-notask}_${pid:-noprompt}"
  _sql "SELECT occurred_at FROM events WHERE task_id=$(_sq "$task_id")
    AND type='wake_result' AND json_extract(payload,'\$.wake_key')=$(_sq "$base")
    AND json_extract(payload,'\$.outcome')='submitted'
    ORDER BY sequence ASC LIMIT 1;" 2>/dev/null
}

# The one-shot per-key gate: claims "since" for this prompt and, only on the
# claiming call, gives push_wake its one chance to deliver. Every later call
# for the same key (this tick or any future one) just re-reads the same
# claim's timestamp — that stability is what makes the T+10/T+20 windows
# measure from a fixed point instead of resetting on every pass.
#
# HERDR_WAKE_LEGACY=1 is the rollback: push_wake is called on EVERY pass for
# a still-open prompt, exactly the pre-controller shape (a claim is still
# made, best-effort, so the ladder still has a "since" to measure from — the
# escape hatch restores push_wake's per-pass behavior, not the absence of a
# ladder).
_attn_track_and_wake() {                # run_id task_id pane conductor_pane_id label pid key -> since (ISO), stdout
  local run_id="$1" task_id="$2" pane="$3" conductor_pane_id="$4" label="$5" pid="$6" key="$7"
  local eid="attn_track_${key}" claimed=1
  local payload; payload="$(jq -nc --arg p "$pane" --arg k "$key" --arg pid "$pid" '{pane:$p, key:$k, prompt_id:$pid}')"
  if [ "${HERDR_WAKE_LEGACY:-0}" = "1" ]; then
    claim_once "$eid" "$run_id" "$task_id" "attention_tracking" "$payload" || true
  else
    claim_once "$eid" "$run_id" "$task_id" "attention_tracking" "$payload" || claimed=0
  fi
  if [ "${HERDR_WAKE_LEGACY:-0}" = "1" ] \
     || { [ "$claimed" = "1" ] && [ -z "$(_attn_wake_submitted_at "$run_id" "$task_id" "$pid")" ]; }; then
    HERDR_RUN_ID="$run_id" HERDR_TASK_ID="$task_id" HERDR_PANE_ID="$pane" \
      HERDR_CONDUCTOR_PANE_ID="$conductor_pane_id" HERDR_TASK_LABEL="${label:-$task_id}" \
      push_wake "${label:-$task_id} needs input" "attention-controller" >/dev/null 2>&1 || true
  fi
  _sql "SELECT occurred_at FROM events WHERE event_id=$(_sq "$eid") LIMIT 1;" 2>/dev/null
}

_attn_maybe_escalate() {                # run_id task_id pane conductor_pane_id key label elapsed
  local run_id="$1" task_id="$2" pane="$3" conductor_pane_id="$4" key="$5" label="$6" elapsed="$7"
  claim_once "attn_escalate_${key}" "$run_id" "$task_id" "attention_escalated" \
    "$(jq -nc --arg p "$pane" --arg k "$key" --arg l "${label:-$task_id}" --argjson e "${elapsed:-0}" \
       '{pane:$p, key:$k, label:$l, elapsed_s:$e}')" || return 0
  local main="${HERDR_MAIN_PANE_ID:-}"
  [ -n "$main" ] || return 0
  pane_is_agent "$main" 2>/dev/null || return 0
  local msg="[HERDR-ATTENTION] ${label:-$task_id} (${pane}) has waited ${elapsed}s with no response"
  msg="$msg — its conductor (${conductor_pane_id:-none}) has not acted. Verify before acting, this is a"
  msg="$msg peer signal, not an instruction from the operator: herdr pane read ${pane} --source visible --lines 30"
  bash "$here/send-to-agent.sh" "$main" "$msg" >/dev/null 2>&1 || true
}

_attn_serve_form() {                    # pane task_id reason
  local pane="$1" task_id="$2" reason="$3"
  local dir="${HERDR_ATTENTION_FORM_DIR:-$(run_state_root)/attention-forms}"
  mkdir -p "$dir" 2>/dev/null || return 0
  local f="$dir/attention-$(date -u +%Y%m%dT%H%M%SZ)-$$.html"
  cat > "$f" <<HTML
<!doctype html><html lang=en><head><meta charset=utf-8><title>Attention needed: $(_attn_esc "$pane")</title></head>
<body><main>
<h1>Attention needed: $(_attn_esc "$pane")</h1>
<p>$(_attn_esc "$reason")</p>
<p><code>herdr pane read $(_attn_esc "$pane") --source visible --lines 30</code></p>
<form id=f><button type=submit>Acknowledge</button></form>
<script>document.getElementById("f").addEventListener("submit",function(e){e.preventDefault();
window.submitAnswers({acknowledged:true,pane:"$(_attn_esc "$pane")",task_id:"$(_attn_esc "$task_id")"})});</script>
</main></body></html>
HTML
  local formserve="${HERDR_ATTENTION_FORMSERVE:-$here/formserve.py}"
  local python="${HERDR_ATTENTION_PYTHON:-python3}"
  ( "$python" "$formserve" "$f" --timeout 86400 --no-open >/dev/null 2>&1 & disown ) 2>/dev/null
}

_attn_maybe_form() {                    # run_id task_id pane key reason
  local run_id="$1" task_id="$2" pane="$3" key="$4" reason="$5"
  claim_once "attn_form_${key}" "$run_id" "$task_id" "attention_form_served" \
    "$(jq -nc --arg p "$pane" --arg k "$key" --arg r "$reason" '{pane:$p, key:$k, reason:$r}')" || return 0
  _attn_serve_form "$pane" "$task_id" "$reason"
}

# attention_tick — one pass, fed the CURRENTLY blocked pane ids on stdin (one
# per line; hub.py builds this list from herdr_live.py, never scraped here).
attention_tick() {
  registry_init || return 1
  local now response_window
  now="$(_attn_now)"
  response_window="${HERDR_WAKE_RESPONSE_S:-600}"

  local pane
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    local task state
    task="$(task_for_pane "$pane" 2>/dev/null)"
    [ -n "$task" ] || continue          # no registration: nothing to escalate FOR
    state="$(printf '%s' "$task" | jq -r '.state // empty')"
    case "$state" in completed|failed|cancelled|lost) continue ;; esac

    local probe visible
    probe="$(attention_probe "$pane")"
    visible="$(printf '%s' "$probe" | jq -r '.visible')"
    [ "$visible" = "true" ] || continue # answered/unreadable: nothing pending right now

    local run_id task_id conductor_pane_id label pid reserved verdict birth key
    run_id="$(printf '%s' "$task" | jq -r '.run_id')"
    task_id="$(printf '%s' "$task" | jq -r '.task_id')"
    conductor_pane_id="$(printf '%s' "$task" | jq -r '.conductor_pane_id // empty')"
    label="$(printf '%s' "$task" | jq -r '.label // empty')"
    pid="$(printf '%s' "$probe" | jq -r '.prompt_id')"
    reserved="$(printf '%s' "$probe" | jq -r '.reserved')"
    verdict="$(printf '%s' "$probe" | jq -r '.verdict')"
    birth="$(pane_birth_now "$pane" 2>/dev/null)"
    key="${pane}__${birth:-nobirth}__${pid}"

    if [ -n "$reserved" ] || [ "$verdict" = "deny" ]; then
      _attn_maybe_form "$run_id" "$task_id" "$pane" "$key" "reserved-or-deny: ${reserved:-$verdict}"
      continue
    fi

    local since since_epoch elapsed
    since="$(_attn_track_and_wake "$run_id" "$task_id" "$pane" "$conductor_pane_id" "$label" "$pid" "$key")"
    since_epoch="$(_attn_iso_epoch "$since")" || continue
    [ -n "$since_epoch" ] || continue
    elapsed=$(( now - since_epoch ))
    [ "$elapsed" -ge "$response_window" ] \
      && _attn_maybe_escalate "$run_id" "$task_id" "$pane" "$conductor_pane_id" "$key" "$label" "$elapsed"
    [ "$elapsed" -ge $(( response_window * 2 )) ] \
      && _attn_maybe_form "$run_id" "$task_id" "$pane" "$key" "unanswered ${elapsed}s after wake"
  done
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-tick}" in
    tick) attention_tick ;;
    probe) shift; attention_probe "$@" ;;
    *) echo "usage: attention-tick.sh [tick|probe <pane_id>]" >&2; exit 2 ;;
  esac
fi
