#!/usr/bin/env bash
# alert-gate.sh — decide whether a prompt on a worker pane is one a HUMAN must
# answer, or one an automated peer is allowed to take.
#
# Provides: human_must_answer <pane_id>   0 = tell a person, 1 = a peer may take it
#           grace_realert <pane_id> <prompt_id> <run> <task> <cmd...>
#
# Why this exists: every approval prompt used to produce a Slack alert AND a
# conductor wake, including the ones peer-answer.sh auto-approves two seconds
# later. A worker doing ordinary work (`git status`, `pwd`, a grep, its own test
# suite) generated dozens of pages in an afternoon — 2026-09-12, observed by the
# operator as "we are spamming the slack". An alert channel that fires on
# everything trains its reader to ignore it, which costs exactly the alert that
# mattered. The registry is unchanged: `input_required` is still recorded for
# every prompt, so nothing is hidden from reconciliation, `hub`, or the sweep.
#
# The gate is the SAME classification the answer path enforces
# (lib/command-policy.sh), so the two can never disagree about who owns a
# prompt: if `herdr-select.sh --authority peer` would refuse it, a human is
# genuinely being waited for and the alert goes out. If peer authority would
# take it, the alert is held.
#
# HELD, NOT DROPPED. "Something else will answer it" is an assumption, and this
# codebase keeps finding bugs that live exactly there. grace_realert re-checks
# after HERDR_ALERT_GRACE_S (default 90): if the SAME prompt is still on screen
# and the task is still blocked, the alert fires after all, late but real. So
# the worst case of a broken or absent answer loop is a delayed page, never a
# silent one.
[ -n "${_HERDR_ALERT_GATE_SH:-}" ] && return 0
_HERDR_ALERT_GATE_SH=1
_ag_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_ag_dir/prompt-parse.sh"
. "$_ag_dir/command-policy.sh"

# 0 = a human must answer this. 1 = peer authority may take it.
# Unreadable, unclassifiable, or no prompt at all -> 0. Telling a person about
# something we could not read is the safe direction; staying quiet is not.
human_must_answer() {
  local pane="$1" cmd verdict
  [ -n "$pane" ] || return 0
  # A COMPLETE recognized prompt must be on screen before anything is classified.
  # Two distinct reasons, both found by tests rather than by reasoning:
  #   - Without any shape check the gate trusts its caller: `prompt_command_text`
  #     falls back to the whole visible region when there is no panel, so ordinary
  #     transcript output classifies as `allow` and an alert gets held on the
  #     strength of a log line.
  #   - `visible` is not enough either. An UNRECOGNIZED menu — omp's
  #     "Approve / Always allow / Deny", which carries no `Command:` row — is
  #     visible but incomplete, and holding it would mean suppressing an alert
  #     for a prompt whose command we cannot even read. If the shape is not one
  #     we fully parse, a person decides.
  # A numbered list only counts when the pane is NOT an omp panel pane. omp
  # paints its steering queue as `1. Conductor: …`, which the numbered
  # extractor matches — the collision prompt_id()'s own header documents. With
  # a queue on screen and an UNRECOGNIZED approval panel below it, accepting
  # the numbered shape would hold an alert for a panel no peer can answer
  # (peer-answer.sh acts only on complete panels), i.e. silence for a prompt
  # that is nobody's (PR #60 review, HERDR-AG-06). A complete menu is
  # authoritative; anything else on a pane showing `Allow tool:` furniture is
  # a person's.
  if [ -z "$(prompt_menu_options "$pane" 2>/dev/null)" ]; then
    herdr pane read "$pane" --source visible --lines 60 2>/dev/null | grep -q 'Allow tool:' && return 0
    [ -n "$(prompt_options "$pane" 2>/dev/null)" ] || return 0
  fi
  cmd="$(prompt_command_text "$pane" 2>/dev/null || printf '')"
  [ -n "${cmd//[[:space:]]/}" ] || return 0
  case "$cmd" in *elided*|*truncated*) return 0 ;; esac
  [ -n "$(conductor_reserved_reason "$cmd")" ] && return 0
  verdict="$(classify_command "$cmd" 2>/dev/null || printf 'escalate')"
  [ "$verdict" = allow ] || return 0
  return 1
}

# Re-check after the grace window and alert if a prompt outlived it.
# Runs detached: a notification hook must never hold the agent's turn.
# `<cmd...>` is the alert command; it is expected to carry its own guards and
# its own outcome recording (for the conductor wake that means re-entering
# push_wake with HERDR_ALERT_FORCE=1, not a raw send-to-agent).
#
# The re-check asks ONE question: is a prompt still on screen? It deliberately
# does NOT require the fingerprint to match. The first draft did, and review
# (PR #60, HERDR-AG-01) showed that is a silent-failure machine: prompt_id()
# always returns a 64-hex digest — it never signals "could not read" — so a
# torn frame, a tmux resize rewrapping a long `Command:` row, a scroll, or one
# unrelated line entering the scraped region all produce a different hash for
# the SAME pending question. The timer would then exit quietly, and no further
# hook fires for that prompt (omp's tool_call is once per tool call, Claude's
# Notification once per prompt). That is permanent silence for a prompt nobody
# answered — the precise outcome this whole mechanism promises cannot happen,
# and the same anti-pattern push-wake.sh's worker-birth check already forbids:
# refuse on a POSITIVE mismatch, never on an unreadable sample.
#
# So: prompt gone -> silence is correct, it was answered. Prompt present ->
# alert, whatever its fingerprint. A changed fingerprint means the operator
# hears about a prompt whose text moved on, which is a worse description and a
# better outcome than hearing nothing. The id is carried into the event for
# forensics only.

# Sanitize the grace window. Split out so it can be asserted directly instead of
# by waiting out a timer — a test that has to sleep 90s to check a clamp does
# not get written, and then the clamp is untested.
_ag_grace_seconds() {                   # [raw] -> integer seconds
  local g="${1:-${HERDR_ALERT_GRACE_S:-90}}"
  case "$g" in
    ''|*[!0-9]*) printf '90\n'; return ;;   # non-numeric: the default, not an error
  esac
  [ "$g" -gt 900 ] && { printf '900\n'; return ; }   # unbounded silence is not a setting
  [ "$g" -lt 1 ] && { printf '1\n'; return ; }
  printf '%s\n' "$g"
}

grace_realert() {
  local pane="$1" pid="$2" run="$3" task="$4"; shift 4
  local grace; grace="$(_ag_grace_seconds)"
  (
    sleep "$grace"
    prompt_menu_visible "$pane" 2>/dev/null || [ -n "$(prompt_options "$pane" 2>/dev/null)" ] || exit 0
    local now_pid rc=0
    now_pid="$(prompt_id "$pane" 2>/dev/null || printf '')"
    "$@" >/dev/null 2>&1 || rc=$?
    # Recorded AFTER the send, carrying its real outcome. Written before, it
    # claimed a delivery that had not happened yet (HERDR-AG-03), which is the
    # same lie push_wake's three-record contract exists to prevent.
    if [ -n "$run" ] && [ -n "$task" ]; then
      append_event "$run" "$task" "alert_grace_expired" \
        "$(jq -nc --arg p "$pane" --arg pid "$pid" --arg now "$now_pid" --arg g "$grace" --argjson rc "$rc" \
           '{pane:$p, prompt_id_at_hold:$pid, prompt_id_now:$now, grace_seconds:$g, delivery_exit:$rc,
             fingerprint_changed:($pid != "" and $now != $pid),
             reason:"held prompt still unanswered after the grace window"}')" \
        >/dev/null 2>&1 || true
    fi
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
