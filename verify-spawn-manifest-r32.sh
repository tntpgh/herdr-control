#!/usr/bin/env bash
# verify-spawn-manifest-r32.sh — R3-2 (round-3 security review): a
# research/explore spawn with no --brief (manifest_json empty) used to merge
# handoffs_write via `"${manifest_json:-\{\}}"` — the backslashes stay
# LITERAL inside double quotes, so the default word expanded to the 4-byte
# string `\{\}`, not `{}`. jq then failed to parse it, and with no `set -e`
# at that point the failure was silent: manifest_json ended up EMPTY, the
# spawn fell through to the broad any-in-worktree write allow instead of the
# single-file handoffs_write restriction, and nothing in the output said so.
#
# Fix: default the empty case to a real `{}` and exit 1 if jq still fails,
# so a broken merge can never silently disappear. This proves the REAL,
# non-dry-run path (the jq merge only runs before register_task, which
# --dry-run exits before reaching) by reading spawn-task.sh's own final
# "capability manifest APPROVED" line, which prints the exact manifest_json
# register_task received.
#
#   bash verify-spawn-manifest-r32.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
real_jq=$(command -v jq)
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n       %s\n' "$1" "$2"; fail=1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
repo="$work/repo"; mkdir -p "$repo"; git -C "$repo" init -q
repo=$(cd "$repo" && pwd -P)

cat > "$work/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pane list") printf '{"result":{"panes":[]}}\n' ;;
  "tab list") printf '{"result":{"tabs":[]}}\n' ;;
  "workspace create") printf '{"result":{"workspace":{"workspace_id":"w1","active_tab_id":"tRoot"}}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1","terminal_id":"term1"}}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
STUB
chmod +x "$work/herdr"

printf '== a genuinely empty manifest (no --brief) still merges handoffs_write ==\n'
# No --brief passed: manifest_json starts genuinely empty, the exact
# pre-conditions the bug needed. explore is a write-restricted job class
# (lib/agent-profiles.sh tools_for_job), so the merge block runs.
out=$(env HERDR_EXTRA_PATH="$work" PATH="$work:$PATH" HERDR_WT_DIR="$work/wt" \
  HERDR_RUN_STATE_DIR="$work/state" HERDR_POSTURE_FLOOR=write HERDR_PANE_ID= \
  bash "$here/spawn-task.sh" "$repo" r32-branch explore omp 2>&1)
rc=$?
line=$(printf '%s\n' "$out" | grep -A1 'capability manifest APPROVED' | tail -1 | sed 's/^ *//')

[ "$rc" = 0 ] || bad "spawn exited $rc (expected 0 — a genuinely empty manifest must not refuse the spawn, only fail if jq itself cannot merge it)" "$out"
[ -n "$line" ] || bad "no 'capability manifest APPROVED' line in output" "$out"
if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
  ok "the final manifest_json register_task received is valid JSON (not the old broken '\\{\\}' / empty array)"
else
  bad "final manifest_json is not valid JSON" "$line"
fi
[ "$(printf '%s' "$line" | jq -r '.handoffs_write // empty' 2>/dev/null)" = "ANSWER.md" ] \
  && ok "handoffs_write survived the merge on a genuinely empty starting manifest" \
  || bad "handoffs_write missing from the merged manifest (R3-2 regression)" "$line"

printf '== a jq failure during the merge refuses the spawn instead of silently dropping handoffs_write ==\n'
# Only the manifest-merge invocation (its filter names handoffs_write) is
# made to fail -- every other jq call in the spawn (tab/pane id extraction,
# etc.) still goes to the real binary, so a failure here isolates the merge
# step specifically rather than breaking the spawn for an unrelated reason.
cat > "$work/jq" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *handoffs_write*) exit 1 ;;
  esac
done
exec "$real_jq" "\$@"
STUB
chmod +x "$work/jq"
out2=$(env HERDR_EXTRA_PATH="$work" PATH="$work:$PATH" HERDR_WT_DIR="$work/wt2" \
  HERDR_RUN_STATE_DIR="$work/state2" HERDR_POSTURE_FLOOR=write HERDR_PANE_ID= \
  bash "$here/spawn-task.sh" "$repo" r32-branch-2 explore omp 2>&1)
rc2=$?
[ "$rc2" != 0 ] \
  && ok "a jq failure during the manifest merge refuses the spawn (fail closed), rather than launching with handoffs_write silently lost" \
  || bad "a broken jq still let the spawn through: rc=$rc2" "$out2"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
