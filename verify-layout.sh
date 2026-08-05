#!/usr/bin/env bash
# verify-layout.sh — proof that lib/layout.sh drives the REAL herdr CLI shape
# (positional pane id on `pane split`, --direction/--ratio/--cwd/--env/--focus,
# `.result.tab.tab_id` / `.result.root_pane.pane_id` / `.result.pane.pane_id`
# response fields) and that spread-tab.sh's layout-file resolution and
# dry-run mode behave as documented.
#
# herdr is stubbed as an exported bash FUNCTION (same technique as
# verify-select-policy.sh) so what's verified is the shipping script against
# the herdr CLI's argument/response contract, not a reimplementation of it.
#
#   bash verify-layout.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/layout.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# ---- the stub ---------------------------------------------------------------
# Handles exactly the three herdr calls layout_apply makes: tab create, pane
# split, pane run. Counts calls per kind and logs full argv so assertions can
# check the exact flags composed (cwd resolution, env forwarding, focus
# threading) without guessing at the real CLI's behaviour from outside it.
export HERDR_LOG="$WORK/calls.log"
export HERDR_RUN_LOG="$WORK/runs.log"
export HERDR_FAIL_ON=""   # "tab" or "split" to make that call error
export HERDR_SEQ_FILE="$WORK/seq"
: > "$HERDR_LOG"; : > "$HERDR_RUN_LOG"; echo 0 > "$HERDR_SEQ_FILE"
herdr() {
  printf '%s\n' "$*" >> "$HERDR_LOG"
  case "$1 $2" in
    "tab create")
      [ "$HERDR_FAIL_ON" = "tab" ] && { echo '{"error":{"message":"stub: tab create failed"}}'; return 1; }
      local n; n=$(( $(cat "$HERDR_SEQ_FILE") + 1 )); echo "$n" > "$HERDR_SEQ_FILE"
      printf '{"result":{"tab":{"tab_id":"tab-%s"},"root_pane":{"pane_id":"pane-%s","terminal_id":"term-%s"}}}\n' "$n" "$n" "$n"
      ;;
    "pane split")
      [ "$HERDR_FAIL_ON" = "split" ] && { echo '{"error":{"message":"stub: pane split failed"}}'; return 1; }
      local n; n=$(( $(cat "$HERDR_SEQ_FILE") + 1 )); echo "$n" > "$HERDR_SEQ_FILE"
      printf '{"result":{"pane":{"pane_id":"pane-%s"}}}\n' "$n"
      ;;
    "pane run")
      printf '%s\n' "$*" >> "$HERDR_RUN_LOG"
      ;;
    "pane rename")
      printf '%s\n' "$*" >> "$HERDR_LOG"
      ;;
    *) echo '{"error":{"message":"stub: unhandled herdr call: '"$*"'"}}'; return 1 ;;
  esac
}
export -f herdr

reset_stub() { : > "$HERDR_LOG"; : > "$HERDR_RUN_LOG"; echo 0 > "$HERDR_SEQ_FILE"; HERDR_FAIL_ON=""; }
calls_matching() { grep -c "$1" "$HERDR_LOG" 2>/dev/null || true; }

printf '== layout_validate rejects malformed input ==\n'
layout_validate '{}' 2>/dev/null; [ $? -eq 1 ] && ok "object (not array) rejected" || bad "object accepted"
layout_validate '[]' 2>/dev/null; [ $? -eq 1 ] && ok "empty array rejected" || bad "empty array accepted"
layout_validate '[{"comand":"typo"}]' 2>/dev/null; [ $? -eq 1 ] && ok "unknown key rejected" || bad "typo'd key accepted"
layout_validate '[{"split":"up"}]' 2>/dev/null; [ $? -eq 1 ] && ok "bad split value rejected" || bad "split=up accepted"
layout_validate '[{"ratio":"0.3"}]' 2>/dev/null; [ $? -eq 1 ] && ok "string-typed ratio rejected" || bad "string ratio \"0.3\" accepted"
layout_validate '[{"ratio":1.5}]' 2>/dev/null; [ $? -eq 1 ] && ok "ratio >= 1 rejected" || bad "ratio=1.5 accepted"
layout_validate '[{"ratio":0}]' 2>/dev/null; [ $? -eq 1 ] && ok "ratio <= 0 rejected" || bad "ratio=0 accepted"
layout_validate '[{"ratio":0.5}]' 2>/dev/null; [ $? -eq 0 ] && ok "in-range numeric ratio accepted" || bad "ratio=0.5 rejected"
layout_validate '[{"cmd":"nvim"},{"split":"down","cmd":"npm run dev"}]' 2>/dev/null
[ $? -eq 0 ] && ok "well-formed 2-pane layout accepted" || bad "well-formed layout rejected"

printf '== layout_apply: single-pane layout makes exactly one tab-create, no split, no run ==\n'
reset_stub
layout_apply ws1 /repo mytab --no-focus '[{}]' >/dev/null
[ "$(calls_matching '^tab create')" = "1" ] && ok "one tab create" || bad "tab create calls=$(calls_matching '^tab create')"
[ "$(calls_matching '^pane split')" = "0" ] && ok "no pane split" || bad "unexpected split call"
[ ! -s "$HERDR_RUN_LOG" ] && ok "no pane run (cmd omitted)" || bad "pane run called with no cmd"
[ "$LAYOUT_TAB_ID" = "tab-1" ] && ok "LAYOUT_TAB_ID threaded from response" || bad "LAYOUT_TAB_ID=$LAYOUT_TAB_ID"
[ "${#LAYOUT_PANE_IDS[@]}" = "1" ] && [ "${LAYOUT_PANE_IDS[0]}" = "pane-1" ] && ok "LAYOUT_PANE_IDS threaded" || bad "LAYOUT_PANE_IDS=${LAYOUT_PANE_IDS[*]:-<empty>}"

printf '== layout_apply: 2-pane layout splits off the ROOT pane, runs cmd in both ==\n'
reset_stub
layout_apply ws1 /repo mytab --no-focus '[{"cmd":"nvim"},{"split":"down","ratio":0.3,"cmd":"npm run dev"}]' >/dev/null
[ "$(calls_matching '^tab create')" = "1" ] && ok "one tab create" || bad "tab create calls=$(calls_matching '^tab create')"
[ "$(calls_matching '^pane split')" = "1" ] && ok "one pane split" || bad "split calls=$(calls_matching '^pane split')"
grep -q '^pane split pane-1 --direction down --ratio 0.3' "$HERDR_LOG" \
  && ok "split chained off the FIRST pane's real id, with direction+ratio forwarded" \
  || bad "split args wrong: $(grep '^pane split' "$HERDR_LOG")"
[ "$(wc -l < "$HERDR_RUN_LOG" | tr -d ' ')" = "2" ] && ok "cmd run in both panes" || bad "run calls=$(cat "$HERDR_RUN_LOG")"
grep -q '^pane run pane-1 nvim$' "$HERDR_RUN_LOG" && ok "root pane ran its own cmd" || bad "root cmd missing/wrong"
grep -q '^pane run pane-2 npm run dev$' "$HERDR_RUN_LOG" && ok "split pane ran its own cmd" || bad "split cmd missing/wrong"

printf '== label: set via a SEPARATE pane rename call, in creation order ==\n'
reset_stub
layout_apply ws1 /repo mytab --no-focus '[{"cmd":"nvim","label":"Editor"},{"split":"down","cmd":"npm run dev","label":"Server"}]' >/dev/null
grep -q '^pane rename pane-1 Editor$' "$HERDR_LOG" && ok "root pane labeled" || bad "root label missing/wrong"
grep -q '^pane rename pane-2 Server$' "$HERDR_LOG" && ok "split pane labeled" || bad "split label missing/wrong"

printf '== label: omitted entirely -> no pane rename call ==\n'
reset_stub
layout_apply ws1 /repo mytab --no-focus '[{"cmd":"nvim"}]' >/dev/null
[ "$(calls_matching '^pane rename')" = "0" ] && ok "no rename call when label omitted" || bad "unexpected rename call"

printf '== cwd resolution: relative joins the layout root, absolute/~ pass through untouched ==\n'
reset_stub
layout_apply ws1 /repo mytab --no-focus '[{"cwd":"./src"},{"split":"right","cwd":"/var/log"},{"split":"right","cwd":"~/logs"}]' >/dev/null
grep -q -- '--cwd /repo/./src' "$HERDR_LOG" && ok "relative cwd joined to layout root" || bad "relative cwd: $(grep 'tab create' "$HERDR_LOG")"
grep -q -- '--cwd /var/log' "$HERDR_LOG" && ok "absolute cwd passed through" || bad "absolute cwd not preserved"
grep -q -- "--cwd $HOME/logs" "$HERDR_LOG" && ok "~ cwd expanded to \$HOME before reaching herdr" || bad "~ cwd not expanded: $(grep 'pane split' "$HERDR_LOG" | tail -1)"

printf '== env forwarding: layout env becomes --env K=V on the pane create/split call ==\n'
reset_stub
layout_apply ws1 /repo mytab --no-focus '[{"env":{"NODE_ENV":"development"}}]' >/dev/null
grep -q -- '--env NODE_ENV=development' "$HERDR_LOG" && ok "env forwarded verbatim" || bad "env missing: $(cat "$HERDR_LOG")"

printf '== focus threading: an explicit pane focus wins over the tab-level flag ==\n'
reset_stub
layout_apply ws1 /repo mytab --focus '[{"focus":false},{"split":"down","focus":true}]' >/dev/null
grep -q '^tab create.*--no-focus$' "$HERDR_LOG" && ok "root pane NOT focused (explicit focus=false beats tab-level --focus)" || bad "root focus wrong: $(grep 'tab create' "$HERDR_LOG")"
grep -q '^pane split.*--focus$' "$HERDR_LOG" && ok "split pane focused (its own focus=true)" || bad "split focus wrong: $(grep 'pane split' "$HERDR_LOG")"

printf '== focus threading: nobody declares focus -> tab-level flag falls through to the root pane ==\n'
reset_stub
layout_apply ws1 /repo mytab --focus '[{},{"split":"down"}]' >/dev/null
grep -q '^tab create.*--focus$' "$HERDR_LOG" && ok "root pane inherits tab-level --focus" || bad "root focus not inherited"
grep -q '^pane split.*--no-focus$' "$HERDR_LOG" && ok "split pane stays unfocused" || bad "split focus wrong"

printf '== herdr call failure propagates (tab create) ==\n'
reset_stub; HERDR_FAIL_ON=tab
layout_apply ws1 /repo mytab --no-focus '[{}]' >/dev/null 2>"$WORK/err.txt"; rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 on tab create failure" || bad "exit $rc (expected 1)"
grep -q "tab create failed" "$WORK/err.txt" && ok "failure explained on stderr" || bad "no explanation on stderr"

printf '== herdr call failure propagates (pane split), root pane already created ==\n'
reset_stub; HERDR_FAIL_ON=split
layout_apply ws1 /repo mytab --no-focus '[{},{"split":"down"}]' >/dev/null 2>"$WORK/err.txt"; rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 on split failure" || bad "exit $rc (expected 1)"
grep -q "pane split failed" "$WORK/err.txt" && ok "failure explained on stderr" || bad "no explanation on stderr"

printf '== spread-tab.sh: layout resolution order and dry-run print the plan without calling herdr ==\n'
reset_stub
PROJ="$WORK/proj-acme"; mkdir -p "$PROJ"
bash "$here/spread-tab.sh" --dry-run --layout example-dev "$PROJ" work >"$WORK/dry.txt" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "dry-run exits 0" || bad "dry-run exit $rc: $(cat "$WORK/dry.txt")"
[ ! -s "$HERDR_LOG" ] && ok "dry-run made ZERO herdr calls" || bad "dry-run called herdr: $(cat "$HERDR_LOG")"
grep -q "layouts/example-dev.json" "$WORK/dry.txt" && ok "explicit --layout selects the named file" || bad "wrong layout selected: $(cat "$WORK/dry.txt")"

mkdir -p "$here/layouts"
echo '[{"cmd":"__probe__"}]' > "$here/layouts/proj-acme.json"
bash "$here/spread-tab.sh" --dry-run "$PROJ" work >"$WORK/dry2.txt" 2>&1
grep -q "layouts/proj-acme.json" "$WORK/dry2.txt" \
  && ok "project-named layout auto-picked ahead of default.json" \
  || bad "auto-pick failed: $(cat "$WORK/dry2.txt")"
rm -f "$here/layouts/proj-acme.json"

bash "$here/spread-tab.sh" --dry-run "$PROJ" work >"$WORK/dry3.txt" 2>&1
grep -q "layouts/default.json" "$WORK/dry3.txt" \
  && ok "falls back to default.json once the project-named override is gone" \
  || bad "fallback failed: $(cat "$WORK/dry3.txt")"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
