#!/usr/bin/env bash
# pane-guard.sh — "is this pane safe to send input to?"
#
# Sourced by herdr-deliver.sh (text delivery) and herdr-select.sh (answering a
# prompt). Both put attacker-reachable input into a live terminal, so both need
# the SAME answer to that question — a second copy of this logic would drift,
# and the drift would be a security hole rather than a cosmetic inconsistency.
#
# Provides: pane_is_agent <pane_id>       0 = safe target, 1 = refuse
#           require_agent_pane <pane_id>  same, but explains the refusal

# Transparent multiplexers say NOTHING about what is running inside the pane —
# herdr reports the tmux client alongside the inner process, so most panes read
# "tmux,node" and a pane whose agent exited reads "tmux,zsh". They must be
# stripped before judging, or "tmux" alone satisfies any "something non-shell is
# running" test and every shell pane passes.
_MUX_RE='^(tmux|screen|zellij|abduco|dtach|mosh-client)$'

# ALLOWLIST, not a denylist. A denylist of shells was the wrong shape: vim
# (`:!cmd`), less (`!cmd`) and any REPL execute commands just as directly as zsh,
# so naming the shells only moved the hole. Name what MAY receive input instead;
# anything unrecognised is refused.
#
# HERDR_AGENT_PROCS only ever WIDENS this gate — HERDR_AGENT_PROCS='.*' disables
# it entirely, and the bridge subprocess inherits the daemon's environment, so a
# value set in herdr-bridge.env or the launchd plist silently applies to input
# arriving from Slack. Treat it as security configuration, not convenience.
# (A malformed regex makes grep error, which denies — that direction is safe.)
_AGENT_RE="${HERDR_AGENT_PROCS:-^(claude|codex|omc|herdr-reviewr|aider|opencode|goose)$}"

# Agents that ride a shared runtime need MORE than the name. Every agent here is
# some form of `node <script>`, but a runtime with no script — or with an
# interactive/eval flag — is a REPL, which evaluates whatever it is handed: the
# exact primitive this gate exists to deny.
_RUNTIME_RE='^(node|deno|bun|python|python3|python3\.[0-9]+|ruby|perl)$'

pane_is_agent() {
  local info rows name cmdline
  info=$(herdr pane process-info --pane "$1" 2>/dev/null) || return 1
  # name<TAB>cmdline per process. A missing cmdline yields an empty field, which
  # fails the runtime test below — conservative, as it should be.
  rows=$(printf '%s' "$info" | jq -r '
    .result.process_info.foreground_processes[]?
    | ((.name // "") + "\t" + (.cmdline // ""))' 2>/dev/null)
  # No foreground process at all = sitting at a shell prompt.
  [ -n "$rows" ] || return 1
  while IFS=$'\t' read -r name cmdline; do
    [ -n "$name" ] || continue
    printf '%s' "$name" | grep -qxE "$_MUX_RE" && continue
    printf '%s' "$name" | grep -qxE "$_AGENT_RE" && return 0
    if printf '%s' "$name" | grep -qxE "$_RUNTIME_RE"; then
      # "Was it given an ARGUMENT" is not the question — `node -i` has one and
      # is still a REPL. The question is whether it was given something to RUN.
      case "$cmdline" in
        *" -i"*|*" --interactive"*|*" -e "*|*" --eval"*|*" -c "*|*" -p "*|*" --print"*)
          continue ;;
      esac
      case "$cmdline" in
        *[![:space:]][[:space:]][!-]*) return 0 ;;
      esac
    fi
  done <<EOF
$rows
EOF
  return 1
}

require_agent_pane() {
  pane_is_agent "$1" && return 0
  echo "herdr: refusing to send input to '$1' — it is not running an agent." >&2
  echo "herdr: input sent to a shell pane executes as a command." >&2
  return 1
}

# The pane's current birth fingerprint (herdr's own terminal_id) — unique per
# pane INSTANCE and never reused, unlike pane_id itself which herdr recycles
# once a pane closes. pane_is_agent above only proves something agent-shaped
# is running in this pane RIGHT NOW; it says nothing about whether that is
# still the same process an earlier decision (a registered task, a captured
# prompt_id) was made about.
pane_birth_now() {                      # pane_id -> live terminal_id, empty if pane gone
  herdr pane list 2>/dev/null | jq -r --arg p "$1" \
    '(.result.panes // .panes)[]? | select(.pane_id==$p) | .terminal_id // empty' 2>/dev/null
}

# Refuse to act if a REGISTERED task's pane has been recycled since spawn —
# the TOCTOU gap the consensus review (docs/control-plane-design.md,
# correction 5) called the most dangerous unhit failure: "a delayed answer
# being injected into a reused pane and accepted by the wrong task." Pane ids
# get freed and reissued; validating "is this an agent pane" and "is this
# prompt still on screen" is not enough if the pane itself now belongs to an
# unrelated later process that also happens to be running an agent showing a
# prompt.
#
# Requires lib/run-registry.sh to already be sourced (uses task_for_pane).
# Only enforces when the pane IS registered — a pane spawned outside the
# registry (e.g. spawn-agent.sh, which never calls register_task) has
# nothing to validate against, so this passes it through unchanged. Same
# backward-compatible principle as --expect-prompt-id: omit the thing to
# check against, and behavior for that caller is unchanged.
require_pane_birth_match() {            # pane_id -> 0 ok-to-proceed, 1 refuse
  local pane="$1" task registered_birth live_birth
  task="$(task_for_pane "$pane" 2>/dev/null)"
  [ -n "$task" ] || return 0
  registered_birth=$(printf '%s' "$task" | jq -r '.pane_birth // empty')
  [ -n "$registered_birth" ] || return 0
  live_birth="$(pane_birth_now "$pane")"
  if [ -z "$live_birth" ]; then
    echo "herdr: refusing — pane '$pane' no longer exists (its registered task's pane is gone)." >&2
    return 1
  fi
  if [ "$live_birth" != "$registered_birth" ]; then
    echo "herdr: refusing — pane '$pane' has been RECYCLED since its task was registered." >&2
    echo "herdr:   registered fingerprint=$registered_birth  live fingerprint=$live_birth" >&2
    echo "herdr:   this pane id now belongs to a different process; refusing to act on stale identity." >&2
    return 1
  fi
  return 0
}
