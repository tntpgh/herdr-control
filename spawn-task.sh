#!/usr/bin/env bash
# spawn-task.sh <project> <branch> [job-class] [agent-or-command...] [--base REF] [--dry-run] [--focus]
#
# Spin a task into its own WORKTREE, opened as a TAB inside the project's own
# workspace (a "sub-tab", not a separate space), running the right agent at the
# right model for the job. This is the orchestrator's per-task hand:
#
#   spawn-task.sh ~/Code/myproject fix-parser implement           # claude, sonnet
#   spawn-task.sh ~/Code/myproject arch-review review codex       # codex, deep model
#   spawn-task.sh ~/Code/myproject fix-worker implement omp       # omp, sonnet
#   spawn-task.sh ~/Code/myproject probe quick pwd                # literal cmd (no model)
#
# Default is BACKGROUND: the new sub-tab does not steal focus (a spawned task
# worker should never yank your terminal out from under you). Pass --focus
# to jump to it immediately: spawn-task.sh --focus ~/Code/myproject fix-parser implement
#
# job-class -> model (edit lib/agent-profiles.sh's model_for_agent; --model/
# --effort override):
#   plan|architect|review|design  -> claude opus   · codex $HERDR_CODEX_DEEP · omp opus:high
#   implement|debug|code          -> claude sonnet · codex $HERDR_CODEX_STD  · omp sonnet:medium
#   explore|quick|mechanical|docs -> claude haiku  · codex $HERDR_CODEX_FAST · omp haiku:low
# (Claude/omp tiers are model-name aliases both CLIs fuzzy-match; Codex model
# names live in config.sh. Known agents live in lib/agent-profiles.sh — add a
# new one there, not in this file.)
#
# herdr's native `worktree create` always makes a SEPARATE space; to get a sub-tab
# we do `git worktree add` + `tab create --workspace <repo-ws>` ourselves. Each tab
# is a real branch checkout, so sort-tabs/mark-tab treat it as a first-class tab.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/run-registry.sh"
. "$here/lib/agent-profiles.sh"
. "$here/lib/repo-root.sh"

# ---- args ------------------------------------------------------------------
base=""; dry=0; model_override=""; effort_override=""; foc=--no-focus; positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --model) model_override="$2"; shift 2 ;;
    --effort) effort_override="$2"; shift 2 ;;
    --dry-run|-n) dry=1; shift ;;
    --focus) foc=--focus; shift ;;
    *) positional+=("$1"); shift ;;
  esac
done
set -- "${positional[@]}"
proj="${1:?usage: spawn-task.sh <project> <branch> [job-class] [agent|command...]}"
branch="${2:?usage: spawn-task.sh <project> <branch> [job-class] [agent|command...]}"
job="${3:-implement}"
shift 3 2>/dev/null || shift $#
rest=("$@"); [ "${#rest[@]}" -eq 0 ] && rest=(claude)
agent="${rest[0]}"

# ---- MODEL MAP (job-class -> model / reasoning-effort) ----------------------
# Table lives in lib/agent-profiles.sh (model_for_agent); this wrapper only
# adds the --model/--effort override, which is local to this invocation.
model_for() {  # <agent> <job> -> "<model>" or "<model>:<effort>"
  if [ -n "$model_override" ]; then
    printf '%s' "$model_override"; [ -n "$effort_override" ] && printf ':%s' "$effort_override"
    return
  fi
  model_for_agent "$1" "$2"
}

# ---- build the launch command line -----------------------------------------
# cli_for_agent (lib/agent-profiles.sh) knows the launch flags for a
# recognized agent (claude/codex/omp today); anything else falls through
# unchanged as a literal command, same as before.
m=$(model_for "$agent" "$job")
if cli=$(cli_for_agent "$agent" "$m"); then
  # extra flags/args after the agent name (e.g. `... implement claude
  # --some-flag`) used to be silently dropped — only the unrecognized-agent
  # fallback below ever consumed them.
  [ "${#rest[@]}" -gt 1 ] && cli="$cli ${rest[*]:1}"
else
  cli="${rest[*]}"  # literal command; no model mapping
fi

# repo_root (lib/repo-root.sh): --show-toplevel alone returns a linked
# worktree's own path, not the shared main-repo root — calling spawn-task.sh
# against an existing task worktree would then scatter the new worktree
# under the sub-worktree's name instead of the real project's.
root=$(repo_root "$proj")
[ -d "$root/.git" ] || git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { echo "spawn-task: not a git repo: $root" >&2; exit 1; }
wt="${HERDR_WT_DIR:-$HOME/.herdr/worktrees}/$(basename "$root")/${branch}"
label="${job}:${branch}"
events_file="$wt/.omc/handoffs/events.jsonl"
wake_pattern="${label}_done"

# ---- task identity (control-plane registration) -----------------------------
# A bare pane_id is not a durable identity: herdr reuses pane ids once a pane
# closes, so a delayed wake or answer can land on an unrelated future
# process. Register a real identity — run/task/worker/conductor id plus the
# worker pane's BIRTH fingerprint (herdr's terminal_id, unique per pane
# instance, never reused) — in the CENTRAL run registry (lib/run-registry.sh),
# not inside this worktree. See docs/control-plane-design.md.
#
# HERDR_RUN_ID lets a conductor group several spawn-task.sh calls under one
# run (export it once per orchestration session); otherwise each spawn gets
# its own run.
run_id="${HERDR_RUN_ID:-$(gen_id run)}"
task_id=$(gen_id task)
worker_id=$(gen_id worker)
conductor_pane_id="${HERDR_PANE_ID:-}"
conductor_id="${HERDR_CONDUCTOR_ID:-conductor_${conductor_pane_id:-unknown}}"

# The conductor pane's birth fingerprint (herdr's terminal_id), captured NOW
# so the push-wake edge (agent-hooks/claude-notify.sh) can revalidate it
# immediately before delivery — conductor_pane_id is exactly as recyclable as
# the worker's own pane_id, and a fingerprint recorded only for the worker
# side leaves the wake-delivery direction with nothing to check against.
# Empty when not spawned from inside a herdr pane, same as conductor_pane_id.
conductor_pane_birth=""
if [ -n "$conductor_pane_id" ]; then
  conductor_pane_birth=$(herdr pane list 2>/dev/null | jq -r --arg p "$conductor_pane_id" \
    '(.result.panes // .panes)[]? | select(.pane_id==$p) | .terminal_id // empty' 2>/dev/null)
fi

if [ "$dry" = 1 ]; then
  echo "spawn-task (dry-run):"
  echo "  repo      : $root"
  echo "  worktree  : $wt   (branch ${branch}${base:+ off ${base}})"
  echo "  workspace : $(bash "$here/ensure-workspace.sh" --no-focus "$root" 2>/dev/null || echo '<would create>')"
  echo "  tab label : $label"
  echo "  launch    : $cli"
  echo "  wake      : $here/wake-on-evidence.sh $events_file '$wake_pattern'"
  echo "  registry  : run=$run_id task=$task_id conductor_pane=${conductor_pane_id:-<none — not running inside a herdr pane>} conductor_pane_birth=${conductor_pane_birth:-<none>}"
  exit 0
fi

# ---- worktree: create or reuse ---------------------------------------------
if git -C "$root" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt"; then
  :  # already checked out here
elif git -C "$root" show-ref --verify --quiet "refs/heads/${branch}"; then
  git -C "$root" worktree add "$wt" "$branch" >/dev/null 2>&1 || { echo "spawn-task: worktree add (existing branch) failed" >&2; exit 1; }
else
  git -C "$root" worktree add -b "$branch" "$wt" ${base:+"$base"} >/dev/null 2>&1 || { echo "spawn-task: worktree add -b failed" >&2; exit 1; }
fi

# ---- coordination scaffold --------------------------------------------------
# The herdr-ops protocol: a worker appends its completion event to its own
# .omc/handoffs/events.jsonl; the conductor watches that FILE via
# wake-on-evidence.sh (never `wait output --match`, which false-fires on the
# kick-off echo quoting the marker). That only works if the directory exists
# and the conductor remembers the exact command — both silently fall on the
# orchestrator otherwise, which is how a whole day gets spent polling panes.
mkdir -p "$(dirname "$events_file")"

# ---- workspace + tab (sub-tab in the repo's space) -------------------------
ws=$(bash "$here/ensure-workspace.sh" --no-focus "$root") || exit 1
tc=$(herdr tab create --workspace "$ws" --cwd "$wt" --label "$label" "$foc" 2>/dev/null)
tab=$(printf '%s' "$tc" | jq -r '.result.tab.tab_id // empty')
pane=$(printf '%s' "$tc" | jq -r '.result.root_pane.pane_id // empty')
pane_birth=$(printf '%s' "$tc" | jq -r '.result.root_pane.terminal_id // empty')
[ -n "$tab" ] && [ -n "$pane" ] || { echo "spawn-task: tab create failed in $ws" >&2; exit 1; }

register_task "$run_id" "$task_id" "$worker_id" "$conductor_id" "$conductor_pane_id" "$conductor_pane_birth" \
  "$pane" "$pane_birth" "$root" "$wt" "$label"

# ---- launch the agent in the tab -------------------------------------------
# Stamp identity into the worker's own shell so its hooks (agent-hooks/
# claude-notify.sh, agent-hooks/omp-notify.sh) can push a wake to the conductor
# pane on input-needed, and can log against the same run/task the conductor is
# watching.
#
# HERDR_PANE_ID is the worker's OWN pane, and it was missing here until
# 2026-08-01 — a latent gap that only showed up once something depended on it:
#   * agent-hooks/omp-notify.sh cannot verify that a prompt actually painted
#     without knowing which pane to read, and refuses to alert blind, so the
#     ENTIRE omp push path silently no-opped for every spawned worker.
#   * lib/push-wake.sh captures prompt_id only when this is set, so for spawned
#     Claude workers it was always empty — meaning --expect-prompt-id, the whole
#     TOCTOU close, could never actually be used from a push wake.
#   * the wake text names the worker's pane so the conductor knows where to
#     look; unset, it read "(?)".
# Cheap to stamp, and three separate features quietly depended on it.
#
# %q-quote every interpolated value — label/branch/job are CLI-supplied and
# land inside a string that gets TYPED into the freshly spawned worker's
# live shell (herdr pane run, below). A single quote in $label (e.g. a
# branch name containing one) previously broke out of the naive
# 'single-quoted' interpolation and executed arbitrary commands in the new
# pane — verified exploitable, fixed here.
stamped_cli=$(printf 'export HERDR_RUN_ID=%q HERDR_TASK_ID=%q HERDR_WORKER_ID=%q HERDR_CONDUCTOR_ID=%q HERDR_CONDUCTOR_PANE_ID=%q HERDR_PANE_ID=%q HERDR_TASK_LABEL=%q; %s' \
  "$run_id" "$task_id" "$worker_id" "$conductor_id" "$conductor_pane_id" "$pane" "$label" "$cli")
herdr pane run "$pane" "$stamped_cli" >/dev/null 2>&1 || { echo "spawn-task: launch failed: $cli" >&2; exit 1; }
herdr pane report-agent "$pane" --source "$HERDR_SOURCE" --agent "$label" --state working >/dev/null 2>&1 || true
set_task_state "$run_id" "$task_id" "running"

bgtag="background"; [ "$foc" = --focus ] && bgtag="focused"
printf 'spawned %-22s ws=%s tab=%s pane=%s  [%s]\n' "$label" "$ws" "$tab" "$pane" "$bgtag"
printf '  worktree: %s\n  launch:   %s\n' "$wt" "$cli"
printf '  wake:     %s %s '"'"'%s'"'"'\n' "$here/wake-on-evidence.sh" "$events_file" "$wake_pattern"
printf '  worker on completion appends to %s, e.g.:\n' "$events_file"
printf '    {"event":"%s", ...}\n' "$wake_pattern"
printf '  registry: %s  (run=%s task=%s)\n' "$(registry_db)" "$run_id" "$task_id"
printf '  conductor: %s%s\n' "${conductor_pane_id:-<none — spawned outside a herdr pane, no push wake>}" \
  "${conductor_pane_id:+ (push wake wired if the worker hits an input-needed event)}"
