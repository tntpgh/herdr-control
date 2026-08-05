#!/usr/bin/env bash
# verify-pick-pane-open.sh — proof that pick-pane-open.sh (the dispatcher
# that lets fzf-based --pick actions run under herdr, which invokes an
# action's `command` WITHOUT a TTY) opens the right pane entrypoint, on the
# right plugin, and forwards --cwd exactly when there is a real directory to
# forward — never a bogus or missing one.
#
# herdr is stubbed as a real executable pointed to via HERDR_BIN_PATH (the
# script's own override hook), not a PATH shim: pick-pane-open.sh never
# touches PATH itself, so this is simpler than herdr-select.sh's exported-
# function stub and exercises the actual lookup mechanism it uses.
#
#   bash verify-pick-pane-open.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# Stub: records its argv, one arg per line, and exits 0.
cat > "$WORK/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HERDR_STUB_ARGV_FILE"
exit 0
EOF
chmod +x "$WORK/herdr"
export HERDR_BIN_PATH="$WORK/herdr"
export HERDR_STUB_ARGV_FILE="$WORK/argv.txt"

REAL_REPO="$WORK/real-repo"
mkdir -p "$REAL_REPO"

run() { HERDR_PLUGIN_CONTEXT_JSON="${1:-}" HERDR_WORKSPACE_CWD="${2:-}" bash "$here/pick-pane-open.sh" "${3:-quick-actions-pick}" 2>"$WORK/err.txt"; }
argv_line() { sed -n "${1}p" "$WORK/argv.txt"; }

printf '== no context at all: opens the right pane, no --cwd forwarded ==\n'
: > "$WORK/argv.txt"
run "" "" "quick-actions-pick"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $(cat "$WORK/err.txt")"
[ "$(argv_line 1)" = "plugin" ] && [ "$(argv_line 2)" = "pane" ] && [ "$(argv_line 3)" = "open" ] && ok "invoked \"herdr plugin pane open\"" || bad "argv[1-3]=$(argv_line 1)/$(argv_line 2)/$(argv_line 3)"
grep -qx -- "--plugin" "$WORK/argv.txt" && grep -qx "tntpgh.herdr-control" "$WORK/argv.txt" && ok "defaults --plugin to tntpgh.herdr-control" || bad "plugin id wrong: $(cat "$WORK/argv.txt")"
grep -qx -- "--entrypoint" "$WORK/argv.txt" && grep -qx "quick-actions-pick" "$WORK/argv.txt" && ok "forwards the requested entrypoint id" || bad "entrypoint wrong: $(cat "$WORK/argv.txt")"
grep -qx -- "--placement" "$WORK/argv.txt" && grep -qx "overlay" "$WORK/argv.txt" && ok "placement=overlay" || bad "placement wrong"
grep -qx -- "--focus" "$WORK/argv.txt" && ok "opens focused" || bad "--focus missing"
grep -qx -- "--cwd" "$WORK/argv.txt" && bad "‑‑cwd forwarded with nothing to forward!" || ok "no --cwd when neither context JSON nor HERDR_WORKSPACE_CWD is set"

printf '== HERDR_PLUGIN_CONTEXT_JSON.focused_pane_cwd (a real dir) wins ==\n'
: > "$WORK/argv.txt"
ctx=$(printf '{"focused_pane_cwd": "%s", "workspace_cwd": "%s"}' "$REAL_REPO" "$WORK")
run "$ctx" "" "quick-actions-pick"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"
grep -qx -- "--cwd" "$WORK/argv.txt" && grep -qx "$REAL_REPO" "$WORK/argv.txt" && ok "forwards focused_pane_cwd" || bad "cwd not forwarded: $(cat "$WORK/argv.txt")"

printf '== falls back to workspace_cwd when focused_pane_cwd is absent ==\n'
: > "$WORK/argv.txt"
ctx=$(printf '{"workspace_cwd": "%s"}' "$REAL_REPO")
run "$ctx" "" "quick-actions-pick"; rc=$?
grep -qx -- "--cwd" "$WORK/argv.txt" && grep -qx "$REAL_REPO" "$WORK/argv.txt" && ok "forwards workspace_cwd" || bad "cwd not forwarded: $(cat "$WORK/argv.txt")"

printf '== a context JSON pointing at a directory that does not exist is silently dropped, not forwarded ==\n'
: > "$WORK/argv.txt"
ctx=$(printf '{"focused_pane_cwd": "%s"}' "$WORK/no-such-dir")
run "$ctx" "" "quick-actions-pick"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 — still opens the pane" || bad "exit $rc"
grep -qx -- "--cwd" "$WORK/argv.txt" && bad "forwarded --cwd pointing at a nonexistent directory" || ok "no --cwd for a nonexistent directory (falls back to plugin root)"

printf '== falls back to HERDR_WORKSPACE_CWD when there is no context JSON ==\n'
: > "$WORK/argv.txt"
run "" "$REAL_REPO" "quick-actions-pick"; rc=$?
grep -qx -- "--cwd" "$WORK/argv.txt" && grep -qx "$REAL_REPO" "$WORK/argv.txt" && ok "forwards HERDR_WORKSPACE_CWD" || bad "cwd not forwarded: $(cat "$WORK/argv.txt")"

printf '== malformed context JSON degrades to no --cwd, does not crash ==\n'
: > "$WORK/argv.txt"
run "not valid json{{{" "" "quick-actions-pick"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 despite malformed JSON" || bad "exit $rc on malformed JSON"
grep -qx -- "--cwd" "$WORK/argv.txt" && bad "forwarded --cwd derived from malformed JSON" || ok "no --cwd on malformed JSON"

printf '== the same dispatcher opens the OTHER entrypoint id it is given ==\n'
: > "$WORK/argv.txt"
run "" "" "projects-pick"; rc=$?
grep -qx "projects-pick" "$WORK/argv.txt" && ok "opens projects-pick when asked" || bad "entrypoint not forwarded: $(cat "$WORK/argv.txt")"

printf '== HERDR_PLUGIN_ID override is respected (matters if this plugin is ever forked/renamed) ==\n'
: > "$WORK/argv.txt"
( export HERDR_PLUGIN_ID="someone.fork"; HERDR_BIN_PATH="$WORK/herdr" HERDR_STUB_ARGV_FILE="$WORK/argv.txt" bash "$here/pick-pane-open.sh" "quick-actions-pick" >/dev/null 2>&1 )
grep -qx "someone.fork" "$WORK/argv.txt" && ok "uses HERDR_PLUGIN_ID when set" || bad "plugin id override ignored: $(cat "$WORK/argv.txt")"

printf '== missing entrypoint argument is a hard error, not a silent bad invoke ==\n'
out=$(bash "$here/pick-pane-open.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "nonzero exit with no entrypoint given" || bad "exit 0 with no entrypoint"
printf '%s' "$out" | grep -q "usage" && ok "prints usage" || bad "no usage message: $out"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
