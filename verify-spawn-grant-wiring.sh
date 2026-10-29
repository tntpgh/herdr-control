#!/usr/bin/env bash
# Offline: spawn-task.sh grant gate refuses BEFORE any side effect.
# Fake herdr on PATH records every call; temp repo + temp registry only.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $1"; }; bad(){ fail=$((fail+1)); echo "FAIL $1"; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/state" "$t/wt"
python3 - "$t" <<'PY'
import os, sys, shlex
t = sys.argv[1]; p = os.path.join(t, "bin", "herdr")
open(p, "w").write('#!/bin/sh\necho "$*" >> %s/herdr.calls\necho "{}"\n' % shlex.quote(t))
os.chmod(p, 0o755)
PY
git init -q "$t/repo"; git -C "$t/repo" -c user.email=x@y -c user.name=x commit -q --allow-empty -m base
run(){ env -u HERDR_PANE_ID PATH="$t/bin:$PATH" HERDR_RUN_STATE_DIR="$t/state" HERDR_WT_DIR="$t/wt" "$@" bash "$here/spawn-task.sh" "${SPAWN_ARGS[@]}" >"$t/out" 2>&1; echo $?; }

SPAWN_ARGS=("$t/repo" probe/grant implement)
rc=$(run HERDR_WORKER_GRANT_ENFORCE=1)
[ "$rc" = 3 ] && grep -q "no --grant" "$t/out" && ok "enforce on + no --grant -> refused (exit 3)" || bad "no-grant rc=$rc $(tail -2 "$t/out")"
[ -z "$(git -C "$t/repo" worktree list --porcelain | grep -c '^worktree ' | grep -v '^1$')" ] && ok "no worktree created" || bad "worktree created"
[ ! -s "$t/herdr.calls" ] && ok "zero herdr calls (no tab/workspace)" || bad "herdr called: $(cat "$t/herdr.calls")"

SPAWN_ARGS=(--grant nope "$t/repo" probe/grant implement)
rc=$(run HERDR_WORKER_GRANT_ENFORCE=1)
[ "$rc" = 3 ] && grep -q "did not admit" "$t/out" && ok "unknown grant -> refused (exit 3)" || bad "unknown grant rc=$rc $(tail -2 "$t/out")"
[ ! -s "$t/herdr.calls" ] && ok "still zero herdr calls" || bad "herdr called"

SPAWN_ARGS=(--dry-run "$t/repo" probe/grant implement)
rc=$(run HERDR_WORKER_GRANT_ENFORCE=0)
grep -q "no --grant" "$t/out" && bad "inactive default still gated" || ok "default INACTIVE: no grant check when enforce unset (rc=$rc)"

echo "spawn-grant-wiring: $pass passed, $fail failed"; [ "$fail" = 0 ]
