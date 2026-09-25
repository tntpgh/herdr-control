#!/usr/bin/env bash
# Proves a terminated foreground watch reports why it stopped.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
set +e
bash "$here/wake-on-evidence.sh" "$work/events" '^DONE$' 10 1 >"$work/out" 2>"$work/err" &
pid=$!
sleep .2
kill -TERM "$pid"
wait "$pid"
rc=$?
set -e
[ "$rc" -eq 4 ] || { echo "FAIL: exit $rc, expected 4"; exit 1; }
grep -q WATCH_INTERRUPTED "$work/err" || { echo "FAIL: missing interruption diagnostic"; exit 1; }
printf 'PASS: interrupted watch reports WATCH_INTERRUPTED\n'
