#!/usr/bin/env bash
# lib/trust.sh — approval for a REPO-LOCAL file that this tool will execute.
#
# Extracted verbatim from quick-action.sh, which has carried it since the
# repo-local action tier shipped. It moved here the moment a SECOND surface
# needed it: a repo-local project space (`<repo>/.herdr-control/project.json`)
# carries pane startup commands, which is the same trust problem as a
# repo-local quick action — shell that arrived with a `git pull`, from a branch
# anyone could have pushed.
#
# Keyed by (sha256 of content, path), so EDITING an already-approved file
# revokes its approval: the hash no longer matches and the next run asks
# again. That is the property worth having — approving a file once must not
# approve whatever it becomes later.
#
# Global-tier files (your own `~/.config`) need no approval: you wrote them.

TRUST_DB="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-control/trusted-actions"

_trust_hash() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

is_trusted() {  # <file> -> 0 iff approved at its CURRENT content hash
  local f="$1" h
  [ -f "$TRUST_DB" ] || return 1
  h=$(_trust_hash "$f")
  [ -n "$h" ] || return 1
  grep -qxF "$h  $f" "$TRUST_DB" 2>/dev/null
}

trust_file() {  # <file> -> record approval, replacing any stale entry for it
  local f="$1" h dir
  h=$(_trust_hash "$f")
  [ -n "$h" ] || { echo "trust: cannot hash $f" >&2; return 1; }
  dir=$(dirname "$TRUST_DB")
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null
  if [ -f "$TRUST_DB" ]; then
    grep -vF "  $f" "$TRUST_DB" >"$TRUST_DB.tmp" 2>/dev/null || : >"$TRUST_DB.tmp"
    mv "$TRUST_DB.tmp" "$TRUST_DB"
  fi
  printf '%s  %s\n' "$h" "$f" >>"$TRUST_DB"
  chmod 600 "$TRUST_DB" 2>/dev/null || true
}
