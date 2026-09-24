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
# Dedupe key = pane id + its REGISTERED pane_birth (task_for_pane's own
# record, not a fresh live read — an unreadable live sample must not change
# the key, PR #132 review item 2) + a whitespace-normalised hash of
# prompt_command_text (not prompt_id: prompt_id hashes the whole
# question+options block and moves on a mere repaint or terminal resize,
# which is not a new prompt). lib/attention-key.sh is the one place this is
# computed, shared with the hooks (item 6) so the two cannot drift apart.
# prompt_id is still carried in every payload, for forensics only.
#
#   1. First sighting of a key claims "attn_track_<key>" — that claim's own
#      timestamp is "since", and the one chance this controller gets to call
#      push_wake for it. Skipped entirely if push_wake already OWNS this
#      exact prompt (a `wake_held`, `wake_attempted`, or `wake_result` row
#      already exists for its wake_key) — a hook firing independently, or an
#      earlier pass of this controller, already has a grace_realert timer
#      running or a delivery in flight; a second push_wake call here would
#      spawn a SECOND timer that force-delivers a second wake when it expires
#      (PR #132 review, P1 — the double-wake this exists to prevent).
#   2. A deny-verdict or conductor-reserved prompt skips the escalation rung
#      (only a human can approve it) but still gets the owner's window: its
#      conductor may deny/redirect, and usually does in seconds. Form only if
#      it is still blocked at HERDR_WAKE_RESPONSE_S.
#   3. elapsed >= HERDR_WAKE_RESPONSE_S (default 600s, "the owner's window"):
#      one escalation to HERDR_MAIN_PANE_ID (birth-guarded the same way a
#      worker pane is), claimed so it fires once — with exactly one retry if
#      the first attempt did not land (refused/unsubmitted/no Main to send
#      to), never more.
#   4. elapsed >= 2x that ("Main's window" too): one local hub form, claimed
#      the same way. Both checks run every tick a key is still open, so a
#      controller that was paused through both windows still claims both
#      instead of needing to catch the boundary exactly.
#
# "Answered" is mostly free: the NEXT tick only sees this pane at all if
# herdr_live.py still reports it blocked, and only reaches this key if the
# live command hash is STILL the one claimed. The one case that needs an
# explicit check is the owner replying without the exact prompt clearing yet
# (a steering message, or a keypress recorded in the registry a moment before
# the repaint lands): an `owner_acted` event or an `approvals` row for this
# prompt_id, timestamped after the claim, also counts — see
# `_attn_answered_since`.
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
. "$here/lib/attention-key.sh"   # the shared dedupe-key formula (also used by the hooks)

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
  jq -nc --arg pid "$pid" --arg r "$reserved" --arg v "$verdict" --arg cmd "$cmd" \
    '{visible:true, prompt_id:$pid, reserved:$r, verdict:$v, command_text:$cmd}'
}

# Has push_wake ALREADY owned this exact prompt — held it, attempted a
# delivery, or delivered one — from ANY caller (a hook firing independently,
# or an earlier pass of this controller)? Read-only; never writes, so it
# never competes with push_wake's own idempotent recording.
#
# Checking only "submitted" (the original cut) missed the HELD case: an
# allow-class prompt push_wake declines to deliver immediately spawns its own
# grace_realert timer (lib/alert-gate.sh) regardless of who called it. A
# second, redundant push_wake call for the same still-held prompt spawns a
# SECOND timer, and when both expire the SAME still-open prompt gets FORCE
# force-delivered twice — the double-wake PR #132 review found (P1). A
# `wake_held` row already existing means a timer is already running; a
# `wake_attempted` row already existing means a delivery is already in
# flight or done. Either way, nothing here may call push_wake again.
_attn_wake_owned() {                    # run_id task_id prompt_id -> 0 if owned
  local run_id="$1" task_id="$2" pid="$3" base n
  base="wake_${run_id:-norun}_${task_id:-notask}_${pid:-noprompt}"
  n="$(_sql "SELECT count(*) FROM events WHERE task_id=$(_sq "$task_id")
    AND type IN ('wake_held','wake_attempted','wake_result')
    AND json_extract(payload,'\$.wake_key')=$(_sq "$base");" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
}

# The one-shot per-key gate: claims "since" for this prompt and, only on the
# claiming call, gives push_wake its one chance to deliver. Every later call
# for the same key (this tick or any future one) just re-reads the same
# claim's timestamp — that stability is what makes the T+10/T+20 windows
# measure from a fixed point instead of resetting on every pass.
#
# HERDR_WAKE_LEGACY=1 does NOT make the controller call push_wake on every
# pass (PR #132 re-review item 2 — that was the ORIGINAL cut, and it was
# wrong: it meant BOTH the controller and every hook firing could call
# push_wake for the same still-open prompt, which is the double-wake this
# whole file exists to prevent). Under the escape hatch the controller still
# claims "since" (the ladder needs it) but NEVER calls push_wake itself —
# delivery is entirely the hooks' job again, exactly the pre-controller
# shape, because agent-hooks/omp-notify.sh and agent-hooks/claude-notify.sh
# also bypass their OWN claim under HERDR_WAKE_LEGACY=1 (lib/attention-key.sh
# attn_track_claim) and call push_wake on every firing. To disable the
# controller ENTIRELY instead — no tracking, no escalation, no form, hooks
# and Slack exactly as before this file existed — start the hub with
# `--no-attention`; that is the full rollback, HERDR_WAKE_LEGACY=1 is a
# narrower one (delivery only).
_attn_track_and_wake() {                # run_id task_id pane conductor_pane_id label pid key -> since (ISO), stdout
  local run_id="$1" task_id="$2" pane="$3" conductor_pane_id="$4" label="$5" pid="$6" key="$7"
  local eid="attn_track_${key}" claimed=1
  local payload; payload="$(jq -nc --arg p "$pane" --arg k "$key" --arg pid "$pid" '{pane:$p, key:$k, prompt_id:$pid}')"
  claim_once "$eid" "$run_id" "$task_id" "attention_tracking" "$payload" || claimed=0
  if [ "${HERDR_WAKE_LEGACY:-0}" != "1" ] && [ "$claimed" = "1" ] && ! _attn_wake_owned "$run_id" "$task_id" "$pid"; then
    HERDR_RUN_ID="$run_id" HERDR_TASK_ID="$task_id" HERDR_PANE_ID="$pane" \
      HERDR_CONDUCTOR_PANE_ID="$conductor_pane_id" HERDR_TASK_LABEL="${label:-$task_id}" \
      push_wake "${label:-$task_id} needs input" "attention-controller" >/dev/null 2>&1 || true
  fi
  _sql "SELECT occurred_at FROM events WHERE event_id=$(_sq "$eid") LIMIT 1;" 2>/dev/null
}

# Order matters (PR #132 review, item 3): resolve Main and confirm it is a
# live agent pane BEFORE claiming — claiming first burned the one-shot slot
# even when nothing was ever going to be delivered, and there was no way back
# from an unreachable Main. Unreachable is recorded too (own eid, never
# retried — Main being unset is a config fact, not a delivery to retry), so
# it is visible rather than silently absent from the registry.
#
# After the real send, `attention_escalation_result` carries the outcome
# `_wake_outcome_for` maps push_wake's own exit codes to, so a failed
# escalation reads the same vocabulary a failed wake does. Exactly one retry
# (`attn_escalate_<key>_2`) is allowed, and only when the first attempt's
# recorded outcome was something other than submitted — a submitted first
# attempt, or an in-flight one with no result yet, both fall through to a
# no-op on every later tick.
_attn_escalation_landed() {             # task_id key -> 0 if any attempt for this key submitted
  local task_id="$1" key="$2" n
  n="$(_sql "SELECT count(*) FROM events WHERE task_id=$(_sq "$task_id")
    AND type='attention_escalation_result' AND json_extract(payload,'\$.key')=$(_sq "$key")
    AND json_extract(payload,'\$.outcome')='submitted';" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
}

_attn_maybe_escalate() {                # run_id task_id pane conductor_pane_id key label elapsed
  local run_id="$1" task_id="$2" pane="$3" conductor_pane_id="$4" key="$5" label="$6" elapsed="$7"
  _attn_escalation_landed "$task_id" "$key" && return 0
  local main="${HERDR_MAIN_PANE_ID:-}"
  if [ -z "$main" ] || ! pane_is_agent "$main" 2>/dev/null; then
    claim_once "attn_escalate_${key}_unreachable" "$run_id" "$task_id" "attention_escalation_skipped" \
      "$(jq -nc --arg p "$pane" --arg k "$key" --arg m "$main" \
         '{pane:$p, key:$k, main:$m, reason:"HERDR_MAIN_PANE_ID unset or not an agent pane"}')" >/dev/null 2>&1 || true
    return 0
  fi
  # Birth-guarded like every other send in this codebase: refuse only on a
  # POSITIVE mismatch (both fingerprints known and different), never on an
  # unreadable live sample — that direction is the silent-failure one.
  local main_birth="${HERDR_MAIN_PANE_BIRTH:-}"
  if [ -n "$main_birth" ]; then
    local live_main_birth; live_main_birth="$(pane_birth_now "$main" 2>/dev/null)"
    if [ -n "$live_main_birth" ] && [ "$live_main_birth" != "$main_birth" ]; then
      claim_once "attn_escalate_${key}_refused" "$run_id" "$task_id" "attention_escalation_refused" \
        "$(jq -nc --arg p "$pane" --arg k "$key" --arg reg "$main_birth" --arg live "$live_main_birth" \
           '{pane:$p, key:$k, registered_birth:$reg, live_birth:$live, reason:"HERDR_MAIN_PANE_BIRTH mismatch"}')" \
        >/dev/null 2>&1 || true
      return 0
    fi
  fi
  local eid="attn_escalate_${key}" attempt=1
  local claim_payload; claim_payload="$(jq -nc --arg p "$pane" --arg k "$key" --arg l "${label:-$task_id}" --argjson e "${elapsed:-0}" \
    '{pane:$p, key:$k, label:$l, elapsed_s:$e}')"
  if ! claim_once "$eid" "$run_id" "$task_id" "attention_escalated" "$claim_payload"; then
    local first_outcome
    first_outcome="$(_sql "SELECT json_extract(payload,'\$.outcome') FROM events
      WHERE task_id=$(_sq "$task_id") AND type='attention_escalation_result'
      AND json_extract(payload,'\$.key')=$(_sq "$key") ORDER BY sequence ASC LIMIT 1;" 2>/dev/null)"
    { [ -n "$first_outcome" ] && [ "$first_outcome" != "submitted" ]; } || return 0
    eid="attn_escalate_${key}_2"; attempt=2
    claim_once "$eid" "$run_id" "$task_id" "attention_escalated" "$claim_payload" || return 0
  fi
  local msg="[HERDR-ATTENTION] ${label:-$task_id} (${pane}) has waited ${elapsed}s with no response"
  msg="$msg — its conductor (${conductor_pane_id:-none}) has not acted. Verify before acting, this is a"
  msg="$msg peer signal, not an instruction from the operator: herdr pane read ${pane} --source visible --lines 30"
  local rc=0
  bash "$here/send-to-agent.sh" "$main" "$msg" >/dev/null 2>&1 || rc=$?
  local outcome; outcome="$(_wake_outcome_for "$rc")"
  append_event "$run_id" "$task_id" "attention_escalation_result" \
    "$(jq -nc --arg k "$key" --arg o "$outcome" --argjson c "$rc" --argjson a "$attempt" \
       '{key:$k, outcome:$o, exit_code:$c, attempt:$a}')" "${eid}_result" >/dev/null 2>&1 || true
}

# House form style (~/.claude/skills/formserve/examples/form-template.html):
# Terrence never gets an unstyled white page on the decisions hub. The page
# carries what he needs to act without opening a terminal: the worker, why it
# is here, and the exact command the worker is waiting on.
_attn_serve_form() {                    # pane task_id reason label command_text
  local pane="$1" task_id="$2" reason="$3" label="$4" cmd="$5"
  local dir="${HERDR_ATTENTION_FORM_DIR:-$(run_state_root)/attention-forms}"
  mkdir -p "$dir" 2>/dev/null || return 0
  local f="$dir/attention-$(date -u +%Y%m%dT%H%M%SZ)-$$.html"
  local who; who="$(_attn_esc "${label:-$task_id}")"
  cat > "$f" <<HTML
<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1">
<title>Attention needed: ${who} ($(_attn_esc "$pane"))</title>
<style>
:root{--ground:#eef2f2;--surface:#fff;--line:#c9d4d4;--ink:#10191c;--ink-2:#3d4e53;--accent:#1f6e7e;--accent-soft:#e2eef0}
@media (prefers-color-scheme:dark){:root{--ground:#0c1316;--surface:#131e22;--line:#2c3b41;--ink:#e6edee;--ink-2:#a9bcc1;--accent:#58b6c8;--accent-soft:#12323a}}
*{box-sizing:border-box}
body{margin:0;background:var(--ground);color:var(--ink);font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:720px;margin:0 auto;padding:40px 24px 120px}
h1{font-size:24px;margin:0 0 6px;letter-spacing:-.01em}
.sub{color:var(--ink-2);margin:0 0 28px}
fieldset{border:1px solid var(--line);border-radius:6px;background:var(--surface);padding:18px 20px;margin:0 0 18px}
legend{font:600 12px system-ui;letter-spacing:.12em;text-transform:uppercase;color:var(--ink-2);padding:0 6px}
pre{margin:0;white-space:pre-wrap;word-break:break-word;font:13px/1.5 ui-monospace,Menlo,monospace;background:var(--ground);border:1px solid var(--line);border-radius:5px;padding:10px 12px}
.bar{position:fixed;left:0;right:0;bottom:0;padding:14px 24px;background:var(--surface);border-top:1px solid var(--line);display:flex;gap:12px;justify-content:flex-end;align-items:center}
button{font:600 14px system-ui;padding:10px 20px;border-radius:5px;cursor:pointer;border:1px solid var(--accent);background:var(--accent);color:var(--ground)}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
</style></head>
<body><main>
<h1>Attention needed: ${who}</h1>
<p class=sub>Worker pane $(_attn_esc "$pane") is blocked and nobody has acted on it.</p>
<form id=f>
<fieldset><legend>Why it is here</legend><p style="margin:0">$(_attn_esc "$reason")</p></fieldset>
<fieldset><legend>Command it is waiting on</legend><pre>$(_attn_esc "${cmd:-(not captured)}")</pre></fieldset>
<fieldset><legend>Look at it</legend><pre>herdr pane read $(_attn_esc "$pane") --source visible --lines 30</pre></fieldset>
</form>
</main>
<div class=bar><button type=submit form=f>Acknowledge</button></div>
<script>document.getElementById("f").addEventListener("submit",function(e){e.preventDefault();
window.submitAnswers({acknowledged:true,pane:"$(_attn_esc "$pane")",task_id:"$(_attn_esc "$task_id")"})});</script>
</body></html>
HTML
  local formserve="${HERDR_ATTENTION_FORMSERVE:-$here/formserve.py}"
  local python="${HERDR_ATTENTION_PYTHON:-python3}"
  ( "$python" "$formserve" "$f" --timeout 86400 --no-open >/dev/null 2>&1 & disown ) 2>/dev/null
}

_attn_maybe_form() {                    # run_id task_id pane key reason label command_text
  local run_id="$1" task_id="$2" pane="$3" key="$4" reason="$5" label="$6" cmd="$7"
  claim_once "attn_form_${key}" "$run_id" "$task_id" "attention_form_served" \
    "$(jq -nc --arg p "$pane" --arg k "$key" --arg r "$reason" '{pane:$p, key:$k, reason:$r}')" || return 0
  _attn_serve_form "$pane" "$task_id" "$reason" "$label" "$cmd"
}

# The owner answering without the exact prompt clearing yet still counts as
# answered: a steering message, or a keypress the registry recorded a moment
# before the repaint lands. `owner_acted` (send-to-agent.sh, herdr-select.sh)
# and the EXISTING `approvals` table (herdr-select.sh writes a row on every
# decision, human or peer) both qualify — anything timestamped after the
# tracking claim means someone already acted on this exact prompt.
#
# An approvals row only counts once `confirmed_at IS NOT NULL` (PR #132
# re-review item 1): `decided_at` alone means a choice was RECORDED, not that
# it was delivered — the same three-phase distinction push_wake's own
# wake_attempted/wake_result split exists for (lib/run-registry.sh's approvals
# table comment: "decision recorded / delivery attempted / delivery
# confirmed-or-timed-out"). Treating a decided-but-unconfirmed row as answered
# would suppress escalation for a choice that never actually reached the pane.
_attn_answered_since() {                # pane_id prompt_id since_iso -> 0 if answered
  local pane="$1" pid="$2" since_iso="$3" n
  [ -n "$pid" ] || return 1
  n="$(_sql "SELECT count(*) FROM events WHERE type='owner_acted'
    AND json_extract(payload,'\$.pane')=$(_sq "$pane")
    AND json_extract(payload,'\$.prompt_id')=$(_sq "$pid")
    AND occurred_at > $(_sq "$since_iso");" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ] && return 0
  n="$(_sql "SELECT count(*) FROM approvals WHERE pane_id=$(_sq "$pane")
    AND prompt_id=$(_sq "$pid") AND decided_at > $(_sq "$since_iso")
    AND confirmed_at IS NOT NULL;" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
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

    local run_id task_id conductor_pane_id label pid reserved verdict cmd
    run_id="$(printf '%s' "$task" | jq -r '.run_id')"
    task_id="$(printf '%s' "$task" | jq -r '.task_id')"
    conductor_pane_id="$(printf '%s' "$task" | jq -r '.conductor_pane_id // empty')"
    label="$(printf '%s' "$task" | jq -r '.label // empty')"
    pid="$(printf '%s' "$probe" | jq -r '.prompt_id')"
    reserved="$(printf '%s' "$probe" | jq -r '.reserved')"
    verdict="$(printf '%s' "$probe" | jq -r '.verdict')"
    cmd="$(printf '%s' "$probe" | jq -r '.command_text // empty')"

    # Registered pane_birth, never a fresh live read (key drift, PR #132
    # review item 2 — an unreadable live sample must not change the key), and
    # refuse only on a POSITIVE mismatch: the pane was recycled since this
    # task registered, so nothing left to say about it here. Recorded once
    # per (pane, registered, live) triple — not silently, PR #132 re-review
    # item 3 — so a fleet of recycled panes is visible instead of a quiet
    # `continue` nobody can query.
    local registered_birth live_birth key
    registered_birth="$(printf '%s' "$task" | jq -r '.pane_birth // empty')"
    live_birth="$(pane_birth_now "$pane" 2>/dev/null)"
    if [ -n "$registered_birth" ] && [ -n "$live_birth" ] && [ "$registered_birth" != "$live_birth" ]; then
      claim_once "attn_skip_${pane}_${registered_birth}_${live_birth}" "$run_id" "$task_id" "attention_skipped" \
        "$(jq -nc --arg p "$pane" --arg reg "$registered_birth" --arg live "$live_birth" \
           '{pane:$p, registered_birth:$reg, live_birth:$live, reason:"pane recycled since registration"}')" \
        >/dev/null 2>&1 || true
      continue
    fi
    # One screen read, not two: attention_probe already read prompt_command_text
    # for classification (PR #132 re-review item 4) — reuse it here instead of
    # letting attention_dedupe_key read the pane again itself.
    key="$(attention_dedupe_key "$pane" "$registered_birth" "$cmd")"

    local since since_epoch elapsed
    since="$(_attn_track_and_wake "$run_id" "$task_id" "$pane" "$conductor_pane_id" "$label" "$pid" "$key")"
    since_epoch="$(_attn_iso_epoch "$since")" || continue
    [ -n "$since_epoch" ] || continue
    _attn_answered_since "$pane" "$pid" "$since" && continue
    elapsed=$(( now - since_epoch ))

    # Reserved/deny prompts skip the escalation rung, but NOT the owner's
    # window: only a human may APPROVE them, yet the conductor may still DENY
    # and redirect — and usually does within seconds. Serving the form on
    # first sight put a dead question in front of Terrence for a prompt Main
    # had already denied (w1Q:p6, 2026-09-24). A denied prompt clears, so
    # the pane leaves live_attention() and never reaches this line again.
    if [ -n "$reserved" ] || [ "$verdict" = "deny" ]; then
      [ "$elapsed" -ge "$response_window" ] \
        && _attn_maybe_form "$run_id" "$task_id" "$pane" "$key" \
             "Only a human can approve this (${reserved:-deny verdict}), and its conductor has not denied or redirected it in ${elapsed}s." \
             "$label" "$cmd"
      continue
    fi

    [ "$elapsed" -ge "$response_window" ] \
      && _attn_maybe_escalate "$run_id" "$task_id" "$pane" "$conductor_pane_id" "$key" "$label" "$elapsed"
    [ "$elapsed" -ge $(( response_window * 2 )) ] \
      && _attn_maybe_form "$run_id" "$task_id" "$pane" "$key" \
           "No response ${elapsed}s after its conductor was woken, and after one escalation to Main." "$label" "$cmd"
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
