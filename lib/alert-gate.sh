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
. "$_ag_dir/run-registry.sh"
. "$_ag_dir/pending-queue.sh"

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
    _pane_visible "$pane" | grep -q 'Allow tool:' && return 0
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

# ---- dedupe: at most ONE Slack post per prompt_id, ever --------------------
# .handoffs/SPEC.md "Slack gets symptoms only": a genuinely human-required
# prompt (escalate/reserved/deny) posts immediately, with no grace delay — so
# unlike the held/allow-class path above, nothing naturally stopped THREE
# Notification/tool_call firings for the SAME still-unanswered prompt from
# posting three separate Slack messages. Measured on this machine's own
# registry.jsonl: 192 of 364 posts in a 48h window were exact duplicates of an
# already-posted prompt_id (up to 19 posts for one prompt). Every caller —
# the immediate branch in claude-notify.sh/omp-notify.sh, a delayed
# grace_realert, and agent-edge.sh's backstop — funnels through
# slack-bridge/herdr-notify.sh, so ONE claim ledger there, keyed by
# prompt_id, catches all three without each caller having to coordinate.
#
# Backed by the SAME registry everything else here uses: INSERT OR IGNORE on
# a UNIQUE event_id is a real atomic claim, not a check-then-write race
# (lib/run-registry.sh's own reasoning for using SQLite over a JSONL spool).
# run_id/task_id are deliberately blank — this ledger is per PROMPT, not per
# task, so a claim survives being asked from a different call site than the
# one that eventually re-derives the same prompt_id.

# alert_claim <prompt_id> -> 0 if THIS call wins the right to post (first
# claim for this prompt_id), 1 if another call already claimed it (skip).
# Registry unavailable (no sqlite3, unwritable state dir) fails OPEN: the
# alert still posts, exactly like every other "could not tell" case in this
# file — a possible duplicate is recoverable, a dropped human-required alert
# is not.
alert_claim() {
  local pid="$1" changes lockdir
  [ -n "$pid" ] || return 0
  # Serialized, not left to SQLite's own UNIQUE constraint: two herdr-notify.sh
  # PROCESSES racing to claim the SAME prompt_id (three hook firings landing
  # close together, or the immediate alert and a wake-fail backstop firing
  # near-simultaneously) were measured to both fail OPEN — registry_init()
  # racing its own one-time CREATE TABLE/PRAGMA DDL against a second process
  # doing the same against a not-yet-existing database file returned a
  # transient error to one or both callers, and alert_claim's own
  # "can't tell, fail open" rule then let EVERY racer post. Reproduced
  # directly (repeatable within ~30 concurrent runs) once two separate bash
  # processes raced first-time registry_init rather than one process priming
  # the schema before the other started.
  #
  # registry_init lives INSIDE the lock, not just the insert: a lock that only
  # wrapped the INSERT would still let two processes race the schema creation
  # itself. mkdir -p is safe to call unlocked (it is idempotent/race-safe by
  # design, unlike a multi-statement CREATE TABLE + PRAGMA batch) — it only
  # has to exist before `mkdir "$lockdir"` can succeed.
  lockdir="$(run_state_root)/.alert-claim.lock"
  mkdir -p "$(run_state_root)" 2>/dev/null || return 0
  pending_lock "$lockdir" || true   # best-effort wait; never skip the claim
                                     # over an exhausted wait — proceed anyway
  if ! registry_init >/dev/null 2>&1; then
    pending_unlock "$lockdir"
    return 0
  fi
  changes="$(_sql "INSERT OR IGNORE INTO events (event_id, run_id, task_id, type, occurred_at, payload)
    VALUES ($(_sq "slack_alert_${pid}"), '', '', 'slack_alert_posted', $(_sq "$(_now_iso)"),
      $(_sq "{\"prompt_id\":\"${pid}\"}"));
    SELECT changes();" 2>/dev/null)"
  pending_unlock "$lockdir"
  [ "$changes" = "1" ]
}

# alert_already_posted <prompt_id> -> 0 (true) if a claim exists already.
# Read-only PEEK, never mutates — this is what --dry-run uses to report the
# same decision alert_claim would make without poisoning the real ledger with
# a test/preview run (a dry-run that CLAIMED would silently drop the real
# alert that follows it).
alert_already_posted() {
  local pid="$1" n
  [ -n "$pid" ] || return 1
  registry_init >/dev/null 2>&1 || return 1
  n="$(_sql "SELECT COUNT(*) FROM events WHERE event_id=$(_sq "slack_alert_${pid}");" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ] 2>/dev/null
}

# alert_release <prompt_id> -> undo a claim after the send it protected
# FAILED (e.g. a Slack API error). Without this, a curl/API failure would
# permanently "have posted" a prompt that never actually reached Slack,
# silently poisoning every later retry — a delayed grace_realert, the
# wake-fail backstop (lib/push-wake.sh), or a fresh hook firing — for that
# prompt's whole lifetime. Claim-before-send stays atomic (race-safe); this
# is the compensating action for the one path that legitimately did not send.
alert_release() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  registry_init >/dev/null 2>&1 || return 0
  _sql "DELETE FROM events WHERE event_id=$(_sq "slack_alert_${pid}");" >/dev/null 2>&1 || true
}
