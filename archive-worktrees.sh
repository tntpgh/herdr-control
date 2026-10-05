#!/usr/bin/env bash
# archive-worktrees.sh — recoverably archive, then remove, linked git
# worktrees whose work is done. DRY-RUN BY DEFAULT.
# (2026-10-05-worktree-archival-and-detached-close proposal; fixed per
# review r1 of PR #236.)
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
#   1. liveness is verifiable and clear: the run registry is readable and
#      has no starting/running/blocked task at or beneath this path, and
#      `herdr pane list` parses, every pane reports a cwd, and no pane's cwd
#      (raw or realpath) is this path or anywhere beneath it.
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
#
# Then tracked changes, untracked files and ignored artifacts are copied to
# ~/Code/.archive/worktrees/<repo>/<branch-or-ref>-<ts>/ with a sha256
# MANIFEST (lib/worktree-archive.sh) — regenerable dirs (node_modules,
# .venv, build/dist caches) are not copied but listed in it as EXCLUDED —
# a `git bundle` of HEAD is written alongside, BOTH are verified, and only
# then does `git worktree remove` run (never `--force`; a leftover directory
# after a clean remove is cleaned by hand with `trash`, never rm -rf).
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

# ---- H5: live pane cwds, raw AND canonical -------------------------------------------
panes_why=""
pane_cwds=""
panes_json=$(herdr pane list 2>/dev/null)
if ! printf '%s' "$panes_json" | jq -e '(.result.panes // .panes) | type == "array"' >/dev/null 2>&1; then
  panes_why="herdr pane list is unavailable or unparseable; liveness cannot be verified"
elif ! no_cwd=$(printf '%s' "$panes_json" | jq -r '[(.result.panes // .panes)[] | select(((.foreground_cwd // .cwd // "") | length) == 0) | .pane_id // "?"] | join(",")'); then
  panes_why="herdr pane list could not be read; liveness cannot be verified"
elif [ -n "$no_cwd" ]; then
  panes_why="pane(s) $no_cwd report no cwd; liveness cannot be verified"
elif ! raw_cwds=$(printf '%s' "$panes_json" | jq -r '(.result.panes // .panes)[] | (.foreground_cwd // .cwd)'); then
  panes_why="herdr pane list could not be read; liveness cannot be verified"
else
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    pane_cwds+="$c"$'\n'
    cr=$(_realdir "$c") && [ "$cr" != "$c" ] && pane_cwds+="$cr"$'\n'
  done <<<"$raw_cwds"
fi

# ---- H3: live registry rows, read ONCE, exit status checked ------------------------
reg_why=""
reg_paths=()                    # "task_id|path" for raw and canonical forms
if ! registry_init >/dev/null 2>&1; then
  reg_why="run registry unreadable (registry_init failed); liveness cannot be verified"
elif ! reg_rows=$(_sql "SELECT task_id || '|' || worktree FROM tasks WHERE state IN ('starting','running','blocked') AND worktree IS NOT NULL AND worktree != '';" 2>/dev/null); then
  reg_why="run registry query failed; liveness cannot be verified"
else
  while IFS='|' read -r tid twt; do
    [ -n "$twt" ] || continue
    reg_paths+=("$tid|$twt")
    twt_real=$(_realdir "$twt") && [ "$twt_real" != "$twt" ] && reg_paths+=("$tid|$twt_real")
  done <<<"$reg_rows"
fi

_live_why() {                   # <wt> <wt_real> -> prints a HOLD reason, or nothing
  local c row
  if [ -n "$panes_why" ]; then printf '%s\n' "$panes_why"; return; fi
  if [ -n "$reg_why" ]; then printf '%s\n' "$reg_why"; return; fi
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
  if ! wt_list=$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}') \
    || [ -z "$wt_list" ]; then
    [ "$scoped" = 1 ] && _die "git worktree list failed for $repo"
    printf '  SKIP    %s — git worktree list failed\n' "$repo"
    continue
  fi
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
    dest="$archive_root/$repo_base/${slot//\//-}-$ts"

    archivable=$((archivable+1))
    printf '  archive %-44s %-20s disposition=%s (%s file(s), %s regenerable dir(s) excluded, + bundle) -> %s\n' \
      "$wt" "${branch:-<detached>}" "$disposition" "$nfiles" "$nexcl" "$dest"
    [ "$apply" = 1 ] || continue

    refuse=""
    if [ -n "$files" ]; then
      if ! archive_copy_and_manifest "$wt" "$dest" "$files"; then
        refuse="archiving failed: $_ARCHIVE_WHY"
      elif ! archive_verify_manifest "$wt" "$_ARCHIVE_MANIFEST"; then
        refuse="archive verification failed: $_ARCHIVE_WHY"
      fi
    elif ! mkdir -p "$dest" 2>/dev/null; then
      refuse="archiving failed: could not create $dest"
    fi
    if [ -z "$refuse" ] && ! archive_record_exclusions "$dest" "$excluded"; then
      refuse="archiving failed: $_ARCHIVE_WHY"
    fi
    if [ -z "$refuse" ] && ! archive_create_bundle "$wt" "$dest/branch.bundle"; then
      refuse="git bundle create failed"
    fi
    if [ -z "$refuse" ] && ! archive_verify_bundle "$wt" "$dest/branch.bundle"; then
      refuse="git bundle verify failed"
    fi
    if [ -z "$refuse" ] && ! printf 'disposition=%s branch=%s ref_sha=%s archived_at=%s\n' \
        "$disposition" "${branch:-<detached>}" "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" "$ts" > "$dest/DISPOSITION.txt" 2>/dev/null; then
      refuse="could not write $dest/DISPOSITION.txt"
    fi
    if [ -n "$refuse" ]; then
      held=$((held+1)); archivable=$((archivable-1))
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
  done <<<"$wt_list"
done

echo
if [ "$apply" = 1 ]; then
  printf '%d archived, %d removed, %d held back\n' "$archivable" "$removed" "$held"
else
  printf '%d archivable, %d held back — DRY RUN, nothing changed. Re-run with --apply\n' "$archivable" "$held"
fi
