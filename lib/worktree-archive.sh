#!/usr/bin/env bash
# lib/worktree-archive.sh — copy-then-verify primitives shared by
# close-done-workers.sh's detached-HEAD close path and archive-worktrees.sh
# (2026-10-05-worktree-archival-and-detached-close proposal).
#
# One job each, composed by the two callers rather than duplicated:
#   archive_enumerate_ignored        <worktree>            -> ignored files
#   archive_enumerate_untracked      <worktree>            -> untracked, non-ignored files
#   archive_enumerate_tracked_dirty  <worktree>             -> tracked files that differ from HEAD
#   archive_copy_and_manifest        <worktree> <dest> <files> -> writes dest/MANIFEST.sha256
#   archive_verify_manifest          <worktree> <manifest>  -> 0 iff copy AND live source
#                                                               both still match the manifest
#   archive_create_bundle            <worktree> <bundle-path>
#   archive_verify_bundle            <bundle-path>
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

_ARCHIVE_WHY=""

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
# alone is not that proof. Prints the manifest path and returns 0 on full
# success; on the first failure, returns 1 with _ARCHIVE_WHY set and leaves
# whatever partial copy exists on disk for the caller to inspect or discard
# — it is never reported as a valid manifest.
archive_copy_and_manifest() {
  local wt="$1" dest="$2" files="$3" rel src dst sha sz manifest
  _ARCHIVE_WHY=""
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
  printf '%s\n' "$manifest"
  return 0
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

# A git bundle of HEAD — every commit reachable from the current tip,
# regardless of branch name, so it captures a detached-HEAD checkout the
# same as a named branch. Not a substitute for the file manifest above (a
# bundle holds commits, not uncommitted/untracked/ignored content) — the two
# together are what "preserve everything this worktree had" means.
archive_create_bundle() {               # <worktree> <bundle-path>
  git -C "$1" bundle create "$2" HEAD 2>/dev/null
}

archive_verify_bundle() {               # <bundle-path>
  git bundle verify "$1" >/dev/null 2>&1
}
