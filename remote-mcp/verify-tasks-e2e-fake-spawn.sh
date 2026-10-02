#!/usr/bin/env bash
# Stand-in for spawn-task.sh used ONLY by verify-tasks-e2e.py.
# register_task() and the identity.json write are REAL (lib/run-registry.sh,
# unmodified) -- only the pane/tab/agent launch itself is skipped, since
# that is the one piece SPEC.md's Acceptance item 2 explicitly defers to
# the conductor's live e2e. argv mirrors tasks.py's _spawn(): root branch
# job_class claude --no-focus --approval menu --brief <path> [--secrets].
#
# $wt is a REAL git repository with a real "trunk" branch and a non-empty
# `trunk` passed to register_task -- not just a bare directory. Without
# this, close-done-workers.sh's own git plumbing has nothing to resolve and
# correctly HOLDs the task forever (2026-10-02: the first version of this
# fixture caught a real close-done-workers.sh bug precisely because it was
# too unrealistic here; this version proves the FIXED behavior for real).
# `.handoffs/.gitignore` (`*`) is committed up front so a worker's own
# .handoffs/ writes (ANSWER.md, events.jsonl, identity.json) never dirty
# the tree, matching verify-close-done-workers.sh's own fixture.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/run-registry.sh
. "$HERE/lib/run-registry.sh"

root="$1" branch="$2"
repo_name=$(basename "$root")
wt="${HERDR_WT_DIR:?HERDR_WT_DIR must be set to a scratch dir}/$repo_name/$branch"
mkdir -p "$(dirname "$wt")"

trunk=main
git init -q -b "$trunk" "$wt"
mkdir -p "$wt/.handoffs"
printf '*\n' > "$wt/.handoffs/.gitignore"
git -C "$wt" -c user.email=e2e@test -c user.name=e2e add -f .handoffs/.gitignore
git -C "$wt" -c user.email=e2e@test -c user.name=e2e commit -q -m init
git -C "$wt" switch -q -c "$branch"

run_id="run_e2e_$(date -u +%Y%m%dT%H%M%SZ)_$$"
task_id="task_e2e_$(date -u +%Y%m%dT%H%M%SZ)_$$_${RANDOM}"

register_task "$run_id" "$task_id" worker_e2e conductor_e2e "" "" \
  pane_e2e_fake birth_e2e_fake "$root" "$wt" e2e-label "$branch" "$trunk" \
  "$repo_name" "" menu

jq -n --arg run "$run_id" --arg task "$task_id" --arg event "e2e_done" \
  --arg events "$wt/.handoffs/events.jsonl" --arg worktree "$wt" \
  '{run_id:$run, task_id:$task, completion_event:$event,
    events_file:$events, worktree:$worktree}' \
  > "$wt/.handoffs/identity.json"
: > "$wt/.handoffs/events.jsonl"
