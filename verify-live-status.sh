#!/usr/bin/env bash
# verify-live-status.sh — status is DERIVED from herdr at read time, never
# trusted from the registry copy.
#
# Every case below is a thing that actually happened on 2026-09-12, not a
# hypothetical: a task stuck `blocked` while its pane was idle, a task stuck
# `running` after its PR merged, and a worker that abandoned a review brief
# and went idle — invisible, because idle and working look the same.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n     want=%s got=%s\n' "$1" "$2" "$3"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PATH="$TMP/bin:$PATH"; mkdir -p "$TMP/bin"

# A stub herdr whose pane list we control. This is the ground truth the real
# code must consult; if the code reads the registry instead, these tests cannot
# change its answer and they fail.
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "pane" ] && [ "${2:-}" = "list" ] && { cat "$HERDR_STUB_PANES"; exit 0; }
exit 1
STUB
chmod +x "$TMP/bin/herdr"
panes(){ printf '%s' "$1" >"$TMP/panes.json"; export HERDR_STUB_PANES="$TMP/panes.json"; }

wt_with_done(){ local d="$TMP/$1"; mkdir -p "$d/.handoffs"
  printf '{"event":"implement:x_done","commit":"abc"}\n' >"$d/.handoffs/events.jsonl"; printf '%s' "$d"; }
wt_silent(){ local d="$TMP/$1"; mkdir -p "$d/.handoffs"; : >"$d/.handoffs/events.jsonl"; printf '%s' "$d"; }

. lib/live-status.sh
reset_cache(){ _LS_SNAPSHOT=""; }
tj(){ printf '{"state":"%s","pane_id":"%s","worktree":"%s"}' "$1" "$2" "${3:-}"; }
state(){ reset_cache; derived_task_state "$(tj "$1" "$2" "${3:-}")" "${4:-}"; }

echo "== the registry copy never wins over live truth"
panes '{"panes":[{"pane_id":"wH:pA","agent":"omp","agent_status":"idle"}]}'
D="$(wt_with_done a)"
# OBSERVED: registry said `blocked` (a prompt answered by nobody), pane was idle.
is "stored blocked + pane idle + done event -> completed" \
   "completed" "$(state blocked "wH:pA" "$D")"
# OBSERVED: registry said `running` hours after the PR merged.
is "stored running + pane idle + done event -> completed" \
   "completed" "$(state running "wH:pA" "$D")"

echo "== idle with no completion evidence is STALLED, not done and not working"
S="$(wt_silent b)"
# OBSERVED: #313's worker took a five-item review brief and went idle without
# touching the branch. Nothing anywhere said so.
is "pane idle + no done event -> stalled" \
   "stalled" "$(state running "wH:pA" "$S")"
panes '{"panes":[{"pane_id":"wH:pA","agent":"omp","agent_status":"done"}]}'
is "pane done + no done event -> stalled" \
   "stalled" "$(state running "wH:pA" "$S")"

echo "== live working beats a stale stored state in both directions"
panes '{"panes":[{"pane_id":"wH:pA","agent":"omp","agent_status":"working"}]}'
is "pane working + stored blocked -> running" \
   "running" "$(state blocked "wH:pA" "$S")"
is "pane working + no done event -> running (not stalled)" \
   "running" "$(state running "wH:pA" "$S")"
panes '{"panes":[{"pane_id":"wH:pA","agent":"omp","agent_status":"blocked"}]}'
is "pane blocked + stored running -> blocked" \
   "blocked" "$(state running "wH:pA" "$S")"

echo "== terminal facts herdr cannot know are NOT overridden"
panes '{"panes":[{"pane_id":"wH:pA","agent":"omp","agent_status":"working"}]}'
for s in completed failed cancelled lost; do
  is "stored $s survives a live pane" "$s" \
     "$(state $s "wH:pA" "$S")"
done

echo "== a pane herdr has never heard of is gone, not idle"
panes '{"panes":[{"pane_id":"wH:pZ","agent":"omp","agent_status":"working"}]}'
is "unknown pane -> gone" "gone" \
   "$(state running "wH:pA" "$S")"
is "empty pane_id -> gone" "gone" \
   "$(state running "" "$S")"

echo "== herdr unreachable: fall back, never invent"
# The failure mode to avoid is a dead herdr silently marking the whole fleet
# stalled and paging a human about it.
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP/bin/herdr"
is "herdr down + stored running -> running" "running" \
   "$(state running "wH:pA" "$S")"
is "herdr down + stored blocked -> blocked" "blocked" \
   "$(state blocked "wH:pA" "$S")"

echo "== legacy .omc handoff bus still counts as evidence"
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "pane" ] && [ "${2:-}" = "list" ] && { cat "$HERDR_STUB_PANES"; exit 0; }
exit 1
STUB
chmod +x "$TMP/bin/herdr"
panes '{"panes":[{"pane_id":"wH:pA","agent":"omp","agent_status":"idle"}]}'
L="$TMP/legacy"; mkdir -p "$L/.omc/handoffs"
printf '{"event":"implement:x_done"}\n' >"$L/.omc/handoffs/events.jsonl"
is "legacy bus -> completed, not stalled" "completed" \
   "$(state running "wH:pA" "$L")"

echo "== the wrapped shape herdr actually returns"
panes '{"result":{"panes":[{"pane_id":"wH:pA","agent":"omp","agent_status":"working"}]}}'
is "result-wrapped pane list is read" "running" \
   "$(state blocked "wH:pA" "$S")"


echo "== every case in the shared truth table (status-cases.json)"
# Both implementations must satisfy this file. hub.py reads the same one in
# verify-hub-status.py; neither may carry a case the table does not.
n=0
while IFS=$'\t' read -r cname stored pane done want; do
  n=$((n+1))
  case "$pane" in
    null)     panes '{"panes":[{"pane_id":"wOTHER:p1","agent":"omp","agent_status":"working"}]}' ;;
    __down__) panes 'not json at all' ;;
    *)        panes "{\"panes\":[{\"pane_id\":\"wH:pA\",\"agent\":\"omp\",\"agent_status\":\"$pane\"}]}" ;;
  esac
  if [ "$pane" = "__down__" ]; then
    cat >"$TMP/bin/herdr" <<'DOWN'
#!/usr/bin/env bash
exit 1
DOWN
  else
    cat >"$TMP/bin/herdr" <<'UP'
#!/usr/bin/env bash
[ "${1:-}" = "pane" ] && [ "${2:-}" = "list" ] && { cat "$HERDR_STUB_PANES"; exit 0; }
exit 1
UP
  fi
  chmod +x "$TMP/bin/herdr"
  ASKED=""
  case "$done" in
    true)  W="$(wt_with_done tt$n)" ;;
    false) W="$(wt_silent tt$n)" ;;
    stale) W="$(wt_with_done tt$n)"; touch -t "$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '10 min ago' +%Y%m%d%H%M)" "$W/.handoffs/events.jsonl"; ASKED=$(( $(date +%s) - 300 )) ;;
    fresh) W="$(wt_with_done tt$n)"; ASKED=$(( $(date +%s) - 300 )) ;;
  esac
  is "table: $cname" "$want" "$(state "$stored" "wH:pA" "$W" "$ASKED")"
done < <(jq -r '.cases[] | [.name, .stored, (.pane // "null"), (.done_event|tostring), .want] | @tsv' status-cases.json)

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
