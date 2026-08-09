#!/usr/bin/env bash
# verify-reconcile.sh — proves lib/reconcile.sh's lost-detection classifier
# against the 2026-08-09 incident: a herdr crash+restart reissues terminal_id
# for every pane it re-enumerates on reconnect, while the agent processes
# underneath never die. Three unrelated tasks across three repos all flipped
# pane_birth mismatch within the same second and were permanently, silently
# marked 'lost' — a terminal, non-resurrectable state by design — even though
# every one of them kept working afterward. This is the regression test for
# the fix: corroborate via agent_session before declaring loss, and treat a
# mass-simultaneous mismatch with no corroboration as identity-uncertain
# (neither buried nor silently resurrected) rather than N independent deaths.
#
# Runs entirely against a throwaway HERDR_RUN_STATE_DIR, with a STUBBED herdr
# (function, not a PATH stub — reconcile.sh does not re-export PATH, so
# bash's function-before-PATH resolution applies cleanly here, same
# reasoning as verify-select-policy.sh's stub).
#
#   bash verify-reconcile.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
export HERDR_RUN_STATE_DIR="$(mktemp -d)/runs"
trap 'rm -rf "$(dirname "$HERDR_RUN_STATE_DIR")"' EXIT

. "$here/lib/run-registry.sh"
. "$here/lib/reconcile.sh"

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# _PANES is a newline-separated "pane_id<TAB>terminal_id<TAB>agent_session" list
# the stub serves as the live `herdr pane list` snapshot for one reconciliation
# call — set it fresh before each scenario.
_PANES=""
herdr() {
  case "$1 $2" in
    "pane list")
      local panes="[]" line pid tid sess
      while IFS=$'\t' read -r pid tid sess; do
        [ -n "$pid" ] || continue
        panes=$(printf '%s' "$panes" | jq --arg p "$pid" --arg t "$tid" --arg s "$sess" \
          '. + [{pane_id:$p, terminal_id:$t, agent_session:(if $s=="" then null else {value:$s} end)}]')
      done <<PANEOF
$_PANES
PANEOF
      jq -nc --argjson panes "$panes" '{result:{panes:$panes}}'
      ;;
    *) return 1 ;;
  esac
}

printf '== isolated mismatch, no corroboration -> lost (existing behavior preserved) ==\n'
register_task runA taskA w c cp cb paneA birthA-old /repo/a /wt/a "isolated" || bad "register taskA failed"
set_task_state runA taskA running || bad "taskA -> running failed"
_PANES=$'paneA\tbirthA-new\t'
run_reconciliation condA SessionStart --quiet-if-empty --no-hook-json >/dev/null
check "isolated mismatch marked lost" "$(read_task runA taskA | jq -r .state)" "lost"
check "reason is pane_recycled" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.reason') FROM events WHERE task_id='taskA' AND type='lost_detected';")" \
  "pane_recycled"

printf '== pane_gone -> lost regardless of corroboration ==\n'
register_task runB taskB w c cp cb paneB birthB /repo/b /wt/b "gone" || bad "register taskB failed"
set_task_state runB taskB running || bad "taskB -> running failed"
_PANES=""    # paneB does not appear in the live list at all
run_reconciliation condB SessionStart --quiet-if-empty --no-hook-json >/dev/null
check "gone pane marked lost" "$(read_task runB taskB | jq -r .state)" "lost"
check "reason is pane_gone" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.reason') FROM events WHERE task_id='taskB' AND type='lost_detected';")" \
  "pane_gone"

printf '== mismatch corroborated by MATCHING agent_session -> rebaseline, NOT lost ==\n'
register_task runC taskC w c cp cb paneC birthC-old /repo/c /wt/c "corroborated" || bad "register taskC failed"
set_task_state runC taskC running || bad "taskC -> running failed"
set_task_agent_session runC taskC "sess-same"
_PANES=$'paneC\tbirthC-new\tsess-same'
run_reconciliation condC SessionStart --quiet-if-empty --no-hook-json >/dev/null
check "corroborated task stays running, not lost" "$(read_task runC taskC | jq -r .state)" "running"
check "pane_birth was rebaselined to the new fingerprint" "$(read_task runC taskC | jq -r .pane_birth)" "birthC-new"
check "pane_birth_rebaselined event logged" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='taskC' AND type='pane_birth_rebaselined';")" "1"
check "no lost_detected event for a corroborated rebaseline" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='taskC' AND type='lost_detected';")" "0"

printf '== mismatch with CONFLICTING agent_session -> genuinely lost, not resurrected ==\n'
register_task runD taskD w c cp cb paneD birthD-old /repo/d /wt/d "conflict" || bad "register taskD failed"
set_task_state runD taskD running || bad "taskD -> running failed"
set_task_agent_session runD taskD "sess-old-owner"
_PANES=$'paneD\tbirthD-new\tsess-new-owner'
run_reconciliation condD SessionStart --quiet-if-empty --no-hook-json >/dev/null
check "conflicting session -> genuinely lost" "$(read_task runD taskD | jq -r .state)" "lost"
check "reason is pane_recycled (a real replacement, not a restart artifact)" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.reason') FROM events WHERE task_id='taskD' AND type='lost_detected';")" \
  "pane_recycled"

printf '== MASS-simultaneous mismatch, no corroboration -> neither lost NOR resurrected ==\n'
# The actual 2026-08-09 incident shape: a herdr restart reissues terminal_id
# for every pane at once. None of these three has an agent_session recorded
# (omp, or a pre-fix legacy row) — exactly the case that used to bury all
# three permanently within the same second.
register_task runE taskE1 w c cp cb paneE1 birthE1-old /repo/e /wt/e1 "mass1" || bad "register taskE1 failed"
register_task runE taskE2 w c cp cb paneE2 birthE2-old /repo/e /wt/e2 "mass2" || bad "register taskE2 failed"
register_task runE taskE3 w c cp cb paneE3 birthE3-old /repo/e /wt/e3 "mass3" || bad "register taskE3 failed"
set_task_state runE taskE1 running || bad "taskE1 -> running failed"
set_task_state runE taskE2 running || bad "taskE2 -> running failed"
set_task_state runE taskE3 running || bad "taskE3 -> running failed"
_PANES=$'paneE1\tbirthE1-new\t\npaneE2\tbirthE2-new\t\npaneE3\tbirthE3-new\t'
run_reconciliation condE SessionStart --quiet-if-empty --no-hook-json >/dev/null
check "taskE1 NOT marked lost during a mass restart" "$(read_task runE taskE1 | jq -r .state)" "running"
check "taskE2 NOT marked lost during a mass restart" "$(read_task runE taskE2 | jq -r .state)" "running"
check "taskE3 NOT marked lost during a mass restart" "$(read_task runE taskE3 | jq -r .state)" "running"
check "taskE1 pane_birth left untouched (no corroboration to rebaseline on)" \
  "$(read_task runE taskE1 | jq -r .pane_birth)" "birthE1-old"
check "pane_identity_uncertain logged for taskE1" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='taskE1' AND type='pane_identity_uncertain';")" "1"
uncertain_n=$(sqlite3 "$(registry_db)" \
  "SELECT json_extract(payload,'\$.concurrent_uncertain_count') FROM events WHERE task_id='taskE1' AND type='pane_identity_uncertain';")
check "mismatch count recorded in the uncertain event" "$uncertain_n" "3"
check "no task from the mass event was marked lost" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE type='lost_detected' AND task_id IN ('taskE1','taskE2','taskE3');")" "0"

printf '== opportunistic backfill: no mismatch, empty agent_session, live one available ==\n'
register_task runF taskF w c cp cb paneF birthF /repo/f /wt/f "backfill" || bad "register taskF failed"
set_task_state runF taskF running || bad "taskF -> running failed"
check "starts with no recorded session" "$(read_task runF taskF | jq -r .agent_session)" ""
_PANES=$'paneF\tbirthF\tsess-backfilled'
run_reconciliation condF SessionStart --quiet-if-empty --no-hook-json >/dev/null
check "agent_session opportunistically backfilled" "$(read_task runF taskF | jq -r .agent_session)" "sess-backfilled"
check "state untouched by a backfill" "$(read_task runF taskF | jq -r .state)" "running"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
