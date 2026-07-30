#!/usr/bin/env bash
# attention.sh — an honest waiting-reason for every agent, as tab colour + a
# `$status` sidebar token, plus a one-line "what needs you next" focus view.
#
# The idea is lifted from caioniehues/herdmates' signal engine and focus pane,
# rebuilt lean: one bash pass over the herd instead of a Rust daemon. Its
# doctrine is the same — NEVER show a wrong reason. When a pane's state is not
# clear, it degrades to a reason-less "waiting" rather than guessing.
#
#   attention.sh                 # classify every agent; colour + $status token
#   attention.sh --focus         # + print the single next thing that needs you
#   attention.sh --dry-run       # print the classification; change nothing
#   attention.sh w2              # limit to one workspace (or a tab/pane id)
#   attention.sh --no-mark       # annotate $status only; don't touch colours
#
# Reason precedence (highest first):
#   permission  — a numbered prompt is on screen (needs an answer now)
#   waiting     — screen unchanged past HERDR_STALL_SECS and no prompt up
#                 (best-effort sub-reason: "waiting for input" / "stalled Ns")
#   working     — screen changed since the last pass
#   idle        — not an agent / a quiet shell
#
# Colour: attention only sets a pane's colour when herdr has NO real agent
# status of its own (agent_status "unknown"); a live status hook always wins.
# The `$status` token is display-only metadata and is always safe to publish.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
source "$HERE/config.sh"
# shellcheck source=lib/pane-guard.sh
source "$HERE/lib/pane-guard.sh"     # pane_is_agent
# shellcheck source=lib/prompt-parse.sh
source "$HERE/lib/prompt-parse.sh"   # prompt_options, prompt_question
# shellcheck source=lib/pane-name.sh
source "$HERE/lib/pane-name.sh"      # pane_display_name

focus=0 dry=0 mark=1 target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --focus)   focus=1 ;;
    --dry-run) dry=1 ;;
    --no-mark) mark=0 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    -*)        echo "attention: unknown flag '$1'" >&2; exit 2 ;;
    *)         target="$1" ;;
  esac
  shift
done

STATE="$HERDR_STATE_DIR/attention"
mkdir -p "$STATE" 2>/dev/null || true

PANES=$(herdr pane list 2>/dev/null) || { echo "attention: herdr not reachable" >&2; exit 1; }
_panes() { printf '%s' "$PANES" | jq -c '(.result.panes // .panes)[]?'; }

# Panes in scope: all, or a workspace / tab / pane target.
scope_panes() {
  case "$target" in
    "")   _panes | jq -r '.pane_id' ;;
    *:p*) printf '%s\n' "$target" ;;
    *:t*) _panes | jq -r --arg t "$target" 'select(.tab_id==$t) | .pane_id' ;;
    *)    _panes | jq -r --arg w "$target" 'select(.workspace_id==$w) | .pane_id' ;;
  esac
}

now() { date +%s; }
_sf() { printf '%s/%s' "$STATE" "$(printf '%s' "$1" | tr ':/' '__')"; }
_vishash() {
  herdr pane read "$1" --source visible --lines 40 2>/dev/null \
    | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g' \
    | sed -E 's/[[:space:]]+$//' | grep -vE '^[[:space:]]*$' \
    | shasum -a 256 2>/dev/null | cut -c1-16
}

# classify <pane> -> "urgency<TAB>state<TAB>reason"
#   urgency: 0 permission · 1 waiting · 2 working · 3 idle  (lower = more urgent)
classify() {
  local pane="$1" opts h sf oldh oldts elapsed vis reason
  if ! pane_is_agent "$pane"; then printf '3\tidle\t'; return; fi

  opts=$(prompt_options "$pane" 2>/dev/null)
  if [ -n "$opts" ]; then
    reason=$(prompt_question "$pane" 2>/dev/null)
    printf '0\tpermission\t%s' "${reason:-permission prompt}"; return
  fi

  h=$(_vishash "$pane"); sf=$(_sf "$pane")
  if [ -f "$sf" ]; then IFS=$'\t' read -r oldh oldts < "$sf"; else oldh=""; oldts=""; fi
  if [ "$h" != "${oldh:-}" ] || [ -z "${oldts:-}" ]; then
    printf '%s\t%s\n' "$h" "$(now)" > "$sf"     # changed (or first sight): reset the clock
    printf '2\tworking\t'; return
  fi

  elapsed=$(( $(now) - oldts ))
  if [ "$elapsed" -lt "$HERDR_STALL_SECS" ]; then printf '2\tworking\t'; return; fi

  # Unchanged past the stall window. Sub-reason is best-effort and honest:
  # a frozen active-work marker -> stalled; a ready composer -> waiting for
  # input; anything else -> bare "waiting".
  vis=$(herdr pane read "$pane" --source visible --lines 12 2>/dev/null | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g')
  if printf '%s' "$vis" | grep -qiE 'esc to interrupt|thinking…|running…|compacting|⏳'; then
    reason="stalled ${elapsed}s"
  elif printf '%s' "$vis" | grep -qE '│[[:space:]]*[❯>][[:space:]]*│|^[[:space:]]*[❯>][[:space:]]*$'; then
    reason="waiting for input"
  else
    reason="waiting"
  fi
  printf '1\twaiting\t%s' "$reason"
}

# apply <pane> <state> <reason>: publish the $status token (always) and set the
# tab colour (only when herdr has no real status of its own).
apply() {
  local pane="$1" state="$2" reason="$3" live herdr_state tok
  tok=$(printf '%s' "${reason:-$state}" | cut -c1-60)   # sidebar columns are scarce
  herdr pane report-metadata "$pane" --source "$HERDR_SOURCE" \
    --token "status=${tok}" >/dev/null 2>&1 || true
  [ "$mark" = 1 ] || return 0
  live=$(_panes | jq -r --arg p "$pane" 'select(.pane_id==$p) | .agent_status // "unknown"')
  case "$live" in ""|unknown) : ;; *) return 0 ;; esac   # a live hook owns the colour
  case "$state" in
    permission|waiting) herdr_state=blocked ;;
    working)            herdr_state=working ;;
    *)                  herdr_state=idle ;;
  esac
  herdr pane report-agent "$pane" --source "$HERDR_SOURCE" \
    --agent "${HERDR_MARK_AGENT:-task}" --state "$herdr_state" >/dev/null 2>&1 || true
}

# --- run --------------------------------------------------------------------
rows=""   # urgency<TAB>state<TAB>pane<TAB>reason, one per line
for pane in $(scope_panes); do
  [ -n "$pane" ] || continue
  IFS=$'\t' read -r urg state reason <<EOF
$(classify "$pane")
EOF
  rows="${rows}${urg}	${state}	${pane}	${reason}
"
  [ "$dry" = 1 ] || apply "$pane" "$state" "$reason"
done

# Per-pane report (skip idle non-agents unless dry-run asked for everything).
printf '%s' "$rows" | sort -t$'\t' -k1,1n | while IFS=$'\t' read -r urg state pane reason; do
  [ -n "$pane" ] || continue
  [ "$state" = idle ] && [ "$dry" != 1 ] && continue
  [ "$reason" = "$state" ] && reason=""      # don't print "waiting — waiting"
  printf '%-11s %-7s %s%s\n' "$pane" "$state" "$(pane_display_name "$pane")" "${reason:+  — $reason}"
done

# --- focus view: the single most urgent thing, then the short queue ----------
if [ "$focus" = 1 ]; then
  echo
  attn=$(printf '%s' "$rows" | sort -t$'\t' -k1,1n | awk -F'\t' '$1<2')  # permission + waiting
  if [ -z "$attn" ]; then
    echo "→ nothing needs you — all agents working or idle."
  else
    top=$(printf '%s\n' "$attn" | head -1)
    IFS=$'\t' read -r _ tstate tpane treason <<EOF
$top
EOF
    [ "$treason" = "$tstate" ] && treason=""
    printf '→ NEXT: %s  (%s%s)\n' "$(pane_display_name "$tpane")" "$tstate" "${treason:+: $treason}"
    rest=$(printf '%s\n' "$attn" | tail -n +2)
    if [ -n "$rest" ]; then
      echo "  then:"
      printf '%s\n' "$rest" | while IFS=$'\t' read -r _ s p r; do
        [ -n "$p" ] || continue
        [ "$r" = "$s" ] && r=""
        printf '   · %s  (%s%s)\n' "$(pane_display_name "$p")" "$s" "${r:+: $r}"
      done
    fi
  fi
fi
