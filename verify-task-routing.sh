#!/usr/bin/env bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/task-routing.sh"
pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
expect_role(){
  local name=$1 brief=$2 expected=$3 out role
  out=$(route_task_deterministic "$brief" 2>/dev/null) || true
  role=$(printf '%s' "$out" | jq -r .role)
  [ "$role" = "$expected" ] && ok "$name" || bad "$name (got $out)"
}
expect_role "ordinary implementation" "Implement the parser change" implementer
expect_role "planning" "Design and break down the parser" planner
for brief in "Rotate the auth token" "Rotate stored credentials" "Read secrets from the vault" "Drop the customer table" "Run destructive cleanup" "Handle the payment refund" "Send an external email" "Send external comms update" "Email the customer a status update" "Deploy to production"; do
  out=$(route_task_deterministic "$brief" 2>/dev/null) && bad "high-risk escalates: $brief" || {
    [ "$(printf '%s' "$out" | jq -r .role)" = escalate ] && ok "high-risk escalates: $brief" || bad "high-risk malformed: $brief"
  }
done
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
