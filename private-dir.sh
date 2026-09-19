#!/usr/bin/env bash
# private-dir.sh — create a repo's self-ignoring .private/ and PROVE it is ignored.
#
# ~/Code/AGENTS.md has pointed at this script for weeks; it did not exist, so
# every session that reached for it either hand-rolled the directory or pasted
# client data somewhere the secret/PII guard then blocked (thurber-os,
# 2026-09-19). The point is not the mkdir — it is the `git check-ignore`
# evidence, because a .gitignore that silently does not match is exactly the
# failure this directory exists to prevent.
#
# Usage: private-dir.sh [repo-path]    (default: the repo containing $PWD)
set -euo pipefail

target="${1:-.}"
root="$(git -C "$target" rev-parse --show-toplevel)"
private="$root/.private"

mkdir -p "$private"
# `*` ignores everything including this file itself, so nothing here can be
# staged even by `git add -A`. Same trick as .handoffs/.
if [[ ! -f "$private/.gitignore" ]]; then
	printf '*\n' > "$private/.gitignore"
fi

# ===== VERIFY =====
probe="$private/.private-dir-probe-$$"
printf 'probe\n' > "$probe"
if git -C "$root" check-ignore -q "$probe"; then
	rm -f "$probe"
	echo "OK  $private is ignored — verified with git check-ignore on a real file"
	git -C "$root" check-ignore -v "$private/.gitignore"
else
	rm -f "$probe"
	echo "FAIL $private is NOT ignored — do not put client data here" >&2
	echo "     $private/.gitignore exists but does not match — it should be exactly '*'" >&2
	echo "     (a pre-existing empty file is the case seen in practice; a negation in" >&2
	echo "     $root/.gitignore cannot cause this, the deeper file wins)" >&2
	exit 1
fi

cat <<EOF

Put real client data (names, emails, phones, street addresses, corpora) in:
  $private
and reference it from tracked text BY PATH, never by value.

Undo: rm -rf "$private"
EOF
