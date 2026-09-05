#!/usr/bin/env bash
# spawn-agent.sh [--focus] [--posture P] <project-path> <role-label> [command...]
#
# Launch an agent SESSION in its own new tab of the project's workspace:
#   - ensure the project's workspace is open (ensure-workspace.sh, always --no-focus)
#   - create a tab in it, labeled <role-label>, cwd = the repo
#   - run <command> in that tab's pane (default: $HERDR_DEFAULT_AGENT)
#   - mark the pane 'working' so the tab shows active
#
# Default is BACKGROUND: the new tab does not steal focus from wherever you
# are (a spawned sub-agent/task worker should never yank your terminal out
# from under you). Pass --focus to jump to it immediately instead.
#
#   spawn-agent.sh ~/src/app fix-bug                    # default agent, background
#   spawn-agent.sh ~/src/app audit codex                # a specific agent, background
#   spawn-agent.sh --focus ~/src/app shell bash          # jump to the new tab
#
# A RECOGNIZED agent (claude/codex/omc/omp — lib/agent-profiles.sh) is a
# MANAGED launch, same rules as spawn-task.sh: cli_for_agent routes it at the
# standard (implement) tier, the machine posture floor is composed with an
# optional --posture request (tighten-only), extra flags that would override
# approval/rules/system context are REFUSED, canonical operator ancestor
# rules are appended (omp-backed launches), and everything is %q-quoted
# across the pane-run shell boundary. Anything else runs as an explicitly
# UNMANAGED literal command and is reported as such — no posture flag, no
# rules append, no false inheritance implied.
#
# Unlike spawn-task.sh this makes NO run-registry entry (no worktree, no
# task): the pane gets identity env (its own HERDR_PANE_ID plus conductor
# identity when spawned from inside a herdr pane) so omp push-wake and
# prompt_id capture work, but there is no task to reconcile and no wake
# persistence — that is spawn-task.sh's job, reported in the output below.
#
# NOTE: routes agent *sessions*, which become panes. It cannot route an in-process
# sub-agent (those are not herdr panes).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
. "$here/lib/agent-profiles.sh"
. "$here/lib/repo-root.sh"

foc=--no-focus; posture_req=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --focus) foc=--focus; shift ;;
    --posture) posture_req="${2:?spawn-agent: --posture needs a value (yolo|write|strict)}"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"

proj="${1:?usage: spawn-agent.sh [--focus] [--posture P] <project-path> <role-label> [command...]}"
role="${2:?usage: spawn-agent.sh [--focus] [--posture P] <project-path> <role-label> [command...]}"
shift 2
cmd=("$@"); [ "${#cmd[@]}" -eq 0 ] && cmd=("$HERDR_DEFAULT_AGENT")
agent="${cmd[0]}"

# The caller's own pane (when running inside a herdr pane) is this spawn's
# CONDUCTOR — captured before we stamp the worker's own HERDR_PANE_ID.
conductor_pane_id="${HERDR_PANE_ID:-}"
conductor_id="${HERDR_CONDUCTOR_ID:-conductor_${conductor_pane_id:-unknown}}"

# ---- managed vs literal (same contract as spawn-task.sh) --------------------
managed=1
if cli=$(cli_for_agent "$agent" "$(model_for_agent "$agent" implement)" "$posture_req"); then
  if [ "${#cmd[@]}" -gt 1 ]; then
    for _x in "${cmd[@]:1}"; do
      if managed_flag_rejected "$_x"; then
        echo "spawn-agent: refusing managed extra flag '$_x' — it would override approval posture, rules/extensions, or system context." >&2
        echo "spawn-agent: tighten with --posture <yolo|write|strict>, or run an explicitly UNMANAGED literal command if you really mean it." >&2
        exit 1
      fi
      cli="$cli $(printf '%q' "$_x")"
    done
  fi
else
  managed=0
  cli="${cmd[*]}"  # literal command; no model mapping, no posture flag, no rules append
fi
eff_posture=$(resolved_posture "$posture_req")

# repo_root (lib/repo-root.sh), not --show-toplevel: inside a linked worktree
# --show-toplevel returns the WORKTREE's own path, which would give a task
# worktree its own separate workspace instead of joining its parent repo's.
root=$(repo_root "$proj")

# Canonical operator ancestor rules (lib/agent-profiles.sh) — same behavior
# as spawn-task.sh: derived from the ORIGINAL project root's ancestors or an
# inherited explicit HERDR_CANONICAL_RULES path; a configured-but-unusable
# source FAILS the managed launch rather than silently dropping the
# operator's rules. Normal project rule discovery is untouched.
CANONICAL_RULES_SRC="" CANONICAL_RULES_ARGS=""
if [ "$managed" = 1 ]; then
  canonical_rules_resolve "$agent" "$root" || {
    echo "spawn-agent: canonical rules source configured but unusable — refusing managed launch" >&2
    exit 1
  }
  [ -n "$CANONICAL_RULES_ARGS" ] && cli="$cli $CANONICAL_RULES_ARGS"
fi

ws=$(bash "$here/ensure-workspace.sh" --no-focus "$root") || exit 1

# Create the tab; the response carries both the tab and its root pane.
tc=$(herdr tab create --workspace "$ws" --cwd "$root" --label "$role" "$foc" 2>/dev/null)
tab=$(printf '%s' "$tc" | jq -r '.result.tab.tab_id // empty')
pane=$(printf '%s' "$tc" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$tab" ] && [ -n "$pane" ] || { echo "spawn-agent: tab create failed in $ws" >&2; exit 1; }

# Stamp identity + operator policy into the pane's shell, %q-quoted (the
# string is TYPED into the live shell — same hazard spawn-task.sh already
# fixed for its stamp). HERDR_PANE_ID is the pane's OWN id, which is what
# lets agent-hooks/omp-notify.sh verify a painted prompt and lib/push-wake.sh
# capture a prompt_id; conductor identity is passed through when this spawn
# came from inside a herdr pane. HERDR_POSTURE_FLOOR is this spawn's
# EFFECTIVE posture, so any child herdr launch from this pane can only
# tighten. No run/task ids are invented here — this pane is NOT registered.
stamped_cli=$(printf 'export HERDR_PANE_ID=%q HERDR_CONDUCTOR_ID=%q HERDR_CONDUCTOR_PANE_ID=%q HERDR_POSTURE_FLOOR=%q' \
  "$pane" "$conductor_id" "$conductor_pane_id" "$eff_posture")
[ -n "${HERDR_POLICY_EXTRA_RULES:-}" ] && stamped_cli="$stamped_cli $(printf 'HERDR_POLICY_EXTRA_RULES=%q' "$HERDR_POLICY_EXTRA_RULES")"
[ -n "$CANONICAL_RULES_SRC" ] && stamped_cli="$stamped_cli $(printf 'HERDR_CANONICAL_RULES=%q' "$CANONICAL_RULES_SRC")"
stamped_cli="$stamped_cli; $cli"

herdr pane run "$pane" "$stamped_cli" >/dev/null 2>&1 \
  || { echo "spawn-agent: failed to run '$cli' in $pane" >&2; exit 1; }

# Reflect 'active' on the tab immediately (the agent's own status hook takes over later).
herdr pane report-agent "$pane" --source "$HERDR_SOURCE" --agent "$role" --state working >/dev/null 2>&1 || true

bgtag="background"; [ "$foc" = --focus ] && bgtag="focused"
printf 'spawned %-14s ws=%s tab=%s pane=%s  cmd=%s  [%s]\n' "$role" "$ws" "$tab" "$pane" "$cli" "$bgtag"
if [ "$managed" = 1 ]; then
  printf '  posture:  %s  (floor %s, request %s; stamped as the pane'"'"'s own floor)\n' \
    "$eff_posture" "${HERDR_POSTURE_FLOOR:-write}" "${posture_req:-none}"
  if [ -n "$CANONICAL_RULES_SRC" ]; then
    printf '  rules:    %s (appended with provenance; normal project discovery untouched)\n' "$CANONICAL_RULES_SRC"
  else
    printf '  rules:    <none — no ancestor AGENTS.md found/configured; normal project discovery only>\n'
  fi
else
  printf '  ⚠ UNMANAGED literal command: no posture flag, no canonical rules append —\n'
  printf '    only the env floor stamp reaches it; nothing here enforces approvals.\n'
fi
printf '  registry: <not registered — no task identity or wake persistence; use spawn-task.sh for a supervised worktree task>\n'
