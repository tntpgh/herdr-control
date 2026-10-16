#!/usr/bin/env bash
# omp-notify.sh — omp's equivalent of claude-notify.sh: alert when a worker
# needs input, both to Slack and as a push wake to its conductor.
#
# ---- what triggers this ------------------------------------------------------
# omp DOES have a "I am asking the human something" surface, and this hook is
# wired to it: `tool_approval_requested` for the approval menu and
# `tool_execution_start` on the `ask` tool for a question (see
# agent-hooks/omp-herdr-control.ts). omp's own herdr integration drives
# pane.report_agent blocked/idle off the same pair.
#
# This file used to say omp had no such event and hang off `tool_call`, which
# fires before EVERY tool call, approved or not. That premise was wrong, and it
# cost: the script had to VERIFY by screen-scraping its own pane on every tool
# call of every worker — 20 `herdr pane read` RPCs and 10 python spawns each,
# which pushed the herdr socket's p95 from 9ms to 136ms with the fleet working
# and made the TUI itself feel laggy (measured 2026-09-14).
#
# The pane read stays, but only on this path: the EVENT says a human is needed,
# the pane says WHAT is on screen — the option rows Slack shows and the
# prompt_id a later answer is asserted against. An auto-approved tool call now
# never reaches this script at all, so it costs nothing.
#
# Reads one JSON object on stdin: {"tool": "...", "message": "...", "cwd": "..."}
# Always exits 0 — a monitoring hook must never fail the agent it monitors.
set -uo pipefail
_hook_dir=$(cd "$(dirname "$0")" && pwd)
here=$(cd "$_hook_dir/.." && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/push-wake.sh"

input="$(cat 2>/dev/null || true)"
tool="$(printf '%s' "$input" | jq -r '.tool // ""' 2>/dev/null || printf '')"
msg="$(printf '%s' "$input" | jq -r '.message // ""' 2>/dev/null || printf '')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || printf '')"
# Untruncated command (project-contract-plan.md #3b, item 2), when the caller
# has it — agent-hooks/omp-herdr-control.ts sends this only for a bash/shell
# tool_approval_requested, separate from `message` (which stays truncated for
# display). herdr-select.sh reads it back from the input_required event this
# script writes via push_wake, keyed to the same prompt_id.
full_cmd="$(printf '%s' "$input" | jq -r '.command // ""' 2>/dev/null || printf '')"
[ -n "$msg" ] || msg="omp needs your permission${tool:+ to use $tool}"

# The worker's own pane. Without it there is no way to confirm a prompt is real,
# and alerting unverified is exactly the storm this script exists to avoid — so
# no pane means no alert. spawn-task.sh stamps HERDR_PANE_ID into the worker's
# environment; an omp session started by hand outside spawn-task.sh therefore
# stays reconciliation-only (attention.sh, wait-for-blocked.sh, the interval
# sweep), which is the same deal a hand-started Claude session gets for its push
# wake.
pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || exit 0

# Is a prompt actually on screen? For an `ask` question, either shape counts:
# prompt_any_visible answers the menu shape and the numbered shape from ONE
# `herdr pane read` (two separate predicates cost 20 CLI spawns and 10 python3
# spawns per tool call per worker, ~1.86s of CPU, measured 2026-09-14).
#
# For an APPROVAL event only the approval panel counts: prompt_menu_visible,
# which needs the `Allow tool:` header, an Approve row AND the navigation
# footer at the bottom of the pane — still one read. Accepting the numbered
# shape here is how a peer signal fired on 2026-09-24 while a worker was
# streaming a Write panel with no menu up: the file body being previewed was a
# numbered markdown list, `N. text` in the last 20 rows matched the numbered
# extractor, and the alert gate then classified that screen text as if it were
# a command. omp approval prompts are never numbered (lib/agent-profiles.sh
# declares omp `menu-prompt` only), so for them a numbered match is always
# transcript, never a question. An unrecognized approval menu (Approve /
# Always allow / Deny) still counts: the parser marks it visible, just not
# complete, and the gate hands it to a person.
if [ "$tool" = ask ]; then
  _prompt_is_up() { prompt_any_visible "$pane" 2>/dev/null; }
else
  _prompt_is_up() { prompt_menu_visible "$pane" 2>/dev/null; }
fi

# Is whatever panel is ON SCREEN right now actually THIS call's own input?
# `_prompt_is_up` alone only answers "is A panel up" — omp shows one
# approval panel at a time and paints queued ones oldest-first, so a
# concurrent call's hook can see its PEER's panel (trace:
# task_20261016T021313Z_56367_9233 02:13:24-36Z, two bash calls
# A(`ls`)/B(`git log`) approved the same second; the hook firing for B
# fingerprinted A's still-painted panel and wrote B's call id against it).
# `full_cmd` (header comment above) is only populated for a bash/shell
# approval; other tools have no recorded command text to compare against
# the panel and rely on the occurrence-ordering check in _occ_still_ours
# below alone. approval_command_text/corroboration_candidates
# (lib/scoped-policy.sh, pulled in transitively via lib/push-wake.sh ->
# lib/alert-gate.sh) are the exact comparison herdr-select.sh and
# push_wake itself already use to corroborate a recorded command against
# the panel's Command:/run: region — reused here rather than a second,
# driftable copy of the same rule.
_panel_matches_call() {
  [ -n "$full_cmd" ] || return 0
  corroboration_candidates "$pane" ""
  approval_command_text "$CC_PANEL" "$full_cmd" "$CC_WRAPJOIN" >/dev/null 2>&1
}

# tool_call fires BEFORE omp paints the approval menu, so a single check would
# usually miss it. Poll briefly. Each attempt costs one `herdr pane read`; the
# sleep is a real settle rather than a busy loop, and this runs detached from the
# agent's turn so the wait costs the agent nothing.
#
# Bounded deliberately: if no prompt has painted within ~1.5s the tool was
# auto-approved and there is nothing to alert about. Waiting longer would only
# delay discovering that.
#
# 5 attempts at 0.3s, not 10 at 0.15s: an approval menu is a BLOCKING prompt —
# once painted it stays until someone answers it — so a coarser poll can only
# delay detection by one interval, never miss it, and it halves the RPCs this
# fires at the herdr server on every tool call of every pane.
#
# Deliberately cheap and identity-oblivious: this is only a "something
# painted" hint, never trusted to write provenance on its own. The gate
# below (occurrence ordering + content corroboration) re-verifies before
# anything is ever written, so this stays `_prompt_is_up` alone rather than
# adding a second `herdr pane read` (corroboration_candidates) to every one
# of these tight 0.3s ticks.
# One total budget for every probe below, measured from here with bash's
# SECONDS counter; the env override is clamped to 1..10s.
_budget="${HERDR_NOTIFY_UNREADABLE_DEADLINE_S:-10}"
case "$_budget" in ''|*[!0-9]*) _budget=10 ;; esac
[ "$_budget" -gt 10 ] && _budget=10
[ "$_budget" -lt 1 ] && _budget=1
SECONDS=0
found=0
for _ in 1 2 3 4 5; do
  if _prompt_is_up; then found=1; break; fi
  [ "$SECONDS" -lt "$_budget" ] || break
  sleep 0.3
done

# Occurrence identity for this hook firing. call_id/native_session arrive only
# from the approval path (notifyForPrompt); an `ask` question (no call id) or a
# hand-started session (no HERDR_RUN_ID/HERDR_TASK_ID) has no occurrence.
call_id="$(printf '%s' "$input" | jq -r '.call_id // ""' 2>/dev/null || printf '')"
native_session="$(printf '%s' "$input" | jq -r '.native_session // ""' 2>/dev/null || printf '')"
_has_occ=0
if [ -n "$call_id" ] && [ -n "$native_session" ] && [ -n "${HERDR_RUN_ID:-}" ] \
   && [ -n "${HERDR_TASK_ID:-}" ] && [ -f "$here/lib/prompt-occurrence.py" ]; then
  _has_occ=1
  _occ_pane_birth="$(read_task "$HERDR_RUN_ID" "$HERDR_TASK_ID" 2>/dev/null \
    | jq -r '.pane_birth // ""' 2>/dev/null || printf '')"
  _occ_py="$(_registry_python 2>/dev/null)" || _has_occ=0
fi

# Is the prompt on screen still THIS hook's occurrence? Fail closed: true
# only on positive binding — this call's own seen exists and is `requested`
# (not answered/declined/withdrawn/completed, no authorization), AND it is
# the EARLIEST still-`requested` occurrence for this task. omp paints
# queued approval panels oldest-first (a few lines up), so "earliest
# unresolved" is what is actually on screen right now — the previous rule
# bound whichever call's own seen was the task's LATEST seen, which is
# backwards: it let a LATER call's hook bind to an EARLIER call's still-
# visible panel (root cause, trace at the top of this file's PR), and it
# made the EARLIER call's own hook give up the instant a later one was
# seen, even though the earlier call's panel was the one genuinely on
# screen (trace: hook A exited at once, superseded=1, because A "was not
# the task's latest seen"). Missing evidence (no seen, unreadable birth)
# leaves the prompt unresolved for the reconciliation paths rather than
# attaching this hook's tool to it; "still requested but not yet earliest"
# is its own outcome (`_occ_not_yet`, never superseded) — the caller keeps
# waiting for its own turn instead of giving up or wrongly binding.
_occ_still_ours() {
  local live st key earliest lc
  _occ_missing=0; _occ_why=birth; _occ_not_yet=0
  if [ -n "${_occ_pane_birth:-}" ]; then
    live="$(pane_birth_now "$pane" 2>/dev/null)" || return 1
    [ "$live" = "$_occ_pane_birth" ] || return 1
  fi
  st="$("$_occ_py" "$here/lib/prompt-occurrence.py" state --db "$(registry_db)" \
    --run "$HERDR_RUN_ID" --task "$HERDR_TASK_ID" --pane "$pane" --birth "${_occ_pane_birth:-}" \
    --session "$native_session" --call-id "$call_id" 2>/dev/null)" || { _occ_why=state_failed; return 1; }
  lc="$(printf '%s' "$st" | jq -r '.lifecycle // ""' 2>/dev/null)"
  _occ_why="lifecycle:${lc:-empty}"
  # No seen of our own at all: unbound for lack of evidence, not superseded.
  [ "$lc" = unknown ] && [ "$(printf '%s' "$st" | jq -r '.authorization // "none"' 2>/dev/null)" = none ] \
    && [ -z "$(printf '%s' "$st" | jq -r '.unresolved_reason // ""' 2>/dev/null)" ] && _occ_missing=1
  [ "$lc" = requested ] || return 1
  [ "$(printf '%s' "$st" | jq -r '.authorization // "none"' 2>/dev/null)" = none ] || return 1
  key="$(printf '%s' "$st" | jq -r '.occ_key // ""' 2>/dev/null)"
  # Scoped to THIS call's own (pane, pane_birth, native_session) — never
  # the whole task_id. fold_task has no occurrence-identity boundary of its
  # own (lib/prompt-occurrence.py fold_task queries WHERE run_id=? AND
  # task_id=? only, with no pane/birth/session filter), so an unscoped
  # "earliest requested across the task" starves every later call forever
  # the moment ANY occurrence never resolves — a crashed call, a killed
  # pane, or omp-herdr-control.ts's in-memory occurrenceByCallId map losing
  # a call across a harness restart before tool_execution_end ever fires
  # (review BLOCK, Finding 1: review/notify-binding-concurrent REVIEW.md).
  # pane_id/pane_birth/native_session are recorded on every fold record
  # from its own `seen` payload (lib/prompt-occurrence.py fold_task,
  # rec["pane_id"]/rec["pane_birth"]/rec["native_session"]), so filtering on
  # them here needs no new fold parameter or registry query — a stale
  # occurrence from a previous pane birth or session is excluded by
  # construction, exactly like the `state` call three lines up already
  # scopes by the same three fields.
  #
  # Within the SAME (pane, birth, session) scope a never-resolved
  # occurrence can still starve every later call in that one session
  # forever (an aborted call with no tool_execution_end). Ordering proves
  # it dead instead: if a LATER occurrence (by first_seen_seq) in the same
  # scope has already resolved (completed/declined/withdrawn — any
  # `resolved:*` lifecycle), the earlier still-`requested` one cannot
  # still be the one on screen, because omp paints panels oldest-first —
  # the later one could not have been reached, let alone resolved, while
  # the earlier one was still genuinely pending. Excluded by
  # construction below rather than trusted as "earliest": a requested
  # occurrence whose first_seen_seq is <= the scope's latest resolved
  # first_seen_seq is dead weight, not a live blocker. Genuine concurrent
  # ambiguity (two still-live requested calls) is untouched: neither is
  # resolved, so neither excludes the other, and the command-corroboration
  # check below still fails closed on a mismatch.
  earliest="$("$_occ_py" "$here/lib/prompt-occurrence.py" fold --db "$(registry_db)" \
    --run "$HERDR_RUN_ID" --task "$HERDR_TASK_ID" 2>/dev/null \
    | jq -r --arg p "$pane" --arg b "${_occ_pane_birth:-}" --arg s "$native_session" '
        [.[] | select(.pane_id==$p) | select(.pane_birth==$b) | select(.native_session==$s)] as $scope
        | ([$scope[] | select(.lifecycle | startswith("resolved")) | .first_seen_seq] | max // -1) as $deadline
        | [$scope[] | select(.lifecycle=="requested") | select(.first_seen_seq > $deadline)]
        | sort_by(.first_seen_seq) | (.[0].occ_key // "")
      ' 2>/dev/null)"
  _occ_why=earliest
  if [ -n "$key" ] && [ "$key" = "$earliest" ]; then _occ_why=bound; return 0; fi
  # Still genuinely pending (requested, unresolved) — just behind another
  # call's panel in the queue, never "gone".
  _occ_not_yet=1
  return 1
}

# Decision trace for this firing: which branch ended it, and why the binding
# held or failed. Identifiers and booleans only — no screen text, command or
# tool input — so a probe that ends without provenance is diagnosable from
# the registry instead of guessed (live w7S:p7 00:45Z/01:00Z both ended ~2s
# in with no recorded reason).
_probe_firing="$$_$(date +%s)"       # per-firing, non-secret; call/task carry the correlation
_probe_trace() {                        # <outcome> [push_rc] [mode]
  [ "$_has_occ" = 1 ] || return 0
  append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "notify_probe_outcome" \
    "$(jq -nc --arg o "$1" --arg rc "${2:-}" --arg md "${3:-}" --arg c "$call_id" --arg fi "$_probe_firing" \
        --arg f "$found" --arg s "$_superseded" \
        --arg m "${_occ_missing:-}" --arg w "${_occ_why:-}" --arg e "${_entry_why:-}" --argjson t "$SECONDS" \
        '{outcome:$o, push_rc:$rc, push_mode:$md, tool_call_id:$c, firing:$fi, found:$f, superseded:$s,
          missing:$m, last_binding:$w, entry_binding:$e, elapsed_s:$t}')" \
    "notify_probe_${HERDR_TASK_ID}_${call_id}_${_probe_firing}" >/dev/null 2>&1 || true
}

# The approval panel being up is not enough on its own (found=1 above is a
# cheap, identity-oblivious screen check) — everything below re-verifies,
# right up to the moment provenance is written, that BOTH (a) this is the
# earliest still-open occurrence for the task (omp paints oldest-first, so
# that is what is actually on screen) and (b) when a command is recorded at
# all, the screen's own Command:/run: region equals it. Neither alone is
# enough: two IDENTICAL commands racing concurrently defeat (b)
# (approval_command_text's own comment), and two DIFFERENT commands racing
# concurrently defeat (a) if "ours" were content-blind (the ls/git log
# trace above). "Still pending but not our turn yet" (`_occ_not_yet`) is
# never superseded — the caller keeps waiting, bounded, for its OWN panel
# rather than giving up (the old rule's failure for A) or binding to
# someone else's (the old rule's failure for B).
_superseded=0
if [ "$_has_occ" = 1 ]; then
  _occ_still_ours; _entry_rc=$?; _entry_why="$_occ_why"
  if [ "$_entry_rc" = 0 ] && [ "$found" = 1 ] && _panel_matches_call; then
    : # already fully confirmed by the fast probe above: bound, on screen,
      # and (when a command was recorded) the screen agrees with it.
  elif [ "$_entry_rc" != 0 ] && [ "$_occ_missing" != 1 ] && [ "$_occ_not_yet" != 1 ]; then
    found=0; _superseded=1
  elif [ "$_occ_missing" = 1 ]; then
    # No seen of our own at all: nothing to wait for. A panel the fast
    # probe already saw (found=1) has no binding evidence behind it either
    # — never ours to claim or to record a screen row against — so that
    # case is treated the same as a genuine supersede, exactly as the old
    # code's separate "every successful parse" re-check used to (it ran
    # _occ_still_ours again regardless of _occ_missing and wiped found).
    [ "$found" = 1 ] && _superseded=1
    found=0
  else
    found=0
    while [ "$SECONDS" -lt "$_budget" ]; do
      _occ_still_ours
      if [ $? -ne 0 ] && [ "$_occ_not_yet" != 1 ]; then _superseded=1; break; fi
      sleep 0.5
      if _prompt_is_up && _panel_matches_call; then
        _occ_still_ours
        if [ $? -eq 0 ]; then found=1; break; fi
        [ "$_occ_not_yet" = 1 ] || { _superseded=1; break; }
      fi
    done
  fi
fi

# The ONE prompt this hook may speak for, captured once right after binding.
# Every later write/claim/timer uses it and nothing re-reads a fresh id, so a
# replacement prompt painted meanwhile can never be (re)bound to this hook.
_bound_pid=""
[ "$found" = 1 ] && _bound_pid="$(prompt_id "$pane" 2>/dev/null || printf '')"
[ "$found" = 1 ] && [ -z "$_bound_pid" ] && { found=0; _superseded=1; }
# Final guard, run immediately before each provenance write: the occurrence
# is still ours AND the screen still shows exactly the bound prompt.
_still_bound() {
  [ -n "$_bound_pid" ] || return 1
  if [ "$_has_occ" = 1 ]; then _occ_still_ours || return 1; fi
  [ "$(prompt_id "$pane" 2>/dev/null || printf '')" = "$_bound_pid" ]
}

# Persist a prompt_occ_screen observation against the SAME occurrence
# onApprovalRequested already recorded `seen` for, whether or not a prompt
# ever painted — a failed/not-found probe used to just `exit 0` here with
# nothing left behind (docs/plans/dot-herdr-recovery-slices.md §2). A
# superseded occurrence records nothing: the screen belongs to another one.
if [ "$_has_occ" = 1 ] && [ "$_superseded" = 0 ]; then
  if [ "$found" = 1 ]; then
    _occ_display=pending_parseable; _occ_screen_id="$_bound_pid"
    _still_bound || { found=0; _superseded=1; }
  else
    _occ_display="$(prompt_occurrence_display "$pane" 2>/dev/null || printf 'read_failed')"
    # Parseable only now (after the bound checks): not ours to name.
    _occ_screen_id=""
  fi
  [ "$_superseded" = 0 ] && "$_occ_py" "$here/lib/prompt-occurrence.py" screen \
    --db "$(registry_db)" --run "$HERDR_RUN_ID" --task "$HERDR_TASK_ID" --pane "$pane" \
    --birth "$_occ_pane_birth" --session "$native_session" --call-id "$call_id" \
    --display "$_occ_display" ${_occ_screen_id:+--prompt-id "$_occ_screen_id"} \
    >/dev/null 2>&1 || true
fi

if [ "$found" != 1 ]; then _probe_trace no_provenance; exit 0; fi

where="${cwd##*/}"
[ -n "$where" ] && msg="$msg  ·  ${where}"

# ---- push wake to the conductor --------------------------------------------
# Authoritative record FIRST, before any optional (and possibly blocking)
# notification, under the bound prompt id with a final guard; push_wake
# itself refuses if the screen no longer shows HERDR_EXPECT_PROMPT_ID, so no
# window remains between this check and its own prompt_id read.
#
# All the guards (agent-pane gate, conductor pane-birth revalidation, prompt_id
# capture, delivery-outcome recording) live in lib/push-wake.sh, shared with
# claude-notify.sh so the two cannot drift.
#
# `$tool` (herdr-control #191) is omp's own `event.toolName` from
# tool_approval_requested, parsed above alongside $msg/$full_cmd — never
# scraped panel text. push_wake records it on the SAME input_required row
# unconditionally, and herdr-select.sh refuses any omp menu panel whose
# scraped "Allow tool: <X>" header does not equal it, so a body row that
# merely starts with that literal can no longer stand in for a real header
# that scrolled off-screen.
#
# Claimed through the SAME attn_track_<key> the attention controller uses
# (lib/attention-key.sh) before calling push_wake at all — PR #132 review,
# item 6: a firing on a still-open prompt the controller (or an earlier
# firing) already owns must not call push_wake again — that is what turned
# one held prompt into two delivered wakes (item 1). HERDR_WAKE_LEGACY=1 is
# the rollback: every firing calls push_wake again, unclaimed.
#
# Losing that claim still records: the controller's row (no tool, no command)
# must not be the only record of this prompt, or herdr-select's #191 check
# refuses every answer to it (live 2026-09-29, 5 of 68 prompts). Record-only
# writes/replaces the row and sends no second wake.
. "$here/lib/attention-key.sh"
_still_bound || { _probe_trace unbound_before_push; exit 0; }
_push_mode=wake
attn_track_claim "$pane" "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" "$_bound_pid" || _push_mode=record-only
if [ "$_push_mode" = wake ]; then
  HERDR_EXPECT_PROMPT_ID="$_bound_pid" push_wake "$msg" "$where" "$full_cmd" "$tool" >/dev/null 2>&1
else
  HERDR_EXPECT_PROMPT_ID="$_bound_pid" push_wake "$msg" "$where" "$full_cmd" "$tool" record-only >/dev/null 2>&1
fi
_push_rc=$?
# push_wake's rc conflates "recorded, no wake" with "refused", so the trace
# reports only what it can observe: whether the registry now holds THIS
# prompt's row carrying THIS hook's tool (possibly from an earlier firing for
# the same call) — never that this firing wrote it.
if [ -n "$tool" ] && [ "$(_sql "SELECT count(*) FROM events WHERE task_id=$(_sq "$HERDR_TASK_ID")
     AND type='input_required' AND json_extract(payload,'\$.prompt_id')=$(_sq "$_bound_pid")
     AND json_extract(payload,'\$.tool')=$(_sq "$tool");" 2>/dev/null)" -ge 1 ] 2>/dev/null; then
  _probe_trace push_attempted_tool_row_present "$_push_rc" "$_push_mode"
else
  _probe_trace push_attempted_no_tool_row "$_push_rc" "$_push_mode"
fi

# ---- outbound Slack alert ---------------------------------------------------
# Same resolution order as claude-notify.sh so a packaged (APM) install and a
# plain checkout both work without editing: explicit override, then this
# checkout, then a deployed herdr-ops skill copy.
for notify in \
  "${HERDR_NOTIFY:-}" \
  "$here/slack-bridge/herdr-notify.sh" \
  "$HOME/.claude/skills/herdr-ops/scripts/slack-bridge/herdr-notify.sh"
do
  [ -n "$notify" ] && [ -f "$notify" ] && break
done
if [ -n "${notify:-}" ] && [ -f "$notify" ] && _still_bound; then
  # --pane, not a cwd hint: unlike the Claude hook we already know exactly which
  # pane asked, because we just confirmed the prompt on it. Passing the pane
  # explicitly avoids herdr-notify having to disambiguate several panes sharing
  # one repo cwd — a wrong guess there sends the operator's reply to a different
  # agent.
  #
  # Gated the same way the conductor wake is (lib/alert-gate.sh, applied inside
  # push_wake): an allow-class, unreserved prompt is one peer-answer.sh takes in
  # seconds, and paging for it is what turned an afternoon of ordinary worker
  # activity into a Slack flood on 2026-09-12. Held, never dropped — if the
  # prompt outlives the grace window the alert is sent after all.
  #
  # Classified for lib/slack-level.sh (2026-09-26): neither send is an error by
  # itself — the conductor is woken for both below — so at the default level
  # both are suppressed and logged. What IS an error is a human-only prompt
  # nobody resolved: that escalates as `human-stale` after HERDR_HUMAN_ALERT_S.
  # A held prompt that stays stuck escalates from agent-edge.sh as `stuck`.
  # At HERDR_SLACK_LEVEL=all no escalation timer is armed: the immediate post
  # goes out, exactly as before. The timer is armed AFTER push_wake (above):
  # grace_realert stands down for any input_required recorded after it was
  # armed, and push_wake has already recorded THIS prompt's input_required.
  # Timers key on the bound prompt id, never a fresh read.
  . "$here/lib/slack-level.sh"
  human_stale=0
  if human_must_answer "$pane" "$full_cmd"; then
    bash "$notify" --class needs-input --choices --pane "$pane" "$msg" >/dev/null 2>&1 || true
    [ "$(slack_level)" = errors ] && human_stale=1
  elif slack_should_send held; then
    # Armed only when it could post (level `all`). At `errors` a held timer can
    # only be suppressed, and it shares grace_realert's claim key with the
    # conductor re-wake push_wake arms for the same prompt — winning that
    # claim to post nothing cost the conductor its wake (PR #166 review).
    grace_realert "$pane" "$_bound_pid" \
      "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" \
      bash "$notify" --class held --choices --pane "$pane" "$msg"
  fi
fi

if [ "${human_stale:-0}" = 1 ]; then
  # Own claim namespace (lib/alert-gate.sh): a peer refusal or the conductor
  # re-wake takes grace_realert_*, and must not silence this ERROR post.
  HERDR_ALERT_GRACE_S="${HERDR_HUMAN_ALERT_S:-300}" HERDR_GRACE_CLAIM_KIND=human_stale \
  grace_realert "$pane" "$_bound_pid" \
    "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" \
    bash "$notify" --class human-stale --choices --pane "$pane" \
    "$msg  ·  only a human may answer this, still open after ${HERDR_HUMAN_ALERT_S:-300}s"
fi

exit 0
