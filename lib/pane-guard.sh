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
# lib/agent-profiles.sh is the single source of truth for known agent binary
# names — add a new agent there, not here.
_pg_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_pg_dir/agent-profiles.sh"
_AGENT_RE="${HERDR_AGENT_PROCS:-^($(printf '%s' "$HERDR_AGENT_PROC_NAMES" | tr ' ' '|'))$}"

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
pane_birth_now() {                      # pane_id -> live terminal_id, empty if pane gone, rc 1 if herdr itself failed
  local out
  out="$(herdr pane list 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -r --arg p "$1" \
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

# Is this pane allowed to BE or RECEIVE conductor authority (Main,
# spawn-task.sh's HERDR_MCP_CONDUCTOR_PANE fallback) -- a live agent pane
# that is not some OTHER task's currently active worker pane. Extracted from
# spawn-task.sh's own F8 check (security review PR #220: pane_is_agent alone
# only proves SOME agent is running there now -- a herdr-recycled pane id can
# belong to an unrelated WORKER, and a worker is never a conductor) so
# designate-main.sh (P3, .handoffs/SPEC.md feat/main-designation-lock) and
# conductor-handover.sh (P1) share the identical judgment instead of growing
# a second copy that drifts. Requires lib/run-registry.sh already sourced
# (uses task_for_pane), same convention as require_pane_birth_match above.
#
# F5 (security review PR #252): task_for_pane's own exit status, not just
# its (possibly empty) stdout, is checked below -- a failed registry read
# must refuse (not a worker -> eligible is the WRONG default for "we
# couldn't tell"), same fail-closed direction as pane_birth_now above.
pane_is_conductor_eligible() {          # pane_id -> 0 eligible, 1 refuse
  local pane="$1" task state
  pane_is_agent "$pane" 2>/dev/null || return 1
  task="$(task_for_pane "$pane" 2>/dev/null)" || return 1
  state="$(printf '%s' "$task" | jq -r '.state // empty' 2>/dev/null)"
  case "$state" in
    running|starting|blocked) return 1 ;;
  esac
  return 0
}

# ---- caller identity from process ancestry (not self-asserted env) ---------
# $HERDR_PANE_ID/$HERDR_TASK_ID come from the CALLING process's own
# environment -- a worker can export whatever it likes before running a
# script that trusts them (F2, security review PR #252: designate-main.sh,
# P3, .handoffs/SPEC.md feat/main-designation-lock). This resolves/validates
# identity from something the caller cannot set: the OS process tree herdr
# itself reports back about each pane's CURRENT foreground job.
#
# Architecture note (measured empirically on this host, both for a plain
# `herdr pane send-text`-typed command and for an agent's own bash-tool
# dispatch): neither path makes the agent binary (omp/claude/codex) a
# process ancestor of the command it runs -- herdr's daemon forks the shell
# itself for BOTH, so "walk ancestry for an agent's binary NAME" (as first
# proposed for designate-main.sh --force, F3) cannot distinguish a human
# typing in a pane from an agent dispatching through its tool. What IS a
# real, unspoofable signal: whether this process's ancestry traces to ANY
# herdr-tracked pane at all. Every agent (worker or Main) by definition runs
# inside one; a genuinely external human shell (direct ssh, a terminal
# outside herdr's purview) never will. caller_pane_from_ancestry's rc=2
# captures exactly that "outside herdr's reach entirely" case, consumed by
# designate-main.sh's --force gate; rc=0 (a pane was found) is the identity
# used everywhere else a caller's own pane must be known for certain.
#
# Bounded (HERDR_ANCESTOR_WALK_MAX hops, default 32) so a cycle or a very
# deep tree cannot hang a caller; each hop costs one `ps` call.
_pg_process_ancestors() {   # -> $PPID, its parent, ... one pid per line
  local pid="$PPID" hops=0 max="${HERDR_ANCESTOR_WALK_MAX:-32}"
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt "$max" ]; do
    printf '%s\n' "$pid"
    hops=$((hops + 1))
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  done
}

# Which live pane is this process actually running inside, as herdr itself
# sees it: the first ancestor pid (closest first) that herdr reports as a
# CURRENT foreground process of some pane.
#   rc 0  -- found; the pane_id is printed on stdout.
#   rc 1  -- the check itself could not complete (herdr/ps read failure, or
#            the ancestor walk produced nothing) -- fails closed, NEVER
#            treated the same as a clean no-match.
#   rc 2  -- the walk ran cleanly end to end and traced to NO herdr pane --
#            the only rc designate-main.sh's --force may treat as "outside
#            herdr's reach" (see note above).
caller_pane_from_ancestry() {
  local panes pane_ids p map ancestors pid found
  panes="$(herdr pane list 2>/dev/null)" || return 1
  [ -n "$panes" ] || return 1
  pane_ids="$(printf '%s' "$panes" | jq -r '(.result.panes // .panes)[]?.pane_id' 2>/dev/null)"
  [ -n "$pane_ids" ] || return 1
  map=""
  for p in $pane_ids; do
    local info
    info="$(herdr pane process-info --pane "$p" 2>/dev/null)" || return 1
    map="$map
$(printf '%s' "$info" | jq -r --arg pane "$p" \
      '.result.process_info.foreground_processes[]? | (.pid|tostring) + " " + $pane' 2>/dev/null)"
  done
  ancestors="$(_pg_process_ancestors)"
  [ -n "$ancestors" ] || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    found="$(printf '%s' "$map" | awk -v want="$pid" '$1==want {print $2; exit}')"
    if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  done <<EOF
$ancestors
EOF
  return 2
}
