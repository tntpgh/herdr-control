#!/usr/bin/env bash
# spawn-task.sh <project> <branch> [job-class] [agent-or-command...] [--base REF] [--dry-run]
#
# Spin a task into its own WORKTREE, opened as a TAB inside the project's own
# workspace (a "sub-tab", not a separate space), running the right agent at the
# right model for the job. This is the orchestrator's per-task hand:
#
#   spawn-task.sh ~/Code/tourguide fix-comps implement           # claude, sonnet
#   spawn-task.sh ~/Code/tourguide arch-review review codex      # codex, deep model
#   spawn-task.sh ~/Code/tourguide probe quick pwd               # literal cmd (no model)
#
# job-class -> model (edit MODEL MAP below; --model/--effort override):
#   plan|architect|review|design  -> claude opus    · codex $HERDR_CODEX_DEEP
#   implement|debug|code          -> claude sonnet  · codex $HERDR_CODEX_STD
#   explore|quick|mechanical|docs -> claude haiku   · codex $HERDR_CODEX_FAST
# (Claude tiers are standard aliases; Codex model names live in config.sh.)
#
# herdr's native `worktree create` always makes a SEPARATE space; to get a sub-tab
# we do `git worktree add` + `tab create --workspace <repo-ws>` ourselves. Each tab
# is a real branch checkout, so sort-tabs/mark-tab treat it as a first-class tab.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/run-registry.sh"

# ---- args ------------------------------------------------------------------
base=""; dry=0; model_override=""; effort_override=""; positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --model) model_override="$2"; shift 2 ;;
    --effort) effort_override="$2"; shift 2 ;;
    --dry-run|-n) dry=1; shift ;;
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
model_for() {  # <agent> <job> -> "<model>" or "<model>:<effort>"
  local a="$1" j="$2"
  if [ -n "$model_override" ]; then
    printf '%s' "$model_override"; [ -n "$effort_override" ] && printf ':%s' "$effort_override"; return
  fi
  case "$a:$j" in
    claude:plan|claude:architect|claude:review|claude:design) echo opus ;;
    claude:implement|claude:debug|claude:code)                echo sonnet ;;
    claude:explore|claude:quick|claude:mechanical|claude:docs) echo haiku ;;
    claude:*)                                                 echo sonnet ;;
    codex:plan|codex:architect|codex:review|codex:design)     echo "$HERDR_CODEX_DEEP" ;;
    codex:implement|codex:debug|codex:code)                   echo "$HERDR_CODEX_STD" ;;
    codex:explore|codex:quick|codex:mechanical|codex:docs)    echo "$HERDR_CODEX_FAST" ;;
    codex:*)                                                  echo "$HERDR_CODEX_STD" ;;
  esac
}

# ---- build the launch command line -----------------------------------------
case "$agent" in
  claude)
    m=$(model_for claude "$job")
    cli="claude --model ${m} --permission-mode acceptEdits" ;;
  codex)
    me=$(model_for codex "$job"); m="${me%%:*}"; e="${me##*:}"
    cli="codex -m ${m} -c model_reasoning_effort=${e}" ;;
  *)
    cli="${rest[*]}" ;;  # literal command; no model mapping
esac

root=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null || (cd "$proj" && pwd))
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
if git -C "$root" worktree list --porcelain 2>/dev/null | grep -qx "worktree $wt"; then
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
tc=$(herdr tab create --workspace "$ws" --cwd "$wt" --label "$label" --focus 2>/dev/null)
tab=$(printf '%s' "$tc" | jq -r '.result.tab.tab_id // empty')
pane=$(printf '%s' "$tc" | jq -r '.result.root_pane.pane_id // empty')
pane_birth=$(printf '%s' "$tc" | jq -r '.result.root_pane.terminal_id // empty')
[ -n "$tab" ] && [ -n "$pane" ] || { echo "spawn-task: tab create failed in $ws" >&2; exit 1; }

register_task "$run_id" "$task_id" "$worker_id" "$conductor_id" "$conductor_pane_id" "$conductor_pane_birth" \
  "$pane" "$pane_birth" "$root" "$wt" "$label"

# ---- launch the agent in the tab -------------------------------------------
# Stamp identity into the worker's own shell so its hooks (agent-hooks/
# claude-notify.sh) can push a wake to the conductor pane on input-needed,
# and can log against the same run/task the conductor is watching.
#
# %q-quote every interpolated value — label/branch/job are CLI-supplied and
# land inside a string that gets TYPED into the freshly spawned worker's
# live shell (herdr pane run, below). A single quote in $label (e.g. a
# branch name containing one) previously broke out of the naive
# 'single-quoted' interpolation and executed arbitrary commands in the new
# pane — verified exploitable, fixed here.
stamped_cli=$(printf 'export HERDR_RUN_ID=%q HERDR_TASK_ID=%q HERDR_WORKER_ID=%q HERDR_CONDUCTOR_ID=%q HERDR_CONDUCTOR_PANE_ID=%q HERDR_TASK_LABEL=%q; %s' \
  "$run_id" "$task_id" "$worker_id" "$conductor_id" "$conductor_pane_id" "$label" "$cli")
herdr pane run "$pane" "$stamped_cli" >/dev/null 2>&1 || { echo "spawn-task: launch failed: $cli" >&2; exit 1; }
herdr pane report-agent "$pane" --source "$HERDR_SOURCE" --agent "$label" --state working >/dev/null 2>&1 || true
set_task_state "$run_id" "$task_id" "running"

printf 'spawned %-22s ws=%s tab=%s pane=%s\n' "$label" "$ws" "$tab" "$pane"
printf '  worktree: %s\n  launch:   %s\n' "$wt" "$cli"
printf '  wake:     %s %s '"'"'%s'"'"'\n' "$here/wake-on-evidence.sh" "$events_file" "$wake_pattern"
printf '  worker on completion appends to %s, e.g.:\n' "$events_file"
printf '    {"event":"%s", ...}\n' "$wake_pattern"
printf '  registry: %s\n' "$(task_file "$run_id" "$task_id")"
printf '  conductor: %s%s\n' "${conductor_pane_id:-<none — spawned outside a herdr pane, no push wake>}" \
  "${conductor_pane_id:+ (push wake wired if the worker hits an input-needed event)}"
