#!/usr/bin/env bash
# herdr-select.sh <pane_id> <option-number> [--expect-prompt-id ID]
#
# Answer a prompt an agent is showing, by selecting that option — the ONE
# path allowed to answer a permission prompt, because the alternative is
# worse: without it you get a notification you cannot act on, and the
# temptation is to let ordinary text delivery press Enter — which silently
# accepts whatever option happened to be highlighted. Here the human has read
# the actual options and named one, by NUMBER, same as always. That is
# consent; a blind Enter is not.
#
# Two prompt SHAPES exist, and the caller never needs to know which one it is
# driving — the option number means the same thing either way:
#   - numbered (Claude, Codex): `❯ N. text`, answered by pressing the bare
#     digit — no Enter, since Enter accepts a DEFAULT and a default is
#     exactly what we refuse to send on someone's behalf.
#   - menu (omp): an up/down + Enter list with no numbers on screen at all —
#     verified live 2026-07-31 against `omp --approval-mode always-ask`.
#     lib/prompt-parse.sh's prompt_menu_options still numbers the rows 1..N
#     top-to-bottom so the external contract (a Slack "reply 1/2/3") stays
#     identical; this script translates that number into "press Down/Up
#     until the target row is highlighted, then Enter" instead of a digit.
#     herdr-select.sh's own audit log records the mechanism used.
#
# Everything below exists to keep the "a human named one" guarantee true:
#   - the target must be an agent pane (shared gate, lib/pane-guard.sh)
#   - a prompt must actually be on screen RIGHT NOW, in one of the two shapes
#   - the chosen number must be one of the options currently offered —
#     re-checked a SECOND time immediately before acting, not just at the
#     top of the script, so a prompt that changed between the initial read
#     and the keypress is caught rather than answered blind
#   - the choice is recorded before it is sent, so what was authorised is on
#     disk even if the keypress or the agent then misbehaves — and if that
#     record fails to write, this now REFUSES to press anything rather than
#     acting with a broken audit trail
#
# --expect-prompt-id closes a time-of-check/time-of-use gap that only matters
# once a decision and its injection can be separated in time (a conductor
# reads a pushed wake, decides, THEN calls this) — the options check above
# already re-reads the screen at call time, but nothing previously proved the
# prompt being answered is the SAME prompt the decision was made about. Pass
# the prompt_id captured at decision time (lib/prompt-parse.sh's prompt_id,
# shape-agnostic) and this refuses to press anything if the on-screen prompt
# has since changed, vanished, or the pane now belongs to a different task.
# Omit it and behavior is unchanged — a human deciding and pressing in one
# motion has no such gap.
#
# A second, unconditional TOCTOU close: pane ids are RECYCLED — closing and
# reopening a tab can hand out the same id to an unrelated later process.
# require_pane_birth_match (lib/pane-guard.sh) revalidates this pane's live
# fingerprint against whatever the run registry recorded at spawn time,
# immediately before the keypress, and refuses on a mismatch. Unlike
# --expect-prompt-id this is not opt-in — it runs whenever the pane IS
# registered, since there is no safe default that skips it.
#
# Exit 0 selected, 2 usage, 3 not an agent pane, 6 no prompt / bad option /
# prompt changed / navigation could not converge, 7 pane recycled since its
# task was registered.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH:-}"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"
. "$here/lib/run-registry.sh"

pane="${1:?usage: herdr-select.sh <pane_id> <option-number> [--expect-prompt-id ID]}"
choice="${2:?option number required}"
shift 2

expect_id=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-prompt-id) expect_id="${2:?--expect-prompt-id needs a value}"; shift 2 ;;
    *) echo "herdr-select: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

case "$choice" in
  ''|*[!0-9]*) echo "herdr-select: option must be a number, got '$choice'" >&2; exit 2 ;;
esac

require_agent_pane "$pane" || exit 3

# Which shape is on screen right now, and is $choice actually on offer?
# Tried in this order for every check in this script (top-of-script here,
# and again immediately pre-send below) so both checks agree on shape even
# if a prompt somehow flipped shape between them (it can't in practice —
# one agent, one prompt style — but "somehow" is exactly what re-checking
# from scratch each time protects against).
_current_offer() {   # -> "mechanism<TAB>options-blob" or empty
  local opts
  opts=$(prompt_options "$pane")
  if [ -n "$opts" ]; then printf 'numbered\t%s' "$opts"; return; fi
  opts=$(prompt_menu_options "$pane")
  [ -n "$opts" ] && printf 'menu\t%s' "$opts"
}

offer=$(_current_offer)
if [ -z "$offer" ]; then
  echo "herdr-select: $pane is not showing a prompt this script recognises — nothing to select." >&2
  echo "herdr-select: refusing to press a key into a pane that did not ask a question." >&2
  exit 6
fi
mechanism="${offer%%$'\t'*}"
options="${offer#*$'\t'}"

label=$(printf '%s\n' "$options" | awk -F'\t' -v c="$choice" '$1==c {print $2; found=1} END{exit !found}') || {
  echo "herdr-select: option '$choice' is not on offer in $pane. Currently ($mechanism):" >&2
  printf '%s\n' "$options" | awk -F'\t' '{printf "  %s. %s\n", $1, $2}' >&2
  exit 6
}

# Right before we act — the closest this synchronous script can get to
# "immediately before injection" — confirm the prompt is still the one a
# decision was made about, if the caller told us which one that was...
current_prompt_id=$(prompt_id "$pane")
if [ -n "$expect_id" ] && [ "$current_prompt_id" != "$expect_id" ]; then
  echo "herdr-select: the prompt in $pane no longer matches the one the decision was made about." >&2
  echo "herdr-select: expected prompt_id $expect_id, currently $current_prompt_id — refusing to answer a different prompt." >&2
  exit 6
fi
# ...and UNCONDITIONALLY re-confirm the option itself is still on offer,
# regardless of --expect-prompt-id. The check above only fires when a
# caller opted in; without it, nothing previously re-verified the choice
# still maps to the same option between the top-of-script read and the
# keypress below — a caller that reads options, thinks for a while, then
# calls this script got no re-check at all until now.
reoffer=$(_current_offer)
if [ -z "$reoffer" ]; then
  echo "herdr-select: the prompt in $pane vanished before it could be answered." >&2
  exit 6
fi
relabel=$(printf '%s\n' "${reoffer#*$'\t'}" | awk -F'\t' -v c="$choice" '$1==c {print $2; found=1} END{exit !found}') || {
  echo "herdr-select: option '$choice' is no longer on offer in $pane — refusing to answer a changed prompt." >&2
  exit 6
}
[ "$relabel" = "$label" ] || {
  echo "herdr-select: option '$choice' now means '$relabel', not '$label' it meant moments ago — refusing." >&2
  exit 6
}

# Also right before we act: this pane id may have been RECYCLED since the
# task registry last recorded it. A live agent showing a live prompt is not
# proof it is the SAME agent — it could be a different task's worker that
# reused this pane id after the original one closed. Unconditional (no
# --expect flag): there is no safe default that skips a fingerprint check.
require_pane_birth_match "$pane" || exit 7

# Record BEFORE sending. If the keypress fails or the agent does something
# unexpected, the audit trail still shows exactly what was authorised and
# when. A failed WRITE now refuses to proceed at all — this used to fall
# through to send-keys regardless, silently breaking the "recorded before
# sent" invariant the header above promises whenever mkdir/jq/the append
# itself failed (a full disk, a missing directory permission).
log_dir="${HERDR_BRIDGE_STATE:-$HOME/.config/herdr-bridge}"
mkdir -p "$log_dir" || { echo "herdr-select: cannot create $log_dir — refusing to answer without an audit trail." >&2; exit 2; }
jq -nc --arg pane "$pane" --arg choice "$choice" --arg label "$label" --arg mechanism "$mechanism" \
       --arg via "${HERDR_SELECT_VIA:-cli}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg prompt_id "$current_prompt_id" \
  '{at:$at,pane:$pane,choice:($choice|tonumber),label:$label,mechanism:$mechanism,via:$via,prompt_id:$prompt_id}' \
  >> "$log_dir/selections.jsonl" || {
  echo "herdr-select: failed to write $log_dir/selections.jsonl — refusing to answer without an audit trail." >&2
  exit 2
}

if [ "$mechanism" = numbered ]; then
  # Claude's and Codex's selection prompts take the bare digit — no Enter,
  # which is the point: Enter is the keystroke that accepts a DEFAULT, and a
  # default is precisely what we are refusing to send on someone's behalf.
  herdr pane send-keys "$pane" "$choice" >/dev/null 2>&1 || {
    echo "herdr-select: failed to send key '$choice' to $pane" >&2
    exit 2
  }
else
  # omp's menu has no digit to press — walk the highlight to the target row
  # with Down/Up, confirming the move after EVERY keystroke (never assume a
  # press landed where expected; a prompt that changes mid-navigation, or a
  # highlight that becomes undetectable, aborts rather than guessing), then
  # Enter submits whichever row is highlighted at that point. Bounded at 20
  # presses — generous for any real menu, finite so a pathological/wrapping
  # menu can't spin forever.
  cur=$(prompt_menu_selected "$pane")
  [ -n "$cur" ] || {
    echo "herdr-select: cannot tell which option is currently highlighted in $pane — refusing to navigate blind." >&2
    exit 6
  }
  tries=0
  while [ "$cur" != "$choice" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 20 ] || {
      echo "herdr-select: menu navigation in $pane did not reach option $choice after 20 presses — aborting." >&2
      exit 6
    }
    dir=Down; [ "$choice" -lt "$cur" ] && dir=Up
    herdr pane send-keys "$pane" "$dir" >/dev/null 2>&1 || {
      echo "herdr-select: failed to send '$dir' to $pane" >&2
      exit 2
    }
    cur=$(prompt_menu_selected "$pane")
    [ -n "$cur" ] || {
      echo "herdr-select: the prompt in $pane vanished or its highlight became unreadable mid-navigation — aborting." >&2
      exit 6
    }
  done
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || {
    echo "herdr-select: failed to send Enter to $pane" >&2
    exit 2
  }
fi

# Answered HERE, so stop tracking it as pending. herdr-resolve retracts alerts
# whose prompt has vanished — correct when you answered in the terminal, wrong
# when you answered in Slack: it would delete the very message carrying your
# choice and the confirmation under it. Untrack, and the record stays.
pending="$log_dir/pending.jsonl"
if [ -s "$pending" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/herdr-pending.XXXXXX") && {
    jq -c --arg p "$pane" 'select(.pane != $p)' < "$pending" > "$tmp" 2>/dev/null \
      && cat "$tmp" > "$pending"
    rm -f "$tmp"
  }
fi

echo "selected $choice ($label) in $pane via $mechanism"
