#!/usr/bin/env bash
# private-dir.sh [<repo>] — create (or verify) this repo's `.private/`, the one
# place real client data may live inside a checkout.
#
# WHY IT EXISTS. The secret scanner's advice used to end "keep it in the DB or
# a gitignored path", which names nothing — so every session invented its own
# answer, or pasted the value into a tracked plan document and hit the guard.
# A guard that blocks work without naming the alternative teaches people to
# route around it.
#
# WHAT IT IS. `<repo-root>/.private/` holding a `.gitignore` of `*`, the same
# self-ignoring trick `.handoffs/` uses: the directory excludes itself and
# everything in it, so nothing inside can be staged even by `git add -A`, and
# no repo-level `.gitignore` edit is needed (which would itself be a tracked
# change, reviewed and merged, before anyone could save a file).
#
# WHAT BELONGS IN IT. A client's email, phone or street address; an export
# from a CRM, MLS or mailbox; anything a person did not publish about
# themselves. Keep the FILE here and reference it by path in tracked docs —
# "computed from .private/reger-corpus.json (23 messages)" carries the same
# meaning to a reader as pasting the address did, and none of the exposure.
#
# WHAT DOES NOT. Anything shared across repos belongs in the KB, where access
# is scoped and audited, not in a file on one machine. Credentials belong in
# 1Password. And a business's PUBLISHED contact — an `info@` or `sales@`
# mailbox at the vendor's own domain — is not client data at all: the scanner
# allows role
# mailboxes at business domains, so those can stay in tracked text.
set -uo pipefail

root=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null) || {
  echo "private-dir: not a git repo: ${1:-$PWD}" >&2
  exit 1
}
dir="$root/.private"
mkdir -p "$dir" || exit 1
printf '*\n' > "$dir/.gitignore"

# PROVE it, rather than announcing it: the whole value is that a file in here
# cannot be committed, and that is a property of `git check-ignore`, not of
# this script having run.
probe="$dir/.probe.$$"
: > "$probe"
if git -C "$root" check-ignore -q "$probe"; then
  verdict="ignored (verified with git check-ignore)"
else
  verdict="NOT IGNORED — something overrides it, do not put real data here"
fi
rm -f "$probe"

printf '%s\n' "$dir"
printf '  %s\n' "$verdict"
printf '  belongs here : client emails/phones/addresses, CRM and mailbox exports\n'
printf '  belongs in KB: anything another repo or another machine needs\n'
printf '  belongs in 1P: credentials\n'
printf '  fine tracked : a business PUBLISHED contact (an info@ or sales@ desk)\n'
case "$verdict" in
  NOT*) exit 1 ;;
esac
