#!/usr/bin/env bash
# verify-hub-factory-env.sh — `install.sh --hub` must not turn a running
# factory OFF. The hub template carries none of the owner-dispatch /
# queue-supervisor keys (activation is a human decision), so before
# carry_hub_factory_env every documented repair re-render (restart.sh:36)
# dropped them silently. Offline: temp plists only; launchctl is never called.
#
#   bash verify-hub-factory-env.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/launchd/agent-lib.sh"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_APP_DIR="$WORK/app"
TPL="$here/com.herdr-control.hub.plist.template"
get() { plutil -extract "EnvironmentVariables.$1" raw -o - "$2" 2>/dev/null; }
render() { render_hub_plist "$TPL" "$1" /opt/homebrew/bin/python3.99; }

# A live plist as it exists on this machine today: a template render plus the
# hand-added factory keys, one of them with ':' and '=' in its value, plus one
# NON-factory key that must never be carried.
LIVE="$WORK/live.plist"
render "$LIVE"
plutil -replace EnvironmentVariables.HERDR_QUEUE_SUPERVISOR -string 1 "$LIVE"
plutil -replace EnvironmentVariables.HERDR_QUEUE_SUPERVISOR_LANES -string thurber-os,kb "$LIVE"
plutil -replace EnvironmentVariables.HERDR_RESULT_AVAILABILITY_ROOTS -string "thurber-os=/a/b:kb=/c d/e" "$LIVE"
plutil -replace EnvironmentVariables.HERDR_OWNER_DISPATCH_AUTH_DB -string /x/dispatch-auth.sqlite3 "$LIVE"
plutil -replace EnvironmentVariables.SOMETHING_ELSE -string keep-out "$LIVE"

printf '== a re-render carries exactly the factory keys the live plist sets ==\n'
NEW="$WORK/new.plist"; render "$NEW"
check "precondition: the bare template render has no factory key" '[ -z "$(get HERDR_QUEUE_SUPERVISOR "$NEW")" ]'
carry_hub_factory_env "$LIVE" "$NEW"; rc=$?
check "carry returns 0" '[ "$rc" = 0 ]'
check "HERDR_QUEUE_SUPERVISOR carried verbatim" '[ "$(get HERDR_QUEUE_SUPERVISOR "$NEW")" = 1 ]'
check "HERDR_QUEUE_SUPERVISOR_LANES carried verbatim" '[ "$(get HERDR_QUEUE_SUPERVISOR_LANES "$NEW")" = thurber-os,kb ]'
check "a value with ':', '=' and a space survives byte-for-byte" \
  '[ "$(get HERDR_RESULT_AVAILABILITY_ROOTS "$NEW")" = "thurber-os=/a/b:kb=/c d/e" ]'
check "HERDR_OWNER_DISPATCH_AUTH_DB carried verbatim" '[ "$(get HERDR_OWNER_DISPATCH_AUTH_DB "$NEW")" = /x/dispatch-auth.sqlite3 ]'
check "a factory key the live plist LACKS is not invented (re-render never turns anything on)" \
  '[ -z "$(get HERDR_QUEUE_SUPERVISOR_STANDING "$NEW")" ] && [ -z "$(get HERDR_OWNER_DISPATCH "$NEW")" ]'
check "a non-factory key is never carried" '[ -z "$(get SOMETHING_ELSE "$NEW")" ]'
check "template keys are untouched (HERDR_EDGE_PEER_ANSWER still 1)" '[ "$(get HERDR_EDGE_PEER_ANSWER "$NEW")" = 1 ]'
check "the result still lints, so stage_plist would accept it" 'plutil -lint "$NEW" >/dev/null'

printf '== first install / broken live plist ==\n'
NEW2="$WORK/new2.plist"; render "$NEW2"; cp "$NEW2" "$WORK/before2"
carry_hub_factory_env "$WORK/absent.plist" "$NEW2"; rc=$?
check "no live plist: no-op, returns 0, render byte-identical" '[ "$rc" = 0 ] && cmp -s "$NEW2" "$WORK/before2"'
printf 'not a plist' > "$WORK/broken.plist"
NEW3="$WORK/new3.plist"; render "$NEW3"
err="$(carry_hub_factory_env "$WORK/broken.plist" "$NEW3" 2>&1)"; rc=$?
check "unparseable live plist: warns, returns 0 so the repair still proceeds" \
  '[ "$rc" = 0 ] && [[ "$err" == *"does not parse"* ]]'

printf '== a carry that cannot write refuses, so install.sh never stages a factory-less plist ==\n'
carry_hub_factory_env "$LIVE" "$WORK/missing-dir/tmp.plist" 2>/dev/null; rc=$?
check "unwritable temp: returns 1" '[ "$rc" = 1 ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
