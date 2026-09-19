#!/usr/bin/env bash
# spawn-task.sh <project> <branch> [job-class] [agent-or-command...] [--base REF] [--dry-run] [--focus] [--no-secrets]
#
# Every worker starts with the 1Password service-account identity (one vault,
# 249 items, READ-ONLY) so an unattended run never stops to ask for a
# credential. `--no-secrets` withholds it — use it when the task handles
# material we did not write (third-party code review, a scrape, anything
# parsing untrusted input). See lib/op-env.sh for why the default is ON.
#
# Spin a task into its own WORKTREE, opened as a TAB inside the project's own
# workspace (a "sub-tab", not a separate space), running the right model at
# the right job-class tier. This is the orchestrator's per-task hand:
#
#   spawn-task.sh ~/Code/myproject fix-parser implement           # claude flavor, sonnet, under omp
#   spawn-task.sh ~/Code/myproject arch-review review codex       # codex flavor, deep model, under omp
#   spawn-task.sh ~/Code/myproject fix-worker implement omp       # omp, sonnet
#   spawn-task.sh ~/Code/myproject probe quick pwd                # literal cmd (no model)
#
# `claude`/`codex` are MODEL FAMILIES, not CLI binaries: both launch under the
# omp harness (lib/agent-profiles.sh's cli_for_agent) with `--models` set to
# the requested family plus its cross-family equivalent at the same
# job-class tier, so Ctrl+P swaps the live pane between them instead of
# locking a worker into whichever flavor was requested at spawn time. One
# approval surface, one push-hook, one answering convention for every worker
# this script spawns — `omc` is the only agent that still launches its own
# native binary (Claude Code + OMC's hook/skill system, a harness in its own
# right, not a bare CLI to wrap).
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
# (Claude/omp tiers are model-name aliases omp fuzzy-matches; Codex model
# names live in config.sh and are launched via omp's `openai-codex/<model>`
# provider prefix. Known agents live in lib/agent-profiles.sh — add a new one
# there, not in this file.)
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
. "$here/lib/handoff.sh"
. "$here/lib/op-env.sh"

# ---- args ------------------------------------------------------------------
# op_mode inherits TIGHTEN-ONLY, the same shape as HERDR_POSTURE_FLOOR: a worker
# spawned with --no-secrets exports HERDR_SECRETS_WITHHELD=1, so a child spawn
# it makes cannot re-grant the credential to itself. Only an explicit
# --secrets, typed by a human or a conductor that holds it, lifts that.
secrets_req=""
[ "${HERDR_SECRETS_WITHHELD:-}" = 1 ] && secrets_req=withhold
base=""; dry=0; model_override=""; effort_override=""; posture_req=""; foc=--no-focus; positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --model) model_override="$2"; shift 2 ;;
    --effort) effort_override="$2"; shift 2 ;;
    --posture) posture_req="${2:?spawn-task: --posture needs a value (yolo|write|strict)}"; shift 2 ;;
    # Credential posture for this spawn — see lib/op-env.sh for why the managed
    # default is ON and the unmanaged default is OFF.
    --no-secrets) secrets_req=withhold; shift ;;
    --secrets) secrets_req=grant; shift ;;
    --dry-run|-n) dry=1; shift ;;
    --focus) foc=--focus; shift ;;
    # Everything after `--` belongs to the worker's own command, flags included.
    # Without this, `spawn-task.sh ~/repo t quick ./tool --no-secrets` silently
    # ate the worker's argument and changed this spawn's credential posture.
    --) shift; positional+=("$@"); break ;;
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
# --effort works STANDALONE: it replaces the effort part of whatever model
# the job-class (or --model) resolved to. It used to be silently dropped
# unless --model was also passed.
model_for() {  # <agent> <job> -> "<model>" or "<model>:<effort>"
  local spec
  if [ -n "$model_override" ]; then spec="$model_override"; else spec=$(model_for_agent "$1" "$2"); fi
  if [ -n "$effort_override" ]; then printf '%s:%s' "${spec%%:*}" "$effort_override"; else printf '%s' "$spec"; fi
}

# ---- build the launch command line -----------------------------------------
# cli_for_agent (lib/agent-profiles.sh) knows the launch flags for a
# recognized agent (claude/codex/omc/omp today) and emits every token
# %q-quoted — safe to type into the worker's live shell. Anything else falls
# through unchanged as a literal command: that path is EXPLICITLY UNMANAGED
# (no posture flag, no canonical rules, raw shell string) and is reported as
# such below rather than dressed up as enforced.
m=$(model_for "$agent" "$job")
managed=1
if cli=$(cli_for_agent "$agent" "$m" "$posture_req"); then
  # Extra flags/args after the agent name ride along %q-quoted — EXCEPT
  # flags that would override the approval posture, rule/extension loading,
  # or the system-prompt channel this script composes (managed_flag_rejected,
  # lib/agent-profiles.sh). Those are refused loudly: a launch that LOOKS
  # floor-governed must actually be floor-governed.
  if [ "${#rest[@]}" -gt 1 ]; then
    for _x in "${rest[@]:1}"; do
      if managed_flag_rejected "$_x"; then
        echo "spawn-task: refusing managed extra flag '$_x' — it would override approval posture, rules/extensions, or system context." >&2
        echo "spawn-task: tighten with --posture <yolo|write|strict>, or run an explicitly UNMANAGED literal command if you really mean it." >&2
        exit 1
      fi
      cli="$cli $(printf '%q' "$_x")"
    done
  fi
else
  managed=0
  cli="${rest[*]}"  # literal command; no model mapping, no posture flag, no rules append
fi

# ---- credential posture ------------------------------------------------------
# ON for a MANAGED launch, OFF for an UNMANAGED one, either overridable.
#
# The asymmetry is the whole point (security review 2026-09-19, SPAWN-OPENV-005).
# A managed launch runs behind the posture ladder and lib/command-policy.sh, so
# credential-VALUE access still stops for a human, and the unattended-run
# argument for default-ON was measured on exactly that path. An unmanaged
# literal command has, by this script's own admission above, no posture flag and
# no approval surface — `spawn-task.sh ~/repo t quick 'curl -s https://x | sh'`
# would otherwise run with a vault credential in its environment and nothing
# between the two. Say --secrets if that is genuinely what you want.
op_mode=withhold
if [ "$managed" = 1 ] && [ "$secrets_req" != withhold ]; then op_mode=""; fi
if [ "$secrets_req" = grant ]; then op_mode=""; fi
# Inherited withholding is tighten-only: --secrets cannot lift a parent's.
[ "${HERDR_SECRETS_WITHHELD:-}" = 1 ] && op_mode=withhold
secrets_note="service account (read-only, 1 vault) — op resolves with no human"
[ "$op_mode" = withhold ] && secrets_note="WITHHELD — token not placed in this worker's environment (the 600-mode file stays readable by this uid; not a sandbox)"
# The posture actually in force for this spawn (floor composed with the
# request — can only tighten). Stamped into the worker below as ITS floor,
# so a child spawn from inside the worktree can tighten further but never
# loosen past what this spawn was granted.
eff_posture=$(resolved_posture "$posture_req")

# repo_root (lib/repo-root.sh): --show-toplevel alone returns a linked
# worktree's own path, not the shared main-repo root — calling spawn-task.sh
# against an existing task worktree would then scatter the new worktree
# under the sub-worktree's name instead of the real project's.
root=$(repo_root "$proj")
# AN EMPTY ROOT IS NOT THE CURRENT DIRECTORY. `repo_root` fails on a bare name
# (`spawn-task.sh tntpgh-dev ...` — the first argument is a PATH), leaving
# `$root` empty, and the guard below then PASSED: `git -C "" rev-parse` runs in
# the caller's cwd and succeeds, so a spawn from inside any repo was accepted.
# The worktree path became `~/.herdr/worktrees//review/pr520` — an empty
# project segment — and everything downstream, including the wake pattern and
# the events bus, pointed there. Measured 2026-09-16 when it cost a
# re-dispatch; the dry run printed the malformed path and proceeded.
[ -n "$root" ] || {
  echo "spawn-task: could not resolve a repo root from '$proj'." >&2
  echo "  The first argument is a PATH, not a repo name: ~/Code/<repo>" >&2
  exit 1; }
[ -d "$root/.git" ] || git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { echo "spawn-task: not a git repo: $root" >&2; exit 1; }
wt="${HERDR_WT_DIR:-$HOME/.herdr/worktrees}/$(basename "$root")/${branch}"
# BELT, because the layout is herdr's and this builds it by hand. herdr owns
# `~/.herdr/worktrees/<repo>/<branch>` and `herdr worktree create` returns the
# path it chose; eliasstravik/herdr-projects records that return value and
# never composes the path, which is the more durable shape — if herdr changes
# the layout, a built path silently diverges from the real one. Migrating this
# to `herdr worktree create` changes workspace and tab semantics (labels,
# focus, the posture stamp) and is its own change; until then, refuse a path
# with an empty segment rather than create one.
case "$wt" in
  *//*|*/) echo "spawn-task: refusing a malformed worktree path: $wt" >&2; exit 1 ;;
esac
label="${job}:${branch}"
events_file=$(handoff_events "$wt")
wake_pattern="${label}_done"

# ---- canonical operator ancestor rules (managed launches only) --------------
# The worktree above lives OUTSIDE the project's ancestor tree, so the
# worker's upward rule discovery cannot reach the operator's ancestor
# AGENTS.md (this fleet: ~/Code/AGENTS.md). canonical_rules_resolve
# (lib/agent-profiles.sh) derives the source from the ORIGINAL project
# root's ancestors — or takes an inherited/explicit HERDR_CANONICAL_RULES
# path — composes it with a provenance header, and hands back an
# --append-system-prompt flag. A configured source that is missing or
# unreadable FAILS the spawn: launching without the operator's rules while
# looking managed is the dishonest direction.
CANONICAL_RULES_SRC="" CANONICAL_RULES_ARGS=""
if [ "$managed" = 1 ]; then
  canonical_rules_resolve "$agent" "$root" || {
    echo "spawn-task: canonical rules source configured but unusable — refusing managed launch" >&2
    exit 1
  }
  [ -n "$CANONICAL_RULES_ARGS" ] && cli="$cli $CANONICAL_RULES_ARGS"
fi

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
  if [ "$managed" = 1 ]; then
    echo "  launch    : $cli"
    echo "  posture   : $eff_posture  (floor ${HERDR_POSTURE_FLOOR:-write}, request ${posture_req:-none}; stamped into the worker as HERDR_POSTURE_FLOOR — child spawns can only tighten)"
    echo "  rules     : ${CANONICAL_RULES_SRC:-<none — no ancestor AGENTS.md found/configured; normal project discovery only>}"
  else
    echo "  launch    : $cli"
    echo "  ⚠ UNMANAGED literal command: no posture flag, no canonical rules append — only the env floor stamp reaches it"
  fi
  # Outside the managed/unmanaged branch on purpose: the UNMANAGED path is the
  # one where the credential posture matters MOST, and reporting it only for
  # managed launches is how a silent grant goes unnoticed.
  echo "  secrets   : $secrets_note"
  echo "  wake      : $here/wake-on-evidence.sh $events_file '$wake_pattern'"
  echo "              ^ run BACKGROUNDED (run_in_background/async:true) — a blocking"
  echo "                foreground call strands you idle until re-prompted by hand"
  echo "  registry  : run=$run_id task=$task_id conductor_pane=${conductor_pane_id:-<none — not running inside a herdr pane>} conductor_pane_birth=${conductor_pane_birth:-<none>}"
  exit 0
fi

# ---- worktree: create or reuse ---------------------------------------------
# A NEW branch is cut from origin's default branch, never from the local
# checkout's HEAD: the local checkout is routinely a dirty, stale lane (2026-09-05:
# knowledge-base's was 76 commits behind, so a worker spent its first minutes
# hunting for files that only existed on origin/main). --base still overrides.
if [ -z "$base" ] && ! git -C "$root" show-ref --verify --quiet "refs/heads/${branch}"; then
  git -C "$root" fetch -q origin 2>/dev/null || echo "spawn-task: fetch failed — basing on the last-known origin ref" >&2
  def=$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); def=${def#origin/}
  if [ -z "$def" ]; then
    def=$(git -C "$root" remote show origin 2>/dev/null | sed -n 's/^ *HEAD branch: //p')
  fi
  if [ -n "$def" ] && git -C "$root" show-ref --verify --quiet "refs/remotes/origin/${def}"; then
    base="origin/${def}"
  else
    echo "spawn-task: could not resolve origin's default branch — basing on local HEAD (pass --base to be explicit)" >&2
  fi
fi
if git -C "$root" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt"; then
  :  # already checked out here
elif git -C "$root" show-ref --verify --quiet "refs/heads/${branch}"; then
  git -C "$root" worktree add "$wt" "$branch" >/dev/null 2>&1 || { echo "spawn-task: worktree add (existing branch) failed" >&2; exit 1; }
else
  git -C "$root" worktree add -b "$branch" "$wt" ${base:+"$base"} >/dev/null 2>&1 || { echo "spawn-task: worktree add -b failed" >&2; exit 1; }
fi

# ---- coordination scaffold --------------------------------------------------
# The herdr-ops protocol: a worker appends its completion event to its own
# .handoffs/events.jsonl (lib/handoff.sh — was .omc/handoffs, a third-party
# harness's state root); the conductor watches that FILE via
# wake-on-evidence.sh (never `wait output --match`, which false-fires on the
# kick-off echo quoting the marker), run via the harness's own background/
# async job facility, NEVER blocking foreground. That only works if the
# directory exists, the conductor remembers the exact command, AND runs it
# backgrounded — all three silently fall on the orchestrator otherwise.
# Forgetting the command means polling panes by hand all day; running it in
# the foreground is subtler and just as costly — it looks armed right up
# until it returns and leaves the conductor idle, needing the operator to
# manually re-prompt every single time (observed live, 2026-08-06). The
# printed hint below is flagged BACKGROUNDED for exactly this reason.
mkdir -p "$(dirname "$events_file")"
# Self-ignoring bus directory. `.omc/` was already in each repo's .gitignore,
# so the old path was invisible to `git status` by accident of the vendor's
# name being listed there; `.handoffs/` is in nobody's. Rather than open 16
# .gitignore PRs (and still miss the next repo), the directory ignores itself:
# a `*` pattern inside it also matches the .gitignore file, so git reports the
# whole thing as nothing. A worker then can't accidentally commit its own
# coordination log into the branch it was sent to write.
printf '*\n' > "$(dirname "$events_file")/.gitignore"

# ---- workspace + tab (sub-tab in the repo's space) -------------------------
ws=$(bash "$here/ensure-workspace.sh" --no-focus "$root") || exit 1
tc=$(herdr tab create --workspace "$ws" --cwd "$wt" --label "$label" "$foc" 2>/dev/null)
tab=$(printf '%s' "$tc" | jq -r '.result.tab.tab_id // empty')
pane=$(printf '%s' "$tc" | jq -r '.result.root_pane.pane_id // empty')
pane_birth=$(printf '%s' "$tc" | jq -r '.result.root_pane.terminal_id // empty')
[ -n "$tab" ] && [ -n "$pane" ] || { echo "spawn-task: tab create failed in $ws" >&2; exit 1; }

register_task "$run_id" "$task_id" "$worker_id" "$conductor_id" "$conductor_pane_id" "$conductor_pane_birth" \
  "$pane" "$pane_birth" "$root" "$wt" "$label"

# ---- close an empty default root tab, if this call just created one --------
# ensure-workspace.sh's own comment already names this gap: "herdr
# auto-creates a root tab as part of workspace creation but gives it no
# label of its own" — that script does a best-effort rename, but the tab
# itself stays open and empty forever once THIS sub-tab is the one doing
# real work. Best-effort, non-fatal, scoped tight: only closes a tab in
# THIS workspace that is not the one just created AND has no agent set at
# all (never ran anything) — a genuinely reused, active workspace with real
# other work in it never loses a tab here, because that tab will have an
# agent.
for _t in $(herdr tab list 2>/dev/null | jq -r --arg ws "$ws" --arg keep "$tab" \
    '(.result.tabs // .tabs)[] | select(.workspace_id==$ws and .tab_id!=$keep) | .tab_id' 2>/dev/null); do
  _agent=$(herdr pane list 2>/dev/null | jq -r --arg t "$_t" \
    '(.result.panes // .panes)[] | select(.tab_id==$t) | .agent // empty' 2>/dev/null | head -1)
  [ -z "$_agent" ] && herdr tab close "$_t" >/dev/null 2>&1
done
true

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
#
# Besides identity, the stamp carries the OPERATOR POLICY a child herdr
# launch from inside this worktree needs (nothing secret goes in here):
#   * HERDR_POSTURE_FLOOR = this spawn's EFFECTIVE posture — the child's
#     floor is what this worker was actually granted, so a descendant can
#     tighten but never loosen past it (lib/posture.sh composes only
#     stricter).
#   * HERDR_POLICY_EXTRA_RULES = the operator's extra command-policy rules
#     (stricter-only by construction, lib/command-policy.sh) — only when set.
#   * HERDR_CANONICAL_RULES = the resolved canonical rules SOURCE path, so a
#     descendant spawn keeps the same explicit operator source instead of
#     re-deriving from a possibly different tree — only when one resolved.
stamped_cli=$(printf 'export HERDR_RUN_ID=%q HERDR_TASK_ID=%q HERDR_WORKER_ID=%q HERDR_CONDUCTOR_ID=%q HERDR_CONDUCTOR_PANE_ID=%q HERDR_PANE_ID=%q HERDR_TASK_LABEL=%q HERDR_POSTURE_FLOOR=%q' \
  "$run_id" "$task_id" "$worker_id" "$conductor_id" "$conductor_pane_id" "$pane" "$label" "$eff_posture")
[ -n "${HERDR_POLICY_EXTRA_RULES:-}" ] && stamped_cli="$stamped_cli $(printf 'HERDR_POLICY_EXTRA_RULES=%q' "$HERDR_POLICY_EXTRA_RULES")"
[ -n "$CANONICAL_RULES_SRC" ] && stamped_cli="$stamped_cli $(printf 'HERDR_CANONICAL_RULES=%q' "$CANONICAL_RULES_SRC")"
# The op prelude runs FIRST (lib/op-env.sh): a worker that has to hunt for a
# credential stops and asks a human, which is the one thing an unattended run
# cannot afford. Measured 2026-09-19 — a spawned worker doing DB work found no
# token, went looking for .env.local (gitignored, so absent from every linked
# worktree), and produced four credential-shaped approval prompts.
stamped_cli="$(op_env_prelude "$op_mode") $stamped_cli; $cli"
herdr pane run "$pane" "$stamped_cli" >/dev/null 2>&1 || { echo "spawn-task: launch failed: $cli" >&2; exit 1; }
herdr pane report-agent "$pane" --source "$HERDR_SOURCE" --agent "$label" --state working >/dev/null 2>&1 || true

# Best-effort agent_session capture — herdr reports this natively for
# claude/codex (empty for omp today) once the CLI has actually started
# reporting in, which can lag a beat behind the launch above. A short,
# bounded poll rather than one immediate read: reconcile.sh's corroboration
# check (lib/reconcile.sh) is the thing that actually NEEDS this to survive a
# herdr crash+restart, and it also opportunistically backfills any task still
# missing one later — so a miss here is degraded, not broken, and never worth
# blocking or failing the spawn over.
agent_session=""
for _ in 1 2 3 4 5; do
  agent_session=$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.agent_session.value // empty')
  [ -n "$agent_session" ] && break
  sleep 0.4
done
[ -n "$agent_session" ] && set_task_agent_session "$run_id" "$task_id" "$agent_session"

set_task_state "$run_id" "$task_id" "running"

bgtag="background"; [ "$foc" = --focus ] && bgtag="focused"
printf 'spawned %-22s ws=%s tab=%s pane=%s  [%s]\n' "$label" "$ws" "$tab" "$pane" "$bgtag"
printf '  worktree: %s\n  launch:   %s\n' "$wt" "$cli"
if [ "$managed" = 1 ]; then
  printf '  posture:  %s  (floor %s, request %s; stamped as the worker'"'"'s own floor)\n' \
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
printf '  secrets:  %s\n' "$secrets_note"
printf '  wake:     %s %s '"'"'%s'"'"'\n' "$here/wake-on-evidence.sh" "$events_file" "$wake_pattern"
printf '            ^ run BACKGROUNDED (run_in_background/async:true) — a blocking\n'
printf '              foreground call strands you idle until re-prompted by hand\n'
printf '  worker on completion appends to %s, e.g.:\n' "$events_file"
printf '    {"event":"%s", ...}\n' "$wake_pattern"
printf '  ⚠ if this task'"'"'s own effect removes its OWN worktree (e.g. "delete\n'
printf '    this now-redundant branch"), %s is gone with it —\n' "$events_file"
printf '    verify completion via outer repo state (git branch -a / git log) instead,\n'
printf '    or have the task call append_event() from lib/run-registry.sh directly\n'
printf '    (writes to the central registry, survives worktree removal) before it\n'
printf '    removes its own worktree.\n'
printf '  registry: %s  (run=%s task=%s)\n' "$(registry_db)" "$run_id" "$task_id"
printf '  conductor: %s%s\n' "${conductor_pane_id:-<none — spawned outside a herdr pane, no push wake>}" \
  "${conductor_pane_id:+ (push wake wired if the worker hits an input-needed event)}"
