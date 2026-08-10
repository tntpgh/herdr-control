#!/usr/bin/env bash
# verify-engineering-ledger.sh — acceptance checks for the Stage-1/E0 ledger.
#
# Uses crafted source fixtures only. It proves that unsafe strings never enter
# the digest and that one failed source still yields the other five records.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/engineering-ledger.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

ledger_now() { printf '2026-08-08T12:00:00Z\n'; }
ledger_sentry_projects_json() {
  printf '%s\n' '[{"id":"101","slug":"node-cloudflare-workers"},{"id":"202","slug":"thurber-ai"}]'
}
ledger_sentry_issues_json() {
  case "$1" in
    101) printf '%s\n' '[{"id":"1","title":"TypeError: client jane@example.com sent xoxb-test","count":"4","firstSeen":"2026-08-08T01:00:00Z","lastSeen":"2026-08-08T02:00:00Z"}]' ;;
    202) printf '%s\n' '[{"id":"2","title":"jane@example.com secret payload","count":"1","firstSeen":"2026-08-08T03:00:00Z","lastSeen":"2026-08-08T04:00:00Z"}]' ;;
    *) return 1 ;;
  esac
}
ledger_kb_rows_json() {
  printf '%s\n' '[{"run_id":"00000000-0000-0000-0000-000000000001","step_label":"sync_jane@example.com","error_class":"ValueError","error_signature":"ValueError: password=hunter2 /Users/alice/client.txt","started_at":"2026-08-08T05:00:00+00:00","run_started_at":"2026-08-08T04:00:00+00:00"}]'
}
ledger_gh_prs_json() {
  printf '%s\n' '[{"number":7,"state":"MERGED","createdAt":"not-a-date jane@example.com","updatedAt":"2026-08-08T02:00:00Z","mergedAt":"2026-08-08T02:00:00Z","closedAt":"2026-08-08T02:00:00Z","title":"client payload must never be selected"}]'
}
ledger_gh_runs_json() {
  printf '%s\n' '[{"databaseId":9,"status":"completed","conclusion":"success","createdAt":"2026-08-08T03:00:00Z","updatedAt":"2026-08-08T04:00:00Z","headBranch":"client-jane@example.com"}]'
}

printf '== sanitization + six-source digest ==\n'
export ENGINEERING_LEDGER_DIR="$WORK/sanitized"
engineering_ledger_poll > "$WORK/summary-1"
digest="$ENGINEERING_LEDGER_DIR/2026-08-08.jsonl"
[ -f "$digest" ] && ok 'digest file created' || bad 'digest file missing'
[ "$(wc -l < "$digest" | tr -d ' ')" = 6 ] && ok 'one JSON line per source (six total)' || bad 'wrong source line count'
jq -e . "$digest" >/dev/null 2>&1 && ok 'every digest line is valid JSON' || bad 'invalid JSONL'

if rg -qi 'jane|xoxb|hunter2|/Users/alice|client payload|headBranch' "$digest"; then
  bad 'raw secret/PII/request-like fixture content leaked'
else
  ok 'raw secret/PII/request-like fixture content absent'
fi
[ "$(jq -r 'select(.source=="sentry" and .source_id=="tourguide") | .top_issues[0].signature' "$digest")" = TypeError ] \
  && ok 'Sentry title reduced to pre-colon error class' || bad 'Sentry signature reduction failed'
[ "$(jq -r 'select(.source=="sentry" and .source_id=="thurber-ai") | .top_issues[0].signature' "$digest")" = redacted ] \
  && ok 'PII-only Sentry title fails closed' || bad 'PII-only title was not redacted'
[ "$(jq -r 'select(.source=="kb") | .failures[0].step_label' "$digest")" = redacted ] \
  && ok 'unsafe KB step label fails closed' || bad 'unsafe KB step label was not redacted'
[ "$(jq -r 'select(.source=="github" and .source_id=="knowledge-base") | .pull_requests.latest_created_at' "$digest")" = null ] \
  && ok 'malformed GitHub timestamp is dropped without aborting' || bad 'malformed timestamp leaked or aborted'
rg -q 'new_signatures=TypeError,ValueError' "$WORK/summary-1" \
  && ok 'stdout summary reports newly observed signatures' || bad 'new-signature summary missing'

before=$(cksum < "$digest")
engineering_ledger_poll > "$WORK/summary-repeat"
after_first_six=$(sed -n '1,6p' "$digest" | cksum)
[ "$before" = "$after_first_six" ] && [ "$(wc -l < "$digest" | tr -d ' ')" = 12 ] \
  && ok 'repeat poll appends without rewriting prior records' || bad 'repeat poll was not append-only'

export ENGINEERING_LEDGER_DIR="$WORK/concurrent"
( engineering_ledger_poll > "$WORK/summary-concurrent-1" ) & poll_a=$!
( engineering_ledger_poll > "$WORK/summary-concurrent-2" ) & poll_b=$!
if wait "$poll_a" && wait "$poll_b" \
  && [ "$(wc -l < "$ENGINEERING_LEDGER_DIR/2026-08-08.jsonl" | tr -d ' ')" = 12 ] \
  && jq -e . "$ENGINEERING_LEDGER_DIR/2026-08-08.jsonl" >/dev/null 2>&1; then
  ok 'concurrent pollers serialize complete JSONL cycles'
else
  bad 'concurrent pollers interleaved or lost a cycle'
fi

foreign_lock="$WORK/foreign-lock"
mkdir "$foreign_lock"
printf '%s\n' 1 > "$foreign_lock/pid"
if ledger_lock_release "$foreign_lock" 2>/dev/null; then
  bad 'poller released a lock owned by another process'
elif [ -d "$foreign_lock" ] && [ -f "$foreign_lock/pid" ]; then
  ok 'lock release refuses another process ownership'
else
  bad 'foreign lock was altered despite ownership refusal'
fi

printf '== one source fails; others continue ==\n'
export ENGINEERING_LEDGER_DIR="$WORK/failure-isolation"
ledger_sentry_issues_json() {
  case "$1" in
    101) printf '%s\n' '[]' ;;
    202) return 1 ;;
    *) return 1 ;;
  esac
}
if engineering_ledger_poll > "$WORK/summary-2"; then
  ok 'poll returns success when one source is unreachable'
else
  bad 'one source failure blocked the poll'
fi
digest="$ENGINEERING_LEDGER_DIR/2026-08-08.jsonl"
[ "$(wc -l < "$digest" | tr -d ' ')" = 6 ] && ok 'failed source still has one ledger record' || bad 'failure cycle lost source records'
[ "$(jq -r 'select(.source=="sentry" and .source_id=="thurber-ai") | .status' "$digest")" = error ] \
  && ok 'failed source recorded as sanitized error' || bad 'failed source status missing'
[ "$(jq -r 'select(.source=="sentry" and .source_id=="tourguide") | .status' "$digest")" = ok ] \
  && ok 'sibling Sentry source still collected' || bad 'sibling Sentry source was blocked'
[ "$(jq -r 'select(.source=="kb") | .status' "$digest")" = ok ] \
  && ok 'KB source still collected' || bad 'KB source was blocked'
[ "$(jq -r 'select(.source=="github") | select(.status=="ok") | .source_id' "$digest" | wc -l | tr -d ' ')" = 3 ] \
  && ok 'all GitHub sources still collected' || bad 'GitHub collection was blocked'

printf '%s\n' '-----------------------------------------------------------------'
if [ "$fail" -eq 0 ]; then
  printf 'PASS: %d engineering-ledger checks passed\n' "$pass"
  exit 0
fi
printf 'FAIL: %d passed, %d failed\n' "$pass" "$fail"
exit 1
