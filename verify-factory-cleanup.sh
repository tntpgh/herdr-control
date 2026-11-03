#!/usr/bin/env bash
# verify-factory-cleanup.sh — cadence, scope, dry-run, and apply contract checks.
# All dependencies are throwaway stubs; no live registry or pane is touched.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/factory-cleanup-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
calls="$work/calls"
: > "$calls"

cat > "$work/conductor-exit.sh" <<'SH'
#!/usr/bin/env bash
printf 'conductor-exit %s\n' "$*" >> "$CALLS"
case " $* " in *' --summary '*) printf '2 3\n';; *) printf 'stub conductor exit\n';; esac
SH
cat > "$work/close-done-workers.sh" <<'SH'
#!/usr/bin/env bash
printf 'close-done %s\n' "$*" >> "$CALLS"
printf 'stub close-done dry run\n'
SH
chmod +x "$work/conductor-exit.sh" "$work/close-done-workers.sh"
export CALLS="$calls"
export HERDR_CONDUCTOR_EXIT_SH="$work/conductor-exit.sh"
export HERDR_CLOSE_DONE_SH="$work/close-done-workers.sh"
export HERDR_HUB_URL="http://127.0.0.1:1"

pass=0 fail=0
ok() { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
has() { grep -q -- "$1" "$2" && ok "$3" || bad "$3"; }

printf '== shift: one conductor, dry by default ==\n'
: > "$calls"
out=$(HERDR_PANE_ID=w1:p2 bash "$here/factory-cleanup.sh" --shift 2>&1)
has '^conductor-exit --conductor=w1:p2$' "$calls" 'shift scopes to current conductor without --apply'
has '^close-done ' "$calls" 'shift always prints the global residual safety gate'
printf '%s' "$out" | grep -q 'DRY RUN' && ok 'dry-run is explicit' || bad 'dry-run marker missing'

printf '== shift without identity refuses ==\n'
HERDR_PANE_ID= bash "$here/factory-cleanup.sh" --shift >/dev/null 2>&1
[ "$?" = 2 ] && ok 'missing conductor refuses' || bad 'missing conductor did not refuse'

printf '== day apply: all workers, merged-only apply ==\n'
: > "$calls"
bash "$here/factory-cleanup.sh" --day --apply >/dev/null 2>&1
has '^conductor-exit --all --apply$' "$calls" 'day apply delegates all-worker closure to conductor-exit'
has '^close-done ' "$calls" 'day apply re-runs the dry global safety gate afterward'

printf '== week: all workers plus fleet debt checklist ==\n'
: > "$calls"
out=$(bash "$here/factory-cleanup.sh" --week 2>&1)
has '^conductor-exit --all$' "$calls" 'week is fleet-scoped but dry by default'
printf '%s' "$out" | grep -q 'xd://single_copy_scan' && ok 'week names single-copy scan' || bad 'week omitted single-copy scan'
printf '%s' "$out" | grep -q 'xd://worktree_debt' && ok 'week names worktree debt scan' || bad 'week omitted worktree debt scan'

printf '== summary: stable two-integer hook contract, no second scan ==\n'
: > "$calls"
out=$(HERDR_PANE_ID=w1:p2 bash "$here/factory-cleanup.sh" --shift --summary)
[ "$out" = '2 3' ] && ok 'summary forwards exact count contract' || bad "summary was '$out'"
grep -q '^close-done ' "$calls" && bad 'summary ran global close scan' || ok 'summary is cheap and does not run global scan'

printf '== invalid cadence refuses ==\n'
bash "$here/factory-cleanup.sh" --cadence=hour >/dev/null 2>&1
[ "$?" = 2 ] && ok 'invalid cadence refuses' || bad 'invalid cadence accepted'

printf '%s\n' '-----' "passed=$pass failed=$fail"
[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
