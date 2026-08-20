#!/usr/bin/env bash
# lib/engineering-stage2.sh — shared Stage-2 proposal-doc discovery for the
# Engineering Evolution Loop (thurber-os docs/engineering-evolution-loop-charter.md
# §3 Stage 2).
#
# Extracted from stage2-diagnose.sh (which used this exact search inline to
# find its own carry-over doc) so stage3-execute.sh finds the SAME latest
# doc through the SAME logic, instead of re-implementing the search a second
# time and risking the two ever disagreeing about what "latest" means.
# shellcheck shell=bash

# stage2_find_latest_doc <thurber_os_repo> -> prints the path to the most
# recent Stage-2 (or original bootstrap) proposal doc on stdout and returns 0,
# or prints nothing and returns 1 if none exists yet.
#
# Prior docs can live in two places: merged onto main, or still sitting on an
# unmerged evolution-loop/* worktree branch — as of this writing neither the
# bootstrap pass nor the first real Stage-2 pass had landed on main yet, so a
# main-only search would wrongly conclude "no prior pass exists." Search both.
stage2_find_latest_doc() {
  local thurber_os="$1" doc
  doc="$( { ls -1 "$thurber_os"/docs/tracking/*-stage2-diagnose-pass.md 2>/dev/null; \
    ls -1 "$HOME"/.herdr/worktrees/thurber-os/evolution-loop/*/docs/tracking/*-stage2-diagnose-pass.md 2>/dev/null; \
    ls -1 "$HOME"/.herdr/worktrees/thurber-os/evolution-loop/*/docs/tracking/*-fable5-bootstrap-diagnosis.md 2>/dev/null; \
    } | awk '{ n=split($0,a,"/"); print a[n]"\t"$0 }' | sort | tail -1 | cut -f2- || true )"
  [ -n "$doc" ] || return 1
  printf '%s\n' "$doc"
}

# stage2_doc_location_label <thurber_os_repo> <doc_path> -> "on main" or
# "UNMERGED -- still on its own branch, not main" — the same on-main/
# unmerged distinction stage2-diagnose.sh's brief already surfaces to the
# next Stage-2 pass, factored out so stage3-execute.sh can report the same
# thing in its own output/audit trail without re-deriving it differently.
stage2_doc_location_label() {
  local thurber_os="$1" doc="$2"
  case "$doc" in
    "$thurber_os"/*) printf 'on main\n' ;;
    *) printf 'UNMERGED -- still on its own branch, not main\n' ;;
  esac
}
