#!/usr/bin/env bash
# launchd/resolve-hub-python.sh — the ONE place that decides which python3
# interpreter runs or compiles hub code. Every consumer calls this exact
# script instead of re-deriving the scan:
#   - launchd/agent-lib.sh's resolve_hub_python() (sourced by install.sh,
#     restart.sh, verify-deploy.sh) — a thin wrapper around this file;
#   - agent-hooks/omp-herdr-control.ts's ensureHub(), via spawnSync, before
#     it spawns hub.py at omp session start.
# "Pin an explicit interpreter" means pinned in ONE place. Before this file
# existed, bash had its own copy of the scan and the TS side spawned bare
# `python3` — two definitions of "the pinned interpreter" that could (and
# did, in review) drift apart the moment one was edited and the other
# wasn't.
#
# Enforces >=3.11 as part of THIS ONE scan (round 6 review: the registry
# wrapper had its own extra floor check the hub/remote-mcp/TS paths lacked —
# two definitions of "pinned enough" drifting the same way "pinned at all"
# once did). Checks the REAL version by running the candidate
# (`sys.version_info`), not the filename: a round 6 follow-up review caught
# that a filename-only check trusts `python3.14` even when that path is a
# symlink (or a stale/rebuilt binary) actually reporting 3.9 — the filename
# is what a directory listing claims, never what's proven. Every candidate
# in a directory is tried highest-named first; a directory whose highest
# NAMED candidate turns out to be a real sub-3.11 interpreter still tries
# the next-highest-named one in the SAME directory before moving on, since
# the name is no longer trusted to order real versions correctly either.
#
# Prints the resolved absolute interpreter path on stdout and exits 0, or
# prints nothing on stdout (diagnostic on stderr) and exits 1. NEVER prints
# `python3` or `/usr/bin/env python3` — those resolve through PATH with no
# guarantee of which interpreter answers, which is the bug this replaces:
# on a machine where Homebrew's generic `python3` symlink is missing, `env
# python3` silently lands on the CLT's /usr/bin/python3 3.9.6 while an
# interactive shell's `python3` is 3.14.
#
# HERDR_HUB_PYTHON_DIRS overrides the search path (colon-separated,
# default /opt/homebrew/bin:/usr/local/bin) — so a test can exercise this
# REAL script's fail-closed branch against empty scratch directories
# without touching the real /opt/homebrew or /usr/local on the dev
# machine, and so .github/workflows/remote-mcp.yml can point this same
# unmodified scan at actions/setup-python's install dir (neither
# /opt/homebrew nor /usr/local on an Ubuntu runner) instead of growing a
# second search path just for CI. Production (launchd-installed) code
# never sets it.
set -uo pipefail

IFS=':' read -r -a search_dirs <<< "${HERDR_HUB_PYTHON_DIRS:-/opt/homebrew/bin:/usr/local/bin}"
for dir in "${search_dirs[@]}"; do
  # `python3.N` has exactly TWO dot-fields (`python3`, `N`) — `-k3` addresses
  # a field that does not exist, so `sort -n` had no numeric key for ANY
  # candidate and silently fell through to `ls`'s alphabetical order:
  # `python3.9` sorted after `python3.14` lexically, so picking the LAST
  # entry chose the LOWER version whenever two were present (review finding
  # on f41370f/c7c9bd4 — this machine has only one installed minor, so
  # round 1/2's own proofs never had two candidates to catch it with).
  # `-k2,2nr` is the version field, numeric descending, explicitly bounded
  # so a future three-dot name cannot widen the key by accident.
  while IFS= read -r found; do
    [ -n "$found" ] || continue
    candidate="$dir/$found"
    [ -x "$candidate" ] || continue
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      exit 0
    fi
    # Named python3.N >= 11 but the REAL interpreter reports otherwise (a
    # lying symlink, or vice versa a conservatively-named real 3.11+): try
    # the next-highest-named candidate in this SAME directory before moving
    # on to the next search dir.
  done < <(ls "$dir" 2>/dev/null | grep -E '^python3\.[0-9]+$' | sort -t. -k2,2nr)
done
echo "resolve-hub-python: no python3.11+ interpreter found under ${search_dirs[*]}" >&2
exit 1
