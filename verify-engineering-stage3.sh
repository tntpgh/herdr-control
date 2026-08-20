#!/usr/bin/env bash
# verify-engineering-stage3.sh — acceptance checks for the Stage-3/E2 bounded
# auto-fix mechanism (lib/engineering-stage3.sh, stage3-execute.sh).
#
# Uses crafted fixtures only, matching verify-engineering-ledger.sh's pattern
# -- no live spawn-task.sh call, no live repo, no real Fable-5/Sol worker.
# stage3_spawn_worker is overridden with a stub that RECORDS what it was
# asked to do instead of doing it, so "an allowlisted+safe item reaches the
# spawn call" is proven by inspecting the stub's captured args, not by
# actually launching anything.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/engineering-stage2.sh"
. "$here/lib/engineering-stage3.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

# ---- fixture repos ----------------------------------------------------------
mkdir -p "$WORK/repos/knowledge-base/connectors" "$WORK/repos/knowledge-base/server" \
         "$WORK/repos/tourguide" "$WORK/repos/thurber-ai/src/dispatch" \
         "$WORK/repos/thurber-ai/src/workflows"
export ENGINEERING_LEDGER_KB_REPO="$WORK/repos/knowledge-base"
export ENGINEERING_LEDGER_TOURGUIDE_REPO="$WORK/repos/tourguide"
export ENGINEERING_LEDGER_THURBER_AI_REPO="$WORK/repos/thurber-ai"

printf 'def foo():\n    pass\n' > "$WORK/repos/knowledge-base/connectors/imessage.py"
printf 'def write_zipforms_fields(address, fields_json, dry_run=True):\n    pass\ndef other_tool():\n    pass\n' \
  > "$WORK/repos/knowledge-base/server/mcp_server.py"
printf 'def other_tool():\n    pass\n' > "$WORK/repos/knowledge-base/server/api_server.py"
printf 'export async function dispatch(request, deps) {}\n' > "$WORK/repos/thurber-ai/src/dispatch/dispatcher.ts"
printf 'import { dispatch } from "../dispatch/dispatcher";\nexport async function run() { dispatch(x); }\n' \
  > "$WORK/repos/thurber-ai/src/workflows/daily-digest.ts"

STATE_DIR="$WORK/state"
AUDIT_LOG="$STATE_DIR/audit.jsonl"
DOC="$WORK/fake-stage2-doc.md"
NOW="2026-08-20T12:00:00Z"

# ---- spawn stub: records instead of launching --------------------------------
SPAWN_CALLS="$WORK/spawn-calls.jsonl"
: > "$SPAWN_CALLS"
stage3_spawn_worker() {  # <repo> <repo_dir> <branch> <prompt>
  jq -nc --arg repo "$1" --arg repo_dir "$2" --arg branch "$3" --arg prompt "$4" \
    '{repo:$repo, repo_dir:$repo_dir, branch:$branch, prompt:$prompt}' >> "$SPAWN_CALLS"
  printf 'spawned %s ws=fake-ws tab=fake-tab pane=t9:p1  [background]\n' "debug:$3"
  return 0
}

finding() {  # repo file class [line_hint] [fix_summary] -> json
  jq -nc --arg repo "$1" --arg file "$2" --arg class "$3" \
    --argjson line_hint "${4:-null}" --arg fix_summary "${5:-a fix}" \
    '{repo:$repo, file:$file, class:$class, line_hint:$line_hint, fix_summary:$fix_summary}'
}

reset_state() { rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; : > "$AUDIT_LOG"; : > "$SPAWN_CALLS"; }

# ============================================================================
printf '== stage2 doc parsing (fail-closed contract) ==\n'
printf 'Some prose. No structured block here.\n' > "$DOC"
if stage3_extract_findings "$DOC" >/dev/null 2>&1; then
  bad 'doc missing the fenced block should fail closed'
else
  ok 'doc missing the fenced block fails closed (exit 1, nothing parsed)'
fi

cat > "$DOC" <<'EOF'
Some prose.
```stage3-findings
[not valid json
```
EOF
if stage3_extract_findings "$DOC" >/dev/null 2>&1; then
  bad 'malformed JSON inside the fence should fail closed'
else
  ok 'malformed JSON inside the fence fails closed'
fi

cat > "$DOC" <<'EOF'
Some prose.
```stage3-findings
[{"repo": "knowledge-base", "class": "dead_code"}]
```
EOF
if stage3_extract_findings "$DOC" >/dev/null 2>&1; then
  bad 'a finding missing required fields (file/fix_summary) should fail closed'
else
  ok 'a finding missing required fields fails closed'
fi

cat > "$DOC" <<'EOF'
Some prose.
```stage3-findings
[]
```
EOF
extracted=$(stage3_extract_findings "$DOC") && [ "$(printf '%s' "$extracted" | jq 'length')" = 0 ] \
  && ok 'a well-formed empty array parses as zero findings (ran, found nothing)' \
  || bad 'well-formed empty array should parse cleanly'

# ============================================================================
printf '== acceptance 1: allowlisted + safe item reaches the spawn call ==\n'
reset_state
f=$(finding knowledge-base connectors/imessage.py missing_error_observability 388 "add structured logging to the FDA permission check")
decision=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$decision" = fired ] && ok 'allowlisted + safe finding decides fired' || bad "expected fired, got '$decision'"
[ "$(wc -l < "$SPAWN_CALLS" | tr -d ' ')" = 1 ] && ok 'stage3_spawn_worker was called exactly once' \
  || bad 'stage3_spawn_worker call count wrong'
call=$(cat "$SPAWN_CALLS")
[ "$(jq -r '.repo' <<<"$call")" = knowledge-base ] && ok 'spawn call carries the right repo' \
  || bad 'spawn call repo wrong'
[ "$(jq -r '.repo_dir' <<<"$call")" = "$WORK/repos/knowledge-base" ] && ok 'spawn call carries the resolved repo_dir' \
  || bad 'spawn call repo_dir wrong'
printf '%s' "$call" | jq -r '.branch' | grep -q '^evolution-loop/stage3-fix-' \
  && ok 'spawn call branch name follows the evolution-loop/stage3-fix-* convention' \
  || bad 'spawn call branch name malformed'
printf '%s' "$call" | jq -r '.prompt' | grep -qF 'connectors/imessage.py' \
  && ok 'the built prompt names the exact target file' || bad 'prompt missing target file'
printf '%s' "$call" | jq -r '.prompt' | grep -qF 'missing_error_observability' \
  && ok 'the built prompt names the exact bug class' || bad 'prompt missing bug class'
printf '%s' "$call" | jq -r '.prompt' | grep -qi 'PR-only, human-merged' \
  && ok 'the built prompt states the PR-only/never-merge boundary' || bad 'prompt missing PR-only boundary'
jq -e 'select(.decision=="fired") | .repo=="knowledge-base"' "$AUDIT_LOG" >/dev/null 2>&1 \
  && ok 'audit log recorded the fired decision' || bad 'audit log missing fired entry'

# ============================================================================
printf '== acceptance 2: denylisted path is correctly skipped, never spawned ==\n'
reset_state
f=$(finding knowledge-base connectors/zipforms_playwright.py dead_code)
decision=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$decision" = skipped-denylist ] && ok 'whole-file denylist entry (zipforms_playwright.py) is skipped' \
  || bad "expected skipped-denylist, got '$decision'"
[ ! -s "$SPAWN_CALLS" ] && ok 'denylisted item never reaches stage3_spawn_worker' \
  || bad 'denylisted item incorrectly called spawn_worker'
jq -e 'select(.decision=="skipped-denylist")' "$AUDIT_LOG" >/dev/null 2>&1 \
  && ok 'denylist skip is logged loudly (present in audit trail)' || bad 'denylist skip missing from audit log'

reset_state
f=$(finding knowledge-base server/mcp_server.py missing_error_observability)
decision=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$decision" = skipped-denylist ] && ok 'content-scoped denylist (write_zipforms_fields in mcp_server.py) is skipped' \
  || bad "expected skipped-denylist for mcp_server.py, got '$decision'"

reset_state
f=$(finding knowledge-base server/api_server.py missing_error_observability)
decision=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$decision" = fired ] && ok 'content-scoped denylist does NOT over-block a file without the unsafe function present' \
  || bad "api_server.py without _handle_zipforms_approve should have fired, got '$decision'"

reset_state
f=$(finding thurber-ai src/dispatch/dispatcher.ts dead_code)
decision=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$decision" = skipped-denylist ] && ok 'thurber-ai dispatch chokepoint file is denylisted' \
  || bad "expected skipped-denylist for dispatcher.ts, got '$decision'"

reset_state
f=$(finding thurber-ai src/workflows/daily-digest.ts dead_code)
decision=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$decision" = skipped-denylist ] && ok 'a workflows/*.ts file that calls dispatch( is denylisted' \
  || bad "expected skipped-denylist for daily-digest.ts, got '$decision'"

# ============================================================================
printf '== acceptance 3: non-allowlisted class is correctly skipped ==\n'
reset_state
f=$(finding knowledge-base connectors/imessage.py entity_relation_corruption)
decision=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$decision" = skipped-not-allowlisted ] && ok 'a class outside the three-item allowlist is skipped' \
  || bad "expected skipped-not-allowlisted, got '$decision'"
[ ! -s "$SPAWN_CALLS" ] && ok 'non-allowlisted item never reaches stage3_spawn_worker' \
  || bad 'non-allowlisted item incorrectly called spawn_worker'

reset_state
f=$(finding some-other-repo connectors/imessage.py dead_code)
decision=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$decision" = skipped-not-allowlisted ] && ok 'a repo outside {knowledge-base,tourguide,thurber-ai} is skipped' \
  || bad "expected skipped-not-allowlisted for out-of-scope repo, got '$decision'"

# ============================================================================
printf '== acceptance 4: rate-limited repeat signature is correctly skipped ==\n'
reset_state
f=$(finding knowledge-base connectors/imessage.py dead_code)
first=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
second=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$first" = fired ] && ok 'first fire of a signature succeeds' || bad "expected first fire, got '$first'"
[ "$second" = skipped-rate-limited ] && ok 'immediate repeat of the same signature is cooldown-limited (7d)' \
  || bad "expected skipped-rate-limited, got '$second'"
[ "$(wc -l < "$SPAWN_CALLS" | tr -d ' ')" = 1 ] && ok 'rate-limited repeat never reaches stage3_spawn_worker a second time' \
  || bad 'rate-limited repeat incorrectly called spawn_worker'

# Cooldown clears after 7 days + 1 second.
later=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' -v+7d -v+1S "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "$NOW + 7 days + 1 second" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
if [ -n "$later" ]; then
  third=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$later" 0)
  [ "$third" = fired ] && ok 'same signature fires again once the 7-day cooldown has elapsed' \
    || bad "expected fired after cooldown elapsed, got '$third'"
else
  bad 'could not compute a +7d timestamp to test cooldown expiry (date arithmetic unavailable)'
fi

# Global hourly cap: 30 distinct signatures within the same hour saturate it;
# the 31st (still within the hour, a fresh signature so per-signature
# cooldown does not apply) must be capped.
reset_state
i=1
while [ "$i" -le 30 ]; do
  f=$(finding knowledge-base "connectors/synthetic_${i}.py" dead_code)
  d=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
  [ "$d" = fired ] || bad "hourly-cap warmup: signature $i expected fired, got '$d'"
  i=$((i + 1))
done
f31=$(finding knowledge-base connectors/synthetic_31.py dead_code)
d31=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f31" "$NOW" 0)
[ "$d31" = skipped-rate-limited ] && ok 'the 31st fire within one hour hits the 30/hr global cap' \
  || bad "expected skipped-rate-limited (global cap), got '$d31'"

# ============================================================================
printf '== dry-run never spawns and never consumes rate-limit budget ==\n'
reset_state
f=$(finding knowledge-base connectors/imessage.py dead_code)
d=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 1)
[ "$d" = dry-run-would-fire ] && ok 'dry-run reports dry-run-would-fire, not fired' || bad "expected dry-run-would-fire, got '$d'"
[ ! -s "$SPAWN_CALLS" ] && ok 'dry-run never calls stage3_spawn_worker' || bad 'dry-run incorrectly called spawn_worker'
d2=$(stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0)
[ "$d2" = fired ] && ok 'a real run after a dry-run for the same signature still fires (dry-run did not burn rate-limit budget)' \
  || bad "expected fired after a prior dry-run, got '$d2'"

# ============================================================================
printf '== audit log sanitization (reuses ledger_sanitize_label, not reimplemented) ==\n'
reset_state
f=$(finding knowledge-base "connectors/leak_test.py" dead_code null "contains a bearer token=abcdef0123456789abcdef0123456789 in the summary")
stage3_process_finding "$STATE_DIR" "$AUDIT_LOG" "$DOC" "$f" "$NOW" 0 >/dev/null
if rg -qi 'abcdef0123456789abcdef0123456789' "$AUDIT_LOG" 2>/dev/null; then
  bad 'a secret-shaped fix_summary leaked into the audit log unsanitized'
else
  ok 'audit log never carries raw fix_summary text (only sanitized file/class/reason fields)'
fi

# ============================================================================
printf '%s\n' '-----------------------------------------------------------------'
printf 'stage3: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  exit 0
fi
exit 1
