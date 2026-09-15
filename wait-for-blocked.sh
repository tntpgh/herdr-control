#!/usr/bin/env bash
# wait-for-blocked.sh — block until any agent pane needs input, then report it.
#
# The orchestration gap this closes: herdr already reports `agent_status:
# blocked` when a session hits a permission prompt, but nothing PUSHES that to a
# conductor session. So a worker sits on "Do you want to proceed? 1/2/3" until
# the conductor happens to poll — which, run by hand, means minutes of a worker
# doing nothing and the operator noticing before the orchestrator does.
#
# Run under Bash run_in_background: the exit re-invokes the conductor with the
# blocked pane named, turning a poll into a wake.
#
#   wait-for-blocked.sh [poll_seconds] [max_polls] [pane_id ...]
#
# With pane ids, only those are watched (use for "my" workers so another
# session's prompt doesn't wake you). With none, watches every agent pane.
#
# Exit 0 = something is blocked (details on stdout). Exit 3 = timed out.
#
# ---- how it waits ----------------------------------------------------------
# PREFERRED: the hub's long-poll (`GET /api/blocked/wait`). The hub holds one
# `events.subscribe` connection to herdr (lib/herdr_live.py) and answers the
# instant an agent's status changes, so this process costs ZERO herdr RPCs
# while it waits. That matters because this script was the fleet's most
# expensive poller: at the old 15s tick it ran a `herdr pane list` plus a
# `pane process-info` and a 200-line `pane read` per candidate, forever, per
# conductor — and a conductor re-arms it after every hit (39 re-arms in one
# 2026-09-13 batch).
#
# FALLBACK: if the hub is not up or its subscription is down, the original
# polling loop runs unchanged. A control-plane optimisation must never be the
# reason a worker's prompt goes unnoticed.
#
# SCRAPE BACKSTOP: herdr's agent_status is push-reported by agents that ship an
# integration (omp reports it from its own tool_approval_requested), but for
# one that does not, herdr-gates.sh:19-25 records it being wrong in both
# directions. So in hub mode, every HERDR_WAIT_SCRAPE_EVERY-th idle timeout
# (default 4 ≈ every 2 minutes) also parses the panes the hub lists as agents
# but not blocked. That is the old safety net at 1/8th the RPCs, not none.
set -uo pipefail

interval="${1:-15}"; max="${2:-240}"; shift "$(( $# < 2 ? $# : 2 ))"
watch_list="$*"

command -v herdr >/dev/null 2>&1 || { echo "wait-for-blocked: herdr not on PATH" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"

HUB="${HERDR_HUB_URL:-http://127.0.0.1:${HERDR_HUB_PORT:-8600}/}"
SCRAPE_EVERY="${HERDR_WAIT_SCRAPE_EVERY:-4}"
deadline=$(( $(date +%s) + interval * max ))

in_watch() {                            # <pane_id>
  [ -z "$watch_list" ] && return 0
  case " $watch_list " in *" $1 "*) return 0 ;; esac
  return 1
}

# ---- reporting: the one place a hit costs pane reads, and it earns them -----
# A numbered prompt is answered with herdr-select.sh <pane> <n>, NOT by sending
# Enter — Enter accepts whatever option happens to be highlighted. When the
# prompt PARSES, emit the fingerprint and the parsed command rows: the
# fingerprint is what `herdr-select.sh --expect-prompt-id` needs to refuse a
# stale decision. When it does not parse, fall back to the raw tail — a pane
# herdr calls blocked but the parser cannot explain is exactly when the
# operator most needs to see raw screen.
report() {                              # lines of "pane<TAB>label<TAB>workspace"
  echo "BLOCKED — these panes are waiting on input:"
  while IFS=$'\t' read -r pane label ws; do
    [ -n "$pane" ] || continue
    echo "  $pane  (ws $ws, ${label})"
    if [ -n "$(prompt_menu_options "$pane" 2>/dev/null)" ] \
       || [ -n "$(prompt_options "$pane" 2>/dev/null)" ]; then
      printf '      prompt_id %s  selected %s\n' \
        "$(prompt_id "$pane" 2>/dev/null | cut -c1-8)" \
        "$(prompt_menu_selected "$pane" 2>/dev/null || echo '-')"
      prompt_command_text "$pane" 2>/dev/null \
        | tr ';' '\n' | sed -E 's/^ +//' | grep -vE '^$' \
        | head -4 | sed 's/^/      | /'
    else
      herdr pane read "$pane" 2>/dev/null | tail -12 | sed 's/^/      | /'
    fi
  done
}

# ---- hub mode ---------------------------------------------------------------
hub_live() {
  curl -s --max-time 3 "${HUB}api/blocked" 2>/dev/null \
    | jq -e '.connected == true' >/dev/null 2>&1
}

hub_hits() {                            # <json> -> "pane\tlabel\tworkspace" lines
  printf '%s' "$1" | jq -r '.blocked[]? | [.pane_id, (.label // "-"), (.workspace // "-")] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r pane label ws; do
        in_watch "$pane" && printf '%s\t%s\t%s\n' "$pane" "$label" "$ws"
      done
}

# Panes the hub says are agents but NOT blocked — the population where a
# missing integration could hide a painted menu.
scrape_backstop() {
  local panes pane label ws
  panes=$(curl -s --max-time 3 "${HUB}api/panes" 2>/dev/null \
    | jq -r '.panes[]? | select(.agent != null and .agent_status != "blocked")
             | [.pane_id, (.label // "-"), (.workspace // "-")] | @tsv' 2>/dev/null) || return 0
  printf '%s\n' "$panes" | while IFS=$'\t' read -r pane label ws; do
    [ -n "$pane" ] || continue
    in_watch "$pane" || continue
    pane_is_agent "$pane" 2>/dev/null || continue
    prompt_menu_visible "$pane" 2>/dev/null || continue
    printf '%s\t%s\t%s\n' "$pane" "$label" "$ws"
  done
}

wait_via_hub() {
  local version=0 idle=0 body hits now left
  while :; do
    now=$(date +%s); left=$(( deadline - now ))
    [ "$left" -gt 0 ] || return 3
    [ "$left" -gt 30 ] && left=30
    body=$(curl -s --max-time "$(( left + 5 ))" \
      "${HUB}api/blocked/wait?since=${version}&timeout=${left}" 2>/dev/null) || return 4
    printf '%s' "$body" | jq -e 'has("version")' >/dev/null 2>&1 || return 4
    printf '%s' "$body" | jq -e '.connected == true' >/dev/null 2>&1 || return 4
    version=$(printf '%s' "$body" | jq -r '.version')
    hits=$(hub_hits "$body")
    if [ -n "$hits" ]; then
      printf '%s\n' "$hits" | report
      return 0
    fi
    idle=$((idle + 1))
    if [ "$SCRAPE_EVERY" -gt 0 ] && [ $((idle % SCRAPE_EVERY)) -eq 0 ]; then
      hits=$(scrape_backstop)
      if [ -n "$hits" ]; then
        printf '%s\n' "$hits" | report
        return 0
      fi
    fi
  done
}

# ---- polling fallback (the original loop, unchanged in behaviour) -----------
wait_via_polling() {
  local i=0 candidates out
  while [ "$i" -lt "$max" ]; do
    candidates="$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
watch = set(sys.argv[1].split()) if len(sys.argv) > 1 and sys.argv[1].strip() else None
try:
    data = json.load(sys.stdin)
    panes = (data.get("result") or data).get("panes") or []
except Exception:
    sys.exit(1)                      # unreadable -> treat as "nothing yet", keep polling
hits = [p for p in panes
        if (p.get("agent_status") == "blocked" or p.get("agent"))
        and (watch is None or p.get("pane_id") in watch)]
for p in hits:
    print("\t".join(str(p.get(k) or "-") for k in ("pane_id", "label", "workspace_id", "agent_status")))
' "$watch_list" 2>/dev/null)"
    # omp can be labelled "working" with a real approval menu painted.
    # A missed push hook must not hide that stall from the polling backstop.
    out="$(while IFS=$'\t' read -r pane label ws status; do
      [ -n "$pane" ] || continue
      if [ "$status" = blocked ] || {
        pane_is_agent "$pane" && prompt_menu_visible "$pane"
      }; then
        printf '%s\t%s\t%s\n' "$pane" "$label" "$ws"
      fi
    done <<EOF
$candidates
EOF
)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | report
      return 0
    fi
    i=$((i + 1))
    sleep "$interval"
  done
  return 3
}

if [ "${HERDR_WAIT_MODE:-auto}" != "poll" ] && hub_live; then
  wait_via_hub; rc=$?
  case "$rc" in
    0) exit 0 ;;
    3) echo "wait-for-blocked: nothing blocked after $((max * interval))s"; exit 3 ;;
    *) echo "wait-for-blocked: hub subscription unavailable mid-wait, falling back to polling" >&2 ;;
  esac
fi

wait_via_polling && exit 0
echo "wait-for-blocked: nothing blocked after $((max * interval))s"
exit 3
