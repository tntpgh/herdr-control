#!/usr/bin/env bash
# approvals-pane.sh — the Pending Approvals pane: survey first, answer second.
#
# Two keystrokes, deliberately. The survey changes nothing; answering is a
# separate `y`, and even then every answer goes through herdr-select.sh, which
# re-reads the options at press time, refuses a changed prompt, a recycled
# pane, or a CLIPPED approval nobody can fully see. This pane adds no
# authority — it removes the four manual steps that made the compliant path
# more expensive than the one the guard now denies.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bash "$here/sweep-approvals.sh" || true
printf '\n'
read -r -p "Answer the operational ones through herdr-select? [y/N] " a || a=""
case "${a:-}" in
  y|Y|yes|YES)
    printf '\n'
    bash "$here/sweep-approvals.sh" --answer || true ;;
  *) printf 'Nothing answered.\n' ;;
esac
printf '\nPress enter to close.'
read -r _ || true
