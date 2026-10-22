#!/usr/bin/env bash
# Offline: fake herdr + temp registry. Proves classification and read-only.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $1"; }; bad(){ fail=$((fail+1)); echo "FAIL $1"; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; mkdir -p "$t/bin" "$t/state"
fake(){ python3 - "$t" "$1" <<'PY'
import os, sys
t, body = sys.argv[1], sys.argv[2]
p = os.path.join(t, "bin", "herdr")
open(p, "w").write("#!/bin/sh\necho \"$*\" >> %s/herdr.calls\nprintf '%%s' '%s'\n" % (t, body))
os.chmod(p, 0o755)
PY
}
db="$t/state/registry.sqlite3"
sqlite3 "$db" "CREATE TABLE tasks(task_id,state,pane_id,pane_birth,label,created_at);
INSERT INTO tasks VALUES('a','running','w1:p1','b1','live-one','2026-10-21T00:00');
INSERT INTO tasks VALUES('b','running','w1:p2','b2','gone-one','2026-10-20T00:00');
INSERT INTO tasks VALUES('c','blocked','w1:p3','old','recycled-one','2026-10-19T00:00');
INSERT INTO tasks VALUES('d','completed','w9:p9','x','done-one','2026-10-18T00:00');"
before=$(sqlite3 "$db" "select group_concat(task_id||state) from tasks")
fake '{"result":{"panes":[{"pane_id":"w1:p1","terminal_id":"b1"},{"pane_id":"w1:p3","terminal_id":"new"}]}}'
out=$(PATH="$t/bin:$PATH" HERDR_RUN_STATE_DIR="$t/state" bash "$here/orphan-plan.sh")
grep -qE '^LIVE .*live-one' <<<"$out" && ok "matching birth -> LIVE" || bad "live: $out"
grep -qE '^ORPHAN .*gone-one.*pane absent' <<<"$out" && ok "absent pane -> ORPHAN" || bad "absent"
grep -qE '^ORPHAN .*recycled-one.*recycled' <<<"$out" && ok "recycled pane_id -> ORPHAN" || bad "recycled"
grep -q done-one <<<"$out" && bad "terminal row listed" || ok "terminal rows ignored"
[ "$(sqlite3 "$db" "select group_concat(task_id||state) from tasks")" = "$before" ] && ok "registry unchanged (read-only)" || bad "registry changed"
grep -qvE '^pane list' "$t/herdr.calls" 2>/dev/null && bad "non-list herdr call: $(cat "$t/herdr.calls")" || ok "only 'herdr pane list' called"
fake 'garbage'
out=$(PATH="$t/bin:$PATH" HERDR_RUN_STATE_DIR="$t/state" bash "$here/orphan-plan.sh")
grep -q "^ORPHAN" <<<"$out" && bad "unreadable herdr produced ORPHAN" || ok "unreadable pane list -> all UNKNOWN, never orphan"
echo "orphan-plan: $pass passed, $fail failed"; [ "$fail" = 0 ]
