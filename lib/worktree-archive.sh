#!/usr/bin/env bash
# lib/worktree-archive.sh — copy-then-verify primitives shared by
# close-done-workers.sh's detached-HEAD close path and archive-worktrees.sh
# (2026-10-05-worktree-archival-and-detached-close proposal).
#
# One job each, composed by the two callers rather than duplicated:
#   archive_enumerate_ignored        <worktree>            -> ignored files
#   archive_enumerate_untracked      <worktree>            -> untracked, non-ignored files
#   archive_enumerate_tracked_dirty  <worktree>             -> tracked files that differ from HEAD
#   archive_split_regenerable        <files>               -> sets _ARCHIVE_KEEP / _ARCHIVE_EXCLUDED
#   archive_copy_and_manifest        <worktree> <dest> <files> -> writes dest/MANIFEST.sha256,
#                                                               sets _ARCHIVE_MANIFEST
#   archive_record_exclusions        <dest> <excluded>     -> appends EXCLUDED lines to the manifest
#   archive_verify_manifest          <worktree> <manifest>  -> 0 iff copy AND live source
#                                                               both still match the manifest
#   archive_need_kb                  <worktree> <files>    -> KiB the copy + bundle may take
#   archive_free_kb                  <path>                -> KiB free on the filesystem holding it
#   archive_root_why                 <archive-root> <worktree> -> a HOLD reason when the archive
#                                                               could not outlive the worktree
#   archive_create_bundle            <worktree> <bundle-path>
#   archive_verify_bundle            <worktree> <bundle-path>
#   archive_fence_take               <worktree>            -> archive-worktrees.sh fences it off
#                                                               from spawn-task.sh, sets _ARCHIVE_FENCE
#   archive_fence_why                <worktree> [own-fence] -> a HOLD reason while another
#                                                               archive run or a spawn-task holds it
#   archive_fence_enter / _leave     <worktree>            -> spawn-task.sh's side of the fence
#
# Results that a caller needs alongside a failure reason travel in globals
# (_ARCHIVE_MANIFEST, _ARCHIVE_WHY, _ARCHIVE_KEEP, _ARCHIVE_EXCLUDED), never
# through `$(…)`: a command substitution runs the function in a subshell and
# throws _ARCHIVE_WHY away, which is how every "archiving failed:" line in
# review r1 of PR #236 ended up with an empty reason.
#
# Every enumerator prints worktree-RELATIVE paths, one per line, via plain
# git plumbing — never a shell find/glob, which would have to reimplement
# .gitignore matching badly. `git ls-files --others --ignored
# --exclude-standard` is used for ignored files specifically because `git
# status --porcelain --ignored` collapses a wholly-ignored directory like
# `.handoffs/` or `tmp/` into ONE line ("!! tmp/") and silently drops every
# file beneath it — verified empirically 2026-10-05: a `tmp/sub/file1.txt`
# two levels under an ignored `tmp/` dir shows up under `ls-files` and NOT
# under `status --porcelain --ignored`'s one collapsed line.
#
# archive_copy_and_manifest's PRECONDITION: `files` is non-empty. Both
# callers skip archiving entirely when there is nothing to archive (a
# worktree with zero ignored/untracked/dirty files trivially satisfies the
# "has been archived" precondition with no manifest at all) — this function
# and archive_verify_manifest never special-case "nothing to do" so an
# accidentally-empty manifest can never be mistaken for "verified".
set -uo pipefail

_ARCHIVE_WHY=""; _ARCHIVE_MANIFEST=""; _ARCHIVE_KEEP=""; _ARCHIVE_EXCLUDED=""
_ARCHIVE_FENCE=""; _ARCHIVE_SPAWN_INTENT=""

# Ignored directories that are build output or dependency caches: re-created
# by an install/build, routinely 7k-28k files each (review r1 M2, measured on
# the real ~/Code preview), so copying them only fills the disk. They are
# never copied; archive_record_exclusions lists each one in the manifest as
# an EXCLUDED line so the archive says what it deliberately left out.
# Applied to IGNORED files only — a tracked or untracked file under a
# directory with one of these names is real work and is always copied.
_ARCHIVE_REGEN_DIRS="node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .next .turbo .parcel-cache .svelte-kit dist build"

_archive_regen_awk() {                  # keep|excluded ; stdin: relpaths
  awk -v mode="$1" -v names="$_ARCHIVE_REGEN_DIRS" '
    BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) regen[a[i]] = 1 }
    $0 == "" { next }
    {
      k = split($0, c, "/"); hit = 0; p = ""
      for (i = 1; i < k; i++) { p = p c[i] "/"; if (c[i] in regen) { hit = 1; break } }
      if (!hit) { if (mode == "keep") print; next }
      if (mode == "excluded") cnt[p]++
    }
    END { if (mode == "excluded") for (p in cnt) printf "%d\t%s\n", cnt[p], p }'
}

# archive_split_regenerable <newline-separated ignored files>
# Sets _ARCHIVE_KEEP (files to copy) and _ARCHIVE_EXCLUDED ("<count>\t<dir>/"
# per excluded directory). Nonzero if the split itself failed — the caller
# must HOLD then, never treat an empty _ARCHIVE_KEEP as "nothing to copy".
archive_split_regenerable() {
  _ARCHIVE_KEEP=""; _ARCHIVE_EXCLUDED=""
  _ARCHIVE_KEEP=$(printf '%s\n' "$1" | _archive_regen_awk keep) || return 1
  _ARCHIVE_EXCLUDED=$(printf '%s\n' "$1" | _archive_regen_awk excluded | sort -t "$(printf '\t')" -k2) || return 1
}

archive_enumerate_ignored() {           # <worktree> -> ignored files, one per line
  git -C "$1" ls-files --others --ignored --exclude-standard 2>/dev/null
}

archive_enumerate_untracked() {         # <worktree> -> untracked, non-ignored files
  git -C "$1" ls-files --others --exclude-standard 2>/dev/null
}

archive_enumerate_tracked_dirty() {     # <worktree> -> tracked files differing from HEAD
  git -C "$1" diff --name-only HEAD 2>/dev/null
}

# archive_copy_and_manifest <worktree> <dest-dir> <newline-separated files>
#
# Copies each worktree-relative path into <dest-dir>/files/<path> and writes
# <dest-dir>/MANIFEST.sha256 as TAB-separated "<sha256>\t<size>\t<relpath>"
# lines, hashing the SOURCE (not the copy) as it is written — the copy's own
# integrity is checked separately, by archive_verify_manifest, which is the
# actual "copy has been checked" proof the proposal requires; a cp exit code
# alone is not that proof. Sets _ARCHIVE_MANIFEST to the manifest path and
# returns 0 on full success; on the first failure, returns 1 with
# _ARCHIVE_WHY set and leaves whatever partial copy exists on disk for the
# caller to inspect or discard — it is never reported as a valid manifest.
# Call it directly, never as `$(archive_copy_and_manifest …)` (see header).
archive_copy_and_manifest() {
  local wt="$1" dest="$2" files="$3" rel src dst sha sz manifest target anc
  _ARCHIVE_WHY=""; _ARCHIVE_MANIFEST=""
  manifest="$dest/MANIFEST.sha256"
  if ! mkdir -p "$dest/files" 2>/dev/null; then
    _ARCHIVE_WHY="could not create $dest/files"
    return 1
  fi
  if ! : > "$manifest" 2>/dev/null; then
    _ARCHIVE_WHY="could not create manifest at $manifest"
    return 1
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    src="$wt/$rel"
    dst="$dest/files/$rel"
    # Never write through an already-archived symlink (review r1 LOW): a
    # tracked dir replaced by a symlink sorts before its own descendants
    # ("a" before "a/sub/b"), so by the time a descendant's mkdir -p runs,
    # $wt/a is itself a symlink and mkdir -p follows it into whatever it
    # targets, creating real directories there. Refuse before any mkdir.
    anc="$rel"
    while case "$anc" in */*) true ;; *) false ;; esac; do
      anc="${anc%/*}"
      if [ -L "$wt/$anc" ]; then
        _ARCHIVE_WHY="path beneath a symlink: $rel"
        return 1
      fi
    done
    if ! mkdir -p "$(dirname "$dst")" 2>/dev/null; then
      _ARCHIVE_WHY="could not create directory for $rel"
      return 1
    fi
    # A symlink (to anything — a directory, a file, something outside this
    # worktree entirely, e.g. ingest/node_modules -> the primary checkout's
    # own node_modules) is archived AS A SYMLINK: its target is recorded in
    # the manifest and reproduced here as a symlink, never dereferenced and
    # never copied. `-f` below follows a symlink to judge its TARGET, so a
    # symlink to a directory reads as "not a regular file" and was
    # misreported as vanished (real-fleet --apply, batch-1.log, 2026-10-05).
    # `-L` is checked first and independently of whether the target exists —
    # a broken symlink is still archived as one, never treated as missing.
    if [ -L "$src" ]; then
      target=$(readlink "$src" 2>/dev/null)
      if [ -z "$target" ]; then
        _ARCHIVE_WHY="could not read symlink target: $rel"
        return 1
      fi
      if ! ln -s "$target" "$dst" 2>/dev/null; then
        _ARCHIVE_WHY="could not record symlink for $rel"
        return 1
      fi
      printf 'SYMLINK\t%s\t%s\n' "$target" "$rel" >> "$manifest"
      continue
    fi
    if [ ! -f "$src" ]; then
      _ARCHIVE_WHY="source file vanished before archiving: $rel"
      return 1
    fi
    if ! cp -p "$src" "$dst" 2>/dev/null; then
      _ARCHIVE_WHY="copy failed for $rel"
      return 1
    fi
    sha=$(shasum -a 256 "$src" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$sha" ]; then
      _ARCHIVE_WHY="could not hash source file: $rel"
      return 1
    fi
    sz=$(wc -c < "$src" 2>/dev/null | tr -d ' ')
    printf '%s\t%s\t%s\n' "$sha" "${sz:-0}" "$rel" >> "$manifest"
  done <<<"$files"
  _ARCHIVE_MANIFEST="$manifest"
  return 0
}

# archive_record_exclusions <dest-dir> <"<count>\t<dir>/" lines>
# Appends one "EXCLUDED\t<file-count>\t<dir>/" line per excluded directory to
# <dest-dir>/MANIFEST.sha256 (creating it when nothing else was copied).
# archive_verify_manifest skips these lines: there is no copy to hash.
archive_record_exclusions() {
  local dest="$1" excluded="$2"
  _ARCHIVE_WHY=""
  [ -n "$excluded" ] || return 0
  if ! mkdir -p "$dest" 2>/dev/null \
    || ! printf '%s\n' "$excluded" | awk -F'\t' 'NF == 2 { printf "EXCLUDED\t%s\t%s\n", $1, $2 }' >> "$dest/MANIFEST.sha256" 2>/dev/null; then
    _ARCHIVE_WHY="could not record excluded directories in $dest/MANIFEST.sha256"
    return 1
  fi
}

# archive_verify_manifest <worktree> <manifest-path>
#
# Recomputes sha256 for every entry TWICE: once against the copy sitting at
# dirname(manifest)/files/<relpath> (did the copy survive intact), and once
# against the live source at <worktree>/<relpath> when it still exists (has
# it changed since archiving — a TOCTOU gap close-done-workers.sh's own
# caller closes by archiving immediately before checking "no dirty tree",
# not after). A manifest with zero parseable entries is never "verified" —
# that is the empty-archive case, which callers must detect before ever
# calling this, not something this function waves through.
archive_verify_manifest() {
  local wt="$1" manifest="$2" dest sha sz rel csha ssha entries=0
  _ARCHIVE_WHY=""
  [ -f "$manifest" ] || { _ARCHIVE_WHY="no manifest at $manifest"; return 1; }
  dest="$(dirname "$manifest")"
  while IFS=$'\t' read -r sha sz rel; do
    [ -n "$sha" ] && [ -n "$rel" ] || continue
    [ "$sha" = EXCLUDED ] && continue
    entries=$((entries + 1))
    if [ "$sha" = SYMLINK ]; then
      # sz holds the recorded TARGET TEXT here, never a hash — comparing it
      # via `readlink` keeps this check from ever dereferencing the link.
      csha=$(readlink "$dest/files/$rel" 2>/dev/null)
      if [ "$csha" != "$sz" ]; then
        _ARCHIVE_WHY="archived symlink does not match its manifest target: $rel"
        return 1
      fi
      if [ -L "$wt/$rel" ]; then
        ssha=$(readlink "$wt/$rel" 2>/dev/null)
        if [ "$ssha" != "$sz" ]; then
          _ARCHIVE_WHY="live source no longer matches its manifest target (changed since archiving): $rel"
          return 1
        fi
      elif [ -e "$wt/$rel" ]; then
        # Replaced by a regular file (or dir) between the copy and this
        # recheck: same PATH, so the file-list comparison never catches
        # it — only this type check does (review r1 MED).
        _ARCHIVE_WHY="live source is no longer a symlink: $rel"
        return 1
      fi
      continue
    fi
    csha=$(shasum -a 256 "$dest/files/$rel" 2>/dev/null | cut -d' ' -f1)
    if [ "$csha" != "$sha" ]; then
      _ARCHIVE_WHY="archived copy does not match its manifest sha256: $rel"
      return 1
    fi
    if [ -f "$wt/$rel" ]; then
      ssha=$(shasum -a 256 "$wt/$rel" 2>/dev/null | cut -d' ' -f1)
      if [ "$ssha" != "$sha" ]; then
        _ARCHIVE_WHY="live source no longer matches its manifest sha256 (changed since archiving): $rel"
        return 1
      fi
    fi
  done < "$manifest"
  if [ "$entries" -eq 0 ]; then
    _ARCHIVE_WHY="manifest has no parseable entries"
    return 1
  fi
  return 0
}

# archive_need_kb <worktree> <newline-separated files> -> KiB the archive
# copy (those files) plus a bundle of HEAD can take. The bundle estimate is
# the repo's whole object store (loose + packed) — an upper bound, never an
# underestimate. Nonzero when anything could not be sized.
archive_need_kb() {
  local wt="$1" files="$2" fkb=0 okb
  if [ -n "$files" ]; then
    fkb=$(cd "$wt" 2>/dev/null && printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 du -k 2>/dev/null \
      | awk '{ s += $1 } END { print s + 0 }') || return 1
  fi
  okb=$(git -C "$wt" count-objects -v 2>/dev/null \
    | awk '$1 == "size:" || $1 == "size-pack:" { s += $2; f = 1 } END { if (!f) exit 1; print s + 0 }') || return 1
  printf '%s\n' "$((fkb + okb))"
}

# archive_free_kb <path> -> KiB available on the filesystem that holds
# <path> (or its nearest existing ancestor). Nonzero when df gives nothing.
archive_free_kb() {
  local d="$1"
  while [ ! -d "$d" ]; do
    case "$d" in /|.|'') return 1 ;; esac
    d=$(dirname "$d")
  done
  df -Pk "$d" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4; f = 1 } END { exit !f }'
}

# archive_root_why <archive-root> <worktree> -> prints a HOLD reason, or
# nothing. The verified archive must outlive the worktree it was taken from
# (review r2 M2 of PR #236): a RELATIVE root resolves against whatever cwd
# the caller happens to have, and a root at or beneath the worktree is
# deleted by the very `git worktree remove` it was meant to survive — the
# only copy goes with it. Compared raw AND resolved (the nearest existing
# ancestor's realpath plus the not-yet-created rest), so a symlinked or
# `..` spelling of the same place is caught too. Unresolvable = a reason.
archive_root_why() {
  local root="$1" wt="$2" wr d rest="" rr r w
  case "$root" in
    /*) ;;
    *) printf 'archive root %s is not an absolute path\n' "$root"; return 0 ;;
  esac
  if ! wr=$(cd "$wt" 2>/dev/null && pwd -P); then
    printf 'cannot resolve %s to check the archive root against it\n' "$wt"
    return 0
  fi
  d="$root"
  while [ ! -d "$d" ]; do
    rest="/$(basename "$d")$rest"
    d=$(dirname "$d")
  done
  if ! rr=$(cd "$d" 2>/dev/null && pwd -P); then
    printf 'cannot resolve the archive root %s\n' "$root"
    return 0
  fi
  rr="${rr%/}$rest"
  for r in "$root" "$rr"; do
    for w in "$wt" "$wr"; do
      case "$r/" in
        "$w"/*)
          printf 'archive root %s is inside this worktree (%s) — the archive would be deleted with it\n' "$root" "$w"
          return 0
          ;;
      esac
    done
  done
}

# A git bundle of HEAD — every commit reachable from the current tip,
# regardless of branch name, so it captures a detached-HEAD checkout the
# same as a named branch. Not a substitute for the file manifest above (a
# bundle holds commits, not uncommitted/untracked/ignored content) — the two
# together are what "preserve everything this worktree had" means.
archive_create_bundle() {               # <worktree> <bundle-path>
  git -C "$1" bundle create "$2" HEAD 2>/dev/null
}

# Verified against the SOURCE repo (`git -C <worktree>`), never the caller's
# cwd: `git bundle verify` needs a repository, so a bare `git bundle verify`
# REFUSED every archive when run from a non-repo dir (launchd, cron, $HOME)
# and silently checked prerequisites against an unrelated repo otherwise.
archive_verify_bundle() {               # <worktree> <bundle-path>
  git -C "$1" bundle verify "$2" >/dev/null 2>&1
}

# ---- the spawn/archive fence (review r3 L1 of PR #236) ------------------------
# `git worktree lock` cannot span `git worktree remove` (git refuses a locked
# worktree without --force --force), and spawn-task.sh read that lock once,
# long before it wrote .handoffs/ — so a re-spawn could pass its check, then
# write a SPEC.md that the remove deleted unarchived. Two kinds of file in
# the worktree's git admin dir (<common-dir>/worktrees/<id>) close that. They
# are outside the worktree, so they never enter a file listing or an archive,
# and `git worktree remove`/`prune` delete them with the admin dir:
#   herdr-archive-fence        archive-worktrees.sh's: created exclusively
#                              BEFORE it locks the worktree, kept until AFTER
#                              the remove.
#   herdr-spawn-intent.<pid>   spawn-task.sh's: created BEFORE it looks for
#                              the fence, deleted when spawn-task.sh exits.
# Each side puts its own file down and only THEN looks for the other's:
#   * a spawn that looked before the fence existed still has its intent down
#     at the archiver's pre-remove re-check (which runs after it fenced), and
#     that re-check REFUSES the remove;
#   * a spawn that looks while the fence exists refuses itself;
#   * a spawn that looks once the remove has run finds its own intent gone
#     with the admin dir (or cannot write it), and refuses itself.
# No timing assumption, no settle period. A fence or intent left behind by a
# SIGKILL is never stolen: both sides keep refusing and print its path.

_archive_admin_dir() {                  # <worktree> -> its git admin dir; nonzero unless a linked worktree
  local gd
  gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  case "$gd" in */worktrees/?*) ;; *) return 1 ;; esac
  [ -f "$gd/commondir" ] || return 1
  printf '%s\n' "$gd"
}

# archive_fence_take <worktree> -> 0 with _ARCHIVE_FENCE set to the fence this
# process now holds, or 1 with _ARCHIVE_WHY. `ln` of a fully written temp
# file is the exclusive create: it fails when the fence already exists, so two
# runs can never both hold it and a reader never sees a half-written one.
# Call directly, never as `$(…)`.
archive_fence_take() {
  local gd f tmp
  _ARCHIVE_FENCE=""
  if ! gd=$(_archive_admin_dir "$1"); then
    _ARCHIVE_WHY="cannot locate the worktree's git admin dir to fence it off from a re-spawn"
    return 1
  fi
  f="$gd/herdr-archive-fence"; tmp="$f.take.$$"
  if ! printf 'archive-worktrees.sh pid %s\n' "$$" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    _ARCHIVE_WHY="could not write the spawn fence in $gd"
    return 1
  fi
  if ! ln "$tmp" "$f" 2>/dev/null; then
    rm -f "$tmp"
    _ARCHIVE_WHY="the spawn fence $f is already held ($(cat "$f" 2>/dev/null || echo '?'))"
    return 1
  fi
  rm -f "$tmp"
  _ARCHIVE_FENCE="$f"
}

# archive_fence_why <worktree> [own-fence] -> prints a HOLD/REFUSE reason, or
# nothing: a fence that is not <own-fence> (another archive run, or one a
# SIGKILL left), or any spawn-task intent at all.
archive_fence_why() {
  local gd s
  if ! gd=$(_archive_admin_dir "$1"); then
    printf 'cannot locate its git admin dir, so a re-spawn into it cannot be ruled out\n'
    return
  fi
  if [ -e "$gd/herdr-archive-fence" ] && [ "$gd/herdr-archive-fence" != "${2:-}" ]; then
    printf 'fenced by another archive run (%s) — if that pid is gone, `git worktree unlock` it and trash %s\n' \
      "$(cat "$gd/herdr-archive-fence" 2>/dev/null || echo '?')" "$gd/herdr-archive-fence"
    return
  fi
  for s in "$gd"/herdr-spawn-intent.*; do
    [ -e "$s" ] || continue
    printf 'spawn-task pid %s is writing into this worktree (%s — if that pid is gone, trash it)\n' "${s##*.}" "$s"
    return
  done
}

# archive_fence_enter <worktree> -> spawn-task.sh's side, run immediately
# before its first write into the worktree. 0: the intent file is down
# (_ARCHIVE_SPAWN_INTENT) and no archive run holds the worktree — write away;
# archive_fence_leave must run at exit. 1: refuse, reason in _ARCHIVE_WHY.
archive_fence_enter() {
  local gd
  _ARCHIVE_SPAWN_INTENT=""
  if ! gd=$(_archive_admin_dir "$1") || ! : > "$gd/herdr-spawn-intent.$$" 2>/dev/null; then
    _ARCHIVE_WHY="$1 is not a linked git worktree whose admin dir takes a spawn intent (removed while spawning?)"
    return 1
  fi
  _ARCHIVE_SPAWN_INTENT="$gd/herdr-spawn-intent.$$"
  if [ -e "$gd/herdr-archive-fence" ]; then
    _ARCHIVE_WHY="$1 is being archived ($(cat "$gd/herdr-archive-fence" 2>/dev/null || echo '?'); if that pid is gone, \`git worktree unlock\` it and trash $gd/herdr-archive-fence)"
    archive_fence_leave
    return 1
  fi
  if [ ! -e "$_ARCHIVE_SPAWN_INTENT" ]; then
    _ARCHIVE_SPAWN_INTENT=""
    _ARCHIVE_WHY="$1 is being archived (removed while spawning)"
    return 1
  fi
}

archive_fence_leave() {
  [ -z "$_ARCHIVE_SPAWN_INTENT" ] || rm -f "$_ARCHIVE_SPAWN_INTENT"
  _ARCHIVE_SPAWN_INTENT=""
}
