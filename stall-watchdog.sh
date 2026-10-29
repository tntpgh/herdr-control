#!/usr/bin/env bash
# stall-watchdog.sh — wake the owner of a task whose pane has gone idle or
# finished while it still owes the conductor an action, with a bounded
# second-window escalation to a REAL human-visible alert when the owner is
# unknown, dead, or does not act.
#
# .handoffs/SPEC.md (feat/stall-watchdog): three real incidents, 8-14h each
# (2026-10-02/03), where a finished/idle worker's pane carried a signal — a
# handoff to the conductor, a ready artifact, a denied prompt, an unprocessed
# message — that nothing ever surfaced past a hub page-count nobody reads as
# an alert ("The hub showed 'N task(s) need attention' the whole time, and
# nobody acted on it. A count on a page is not a wake-up.").
#
# hub.py's _stall_watchdog_tick() decides WHICH (task, signal) pairs qualify
# — stall_watchdog_candidates() reuses CACHES["herdr"] (herdr_data() already
# derives idle/done via derive()) plus its own small supplemental queries for
# the two signals that state alone cannot see — and calls this once per
# qualifying pair. Same split of responsibility as project-wake.sh ("hub.py
# decides WHAT, bash decides HOW", carried over from attention-tick.sh
# itself): this script owns dedupe, conductor-pane resolution + birth guard,
# delivery, the second-window escalation ladder, and the one acknowledgement
# check that stops repeats.
#
#   stall-watchdog.sh wake <task_id> <signal> <fingerprint> <detail> [artifact_path]
#   stall-watchdog.sh ack <task_id> [signal]      # identical to stall-ack.sh
#
# Exit 0 always (a detection pass must not die on one bad row); failures are
# recorded as events, never thrown.
#
# ---- dedupe / re-arm --------------------------------------------------------
# key = stall_<task_id>_<signal>_<sha of fingerprint>. claim_once makes the
# FIRST sighting of a given fingerprint the only chance this gets to wake —
# the same one-shot-per-key shape attn_track_claim (lib/attention-key.sh)
# uses for a live prompt, applied to a different kind of key because a
# prompt-command-text key does not fit a terminal task or a file mtime:
# SPEC's own "reuse lib/attention-key.sh dedup if it fits" leaves this one
# not fitting that specific formula — what IS reused is the underlying
# primitive, claim_once, the same one attn_track_claim itself is built on.
#
# A later call for the SAME fingerprint finds the slot already claimed. That
# is not a no-op: it checks whether the wake was acknowledged (stall-ack.sh,
# a stall_acked event newer than the wake's own claim) — acknowledged means
# stop, satisfying "one wake per task per signal ... An acknowledged wake
# stops repeating". Not acknowledged and elapsed since the wake is past
# HERDR_STALL_WATCHDOG_ESCALATE_S (default 2x the detect threshold):
# escalate exactly once (a SECOND claim_once, `${key}_escalate`) — the same
# two-rung shape attention-tick.sh's own _attn_maybe_escalate uses (the
# owner's window, then a real alert).
#
# A fingerprint that CHANGES (a rewritten artifact, a fresh denial, a new
# handoff) re-arms on its own: it is simply a different claim_once key, so
# the whole ladder runs again for it independent of any earlier occurrence.
#
# ---- owner unknown or dead --------------------------------------------------
# No conductor_pane_id recorded, or the pane is no longer a live agent, or
# its registered birth disagrees with the live one (pane recycled):
# escalates on the SAME call, no owner window — there is no owner to wait
# on. Still claim_once-guarded so a repeat detection of the identical
# fingerprint does not re-escalate every tick.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "$here/config.sh" 2>/dev/null || true
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"
. "$here/lib/alert-gate.sh"       # alert_claim — the escalation post-dedupe
. "$here/lib/escalation.sh"       # feat/no-progress-model-escalation R2:
                                   # same resident watchdog feeds the
                                   # stronger-model detector every real
                                   # cycle — no second daemon.

SW_SEND="${HERDR_STALL_WATCHDOG_SEND:-$here/send-to-agent.sh}"
SW_NOTIFY="${HERDR_STALL_WATCHDOG_NOTIFY:-$here/slack-bridge/herdr-notify.sh}"

_sw_digest() {                          # <text> -> short stable digest
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-16
  elif command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 | cut -c1-16
  else
    printf '%s' "$1" | cksum | tr -d ' \t'
  fi
}

# ---- completion harvest / successor queue (docs/design/completion- -------
# harvest-dispatch.md) ---------------------------------------------------
# `signal` in {artifact, handoff} is the one shape that actually means "a
# worker finished something" (denied/unprocessed/conductor_prompt are not).
# For those two signals only:
#   1. `_sw_record_receipt`, called ONCE early in cmd_wake, unconditional
#      (independent of whether an owner is even reachable to wake) —
#      records a durable completion receipt, deduped by task + the
#      artifact's own content sha (lib/run-registry.sh's
#      record_completion_receipt).
#   2. `_sw_successor_note`, called at EACH actual send site (both already
#      gated on a live, identity-matched conductor pane — never computed,
#      let alone claimed, for an unreachable/dead owner, so a successor is
#      never silently burned on a wake nobody received) — if the task's
#      lane has a pre-planned successor and is not held, checks WHO (if
#      anyone) already holds the dispatch claim for that exact lane +
#      successor-content pair (dispatch_successor_owner): empty -> tries
#      to WIN it (dispatch_successor_once, "one writer per scope", the
#      scope being the lane); already ours (e.g. an earlier attempt for
#      this SAME wake failed to deliver and this is the M3 retry) ->
#      re-asserts it, no new write; someone else's -> silent. Either way
#      the note is folded in iff we own the claim — review REVIEW-HARVEST-
#      6a20224 HIGH: the claim is WHO gets to announce the successor,
#      decided once, but whether THIS delivery attempt's message includes
#      the note is re-derived from that fact every call, so a failed send
#      (nothing delivered, nothing typed) never silently drops the note on
#      its own retry — it just keeps riding along with the base wake's
#      message, same as everything else in it, until delivery confirms or
#      the base wake's own N4 typed-gate stops retrying. A duplicate
#      harvest of the same completion by a DIFFERENT task racing the same
#      lane still gets exactly one winner and omits the note on the loser
#      — exactly one dispatch per successor, never a repeated hand-off
#      across two different owners. Never a new send, never a spawn,
#      never new authority: the successor is a string folded into the
#      EXISTING wake to the EXISTING owner, nothing more. A task with no
#      assigned lane, no queued successor, or a successor someone else
#      already owns the dispatch for degrades to exactly today's bare
#      wake text.
_sw_artifact_sha() {                    # worktree relpath -> sha256 or empty
  local path="$1/$2"
  [ -f "$path" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
  fi
}
_sw_record_receipt() {                  # task_id signal artifact worktree
  local task_id="$1" signal="$2" artifact="$3" worktree="$4" sha
  case "$signal" in
    artifact|handoff) ;;
    *) return 0 ;;
  esac
  if [ -n "$artifact" ] && [ -n "$worktree" ]; then
    sha="$(_sw_artifact_sha "$worktree" "$artifact")"
    [ -n "$sha" ] && record_completion_receipt "$task_id" "$artifact" "$sha" >/dev/null 2>&1
  fi
}
# Review REVIEW-HARVEST-6a20224 HIGH: the dispatch claim is the RIGHT to
# announce a successor, decided once -- but whether THIS attempt's
# message includes the note is re-derived from that permanent fact on
# EVERY call, so a failed send's retry (same task, same key, called
# again by cmd_wake's own M3 retry loop) still carries the note instead
# of silently losing it. Owner-empty: try to win the claim. Owner==us
# (we already won it, possibly on an earlier failed attempt for this
# same wake): re-assert, no new write. Owner==someone else: silent, no
# write attempted -- this is what keeps two tasks racing the same lane's
# successor to exactly one dispatch and prevents a retry from ever
# claiming twice (successor_dispatch_count stays at 1 regardless of how
# many times this function is called for the winning task).
_sw_successor_note() {                  # task_id signal conductor -> prints "Pre-planned next: ..." or nothing
  local task_id="$1" signal="$2" conductor="$3" lane succ owner
  case "$signal" in
    artifact|handoff) ;;
    *) return 0 ;;
  esac
  lane="$(read_lane_for_task "$task_id" 2>/dev/null)" || return 0
  succ="$(lane_successor_admits "$lane" 2>/dev/null)" || return 0
  [ -n "$succ" ] || return 0
  owner="$(dispatch_successor_owner "$lane" "$succ" 2>/dev/null)"
  if [ -z "$owner" ]; then
    dispatch_successor_once "$lane" "$succ" "$task_id" "$conductor" >/dev/null 2>&1
    owner="$(dispatch_successor_owner "$lane" "$succ" 2>/dev/null)"
  fi
  [ "$owner" = "$task_id" ] && printf 'Pre-planned next (lane %s): %s' "$lane" "$succ"
}

_sw_escalate_window_s() {
  local raw="${HERDR_STALL_WATCHDOG_ESCALATE_S:-}" thresh="${HERDR_STALL_WATCHDOG_THRESHOLD_S:-600}"
  case "$thresh" in ''|*[!0-9]*) thresh=600 ;; esac
  case "$raw" in
    '') printf '%s\n' "$(( thresh * 2 ))" ;;
    *[!0-9]*) printf '%s\n' "$(( thresh * 2 ))" ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

_sw_epoch() {                           # ISO8601 UTC -> epoch seconds, or empty
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

# The occurred_at of a claimed event, as epoch seconds — "when did WE first
# wake for this fingerprint", the clock the escalation window measures from.
_sw_claimed_at_epoch() {                # event_id -> epoch, or empty
  local iso
  iso="$(_sql "SELECT occurred_at FROM events WHERE event_id=$(_sq "$1") LIMIT 1;" 2>/dev/null)"
  [ -n "$iso" ] && _sw_epoch "$iso"
}

# Acknowledged = a stall_acked event for this task, scoped to this signal or
# to "all" (stall-ack.sh with no signal argument acks every open stall for
# the task), timestamped AFTER the wake's own claim. ISO8601 from _now_iso is
# fixed-width and lexically sortable, so a plain string compare is correct —
# the same precedent grace_realert's own `occurred_at > $(_sq "$hold_at")`
# uses without wrapping either side in datetime().
_sw_acked_since() {                     # task_id signal since_iso -> 0 if acked
  local n
  n="$(_sql "SELECT count(*) FROM events WHERE task_id=$(_sq "$1") AND type='stall_acked'
        AND (json_extract(payload,'\$.signal')=$(_sq "$2") OR json_extract(payload,'\$.signal')='all')
        AND occurred_at > $(_sq "$3");" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
}

# Owner-side ACTIVITY (review H2): most real handling is never routed
# through stall-ack.sh at all — a conductor just messages the worker
# (owner_acted/brief_delivered/reply_delivered) or reviews an approval
# (approval_reviewed). ANY of those after the wake's own claim counts the
# same as an explicit ack; otherwise every wake the conductor handles the
# NORMAL way still escalates to Slack 2x the threshold later regardless.
_sw_owner_acted_since() {               # task_id since_iso -> 0 if owner activity happened after
  local n
  n="$(_sql "SELECT count(*) FROM events WHERE task_id=$(_sq "$1")
        AND type IN ('owner_acted','brief_delivered','reply_delivered','approval_reviewed')
        AND occurred_at > $(_sq "$2");" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
}

# Delivery CONFIRMATION (review M3): claim_once only ever meant "we decided
# to wake for this fingerprint", not "the conductor received it" —
# send-to-agent.sh can refuse a live prompt (exit 5/6) or report
# UNSUBMITTED (exit 4), and the first cut here never retried; the only
# fallback was a Slack alert a full escalate-window later. A confirmed
# delivery is a stall_wake_result for this exact key with exit_code 0 —
# append-only per attempt, same precedent as lib/push-wake.sh's own
# wake_attempted/wake_result rows, so a retry's outcome is a new fact.
_sw_wake_confirmed() {                  # task_id key -> 0 if delivered (rc=0) at least once
  local n
  n="$(_sql "SELECT count(*) FROM events WHERE task_id=$(_sq "$1") AND type='stall_wake_result'
        AND json_extract(payload,'\$.key')=$(_sq "$2") AND json_extract(payload,'\$.exit_code')=0;" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
}

# Review N4: `claim_once`'s 2x-threshold Slack escalation window retries
# every tick while a wake sits unconfirmed — but `send-to-agent.sh` exit 4
# (UNSUBMITTED) and the mid-submit exit 5 ("the text was delivered but NOT
# submitted") both mean text ALREADY SAT in the composer; retrying typed a
# fresh copy on top of it every 15s, up to 2*threshold/15 times (live:
# `wake_result unsubmitted exit 4` into w4P:pE at seq 112937 and 116174).
# `_sw_send_and_record` below records whether THIS attempt typed anything
# (rc=4, or any REFUSED/UNCONFIRMED message containing "delivered" — the
# two pre-type refusals never say that) so a later tick can tell "nothing
# landed yet, safe to retry" from "something is already sitting there,
# stop typing and let it ride to the window's own Slack fallback instead".
_sw_wake_typed() {                      # task_id key -> 0 if an attempt already typed text
  local n
  n="$(_sql "SELECT count(*) FROM events WHERE task_id=$(_sq "$1") AND type='stall_wake_result'
        AND json_extract(payload,'\$.key')=$(_sq "$2") AND json_extract(payload,'\$.typed')=1;" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ]
}

# One send attempt, recorded append-only with whether it CONFIRMED
# (exit_code) and whether it TYPED anything regardless (typed) — shared by
# the first-sighting send and the M3 retry so both feed the same facts
# `_sw_wake_confirmed`/`_sw_wake_typed` read back.
_sw_send_and_record() {                 # run_id task_id key signal conductor msg
  local run_id="$1" task_id="$2" key="$3" signal="$4" conductor="$5" msg="$6"
  local rc=0 out typed=0
  out="$(bash "$SW_SEND" "$conductor" --not-an-answer "$msg" 2>&1)" || rc=$?
  if [ "$rc" = 4 ] || printf '%s' "$out" | grep -qi 'delivered'; then
    typed=1
  fi
  append_event "$run_id" "$task_id" stall_wake_result \
    "$(jq -nc --arg k "$key" --arg s "$signal" --argjson rc "$rc" --argjson typed "$typed" \
       '{key:$k, signal:$s, exit_code:$rc, typed:$typed}')" \
    >/dev/null 2>&1 || true
}

# Owner liveness, with the distinction review H3 asks for: "herdr itself is
# unreachable right now" (echoes `unreachable`, skip this tick entirely —
# try again next tick, no claim spent, no escalation) is NOT the same fact
# as "this specific conductor pane is gone or not running an agent"
# (`dead`, the real escalate-now case). `herdr pane list` succeeding (even
# with zero panes) proves the daemon itself answered, so a SEPARATE
# `pane_is_agent` failure immediately after that can only mean "no agent in
# THIS pane", never "herdr is down" — the ambiguity pane_is_agent's own
# single nonzero return code cannot resolve by itself (lib/pane-guard.sh:43).
_sw_owner_status() {                    # conductor_pane conductor_birth -> ok|dead|unreachable
  local conductor="$1" cond_birth="$2"
  if [ -z "$conductor" ]; then
    printf 'dead\n'; return
  fi
  local list_json
  if ! list_json="$(herdr pane list 2>/dev/null)"; then
    printf 'unreachable\n'; return
  fi
  local live_birth
  live_birth="$(printf '%s' "$list_json" | jq -r --arg p "$conductor" \
    '(.result.panes // .panes)[]? | select(.pane_id==$p) | .terminal_id // empty' 2>/dev/null)"
  if [ -z "$live_birth" ]; then
    printf 'dead\n'; return                        # pane genuinely gone
  fi
  if [ -n "$cond_birth" ] && [ "$live_birth" != "$cond_birth" ]; then
    printf 'dead\n'; return                        # recycled
  fi
  if ! pane_is_agent "$conductor" 2>/dev/null; then
    printf 'dead\n'; return                        # herdr IS up; this pane just isn't an agent
  fi
  printf 'ok\n'
}

# alert_claim's event_id length budget: keep the dedupe key short (SQLite
# TEXT has no hard limit, but a stable short id is easier to grep in the
# registry and matches _ag_claim_id's own 'slack_alert_<pane>_<key>' shape).
_sw_escalate() {                        # task_id run_id signal label pane conductor detail artifact reason digest
  local task_id="$1" run_id="$2" signal="$3" label="$4" pane="$5" conductor="$6" detail="$7" artifact="$8" reason="$9" digest="${10:-}"
  local alert_pane="${conductor:-_none}" key="${signal}_${task_id}_${digest}"
  alert_claim "$alert_pane" "$key" || return 0   # already posted for this (task,signal) within the TTL
  local art_note=""
  [ -n "$artifact" ] && art_note=" ($artifact)"
  local msg="[STALL-WATCHDOG] ${label} (${task_id}) pane ${pane:-<none>}: ${signal}${art_note} — ${detail}. ${reason}. Nothing answers prompts or acts on the worker's behalf here — a human looks. Ack once handled: $here/stall-ack.sh ${task_id} ${signal}"
  local rc=0
  if [ -n "$conductor" ]; then
    bash "$SW_NOTIFY" --pane "$conductor" --class stall-watchdog "$msg" >/dev/null 2>&1 || rc=$?
  else
    bash "$SW_NOTIFY" --class stall-watchdog "$msg" >/dev/null 2>&1 || rc=$?
  fi
  append_event "$run_id" "$task_id" stall_escalated \
    "$(jq -nc --arg s "$signal" --arg r "$reason" --argjson rc "$rc" \
       '{signal:$s, reason:$r, notify_exit:$rc}')" >/dev/null 2>&1 || true
}

# _sw_escalation_tick <run_id> <task_id> <signal> <fingerprint> <detail> —
# feed one real watchdog cycle into lib/escalation.sh's detector. Called
# unconditionally from cmd_wake's first sighting of EVERY candidate hub.py
# hands it (hub dispatches a wake every tick the task is still an
# unresolved candidate — see hub.py's _stall_watchdog_tick — so a task that
# stays stalled produces one tick per real cycle here, not a synthetic
# poll). `commit_sha` is the task worktree's actual HEAD; `artifact_fp` is
# a digest of hub's own progress fingerprint for this signal (already
# computed upstream, reused rather than re-derived).
#
# R3 (root audit of 7bb9fba): a `denied` signal is a tool/approval-policy
# denial, not a tool EXECUTION failure — it is fed as `denial_sig`, kept
# OUT of `tool_fail_sig`, so a repeated denial can never by itself drive a
# loop verdict (escalating on a denial alone would look like routing
# around it with a stronger model; lib/escalation.sh's
# esc_carry_forward_denials is the explicit "stays held" path instead).
# `tool_fail_sig` is reserved for a genuine repeated tool EXECUTION
# failure signature, which this resident wiring does not currently have a
# source for (no stall-watchdog signal reports one) — left empty here on
# purpose rather than fed from signal=denied.
#
# waiting_on_human is set here for the one signal stall-watchdog itself
# names for it (`conductor_prompt`); no_progress_tick ALSO ORs in
# esc_task_awaiting_human's registry-grounded check unconditionally, so a
# task blocked on an `input_required` prompt is excluded regardless of
# which signal happened to trigger this particular wake (R3: the
# conductor_prompt-only exclusion alone was too narrow).
#
# Never lets a detector failure break the real stall-wake path below it.
_sw_escalation_tick() {
  [ "${HERDR_ESCALATION_ENABLED:-1}" = 1 ] || return 0
  local run_id="$1" task_id="$2" signal="$3" fingerprint="$4" detail="$5"
  local task_json worktree commit_sha="" artifact_fp tool_fail_sig="" denial_sig="" waiting_on_human=0
  task_json="$(read_task "$run_id" "$task_id" 2>/dev/null)" || return 0
  worktree="$(printf '%s' "$task_json" | jq -r '.worktree // empty' 2>/dev/null)"
  [ -n "$worktree" ] && [ -d "$worktree/.git" ] && commit_sha="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)"
  artifact_fp="$(_sw_digest "$fingerprint")"
  [ "$signal" = denied ] && denial_sig="$(_sw_digest "$detail")"
  [ "$signal" = conductor_prompt ] && waiting_on_human=1
  no_progress_tick "$run_id" "$task_id" "$commit_sha" "$artifact_fp" "$tool_fail_sig" "$waiting_on_human" "$denial_sig" >/dev/null 2>&1 || return 0
  local verdict loop reason evidence
  verdict="$(no_progress_detect "$run_id" "$task_id" 2>/dev/null)" || return 0
  loop="$(printf '%s' "$verdict" | jq -r '.loop' 2>/dev/null)"
  [ "$loop" = true ] || return 0
  reason="$(printf '%s' "$verdict" | jq -r '.reason' 2>/dev/null)"
  evidence="$(printf '%s' "$verdict" | jq -c '{cycles:.cycles, window:.window}' 2>/dev/null)"
  esc_escalate "$run_id" "$task_id" "${HERDR_ESCALATION_AGENT:-claude}" "$reason" "${evidence:-{\}}" \
    "${HERDR_ESCALATION_DRY_RUN:-0}" "$here/.handoffs/escalations" >/dev/null 2>&1
}

cmd_wake() {
  local task_id="${1:?usage: stall-watchdog.sh wake <task_id> <signal> <fingerprint> <detail> [artifact]}"
  local signal="${2:?signal required}"
  local fingerprint="${3:-}"
  local detail="${4:-}"
  local artifact="${5:-}"
  registry_init || return 0

  local task_json
  task_json="$(_sql "$(_task_json_select) WHERE task_id=$(_sq "$task_id");" 2>/dev/null)"
  [ -n "$task_json" ] || return 0   # task vanished between detection and delivery — nothing to wake

  local run_id pane conductor conductor_birth label worktree
  run_id="$(printf '%s' "$task_json" | jq -r '.run_id // empty')"
  pane="$(printf '%s' "$task_json" | jq -r '.pane_id // empty')"
  conductor="$(printf '%s' "$task_json" | jq -r '.conductor_pane_id // empty')"
  conductor_birth="$(printf '%s' "$task_json" | jq -r '.conductor_pane_birth // empty')"
  label="$(printf '%s' "$task_json" | jq -r '.label // empty')"
  worktree="$(printf '%s' "$task_json" | jq -r '.worktree // empty')"
  [ -n "$label" ] || label="$task_id"
  _sw_record_receipt "$task_id" "$signal" "$artifact" "$worktree"

  # feat/no-progress-model-escalation R2: every real cycle hub hands this
  # task to us, regardless of whether the stall-WAKE itself is deduped
  # below — the escalation window needs one tick per cycle, not one per
  # distinct fingerprint.
  _sw_escalation_tick "$run_id" "$task_id" "$signal" "$fingerprint" "$detail"
  local digest key payload
  digest="$(_sw_digest "$fingerprint")"
  key="stall_${task_id}_${signal}_${digest}"
  payload="$(jq -nc --arg s "$signal" --arg f "$fingerprint" --arg d "$detail" --arg a "$artifact" \
             --arg p "$pane" --arg c "$conductor" \
             '{signal:$s, fingerprint:$f, detail:$d, artifact:$a, pane:$p, conductor:$c}')"

  # Review H3: check an EXISTING claim, its ack, and any owner-side activity
  # BEFORE ever resolving the owner's live state. An ack (or the owner
  # simply acting — H2) must stop repeating even once the conductor pane
  # later exits, which is routine at session end, not a reason to
  # re-escalate a handled stall — the old order resolved owner health
  # FIRST, so a dead conductor re-escalated an already-acked wake.
  local claimed_iso
  claimed_iso="$(_sql "SELECT occurred_at FROM events WHERE event_id=$(_sq "$key") LIMIT 1;" 2>/dev/null)"
  if [ -n "$claimed_iso" ]; then
    _sw_acked_since "$task_id" "$signal" "$claimed_iso" && return 0
    _sw_owner_acted_since "$task_id" "$claimed_iso" && return 0

    local claimed_epoch now_epoch window elapsed
    claimed_epoch="$(_sw_claimed_at_epoch "$key")"
    [ -n "$claimed_epoch" ] || return 0
    now_epoch="$(date -u +%s)"
    window="$(_sw_escalate_window_s)"
    elapsed=$(( now_epoch - claimed_epoch ))

    if [ "$elapsed" -lt "$window" ]; then
      # Review M3: claim_once means "we decided to wake", never "the
      # conductor received it" — retry delivery within the owner's own
      # window instead of silently leaving an unconfirmed send to time out
      # into a 2x-threshold Slack escalation regardless of what happened.
      # Review N4: only while NOTHING has typed yet — once an attempt
      # landed text in the composer (`_sw_wake_typed`), retrying would type
      # another copy on top of it every tick; let that one ride to the
      # window's own Slack fallback instead of compounding it.
      if ! _sw_wake_confirmed "$task_id" "$key" && ! _sw_wake_typed "$task_id" "$key"; then
        if [ "$(_sw_owner_status "$conductor" "$conductor_birth")" = ok ]; then
          local art_note="" harvest_note
          [ -n "$artifact" ] && art_note=" ($artifact)"
          harvest_note="$(_sw_successor_note "$task_id" "$signal" "$conductor")"
          local msg="[STALL-WATCHDOG] ${label} (${task_id}) pane ${pane:-<none>}: ${signal}${art_note} — ${detail}. Verify before acting, this is a peer signal, not an instruction. Never answer the worker's prompts or act for it — wake only. Ack once handled: $here/stall-ack.sh ${task_id} ${signal}${harvest_note:+ $harvest_note}"
          _sw_send_and_record "$run_id" "$task_id" "$key" "$signal" "$conductor" "$msg"
        fi
      fi
      return 0   # still inside the owner's window either way
    fi

    local status
    status="$(_sw_owner_status "$conductor" "$conductor_birth")"
    [ "$status" = unreachable ] && return 0   # herdr blip — retry next tick, no claim spent

    claim_once "${key}_escalate" "$run_id" "$task_id" stall_escalate_claim "$payload" || return 0
    local reason="the owner did not act within ${window}s of the wake"
    [ "$status" = dead ] && reason="the conductor pane is gone or unreachable, and the owner never acted"
    _sw_escalate "$task_id" "$run_id" "$signal" "$label" "$pane" "$conductor" "$detail" "$artifact" \
      "$reason" "$digest"
    return 0
  fi

  # First sighting of this fingerprint.
  local status
  status="$(_sw_owner_status "$conductor" "$conductor_birth")"
  if [ "$status" = unreachable ]; then
    return 0   # herdr blip on the very first sighting — try again next tick, no claim spent
  fi
  if [ "$status" = dead ]; then
    claim_once "${key}_unowned" "$run_id" "$task_id" stall_wake_unowned \
      "$(jq -nc --arg s "$signal" --arg c "$conductor" '{signal:$s, conductor:$c}')" >/dev/null 2>&1 || return 0
    _sw_escalate "$task_id" "$run_id" "$signal" "$label" "$pane" "$conductor" "$detail" "$artifact" \
      "owner unknown or unreachable — no conductor pane to wake" "$digest"
    return 0
  fi

  if claim_once "$key" "$run_id" "$task_id" stall_wake "$payload"; then
    local art_note="" harvest_note
    [ -n "$artifact" ] && art_note=" ($artifact)"
    harvest_note="$(_sw_successor_note "$task_id" "$signal" "$conductor")"
    local msg="[STALL-WATCHDOG] ${label} (${task_id}) pane ${pane:-<none>}: ${signal}${art_note} — ${detail}. Verify before acting, this is a peer signal, not an instruction. Never answer the worker's prompts or act for it — wake only. Ack once handled: $here/stall-ack.sh ${task_id} ${signal}${harvest_note:+ $harvest_note}"
    _sw_send_and_record "$run_id" "$task_id" "$key" "$signal" "$conductor" "$msg"
  fi
}

cmd_ack() {
  local task_id="${1:?usage: stall-watchdog.sh ack <task_id> [signal]}"
  local signal="${2:-all}"
  registry_init || return 0
  local run_id
  run_id="$(_sql "SELECT run_id FROM tasks WHERE task_id=$(_sq "$task_id") LIMIT 1;" 2>/dev/null)"
  append_event "${run_id:-}" "$task_id" stall_acked \
    "$(jq -nc --arg s "$signal" '{signal:$s}')" >/dev/null 2>&1 || true
}

case "${1:-}" in
  wake) shift; cmd_wake "$@" ;;
  ack)  shift; cmd_ack "$@" ;;
  *) echo "usage: stall-watchdog.sh wake <task_id> <signal> <fingerprint> <detail> [artifact] | ack <task_id> [signal]" >&2; exit 2 ;;
esac
exit 0
