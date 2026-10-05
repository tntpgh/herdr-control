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
#   archive_create_bundle            <worktree> <bundle-path>
#   archive_verify_bundle            <worktree> <bundle-path>
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
  local wt="$1" dest="$2" files="$3" rel src dst sha sz manifest
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
    if [ ! -f "$src" ]; then
      _ARCHIVE_WHY="source file vanished before archiving: $rel"
      return 1
    fi
    dst="$dest/files/$rel"
    if ! mkdir -p "$(dirname "$dst")" 2>/dev/null; then
      _ARCHIVE_WHY="could not create directory for $rel"
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
