#!/usr/bin/env bash
# verify-claims.sh — pins lib/claims.sh and claim.sh.
#
# Runs against a THROWAWAY registry (HERDR_RUN_STATE_DIR in a temp dir), so it
# never touches the real control plane. Every check is a real two-pane race or
# a real clock lapse — nothing here asserts that a function merely returns.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

TMPROOT=$(mktemp -d)
export HERDR_RUN_STATE_DIR="$TMPROOT/state"
REPO_A="$TMPROOT/repoA"
REPO_B="$TMPROOT/repoB"
for r in "$REPO_A" "$REPO_B"; do
  mkdir -p "$r" && git -C "$r" init -q 2>/dev/null
done

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }

# Every invocation is a fresh process with an explicit pane identity, which is
# exactly how two real panes reach the registry. HERDR_PANE_ID is unset because
# the harness itself runs inside a real pane, and that would otherwise make
# both "panes" the same one — a bug this suite hit while being written.
claim() { env -u HERDR_PANE_ID CLAIM_PANE_ID="$1" "$HERE/claim.sh" "${@:2}"; }

printf '\n== acquire / renew / conflict ==\n'

out=$(claim w:p1 take "$REPO_A" -m "first work"); rc=$?
check "p1 acquires a free scope" "$rc" "0"
case "$out" in *"claimed repoA"*) ok "acquire names the scope" ;; *) bad "acquire names the scope" "$out" ;; esac

claim w:p1 take "$REPO_A" -m "first work" >/dev/null; rc=$?
check "re-acquiring own scope is a renewal, not a conflict" "$rc" "0"

out=$(claim w:p2 take "$REPO_A" -m "second work"); rc=$?
check "a second pane is refused with rc=2" "$rc" "2"
case "$out" in *"already claimed by w:p1"*) ok "conflict names the holder" ;; *) bad "conflict names the holder" "$out" ;; esac
case "$out" in *"first work"*) ok "conflict names the holder's purpose" ;; *) bad "conflict names the holder's purpose" "$out" ;; esac

out=$(claim w:p2 take "$REPO_B" -m "other repo"); rc=$?
check "a disjoint scope is free to claim concurrently" "$rc" "0"

printf '\n== visibility ==\n'
out=$(claim w:p2 status)
case "$out" in *"held elsewhere"*repoA*) ok "status shows another pane's holdings" ;; *) bad "status shows another pane's holdings" "$out" ;; esac
case "$out" in *repoB*) ok "status shows this pane's own holdings" ;; *) bad "status shows own holdings" "$out" ;; esac

out=$(claim w:p3 who "$REPO_A")
case "$out" in *w:p1*) ok "who names the holder" ;; *) bad "who names the holder" "$out" ;; esac

out=$(claim w:p3 list)
case "$out" in *repoA*repoB*|*repoB*repoA*) ok "list shows every live claim" ;; *) bad "list shows every live claim" "$out" ;; esac

printf '\n== release ==\n'
claim w:p1 drop "$REPO_A" >/dev/null
out=$(claim w:p3 who "$REPO_A")
case "$out" in *unclaimed*) ok "drop frees the scope" ;; *) bad "drop frees the scope" "$out" ;; esac

claim w:p2 take "$REPO_A" -m "took over" >/dev/null; rc=$?
check "a freed scope is immediately claimable" "$rc" "0"

# A pane may not silently release someone else's claim — the one thing an
# advisory system must not allow between peers.
claim w:p9 drop "$REPO_A" >/dev/null
out=$(claim w:p3 who "$REPO_A")
case "$out" in *w:p2*) ok "drop cannot release another pane's claim" ;; *) bad "drop cannot release another pane's claim" "$out" ;; esac

claim w:p9 drop "$REPO_A" --force >/dev/null
out=$(claim w:p3 who "$REPO_A")
case "$out" in *unclaimed*) ok "--force can release another pane's claim (human override)" ;; *) bad "--force releases" "$out" ;; esac

printf '\n== TTL is the reaper ==\n'
HERDR_CLAIM_TTL_S=1 claim w:p1 take "$REPO_A" -m "short lease" >/dev/null
out=$(claim w:p3 who "$REPO_A")
case "$out" in *w:p1*) ok "a fresh short lease is held" ;; *) bad "a fresh short lease is held" "$out" ;; esac
sleep 2
out=$(claim w:p3 who "$REPO_A")
case "$out" in *unclaimed*) ok "a lapsed lease auto-releases with no sweeper running" ;; *) bad "lapsed lease auto-releases" "$out" ;; esac
claim w:p2 take "$REPO_A" -m "after expiry" >/dev/null; rc=$?
check "another pane can claim after expiry" "$rc" "0"

printf '\n== chained conductors: a child may not escape its parent ==\n'
mkdir -p "$REPO_A/sub" && git -C "$REPO_A/sub" init -q 2>/dev/null
claim w:p2 drop "$REPO_A" >/dev/null
claim w:p7 take "$REPO_A" -m "conductor scope" >/dev/null
parent_id=$(claim w:p7 id "$REPO_A")

if [ -n "$parent_id" ]; then
  ok "a holder's claim id is readable from the CLI"

  claim w:p8 take "$REPO_A/sub" -m "sub-conductor" --parent "$parent_id" >/dev/null 2>&1
  rc=$?
  check "a child scope INSIDE the parent's is allowed" "$rc" "0"

  claim w:p9 take "$REPO_B" -m "escapes parent" --parent "$parent_id" >/dev/null 2>&1
  rc=$?
  [ "$rc" != 0 ] && ok "a child scope OUTSIDE the parent's is refused" \
                 || bad "a child scope OUTSIDE the parent's is refused" "rc=$rc"

  # A delegation whose parent has since lapsed must not still be honoured —
  # otherwise an expired conductor keeps minting children forever.
  claim w:p7 drop "$REPO_A" --force >/dev/null
  claim w:pA take "$REPO_A/sub2" -m "orphan child" --parent "$parent_id" >/dev/null 2>&1
  rc=$?
  [ "$rc" != 0 ] && ok "delegation under a released parent is refused" \
                 || bad "delegation under a released parent is refused" "rc=$rc"
else
  bad "a holder's claim id is readable from the CLI" "got empty"
fi

printf '\n== summary ==\n'
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
