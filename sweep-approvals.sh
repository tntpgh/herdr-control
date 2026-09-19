#!/usr/bin/env bash
# sweep-approvals.sh — every pane that is asking something, what it is asking,
# and what the classifier says about it. `--answer` answers only the ones the
# classifier calls operational, and only through herdr-select.sh.
#
#   bash sweep-approvals.sh              # LIST (default; changes nothing)
#   bash sweep-approvals.sh --answer     # answer the `allow` ones, accountably
#   bash sweep-approvals.sh --json       # same survey, machine-readable
#
# WHY THIS EXISTS. Answering a prompt used to be one command:
# `herdr pane send-keys <pane> ENTER`. That is now DENIED, correctly — it
# accepts whichever option happens to be highlighted, with no classifier
# verdict, no prompt-id check, no pane fingerprint and no audit record. The
# compliant path is `herdr-select.sh <pane> <option> --expect-prompt-id <id>`,
# and the id has to be read off the pane first: four steps and a copied hash,
# per pane. On 2026-09-18 four panes were parked at once; nobody does that by
# hand at that price, and guard-raw-prompt-answer.sh's own comments say an
# over-broad guard "teaches the people it nags to route around it". A guard
# whose compliant path costs four manual steps teaches the same lesson. This is
# the half that repays it.
#
# WHAT IT WILL NOT DO. It never sends a key itself. Every answer goes through
# herdr-select.sh, which re-reads the options at press time, refuses if the
# prompt changed (--expect-prompt-id), refuses if the option now means
# something else, refuses if the pane id was RECYCLED by another task, refuses
# if the approval text is CLIPPED (exit 8 — measured live: a command that did
# not fit the box), and writes the decision to an append-only audit trail. Its
# `peer` authority is already allow-only and already refuses the
# human-reserved list. This script adds no authority; it removes typing.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
[ -r "$here/config.sh" ] && . "$here/config.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$here/lib/prompt-parse.sh"
# shellcheck source=/dev/null
. "$here/lib/command-policy.sh"

MODE=list
for a in "$@"; do
  case "$a" in
    --answer) MODE=answer ;;
    --list|--dry-run) MODE=list ;;
    --json) MODE=json ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

HERDR="${HERDR_BIN:-herdr}"
SELECT="${HERDR_SELECT:-$here/herdr-select.sh}"

panes() {
  $HERDR pane list 2>/dev/null \
    | tr ',' '\n' \
    | sed -nE 's/.*"pane_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
}

# The NARROWEST affirmative, never a broadening one. "Approve and don't ask
# again" / "Yes, and remember this" change the posture for every later prompt,
# which is a decision about the future and therefore not a peer's to make —
# even when this exact command classifies as operational.
narrow_affirmative() {                    # <options tsv> -> option number, or nothing
  # EXACTNESS is the mechanism, and it is the whole mechanism. An option is
  # pressable only if its label is EXACTLY one of these — so "Approve and don't
  # ask again", "Yes, and remember this decision for the rest of the session",
  # "Approve (always)" and anything else that also decides FUTURE prompts falls
  # through and the prompt is held for a human. A peer may answer this command;
  # it may not change the posture for every command after it.
  #
  # An earlier version also carried a "don't ask/always/remember/session"
  # exclusion list. It was dead: exact matching already excludes every one of
  # those, so the list could never fire. Deleted rather than kept as decoration
  # — but if anyone ever loosens this to a prefix or substring match, that list
  # has to come back in the same commit, because exactness is the only thing
  # standing between a peer and a permanent grant.
  local n label low
  while IFS=$'\t' read -r n label; do
    [ -n "${n:-}" ] || continue
    low="$(printf '%s' "$label" | tr 'A-Z' 'a-z')"
    case "$low" in
      approve|yes|allow|"allow once"|"yes, once"|proceed|continue) printf '%s\n' "$n"; return 0 ;;
    esac
  done <<EOF
$1
EOF
  return 1
}

json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '""'; }

# Everything below is the SURVEY ITSELF, in a function, so the suite can source
# this file and drive narrow_affirmative directly rather than only through a
# fixture — the option-choosing rule is the one piece here with real judgement
# in it, and a rule testable only end-to-end is a rule whose edges go untested.
sweep_main() {
found=0 answered=0 held=0 clipped=0
[ "$MODE" = json ] && printf '['
first=1

for p in $(panes); do
  prompt_any_visible "$p" 2>/dev/null || continue
  opts="$(prompt_menu_options "$p" 2>/dev/null || true)"
  [ -n "$opts" ] || opts="$(prompt_options "$p" 2>/dev/null || true)"
  # A prompt this can SEE but not parse is the most dangerous one to answer, so
  # it is always reported and never answered. Same rule as the guard.
  parseable=1; [ -n "$opts" ] || parseable=0
  found=$((found + 1))

  pid="$(prompt_id "$p" 2>/dev/null || true)"
  cmd="$(prompt_command_text "$p" 2>/dev/null || true)"
  # NOT flattened. Collapsing newlines into "; " turned a heredoc commit
  # message into command segments and the classifier then called a plain
  # `git add && git commit` an escalate, with the reason "downloads a program
  # to disk". Measured 2026-09-18 while triaging a stalled pane: the real
  # multi-line text classifies `allow`. The text the classifier sees here is
  # the text herdr-select will classify.
  verdict="$(classify_command "$cmd" 2>/dev/null || printf 'escalate')"
  reason="$(classify_reason 2>/dev/null || true)"
  label="$($HERDR pane list 2>/dev/null | tr '{' '\n' | grep -F "\"$p\"" | sed -nE 's/.*"label"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
  one="$(printf '%s' "$cmd" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-96)"

  if [ "$MODE" = json ]; then
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"pane":%s,"label":%s,"prompt_id":%s,"verdict":%s,"reason":%s,"parseable":%s,"options":%s,"command":%s}' \
      "$(json_escape "$p")" "$(json_escape "${label:-}")" "$(json_escape "${pid:-}")" \
      "$(json_escape "$verdict")" "$(json_escape "${reason:-}")" "$parseable" \
      "$(json_escape "$opts")" "$(json_escape "$cmd")"
    continue
  fi

  printf '\n%s  %s\n' "$p" "${label:+[$label]}"
  printf '  asks: %s\n' "${one:-<unreadable>}"
  printf '  policy: %s%s\n' "$verdict" "${reason:+ — $reason}"
  if [ "$parseable" = 1 ]; then
    printf '%s\n' "$opts" | sed 's/^/  option: /'
  else
    printf '  options: NOT PARSEABLE — read it first: %s pane read %s --source visible\n' "$HERDR" "$p"
  fi

  [ "$MODE" = answer ] || continue

  if [ "$parseable" = 0 ]; then
    printf '  -> HELD: a prompt that cannot be parsed is not answered\n'; held=$((held + 1)); continue
  fi
  if [ "$verdict" != allow ]; then
    printf '  -> HELD: policy says %s, which is yours to answer\n' "$verdict"; held=$((held + 1)); continue
  fi
  choice="$(narrow_affirmative "$opts")" || {
    printf '  -> HELD: no NARROW affirmative option (only ones that also change future prompts)\n'
    held=$((held + 1)); continue; }
  [ -n "$pid" ] || { printf '  -> HELD: no prompt id to bind the answer to\n'; held=$((held + 1)); continue; }

  out="$(bash "$SELECT" "$p" "$choice" --expect-prompt-id "$pid" 2>&1)"; rc=$?
  case "$rc" in
    0) printf '  -> answered %s via herdr-select\n' "$choice"; answered=$((answered + 1)) ;;
    8) # The clipping refusal is a RESULT, not an error: the request does not fit
       # the approval box, so nobody — human or peer — can see all of what they
       # would be approving. The worker has to re-issue it smaller.
       printf '  -> NEEDS THE WORKER: approval text is clipped, so no one can see all of it\n'
       printf '     tell it to re-issue in shorter commands (send-to-agent.sh %s "...")\n' "$p"
       clipped=$((clipped + 1)) ;;
    *) printf '  -> herdr-select refused (exit %s): %s\n' "$rc" "$(printf '%s' "$out" | head -1)"
       held=$((held + 1)) ;;
  esac
done

if [ "$MODE" = json ]; then printf ']\n'; exit 0; fi

if [ "$found" = 0 ]; then
  printf 'No pane is asking anything.\n'
  exit 0
fi
printf '\n-----\n'
if [ "$MODE" = answer ]; then
  printf '%s prompting · %s answered · %s held for you · %s need the worker\n' \
    "$found" "$answered" "$held" "$clipped"
  printf 'Answers are in the audit trail: %s/selections.jsonl\n' "${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}"
else
  printf '%s pane(s) asking. Nothing was answered — this was a survey.\n' "$found"
  printf 'To answer the operational ones accountably: bash %s --answer\n' "$0"
fi
}

# Executed, not sourced: run it. Sourced by the suite: define and stop.
case "${BASH_SOURCE[0]}" in
  "$0") sweep_main ;;
esac
