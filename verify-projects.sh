#!/usr/bin/env bash
# verify-projects.sh — proof that lib/project.sh + open-project.sh open a
# whole project workspace correctly: one ensure-workspace call, one
# layout_apply (tab) per project tab, focus only on the first tab, working_dir
# ~-expansion, and the CLI's headless/--pick/dry-run/unknown-name behaviour.
#
# herdr is stubbed as an exported bash FUNCTION (same technique as
# verify-layout.sh / verify-select-policy.sh). ensure-workspace.sh is REAL —
# not reimplemented — since it's invoked as a genuine subprocess and the
# exported herdr stub propagates to it, this exercises the shipping script,
# not a mock of it.
#
#   bash verify-projects.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/layout.sh"
. "$here/lib/project.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

export HERDR_LOG="$WORK/calls.log"
export HERDR_RUN_LOG="$WORK/runs.log"
export HERDR_FAIL_ON=""
export HERDR_SEQ_FILE="$WORK/seq"
: > "$HERDR_LOG"; : > "$HERDR_RUN_LOG"; echo 0 > "$HERDR_SEQ_FILE"
herdr() {
  printf '%s\n' "$*" >> "$HERDR_LOG"
  case "$1 $2" in
    "pane list")
      echo '{"result":{"panes":[]}}'
      ;;
    "workspace create")
      [ "$HERDR_FAIL_ON" = "workspace" ] && { echo '{"error":{"message":"stub: workspace create failed"}}'; return 1; }
      local n; n=$(( $(cat "$HERDR_SEQ_FILE") + 1 )); echo "$n" > "$HERDR_SEQ_FILE"
      printf '{"result":{"workspace":{"workspace_id":"ws-%s","active_tab_id":"roottab-%s"}}}\n' "$n" "$n"
      ;;
    "tab create")
      [ "$HERDR_FAIL_ON" = "tab" ] && { echo '{"error":{"message":"stub: tab create failed"}}'; return 1; }
      local n; n=$(( $(cat "$HERDR_SEQ_FILE") + 1 )); echo "$n" > "$HERDR_SEQ_FILE"
      printf '{"result":{"tab":{"tab_id":"tab-%s"},"root_pane":{"pane_id":"pane-%s","terminal_id":"term-%s"}}}\n' "$n" "$n" "$n"
      ;;
    "pane split")
      local n; n=$(( $(cat "$HERDR_SEQ_FILE") + 1 )); echo "$n" > "$HERDR_SEQ_FILE"
      printf '{"result":{"pane":{"pane_id":"pane-%s"}}}\n' "$n"
      ;;
    "pane run")
      printf '%s\n' "$*" >> "$HERDR_RUN_LOG"
      ;;
    "tab rename")
      : ;;
    "pane rename")
      : ;;
    *) echo '{"error":{"message":"stub: unhandled herdr call: '"$*"'"}}'; return 1 ;;
  esac
}
export -f herdr
reset_stub() { : > "$HERDR_LOG"; : > "$HERDR_RUN_LOG"; echo 0 > "$HERDR_SEQ_FILE"; HERDR_FAIL_ON=""; }
calls_matching() { grep -c "$1" "$HERDR_LOG" 2>/dev/null || true; }

printf '== project_validate rejects malformed input ==\n'
project_validate '[]' 2>/dev/null; [ $? -eq 1 ] && ok "array (not object) rejected" || bad "array accepted"
project_validate '{"name":"x"}' 2>/dev/null; [ $? -eq 1 ] && ok "missing working_dir/tabs rejected" || bad "incomplete project accepted"
project_validate '{"name":"x","working_dir":"/tmp","tabs":[],"nope":1}' 2>/dev/null
[ $? -eq 1 ] && ok "unknown top-level key rejected" || bad "typo'd key accepted"
project_validate '{"name":"x","working_dir":"/tmp","tabs":[{"panes":[{}]}]}' 2>/dev/null
[ $? -eq 1 ] && ok "tab missing label rejected" || bad "labelless tab accepted"
project_validate '{"name":"x","working_dir":"/tmp","tabs":[{"label":"a","panes":[{"bogus":1}]}]}' 2>/dev/null
[ $? -eq 1 ] && ok "invalid nested panes layout rejected (delegates to layout_validate)" || bad "bad panes accepted"
project_validate '{"name":"x","working_dir":"/tmp","tabs":[{"label":"a","panes":[{"cmd":"nvim"}]}]}' 2>/dev/null
[ $? -eq 0 ] && ok "well-formed single-tab project accepted" || bad "well-formed project rejected"

printf '== project_open: single tab -> one workspace, one tab-create, focus on tab 0 ==\n'
reset_stub
project_open '{"name":"x","working_dir":"'"$WORK"'","tabs":[{"label":"work","panes":[{"cmd":"claude","focus":true}]}]}' --no-focus >/dev/null
[ "$(calls_matching '^workspace create')" = "1" ] && ok "one workspace create" || bad "workspace create calls=$(calls_matching '^workspace create')"
[ "$(calls_matching '^tab create')" = "1" ] && ok "one tab create" || bad "tab create calls=$(calls_matching '^tab create')"
[ "$PROJECT_WORKSPACE_ID" = "ws-1" ] && ok "PROJECT_WORKSPACE_ID threaded" || bad "PROJECT_WORKSPACE_ID=$PROJECT_WORKSPACE_ID"
grep -q '^tab rename roottab-1 ' "$HERDR_LOG" && ok "root tab renamed using workspace create's active_tab_id" || bad "no/wrong tab rename: $(grep '^tab rename' "$HERDR_LOG")"

printf '== project_open: 3 tabs -> one workspace, THREE tab-creates, only tab 0 gets the project focus flag ==\n'
reset_stub
project_open '{"name":"x","working_dir":"'"$WORK"'","tabs":[
  {"label":"a","panes":[{}]},
  {"label":"b","panes":[{}]},
  {"label":"c","panes":[{}]}
]}' --focus >/dev/null
[ "$(calls_matching '^workspace create')" = "1" ] && ok "workspace created ONCE even with 3 tabs" || bad "workspace create calls=$(calls_matching '^workspace create')"
[ "$(calls_matching '^tab create')" = "3" ] && ok "3 tab creates, one per project tab" || bad "tab create calls=$(calls_matching '^tab create')"
first_tab_line=$(grep '^tab create' "$HERDR_LOG" | sed -n '1p')
rest_tab_lines=$(grep '^tab create' "$HERDR_LOG" | sed -n '2,3p')
printf '%s' "$first_tab_line" | grep -q -- '--focus$' && ok "tab 0 got the project-level --focus" || bad "tab 0 focus wrong: $first_tab_line"
printf '%s\n' "$rest_tab_lines" | grep -qv -- '--no-focus$' && bad "a later tab was NOT --no-focus: $rest_tab_lines" || ok "tabs 1 and 2 are --no-focus regardless of the project flag"

printf '== project_open: working_dir ~-expansion ==\n'
reset_stub
mkdir -p "$WORK/home/proj"
HOME="$WORK/home" project_open '{"name":"x","working_dir":"~/proj","tabs":[{"label":"a","panes":[{}]}]}' --no-focus >/dev/null
grep -q -- "--cwd $WORK/home/proj" "$HERDR_LOG" && ok "~ expanded against HOME before ensure-workspace" || bad "cwd not expanded: $(grep 'tab create' "$HERDR_LOG")"

printf '== project_open: a herdr call failing mid-build propagates, names the tab, stops the loop ==\n'
reset_stub
HERDR_FAIL_ON=tab
project_open '{"name":"x","working_dir":"'"$WORK"'","tabs":[
  {"label":"a","panes":[{}]},
  {"label":"b","panes":[{}]}
]}' --no-focus >/dev/null 2>"$WORK/err.txt"; rc=$?
HERDR_FAIL_ON=""
[ "$rc" -eq 1 ] && ok "exit 1 when a tab's herdr call fails" || bad "exit $rc (expected 1)"
grep -q 'tab "a" failed to build' "$WORK/err.txt" && ok "failure names the failing tab" || bad "no explanation on stderr: $(cat "$WORK/err.txt")"
[ "$(calls_matching '^tab create')" = "1" ] && ok "loop stopped after the first failure — tab \"b\" never attempted" || bad "unexpected tab-create count=$(calls_matching '^tab create')"

printf '== open-project.sh: dry-run makes zero herdr calls, prints every tab and pane ==\n'
reset_stub
PROJDIR="$WORK/projects"; mkdir -p "$PROJDIR"
cat > "$PROJDIR/demo.json" <<'EOF'
{"name":"demo","description":"a demo","working_dir":"/tmp",
 "tabs":[{"label":"one","panes":[{"cmd":"echo hi","label":"Hi"}]},
         {"label":"two","panes":[{"cmd":"echo bye"}]}]}
EOF
bash -c '
  set -uo pipefail
  export HERDR_LOG="'"$HERDR_LOG"'"
  export XDG_CONFIG_HOME="'"$WORK"'/empty-xdg"
  cd "'"$here"'"
  # simulate the projects/ dir by symlinking the demo project in temporarily
  ln -sf "'"$PROJDIR"'/demo.json" "'"$here"'/projects/__verify_demo__.json"
  bash "'"$here"'/open-project.sh" --dry-run demo
  rm -f "'"$here"'/projects/__verify_demo__.json"
' >"$WORK/dry.txt" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "dry-run exits 0" || bad "dry-run exit $rc: $(cat "$WORK/dry.txt")"
[ ! -s "$HERDR_LOG" ] && ok "dry-run made ZERO herdr calls" || bad "dry-run called herdr"
grep -q 'tab: one' "$WORK/dry.txt" && grep -q 'tab: two' "$WORK/dry.txt" && ok "both tabs printed" || bad "missing a tab in dry-run output: $(cat "$WORK/dry.txt")"
grep -q 'label=Hi' "$WORK/dry.txt" && ok "pane label shown in plan" || bad "pane label missing from dry-run"

printf '== open-project.sh: unknown name lists available projects, tagged by scope, on stderr ==\n'
XDG_CONFIG_HOME="$WORK/empty-xdg" bash "$here/open-project.sh" --dry-run this-project-does-not-exist >"$WORK/out.txt" 2>"$WORK/err.txt"; rc=$?
[ "$rc" -ne 0 ] && ok "nonzero exit for unknown project" || bad "exit 0 for an unknown project name"
grep -q "no such project" "$WORK/err.txt" && ok "explains the miss on stderr" || bad "no explanation"
grep -q "herdr-control (example)" "$WORK/err.txt" && ok "lists a real shipped example, tagged (example)" || bad "available list missing/wrong: $(cat "$WORK/err.txt")"

printf '== open-project.sh: personal tier (XDG config dir) is discovered and tagged (personal) ==\n'
PERSONAL="$WORK/xdg-config"; mkdir -p "$PERSONAL/herdr-control/projects"
cat > "$PERSONAL/herdr-control/projects/mine.json" <<'EOF'
{"name":"mine","description":"my real project","working_dir":"/tmp",
 "tabs":[{"label":"work","panes":[{"cmd":"claude"}]}]}
EOF
XDG_CONFIG_HOME="$PERSONAL" bash "$here/open-project.sh" --dry-run mine >"$WORK/personal.txt" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "personal-tier project resolves headlessly" || bad "exit $rc: $(cat "$WORK/personal.txt")"
grep -q "$PERSONAL/herdr-control/projects/mine.json" "$WORK/personal.txt" && ok "resolved from the personal (XDG config) dir, not the repo" || bad "wrong file resolved: $(cat "$WORK/personal.txt")"

printf '== open-project.sh: a name that exists in BOTH tiers resolves to the PERSONAL one ==\n'
cat > "$PERSONAL/herdr-control/projects/herdr-control.json" <<'EOF'
{"name":"herdr-control","description":"a personal override","working_dir":"/tmp",
 "tabs":[{"label":"work","panes":[{"cmd":"claude"}]}]}
EOF
XDG_CONFIG_HOME="$PERSONAL" bash "$here/open-project.sh" --dry-run herdr-control >"$WORK/collide.txt" 2>&1
grep -q "a personal override" "$WORK/collide.txt" && ok "personal tier wins over the shipped example on a name collision" || bad "shipped example won instead: $(cat "$WORK/collide.txt")"


printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
