#!/usr/bin/env bash
# archive-worktrees.sh — recoverably archive, then remove, linked git
# worktrees whose work is done. DRY-RUN BY DEFAULT.
# (2026-10-05-worktree-archival-and-detached-close proposal; fixed per
# reviews r1 and r2 of PR #236.)
#
#   archive-worktrees.sh                                  # preview every repo under ~/Code
#   archive-worktrees.sh ~/Code/herdr-control              # preview one repo
#   archive-worktrees.sh --apply ~/Code/herdr-control      # archive+remove the MERGED ones
#   archive-worktrees.sh --apply --branch=fix/x --disposition=abandoned ~/Code/herdr-control
#   archive-worktrees.sh --apply --worktree=<path> --disposition=superseded ~/Code/herdr-control
#   archive-worktrees.sh --apply --branch=fix/x --include-dirty ~/Code/herdr-control
#
# FAIL CLOSED. Anything this cannot verify — gh erroring, the registry
# unreadable, the pane list unparseable, origin unreachable, free disk
# unknown, an ambiguous PR state, no explicit disposition — HOLDs the
# worktree with the reason printed. Never "no PR", never inferred.
#
# ---- scoping -----------------------------------------------------------------
# --branch=<name> / --worktree=<path> (one of them), and anything that needs
# them (--disposition=, --include-dirty), require EXACTLY ONE repo argument,
# and the scope must match exactly one linked worktree in that repo, or the
# run refuses before touching anything. Herdr reuses branch names like
# review/pr-N across repos, so a branch name alone never names a worktree.
# A detached HEAD has no branch: scope it with --worktree=<path>.
#
# ---- never candidates, whatever the flags --------------------------------------
#   * the repo's PRIMARY checkout (the first `git worktree list` entry);
#   * anything whose real path is not strictly beneath an allowed root:
#     ~/.herdr/worktrees or ${HERDR_CODE_ROOT:-~/Code}/.worktrees;
#   * a protected path, or a worktree that contains one: $HERDR_APP_DIR
#     (default ~/.local/share/herdr-control/app — the deployed app launchd
#     runs hub.py from: a detached linked worktree with no pane and no
#     registry row, so no liveness signal can see it) and ~/.local/share.
#
# ---- a worktree is removable only when ALL of ------------------------------------
#   1. liveness is verifiable and clear — at preview time AND again
#      immediately before `git worktree remove` (review r2 H1):
#        - the run registry ALREADY EXISTS, has ever held a task, reads
#          (read-only), and has no starting/running/blocked task at or
#          beneath this path. A missing or empty registry is never "nobody is
#          working", and this tool never creates one (r2 H2);
#        - `herdr pane list` parses and lists at least one pane, every pane
#          reports a cwd, and no pane's cwd OR foreground_cwd (raw or
#          realpath) is this path or beneath it (r2 M1);
#        - `lsof` runs and sees this process, and NO process at all — herdr
#          pane or not — has its cwd OR any open file at or beneath this
#          path (r2 H3, r3 L2);
#        - no other archive run fences it and no spawn-task.sh is writing
#          into it (r3 L1; lib/worktree-archive.sh, "the spawn/archive fence").
#   2. HEAD is reachable from a ref origin has RIGHT NOW (`git ls-remote
#      origin`: branches, tags, refs/pull/N/head) — never a cached
#      remote-tracking ref. RECOVERABILITY, never delivery.
#   3. its disposition is explicit, exactly one of:
#        merged      read off GitHub: a MERGED PR on the branch and no OPEN
#                    one. Never a flag.
#        abandoned | superseded
#                    stated by the operator with --disposition=, scoped to
#                    this one worktree. Required for a branch with no PR or
#                    only CLOSED ones, and for every detached HEAD.
#      ANY open PR on the branch HOLDs, whatever older PRs it carries.
#   4. no nested git repository/worktree inside it, and no dirty tracked or
#      untracked work unless the operator names this exact worktree with
#      --include-dirty. Ignored artifacts (.handoffs/, tmp/) are archived.
#   5. the archive root's filesystem has room for the copy plus a bundle of
#      HEAD plus HERDR_ARCHIVE_MIN_FREE_KB (default 1 GiB) of headroom.
#   6. git could actually remove it and the archive outlives it: the path is
#      not a symlink and git resolves it to itself (r2 L1); it is not
#      `git worktree lock`ed and has no submodule (r2 L3); it has no
#      worktree-private refs/worktree or refs/bisect refs, which the HEAD
#      bundle would not carry (r2 L5); and the archive root
#      (HERDR_ARCHIVE_ROOT, absolute) is not at or beneath it (r2 M2).
#
# Then tracked changes, untracked files and ignored artifacts are copied to
# ~/Code/.archive/worktrees/<repo>/<branch-or-ref>-<ts>-<pid>/ with a sha256
# MANIFEST (lib/worktree-archive.sh) — regenerable dirs (node_modules,
# .venv, build/dist caches) are not copied but listed in it as EXCLUDED —
# a `git bundle` of HEAD is written alongside, BOTH are verified, and only
# then does `git worktree remove` run (never `--force`; a leftover directory
# after a clean remove is cleaned by hand with `trash`, never rm -rf).
#
# ---- --apply concurrency (review r2 H1/M3) ---------------------------------------
#   * one --apply at a time: a mkdir lock, archive-worktrees.lock, beside the
#     registry this run trusts ($HERDR_RUN_STATE_DIR). A second run exits.
#   * each worktree is fenced off from spawn-task.sh (lib/worktree-archive.sh
#     archive_fence_take) from BEFORE its `git worktree lock` until AFTER its
#     `git worktree remove`, and `git worktree lock`ed for the archive window;
#     spawn-task.sh refuses a worktree that is either (r2 H1, r3 L1).
#   * the archive is written to <dest>.partial/ (created with a plain mkdir,
#     never -p) and renamed to <dest>/ only once verified, so an interrupted
#     run leaves a dir that says it is unfinished.
#   * right before the remove, spawn intents, liveness, HEAD, the file set
#     and the manifest are all read AGAIN for that one worktree; any change
#     REFUSES it.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/run-registry.sh
source "$HERE/lib/run-registry.sh"
# shellcheck source=lib/worktree-archive.sh
source "$HERE/lib/worktree-archive.sh"

_die() { printf 'archive-worktrees: %s\n' "$1" >&2; exit 1; }
_realdir() { (cd "$1" 2>/dev/null && pwd -P); }
_within() {                     # <path> <base>: path is base or beneath it
  [ -n "$1" ] && [ -n "$2" ] || return 1
  case "$1" in "$2"|"$2"/*) return 0 ;; esac
  return 1
}

apply=0; disposition_flag=""; branch_filter=""; worktree_filter=""; include_dirty=0
repo_args=()
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    --include-dirty) include_dirty=1 ;;
    --disposition=*) disposition_flag="${a#--disposition=}" ;;
    --branch=*) branch_filter="${a#--branch=}" ;;
    --worktree=*) worktree_filter="${a#--worktree=}" ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    --*) _die "unknown flag $a" ;;
    *) repo_args+=("$a") ;;
  esac
done

case "$disposition_flag" in
  ''|abandoned|superseded) ;;
  *) _die "--disposition=$disposition_flag invalid (abandoned|superseded only — merged is read from GitHub, never asserted)" ;;
esac
[ -n "$branch_filter" ] && [ -n "$worktree_filter" ] && _die "give --branch= or --worktree=, not both"
scoped=0
{ [ -n "$branch_filter" ] || [ -n "$worktree_filter" ]; } && scoped=1
if [ "$scoped" != 1 ]; then
  [ -n "$disposition_flag" ] && _die "--disposition=$disposition_flag requires --branch=<name> or --worktree=<path> to scope it to one worktree"
  [ "$include_dirty" = 1 ] && _die "--include-dirty requires --branch=<name> or --worktree=<path> to scope it to one worktree"
fi
if [ "$scoped" = 1 ] && [ "${#repo_args[@]}" -ne 1 ]; then
  _die "--branch=/--worktree= require exactly one repo argument (got ${#repo_args[@]}) — branch names repeat across repos"
fi
wf_real=""
if [ -n "$worktree_filter" ]; then
  wf_real=$(_realdir "$worktree_filter") || _die "--worktree=$worktree_filter is not an existing directory"
fi

code_root="${HERDR_CODE_ROOT:-$HOME/Code}"
archive_root="${HERDR_ARCHIVE_ROOT:-$HOME/Code/.archive/worktrees}"
min_free_kb="${HERDR_ARCHIVE_MIN_FREE_KB:-1048576}"
case "$min_free_kb" in ''|*[!0-9]*) _die "HERDR_ARCHIVE_MIN_FREE_KB=$min_free_kb is not a whole number of KiB" ;; esac
# r2 M2: a relative root resolves against the caller's cwd — wherever that is.
case "$archive_root" in /*) ;; *) _die "HERDR_ARCHIVE_ROOT=$archive_root is not an absolute path" ;; esac

# Repos to scan: explicit args, or every PRIMARY checkout directly under the
# code root (`.git` a real directory — a linked worktree's `.git` is a FILE).
if [ "${#repo_args[@]}" -eq 0 ]; then
  while IFS= read -r d; do
    [ -d "$d/.git" ] && repo_args+=("$d")
  done < <(find "$code_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

# ---- C1: allowed roots and protected paths (resolved once) -------------------------
allowed_roots=()
for r in "$HOME/.herdr/worktrees" "$code_root/.worktrees"; do
  rr=$(_realdir "$r") && allowed_roots+=("$rr")
done
protected=()
for p in "${HERDR_APP_DIR:-$HOME/.local/share/herdr-control/app}" "$HOME/.local/share"; do
  protected+=("$p")
  pr=$(_realdir "$p") && [ "$pr" != "$p" ] && protected+=("$pr")
done

_root_why() {                   # <wt> <wt_real> -> prints a HOLD reason, or nothing
  local p r
  for p in "${protected[@]}"; do
    if _within "$1" "$p" || _within "$2" "$p" || _within "$p" "$1" || _within "$p" "$2"; then
      printf 'protected path (%s) — never archivable\n' "$p"
      return
    fi
  done
  for r in ${allowed_roots[@]+"${allowed_roots[@]}"}; do
    [ "$2" != "$r" ] && _within "$2" "$r" && return
  done
  printf 'outside the allowed worktree roots (~/.herdr/worktrees, %s/.worktrees) — never archivable\n' "$code_root"
}

# _origin_slug <worktree> -> "owner/repo" for gh lookups: an explicit
# `git config herdr.origin-slug` (a mirror/alias origin, or a fixture whose
# origin is a local path) first, else a literal github.com remote URL.
# Nonzero when neither resolves — the caller HOLDs, it never skips the PR check.
_origin_slug() {
  local override url
  override=$(git -C "$1" config --get herdr.origin-slug 2>/dev/null)
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    *@github.com:*)          url="${url#*@github.com:}" ;;
    https://github.com/*)    url="${url#https://github.com/}" ;;
    ssh://*@github.com/*)    url="${url#ssh://*@github.com/}" ;;
    *) return 1 ;;
  esac
  url="${url%.git}"
  printf '%s\n' "$url"
}

# ---- liveness: three sources, each a function so the pre-remove re-check
# (r2 H1) reads them AGAIN rather than trusting this run's first snapshot.

# H5 + r2 M1/H2: live pane cwds — BOTH cwd and foreground_cwd, raw AND
# canonical. A pane with neither field, or a list with no panes at all (the
# wrong herdr server/socket), makes liveness unverifiable.
_read_panes() {
  local json no_cwd raw c cr n
  panes_why=""; pane_cwds=""
  json=$(herdr pane list 2>/dev/null)
  if ! printf '%s' "$json" | jq -e '(.result.panes // .panes) | type == "array"' >/dev/null 2>&1; then
    panes_why="herdr pane list is unavailable or unparseable; liveness cannot be verified"
  elif ! n=$(printf '%s' "$json" | jq -r '(.result.panes // .panes) | length') || [ "$n" = 0 ]; then
    panes_why="herdr pane list returned no panes (wrong herdr server?); liveness cannot be verified"
  elif ! no_cwd=$(printf '%s' "$json" | jq -r '[(.result.panes // .panes)[] | select(((.cwd // "") == "") and ((.foreground_cwd // "") == "")) | .pane_id // "?"] | join(",")'); then
    panes_why="herdr pane list could not be read; liveness cannot be verified"
  elif [ -n "$no_cwd" ]; then
    panes_why="pane(s) $no_cwd report no cwd; liveness cannot be verified"
  elif ! raw=$(printf '%s' "$json" | jq -r '(.result.panes // .panes)[] | (.cwd, .foreground_cwd) | select(. != null and . != "")'); then
    panes_why="herdr pane list could not be read; liveness cannot be verified"
  else
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      pane_cwds+="$c"$'\n'
      cr=$(_realdir "$c") && [ "$cr" != "$c" ] && pane_cwds+="$cr"$'\n'
    done <<<"$raw"
  fi
}

# H3 + r2 H2: live registry rows, exit status checked. A registry that does
# not already exist, or has never held a task, is a WRONG registry (typo'd or
# unset HERDR_RUN_STATE_DIR), never an empty one — and it is opened
# -readonly: registry_init would mkdir and CREATE it, which is exactly how a
# typo'd dir used to read as "nobody is working".
_reg_ro() {
  sqlite3 -readonly -batch -noheader -cmd ".timeout ${HERDR_REGISTRY_BUSY_MS:-5000}" "$(registry_db)" "$1"
}
_read_registry() {
  local db n rows tid twt twt_real
  reg_why=""; reg_paths=()        # "task_id|path" for raw and canonical forms
  db=$(registry_db)
  if [ ! -f "$db" ] || [ ! -s "$db" ]; then
    reg_why="run registry $db does not exist (HERDR_RUN_STATE_DIR wrong or unset?) — a missing registry is not an empty one; liveness cannot be verified"
  elif ! n=$(_reg_ro "SELECT count(*) FROM tasks;" 2>/dev/null); then
    reg_why="run registry query failed; liveness cannot be verified"
  elif [ "$n" = 0 ] || case "$n" in ''|*[!0-9]*) true ;; *) false ;; esac; then
    reg_why="run registry $db has never held a task (not the live registry?); liveness cannot be verified"
  elif ! rows=$(_reg_ro "SELECT task_id || '|' || worktree FROM tasks WHERE state IN ('starting','running','blocked') AND worktree IS NOT NULL AND worktree != '';" 2>/dev/null); then
    reg_why="run registry query failed; liveness cannot be verified"
  else
    while IFS='|' read -r tid twt; do
      [ -n "$twt" ] || continue
      reg_paths+=("$tid|$twt")
      twt_real=$(_realdir "$twt") && [ "$twt_real" != "$twt" ] && reg_paths+=("$tid|$twt_real")
    done <<<"$rows"
  fi
}

# r2 H3 + r3 L2: every process's cwd AND every file it holds open, herdr
# pane or not — an omp session, editor, dev server, log writer or `tail -f`
# under ~/Code/.worktrees is as live as a pane, wherever its own cwd is.
# lsof reports the kernel's (canonical) path. It must exit 0 AND list this
# very process, or it cannot see what it is being asked about. Only rows at
# or beneath an allowed root are kept: a worktree anywhere else HOLDs before
# liveness is consulted, and the full listing is tens of thousands of rows.
# One pipe, no `grep -q` on the listing: an early-exiting reader SIGPIPEs a
# writer of that size, which pipefail reports as "lsof failed". -n -P: the
# full listing includes sockets, and resolving them would hang on DNS.
_read_procs() {
  local rc
  proc_why=""
  proc_files=$(lsof -w -n -P -Fpfn 2>/dev/null \
    | AW_SELF="$$" AW_ROOTS="$(printf '%s\n' ${allowed_roots[@]+"${allowed_roots[@]}"})" awk '
        BEGIN { nr = split(ENVIRON["AW_ROOTS"], r, "\n") }
        /^p/ { p = substr($0, 2); if (p == ENVIRON["AW_SELF"]) self = 1; next }
        /^f/ { f = substr($0, 2); next }
        /^n\// {
          n = substr($0, 2)
          for (i = 1; i <= nr; i++) if (r[i] != "" && (n == r[i] || index(n, r[i] "/") == 1)) { print p "\t" f "\t" n; break }
        }
        END { if (!self) exit 3 }')
  rc=$?
  case "$rc" in
    0) ;;
    3) proc_why="lsof did not list this process; open files cannot be verified"; proc_files="" ;;
    *) proc_why="lsof failed; open files cannot be verified"; proc_files="" ;;
  esac
}

_live_why() {                   # <wt> <wt_real> -> prints a HOLD reason, or nothing
  local c row pid fd hit
  if [ -n "$panes_why" ]; then printf '%s\n' "$panes_why"; return; fi
  if [ -n "$reg_why" ]; then printf '%s\n' "$reg_why"; return; fi
  if [ -n "$proc_why" ]; then printf '%s\n' "$proc_why"; return; fi
  while IFS= read -r c; do
    if _within "$c" "$1" || _within "$c" "$2"; then
      printf 'a live pane cwd (%s) is inside this worktree\n' "$c"
      return
    fi
  done <<<"$pane_cwds"
  for row in ${reg_paths[@]+"${reg_paths[@]}"}; do
    if _within "${row#*|}" "$1" || _within "${row#*|}" "$2"; then
      printf 'task %s is still starting/running/blocked against this worktree\n' "${row%%|*}"
      return
    fi
  done
  hit=$(printf '%s\n' "$proc_files" | AW_WT="$1" AW_WTR="$2" awk '
    function within(p, b) { return b != "" && (p == b || index(p, b "/") == 1) }
    !hit { n = $0; sub(/^[^\t]*\t[^\t]*\t/, "", n)
           if (within(n, ENVIRON["AW_WT"]) || within(n, ENVIRON["AW_WTR"])) { print; hit = 1 } }')
  if [ -n "$hit" ]; then
    IFS=$'\t' read -r pid fd c <<<"$hit"
    if [ "$fd" = cwd ]; then
      printf 'process %s has its cwd (%s) inside this worktree\n' "$pid" "$c"
    else
      printf 'process %s has %s open inside this worktree (fd %s)\n' "$pid" "$c" "$fd"
    fi
  fi
}

_read_registry

# ---- r2 M3: one --apply at a time ----------------------------------------------------
# A mkdir lock (no flock on macOS) beside the registry this run trusts — the
# real registry dir in production, a scratch one under test. With no usable
# registry every worktree HOLDs on reg_why and nothing is mutated, so no
# lock is needed (and the missing dir is never created). A lock left by a
# SIGKILLed run is never stolen: its pid is printed for the operator.
# The EXIT trap also unlocks a worktree this run `git worktree lock`ed, and
# only then drops the spawn fence it holds (r3 L1) — never the other order.
run_lock=""; locked_wt=""; locked_repo=""; fenced=""
_release_fence() {
  [ -z "$fenced" ] || rm -f "$fenced"
  fenced=""
}
_cleanup() {
  [ -n "$locked_wt" ] && git -C "$locked_repo" worktree unlock "$locked_wt" >/dev/null 2>&1
  _release_fence
  if [ -n "$run_lock" ]; then
    rm -f "$run_lock/pid"
    rmdir "$run_lock" 2>/dev/null
  fi
  return 0
}
trap _cleanup EXIT
trap 'exit 130' INT TERM HUP
if [ "$apply" = 1 ] && [ -z "$reg_why" ]; then
  lock="$(run_state_root)/archive-worktrees.lock"
  mkdir "$lock" 2>/dev/null \
    || _die "another archive-worktrees.sh --apply holds $lock (pid $(cat "$lock/pid" 2>/dev/null || echo '?')); if that pid is gone, \`trash\` the lock dir and re-run"
  run_lock="$lock"
  printf '%s\n' "$$" > "$lock/pid"
fi

_read_panes
_read_procs
_WT_LOCK_REASON="archive-worktrees.sh pid $$: archiving, about to remove"

# r2 H1: <wt> <wt_real> <head> <files> <excluded> <manifest|""> -> prints a
# reason, or nothing. Run immediately before `git worktree remove`, while
# the worktree is `git worktree lock`ed: everything the decision rested on is
# read AGAIN for this one worktree. Ignored files (.handoffs/SPEC.md from a
# re-spawn) are deleted by a non-forced remove, so a new one must REFUSE.
# r3 L1: this runs AFTER this run fenced the worktree (archive_fence_take).
# A spawn-task that passed its own fence check before that still has its
# intent file down here, whenever it writes — or, if it already finished,
# its writes (identity.json at least) show up below as changed files.
_recheck_why() {
  local wt="$1" wt_real="$2" head="$3" files="$4" excluded="$5" manifest="$6" why now td ut ig nf first
  why=$(archive_fence_why "$wt" "$fenced")
  if [ -n "$why" ]; then printf '%s\n' "$why"; return; fi
  _read_panes; _read_registry; _read_procs
  why=$(_live_why "$wt" "$wt_real")
  if [ -n "$why" ]; then printf '%s\n' "$why"; return; fi
  now=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  if [ "$now" != "$head" ]; then printf 'HEAD moved during archiving (%s -> %s)\n' "$head" "${now:-?}"; return; fi
  if ! td=$(archive_enumerate_tracked_dirty "$wt") || ! ut=$(archive_enumerate_untracked "$wt") \
    || ! ig=$(archive_enumerate_ignored "$wt") || ! archive_split_regenerable "$ig"; then
    printf 'git could not re-list the worktree files\n'
    return
  fi
  nf=$(printf '%s\n%s\n%s\n' "$td" "$ut" "$_ARCHIVE_KEEP" | grep . | sort -u)
  if [ "$nf" != "$files" ]; then
    first=$(comm -3 <(printf '%s\n' "$files") <(printf '%s\n' "$nf") | head -1 | tr -d '\t')
    printf 'files changed during archiving (e.g. %s)\n' "${first:-?}"
    return
  fi
  if [ "$(printf '%s\n' "$_ARCHIVE_EXCLUDED" | cut -f2)" != "$(printf '%s\n' "$excluded" | cut -f2)" ]; then
    printf 'regenerable directories changed during archiving\n'
    return
  fi
  if [ -n "$manifest" ] && ! archive_verify_manifest "$wt" "$manifest"; then
    printf '%s\n' "$_ARCHIVE_WHY"
  fi
}

_in_scope() {                   # <wt> <wt_real> <branch>
  [ "$scoped" = 1 ] || return 0
  if [ -n "$branch_filter" ]; then [ "$3" = "$branch_filter" ]; return; fi
  [ "$1" = "$worktree_filter" ] || [ "$2" = "$wf_real" ]
}

archivable=0; removed=0; held=0

for repo in ${repo_args[@]+"${repo_args[@]}"}; do
  if [ ! -d "$repo/.git" ]; then
    [ "$scoped" = 1 ] && _die "$repo is not a primary checkout (no .git directory)"
    printf '  SKIP    %s — not a primary checkout (no .git directory)\n' "$repo"
    continue
  fi
  repo_base="$(basename "$repo")"
  if ! porcelain=$(git -C "$repo" worktree list --porcelain 2>/dev/null) \
    || ! wt_list=$(printf '%s\n' "$porcelain" | awk '/^worktree /{print substr($0,10)}') \
    || [ -z "$wt_list" ]; then
    [ "$scoped" = 1 ] && _die "git worktree list failed for $repo"
    printf '  SKIP    %s — git worktree list failed\n' "$repo"
    continue
  fi
  locked_list=$(printf '%s\n' "$porcelain" | awk '/^worktree /{cur=substr($0,10)} /^locked/{print cur}')
  primary="${wt_list%%$'\n'*}"

  # H4: a scope must name exactly one linked worktree before anything runs.
  if [ "$scoped" = 1 ]; then
    matches=0
    while IFS= read -r wt; do
      [ "$wt" = "$primary" ] && continue
      _in_scope "$wt" "$(_realdir "$wt")" "$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" && matches=$((matches+1))
    done <<<"$wt_list"
    [ "$matches" -eq 1 ] || _die "scope ${branch_filter:+--branch=$branch_filter}${worktree_filter:+--worktree=$worktree_filter} matches $matches linked worktrees in $repo (need exactly 1)"
  fi

  # M1: what origin has RIGHT NOW, once per repo — only tips present locally
  # can be excluded; a tip we do not have proves nothing, so it is dropped
  # and the commits it might cover stay unproven (HOLD).
  origin_why=""; origin_excl=""
  if ! ls_out=$(git -C "$repo" ls-remote origin 2>/dev/null); then
    origin_why="git ls-remote origin failed; reachability cannot be verified against the real remote"
  elif ! origin_excl=$(printf '%s\n' "$ls_out" | cut -f1 | sort -u \
      | git -C "$repo" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
      | awk '$2 == "commit" { print "^" $1 }'); then
    origin_why="could not resolve origin's refs locally; reachability cannot be verified"
  fi

  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ "$wt" = "$primary" ] && continue
    [ -d "$wt" ] || continue
    wt_real=$(_realdir "$wt")
    branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)
    _in_scope "$wt" "$wt_real" "$branch" || continue

    why=""
    [ -n "$wt_real" ] || why="cannot resolve the real path"
    [ -n "$why" ] || why=$(_root_why "$wt" "$wt_real")
    [ -n "$why" ] || why=$(_live_why "$wt" "$wt_real")
    [ -n "$why" ] || why=$(archive_root_why "$archive_root" "$wt")
    # r2 L1: a registered path swapped for a symlink would be checked and
    # archived as some OTHER directory under this worktree's label.
    if [ -z "$why" ]; then
      if [ -L "$wt" ]; then
        why="the worktree path is a symlink — checks and archive would describe another directory"
      elif ! tl=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || [ "$(_realdir "$tl")" != "$wt_real" ]; then
        why="git resolves this path to another checkout (${tl:-?}), not this worktree"
      fi
    fi
    # r2 L3: git worktree remove can never remove these; previewing them as
    # archivable only wrote a fresh archive and a LEFTOVER on every run.
    if [ -z "$why" ] && printf '%s\n' "$locked_list" | grep -qxF -- "$wt"; then
      why="locked (git worktree lock) — git worktree remove would refuse it; unlock it first"
    fi
    # r3 L1: another archive run's fence, or a spawn-task mid-write.
    [ -n "$why" ] || why=$(archive_fence_why "$wt")
    if [ -z "$why" ]; then
      if ! idx=$(git -C "$wt" ls-files -s 2>/dev/null); then
        why="git ls-files failed; submodules cannot be checked"
      else
        gl=$(printf '%s\n' "$idx" | awk '$1 == "160000" { sub(/^[^\t]*\t/, ""); print; exit }')
        [ -n "$gl" ] && why="contains a submodule ($gl) — git worktree remove would refuse it"
      fi
    fi
    # r2 L5: worktree-private refs are deleted with the worktree; the bundle
    # holds HEAD only.
    if [ -z "$why" ]; then
      if ! wrefs=$(git -C "$wt" for-each-ref --format='%(refname)' refs/worktree refs/bisect 2>/dev/null); then
        why="git for-each-ref failed; worktree-private refs cannot be checked"
      elif [ -n "$wrefs" ]; then
        why="has worktree-private refs the archive bundle would not carry (${wrefs%%$'\n'*})"
      fi
    fi

    if [ -z "$why" ]; then
      if [ -n "$origin_why" ]; then
        why="$origin_why"
      else
        only_here=$(printf '%s\n' "$origin_excl" | git -C "$wt" rev-list --count --stdin HEAD 2>/dev/null)
        case "$only_here" in
          0) ;;
          ''|*[!0-9]*) why="commits on HEAD cannot be checked against origin" ;;
          *) why="$only_here commit(s) on ${branch:-HEAD} are on no ref origin has (ls-remote)" ;;
        esac
      fi
    fi

    # H1/H2/H6: an explicit disposition, or HOLD.
    disposition=""
    if [ -z "$why" ]; then
      if [ -z "$branch" ]; then
        if [ -n "$disposition_flag" ]; then
          disposition="$disposition_flag"
        else
          why="detached HEAD — needs --worktree=$wt --disposition=abandoned|superseded (with its repo argument)"
        fi
      elif ! slug=$(_origin_slug "$wt") || [ -z "$slug" ]; then
        why="cannot resolve origin's GitHub owner/repo (set git config herdr.origin-slug); PR state unknown"
      elif ! prs=$(_gh_pr_lookup "$slug" --head-all "$branch"); then
        why="gh PR lookup failed for $slug:$branch; PR state unknown"
      else
        open_url=""; odd=""; merged=0; nprs=0
        while IFS='|' read -r st url _oid; do
          [ -n "$st$url" ] || continue
          nprs=$((nprs+1))
          case "$st" in
            OPEN)   [ -n "$open_url" ] || open_url="$url" ;;
            MERGED) merged=1 ;;
            CLOSED) ;;
            *)      [ -n "$odd" ] || odd="${url:-?} has state ${st:-?}" ;;
          esac
        done <<<"$prs"
        if [ -n "$open_url" ]; then
          why="$open_url is OPEN — not yet closable"
        elif [ -n "$odd" ]; then
          why="$odd — PR state ambiguous"
        elif [ "$merged" = 1 ]; then
          if [ -n "$disposition_flag" ]; then
            why="GitHub shows a MERGED PR on $branch; --disposition=$disposition_flag contradicts it"
          else
            disposition=merged
          fi
        elif [ -n "$disposition_flag" ]; then
          disposition="$disposition_flag"
        elif [ "$nprs" -eq 0 ]; then
          why="no PR on $branch — needs --branch=$branch --disposition=abandoned|superseded"
        else
          why="PR(s) on $branch CLOSED unmerged — needs --branch=$branch --disposition=abandoned|superseded"
        fi
      fi
    fi

    # L2 + dirty: enumerate once, every git call's exit status checked.
    files=""; excluded=""
    if [ -z "$why" ]; then
      if ! td=$(archive_enumerate_tracked_dirty "$wt") || ! ut=$(archive_enumerate_untracked "$wt") \
        || ! ig=$(archive_enumerate_ignored "$wt"); then
        why="git could not list this worktree's changed/untracked/ignored files"
      fi
    fi
    if [ -z "$why" ]; then
      nested=$(printf '%s\n%s\n' "$ut" "$ig" | grep -m1 '/$')
      while IFS= read -r o; do
        [ -n "$nested" ] && break
        [ "$o" != "$wt" ] && _within "$o" "$wt" && nested="$o"
      done <<<"$wt_list"
      [ -n "$nested" ] && why="contains a nested git repository/worktree ($nested)"
    fi
    if [ -z "$why" ]; then
      ndirty=$(printf '%s\n%s\n' "$td" "$ut" | grep -c .)
      if [ "$ndirty" -gt 0 ] && [ "$include_dirty" != 1 ]; then
        if [ -n "$branch" ]; then hint="--branch=$branch"; else hint="--worktree=$wt"; fi
        why="dirty: uncommitted work ($ndirty tracked/untracked file(s)) — pass $hint --include-dirty (with its repo argument) to archive anyway"
      fi
    fi
    if [ -z "$why" ]; then
      if ! archive_split_regenerable "$ig"; then
        why="could not separate regenerable directories from ignored files"
      else
        files=$(printf '%s\n%s\n%s\n' "$td" "$ut" "$_ARCHIVE_KEEP" | grep . | sort -u)
        excluded="$_ARCHIVE_EXCLUDED"
      fi
    fi

    # M2: room for the copy + bundle + headroom, or HOLD.
    if [ -z "$why" ]; then
      if ! need_kb=$(archive_need_kb "$wt" "$files"); then
        why="could not size the archive copy/bundle"
      elif ! free_kb=$(archive_free_kb "$archive_root"); then
        why="could not read free disk space under $archive_root"
      elif [ "$free_kb" -lt $((need_kb + min_free_kb)) ]; then
        why="insufficient disk under $archive_root: ${free_kb} KiB free, need ${need_kb} KiB + ${min_free_kb} KiB headroom"
      fi
    fi

    if [ -n "$why" ]; then
      held=$((held+1))
      printf '  HOLD    %-44s %-20s %s\n' "$wt" "${branch:-<detached>}" "$why"
      continue
    fi

    nfiles=$(printf '%s\n' "$files" | grep -c .)
    nexcl=$(printf '%s\n' "$excluded" | grep -c .)
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    slot="${branch:-detached-$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)}"
    # r2 M3: the pid makes the name unique per run; it is still created with
    # a plain mkdir (never -p) and refused if anything is already there.
    dest="$archive_root/$repo_base/${slot//\//-}-$ts-$$"

    archivable=$((archivable+1))
    printf '  archive %-44s %-20s disposition=%s (%s file(s), %s regenerable dir(s) excluded, + bundle) -> %s\n' \
      "$wt" "${branch:-<detached>}" "$disposition" "$nfiles" "$nexcl" "$dest"
    [ "$apply" = 1 ] || continue

    # Archive into <dest>.partial/ (r2 L2: an interrupted run leaves a dir
    # that says it is unfinished), with the worktree fenced off from
    # spawn-task.sh from here until AFTER the remove (r3 L1) and locked
    # against git for the archive window (r2 H1).
    refuse=""; part="$dest.partial"; manifest=""
    head_sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    [ -n "$head_sha" ] || refuse="could not resolve HEAD"
    if [ -z "$refuse" ]; then
      if archive_fence_take "$wt"; then fenced="$_ARCHIVE_FENCE"; else refuse="$_ARCHIVE_WHY"; fi
    fi
    if [ -z "$refuse" ]; then
      if git -C "$repo" worktree lock --reason "$_WT_LOCK_REASON" "$wt" >/dev/null 2>&1; then
        locked_wt="$wt"; locked_repo="$repo"
      else
        refuse="git worktree lock failed — cannot fence off a re-spawn while archiving"
      fi
    fi
    if [ -z "$refuse" ] && { [ -e "$dest" ] || ! mkdir -p "$archive_root/$repo_base" 2>/dev/null || ! mkdir "$part" 2>/dev/null; }; then
      refuse="archiving failed: could not create $part (or $dest already exists)"
    fi
    if [ -z "$refuse" ] && [ -n "$files" ]; then
      if ! archive_copy_and_manifest "$wt" "$part" "$files"; then
        refuse="archiving failed: $_ARCHIVE_WHY"
      elif ! archive_verify_manifest "$wt" "$_ARCHIVE_MANIFEST"; then
        refuse="archive verification failed: $_ARCHIVE_WHY"
      else
        manifest="$_ARCHIVE_MANIFEST"
      fi
    fi
    if [ -z "$refuse" ] && ! archive_record_exclusions "$part" "$excluded"; then
      refuse="archiving failed: $_ARCHIVE_WHY"
    fi
    if [ -z "$refuse" ] && ! archive_create_bundle "$wt" "$part/branch.bundle"; then
      refuse="git bundle create failed"
    fi
    if [ -z "$refuse" ] && ! archive_verify_bundle "$wt" "$part/branch.bundle"; then
      refuse="git bundle verify failed"
    fi
    if [ -z "$refuse" ] && ! printf 'disposition=%s branch=%s ref_sha=%s archived_at=%s\n' \
        "$disposition" "${branch:-<detached>}" "$head_sha" "$ts" > "$part/DISPOSITION.txt" 2>/dev/null; then
      refuse="could not write $part/DISPOSITION.txt"
    fi
    if [ -z "$refuse" ]; then
      recheck=$(_recheck_why "$wt" "$wt_real" "$head_sha" "$files" "$excluded" "$manifest")
      [ -n "$recheck" ] && refuse="changed while archiving: $recheck"
    fi
    if [ -z "$refuse" ] && { [ -e "$dest" ] || ! mv "$part" "$dest" 2>/dev/null; }; then
      refuse="could not rename $part to $dest"
    fi
    # git refuses to remove a locked worktree (short of --force --force), so
    # the lock comes off here; the spawn fence stays on across the remove.
    if [ -n "$locked_wt" ]; then
      if ! git -C "$repo" worktree unlock "$wt" >/dev/null 2>&1; then
        [ -n "$refuse" ] && refuse="$refuse; "
        refuse="${refuse}git worktree unlock failed — it is still locked"
      fi
      locked_wt=""
    fi
    if [ -n "$refuse" ]; then
      _release_fence
      held=$((held+1)); archivable=$((archivable-1))
      [ -d "$part" ] && refuse="$refuse (unfinished archive left at $part)"
      printf '  REFUSED %-44s %-20s %s\n' "$wt" "${branch:-<detached>}" "$refuse"
      continue
    fi

    if remove_err=$(git -C "$repo" worktree remove "$wt" 2>&1); then
      removed=$((removed+1))
      printf '  removed %-44s %-20s archived to %s\n' "$wt" "${branch:-<detached>}" "$dest"
    else
      printf '  LEFTOVER %-43s %-20s archived to %s; git worktree remove failed (%s) — clean up by hand with `trash`, never rm -rf\n' \
        "$wt" "${branch:-<detached>}" "$dest" "$remove_err"
    fi
    _release_fence
  done <<<"$wt_list"
done

echo
if [ "$apply" = 1 ]; then
  printf '%d archived, %d removed, %d held back\n' "$archivable" "$removed" "$held"
else
  printf '%d archivable, %d held back — DRY RUN, nothing changed. Re-run with --apply\n' "$archivable" "$held"
fi
