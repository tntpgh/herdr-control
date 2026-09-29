#!/usr/bin/env bash
# bash-write-targets.sh — CLI wrapper around command-policy.sh's
# bash_write_targets, so agent-hooks/omp-herdr-control.ts's write-scope hook
# (#184) can shell out to the SAME parser classify_command's peer-approval
# rule uses, instead of a second TypeScript reimplementation of redirect/
# verb parsing — the same pattern pretoolRegistrationBlock already uses for
# lib/pretool-registration.sh.
#
# Usage: bash-write-targets.sh <raw command text> <cwd>
# Stdout: one "TARGET\t<abs path>", "COMPUTED\t<raw text>", or
# "UNPARSED\t<reason>" line per write target (see command-policy.sh's #184
# section for the full contract). The caller MUST treat COMPUTED and
# UNPARSED identically to "outside scope"; only genuinely empty output means
# this command names no write target at all. Always exits 0.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/command-policy.sh"

bash_write_targets "${1:-}" "${2:-.}"
exit 0
