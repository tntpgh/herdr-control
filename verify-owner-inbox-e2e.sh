#!/usr/bin/env bash
# verify-owner-inbox-e2e.sh — real-registry e2e for register-owner.sh /
# unregister-owner.sh (ZERO-LOOP-001 #5), and proof that publisher.py's
# registry_owners()/owner_pane_status() read the SAME real sqlite file those
# scripts write, not a hand-built fixture (that unit-level coverage is
# remote-mcp/verify-owner-inbox.py; this script is the missing "through the
# real bash scripts against a scratch registry" half SPEC's acceptance list
# names).
#
# herdr is stubbed as an exported bash FUNCTION, not a PATH binary, because
# register-owner.sh re-exports PATH with the system directories first (same
# reasoning as verify-select-policy.sh) — a function wins command lookup
# regardless of what PATH says.
#
#   bash verify-owner-inbox-e2e.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
PANES_FILE="$WORK/panes.json"
export PANES_FILE

failures=0
check() {  # label condition-description actual-output
  if [ "$2" = "0" ]; then echo "  ok    $1"; else echo "  FAIL  $1 -- $3"; failures=$((failures + 1)); fi
}

# Agent pane w1:p1 (omp), shell pane w1:p9 (zsh, never a valid owner target).
cat > "$PANES_FILE" <<'EOF'
{"result":{"panes":[
  {"pane_id":"w1:p1","terminal_id":"term_a","workspace":"ops"},
  {"pane_id":"w1:p9","terminal_id":"term_shell","workspace":"ops"}
]}}
EOF

herdr() {
  case "$1 $2" in
    "pane list") cat "$PANES_FILE" ;;
    "pane process-info")
      case "$4" in
        w1:p1) printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
        w1:p9) printf '{"result":{"process_info":{"foreground_processes":[{"name":"zsh","cmdline":"-zsh"}]}}}\n' ;;
        *)     printf '{"result":{"process_info":{"foreground_processes":[]}}}\n' ;;
      esac ;;
    "pane get")
      printf '{"result":{"pane":{"agent_session":{"value":"/fake/sessions/conductor.jsonl"}}}}\n' ;;
    *) echo "fake herdr: unhandled call: $*" >&2; return 1 ;;
  esac
}
export -f herdr

echo "== register-owner.sh against a real scratch registry, real require_agent_pane =="
out=$(bash "$here/register-owner.sh" conductor w1:p1 2>&1); rc=$?
check "register-owner.sh exits 0 for an agent pane" "$([ "$rc" = 0 ] && echo 0 || echo 1)" "$out"
check "the printed row carries the real pane/birth/workspace" \
  "$(echo "$out" | grep -q '"pane_id":"w1:p1"' && echo "$out" | grep -q '"pane_birth":"term_a"' && echo "$out" | grep -q '"workspace":"ops"' && echo 0 || echo 1)" "$out"
check "the printed row carries the agent_session from the real pane get call" \
  "$(echo "$out" | grep -q 'conductor.jsonl' && echo 0 || echo 1)" "$out"

echo "== a target that is not an agent pane is refused by the REAL require_agent_pane, no row written =="
out2=$(bash "$here/register-owner.sh" shellowner w1:p9 2>&1); rc2=$?
check "register-owner.sh exits nonzero for a shell pane" "$([ "$rc2" != 0 ] && echo 0 || echo 1)" "$out2"
row2=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "SELECT count(*) FROM owners WHERE label='shellowner';" 2>/dev/null)
check "no owners row was ever written for the refused label" "$([ "${row2:-1}" = "0" ] && echo 0 || echo 1)" "row2=$row2"

echo "== a label failing the strict regex is refused before herdr is ever called =="
out3=$(bash "$here/register-owner.sh" Bad_Label w1:p1 2>&1); rc3=$?
check "register-owner.sh exits nonzero for an invalid label" "$([ "$rc3" != 0 ] && echo 0 || echo 1)" "$out3"

echo "== publisher.py's registry_owners()/owner_pane_status() read the SAME real file, birth matches =="
py_out=$(HERDR_RUN_REGISTRY="$HERDR_RUN_STATE_DIR/registry.sqlite3" python3 -c "
import importlib.util, sys
sys.path.insert(0, '$here/remote-mcp')
spec = importlib.util.spec_from_file_location('publisher_e2e', '$here/remote-mcp/publisher.py')
pub = importlib.util.module_from_spec(spec); sys.modules['publisher_e2e'] = pub; spec.loader.exec_module(pub)
rows = pub.registry_owners()
live = {'w1:p1': {'birth': 'term_a'}, 'w1:p9': {'birth': 'term_shell'}}
print('conductor_row_pane_id', rows.get('conductor', {}).get('pane_id'))
print('status_ok', pub.owner_pane_status('conductor', rows, live))
")
check "registry_owners() sees the real row register-owner.sh wrote" \
  "$(echo "$py_out" | grep -qx 'conductor_row_pane_id w1:p1' && echo 0 || echo 1)" "$py_out"
check "owner_pane_status() is 'ok' when the live birth matches the real registered birth" \
  "$(echo "$py_out" | grep -qx 'status_ok ok' && echo 0 || echo 1)" "$py_out"

echo "== a herdr restart (same pane_id, new terminal_id) reads as 'changed', not silently 'ok' =="
cat > "$PANES_FILE" <<'EOF'
{"result":{"panes":[
  {"pane_id":"w1:p1","terminal_id":"term_RESTARTED","workspace":"ops"}
]}}
EOF
py_out2=$(HERDR_RUN_REGISTRY="$HERDR_RUN_STATE_DIR/registry.sqlite3" python3 -c "
import importlib.util, sys
sys.path.insert(0, '$here/remote-mcp')
spec = importlib.util.spec_from_file_location('publisher_e2e2', '$here/remote-mcp/publisher.py')
pub = importlib.util.module_from_spec(spec); sys.modules['publisher_e2e2'] = pub; spec.loader.exec_module(pub)
rows = pub.registry_owners()
live = {'w1:p1': {'birth': 'term_RESTARTED'}}
print('status_changed', pub.owner_pane_status('conductor', rows, live))
")
check "owner_pane_status() is 'changed' once the live terminal_id disagrees with the registered one" \
  "$(echo "$py_out2" | grep -qx 'status_changed changed' && echo 0 || echo 1)" "$py_out2"

echo "== the pane vanishing entirely reads as 'gone' =="
py_out3=$(HERDR_RUN_REGISTRY="$HERDR_RUN_STATE_DIR/registry.sqlite3" python3 -c "
import importlib.util, sys
sys.path.insert(0, '$here/remote-mcp')
spec = importlib.util.spec_from_file_location('publisher_e2e3', '$here/remote-mcp/publisher.py')
pub = importlib.util.module_from_spec(spec); sys.modules['publisher_e2e3'] = pub; spec.loader.exec_module(pub)
rows = pub.registry_owners()
print('status_gone', pub.owner_pane_status('conductor', rows, {}))
")
check "owner_pane_status() is 'gone' once the pane_id is no longer in the live list" \
  "$(echo "$py_out3" | grep -qx 'status_gone gone' && echo 0 || echo 1)" "$py_out3"

echo "== unregister-owner.sh removes the real row; the Mac re-check then reads 'not_registered' =="
cat > "$PANES_FILE" <<'EOF'
{"result":{"panes":[{"pane_id":"w1:p1","terminal_id":"term_a","workspace":"ops"}]}}
EOF
out4=$(bash "$here/unregister-owner.sh" conductor 2>&1); rc4=$?
check "unregister-owner.sh exits 0" "$([ "$rc4" = 0 ] && echo 0 || echo 1)" "$out4"
row4=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "SELECT count(*) FROM owners WHERE label='conductor';" 2>/dev/null)
check "the real row is gone from the real registry" "$([ "${row4:-1}" = "0" ] && echo 0 || echo 1)" "row4=$row4"
out4b=$(bash "$here/unregister-owner.sh" conductor 2>&1); rc4b=$?
check "unregister-owner.sh is idempotent (exits 0 again on an already-absent label)" "$([ "$rc4b" = 0 ] && echo 0 || echo 1)" "$out4b"
py_out4=$(HERDR_RUN_REGISTRY="$HERDR_RUN_STATE_DIR/registry.sqlite3" python3 -c "
import importlib.util, sys
sys.path.insert(0, '$here/remote-mcp')
spec = importlib.util.spec_from_file_location('publisher_e2e4', '$here/remote-mcp/publisher.py')
pub = importlib.util.module_from_spec(spec); sys.modules['publisher_e2e4'] = pub; spec.loader.exec_module(pub)
rows = pub.registry_owners()
print('status_unregistered', pub.owner_pane_status('conductor', rows, {'w1:p1': {'birth': 'term_a'}}))
")
check "owner_pane_status() is 'not_registered' once unregister-owner.sh has removed the row" \
  "$(echo "$py_out4" | grep -qx 'status_unregistered not_registered' && echo 0 || echo 1)" "$py_out4"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures check(s)"
  exit 1
fi
echo "PASS: all real-registry owner-inbox e2e checks green"
