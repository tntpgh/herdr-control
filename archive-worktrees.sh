#!/usr/bin/env bash
# archive-worktrees.sh — recoverably archive, then remove, linked git
# worktrees whose work is done. DRY-RUN BY DEFAULT.
# (2026-10-05-worktree-archival-and-detached-close proposal.)
#
#   archive-worktrees.sh                                  # preview every repo under ~/Code
#   archive-worktrees.sh ~/Code/herdr-control              # preview one repo
#   archive-worktrees.sh --apply ~/Code/herdr-control      # archive+remove removable worktrees
#   archive-worktrees.sh --apply --branch=fix/x --disposition=abandoned ~/Code/herdr-control
#   archive-worktrees.sh --apply --branch=fix/x --include-dirty ~/Code/herdr-control
#
# `--disposition=` is ONLY for a CLOSED-and-unmerged PR (abandoned|superseded)
# and ONLY scoped to one worktree via `--branch=` — one flag cannot honestly
# describe a whole batch. `merged` is never a flag: it is read off GitHub
# automatically from the branch's own PR state, same as close-done-workers.sh.
#
# ---- what this does, and does not, touch ------------------------------------
# Only LINKED worktrees (`git worktree list` minus the repo's own PRIMARY
# checkout, always its list's first entry) are ever candidates. The primary
# checkout is never touched, dirty or not: it is shared, global state every
# session reads (~/Code/AGENTS.md), and worktree-concurrency-nudge already
# treats switching it off trunk as a deliberate exception, not routine.
#
# A worktree is removable only when ALL of:
#   1. no live pane is using it — a non-terminal (starting/running/blocked)
#      registry row for this exact path HOLDs it; `herdr pane list`'s
#      reported cwd is a best-effort SECOND signal (field name unconfirmed
#      against the real binary's own RPC shape, unlike the registry check,
#      which reuses already-proven lib/run-registry.sh queries) — either
#      signal, or an unparseable pane list, holds the worktree; dry-run
#      never mutates regardless, so a false positive here costs nothing
#      until --apply is actually used.
#   2. every local commit on its branch (or detached HEAD) is reachable from
#      a remote-tracking ref OR a matching refs/pull/<N>/head — proving
#      RECOVERABILITY, never delivery.
#   3. its disposition is explicit: `merged` is read off GitHub automatically
#      (the branch's own PR, if any, is MERGED); `abandoned`/`superseded`
#      require --disposition=<that> scoped via --branch=; a branch with no
#      PR at all and fully reachable commits gets `reachable`; an OPEN PR,
#      or a CLOSED-unmerged one with no --disposition, never removes.
#   4. it has NO dirty tracked/untracked work — "never touch the dirty
#      list". A modified tracked file or an untracked (non-ignored) file
#      HOLDs by default; the operator must name this exact worktree with
#      --branch=<name> --include-dirty to archive it anyway. Ignored
#      artifacts (.handoffs/, tmp/) are not "dirty work" and are always
#      archived regardless.
#
# Before ANY of that, tracked changes (`git diff --name-only HEAD`),
# untracked files and ignored artifacts are copied to
# ~/Code/.archive/worktrees/<repo>/<branch-or-ref>-<ts>/ with a sha256
# MANIFEST (lib/worktree-archive.sh), a `git bundle` of HEAD is written
# alongside it, and BOTH are verified — only then does `git worktree
# remove` run (never `--force`; a leftover directory after a clean remove
# is a bug to fix by hand with `trash`, never rm -rf).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/run-registry.sh
source "$HERE/lib/run-registry.sh"
# shellcheck source=lib/worktree-archive.sh
source "$HERE/lib/worktree-archive.sh"

apply=0; disposition_flag=""; branch_filter=""; include_dirty=0
repo_args=()
for a in "$@"; do
  case "$a" in
    --apply) apply=1 ;;
    --include-dirty) include_dirty=1 ;;
    --disposition=*) disposition_flag="${a#--disposition=}" ;;
    --branch=*) branch_filter="${a#--branch=}" ;;
    -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) printf 'archive-worktrees: unknown flag %s\n' "$a" >&2; exit 1 ;;
    *) repo_args+=("$a") ;;
  esac
done

case "$disposition_flag" in
  ''|abandoned|superseded) ;;
  *)
    printf 'archive-worktrees: --disposition=%s invalid (abandoned|superseded only — merged is read from GitHub, never asserted)\n' "$disposition_flag" >&2
    exit 1 ;;
esac
if [ -n "$disposition_flag" ] && [ -z "$branch_filter" ]; then
  printf 'archive-worktrees: --disposition=%s requires --branch=<name> to scope it to one worktree\n' "$disposition_flag" >&2
  exit 1
fi
if [ "$include_dirty" = 1 ] && [ -z "$branch_filter" ]; then
  printf 'archive-worktrees: --include-dirty requires --branch=<name> to scope it to one worktree\n' >&2
  exit 1
fi

# Repos to scan: explicit args, or every PRIMARY checkout directly under
# ~/Code (`.git` a real directory — a linked worktree's `.git` is a FILE,
# so this already excludes every worktree from being scanned as a repo).
if [ "${#repo_args[@]}" -eq 0 ]; then
  while IFS= read -r d; do
    [ -d "$d/.git" ] && repo_args+=("$d")
  done < <(find "${HERDR_CODE_ROOT:-$HOME/Code}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

# _origin_slug <worktree> -> "owner/repo" for gh lookups. Tries an explicit
# `git config herdr.origin-slug` override first — for a self-hosted/mirror
# origin whose remote URL is not literally github.com, or a fixture whose
# "origin" is a local path — then falls back to parsing a real github.com
# remote URL. Empty, nonzero when neither resolves.
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

panes_json=$(herdr pane list 2>/dev/null)
panes_ok=0
printf '%s' "$panes_json" | jq -e '(.result.panes // .panes) | type == "array"' >/dev/null 2>&1 && panes_ok=1
_live_cwds=""
[ "$panes_ok" = 1 ] && _live_cwds=$(printf '%s' "$panes_json" | jq -r '(.result.panes // .panes)[] | (.foreground_cwd // .cwd // empty)')

archivable=0; removed=0; held=0

for repo in "${repo_args[@]}"; do
  [ -d "$repo/.git" ] || continue
  repo_base="$(basename "$repo")"
  primary=$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
  [ -n "$primary" ] || continue

  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ "$wt" = "$primary" ] && continue
    [ -d "$wt" ] || continue
    branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)
    [ -n "$branch_filter" ] && [ "$branch" != "$branch_filter" ] && continue

    why=""
    wt_real=$(cd "$wt" 2>/dev/null && pwd -P)
    if [ "$panes_ok" != 1 ]; then
      why="herdr pane list is unavailable or unparseable; liveness cannot be verified"
    elif printf '%s\n' "$_live_cwds" | grep -qxF "$wt" \
      || { [ -n "$wt_real" ] && printf '%s\n' "$_live_cwds" | grep -qxF "$wt_real"; }; then
      why="a live pane reports this worktree as its cwd"
    fi
    # Compare against BOTH the raw and the realpath-canonicalized form: the
    # registry's stored `worktree` column may have been recorded through a
    # symlinked ancestor (e.g. macOS's /var -> /private/var) that differs
    # textually from what `git worktree list` reports for the same path —
    # an exact-string-only match would silently miss a live row and archive
    # a worktree a worker is still using.
    if [ -z "$why" ]; then
      while IFS='|' read -r tid twt; do
        [ -n "$twt" ] || continue
        if [ "$twt" = "$wt" ] || { [ -n "$wt_real" ] && [ "$twt" = "$wt_real" ]; }; then
          why="task $tid is still starting/running/blocked against this worktree"
          break
        fi
        twt_real=$(cd "$twt" 2>/dev/null && pwd -P)
        if [ -n "$twt_real" ] && [ -n "$wt_real" ] && [ "$twt_real" = "$wt_real" ]; then
          why="task $tid is still starting/running/blocked against this worktree"
          break
        fi
      done < <(_sql "SELECT task_id, worktree FROM tasks WHERE state IN ('starting','running','blocked') AND worktree IS NOT NULL AND worktree != '';" 2>/dev/null)
    fi

    only_here="" ref="${branch:-HEAD}"
    if [ -z "$why" ]; then
      only_here=$(git -C "$wt" rev-list --count "$ref" --not --remotes 2>/dev/null)
      case "$only_here" in
        ''|*[!0-9]*) why="commits on $ref cannot be checked against the remotes" ;;
      esac
      if [ -z "$why" ] && [ "$only_here" != 0 ] && [ -n "$branch" ]; then
        slug=$(_origin_slug "$wt") || slug=""
        if [ -n "$slug" ]; then
          info=$(_gh_pr_lookup "$slug" --head "$branch")
          if [ -n "$info" ]; then
            IFS='|' read -r _pr_state pr_url _pr_oid <<<"$info"
            pr_num="${pr_url##*/}"
            pull_sha=$(git -C "$wt" ls-remote origin "refs/pull/$pr_num/head" 2>/dev/null | cut -f1)
            [ -n "$pull_sha" ] && only_here=$(git -C "$wt" rev-list --count "$ref" --not --remotes "$pull_sha" 2>/dev/null)
          fi
        fi
      fi
      if [ -z "$why" ] && [ "${only_here:-1}" != 0 ]; then
        why="$only_here commit(s) on $ref exist on no remote ref and no matching refs/pull/N/head"
      fi
    fi

    disposition=""
    if [ -z "$why" ]; then
      if [ -n "$branch" ]; then
        slug=$(_origin_slug "$wt") || slug=""
        info=""
        [ -n "$slug" ] && info=$(_gh_pr_lookup "$slug" --head "$branch")
        if [ -n "$info" ]; then
          IFS='|' read -r pr_state pr_url _pr_oid <<<"$info"
          case "$pr_state" in
            MERGED) disposition=merged ;;
            OPEN)   why="$pr_url is OPEN — not yet closable" ;;
            CLOSED)
              if [ "$branch" = "$branch_filter" ] && [ -n "$disposition_flag" ]; then
                disposition="$disposition_flag"
              else
                why="$pr_url is CLOSED and unmerged — needs --branch=$branch --disposition=abandoned|superseded"
              fi
              ;;
            *) why="$pr_url has unexpected state ${pr_state:-unknown}" ;;
          esac
        else
          disposition=reachable   # no PR was ever opened; commits sit on a plain remote ref
        fi
      else
        disposition=reachable     # detached HEAD, already proven reachable above
      fi
    fi

    # Dirty tracked/untracked work is never silently swept into an archive
    # and removed — "never touch the dirty list" per the proposal. Ignored
    # artifacts (.handoffs/, tmp/) are NOT "dirty work" in this sense and are
    # always archived regardless. Dirty work is held unless the operator
    # names this exact worktree with --branch=<name> --include-dirty.
    if [ -z "$why" ]; then
      dirty_files=$( { archive_enumerate_tracked_dirty "$wt"; archive_enumerate_untracked "$wt"; } | sort -u )
      ndirty=$(printf '%s\n' "$dirty_files" | grep -c . || true)
      if [ "$ndirty" -gt 0 ] && { [ "$include_dirty" != 1 ] || [ "$branch" != "$branch_filter" ]; }; then
        why="dirty: uncommitted work ($ndirty tracked/untracked file(s)) — pass --branch=${branch:-<name>} --include-dirty to archive anyway"
      fi
    fi

    if [ -n "$why" ]; then
      held=$((held+1))
      printf '  HOLD    %-44s %-20s %s\n' "$wt" "${branch:-<detached>}" "$why"
      continue
    fi

    files=$( { archive_enumerate_tracked_dirty "$wt"; archive_enumerate_untracked "$wt"; archive_enumerate_ignored "$wt"; } | sort -u )
    nfiles=$(printf '%s\n' "$files" | grep -c . || true)
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    slot="${branch:-detached-$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)}"
    dest="${HERDR_ARCHIVE_ROOT:-$HOME/Code/.archive/worktrees}/$repo_base/${slot//\//-}-$ts"

    archivable=$((archivable+1))
    printf '  archive %-44s %-20s disposition=%s (%s file(s) + bundle) -> %s\n' \
      "$wt" "${branch:-<detached>}" "$disposition" "$nfiles" "$dest"
    [ "$apply" = 1 ] || continue

    manifest=""
    if [ -n "$files" ]; then
      if ! manifest=$(archive_copy_and_manifest "$wt" "$dest" "$files"); then
        held=$((held+1)); archivable=$((archivable-1))
        printf '  REFUSED %-44s %-20s archiving failed: %s\n' "$wt" "${branch:-<detached>}" "$_ARCHIVE_WHY"
        continue
      fi
      if ! archive_verify_manifest "$wt" "$manifest"; then
        held=$((held+1)); archivable=$((archivable-1))
        printf '  REFUSED %-44s %-20s archive verification failed: %s\n' "$wt" "${branch:-<detached>}" "$_ARCHIVE_WHY"
        continue
      fi
    else
      mkdir -p "$dest" 2>/dev/null
    fi
    if ! archive_create_bundle "$wt" "$dest/branch.bundle"; then
      held=$((held+1)); archivable=$((archivable-1))
      printf '  REFUSED %-44s %-20s git bundle create failed\n' "$wt" "${branch:-<detached>}"
      continue
    fi
    if ! archive_verify_bundle "$dest/branch.bundle"; then
      held=$((held+1)); archivable=$((archivable-1))
      printf '  REFUSED %-44s %-20s git bundle verify failed\n' "$wt" "${branch:-<detached>}"
      continue
    fi
    printf 'disposition=%s branch=%s ref_sha=%s archived_at=%s\n' \
      "$disposition" "${branch:-<detached>}" "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" "$ts" > "$dest/DISPOSITION.txt"

    if remove_err=$(git -C "$repo" worktree remove "$wt" 2>&1); then
      removed=$((removed+1))
      printf '  removed %-44s %-20s archived to %s\n' "$wt" "${branch:-<detached>}" "$dest"
    else
      printf '  LEFTOVER %-43s %-20s archived to %s; git worktree remove failed (%s) — clean up by hand with `trash`, never rm -rf\n' \
        "$wt" "${branch:-<detached>}" "$dest" "$remove_err"
    fi
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
done

echo
if [ "$apply" = 1 ]; then
  printf '%d archived, %d removed, %d held back\n' "$archivable" "$removed" "$held"
else
  printf '%d archivable, %d held back — DRY RUN, nothing changed. Re-run with --apply\n' "$archivable" "$held"
fi
