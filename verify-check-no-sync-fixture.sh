#!/usr/bin/env bash
# verify-check-no-sync-fixture.sh — round 7 review (narrowed, same-day second
# correction): the first fix for finding 1 routed a queued occurrence flush
# through an anonymous waiter-closure array specifically so
# check-no-sync-on-agent-start.mjs's identifier-based call graph could never
# resolve the dispatch back to a named function — a spawnSync reachable from
# onBeforeAgentStart, hidden from the guard that exists to catch exactly
# that. Rejected as a second instance of the round 6 glob-evasion problem;
# the production fix was replaced with a genuinely async flush (option a),
# and the checker itself was extended to catch this SHAPE generically (an
# "opaque dispatch": a reachable function calling a bare identifier that is
# neither a tracked top-level function, an import, a global, a parameter,
# nor a local declaration — see opaqueCalleesOf in the checker).
#
# This proves the extension actually fires: a minimal fixture reproducing
# the exact evasion shape (push a spawnSync-calling closure into a
# module-level array from an UNREACHABLE function; a REACHABLE function
# drains the array generically via `for (const w of q) w()`) must FAIL.
# The real hook file is run alongside as a positive control and must PASS.
#
#   bash verify-check-no-sync-fixture.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

cat > "$WORK/fixture.ts" <<'EOF'
import { spawnSync } from "node:child_process";

function onBeforeAgentStart(): void {
  ensureHub();
}

function ensureHub(): void {
  refreshHubPythonAsync();
}

let waiters: Array<() => void> = [];

function refreshHubPythonAsync(): void {
  const q = waiters;
  waiters = [];
  for (const w of q) w();
}

// Unreachable from onBeforeAgentStart by name — only reachable through the
// stored closure refreshHubPythonAsync drains generically above.
function registerFlush(): void {
  waiters.push(() => {
    doSync();
  });
}

function doSync(): void {
  spawnSync("python3", ["-c", "pass"]);
}
EOF

printf '== negative fixture: a closure-hidden spawnSync reachable only via a stored-callback array must FAIL ==\n'
out="$(bun "$here/agent-hooks/check-no-sync-on-agent-start.mjs" "$WORK/fixture.ts" onBeforeAgentStart 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'opaque' \
  && ok "checker FAILS on the evasion-shaped fixture (opaque dispatch caught): $out" \
  || bad "expected FAIL mentioning opaque dispatch, got rc=$rc: $out"

printf '== positive control: the real hook file must still PASS ==\n'
out2="$(cd "$here" && bun agent-hooks/check-no-sync-on-agent-start.mjs 2>&1)"; rc2=$?
[ "$rc2" -eq 0 ] && ok "real file still PASSES: $out2" || bad "real file regressed: $out2"

echo "-----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
