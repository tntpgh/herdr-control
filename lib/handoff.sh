#!/usr/bin/env bash
# handoff.sh — where the worker→conductor completion bus lives.
#
# It used to live at `<worktree>/.omc/handoffs/events.jsonl`. `.omc` is the
# hardcoded state root of a third-party Claude Code package
# (oh-my-claude-sisyphus); we run omp, herdr can drive any CLI (config.sh's
# HERDR_AGENT_CMD: omp · claude · codex · aider), and the protocol is ours.
# Naming our own bus after someone else's harness meant a worker on a machine
# without that package still wrote into a directory named for it, and the
# 2026-09-09 retirement of that package nearly swept the bus with it.
#
# Canonical path is now `<worktree>/.handoffs/events.jsonl`, overridable with
# HERDR_HANDOFF_DIR (a directory NAME relative to the worktree, not a path).
#
# Compatibility, deliberately asymmetric: we WRITE only the canonical path and
# READ both. A worker spawned before this change was briefed with the legacy
# path and is still running; dropping the read side would silently mark it
# lost. Delete the legacy half once no in-flight worker predates it.

HANDOFF_LEGACY_REL=".omc/handoffs"

handoff_rel() { printf '%s\n' "${HERDR_HANDOFF_DIR:-.handoffs}"; }

# Directory the spawn creates and the worker appends into.
handoff_dir() { printf '%s/%s\n' "${1%/}" "$(handoff_rel)"; }

# The canonical events file — the one briefs name and watchers are pointed at.
handoff_events() { printf '%s/%s/events.jsonl\n' "${1%/}" "$(handoff_rel)"; }

# Every events file a READER must consider: canonical first, then legacy when
# it exists. Prints nothing for a worktree that has neither.
handoff_event_files() {                # worktree -> 0..2 paths, newest scheme first
  local wt="${1%/}" f
  f="$(handoff_events "$wt")"
  [ -r "$f" ] && printf '%s\n' "$f"
  f="$wt/$HANDOFF_LEGACY_REL/events.jsonl"
  [ -r "$f" ] && printf '%s\n' "$f"
  return 0
}
